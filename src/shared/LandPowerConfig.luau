-- [ACTIVE] LandPowerConfig
-- Recommended / lock power to ENTER each land (Land 1 has no lock).
local M = {}

M.MAX_LAND = 10
M.LAND_1_RECOMMENDED = 200

-- Power needed to pass Workspace.Map["Land Locks"]["Land N Lock"] and enter that land.
M.ENTER_POWER = {
	[2] = 600,
	[3] = 3_000,
	[4] = 12_000,
	[5] = 35_000,
	[6] = 100_000,
	[7] = 300_000,
	[8] = 900_000,
	[9] = 2_500_000,
	[10] = 7_500_000,
}

function M.requiredToEnterLand(land: number): number
	local n = math.floor(land)
	if n <= 1 then
		return 0
	end
	return M.ENTER_POWER[n] or M.ENTER_POWER[M.MAX_LAND]
end

function M.formatPower(n: number): string
	local s = tostring(math.max(0, math.floor(n + 0.5)))
	local k = 1
	while k > 0 do
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
	end
	return s
end

-- Previous lock requirement, next lock requirement, next land index (11 = past Land 10).
function M.bandForPower(power: number): (number, number, number)
	local p = math.max(0, power)
	local prev = 0
	for land = 2, M.MAX_LAND do
		local req = M.ENTER_POWER[land]
		if p < req then
			return prev, req, land
		end
		prev = req
	end
	local last = M.ENTER_POWER[M.MAX_LAND]
	return last, last, M.MAX_LAND + 1
end

-- 0 = early in a land band (weaker swing), 1 = at the next lock (full swing to cross).
function M.swingPeakAlpha(power: number): number
	local prev, nextReq, nextLand = M.bandForPower(power)
	if nextLand > M.MAX_LAND then
		return 1
	end
	local span = nextReq - prev
	if span <= 0 then
		return 1
	end
	local t = math.clamp((power - prev) / span, 0, 1)
	if t < 0.7 then
		return 0.12 + 0.28 * (t / 0.7)
	end
	local u = (t - 0.7) / 0.3
	u = u * u * (3 - 2 * u)
	return 0.4 + 0.6 * u
end

function M.meetsLandLock(power: number, land: number): boolean
	return power >= M.requiredToEnterLand(land)
end

return M
