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

function M.getSpawnCFrameForLand(land: number): CFrame?
	local folder = findLandFolder(land)
	if not folder then
		return nil
	end

	local spawnNode = folder:FindFirstChild("Spawn")
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
