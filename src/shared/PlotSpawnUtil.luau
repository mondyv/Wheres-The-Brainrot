-- [ACTIVE] PlotSpawnUtil
--[[
	Resolves plot spawn CFrames and teleports characters onto the assigned plot.
	Shared by PlotPlayerSpawn and ReturnTeleport.
--]]

local PlotPaths = require(script.Parent.PlotPaths)

local PlotSpawnUtil = {}

local SPAWN_CLEARANCE = 4

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

local function boundingBoxOf(root: Instance): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	-- Include the root itself when it's a BasePart (Floor may be a single tile part).
	if root:IsA("BasePart") then
		any = true
		minV, maxV = expandPartBounds(root.CFrame, root.Size, minV, maxV)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			any = true
			minV, maxV = expandPartBounds(d.CFrame, d.Size, minV, maxV)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

-- Ground-plane pad under story 1 (all flat / low parts), not just one Floor tile.
local function groundPadBoundsOfStory(story1: Instance): (Vector3?, Vector3?)
	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	if floor then
		local floorMin, floorMax = boundingBoxOf(floor)
		if floorMin and floorMax then
			local spanX = floorMax.X - floorMin.X
			local spanZ = floorMax.Z - floorMin.Z
			-- Full pad already — don't pull in walls/stands.
			if spanX >= 24 and spanZ >= 24 then
				return floorMin, floorMax
			end
		end
	end

	local candidates: { BasePart } = {}
	local minBottom = math.huge
	local function consider(part: BasePart)
		table.insert(candidates, part)
		local bottom = part.Position.Y - part.Size.Y * 0.5
		if bottom < minBottom then
			minBottom = bottom
		end
	end

	if floor then
		if floor:IsA("BasePart") then
			consider(floor)
		end
		for _, d in ipairs(floor:GetDescendants()) do
			if d:IsA("BasePart") then
				consider(d)
			end
		end
	end

	-- Floor is only a corner tile — expand with other low flat parts on story 1.
	for _, d in ipairs(story1:GetDescendants()) do
		if d:IsA("BasePart") and d.Size.Y <= 4 then
			local n = string.lower(d.Name)
			local looksFloor = string.find(n, "floor", 1, true)
				or string.find(n, "pad", 1, true)
				or string.find(n, "ground", 1, true)
				or string.find(n, "tile", 1, true)
			if looksFloor or d.Size.Y <= 1.75 then
				consider(d)
			end
		end
	end

	if #candidates == 0 then
		return nil, nil
	end

	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	local yCutoff = minBottom + 6
	for _, part in ipairs(candidates) do
		local top = part.Position.Y + part.Size.Y * 0.5
		if top <= yCutoff then
			any = true
			minV, maxV = expandPartBounds(part.CFrame, part.Size, minV, maxV)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function cfOnTopOfBounds(minV: Vector3, maxV: Vector3, face: Vector3): CFrame
	local center = (minV + maxV) * 0.5
	local topY = maxV.Y + SPAWN_CLEARANCE
	local pos = Vector3.new(center.X, topY, center.Z)
	local flat = Vector3.new(face.X, 0, face.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

function PlotSpawnUtil.findFirstFloorSpawnCFrame(plot: Instance): CFrame?
	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil
	end

	local spawnNode = story1:FindFirstChild("Spawn")
	if spawnNode then
		local anchor: BasePart? = nil
		if spawnNode:IsA("BasePart") then
			anchor = spawnNode
		else
			anchor = spawnNode:FindFirstChildWhichIsA("BasePart", true)
		end
		if anchor then
			local top = anchor.CFrame.Position + Vector3.new(0, anchor.Size.Y * 0.5 + SPAWN_CLEARANCE, 0)
			local look = anchor.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 0.08 then
				flat = Vector3.new(0, 0, -1)
			end
			return CFrame.lookAt(top, top + flat.Unit)
		end
	end

	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	local bboxRoot: Instance = if floor then floor else story1
	local minV, maxV = boundingBoxOf(bboxRoot)
	if not minV or not maxV then
		return nil
	end

	local face = Vector3.new(0, 0, -1)
	local posPart = PlotPaths.findSpawnAndBasesFolder()
	local slotId = plot:GetAttribute("PlotSlotId")
	if posPart and typeof(slotId) == "number" then
		local anchor = posPart:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
		if anchor and anchor:IsA("BasePart") then
			local look = (anchor :: BasePart).CFrame.LookVector
			face = Vector3.new(look.X, 0, look.Z)
		end
	end

	return cfOnTopOfBounds(minV, maxV, face)
end

function PlotSpawnUtil.getPlotFloorBounds(plot: Instance): (Vector3?, Vector3?)
	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil, nil
	end
	local padMin, padMax = groundPadBoundsOfStory(story1)
	if padMin and padMax then
		return padMin, padMax
	end
	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	local bboxRoot: Instance = if floor then floor else story1
	return boundingBoxOf(bboxRoot)
end

-- Oriented box covering the whole story-1 ground pad (for SelectionBox outlines).
function PlotSpawnUtil.getPlotFloorOutlineCFrameSize(plot: Instance): (CFrame?, Vector3?)
	local minV, maxV = PlotSpawnUtil.getPlotFloorBounds(plot)
	if not minV or not maxV then
		return nil, nil
	end
	local size = maxV - minV
	local height = math.clamp(math.max(size.Y, 0.35), 0.35, 3)
	local center = Vector3.new((minV.X + maxV.X) * 0.5, minV.Y + height * 0.5, (minV.Z + maxV.Z) * 0.5)

	-- Prefer BasePOSPart orientation when it covers a full pad; never shrink below floor AABB.
	local yaw = CFrame.new(center)
	local outX = math.max(size.X, 6)
	local outZ = math.max(size.Z, 6)
	local slotId = plot:GetAttribute("PlotSlotId")
	local posFolder = PlotPaths.findSpawnAndBasesFolder()
	if posFolder and typeof(slotId) == "number" then
		local anchor = posFolder:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
		if anchor and anchor:IsA("BasePart") then
			local a = anchor :: BasePart
			if a.Size.X >= 20 and a.Size.Z >= 20 then
				outX = math.max(outX, a.Size.X)
				outZ = math.max(outZ, a.Size.Z)
			end
			local flat = Vector3.new(a.CFrame.LookVector.X, 0, a.CFrame.LookVector.Z)
			if flat.Magnitude >= 0.08 then
				yaw = CFrame.lookAt(center, center + flat.Unit)
			else
				yaw = CFrame.new(center) * (a.CFrame - a.CFrame.Position)
			end
		end
	end

	return yaw, Vector3.new(outX, height, outZ)
end

-- Random floor point on a plot, facing toward targetPos, at least minDist studs away (flat XZ).
function PlotSpawnUtil.pickRandomAmbushPositionOnPlot(
	plot: Instance,
	targetPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local minV, maxV = PlotSpawnUtil.getPlotFloorBounds(plot)
	if not minV or not maxV then
		return nil
	end

	local spanX = maxV.X - minV.X - edgeMargin * 2
	local spanZ = maxV.Z - minV.Z - edgeMargin * 2
	if spanX < 4 or spanZ < 4 then
		return nil
	end

	local topY = maxV.Y + 2
	local targetFlat = Vector3.new(targetPos.X, topY, targetPos.Z)

	for _ = 1, 32 do
		local x = minV.X + edgeMargin + math.random() * spanX
		local z = minV.Z + edgeMargin + math.random() * spanZ
		local pos = Vector3.new(x, topY, z)
		local flatDist = (targetFlat - pos).Magnitude
		if flatDist >= minDist and (not maxDist or flatDist <= maxDist) then
			return pos
		end
	end

	local center = (minV + maxV) * 0.5
	local centerFlat = Vector3.new(center.X, topY, center.Z)
	local away = centerFlat - targetFlat
	if away.Magnitude < 0.1 then
		away = Vector3.new(1, 0, 0)
	else
		away = away.Unit * minDist
	end
	local fallback = targetFlat + away
	return Vector3.new(
		math.clamp(fallback.X, minV.X + edgeMargin, maxV.X - edgeMargin),
		topY,
		math.clamp(fallback.Z, minV.Z + edgeMargin, maxV.Z - edgeMargin)
	)
end

function PlotSpawnUtil.getAssignedPlotSpawnCFrame(player: Player): CFrame?
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot or not plot.Parent then
		return nil
	end
	return PlotSpawnUtil.findFirstFloorSpawnCFrame(plot)
end

function PlotSpawnUtil.teleportCharacterToCFrame(character: Model, spawnCf: CFrame)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = character:WaitForChild("HumanoidRootPart", 8) :: BasePart?
	end
	if not hrp then
		return
	end

	-- Move via HRP so welded head-carries stay in the character assembly.
	-- Model:PivotTo can desync nested carry models after a long-distance teleport.
	hrp.CFrame = spawnCf
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

return PlotSpawnUtil
