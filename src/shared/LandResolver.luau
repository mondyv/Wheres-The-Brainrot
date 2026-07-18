-- [ACTIVE] LandResolver
--[[
	Resolve Land 1–10 from multiplier hitboxes under Map.Lands.Land<N>,
	and land Spawn parts for Robux revive teleport.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck

local M = {}

local LAND_FOLDER_PATTERN = "^Land(%d+)$"
local MAX_LAND = 10
local SPAWN_CLEARANCE = 4

export type LandHitbox = {
	part: BasePart,
	land: number,
	displayLuck: number,
}

local landHitboxes: { LandHitbox } = {}
local registeredParts: { [BasePart]: boolean } = {}
local landFolders: { [number]: Instance } = {}
local discoveryHooked = false
local initialScanDone = false

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function isPointWithinPartXZ(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Z) <= half.Z
end

local function expandPartBounds(cf: CFrame, size: Vector3, minV: Vector3, maxV: Vector3): (Vector3, Vector3)
	local hs = size * 0.5
	local newMin = minV
	local newMax = maxV
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local world = cf:PointToWorldSpace(Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz))
				newMin = Vector3.new(math.min(newMin.X, world.X), math.min(newMin.Y, world.Y), math.min(newMin.Z, world.Z))
				newMax = Vector3.new(math.max(newMax.X, world.X), math.max(newMax.Y, world.Y), math.max(newMax.Z, world.Z))
			end
		end
	end
	return newMin, newMax
end

local function boundingBoxOfSpawnRoot(spawnNode: Instance): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false

	local function includePart(part: BasePart)
		any = true
		minV, maxV = expandPartBounds(part.CFrame, part.Size, minV, maxV)
	end

	if spawnNode:IsA("BasePart") then
		includePart(spawnNode)
	elseif spawnNode:IsA("Model") or spawnNode:IsA("Folder") then
		for _, desc in spawnNode:GetDescendants() do
			if desc:IsA("BasePart") then
				includePart(desc)
			end
		end
	end

	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function getSpawnNode(landFolder: Instance): Instance?
	local direct = landFolder:FindFirstChild("Spawn")
	if direct then
		return direct
	end
	for _, child in landFolder:GetChildren() do
		if string.lower(child.Name) == "spawn" then
			return child
		end
	end
	for _, desc in landFolder:GetDescendants() do
		local lower = string.lower(desc.Name)
		if lower == "spawn" or lower == "spawnpart" or lower == "landspawn" then
			if desc:IsA("BasePart") or desc:IsA("Model") or desc:IsA("Folder") then
				return desc
			end
		end
	end
	return nil
end

local function positionWithinSpawnNode(worldPos: Vector3, spawnNode: Instance): boolean
	if spawnNode:IsA("BasePart") then
		return isPointWithinPartXZ(worldPos, spawnNode)
	end

	for _, desc in spawnNode:GetDescendants() do
		if desc:IsA("BasePart") and isPointWithinPartXZ(worldPos, desc) then
			return true
		end
	end

	return false
end

local function landNumberFromName(name: string): number?
	local n = tonumber(string.match(name, LAND_FOLDER_PATTERN))
	if not n then
		return nil
	end
	return math.clamp(math.floor(n), 1, MAX_LAND)
end

local function findLandFolder(land: number): Instance?
	local cached = landFolders[land]
	if cached and cached.Parent then
		return cached
	end

	local map = workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return nil
	end

	local folder = lands:FindFirstChild("Land" .. tostring(land))
	if folder then
		landFolders[land] = folder
		return folder
	end

	for _, child in lands:GetChildren() do
		if landNumberFromName(child.Name) == land then
			landFolders[land] = child
			return child
		end
	end

	return nil
end

local function ancestorLandFolder(part: BasePart): (number?, Instance?)
	local current: Instance? = part.Parent
	while current do
		local land = landNumberFromName(current.Name)
		if land then
			landFolders[land] = current
			return land, current
		end
		current = current.Parent
	end
	return nil, nil
end

local function tryRegisterHitbox(part: BasePart)
	if registeredParts[part] then
		return
	end

	local displayLuck = PlotLuck.parseHitboxDisplayLuck(part.Name)
	if not displayLuck then
		return
	end

	local land, folder = ancestorLandFolder(part)
	if not land or not folder then
		return
	end

	registeredParts[part] = true
	table.insert(landHitboxes, {
		part = part,
		land = land,
		displayLuck = displayLuck,
	})
end

local function scanLandsRoot(lands: Instance)
	for _, desc in lands:GetDescendants() do
		if desc:IsA("BasePart") then
			tryRegisterHitbox(desc)
		end
	end
	for _, child in lands:GetChildren() do
		local land = landNumberFromName(child.Name)
		if land then
			landFolders[land] = child
		end
	end
end

local function ensureDiscovery()
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end

	local lands = map:FindFirstChild("Lands")

	-- Full scan only once; live additions are tracked via DescendantAdded below.
	if lands and not initialScanDone then
		initialScanDone = true
		scanLandsRoot(lands)
	end

	if discoveryHooked then
		return
	end
	discoveryHooked = true

	if lands then
		lands.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") then
				tryRegisterHitbox(desc)
			end
		end)
		lands.ChildAdded:Connect(function(child)
			local land = landNumberFromName(child.Name)
			if land then
				landFolders[land] = child
			end
		end)
	end

	map.ChildAdded:Connect(function(child)
		if child.Name == "Lands" then
			task.defer(function()
				if child.Parent and not initialScanDone then
					initialScanDone = true
					scanLandsRoot(child)
				end
				(child :: Instance).DescendantAdded:Connect(function(desc)
					if desc:IsA("BasePart") then
						tryRegisterHitbox(desc)
					end
				end)
			end)
		end
	end)
end

local function centerOfLand(child: Instance): Vector3?
	if child:IsA("Model") then
		return (child :: Model):GetBoundingBox().Position
	elseif child:IsA("BasePart") then
		return (child :: BasePart).Position
	elseif child:IsA("Folder") then
		local sum = Vector3.zero
		local count = 0
		for _, d in ipairs((child :: Folder):GetDescendants()) do
			if d:IsA("BasePart") then
				sum += d.Position
				count += 1
				if count >= 60 then
					break
				end
			end
		end
		if count > 0 then
			return sum / count
		end
	end
	return nil
end

local function resolveLandByNearest(worldPos: Vector3): number
	local best = 1
	local bestDist = math.huge
	local map = workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return 1
	end

	for _, child in lands:GetChildren() do
		local n = landNumberFromName(child.Name)
		if not n then
			continue
		end
		local centerPos = centerOfLand(child)
		if centerPos then
			local dist = (centerPos - worldPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = n
			end
		elseif bestDist == math.huge then
			best = n
		end
	end

	return best
end

function M.resolveLandAtPosition(worldPos: Vector3): number
	ensureDiscovery()

	local bestLand: number? = nil
	local bestLuck = -1
	for _, entry in landHitboxes do
		if entry.part.Parent and isPointInsidePartOBB(worldPos, entry.part) then
			if entry.land > (bestLand or 0) or (bestLand == entry.land and entry.displayLuck > bestLuck) then
				bestLand = entry.land
				bestLuck = entry.displayLuck
			end
		end
	end

	if bestLand then
		return bestLand
	end

	return resolveLandByNearest(worldPos)
end

local function spawnCFrameFromPart(part: BasePart): CFrame
	local top = part.CFrame.Position + Vector3.new(0, part.Size.Y * 0.5 + SPAWN_CLEARANCE, 0)
	local look = part.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(top, top + flat.Unit)
end

function M.getSpawnBoundsForLandFolder(landFolder: Instance): (Vector3?, Vector3?)
	local spawnNode = getSpawnNode(landFolder)
	if not spawnNode then
		return nil, nil
	end
	return boundingBoxOfSpawnRoot(spawnNode)
end

function M.getSpawnPartsForLandFolder(landFolder: Instance): { BasePart }
	local spawnNode = getSpawnNode(landFolder)
	local parts: { BasePart } = {}
	if not spawnNode then
		return parts
	end
	if spawnNode:IsA("BasePart") then
		table.insert(parts, spawnNode)
		return parts
	end
	for _, desc in spawnNode:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

function M.isPositionWithinLandSpawn(worldPos: Vector3): boolean
	local map = workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return false
	end

	for _, landFolder in lands:GetChildren() do
		if not landNumberFromName(landFolder.Name) then
			continue
		end
		local spawnNode = getSpawnNode(landFolder)
		if spawnNode and positionWithinSpawnNode(worldPos, spawnNode) then
			return true
		end
	end

	return false
end

function M.getSpawnCFrameForLand(land: number): CFrame?
	local folder = findLandFolder(land)
	if not folder then
		return nil
	end

	local spawnNode = getSpawnNode(folder)
	if not spawnNode then
		return nil
	end

	if spawnNode:IsA("BasePart") then
		return spawnCFrameFromPart(spawnNode)
	end

	local anchor = spawnNode:FindFirstChildWhichIsA("BasePart", true)
	if anchor and anchor:IsA("BasePart") then
		return spawnCFrameFromPart(anchor)
	end

	return nil
end

function M.getReviveSpawnCFrame(worldPos: Vector3): (number, CFrame?)
	local land = M.resolveLandAtPosition(worldPos)
	local spawnCf = M.getSpawnCFrameForLand(land)
	return land, spawnCf
end

return M
