-- Unified swing upgrade curves: power mainly drives the release launch,
-- rope drives the max distance you can travel from the hook point.
local M = {}

-- Reference levels shape the early/mid curve; growth continues past them with diminishing returns.
M.POWER_REFERENCE_LEVEL = 300
M.ROPE_REFERENCE_LEVEL = 100

-- UI display: base 10, +10 power / +25 reach per purchase level.
M.POWER_DISPLAY_BASE = 10
M.POWER_DISPLAY_STEP = 10
M.REACH_DISPLAY_BASE = 10
M.REACH_DISPLAY_STEP = 25

-- Rope max distance: physics cap (in studs) for how far the player can travel from the hook point.
M.BASE_MAX_SWING_DISTANCE = 30
M.ROPE_DISTANCE_PER_LEVEL = 0.5

local function floorLevel(n: number): number
	return math.max(0, math.floor(n))
end

function M.maxSwingDistance(ropeLevel: number): number
	return M.BASE_MAX_SWING_DISTANCE + floorLevel(ropeLevel) * M.ROPE_DISTANCE_PER_LEVEL
end

-- Early levels matter more; beyond referenceLevel growth continues with diminishing returns.
function M.progressT(level: number, referenceLevel: number): number
	local cap = math.max(1, referenceLevel)
	local linear = floorLevel(level) / cap
	local curved = linear ^ 0.55
	if linear <= 1 then
		return linear * 0.3 + curved * 0.7
	end
	local atCap = 1
	local excess = linear - 1
	return atCap + excess ^ 0.48 * 0.42
end

function M.launchProgressT(level: number, referenceLevel: number): number
	local cap = math.max(1, referenceLevel)
	local linear = floorLevel(level) / cap
	local early = linear ^ 0.38
	local base = M.progressT(level, referenceLevel)
	if linear <= 1 then
		return math.clamp(base * 0.35 + early * 0.65, 0, 1)
	end
	local atCap = math.clamp(base, 0, 1)
	local excess = linear - 1
	return atCap + excess ^ 0.42 * 0.38
end

function M.displayPower(level: number): number
	return M.POWER_DISPLAY_BASE + floorLevel(level) * M.POWER_DISPLAY_STEP
end

function M.displayReach(level: number): number
	return M.REACH_DISPLAY_BASE + floorLevel(level) * M.REACH_DISPLAY_STEP
end

function M.displayCarry(level: number): number
	return 1 + floorLevel(level)
end

function M.displayBonusForUnits(levelAttr: string, units: number): number
	if levelAttr == "PowerUpgradeLevel" then
		return M.POWER_DISPLAY_STEP
	end
	if levelAttr == "RopeUpgradeLevel" then
		return M.REACH_DISPLAY_STEP
	end
	return math.max(0, math.floor(units))
end

export type PowerStats = {
	steeringForce: number,
	maxSwingSpeed: number,
	swingArcForce: number,
	swingSpeedPump: number,
	zipToward: number,
	launchImpulseBase: number,
	launchMomentumRatio: number,
	launchVelocityCarry: number,
	maxLaunchSpeed: number,
	launchChargeBonus: number,
	launchUpImpulse: number,
	launchDeadhangImpulse: number,
}

export type RopeStats = {
	reachStuds: number,
	maxSwingDistance: number,
}

function M.powerStats(powerLevel: number): PowerStats
	-- Power mainly improves the release LAUNCH. Swing-while-hooked grows only slightly
	-- so high power doesn't make hooked control feel uncontrollable.
	local t = M.progressT(powerLevel, M.POWER_REFERENCE_LEVEL)
	local lt = M.launchProgressT(powerLevel, M.POWER_REFERENCE_LEVEL)

	local maxSwingSpeed = 78 + t * 18

	return {
		steeringForce = 95 + t * 28,
		maxSwingSpeed = maxSwingSpeed,
		swingArcForce = 36 + t * 14,
		swingSpeedPump = 1.0 + t * 0.45,
		zipToward = 26 + t * 8,
		launchImpulseBase = 22 + lt * 78,
		launchMomentumRatio = 0.32 + lt * 0.48,
		launchVelocityCarry = 0.28 + lt * 0.22,
		maxLaunchSpeed = maxSwingSpeed + 60 + lt * 110,
		launchChargeBonus = 18 + lt * 46,
		launchUpImpulse = 6 + lt * 9,
		launchDeadhangImpulse = 26 + lt * 24,
	}
end

function M.ropeStats(ropeLevel: number): RopeStats
	local maxDist = M.maxSwingDistance(ropeLevel)
	return {
		reachStuds = maxDist,
		maxSwingDistance = maxDist,
	}
end

-- Decode legacy SwingForce / SwingRange attributes into upgrade levels.
function M.levelFromLegacyDisplay(attr: string, value: number): number
	if typeof(value) ~= "number" then
		return 0
	end
	local v = math.floor(value)
	if attr == "SwingForce" then
		if v >= M.POWER_DISPLAY_BASE then
			local delta = v - M.POWER_DISPLAY_BASE
			if delta > 0 and delta % M.POWER_DISPLAY_STEP == 0 then
				return delta // M.POWER_DISPLAY_STEP
			end
			if delta >= 10 and delta % 10 == 0 then
				return delta // 10
			end
			return math.max(0, math.floor(delta / M.POWER_DISPLAY_STEP + 0.5))
		end
		return math.max(0, v - 1)
	end
	if attr == "SwingRange" then
		if v >= M.REACH_DISPLAY_BASE then
			local delta = v - M.REACH_DISPLAY_BASE
			if delta > 0 and delta % M.REACH_DISPLAY_STEP == 0 then
				return delta // M.REACH_DISPLAY_STEP
			end
			if delta >= 10 and delta % 10 == 0 then
				return delta // 10
			end
			return math.max(0, math.floor(delta / M.REACH_DISPLAY_STEP + 0.5))
		end
		return math.max(0, v - 1)
	end
	if attr == "Carry" then
		return math.max(0, v - 1)
	end
	return 0
end

return M
