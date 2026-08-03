-- [ACTIVE] BushLuckyBlockConfig
--[[
	Rare lucky-block drops from bush searches. Chance + block tier scale with land.
]]

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

-- Weighted block kinds per land (higher lands unlock better blocks).
M.BLOCK_WEIGHTS_BY_LAND = {
	[1] = { ["Starter Lucky Block"] = 100 },
	[2] = { ["Starter Lucky Block"] = 100 },
	[3] = { ["Starter Lucky Block"] = 92, ["Mythic Lucky Block"] = 8 },
	[4] = { ["Starter Lucky Block"] = 82, ["Mythic Lucky Block"] = 18 },
	[5] = { ["Starter Lucky Block"] = 70, ["Mythic Lucky Block"] = 28, ["Godly Luckyblock"] = 2 },
	[6] = { ["Starter Lucky Block"] = 55, ["Mythic Lucky Block"] = 38, ["Godly Luckyblock"] = 7 },
	[7] = { ["Starter Lucky Block"] = 40, ["Mythic Lucky Block"] = 45, ["Godly Luckyblock"] = 14, ["Secret Lucky Block"] = 1 },
	[8] = { ["Starter Lucky Block"] = 28, ["Mythic Lucky Block"] = 48, ["Godly Luckyblock"] = 20, ["Secret Lucky Block"] = 4 },
	[9] = { ["Starter Lucky Block"] = 18, ["Mythic Lucky Block"] = 45, ["Godly Luckyblock"] = 28, ["Secret Lucky Block"] = 9 },
	[10] = { ["Starter Lucky Block"] = 10, ["Mythic Lucky Block"] = 40, ["Godly Luckyblock"] = 35, ["Secret Lucky Block"] = 15 },
}

M.VARIANT_BY_BLOCK = {
	["Starter Lucky Block"] = "basic",
	["Mythic Lucky Block"] = "67",
	["Godly Luckyblock"] = "blue",
	["Secret Lucky Block"] = nil,
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
		return "Starter Lucky Block", M.VARIANT_BY_BLOCK["Starter Lucky Block"]
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
	return chosen, M.VARIANT_BY_BLOCK[chosen]
end

return M
