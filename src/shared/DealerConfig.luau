-- [ACTIVE] DealerConfig
--[[
	Brainrot Dealer — shared config (client + server).
	Restock cadence, dev product ids, per-rarity stock/rebirth gates, and the
	roll weights used to generate the 7 global offering slots.

	Stock model: global catalog carries *starting* stock per slot (restocked
	every RESTOCK_INTERVAL_SEC across all servers). Each player tracks their
	own remaining stock locally on the server — cash buys never steal from
	other players or write the global DataStore.
]]

local DealerConfig = {}

export type RarityId = "common" | "uncommon" | "rare" | "epic" | "mythic" | "legendary" | "brainrot god" | "secret"

DealerConfig.SLOT_COUNT = 7
DealerConfig.OFFERS_PER_RARITY = 2
DealerConfig.RESTOCK_INTERVAL_SEC = 600 -- 10 minutes, identical across every server

DealerConfig.CASH_PRICE_MULTIPLIER = 1000 -- price = $/s (lvl1 normal) × 1000

-- ── Developer product ids ───────────────────────────────────────────────────────
DealerConfig.PRODUCT = {
	PERSONAL_RESTOCK = 3610096531,
	-- Brainrot Dealer 1x (49 R$) — dedicated product; do not reuse steal ids.
	ROBUX_BUY_1X = 3610100073,
}
DealerConfig.ROBUX_BUY_PRICE_DISPLAY = 49 -- R$, display only — Roblox owns the real price
DealerConfig.ROBUX_BUY_MAX_PER_SLOT = 3

-- Ascending display order (common first). Mirrors BrainrotsConfig.RARITY_ORDER
-- but is kept local so the Dealer can sort listings without reaching into the
-- big brainrot config from the client.
DealerConfig.RARITY_RANK = {
	common = 1,
	uncommon = 2,
	rare = 3,
	epic = 4,
	mythic = 5,
	legendary = 6,
	["brainrot god"] = 7,
	secret = 8,
} :: { [string]: number }

function DealerConfig.rarityRank(rarity: string): number
	return DealerConfig.RARITY_RANK[string.lower(rarity or "")] or 999
end

-- Rebirths required before a rarity's offerings are visible/unlocked for a player.
DealerConfig.REBIRTHS_FOR_RARITY = {
	common = 0,
	uncommon = 0,
	rare = 1,
	epic = 3,
	mythic = 5,
	legendary = 8,
	["brainrot god"] = 12,
	secret = 16,
} :: { [string]: number }

-- Weighted roll chances used when picking which rarity fills an offering group.
-- Harder rarities are weighted much lower so they show up less often.
DealerConfig.RARITY_ROLL_WEIGHTS = {
	common = 100,
	uncommon = 70,
	rare = 45,
	epic = 25,
	mythic = 12,
	legendary = 6,
	["brainrot god"] = 2.5,
	secret = 1,
} :: { [string]: number }

-- Per-listing *starting* stock is rolled independently (1–4).
-- Rarer brainrots lean toward 1x; commons can hit 2–3x more often, 4x rarely.
DealerConfig.MAX_STOCK = 4
-- Base weights before rarity bias (amount → weight).
DealerConfig.STOCK_ROLL_WEIGHTS = {
	[1] = 50,
	[2] = 30,
	[3] = 15,
	[4] = 5,
} :: { [number]: number }

-- Multiplies high-stock weights down for rarer tiers (1x stays dominant).
DealerConfig.STOCK_RARITY_HIGH_BIAS = {
	common = 1.0,
	uncommon = 0.85,
	rare = 0.65,
	epic = 0.45,
	mythic = 0.3,
	legendary = 0.18,
	["brainrot god"] = 0.1,
	secret = 0.06,
} :: { [string]: number }

function DealerConfig.rebirthsNeededForRarity(rarity: string): number
	return DealerConfig.REBIRTHS_FOR_RARITY[rarity] or 0
end

-- Weighted 1–4 stock roll; rarer rarities have smaller chance of high stock.
function DealerConfig.rollStock(rarity: string?): number
	local rarityKey = string.lower(rarity or "common")
	local highBias = DealerConfig.STOCK_RARITY_HIGH_BIAS[rarityKey] or 0.5

	local weights: { [number]: number } = {}
	local total = 0
	for amount, baseW in DealerConfig.STOCK_ROLL_WEIGHTS do
		local w = baseW
		if amount >= 2 then
			w = baseW * highBias
		end
		weights[amount] = w
		total += w
	end
	if total <= 0 then
		return 1
	end

	local roll = math.random() * total
	local cumulative = 0
	-- Iterate amounts in order so weighting is stable.
	for amount = 1, DealerConfig.MAX_STOCK do
		local w = weights[amount]
		if w then
			cumulative += w
			if roll <= cumulative then
				return amount
			end
		end
	end
	return 1
end

return DealerConfig
