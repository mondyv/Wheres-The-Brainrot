-- [ACTIVE] LevelConfig
-- Player account level / XP / level-up rewards (shared client + server).
local BrainrotEconomy = require(script.Parent:WaitForChild("BrainrotEconomy"))

local M = {}

M.LEVEL_ATTR = "PlayerLevel"
M.XP_ATTR = "PlayerXP" -- XP into the current level
M.XP_NEEDED_ATTR = "PlayerXPNeeded"
M.XP_GAIN_PULSE_ATTR = "XpGainPulse"
M.LAST_XP_GAIN_ATTR = "LastXpGain"
M.LEVEL_UP_PULSE_ATTR = "LevelUpPulse"
M.LEVEL_UP_TO_ATTR = "LevelUpTo"

-- Soft display cap for Level Info browsing; XP still works past this.
M.MAX_LEVEL = 100

-- XP amounts for gameplay hooks.
M.XP = {
	-- Granted once every WORKOUT_XP_EVERY_GAINS workout power ticks (not each tick).
	workout = 8,
	sell = 15,
	daily = 50,
	timQuest = 100,
	acceptBrainrot = 10,
	rebirth = 200,
	steal = 25,
	luckyBlock = 20,
}
M.WORKOUT_XP_EVERY_GAINS = 5

export type LevelReward = {
	id: number,
	kind: "cash",
	amount: number,
	displayAmount: string,
	displayName: string,
}

-- XP required to go from `level` → `level + 1`.
function M.xpRequiredForLevel(level: number): number
	local lv = math.max(1, math.floor(level))
	return math.max(50, math.floor(70 + (lv ^ 1.42) * 28))
end

function M.rewardsForLevel(level: number): { LevelReward }
	local lv = math.max(1, math.floor(level))
	local cashA = math.floor(20_000 * lv * lv)
	local cashB = math.floor(12_000 * lv * (lv + 3))
	return {
		{
			id = 1,
			kind = "cash",
			amount = cashA,
			displayAmount = "+" .. BrainrotEconomy.formatCashShort(cashA),
			displayName = "Cash",
		},
		{
			id = 2,
			kind = "cash",
			amount = cashB,
			displayAmount = "+" .. BrainrotEconomy.formatCashShort(cashB),
			displayName = "Bonus Cash",
		},
	}
end

function M.progressAlpha(xp: number, needed: number): number
	if needed <= 0 then
		return 1
	end
	return math.clamp(xp / needed, 0, 1)
end

return M
