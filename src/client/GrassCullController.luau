-- [ACTIVE] GrassCullController
--[[
	Client-only land content cull (kept name for init wiring).

	Island / ground stay in Workspace so you can see far platforms.
	Grass / trees / rocks stay on the current land plus two ahead (and one behind).
	While swinging, keep the predicted destination too and trickle-restore so
	trees are not empty boxes in the air.

	From the safezone this treats you as Land 1 and streams Land 1–3 so the
	second island is not an empty box. Respawn streams those lands again.

	Studio play-solo skips this entirely (full place is already in RAM).
	Grass park/restore is gated by StreamingSettings.CUSTOM_CULL_ENABLED (off).
	Look-ahead streaming still runs so swinging is not empty air.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local StreamingSettings = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StreamingSettings"))

local M = {}

local lowGraphics = false
local KEEP_BEHIND = 1
local KEEP_AHEAD = 2
local SWING_KEEP_AHEAD = 3
local LOW_GFX_KEEP_AHEAD = 1
local POLL_SEC = 0.45
-- Studio play-solo already has the whole place in-process; park immediately.
local START_DELAY_SEC = if RunService:IsStudio() then 0.4 else 2
local FEATURE_ENABLED = StreamingSettings.isCustomEnabled()
local REPARENT_PER_YIELD = 2
local SWING_REPARENT_PER_YIELD = 1
local FAST_MOVE_SPEED = 36
local LOOKAHEAD_DIST = 260
local LOOKAHEAD_COOLDOWN = 0.35
local LOOKAHEAD_TIMEOUT = 0.55
local START_STREAM_MAX_LAND = 3

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
local wasFastTraveling = false
local startStreamAt = 0.0
local streamBusy = false
local startStreamLand = 1
local START_STREAM_COOLDOWN = 1.4
local lastLookaheadAt = 0.0
local lookAheadSide = 1
local lastPredLand = 0
local charAddedConn: RBXScriptConnection? = nil

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
		or ak == "cliff"
		or ak == "cliffs"
		or ak == "side"
		or ak == "sides"
		or ak == "wall"
		or ak == "walls"
		or ak == "rim"
		or ak == "dirt"
		or ak == "soil"
		or ak == "rockface"
		or ak == "underside"
		or string.find(ak, "cliff", 1, true)
		or string.find(ak, "landside", 1, true)
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

local function predictedLandFromHrp(): number
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return if currentLand > 0 then currentLand else 1
	end
	local here = 1
	if SafezoneUtil.isCharacterInSafezone(char) then
		here = 1
	else
		here = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
		if here < 1 then
			here = if currentLand > 0 then currentLand else 1
		end
	end
	if not isFastTraveling() then
		return here
	end
	local vel = (hrp :: BasePart).AssemblyLinearVelocity
	local horiz = Vector3.new(vel.X, 0, vel.Z)
	local dir: Vector3
	if horiz.Magnitude >= 12 then
		dir = horiz.Unit
	else
		local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		if look.Magnitude < 0.05 then
			return here
		end
		dir = look.Unit
	end
	local best = here
	for _, dist in { 90, LOOKAHEAD_DIST, 280 } do
		local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position + dir * dist))
		if land > best then
			best = land
		end
	end
	return best
end

-- Safezone sits next to Land 1. Treating land 0 as "keep everything" meant the first
-- walk toward Land 1 parked Lands 3–10 in one hitch (CPU spike, triangles barely move).
local function cullLandIndex(playerLand: number): number
	if playerLand <= 0 then
		return 1
	end
	return playerLand
end

local function shouldParkEntry(entry: CullEntry, playerLand: number): boolean
	playerLand = cullLandIndex(playerLand)
	local behind = KEEP_BEHIND
	local ahead = KEEP_AHEAD
	if lowGraphics then
		behind = 0
		ahead = LOW_GFX_KEEP_AHEAD
	end
	local lo = playerLand - behind
	local hi = playerLand + ahead
	if isFastTraveling() then
		local pred = predictedLandFromHrp()
		hi = math.max(hi, pred + 1, playerLand + SWING_KEEP_AHEAD)
	end
	if entry.land < lo or entry.land > hi then
		return true
	end
	-- Low Graphics: hide grass/trees/rocks even on the land you're standing on.
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
	local parkBudget = if UserInputService.TouchEnabled then 4 else 8
	for _, entry in toPark do
		parkEntry(entry)
		n += 1
		if n % parkBudget == 0 then
			RunService.Heartbeat:Wait()
		end
	end

	-- Trickle restore even while swinging — skipping it left empty trees until you landed.
	-- One folder per frame in the air so a whole Grass dump cannot freeze the client.
	local restoreBudget = if isFastTraveling() then SWING_REPARENT_PER_YIELD else REPARENT_PER_YIELD

	table.sort(toRestore, function(a, b)
		local pa = restorePriority(a)
		local pb = restorePriority(b)
		if pa ~= pb then
			return pa < pb
		end
		return a.land < b.land
	end)

	n = 0
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
	end

	landChildConns[landNum] = landFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			if child.Parent ~= landFolder then
				return
			end
			registerCullable(landNum, child)
			if shouldKeepChild(child) and cullActive and currentLand > 0 then
				-- Coalesce: a new island mesh should not dump every parked prop in one frame.
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
	-- From the base you should see Land 1 + two ahead, not an empty second island.
	if SafezoneUtil.isCharacterInSafezone(char) then
		return 1
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
	if land < 1 then
		return if currentLand > 0 then currentLand else 1
	end
	return land
end

-- Standing in safezone / land 1, pull Land 1–3 so the second island is not a blank box.
local function requestStreamAt(focus: Vector3, timeoutSec: number)
	if not Workspace.StreamingEnabled then
		return
	end
	if streamBusy then
		return
	end
	streamBusy = true
	task.spawn(function()
		local ok, err = pcall(function()
			player:RequestStreamAroundAsync(focus, timeoutSec)
		end)
		if not ok then
			warn("[GrassCullController] RequestStreamAroundAsync failed:", err)
		end
		streamBusy = false
	end)
end

local function prewarmStartLands()
	if not Workspace.StreamingEnabled then
		return
	end
	if isFastTraveling() then
		return
	end
	local land = if currentLand > 0 then currentLand else playerLandNow()
	if land > 2 then
		return
	end
	local now = os.clock()
	if streamBusy or now - startStreamAt < START_STREAM_COOLDOWN then
		return
	end
	local want = math.clamp(startStreamLand, 1, START_STREAM_MAX_LAND)
	startStreamLand = want % START_STREAM_MAX_LAND + 1
	local focus = LandResolver.getLandCenter(want)
	if not focus then
		return
	end
	startStreamAt = now
	requestStreamAt(focus, 2)
end

local function softPrewarmAlongVelocity()
	if not Workspace.StreamingEnabled then
		return
	end
	if not isFastTraveling() then
		return
	end
	local now = os.clock()
	if streamBusy or now - lastLookaheadAt < LOOKAHEAD_COOLDOWN then
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local vel = (hrp :: BasePart).AssemblyLinearVelocity
	local horiz = Vector3.new(vel.X, 0, vel.Z)
	if horiz.Magnitude < 12 then
		return
	end
	local focus = hrp.Position
		+ horiz.Unit * LOOKAHEAD_DIST
		+ hrp.CFrame.RightVector * (55 * lookAheadSide)
		+ Vector3.new(0, math.clamp(vel.Y, -20, 40), 0)
	lookAheadSide *= -1
	lastLookaheadAt = now
	requestStreamAt(focus, LOOKAHEAD_TIMEOUT)
end

local function onHeartbeat(dt: number)
	-- Look-ahead always runs (even with cull off) so fast swings are not empty.
	if isFastTraveling() then
		softPrewarmAlongVelocity()
	end
	accum += dt
	if accum < POLL_SEC then
		return
	end
	accum = 0

	prewarmStartLands()
	if not FEATURE_ENABLED or not cullActive then
		return
	end
	local land = playerLandNow()
	local fast = isFastTraveling()
	local pred = if fast then predictedLandFromHrp() else land
	if land ~= currentLand and land > 0 then
		requestApplyForPlayerLand(land)
		lastPredLand = pred
	elseif pred ~= lastPredLand and pred > 0 then
		requestApplyForPlayerLand(land > 0 and land or pred)
		lastPredLand = pred
	elseif wasFastTraveling and not fast then
		if land > 0 or currentLand > 0 then
			requestApplyForPlayerLand(land > 0 and land or currentLand)
		end
		lastPredLand = pred
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

	-- Studio play-solo holds the entire place in RAM already. Reparenting every
	-- land's grass 0.4s after spawn freezes the character and does not drop 9GB.
	if RunService:IsStudio() then
		return
	end

	pcall(function()
		StreamingSettings.apply(Workspace)
	end)

	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

	-- From spawn / respawn, start pulling Land 1–3 immediately.
	task.spawn(function()
		for _ = 1, 8 do
			if not player.Parent then
				return
			end
			prewarmStartLands()
			task.wait(1.2)
		end
	end)

	if not FEATURE_ENABLED then
		return
	end

	charAddedConn = player.CharacterAdded:Connect(function()
		task.defer(function()
			if not cullActive then
				return
			end
			-- Server PlotSpawnUtil already streams the pad + Land 1–3.
			-- Re-apply here so parked trees come back after the new character exists.
			requestApplyForPlayerLand(playerLandNow())
		end)
	end)

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
			StreamingSettings.apply(Workspace)
		end)
		-- Park far lands while still at base so walking into Land 1 isn't a mass reparent.
		requestApplyForPlayerLand(if land > 0 then land else 1)

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
	end)
end

return M
