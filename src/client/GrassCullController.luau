-- [ACTIVE] GrassCullController
--[[
	Client-only land content cull (kept name for init wiring).

	When a Map.Lands/LandN is more than KEEP_RADIUS lands away:
	  - Park (reparent into a local cache) every non-essential child so grass,
	    bushes, trees, rocks, and decor stop rendering.
	  - Restore when the player is back within range.
	Nothing is Destroy'd.

	Also:
	  - Never keep Models/Folders just because they're named "Island"/"Ground"
	    (that used to leave thousands of nested grassparts loaded).
	  - Only BasePart walk surfaces + spawn/hitboxes stay on far lands.
	  - On the current land, strip CastShadow / CanCollide on grassparts in batches.
	  - If land can't be resolved, park ALL land decor (don't leave the whole map up).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

-- Current land only — lands ahead / behind / 2+ away stay parked.
local KEEP_RADIUS = 0
local POLL_SEC = 0.35
local FORCE_APPLY_SEC = 2.0
local SHADOW_STRIP_PER_FRAME = 90
local FEATURE_ENABLED = true

local player = Players.LocalPlayer
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsChildConn: RBXScriptConnection? = nil
local accum = 0.0
local forceAccum = 0.0
local currentLand = 0

type CullEntry = {
	inst: Instance,
	home: Instance,
	land: number,
}

local entries: { [Instance]: CullEntry } = {}
local landFolders: { [number]: Instance } = {}
local landChildConns: { [number]: RBXScriptConnection } = {}

local cacheFolder: Folder? = nil

-- Grassparts waiting for one-time shadow/collision strip (current land only).
local shadowQueue: { BasePart } = {}
local shadowQueued: { [BasePart]: boolean } = {}
local shadowDone: { [BasePart]: boolean } = {}

local HEAVY_EXACT: { [string]: boolean } = {
	grass = true,
	bushes = true,
	bush = true,
	bushscript = true,
	bushscripts = true,
	trees = true,
	tree = true,
	rocks = true,
	rock = true,
	decor = true,
	decoration = true,
	decorations = true,
	foliage = true,
	props = true,
	prop = true,
	plants = true,
	plant = true,
	flowers = true,
	flower = true,
	leaves = true,
	leaf = true,
	detail = true,
	details = true,
	mesh = true,
	meshes = true,
	vegetation = true,
	scenery = true,
	clutter = true,
}

local function getCache(): Folder
	local existing = cacheFolder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LandContentCullCache"
	folder.Parent = player:FindFirstChild("PlayerScripts") or player
	cacheFolder = folder
	return folder
end

local function landsRoot(): Instance?
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Lands")
end

local function landNumberFromFolder(landFolder: Instance): number?
	local n = string.match(landFolder.Name, "^Land(%d+)$")
	if not n then
		return nil
	end
	return tonumber(n)
end

local function alnumLower(name: string): string
	return string.gsub(string.lower(name), "[^a-z0-9]", "")
end

-- Essential gameplay / footing only. Models named Island/Ground are NOT kept whole.
local function shouldKeepChild(inst: Instance): boolean
	if inst:IsA("BaseScript") or inst:IsA("ModuleScript") then
		return true
	end

	local name = string.lower(inst.Name)
	local ak = alnumLower(inst.Name)

	if name == "spawn" or name == "spawnpart" or name == "landspawn" or ak == "spawn" then
		return true
	end
	if string.find(name, "hitbox", 1, true) or string.find(ak, "hitbox", 1, true) then
		return true
	end
	if string.find(ak, "comingsoon", 1, true) then
		return true
	end
	if string.find(ak, "safezone", 1, true) then
		return true
	end

	-- Only bare BaseParts used as walk surfaces — never Models/Folders with these names.
	if not inst:IsA("BasePart") then
		return false
	end

	if
		name == "ground"
		or name == "floor"
		or name == "terrain"
		or name == "baseplate"
		or name == "path"
		or name == "road"
		or name == "bridge"
		or name == "platform"
		or name == "collision"
		or name == "walkway"
		or ak == "ground"
		or ak == "floor"
		or ak == "baseplate"
		or ak == "collision"
	then
		return true
	end

	return false
end

local function isHeavyDecorName(name: string): boolean
	local ak = alnumLower(name)
	if HEAVY_EXACT[ak] then
		return true
	end
	if string.find(ak, "grass", 1, true) then
		return true
	end
	if string.find(ak, "bush", 1, true) then
		return true
	end
	if string.find(ak, "foliage", 1, true) or string.find(ak, "vegetation", 1, true) then
		return true
	end
	if string.find(ak, "tree", 1, true) and not string.find(ak, "street", 1, true) then
		return true
	end
	return false
end

local function shouldKeepLand(landNum: number, playerLand: number): boolean
	-- Unknown / safezone: park every land's decor so the whole map isn't drawn.
	if playerLand <= 0 then
		return false
	end
	return math.abs(landNum - playerLand) <= KEEP_RADIUS
end

local function parkEntry(entry: CullEntry)
	local cache = getCache()
	local inst = entry.inst
	if not inst.Parent then
		return
	end
	if inst.Parent == cache then
		return
	end
	entry.home = inst.Parent
	inst.Parent = cache
end

local function restoreEntry(entry: CullEntry)
	local inst = entry.inst
	local home = entry.home
	if not home or not home.Parent then
		return
	end
	if inst.Parent == home then
		return
	end
	inst.Parent = home
end

local function unregisterEntry(inst: Instance)
	entries[inst] = nil
end

local function queueShadowStrip(root: Instance)
	local stack: { Instance } = { root }
	local processed = 0
	while #stack > 0 do
		local node = table.remove(stack) :: Instance
		if node:IsA("BasePart") then
			local n = string.lower(node.Name)
			if string.find(n, "grass", 1, true) or n == "grasspart" then
				local part = node :: BasePart
				if not shadowDone[part] and not shadowQueued[part] then
					shadowQueued[part] = true
					table.insert(shadowQueue, part)
				end
			end
		end
		for _, child in node:GetChildren() do
			table.insert(stack, child)
		end
		processed += 1
		if processed % 400 == 0 then
			task.wait()
		end
	end
end

local function registerCullable(landNum: number, inst: Instance)
	if entries[inst] then
		return
	end
	if shouldKeepChild(inst) then
		return
	end
	local home = inst.Parent
	if not home then
		return
	end
	local cache = getCache()
	if home == cache then
		return
	end

	local entry: CullEntry = {
		inst = inst,
		home = home,
		land = landNum,
	}
	entries[inst] = entry

	inst.Destroying:Once(function()
		unregisterEntry(inst)
		if inst:IsA("BasePart") then
			shadowQueued[inst] = nil
			shadowDone[inst] = nil
		end
	end)

	if not shouldKeepLand(landNum, currentLand) then
		parkEntry(entry)
	elseif isHeavyDecorName(inst.Name) then
		task.defer(queueShadowStrip, inst)
	end
end

local function applyForPlayerLand(playerLand: number)
	currentLand = playerLand
	for _, entry in entries do
		if shouldKeepLand(entry.land, playerLand) then
			restoreEntry(entry)
			if isHeavyDecorName(entry.inst.Name) then
				task.defer(queueShadowStrip, entry.inst)
			end
		else
			parkEntry(entry)
		end
	end
end

local function hookLandFolder(landFolder: Instance, landNum: number)
	landFolders[landNum] = landFolder

	local existingConn = landChildConns[landNum]
	if existingConn then
		existingConn:Disconnect()
		landChildConns[landNum] = nil
	end

	for _, child in landFolder:GetChildren() do
		registerCullable(landNum, child)
	end

	landChildConns[landNum] = landFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			if child.Parent == landFolder then
				registerCullable(landNum, child)
			end
		end)
	end)
end

local function scanExistingLands()
	local lands = landsRoot()
	if not lands then
		return
	end
	for _, child in lands:GetChildren() do
		local landNum = landNumberFromFolder(child)
		if landNum then
			hookLandFolder(child, landNum)
		end
	end
end

local function playerLandNow(): number
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return 0
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
	if land < 1 then
		return 0
	end
	return land
end

local function pumpShadowStrip()
	local n = #shadowQueue
	if n == 0 then
		return
	end
	local budget = SHADOW_STRIP_PER_FRAME
	while budget > 0 and #shadowQueue > 0 do
		local part = table.remove(shadowQueue)
		if part then
			shadowQueued[part] = nil
			if part.Parent and not shadowDone[part] then
				shadowDone[part] = true
				part.CastShadow = false
				if part.CanCollide then
					part.CanCollide = false
				end
				if part.CanQuery then
					part.CanQuery = false
				end
				if part.CanTouch then
					part.CanTouch = false
				end
			end
		end
		budget -= 1
	end
end

local function onHeartbeat(dt: number)
	if not FEATURE_ENABLED then
		return
	end

	pumpShadowStrip()

	accum += dt
	forceAccum += dt
	if accum < POLL_SEC then
		return
	end
	accum = 0

	local land = playerLandNow()
	local force = forceAccum >= FORCE_APPLY_SEC
	if force then
		forceAccum = 0
	end
	if land ~= currentLand or force then
		applyForPlayerLand(land)
	end
end

local function onLandFolderAdded(landFolder: Instance)
	local landNum = landNumberFromFolder(landFolder)
	if not landNum then
		return
	end
	hookLandFolder(landFolder, landNum)
	applyForPlayerLand(currentLand)
end

function M.setEnabled(enabled: boolean)
	FEATURE_ENABLED = enabled
	if enabled then
		scanExistingLands()
		applyForPlayerLand(playerLandNow())
		return
	end
	for _, entry in entries do
		restoreEntry(entry)
	end
end

function M.init()
	if wired then
		return
	end
	wired = true

	if not FEATURE_ENABLED then
		return
	end

	task.spawn(function()
		local lands = landsRoot()
		local deadline = os.clock() + 30
		while not lands and os.clock() < deadline do
			task.wait(0.5)
			lands = landsRoot()
		end
		if not lands then
			warn("[GrassCullController] Map.Lands missing — land content cull skipped")
			return
		end

		getCache()
		scanExistingLands()
		-- Start parked until we know where the player is (avoids loading every land at join).
		applyForPlayerLand(0)
		task.wait(0.5)
		applyForPlayerLand(playerLandNow())

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

		player.CharacterAdded:Connect(function()
			task.defer(function()
				applyForPlayerLand(playerLandNow())
			end)
		end)
	end)
end

return M
