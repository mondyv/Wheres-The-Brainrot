-- Unified swing target pick + CanSwing (UI and attach must use the same rules).
local CollectionService = game:GetService("CollectionService")

local SwingConfig = require(script.Parent.SwingConfig)

local M = {}

export type CanSwingResult = {
	canShowUi: boolean,
	canAttach: boolean,
	target: BasePart?,
	attachWorld: Vector3?,
	distance: number,
	inSafezone: boolean,
}

export type SwingQuery = {
	hrpPosition: Vector3,
	humanoid: Humanoid?,
	isAirborne: boolean,
	isSwinging: boolean,
	isDead: boolean,
	inSafezone: boolean,
	lastSwingEndClock: number,
	attachRangeStuds: number,
	cameraLook: Vector3?,
	partCache: { BasePart },
	now: number,
}

function M.closestAttachWorldOnPart(part: BasePart, hrpPosition: Vector3): Vector3
	local ok, pt = pcall(function()
		return part:GetClosestPointOnSurface(hrpPosition)
	end)
	if ok and typeof(pt) == "Vector3" then
		return pt :: Vector3
	end
	return part.Position
end

function M.attachRangeLimit(attachRangeStuds: number): number
	return attachRangeStuds + SwingConfig.ATTACH_RANGE_SLACK
end

function M.isValidSwingTarget(inst: Instance?): boolean
	if not inst or not inst:IsA("BasePart") or not inst.Parent then
		return false
	end
	return CollectionService:HasTag(inst, SwingConfig.SWING_TARGET_TAG) or inst.Name == "SwingTarget" or inst.Name == "SwingPart"
end

local function lookAlignment(cameraLook: Vector3?, hrpPosition: Vector3, attachWorld: Vector3): number
	if not cameraLook then
		return 1
	end
	local dir = attachWorld - hrpPosition
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	local flatLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)
	if flatDir.Magnitude > 0.05 and flatLook.Magnitude > 0.05 then
		return flatDir.Unit:Dot(flatLook.Unit)
	end
	if dir.Magnitude > 0.08 then
		return cameraLook:Dot(dir.Unit)
	end
	return 1
end

function M.findBestTarget(query: SwingQuery): (BasePart?, Vector3?, number)
	local limit = M.attachRangeLimit(query.attachRangeStuds)
	local best: BasePart? = nil
	local bestWorld: Vector3? = nil
	local bestDist = math.huge
	local bestScore = -math.huge

	for _, p in query.partCache do
		if not p.Parent then
			continue
		end
		local attachWorld = M.closestAttachWorldOnPart(p, query.hrpPosition)
		local dir = attachWorld - query.hrpPosition
		local dist = dir.Magnitude
		if dist < SwingConfig.MIN_ATTACH_DIST or dist > limit then
			continue
		end

		local score: number
		if dist <= SwingConfig.NEAR_ATTACH_STUDS then
			score = 1000 - dist
		else
			local align = lookAlignment(query.cameraLook, query.hrpPosition, attachWorld)
			if align < SwingConfig.MIN_GRAPPLE_LOOK_DOT then
				continue
			end
			score = align * 120 - dist * 0.08
			if attachWorld.Y > query.hrpPosition.Y + 2 then
				score += 6
			end
		end

		if score > bestScore then
			bestScore = score
			best = p
			bestWorld = attachWorld
			bestDist = dist
		end
	end

	return best, bestWorld, bestDist
end

function M.mayAttachFromState(query: SwingQuery, distance: number): boolean
	if query.isSwinging or query.isDead then
		return false
	end
	if distance <= SwingConfig.NEAR_ATTACH_STUDS then
		return true
	end
	if query.isAirborne then
		return true
	end
	return query.now - query.lastSwingEndClock < SwingConfig.REATTACH_AIR_GRACE
end

function M.canSwing(query: SwingQuery): CanSwingResult
	local none: CanSwingResult = {
		canShowUi = false,
		canAttach = false,
		target = nil,
		attachWorld = nil,
		distance = math.huge,
		inSafezone = query.inSafezone,
	}

	if query.isSwinging or query.isDead then
		return none
	end

	local target, attachWorld, dist = M.findBestTarget(query)
	if not target or not attachWorld then
		return none
	end

	if not M.mayAttachFromState(query, dist) then
		return none
	end

	local canShowUi = true
	local canAttach = not query.inSafezone

	return {
		canShowUi = canShowUi,
		canAttach = canAttach,
		target = target,
		attachWorld = attachWorld,
		distance = dist,
		inSafezone = query.inSafezone,
	}
end

return M
