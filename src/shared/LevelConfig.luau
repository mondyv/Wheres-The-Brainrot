-- [ACTIVE] LevelConfig
-- Player account level / XP / level-up rewards (shared client + server).
local BrainrotEconomy = require(script.Parent:WaitForChild("BrainrotEconomy"))
local LuckyBlockCatalog = require(script.Parent:WaitForChild("LuckyBlockCatalog"))

local M = {}

M.LEVEL_ATTR = "PlayerLevel"
M.XP_ATTR = "PlayerXP" -- XP into the current level
M.XP_NEEDED_ATTR = "PlayerXPNeeded"
M.XP_GAIN_PULSE_ATTR = "XpGainPulse"
M.LAST_XP_GAIN_ATTR = "LastXpGain"
M.LEVEL_UP_PULSE_ATTR = "LevelUpPulse"
M.LEVEL_UP_TO_ATTR = "LevelUpTo"
M.LAST_LEVEL_CASH_ATTR = "LastLevelRewardCash"
M.LEVEL_LUCK_MULT_ATTR = "LevelLuckMultiplier"
M.LEVEL_LUCK_UNTIL_ATTR = "LevelLuckUntil"

-- Hard cap; Level 200 requirement is 1000 XP.
M.MAX_LEVEL = 200

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

export type LevelRewardKind = "cash" | "lucky_block" | "cash_boost" | "luck_boost"

export type LevelReward = {
	id: number,
	kind: LevelRewardKind,
	amount: number?, -- cash, or cash_boost percent
	luckMult: number?, -- luck_boost only
	luckSec: number?, -- luck_boost only
	luckyBlockId: string?, -- lucky_block only (LuckyBlockCatalog id)
	displayAmount: string,
	displayName: string,
}

local function cashReward(id: number, amount: number): LevelReward
	return {
		id = id,
		kind = "cash",
		amount = amount,
		displayAmount = "+" .. BrainrotEconomy.formatCashShort(amount),
		displayName = "Cash",
	}
end

local function luckyReward(id: number, blockId: string): LevelReward
	local displayName = LuckyBlockCatalog.displayName(blockId)
	return {
		id = id,
		kind = "lucky_block",
		luckyBlockId = blockId,
		amount = 0,
		displayAmount = displayName,
		displayName = displayName,
	}
end

local function cashBoostReward(id: number, percent: number): LevelReward
	local p = math.max(1, math.floor(percent))
	return {
		id = id,
		kind = "cash_boost",
		amount = p,
		displayAmount = string.format("+%d%% Cash Boost", p),
		displayName = "Cash Boost",
	}
end

local function luckBoostReward(id: number, mult: number, sec: number): LevelReward
	local minutes = math.max(1, math.floor(sec / 60 + 0.5))
	return {
		id = id,
		kind = "luck_boost",
		luckMult = mult,
		luckSec = sec,
		displayAmount = string.format("%.2gx Luck %dm", mult, minutes),
		displayName = "Luck Boost",
	}
end

-- Millions by the 40s; early levels stay modest.
local function cashForLevel(lv: number): number
	return math.max(250, math.floor(40 * (lv ^ 3.25) + 200 * lv))
end

-- Lucky blocks start at 10, then sparse milestones. Quests handle most blocks.
local function secondRewardForLevel(lv: number): LevelReward
	if lv < 10 then
		return cashReward(2, math.floor(cashForLevel(lv) * 0.35))
	end
	if lv == 10 then
		return luckyReward(2, "troll")
	elseif lv == 40 then
		return luckyReward(2, "neon")
	elseif lv == 60 then
		return luckyReward(2, "1")
	elseif lv == 80 then
		return luckyReward(2, "purple")
	elseif lv == 100 then
		return luckyReward(2, "Mythic Lucky Block")
	elseif lv == 150 then
		return luckyReward(2, "yellow")
	elseif lv == 200 then
		return luckyReward(2, "Godly Luckyblock")
	end
	if lv % 12 == 0 then
		return luckBoostReward(2, 1.25, 8 * 60)
	end
	if lv % 8 == 0 then
		return cashBoostReward(2, if lv >= 80 then 2 else 1)
	end
	return cashReward(2, math.floor(cashForLevel(lv) * 0.4))
end

-- XP required to go from `level` → `level + 1` (index = current level).
local XP_TO_NEXT: { [number]: number } = {
	[1] = 10,
	[2] = 25,
	[3] = 75,
	[4] = 200,
	[5] = 220,
	[6] = 240,
	[7] = 260,
	[8] = 280,
	[9] = 300,
	[10] = 320,
	[11] = 329,
	[12] = 337,
	[13] = 346,
	[14] = 355,
	[15] = 363,
	[16] = 372,
	[17] = 381,
	[18] = 389,
	[19] = 398,
	[20] = 407,
	[21] = 415,
	[22] = 424,
	[23] = 433,
	[24] = 441,
	[25] = 450,
	[26] = 456,
	[27] = 462,
	[28] = 468,
	[29] = 474,
	[30] = 480,
	[31] = 486,
	[32] = 492,
	[33] = 498,
	[34] = 504,
	[35] = 510,
	[36] = 516,
	[37] = 522,
	[38] = 528,
	[39] = 534,
	[40] = 540,
	[41] = 546,
	[42] = 552,
	[43] = 558,
	[44] = 564,
	[45] = 570,
	[46] = 576,
	[47] = 582,
	[48] = 588,
	[49] = 594,
	[50] = 600,
	[51] = 604,
	[52] = 607,
	[53] = 611,
	[54] = 614,
	[55] = 618,
	[56] = 622,
	[57] = 625,
	[58] = 629,
	[59] = 632,
	[60] = 636,
	[61] = 640,
	[62] = 643,
	[63] = 647,
	[64] = 650,
	[65] = 654,
	[66] = 658,
	[67] = 661,
	[68] = 665,
	[69] = 668,
	[70] = 672,
	[71] = 676,
	[72] = 679,
	[73] = 683,
	[74] = 686,
	[75] = 690,
	[76] = 694,
	[77] = 697,
	[78] = 701,
	[79] = 704,
	[80] = 708,
	[81] = 712,
	[82] = 715,
	[83] = 719,
	[84] = 722,
	[85] = 726,
	[86] = 730,
	[87] = 733,
	[88] = 737,
	[89] = 740,
	[90] = 744,
	[91] = 748,
	[92] = 751,
	[93] = 755,
	[94] = 758,
	[95] = 762,
	[96] = 766,
	[97] = 769,
	[98] = 773,
	[99] = 776,
	[100] = 780,
	[101] = 782,
	[102] = 785,
	[103] = 787,
	[104] = 790,
	[105] = 792,
	[106] = 794,
	[107] = 797,
	[108] = 799,
	[109] = 802,
	[110] = 804,
	[111] = 806,
	[112] = 809,
	[113] = 811,
	[114] = 814,
	[115] = 816,
	[116] = 818,
	[117] = 821,
	[118] = 823,
	[119] = 826,
	[120] = 828,
	[121] = 830,
	[122] = 833,
	[123] = 835,
	[124] = 838,
	[125] = 840,
	[126] = 842,
	[127] = 845,
	[128] = 847,
	[129] = 850,
	[130] = 852,
	[131] = 854,
	[132] = 857,
	[133] = 859,
	[134] = 862,
	[135] = 864,
	[136] = 866,
	[137] = 869,
	[138] = 871,
	[139] = 874,
	[140] = 876,
	[141] = 878,
	[142] = 881,
	[143] = 883,
	[144] = 886,
	[145] = 888,
	[146] = 890,
	[147] = 893,
	[148] = 895,
	[149] = 898,
	[150] = 900,
	[151] = 902,
	[152] = 904,
	[153] = 906,
	[154] = 908,
	[155] = 910,
	[156] = 912,
	[157] = 914,
	[158] = 916,
	[159] = 918,
	[160] = 920,
	[161] = 922,
	[162] = 924,
	[163] = 926,
	[164] = 928,
	[165] = 930,
	[166] = 932,
	[167] = 934,
	[168] = 936,
	[169] = 938,
	[170] = 940,
	[171] = 942,
	[172] = 944,
	[173] = 946,
	[174] = 948,
	[175] = 950,
	[176] = 952,
	[177] = 954,
	[178] = 956,
	[179] = 958,
	[180] = 960,
	[181] = 962,
	[182] = 964,
	[183] = 966,
	[184] = 968,
	[185] = 970,
	[186] = 972,
	[187] = 974,
	[188] = 976,
	[189] = 978,
	[190] = 980,
	[191] = 982,
	[192] = 984,
	[193] = 986,
	[194] = 988,
	[195] = 990,
	[196] = 992,
	[197] = 994,
	[198] = 996,
	[199] = 998,
	[200] = 1000,
}

function M.xpRequiredForLevel(level: number): number
	local lv = math.max(1, math.floor(level))
	if lv >= M.MAX_LEVEL then
		return XP_TO_NEXT[M.MAX_LEVEL] or 1000
	end
	return XP_TO_NEXT[lv] or 1000
end

function M.rewardsForLevel(level: number): { LevelReward }
	local lv = math.max(1, math.floor(level))
	return {
		cashReward(1, cashForLevel(lv)),
		secondRewardForLevel(lv),
	}
end

function M.totalCashFromRewards(rewards: { LevelReward }): number
	local total = 0
	for _, reward in rewards do
		if reward.kind == "cash" and typeof(reward.amount) == "number" then
			total += math.max(0, math.floor(reward.amount))
		end
	end
	return total
end

function M.formatRewardSummary(rewards: { LevelReward }): string
	local parts = {}
	for _, reward in rewards do
		table.insert(parts, reward.displayAmount)
	end
	return table.concat(parts, "  ·  ")
end

function M.progressAlpha(xp: number, needed: number): number
	if needed <= 0 then
		return 1
	end
	return math.clamp(xp / needed, 0, 1)
end

return M
