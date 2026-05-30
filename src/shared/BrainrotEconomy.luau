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

local function normalizeId(value: string): string
	return string.lower(string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

function M.incomePerSecond(entry: InvEntry): number
	local rMax = RARITY_MAX[normalizeId(entry.rarity)]
	if not rMax then
		return 0
	end
	local mm = MUTATION_MULT[normalizeId(entry.mutation)] or 1
	local lvl = math.clamp(math.floor(entry.level), 1, MAX_LEVEL)
	local factor = rMax ^ ((lvl - 1) / (MAX_LEVEL - 1))
	return entry.baseIncome * mm * factor
end

function M.sellPrice(entry: InvEntry): number
	return math.max(1, math.floor(M.incomePerSecond(entry) * M.SELL_INCOME_MULT))
end

local function formatCashAmount(rounded: number, suffix: string): string
	if math.abs(rounded - math.floor(rounded + 0.0001)) < 0.005 then
		return string.format("$%d%s", math.floor(rounded + 0.5), suffix)
	end
	local whole = math.floor(rounded)
	local frac = math.floor((rounded - whole) * 100 + 0.5)
	if frac >= 100 then
		whole += 1
		frac = 0
	end
	return string.format("$%d,%02d%s", whole, frac, suffix)
end

local function formatScaledCash(n: number, divisor: number, suffix: string): string
	local v = n / divisor
	local rounded = math.floor(v * 100 + 0.5) / 100
	return formatCashAmount(rounded, suffix)
end

function M.formatCashShort(n: number): string
	if n >= 1e15 then
		return formatScaledCash(n, 1e15, "Qa")
	elseif n >= 1e12 then
		return formatScaledCash(n, 1e12, "T")
	elseif n >= 1e9 then
		return formatScaledCash(n, 1e9, "B")
	elseif n >= 1e6 then
		return formatScaledCash(n, 1e6, "M")
	elseif n >= 1e3 then
		return formatScaledCash(n, 1e3, "K")
	end
	return string.format("$%d", math.floor(n + 0.5))
end

local function formatScaledNumber(n: number, divisor: number, suffix: string): string
	local v = n / divisor
	local rounded = math.floor(v * 100 + 0.5) / 100
	if math.abs(rounded - math.floor(rounded + 0.0001)) < 0.005 then
		return string.format("%d%s", math.floor(rounded + 0.5), suffix)
	end
	local whole = math.floor(rounded)
	local frac = math.floor((rounded - whole) * 100 + 0.5)
	if frac >= 100 then
		whole += 1
		frac = 0
	end
	return string.format("%d,%02d%s", whole, frac, suffix)
end

-- Compact count (rebirths, etc.) — same K/M/B steps as cash, without a $ prefix.
function M.formatNumberShort(n: number): string
	local v = math.max(0, math.floor(n + 0.5))
	if v >= 1e15 then
		return formatScaledNumber(v, 1e15, "Qa")
	elseif v >= 1e12 then
		return formatScaledNumber(v, 1e12, "T")
	elseif v >= 1e9 then
		return formatScaledNumber(v, 1e9, "B")
	elseif v >= 1e6 then
		return formatScaledNumber(v, 1e6, "M")
	elseif v >= 1e3 then
		return formatScaledNumber(v, 1e3, "K")
	end
	return tostring(v)
end

-- Live cash pad total: whole dollars under 1K; K/M/B with optional cents above.
function M.formatCashAccumulated(n: number): string
	if n <= 0 then
		return "$0"
	end
	if n >= 1e15 then
		return formatScaledCash(n, 1e15, "Qa")
	elseif n >= 1e12 then
		return formatScaledCash(n, 1e12, "T")
	elseif n >= 1e9 then
		return formatScaledCash(n, 1e9, "B")
	elseif n >= 1e6 then
		return formatScaledCash(n, 1e6, "M")
	elseif n >= 1e3 then
		return formatScaledCash(n, 1e3, "K")
	end
	return string.format("$%d", math.floor(n + 0.5))
end

function M.formatSellButton(n: number): string
	return "+" .. M.formatCashShort(n)
end

return M
