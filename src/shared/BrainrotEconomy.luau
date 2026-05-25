--[[
	Shared sell pricing + income helpers (uses inventory entry fields; no server Brainrots require).
	Sell price = 10× current income per second.
--]]

local M = {}

M.SELL_INCOME_MULT = 10

local RARITY_MAX = {
	common = 10_000,
	uncommon = 50_000,
	rare = 250_000,
	epic = 1_000_000,
	mythic = 5_000_000,
	legendary = 25_000_000,
	["brainrot god"] = 125_000_000,
	secret = 1_000_000_000,
}

local MUTATION_MULT = {
	normal = 1,
	golden = 3,
	diamond = 4,
	lava = 8,
	galaxy = 12,
	rainbow = 25,
}

local MAX_LEVEL = 90

export type InvEntry = {
	name: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

function M.incomePerSecond(entry: InvEntry): number
	local rMax = RARITY_MAX[entry.rarity]
	if not rMax then
		return 0
	end
	local mm = MUTATION_MULT[entry.mutation] or 1
	local lvl = math.clamp(math.floor(entry.level), 1, MAX_LEVEL)
	local factor = rMax ^ ((lvl - 1) / (MAX_LEVEL - 1))
	return entry.baseIncome * mm * factor
end

function M.sellPrice(entry: InvEntry): number
	return math.max(1, math.floor(M.incomePerSecond(entry) * M.SELL_INCOME_MULT))
end

function M.formatCashShort(n: number): string
	if n >= 1e15 then
		return string.format("$%.2fQa", n / 1e15)
	elseif n >= 1e12 then
		return string.format("$%.2fT", n / 1e12)
	elseif n >= 1e9 then
		return string.format("$%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("$%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("$%.2fK", n / 1e3)
	end
	return string.format("$%d", math.floor(n + 0.5))
end

function M.formatSellButton(n: number): string
	return "+" .. M.formatCashShort(n)
end

return M
