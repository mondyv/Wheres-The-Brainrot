-- Unified swing upgrade curves: one progression factor drives power, speed, zip, and launch.
local M = {}

M.POWER_MAX_LEVEL = 300
M.ROPE_MAX_LEVEL = 100

-- UI display uses clean steps of 10 (10 → 20 → 30 … per single upgrade).
M.POWER_DISPLAY_BASE = 10
M.POWER_DISPLAY_STEP = 10
M.REACH_DISPLAY_BASE = 10
M.REACH_DISPLAY_STEP = 10

local function floorLevel(n: number): number
	return math.max(0, math.floor(n))
end

-- Smooth 0→1 curve: incremental early, stronger mid/late, no per-level spikes.
function M.progressT(level: number, maxLevel: number): number
	local cap = math.max(1, maxLevel)
	local t = math.clamp(floorLevel(level) / cap, 0, 1)
	return t ^ 1.45 * (1.08 - t * 0.08)
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
	local n = math.max(0, math.floor(units))
	if levelAttr == "PowerUpgradeLevel" then
		return n * M.POWER_DISPLAY_STEP
	end
	if levelAttr == "RopeUpgradeLevel" then
		return n * M.REACH_DISPLAY_STEP
	end
	return n
end

export type PowerStats = {
	steeringForce: number,
	maxSwingSpeed: number,
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
	local maxSwingSpeed = 78 + t * 40

	return {
		steeringForce = 78 + t * 72,
		maxSwingSpeed = maxSwingSpeed,
		zipToward = 25 + t * 14,
		-- Higher bases for satisfying zero-upgrade swings; t-range trimmed to preserve endgame caps.
		launchImpulseBase = 14 + t * 7,
		launchMomentumRatio = 0.18 + t * 0.09,
		launchVelocityCarry = 0.15 + t * 0.03,
		maxLaunchSpeed = maxSwingSpeed + 16 + t * 10,
		launchChargeBonus = 11 + t * 8,
		launchUpImpulse = 4 + t * 2.5,
		launchDeadhangImpulse = 18 + t * 6,
	}
end

function M.ropeStats(ropeLevel: number): RopeStats
	local t = M.progressT(ropeLevel, M.ROPE_MAX_LEVEL)
	return {
		reachStuds = 56 + t * 644,
	}
end

-- Decode legacy SwingForce / SwingRange attributes into upgrade levels.
function M.levelFromLegacyDisplay(attr: string, value: number): number
	if typeof(value) ~= "number" then
		return 0
	end
	local v = math.floor(value)
	if attr == "SwingForce" then
		if v >= M.POWER_DISPLAY_BASE and (v - M.POWER_DISPLAY_BASE) % M.POWER_DISPLAY_STEP == 0 then
			return math.max(0, (v - M.POWER_DISPLAY_BASE) / M.POWER_DISPLAY_STEP)
		end
		return math.max(0, v - 1)
	end
	if attr == "SwingRange" then
		if v >= M.REACH_DISPLAY_BASE and (v - M.REACH_DISPLAY_BASE) % M.REACH_DISPLAY_STEP == 0 then
			return math.max(0, (v - M.REACH_DISPLAY_BASE) / M.REACH_DISPLAY_STEP)
		end
		return math.max(0, v - 1)
	end
	if attr == "Carry" then
		return math.max(0, v - 1)
	end
	return 0
end

return M
