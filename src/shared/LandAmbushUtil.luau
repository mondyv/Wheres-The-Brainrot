-- [ACTIVE] LandAmbushUtil
--[[
	Random ambush positions on Map.Lands.Land<N> (wilderness lands, not player plot).
	Ground height uses raycasts so invisible ceiling borders are not used as floor Y.
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

local function shouldIncludePart(part: BasePart): boolean
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
	local stack = { root }
	local count = 0
	local any = false
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst:IsA("BasePart") and shouldIncludePart(inst) then
			any = true
			minV, maxV = expandPartBounds(inst.CFrame, inst.Size, minV, maxV)
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		count += 1
		if count % 800 == 0 then
			task.wait()
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function resolveGroundY(x: number, z: number, referenceY: number): number
	local origin = Vector3.new(x, referenceY + 80, z)
	local result = workspace:Raycast(origin, Vector3.new(0, -220, 0))
	if result then
		return result.Position.Y + 2
	end
	return referenceY
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
	return boundingBoxOf(landFolder)
end

function LandAmbushUtil.pickRandomAmbushOnLand(
	landFolder: Instance,
	targetPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local minV, maxV = LandAmbushUtil.getLandBounds(landFolder)
	if not minV or not maxV then
		return nil
	end

	local spanX = maxV.X - minV.X - edgeMargin * 2
	local spanZ = maxV.Z - minV.Z - edgeMargin * 2
	if spanX < 6 or spanZ < 6 then
		return nil
	end

	local refY = targetPos.Y
	local targetFlat = Vector3.new(targetPos.X, refY, targetPos.Z)

	for _ = 1, 36 do
		local x = minV.X + edgeMargin + math.random() * spanX
		local z = minV.Z + edgeMargin + math.random() * spanZ
		local y = resolveGroundY(x, z, refY)
		local pos = Vector3.new(x, y, z)
		local flatDist = (Vector3.new(targetFlat.X, y, targetFlat.Z) - pos).Magnitude
		if flatDist >= minDist and (not maxDist or flatDist <= maxDist) then
			return pos
		end
	end

	local center = (minV + maxV) * 0.5
	local centerFlat = Vector3.new(center.X, refY, center.Z)
	local away = centerFlat - targetFlat
	if away.Magnitude < 0.1 then
		away = Vector3.new(1, 0, 0)
	else
		away = away.Unit * minDist
	end
	local fx = math.clamp(targetFlat.X + away.X, minV.X + edgeMargin, maxV.X - edgeMargin)
	local fz = math.clamp(targetFlat.Z + away.Z, minV.Z + edgeMargin, maxV.Z - edgeMargin)
	local fy = resolveGroundY(fx, fz, refY)
	return Vector3.new(fx, fy, fz)
end

function LandAmbushUtil.pickAmbushForPlayer(
	playerPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local land = LandResolver.resolveLandAtPosition(playerPos)
	local folder = LandAmbushUtil.findLandFolder(land)
	if folder then
		local pos = LandAmbushUtil.pickRandomAmbushOnLand(folder, playerPos, minDist, maxDist, edgeMargin)
		if pos then
			return pos
		end
	end

	for offsetLand = 1, 10 do
		local tryLand = ((land - 1 + offsetLand) % 10) + 1
		local tryFolder = LandAmbushUtil.findLandFolder(tryLand)
		if tryFolder then
			local pos = LandAmbushUtil.pickRandomAmbushOnLand(tryFolder, playerPos, minDist, maxDist, edgeMargin)
			if pos then
				return pos
			end
		end
	end

	return nil
end

return LandAmbushUtil
