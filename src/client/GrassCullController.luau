-- [ACTIVE] GrassCullController
--[[
	One-time CastShadow / collision strip for grassparts on the current land.
	Does NOT toggle LocalTransparency (that hitch'd FPS without freeing the ~2GB
	mesh RAM — only reducing grass MeshPart count in Studio drops memory).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

local OPTIMIZE_PER_FRAME = 60
local REBUILD_INTERVAL = 6.0

local player = Players.LocalPlayer
local pending: { BasePart } = {}
local optimizedLand: { [number]: boolean } = {}
local currentLand = 0
local rebuildAccum = 0.0
local heartbeatConn: RBXScriptConnection? = nil

local function landFolderFor(land: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return nil
	end
	return lands:FindFirstChild("Land" .. tostring(land))
end

local function collectGrassParts(landFolder: Instance): { BasePart }
	local out: { BasePart } = {}
	local grassFolder = landFolder:FindFirstChild("grass")
	if not grassFolder then
		return out
	end
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
	part.CastShadow = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
end

local function queueLandOptimize(land: number)
	if optimizedLand[land] then
		return
	end
	optimizedLand[land] = true
	table.clear(pending)
	local folder = landFolderFor(land)
	if not folder then
		return
	end
	pending = collectGrassParts(folder)
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
	rebuildAccum += dt

	if #pending > 0 then
		local n = math.min(#pending, OPTIMIZE_PER_FRAME)
		for _ = 1, n do
			local part = table.remove(pending)
			if part and part.Parent then
				optimizePart(part)
			end
		end
		return
	end

	if rebuildAccum < REBUILD_INTERVAL then
		return
	end
	rebuildAccum = 0

	local origin = playerPos()
	if not origin then
		return
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(origin))
	if land == currentLand then
		return
	end
	currentLand = land
	queueLandOptimize(land)
end

function M.init()
	if heartbeatConn then
		return
	end
	task.spawn(function()
		task.wait(3)
		local origin = playerPos()
		if origin then
			currentLand = math.floor(LandResolver.resolveLandAtPosition(origin))
			queueLandOptimize(currentLand)
		end
	end)
	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
end

return M
