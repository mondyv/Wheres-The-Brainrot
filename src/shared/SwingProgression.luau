-- [ACTIVE] SwingProgression
-- Unified swing upgrade curves: one progression factor drives power, speed, zip, and launch.
-- Soft caps shape the early curve; levels past the soft cap keep growing (no hard power freeze).
local M = {}

-- Soft reference levels for the early curve (feel through mid-game).
-- Past these, progressT continues to grow so high upgrades still throw farther / reach more.
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

-- Early levels matter more; past softCap, keep growing with mild diminishing returns (never flat).
function M.progressT(level: number, softCap: number): number
	local cap = math.max(1, softCap)
	local lv = floorLevel(level)
	local linear = math.clamp(lv / cap, 0, 1)
	local curved = linear ^ 0.55
	local base = linear * 0.3 + curved * 0.7
	if lv <= cap then
		return base
	end
	local over = (lv - cap) / cap
	-- Smooth diminishing: still meaningful at 400, 600, 1000+ without exploding.
	local post = over / (1 + over * 0.28)
	return base + post * 1.15
end

-- Throw/release stays mild at low power, then ramps hard toward / past the soft cap.
function M.launchProgressT(level: number, softCap: number): number
	local cap = math.max(1, softCap)
	local lv = floorLevel(level)
	local linear = math.clamp(lv / cap, 0, 1)
	local delayed = linear ^ 1.48
	if lv <= cap then
		return delayed
	end
	local over = (lv - cap) / cap
	local post = over / (1 + over * 0.24)
	return delayed + post * 1.45
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
}

function M.powerStats(powerLevel: number): PowerStats
	local t = M.progressT(powerLevel, M.POWER_MAX_LEVEL)
	local lt = M.launchProgressT(powerLevel, M.POWER_MAX_LEVEL)
	local maxSwingSpeed = 118 + t * 86

	return {
		steeringForce = 110 + t * 92,
		maxSwingSpeed = maxSwingSpeed,
		swingArcForce = 52 + t * 66,
		swingSpeedPump = 1.12 + t * 1.6,
		zipToward = 25 + t * 18,
		launchImpulseBase = 8 + lt * 42,
		launchMomentumRatio = 0.16 + lt * 0.22,
		launchVelocityCarry = 0.12 + lt * 0.16,
		maxLaunchSpeed = maxSwingSpeed + 16 + lt * 165,
		launchChargeBonus = 6 + lt * 22,
		launchUpImpulse = 2.2 + lt * 5.8,
		launchDeadhangImpulse = 10 + lt * 24,
	}
end

-- Backend reach grows with power so late lands are latchable; Land 1 still starts modest.
local REACH_STUDS_BASE = 128
local REACH_STUDS_RANGE = 520

function M.ropeStats(ropeLevel: number): RopeStats
	-- Slower than general progressT: early levels barely grow reach; late still has headroom.
	local cap = math.max(1, M.ROPE_MAX_LEVEL)
	local lv = math.max(0, math.floor(ropeLevel))
	local linear = math.clamp(lv / cap, 0, 1)
	local curved = linear ^ 0.68
	local t = linear * 0.32 + curved * 0.68
	if lv > cap then
		local over = (lv - cap) / cap
		local post = over / (1 + over * 0.38)
		t += post * 0.85
	end
	return {
		reachStuds = REACH_STUDS_BASE + t * REACH_STUDS_RANGE,
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
