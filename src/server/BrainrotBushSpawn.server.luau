--[[
	╔══════════════════════════════════════════════════════════════╗
	║              BRAINROT BUSH SPAWN SYSTEM                     ║
	║                                                              ║
	║  Brainrots randomly appear in bushes across all Lands.       ║
	║  Each bush has an independent timer. Collecting resets       ║
	║  that bush to a longer cooldown to prevent farming.          ║
	║                                                              ║
	║  All tunable values are in the CONFIGURATION block below.    ║
	╚══════════════════════════════════════════════════════════════╝

	-- CONFLICT: src/client/BushHoldInteraction.luau also attaches Search prompts to
	-- every BushSCRIPT under Map. Running both systems yields duplicate prompts.
	-- Disable BushHoldInteraction.init() in init.client.luau until harvest is wired
	-- into onPlayerInteract below (Section 3f TODO).
--]]

-- ══════════════════════════════════════════════════════════════
--  CONFIGURATION — edit these values to balance the game
-- ══════════════════════════════════════════════════════════════

local CONFIG = {
	-- Initial spawn: how long after server start before a bush first spawns
	InitialCooldownMin = 30, -- seconds
	InitialCooldownMax = 180, -- seconds

	-- Normal respawn: after an uncollected brainrot despawns on its own
	RespawnCooldownMin = 45, -- seconds
	RespawnCooldownMax = 150, -- seconds

	-- Post-discovery: after a player collects a brainrot (anti-farm)
	DiscoveryCooldownMin = 60, -- seconds (1 minute minimum)
	DiscoveryCooldownMax = 120, -- seconds

	-- How long an uncollected brainrot stays before auto-despawning
	UncollectedDespawn = 90, -- seconds

	-- ProximityPrompt settings
	PromptHoldDuration = 0.5, -- seconds to hold E
	PromptMaxDistance = 8, -- studs
	PromptActionText = "Search",
	PromptObjectText = "Bush",

	-- Brainrot positioning
	SpawnHeightOffset = 0, -- studs above bush CFrame to place the brainrot

	-- Path to brainrot templates
	-- ⚠️ TODO: Confirm this path matches your ReplicatedStorage layout
	BrainrotFolder = nil :: Instance?, -- set after services load
}

-- Retry when the brainrot pool is empty (not in CONFIG — fixed backoff)
local EMPTY_POOL_RETRY_SEC = 10

-- ══════════════════════════════════════════════════════════════
--  SERVICES & REFERENCES
-- ══════════════════════════════════════════════════════════════

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- ⚠️ TODO: Confirm this path matches your ReplicatedStorage layout
CONFIG.BrainrotFolder = ReplicatedStorage:WaitForChild("Brainrots")

local Map = Workspace:WaitForChild("Map")
local Lands = Map:WaitForChild("Lands")

type BushState = {
	part: Instance,
	landName: string,
	hasRot: boolean,
	isBeingCollected: boolean,
	currentRot: Model?,
	prompt: ProximityPrompt,
	timerVersion: number,
	despawnVersion: number,
}

local bushStates: { BushState } = {}

-- ══════════════════════════════════════════════════════════════
--  HELPERS
-- ══════════════════════════════════════════════════════════════

--[[
	getRandomCooldown — returns a float in [min, max] for non-uniform timer spacing.
]]
local function getRandomCooldown(minSec: number, maxSec: number): number
	return math.random() * (maxSec - minSec) + minSec
end

--[[
	getLandNameForBush — walks ancestors until parent is Lands (Land1, Last, etc.).
]]
local function getLandNameForBush(bush: Instance): string
	local node: Instance? = bush.Parent
	while node and node ~= Lands do
		if node.Parent == Lands then
			return node.Name
		end
		node = node.Parent
	end
	return "Unknown"
end

--[[
	getBushPivot — world CFrame for positioning clones and prompts.
]]
local function getBushPivot(bush: Instance): CFrame?
	if bush:IsA("BasePart") then
		-- ⚠️ TODO: If BushSCRIPT is a Model, change .CFrame → :GetPivot()
		return bush.CFrame
	end
	if bush:IsA("Model") then
		-- ⚠️ TODO: If BushSCRIPT is a Model, change .CFrame → :GetPivot()
		return bush:GetPivot()
	end
	return nil
end

--[[
	getPromptHost — BasePart to parent the ProximityPrompt onto.
]]
local function getPromptHost(bush: Instance): BasePart?
	if bush:IsA("BasePart") then
		return bush
	end
	if bush:IsA("Model") then
		local m = bush :: Model
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		return m:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

--[[
	pickRandomBrainrot — returns a template Instance from the pool, not a clone.
]]
local function pickRandomBrainrot(): Instance?
	local folder = CONFIG.BrainrotFolder
	if not folder then
		warn("[BrainrotSystem] BrainrotFolder not configured")
		return nil
	end

	local pool: { Instance } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(pool, child)
		end
	end

	if #pool == 0 then
		warn("[BrainrotSystem] ReplicatedStorage.Brainrots has no Model children — retrying spawn later")
		return nil
	end

	return pool[math.random(1, #pool)]
end

-- ══════════════════════════════════════════════════════════════
--  CORE FUNCTIONS (forward declarations for mutual calls)
-- ══════════════════════════════════════════════════════════════

local cleanup: (BushState) -> ()
local spawnBrainrot: (BushState) -> ()
local onPlayerInteract: (BushState, Player) -> ()
local onExpired: (BushState) -> ()

--[[
	startSpawnCooldown — schedules spawnBrainrot after a random delay; cancels prior spawn timers.
]]
local function startSpawnCooldown(bushState: BushState, minSec: number, maxSec: number, reason: string)
	bushState.timerVersion += 1
	local capturedVersion = bushState.timerVersion
	local seconds = getRandomCooldown(minSec, maxSec)

	print(
		string.format(
			"[BrainrotSystem] Spawn cooldown started (%.1fs) land=%s bush=%s reason=%s",
			seconds,
			bushState.landName,
			bushState.part:GetFullName(),
			reason
		)
	)

	task.delay(seconds, function()
		if bushState.timerVersion ~= capturedVersion then
			print(
				string.format(
					"[BrainrotSystem] Spawn timer cancelled land=%s bush=%s reason=%s",
					bushState.landName,
					bushState.part:GetFullName(),
					reason
				)
			)
			return
		end
		if bushState.part.Parent == nil then
			return
		end
		spawnBrainrot(bushState)
	end)
end

--[[
	startUncollectedDespawnTimer — auto-despawn if nobody collects the rot.
]]
local function startUncollectedDespawnTimer(bushState: BushState)
	bushState.despawnVersion += 1
	local capturedVersion = bushState.despawnVersion
	local seconds = CONFIG.UncollectedDespawn

	task.delay(seconds, function()
		if bushState.despawnVersion ~= capturedVersion then
			print(
				string.format(
					"[BrainrotSystem] Despawn timer cancelled land=%s bush=%s",
					bushState.landName,
					bushState.part:GetFullName()
				)
			)
			return
		end
		if bushState.part.Parent == nil then
			return
		end
		onExpired(bushState)
	end)
end

--[[
	cleanup — removes active rot, resets flags, disables prompt. Safe on collect and expiry.
]]
cleanup = function(bushState: BushState)
	local rot = bushState.currentRot
	if rot and rot.Parent ~= nil then
		rot:Destroy()
	end
	bushState.currentRot = nil
	bushState.hasRot = false
	bushState.isBeingCollected = false
	bushState.prompt.Enabled = false
end

--[[
	spawnBrainrot — clones a template, parents to ActiveBrainrots, enables prompt, starts despawn timer.
]]
spawnBrainrot = function(bushState: BushState)
	if bushState.part.Parent == nil then
		return
	end
	if bushState.hasRot then
		return
	end

	local template = pickRandomBrainrot()
	if not template then
		task.delay(EMPTY_POOL_RETRY_SEC, function()
			if bushState.part.Parent == nil then
				return
			end
			if bushState.hasRot then
				return
			end
			spawnBrainrot(bushState)
		end)
		return
	end

	-- ⚠️ TODO: Assumes brainrots are Models in ReplicatedStorage.Brainrots.
	-- If they live elsewhere or are a different type, change the path and clone logic here.
	local clone = template:Clone()
	if not clone:IsA("Model") then
		warn("[BrainrotSystem] Cloned brainrot is not a Model: " .. clone:GetFullName())
		clone:Destroy()
		return
	end

	local pivot = getBushPivot(bushState.part)
	if not pivot then
		warn("[BrainrotSystem] Could not read pivot for bush: " .. bushState.part:GetFullName())
		clone:Destroy()
		return
	end

	local spawnCf = pivot + Vector3.new(0, CONFIG.SpawnHeightOffset, 0)
	clone:PivotTo(spawnCf)

	local activeFolder = Workspace:FindFirstChild("ActiveBrainrots")
	if not activeFolder or not activeFolder:IsA("Folder") then
		activeFolder = Instance.new("Folder")
		activeFolder.Name = "ActiveBrainrots"
		activeFolder.Parent = Workspace
	end
	clone.Parent = activeFolder

	bushState.currentRot = clone
	bushState.hasRot = true
	bushState.isBeingCollected = false
	bushState.prompt.Enabled = true

	-- ⚠️ TODO: Decide if bushes with brainrots should have a visual tell (particle, glow, shake).
	-- If yes, add the visual effect here when spawning and remove it in cleanup.

	print(
		string.format(
			"[BrainrotSystem] Brainrot spawned name=%s land=%s bush=%s",
			clone.Name,
			bushState.landName,
			bushState.part:GetFullName()
		)
	)

	startUncollectedDespawnTimer(bushState)
end

--[[
	onPlayerInteract — first player wins; starts post-discovery cooldown.
]]
onPlayerInteract = function(bushState: BushState, player: Player)
	if not bushState.hasRot then
		return
	end
	if bushState.isBeingCollected then
		return
	end

	bushState.isBeingCollected = true
	bushState.despawnVersion += 1

	cleanup(bushState)

	-- ⚠️ TODO: Award the brainrot to the player here.
	-- This is where you'd update a datastore, add to inventory, fire a client RemoteEvent for UI, etc.
	-- For now, just prints to confirm it works.
	print(
		string.format(
			"[BrainrotSystem] Brainrot collected player=%s land=%s bush=%s",
			player.Name,
			bushState.landName,
			bushState.part:GetFullName()
		)
	)

	startSpawnCooldown(
		bushState,
		CONFIG.DiscoveryCooldownMin,
		CONFIG.DiscoveryCooldownMax,
		"post-discovery"
	)
end

--[[
	onExpired — nobody collected in time; normal respawn cooldown.
]]
onExpired = function(bushState: BushState)
	if not bushState.hasRot then
		return
	end

	print(
		string.format(
			"[BrainrotSystem] Brainrot expired land=%s bush=%s",
			bushState.landName,
			bushState.part:GetFullName()
		)
	)

	cleanup(bushState)

	startSpawnCooldown(bushState, CONFIG.RespawnCooldownMin, CONFIG.RespawnCooldownMax, "uncollected-expiry")
end

--[[
	initializeBush — builds state, creates disabled ProximityPrompt, starts initial cooldown.
]]
local function initializeBush(bush: Instance): BushState?
	local host = getPromptHost(bush)
	if not host then
		warn("[BrainrotSystem] BushSCRIPT has no BasePart to host prompt: " .. bush:GetFullName())
		return nil
	end

	-- ⚠️ TODO: Currently using ProximityPrompt. Swap to Touched/ClickDetector/RemoteEvent if needed.
	-- To swap: delete the ProximityPrompt creation block, and replace the .Triggered connection below.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BrainrotBushSpawnPrompt"
	prompt.HoldDuration = CONFIG.PromptHoldDuration
	prompt.MaxActivationDistance = CONFIG.PromptMaxDistance
	prompt.ActionText = CONFIG.PromptActionText
	prompt.ObjectText = CONFIG.PromptObjectText
	prompt.Enabled = false
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("BrainrotSpawnManaged", true)
	prompt.Parent = host

	local bushState: BushState = {
		part = bush,
		landName = getLandNameForBush(bush),
		hasRot = false,
		isBeingCollected = false,
		currentRot = nil,
		prompt = prompt,
		timerVersion = 0,
		despawnVersion = 0,
	}

	prompt.Triggered:Connect(function(player: Player)
		onPlayerInteract(bushState, player)
	end)

	table.insert(bushStates, bushState)

	print(
		string.format(
			"[BrainrotSystem] Bush initialized land=%s bush=%s",
			bushState.landName,
			bush:GetFullName()
		)
	)

	startSpawnCooldown(bushState, CONFIG.InitialCooldownMin, CONFIG.InitialCooldownMax, "initial")

	return bushState
end

-- ══════════════════════════════════════════════════════════════
--  INITIALIZATION — runs once on server start
-- ══════════════════════════════════════════════════════════════

local activeBrainrots = Workspace:FindFirstChild("ActiveBrainrots")
if not activeBrainrots or not activeBrainrots:IsA("Folder") then
	activeBrainrots = Instance.new("Folder")
	activeBrainrots.Name = "ActiveBrainrots"
	activeBrainrots.Parent = Workspace
end

local totalBushes = 0
local landCount = 0

for _, land in ipairs(Lands:GetChildren()) do
	landCount += 1
	local bushFolder = land:FindFirstChild("BushSCRIPTs")
	if not bushFolder then
		continue
	end

	for _, child in ipairs(bushFolder:GetChildren()) do
		if child.Name == "BushSCRIPT" then
			if initializeBush(child) then
				totalBushes += 1
			end
		end
	end
end

print(
	string.format(
		"[BrainrotSystem] Initialized %d bushes across %d lands.",
		totalBushes,
		landCount
	)
)
