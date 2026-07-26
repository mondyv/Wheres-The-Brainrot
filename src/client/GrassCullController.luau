-- [ACTIVE] GrassCullController
--[[
	Dense LandN/grass/grasspart meshes are the main FPS suspect (Land 9 is fine =
	sparse; other lands choke on thousands of nearby MeshParts).

	Culls distant grassparts on the player's current land via LocalTransparencyModifier,
	and strips CastShadow / collision once so the GPU isn't shading every blade.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

local VISIBLE_RANGE = 55
local VISIBLE_RANGE_SQ = VISIBLE_RANGE * VISIBLE_RANGE
local SCAN_INTERVAL = 0.45
local REBUILD_INTERVAL = 4.0
local OPTIMIZE_PER_FRAME = 80

local player = Players.LocalPlayer
local grassParts: { BasePart } = {}
local hidden: { [BasePart]: boolean } = {}
local optimized: { [BasePart]: boolean } = {}
local currentLand = 0
local scanAccum = 0.0
local rebuildAccum = 0.0
local optimizeCursor = 1
local heartbeatConn: RBXScriptConnection? = nil

local function landFolderFor(land: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return nil
	end
	local named = lands:FindFirstChild("Land" .. tostring(land))
	if named then
		return named
	end
	return nil
end

local function collectGrassParts(landFolder: Instance): { BasePart }
	local out: { BasePart } = {}
	local grassFolder = landFolder:FindFirstChild("grass")
	if not grassFolder then
		return out
	end
	-- Stack walk — never GetDescendants on huge grass trees.
	local stack: { Instance } = { grassFolder }
	while #stack > 0 do
		local inst = table.remove(stack) :: Instance
		if inst:IsA("BasePart") and string.lower(inst.Name) == "grasspart" then
			table.insert(out, inst)
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
	end
	return out
end

local function optimizePart(part: BasePart)
	if optimized[part] then
		return
	end
	optimized[part] = true
	part.CastShadow = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Anchored = true
end

local function rebuildForLand(land: number)
	currentLand = land
	table.clear(grassParts)
	table.clear(hidden)
	-- Keep optimized map — parts keep their one-time flags.
	local folder = landFolderFor(land)
	if not folder then
		return
	end
	grassParts = collectGrassParts(folder)
end

local function playerPos(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function onHeartbeat(dt: number)
	scanAccum += dt
	rebuildAccum += dt

	local origin = playerPos()
	if not origin then
		return
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(origin))

	if land ~= currentLand or rebuildAccum >= REBUILD_INTERVAL then
		rebuildAccum = 0
		optimizeCursor = 1
		rebuildForLand(land)
	end

	local n = #grassParts
	-- Spread CastShadow stripping so first visit to a dense land doesn't hitch.
	if n > 0 then
		local endIdx = math.min(n, optimizeCursor + OPTIMIZE_PER_FRAME - 1)
		for i = optimizeCursor, endIdx do
			local part = grassParts[i]
			if part and part.Parent then
				optimizePart(part)
			end
		end
		optimizeCursor = endIdx + 1
		if optimizeCursor > n then
			optimizeCursor = n + 1 -- done for this rebuild
		end
	end

	if scanAccum < SCAN_INTERVAL then
		return
	end
	scanAccum = 0

	if n == 0 then
		return
	end

	for _, part in grassParts do
		if not part.Parent then
			continue
		end
		local delta = part.Position - origin
		local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
		local shouldHide = distSq > VISIBLE_RANGE_SQ
		if hidden[part] ~= shouldHide then
			hidden[part] = shouldHide
			part.LocalTransparencyModifier = if shouldHide then 1 else 0
		end
	end
end

function M.init()
	if heartbeatConn then
		return
	end
	-- Let map stream in before first cull pass.
	task.spawn(function()
		task.wait(2.5)
		local origin = playerPos()
		if origin then
			rebuildForLand(math.floor(LandResolver.resolveLandAtPosition(origin)))
		end
	end)
	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
end

return M
