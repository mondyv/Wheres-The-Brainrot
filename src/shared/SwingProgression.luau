-- Unified swing upgrade curves for in-swing steering/speed (release launch is deterministic in SwingSystem).
local M = {}

M.POWER_MAX_LEVEL = 300
M.ROPE_MAX_LEVEL = 100

-- UI display: base 10, +1 per upgrade level (Power10 → 10 to 20, label shows +10).
M.POWER_DISPLAY_BASE = 10
M.POWER_DISPLAY_STEP = 1
M.REACH_DISPLAY_BASE = 10
M.REACH_DISPLAY_STEP = 1

local function floorLevel(n: number): number
	return math.max(0, math.floor(n))
end

-- Early levels matter more; late levels soften toward the cap (no flat early grind).
function M.progressT(level: number, maxLevel: number): number
	local cap = math.max(1, maxLevel)
	local linear = math.clamp(floorLevel(level) / cap, 0, 1)
	local curved = linear ^ 0.55
	return linear * 0.3 + curved * 0.7
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

function M.displayBonusForUnits(_levelAttr: string, units: number): number
	return math.max(0, math.floor(units))
end

export type PowerStats = {
	steeringForce: number,
	maxSwingSpeed: number,
	swingArcForce: number,
	zipToward: number,
}

export type RopeStats = {
	reachStuds: number,
}

function M.powerStats(powerLevel: number): PowerStats
	local t = M.progressT(powerLevel, M.POWER_MAX_LEVEL)
	local maxSwingSpeed = 78 + t * 58

	return {
		steeringForce = 78 + t * 75,
		maxSwingSpeed = maxSwingSpeed,
		swingArcForce = 34 + t * 50,
		zipToward = 14 + t * 10,
	}
end

-- Backend reach grows ~2.5× slower than power/speed (UI display unchanged).
local REACH_STUDS_RANGE = 258

function M.ropeStats(ropeLevel: number): RopeStats
	local t = M.progressT(ropeLevel, M.ROPE_MAX_LEVEL)
	return {
		reachStuds = 56 + t * REACH_STUDS_RANGE,
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
			-- Legacy UI stored +10 display steps (10, 20, 110 …).
			if delta >= 10 and delta % 10 == 0 and delta // 10 <= M.POWER_MAX_LEVEL then
				local asStep10 = delta // 10
				if asStep10 * 10 == delta then
					return asStep10
				end
			end
			return math.max(0, delta)
		end
		return math.max(0, v - 1)
	end
	if attr == "SwingRange" then
		if v >= M.REACH_DISPLAY_BASE then
			local delta = v - M.REACH_DISPLAY_BASE
			if delta >= 10 and delta % 10 == 0 and delta // 10 <= M.ROPE_MAX_LEVEL then
				local asStep10 = delta // 10
				if asStep10 * 10 == delta then
					return asStep10
				end
			end
			return math.max(0, delta)
		end
		return math.max(0, v - 1)
	end
	if attr == "Carry" then
		return math.max(0, v - 1)
	end
	return 0
end

return M
