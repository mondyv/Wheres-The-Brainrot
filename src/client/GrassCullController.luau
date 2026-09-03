-- [ACTIVE] GrassCullController
--[[
	Client-only land content cull (kept name for init wiring).

	Default: park non-essential LandN children when 2+ lands away (keep ±1).
	Low Graphics: keep current land only, and also park grass/trees/rocks/decor
	on that land (bushes stay). Never Destroy — restore when range/settings change.

	Never restore parked grass/props until that land's walk mesh (Island/ground)
	is present. Force-restoring from the local cache before the island streams
	in is what spawned high-tri decor with no land mass underneath.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

-- Keep current land and ±keepRadius. Unload when abs(delta) > keepRadius.
local DEFAULT_KEEP_RADIUS = 1
local SWING_KEEP_RADIUS = 2
local keepRadius = DEFAULT_KEEP_RADIUS
local lowGraphics = false
local POLL_SEC = 0.45
-- Studio play-solo already has the whole place in-process; park immediately.
local START_DELAY_SEC = if RunService:IsStudio() then 0.4 else 4
local FEATURE_ENABLED = true
-- Reparent budget: restore terrain/island first (see restorePriority), a few per frame.
local REPARENT_PER_YIELD = if RunService:IsStudio() then 10 else 3
local REPARENT_PER_YIELD_SWING = 10
local FAST_MOVE_SPEED = 36
local STREAM_AHEAD_STUDS = 180
local STREAM_FAR_STUDS = 320
local lastStreamAt = 0.0
local STREAM_COOLDOWN = 0.35
local GAMEPLAY_STREAM_TARGET = 280
local MOBILE_STREAM_TARGET = 200
local STUDIO_STREAM_TARGET = 180
local SWING_STREAM_TARGET = 420
local STUDIO_SWING_STREAM_TARGET = 240
local swingStreamBoosted = false
local wasFastTraveling = false

local player = Players.LocalPlayer
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsChildConn: RBXScriptConnection? = nil
local accum = 0.0
local currentLand = 0
local cullActive = false
local applyToken = 0
local applyRunning = false
local applyQueuedLand: number? = nil
local lastChildAddedApplyAt = 0.0
local CHILD_ADDED_APPLY_DEBOUNCE = 0.55

type CullEntry = {
	inst: Instance,
	home: Instance,
	land: number,
}

local entries: { [Instance]: CullEntry } = {}
local landFolders: { [number]: Instance } = {}
local landChildConns: { [number]: RBXScriptConnection } = {}

local cacheFolder: Folder? = nil

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

local function shouldKeepChild(inst: Instance): boolean
	if inst:IsA("BaseScript") or inst:IsA("ModuleScript") then
		return true
	end

	local name = string.lower(inst.Name)

	if name == "spawn" or name == "spawnpart" or name == "landspawn" then
		return true
	end
	if string.find(name, "hitbox", 1, true) then
		return true
	end
	if string.find(name, "comingsoon", 1, true) then
		return true
	end
	if string.find(name, "safezone", 1, true) then
		return true
	end

	-- Keep walk mesh models resident so bushes never pop in before the land.
	local ak = alnumLower(inst.Name)
	if
		ak == "island"
		or ak == "ground"
		or ak == "terrain"
		or ak == "floor"
		or ak == "baseplate"
		or ak == "landmesh"
		or ak == "land"
	then
		return true
	end

	-- Walk surfaces: BaseParts only for everything else.
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
	then
		return true
	end

	return false
end

-- Heavy decor safe to hide even on the current land in Low Graphics (never bushes).
local function isLowGfxDecorName(name: string): boolean
	local ak = alnumLower(name)
	if ak == "" then
		return false
	end
	if string.find(ak, "bush", 1, true) then
		return false
	end
	if ak == "grass" or string.find(ak, "grass", 1, true) then
		return true
	end
	if ak == "trees" or ak == "tree" or ak == "rocks" or ak == "rock" then
		return true
	end
	if
		ak == "decor"
		or ak == "decoration"
		or ak == "decorations"
		or ak == "foliage"
		or ak == "vegetation"
		or ak == "plants"
		or ak == "plant"
		or ak == "leaves"
		or ak == "flowers"
		or ak == "clutter"
		or ak == "scenery"
		or ak == "props"
	then
		return true
	end
	return false
end

local function restorePriority(entry: CullEntry): number
	local ak = alnumLower(entry.inst.Name)
	if
		ak == "island"
		or ak == "ground"
		or ak == "terrain"
		or ak == "floor"
		or ak == "baseplate"
		or ak == "landmesh"
		or ak == "land"
		or string.find(ak, "hitbox", 1, true)
	then
		return 0
	end
	if string.find(ak, "bush", 1, true) then
		return 2
	end
	return 1
end

local function isFastTraveling(): boolean
	if player:GetAttribute("IsSwinging") == true then
		return true
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	local v = (hrp :: BasePart).AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude >= FAST_MOVE_SPEED
end

-- Safezone sits next to Land 1. Treating land 0 as "keep everything" meant the first
-- walk toward Land 1 parked Lands 3–10 in one hitch (CPU spike, triangles barely move).
local function cullLandIndex(playerLand: number): number
	if playerLand <= 0 then
		return 1
	end
	return playerLand
end

local function shouldKeepLand(landNum: number, playerLand: number): boolean
	playerLand = cullLandIndex(playerLand)
	local radius = keepRadius
	-- While swinging / fast travel, keep one extra land ahead so tops aren't parked.
	if not lowGraphics and isFastTraveling() then
		radius = math.max(radius, SWING_KEEP_RADIUS)
	end
	return math.abs(landNum - playerLand) <= radius
end

local function shouldParkEntry(entry: CullEntry, playerLand: number): boolean
	if not shouldKeepLand(entry.land, playerLand) then
		return true
	end
	-- Low Graphics: also dump grass/trees/rocks on the land you're standing on.
	if lowGraphics and isLowGfxDecorName(entry.inst.Name) then
		return true
	end
	return false
end

local function landFolderHasWalkMesh(landNum: number): boolean
	local folder = landFolders[landNum]
	if not folder or not folder.Parent then
		return false
	end
	for _, child in folder:GetChildren() do
		if not shouldKeepChild(child) then
			continue
		end
		local n = string.lower(child.Name)
		if
			n == "spawn"
			or n == "spawnpart"
			or n == "landspawn"
			or string.find(n, "comingsoon", 1, true)
			or string.find(n, "safezone", 1, true)
			or string.find(n, "hitbox", 1, true)
			or child:IsA("BaseScript")
			or child:IsA("ModuleScript")
		then
			continue
		end
		return true
	end
	return false
end

local function parkEntry(entry: CullEntry)
	if not cullActive then
		return
	end
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
	-- Do not force grass/props into Workspace while the land mesh is still out.
	if not landFolderHasWalkMesh(entry.land) then
		return
	end
	inst.Parent = home
end

local function unregisterEntry(inst: Instance)
	entries[inst] = nil
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
	end)

	if cullActive and currentLand > 0 and shouldParkEntry(entry, currentLand) then
		parkEntry(entry)
	end
end

local function applyForPlayerLand(playerLand: number)
	playerLand = cullLandIndex(playerLand)
	if not cullActive then
		return
	end
	applyToken += 1
	currentLand = playerLand

	-- Park first (cheap: leaving view), then restore slowly (entering view = hitch source).
	local toPark: { CullEntry } = {}
	local toRestore: { CullEntry } = {}
	for _, entry in entries do
		if shouldParkEntry(entry, playerLand) then
			table.insert(toPark, entry)
		else
			table.insert(toRestore, entry)
		end
	end

	local n = 0
	local parkBudget = if isFastTraveling() then REPARENT_PER_YIELD_SWING else REPARENT_PER_YIELD
	if UserInputService.TouchEnabled then
		parkBudget = math.min(parkBudget, 2)
	end
	for _, entry in toPark do
		parkEntry(entry)
		n += 1
		if n % parkBudget == 0 then
			RunService.Heartbeat:Wait()
		end
	end

	table.sort(toRestore, function(a, b)
		local pa = restorePriority(a)
		local pb = restorePriority(b)
		if pa ~= pb then
			return pa < pb
		end
		return a.land < b.land
	end)

	n = 0
	local restoreBudget = if isFastTraveling() then REPARENT_PER_YIELD_SWING else REPARENT_PER_YIELD
	if UserInputService.TouchEnabled then
		restoreBudget = math.min(restoreBudget, 2)
	end
	for _, entry in toRestore do
		restoreEntry(entry)
		n += 1
		if n % restoreBudget == 0 then
			RunService.Heartbeat:Wait()
		end
	end
end

-- One in-flight pass; extra requests coalesce so stream-in ChildAdded can't restart reparenting.
local function requestApplyForPlayerLand(playerLand: number)
	applyQueuedLand = cullLandIndex(playerLand)
	if applyRunning then
		return
	end
	applyRunning = true
	task.spawn(function()
		while applyQueuedLand do
			local land = applyQueuedLand
			applyQueuedLand = nil
			applyForPlayerLand(land)
		end
		applyRunning = false
	end)
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
		-- One level deep: grass folders parented under Island/etc.
		if not shouldKeepChild(child) then
			for _, nested in child:GetChildren() do
				if isLowGfxDecorName(nested.Name) then
					registerCullable(landNum, nested)
				end
			end
		end
	end

	landChildConns[landNum] = landFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			if child.Parent ~= landFolder then
				return
			end
			registerCullable(landNum, child)
			if not shouldKeepChild(child) then
				for _, nested in child:GetChildren() do
					if isLowGfxDecorName(nested.Name) then
						registerCullable(landNum, nested)
					end
				end
			elseif cullActive and currentLand > 0 then
				-- Coalesce: every streamed island/mesh used to restart a full reparent pass.
				local now = os.clock()
				if now - lastChildAddedApplyAt >= CHILD_ADDED_APPLY_DEBOUNCE then
					lastChildAddedApplyAt = now
					requestApplyForPlayerLand(currentLand)
				end
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
		return currentLand
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
	if land < 1 then
		return currentLand
	end
	return land
end

local function gameplayStreamRadius(): number
	if RunService:IsStudio() then
		return STUDIO_STREAM_TARGET
	end
	if UserInputService.TouchEnabled then
		return MOBILE_STREAM_TARGET
	end
	return GAMEPLAY_STREAM_TARGET
end

local function setSwingStreamBoost(on: boolean)
	if swingStreamBoosted == on then
		return
	end
	swingStreamBoosted = on
	pcall(function()
		local wsAny = Workspace :: any
		if on then
			wsAny.StreamingTargetRadius = if RunService:IsStudio() then STUDIO_SWING_STREAM_TARGET else SWING_STREAM_TARGET
		else
			wsAny.StreamingTargetRadius = gameplayStreamRadius()
		end
	end)
end

-- Soft-prewarm: request Roblox streaming ahead along swing velocity.
-- Never force-restore cached grass/props before the island mesh streams in.
local function softPrewarmAhead()
	if not Workspace.StreamingEnabled then
		return
	end
	-- Extra RequestStreamAroundAsync hitch phones; let the default streamer catch up.
	if UserInputService.TouchEnabled then
		if isFastTraveling() then
			setSwingStreamBoost(true)
		else
			setSwingStreamBoost(false)
		end
		return
	end
	if not isFastTraveling() then
		setSwingStreamBoost(false)
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local vel = (hrp :: BasePart).AssemblyLinearVelocity
	local horiz = Vector3.new(vel.X, 0, vel.Z)
	local look = Vector3.new((hrp :: BasePart).CFrame.LookVector.X, 0, (hrp :: BasePart).CFrame.LookVector.Z)
	local dir: Vector3
	if horiz.Magnitude >= FAST_MOVE_SPEED * 0.35 then
		dir = horiz.Unit
	elseif look.Magnitude > 0.05 then
		dir = look.Unit
	else
		return
	end

	setSwingStreamBoost(true)

	local now = os.clock()
	if now - lastStreamAt < STREAM_COOLDOWN then
		return
	end
	lastStreamAt = now

	local origin = (hrp :: BasePart).Position
	local near = origin + dir * STREAM_AHEAD_STUDS
	local far = origin + dir * STREAM_FAR_STUDS
	task.spawn(function()
		local ok1, err1 = pcall(function()
			player:RequestStreamAroundAsync(near, 4)
		end)
		if not ok1 then
			warn("[GrassCullController] RequestStreamAroundAsync failed:", err1)
		end
		local ok2, err2 = pcall(function()
			player:RequestStreamAroundAsync(far, 4)
		end)
		if not ok2 then
			warn("[GrassCullController] RequestStreamAroundAsync far failed:", err2)
		end
	end)
end

local function onHeartbeat(dt: number)
	if not FEATURE_ENABLED or not cullActive then
		return
	end
	accum += dt
	if accum < POLL_SEC then
		-- Between polls, trickle prewarm while swinging so boundary hits stay light.
		if isFastTraveling() then
			softPrewarmAhead()
		else
			setSwingStreamBoost(false)
		end
		return
	end
	accum = 0

	local land = playerLandNow()
	local fast = isFastTraveling()
	if land ~= currentLand and land > 0 then
		requestApplyForPlayerLand( land)
	elseif fast then
		softPrewarmAhead()
		-- Expand keep radius once when swing starts so next land tops stay resident.
		if not wasFastTraveling and (land > 0 or currentLand > 0) then
			requestApplyForPlayerLand( land > 0 and land or currentLand)
		end
	elseif wasFastTraveling then
		setSwingStreamBoost(false)
		if land > 0 or currentLand > 0 then
			requestApplyForPlayerLand( land > 0 and land or currentLand)
		end
	end
	wasFastTraveling = fast
end

local function onLandFolderAdded(landFolder: Instance)
	local landNum = landNumberFromFolder(landFolder)
	if not landNum then
		return
	end
	hookLandFolder(landFolder, landNum)
	if cullActive and currentLand > 0 then
		task.defer(function()
			requestApplyForPlayerLand( currentLand)
		end)
	end
end

function M.setEnabled(enabled: boolean)
	FEATURE_ENABLED = enabled
	if enabled then
		scanExistingLands()
		if cullActive then
			requestApplyForPlayerLand( playerLandNow())
		end
		return
	end
	for _, entry in entries do
		restoreEntry(entry)
	end
end

-- Low Graphics: current land only + hide grass/trees/rocks on that land too.
function M.setLowGraphics(enabled: boolean)
	local nextOn = enabled == true
	if lowGraphics == nextOn then
		return
	end
	lowGraphics = nextOn
	keepRadius = if nextOn then 0 else DEFAULT_KEEP_RADIUS
	if cullActive then
		local land = playerLandNow()
		if land > 0 then
			task.defer(function()
				requestApplyForPlayerLand( land)
			end)
		end
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

	if RunService:IsStudio() then
		lowGraphics = true
		keepRadius = 0
	end

	task.spawn(function()
		-- Never reparent map content during loading / first frames.
		task.wait(START_DELAY_SEC)

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

		local land = playerLandNow()
		if land <= 0 then
			local charDeadline = os.clock() + 15
			while land <= 0 and os.clock() < charDeadline do
				task.wait(0.5)
				land = playerLandNow()
			end
		end

		cullActive = true
		pcall(function()
			(Workspace :: any).StreamingTargetRadius = gameplayStreamRadius()
		end)
		-- Park far lands while still at base so walking into Land 1 isn't a mass reparent.
		requestApplyForPlayerLand(if land > 0 then land else 1)

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

return M
