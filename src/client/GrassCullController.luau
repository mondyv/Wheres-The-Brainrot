-- [ACTIVE] GrassCullController
--[[
	Client-only grass streaming: keep Map.Lands/LandN/grass for the current land
	and immediate neighbors (±1). When a land is 2+ away, parent its grass folder
	into a local cache so it is not rendered / queried (not Destroy'd — restored
	when you move back in range).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

-- Keep current land and ±KEEP_RADIUS. Unload when abs(delta) > KEEP_RADIUS
-- ("2 lands away" => unload at distance >= 2).
local KEEP_RADIUS = 1
local POLL_SEC = 0.45
local FEATURE_ENABLED = true

local player = Players.LocalPlayer
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsChildConn: RBXScriptConnection? = nil
local landsDescConn: RBXScriptConnection? = nil
local accum = 0.0
local currentLand = 0

-- grass folder -> original parent under its Land
local grassHome: { [Instance]: Instance } = {}
-- land number -> grass folder (live or parked)
local grassByLand: { [number]: Instance } = {}

local cacheFolder: Folder? = nil

local function getCache(): Folder
	local existing = cacheFolder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "GrassCullCache"
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

local function findGrassFolder(landFolder: Instance): Instance?
	return landFolder:FindFirstChild("grass") or landFolder:FindFirstChild("Grass")
end

local function registerGrass(landNum: number, grass: Instance)
	if grassByLand[landNum] == grass then
		return
	end
	grassByLand[landNum] = grass
	if grass.Parent and grass.Parent ~= getCache() then
		grassHome[grass] = grass.Parent
	end
	grass.Destroying:Once(function()
		if grassByLand[landNum] == grass then
			grassByLand[landNum] = nil
		end
		grassHome[grass] = nil
	end)
end

local function parkGrass(grass: Instance)
	local cache = getCache()
	if grass.Parent == cache then
		return
	end
	if grass.Parent then
		grassHome[grass] = grass.Parent
	end
	grass.Parent = cache
end

local function restoreGrass(grass: Instance)
	local home = grassHome[grass]
	if not home or not home.Parent then
		return
	end
	if grass.Parent == home then
		return
	end
	grass.Parent = home
end

local function shouldKeepLand(landNum: number, playerLand: number): boolean
	if playerLand <= 0 then
		return true
	end
	return math.abs(landNum - playerLand) <= KEEP_RADIUS
end

local function applyForPlayerLand(playerLand: number)
	if playerLand <= 0 then
		return
	end
	for landNum, grass in grassByLand do
		if not grass.Parent and grass ~= getCache() then
			continue
		end
		if shouldKeepLand(landNum, playerLand) then
			restoreGrass(grass)
		else
			parkGrass(grass)
		end
	end
end

local function scanExistingLands()
	local lands = landsRoot()
	if not lands then
		return
	end
	for _, child in lands:GetChildren() do
		local landNum = landNumberFromFolder(child)
		if not landNum then
			continue
		end
		local grass = findGrassFolder(child)
		if grass then
			registerGrass(landNum, grass)
		end
	end
end

local function playerLandNow(): number
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return currentLand
	end
	return math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
end

local function onHeartbeat(dt: number)
	if not FEATURE_ENABLED then
		return
	end
	accum += dt
	if accum < POLL_SEC then
		return
	end
	accum = 0

	local land = playerLandNow()
	if land ~= currentLand then
		currentLand = land
		applyForPlayerLand(currentLand)
	end
end

local function onLandsDescendantAdded(inst: Instance)
	if not FEATURE_ENABLED then
		return
	end
	-- Grass folder itself appeared under a land.
	if inst.Name == "grass" or inst.Name == "Grass" then
		local landFolder = inst.Parent
		if not landFolder then
			return
		end
		local landNum = landNumberFromFolder(landFolder)
		if not landNum then
			return
		end
		registerGrass(landNum, inst)
		if currentLand > 0 and not shouldKeepLand(landNum, currentLand) then
			parkGrass(inst)
		end
		return
	end
end

local function onLandFolderAdded(landFolder: Instance)
	local landNum = landNumberFromFolder(landFolder)
	if not landNum then
		return
	end
	local grass = findGrassFolder(landFolder)
	if grass then
		registerGrass(landNum, grass)
		if currentLand > 0 and not shouldKeepLand(landNum, currentLand) then
			parkGrass(grass)
		end
	else
		task.defer(function()
			local late = findGrassFolder(landFolder)
			if late then
				registerGrass(landNum, late)
				if currentLand > 0 and not shouldKeepLand(landNum, currentLand) then
					parkGrass(late)
				end
			end
		end)
	end
end

function M.setEnabled(enabled: boolean)
	FEATURE_ENABLED = enabled
	if enabled then
		scanExistingLands()
		currentLand = playerLandNow()
		applyForPlayerLand(currentLand)
		return
	end
	-- Restore everything.
	for _, grass in grassByLand do
		restoreGrass(grass)
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
			warn("[GrassCullController] Map.Lands missing — grass distance cull skipped")
			return
		end

		getCache()
		scanExistingLands()
		currentLand = playerLandNow()
		applyForPlayerLand(currentLand)

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
		landsDescConn = lands.DescendantAdded:Connect(onLandsDescendantAdded)
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

return M
