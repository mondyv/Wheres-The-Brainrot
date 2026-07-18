-- [ACTIVE] LandAmbushUtil
--[[
	Random ambush positions on Map.Lands.Land<N>.Spawn (wilderness lands, not player plot).
	Samples inside the Spawn part OBB (not world AABB) so spawns stay off ledges.
	Ground height uses raycasts that skip invisible/border/hitbox parts.
]]

local LandResolver = require(script.Parent.LandResolver)

local LandAmbushUtil = {}

local SKIP_NAME = {
	invisible = true,
	border = true,
	hitbox = true,
	safezone = true,
	redwall = true,
	reddie = true,
}

local function shouldUseAsGround(part: BasePart): boolean
	local n = string.lower(part.Name)
	for token, _ in SKIP_NAME do
		if string.find(n, token, 1, true) then
			return false
		end
	end
	if part.Transparency >= 0.98 and not part.CanCollide then
		return false
	end
	return true
end

local function isInsideSpawnXZ(part: BasePart, worldPos: Vector3, edgeMargin: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPos)
	local half = part.Size * 0.5
	local insetX = math.max(half.X - edgeMargin, 0)
	local insetZ = math.max(half.Z - edgeMargin, 0)
	if insetX < 1 or insetZ < 1 then
		-- Tiny spawn: keep a proportional inset so we never sit on the rim.
		insetX = half.X * 0.7
		insetZ = half.Z * 0.7
	end
	return math.abs(localPt.X) <= insetX and math.abs(localPt.Z) <= insetZ
end

local function resolveGroundY(x: number, z: number, referenceY: number): number?
	local origin = Vector3.new(x, referenceY + 90, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	params.FilterDescendantsInstances = ignore

	for _ = 1, 10 do
		local result = workspace:Raycast(origin, Vector3.new(0, -260, 0), params)
		if not result then
			return nil
		end
		local hitPart = result.Instance
		if hitPart:IsA("BasePart") and shouldUseAsGround(hitPart) then
			return result.Position.Y + 2
		end
		table.insert(ignore, hitPart)
		params.FilterDescendantsInstances = ignore
		origin = result.Position - Vector3.new(0, 0.15, 0)
	end
	return nil
end

local function samplePointOnSpawnPart(
	part: BasePart,
	targetPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local half = part.Size * 0.5
	local usableX = math.max(half.X - edgeMargin, half.X * 0.55)
	local usableZ = math.max(half.Z - edgeMargin, half.Z * 0.55)
	if usableX < 2 or usableZ < 2 then
		return nil
	end

	local refY = targetPos.Y
	local targetFlat = Vector3.new(targetPos.X, 0, targetPos.Z)
	local bestFar: Vector3? = nil
	local bestFarDist = -1

	for _ = 1, 48 do
		local lx = (math.random() * 2 - 1) * usableX
		local lz = (math.random() * 2 - 1) * usableZ
		-- Sample near the top face so we stay over the Spawn footprint.
		local localY = half.Y * 0.35
		local world = part.CFrame:PointToWorldSpace(Vector3.new(lx, localY, lz))
		local y = resolveGroundY(world.X, world.Z, refY)
		if not y then
			continue
		end
		local pos = Vector3.new(world.X, y, world.Z)
		if not isInsideSpawnXZ(part, pos, edgeMargin) then
			continue
		end

		local flatDist = (targetFlat - Vector3.new(pos.X, 0, pos.Z)).Magnitude
		if flatDist > bestFarDist then
			bestFarDist = flatDist
			bestFar = pos
		end
		if flatDist >= minDist and (not maxDist or flatDist <= maxDist) then
			return pos
		end
	end

	-- Prefer farthest valid point still on Spawn (never leave the Spawn volume).
	if bestFar and bestFarDist >= math.min(minDist * 0.55, 14) then
		return bestFar
	end
	return bestFar
end

function LandAmbushUtil.findLandFolder(land: number): Instance?
	local map = workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return nil
	end
	return lands:FindFirstChild("Land" .. tostring(math.floor(land)))
end

function LandAmbushUtil.getLandBounds(landFolder: Instance): (Vector3?, Vector3?)
	return LandResolver.getSpawnBoundsForLandFolder(landFolder)
end

function LandAmbushUtil.pickRandomAmbushOnLand(
	landFolder: Instance,
	targetPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local parts = LandResolver.getSpawnPartsForLandFolder(landFolder)
	if #parts == 0 then
		return nil
	end

	-- Try larger Spawn parts first (more room to stay far from the player).
	table.sort(parts, function(a, b)
		return (a.Size.X * a.Size.Z) > (b.Size.X * b.Size.Z)
	end)

	local bestOverall: Vector3? = nil
	local bestOverallDist = -1
	local targetFlat = Vector3.new(targetPos.X, 0, targetPos.Z)

	for _, part in parts do
		local pos = samplePointOnSpawnPart(part, targetPos, minDist, maxDist, edgeMargin)
		if pos then
			local flatDist = (targetFlat - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if flatDist >= minDist and (not maxDist or flatDist <= maxDist) then
				return pos
			end
			if flatDist > bestOverallDist then
				bestOverallDist = flatDist
				bestOverall = pos
			end
		end
	end

	return bestOverall
end

function LandAmbushUtil.pickAmbushForPlayer(
	playerPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	-- Only the land the player is currently on — never spill onto another Land's Spawn.
	local land = LandResolver.resolveLandAtPosition(playerPos)
	local folder = LandAmbushUtil.findLandFolder(land)
	if not folder then
		return nil
	end
	return LandAmbushUtil.pickRandomAmbushOnLand(folder, playerPos, minDist, maxDist, edgeMargin)
end

return LandAmbushUtil
