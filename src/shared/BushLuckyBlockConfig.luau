-- [ACTIVE] BushLuckyBlockConfig
--[[
	Rare lucky-block drops from bush searches. Chance + block tier scale with land.
	Block ids / variants come from LuckyBlockCatalog.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))

local M = {}

-- Per-land chance to drop a lucky block on a successful bush search.
M.CHANCE_BY_LAND = {
	[1] = 0.012,
	[2] = 0.016,
	[3] = 0.020,
	[4] = 0.025,
	[5] = 0.030,
	[6] = 0.035,
	[7] = 0.040,
	[8] = 0.045,
	[9] = 0.050,
	[10] = 0.055,
}

-- Weighted block kinds per land (higher lands unlock better catalog tiers).
M.BLOCK_WEIGHTS_BY_LAND = {
	[1] = {
		["Starter Lucky Block"] = 88,
		["troll"] = 12,
	},
	[2] = {
		["Starter Lucky Block"] = 75,
		["troll"] = 18,
		["neon"] = 7,
	},
	[3] = {
		["Starter Lucky Block"] = 55,
		["troll"] = 18,
		["neon"] = 15,
		["1"] = 8,
		["Mythic Lucky Block"] = 4,
	},
	[4] = {
		["Starter Lucky Block"] = 40,
		["neon"] = 18,
		["1"] = 16,
		["Mythic Lucky Block"] = 18,
		["purple"] = 8,
	},
	[5] = {
		["Starter Lucky Block"] = 28,
		["neon"] = 12,
		["1"] = 14,
		["Mythic Lucky Block"] = 22,
		["purple"] = 14,
		["yellow"] = 8,
		["Godly Luckyblock"] = 2,
	},
	[6] = {
		["Mythic Lucky Block"] = 22,
		["purple"] = 18,
		["yellow"] = 16,
		["Godly Luckyblock"] = 14,
		["heart"] = 12,
		["neon"] = 10,
		["1"] = 8,
	},
	[7] = {
		["Mythic Lucky Block"] = 12,
		["purple"] = 14,
		["yellow"] = 14,
		["Godly Luckyblock"] = 18,
		["heart"] = 16,
		["chamber"] = 12,
		["rainbow"] = 8,
		["Secret Lucky Block"] = 6,
	},
	[8] = {
		["Godly Luckyblock"] = 16,
		["heart"] = 16,
		["chamber"] = 16,
		["rainbow"] = 14,
		["Secret Lucky Block"] = 14,
		["star"] = 10,
		["yellow"] = 8,
		["purple"] = 6,
	},
	[9] = {
		["heart"] = 12,
		["chamber"] = 14,
		["rainbow"] = 16,
		["Secret Lucky Block"] = 16,
		["star"] = 14,
		["ruby"] = 12,
		["1 opposite"] = 6,
		["Godly Luckyblock"] = 10,
	},
	[10] = {
		["chamber"] = 10,
		["rainbow"] = 12,
		["Secret Lucky Block"] = 14,
		["star"] = 16,
		["ruby"] = 18,
		["1 opposite"] = 14,
		["heart"] = 8,
		["Godly Luckyblock"] = 8,
	},
}

function M.chanceForLand(land: number): number
	local n = math.clamp(math.floor(land), 1, 10)
	return M.CHANCE_BY_LAND[n] or M.CHANCE_BY_LAND[1]
end

function M.pickBlockForLand(land: number): (string, string?)
	local n = math.clamp(math.floor(land), 1, 10)
	local weights = M.BLOCK_WEIGHTS_BY_LAND[n] or M.BLOCK_WEIGHTS_BY_LAND[1]
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return "Starter Lucky Block", LuckyBlockCatalog.defaultVariant("Starter Lucky Block")
	end
	local r = math.random() * total
	local acc = 0
	local chosen = "Starter Lucky Block"
	for name, w in weights do
		if w > 0 then
			acc += w
			if r <= acc then
				chosen = name
				break
			end
		end
	end
	return chosen, LuckyBlockCatalog.defaultVariant(chosen)
end

return M
