-- [ACTIVE] GrassCullController
--[[
	Client-only land content cull (kept name for init wiring).

	For Map.Lands/LandN when the land is 2+ away from the player:
	  - Park (reparent into a local cache) every direct child that is NOT essential.
	  - Restore when the player is within ±1 land again.
	Nothing is Destroy'd — safe to bring back.

	Always kept on far lands:
	  Spawn / hitboxes / ComingSoon / walk-surface BaseParts / scripts

	IMPORTANT: only bare BaseParts named Ground/Floor/etc. are kept — never whole
	Models named Island (those used to keep thousands of nested grassparts loaded).
	Cull starts after a short delay so join/loading is never blocked by reparents.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

-- Keep current land and ±KEEP_RADIUS. Unload when abs(delta) > KEEP_RADIUS.
local KEEP_RADIUS = 1
local POLL_SEC = 0.45
local START_DELAY_SEC = 4
local FEATURE_ENABLED = true

local player = Players.LocalPlayer
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsChildConn: RBXScriptConnection? = nil
local accum = 0.0
local currentLand = 0
local cullActive = false

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

	-- Walk surfaces: BaseParts only. Models named Island/Ground must NOT stay whole.
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

local function shouldKeepLand(landNum: number, playerLand: number): boolean
	if playerLand <= 0 then
		-- Don't touch anything until we know where the player is (avoids mass reparent on join).
		return true
	end
	return math.abs(landNum - playerLand) <= KEEP_RADIUS
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

	if cullActive and currentLand > 0 and not shouldKeepLand(landNum, currentLand) then
		parkEntry(entry)
	end
end

local function applyForPlayerLand(playerLand: number)
	if not cullActive or playerLand <= 0 then
		return
	end
	currentLand = playerLand
	local parked = 0
	for _, entry in entries do
		if shouldKeepLand(entry.land, playerLand) then
			restoreEntry(entry)
		else
			parkEntry(entry)
			parked += 1
			-- Spread massive reparents across frames so join never freezes black.
			if parked % 3 == 0 then
				task.wait()
			end
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
		return currentLand
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
	if land < 1 then
		return currentLand
	end
	return land
end

local function onHeartbeat(dt: number)
	if not FEATURE_ENABLED or not cullActive then
		return
	end
	accum += dt
	if accum < POLL_SEC then
		return
	end
	accum = 0

	local land = playerLandNow()
	if land ~= currentLand and land > 0 then
		applyForPlayerLand(land)
	end
end

local function onLandFolderAdded(landFolder: Instance)
	local landNum = landNumberFromFolder(landFolder)
	if not landNum then
		return
	end
	hookLandFolder(landFolder, landNum)
	if cullActive and currentLand > 0 then
		task.defer(applyForPlayerLand, currentLand)
	end
end

function M.setEnabled(enabled: boolean)
	FEATURE_ENABLED = enabled
	if enabled then
		scanExistingLands()
		if cullActive then
			applyForPlayerLand(playerLandNow())
		end
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
		if land > 0 then
			applyForPlayerLand(land)
		end

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

return M
