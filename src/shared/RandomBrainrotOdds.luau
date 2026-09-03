-- [ACTIVE] RandomBrainrotOdds
--[[
	Scales Random Brainrot product odds by the player's current plot $/s.
	Shared by server grants and client Chances UI so they stay in sync.

	Design: paid roll is a small side-grade near your progression, never a
	jump into god/secret while you're still mid-game (e.g. ~300k $/s).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local M = {}

export type RarityId =
	"common"
	| "uncommon"
	| "rare"
	| "epic"
	| "mythic"
	| "legendary"
	| "brainrot god"
	| "secret"

export type OddsResult = {
	plotIncome: number,
	maxBaseIncome: number,
	tier: number,
	weights: { [RarityId]: number },
	percents: { [RarityId]: number },
	summaryLabel: string,
}

local RARITY_ORDER: { RarityId } = {
	"common",
	"uncommon",
	"rare",
	"epic",
	"mythic",
	"legendary",
	"brainrot god",
	"secret",
}

-- Better rarities in each tier are ~3x the old mix. God/secret still only
-- appear at the highest gates (also blocked by maxAllowedBaseIncome).
local TIER_WEIGHTS: { [number]: { [RarityId]: number } } = {
	[1] = { common = 72, uncommon = 22, rare = 6, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[2] = { common = 50, uncommon = 32, rare = 18, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[3] = { common = 30, uncommon = 28, rare = 30, epic = 12, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[4] = { common = 12, uncommon = 24, rare = 30, epic = 28, mythic = 6, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[5] = { common = 4, uncommon = 12, rare = 24, epic = 32, mythic = 28, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[6] = { common = 2, uncommon = 6, rare = 16, epic = 28, mythic = 36, legendary = 12, ["brainrot god"] = 0, secret = 0 },
	[7] = { common = 0, uncommon = 2, rare = 10, epic = 24, mythic = 36, legendary = 28, ["brainrot god"] = 0, secret = 0 },
	[8] = { common = 0, uncommon = 0, rare = 6.5, epic = 18, mythic = 32, legendary = 42, ["brainrot god"] = 1.5, secret = 0 },
	[9] = { common = 0, uncommon = 0, rare = 3, epic = 13, mythic = 30, legendary = 48, ["brainrot god"] = 6, secret = 0 },
	[10] = { common = 0, uncommon = 0, rare = 0, epic = 6.1, mythic = 19, legendary = 50, ["brainrot god"] = 24, secret = 0.9 },
}

-- Plot $/s required to reach each odds tier.
-- Gates align with cheapest units of newly unlocked rarities (mythic ~6.2k base).
local TIER_INCOME: { number } = {
	0, -- 1
	150, -- 2
	750, -- 3
	4_000, -- 4  (tiny mythic tease)
	12_000, -- 5  (real mythic odds — ~2 low mythics placed)
	45_000, -- 6  (legendary tease)
	150_000, -- 7
	500_000, -- 8  (tiny god)
	1_800_000, -- 9
	6_000_000, -- 10 (tiny secret)
}

-- When a mid-tier rarity has weight, allow at least its cheapest playable unit
-- so Chances never shows 0% while the tier table says otherwise.
local FORCE_CHEAPEST_RARITIES: { [RarityId]: boolean } = {
	common = true,
	uncommon = true,
	rare = true,
	epic = true,
	mythic = true,
	legendary = true,
}

M.UI_ROW_NAMES = {
	common = "Common",
	uncommon = "Uncommon",
	rare = "Rare",
	epic = "Epic",
	mythic = "Mythical",
	legendary = "Legendary",
	["brainrot god"] = "BrainrotGod",
	secret = "Secret",
} :: { [RarityId]: string }

M.DISPLAY_NAMES = {
	common = "Common",
	uncommon = "Uncommon",
	rare = "Rare",
	epic = "Epic",
	mythic = "Mythical",
	legendary = "Legendary",
	["brainrot god"] = "Godly",
	secret = "Secret",
} :: { [RarityId]: string }

local function isPlayable(name: string): boolean
	local lower = string.lower(name)
	if string.find(lower, "easter", 1, true) then
		return false
	end
	local exclusive = StoreConfig.EXCLUSIVE_BRAINROT_NAME
	if typeof(exclusive) == "string" and string.lower(exclusive) == lower then
		return false
	end
	return true
end

function M.tierForIncome(plotIncomePerSecond: number): number
	local ips = math.max(0, plotIncomePerSecond)
	local tier = 1
	for i, need in ipairs(TIER_INCOME) do
		if ips >= need then
			tier = i
		end
	end
	return tier
end

local minIncomeByRarity: { [RarityId]: number }? = nil
local poolByRarity: { [RarityId]: { { name: string, baseIncome: number } } }? = nil

local function ensurePools()
	if poolByRarity then
		return
	end
	local pools: { [RarityId]: { { name: string, baseIncome: number } } } = {
		common = {},
		uncommon = {},
		rare = {},
		epic = {},
		mythic = {},
		legendary = {},
		["brainrot god"] = {},
		secret = {},
	}
	local mins: { [RarityId]: number } = {
		common = math.huge,
		uncommon = math.huge,
		rare = math.huge,
		epic = math.huge,
		mythic = math.huge,
		legendary = math.huge,
		["brainrot god"] = math.huge,
		secret = math.huge,
	}

	local all = BrainrotsConfig:GetAllSorted()
	for _, def in ipairs(all) do
		local name = def.name
		local rarity = string.lower(tostring(def.rarity or ""))
		local base = if typeof(def.baseIncome) == "number" then def.baseIncome else 0
		if typeof(name) ~= "string" or not isPlayable(name) then
			continue
		end
		if rarity == "godly" then
			rarity = "brainrot god"
		elseif rarity == "mythical" then
			rarity = "mythic"
		end
		local bucket = pools[rarity :: RarityId]
		if not bucket then
			continue
		end
		table.insert(bucket, { name = name, baseIncome = base })
		mins[rarity :: RarityId] = math.min(mins[rarity :: RarityId], base)
	end

	for _, id in ipairs(RARITY_ORDER) do
		if mins[id] == math.huge then
			mins[id] = 0
		end
		table.sort(pools[id], function(a, b)
			if a.baseIncome ~= b.baseIncome then
				return a.baseIncome < b.baseIncome
			end
			return a.name < b.name
		end)
	end

	poolByRarity = pools
	minIncomeByRarity = mins
end

local function filterPool(rarity: RarityId, maxBase: number): { { name: string, baseIncome: number } }
	ensurePools()
	local pools = poolByRarity :: { [RarityId]: { { name: string, baseIncome: number } } }
	local out = {}
	for _, entry in ipairs(pools[rarity]) do
		if entry.baseIncome <= maxBase then
			table.insert(out, entry)
		end
	end
	return out
end

function M.maxAllowedBaseIncome(plotIncomePerSecond: number): number
	ensurePools()
	local ips = math.max(0, plotIncomePerSecond)
	-- Soft cap keeps paid rolls as side-grades, not base-replacers.
	-- Slightly more generous than before so mid-rarities aren't stuck at 0%.
	local soft = ips * 0.30 + 80
	local hard = ips * 0.48 + 120
	local baseCap = math.max(30, math.floor(math.min(soft, hard)))

	local tier = M.tierForIncome(ips)
	local source = TIER_WEIGHTS[tier] or TIER_WEIGHTS[1]
	local mins = minIncomeByRarity :: { [RarityId]: number }
	local need = baseCap
	-- Plot-relative ceiling so forcing cheapest mythic/legendary never goes crazy.
	local plotCap = math.floor(ips * 0.65 + 150)

	for _, id in ipairs(RARITY_ORDER) do
		local w = source[id] or 0
		if w > 0 and FORCE_CHEAPEST_RARITIES[id] then
			local minBase = mins[id] or 0
			if minBase > 0 then
				need = math.max(need, math.min(minBase, plotCap))
			end
		end
	end

	return need
end

function M.compute(plotIncomePerSecond: number): OddsResult
	ensurePools()
	local ips = math.max(0, plotIncomePerSecond)
	local maxBase = M.maxAllowedBaseIncome(ips)
	local tier = M.tierForIncome(ips)
	local raw = {}
	local source = TIER_WEIGHTS[tier] or TIER_WEIGHTS[1]
	for k, v in source do
		raw[k] = v
	end

	-- Zero rarities whose cheapest playable unit exceeds the income cap.
	local mins = minIncomeByRarity :: { [RarityId]: number }
	for _, id in ipairs(RARITY_ORDER) do
		local w = raw[id] or 0
		if w > 0 and (mins[id] <= 0 or mins[id] > maxBase or #filterPool(id, maxBase) == 0) then
			raw[id] = 0
		end
	end

	local total = 0
	for _, id in ipairs(RARITY_ORDER) do
		total += raw[id] or 0
	end
	if total <= 0 then
		raw.common = 100
		total = 100
	end

	local percents: { [RarityId]: number } = {}
	for _, id in ipairs(RARITY_ORDER) do
		local w = raw[id] or 0
		percents[id] = if total > 0 then (w / total) * 100 else 0
	end

	local enabled: { string } = {}
	for _, id in ipairs(RARITY_ORDER) do
		if (percents[id] or 0) > 0.05 then
			table.insert(enabled, M.DISPLAY_NAMES[id])
		end
	end
	local summary = if #enabled == 0 then "Common"
		elseif #enabled == 1 then enabled[1]
		else `{enabled[1]}-{enabled[#enabled]}`

	return {
		plotIncome = ips,
		maxBaseIncome = maxBase,
		tier = tier,
		weights = raw,
		percents = percents,
		summaryLabel = summary,
	}
end

function M.formatPercent(pct: number): string
	if pct <= 0 then
		return "0%"
	end
	if pct >= 10 then
		return string.format("%.0f%%", pct)
	end
	if pct >= 1 then
		return string.format("%.1f%%", pct)
	end
	return string.format("%.2f%%", pct)
end

local function weightedPick(weights: { [RarityId]: number }): RarityId?
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local r = math.random() * total
	local acc = 0
	for _, id in ipairs(RARITY_ORDER) do
		local w = weights[id] or 0
		if w > 0 then
			acc += w
			if r <= acc then
				return id
			end
		end
	end
	return nil
end

function M.pickName(plotIncomePerSecond: number): string?
	local odds = M.compute(plotIncomePerSecond)
	local maxBase = odds.maxBaseIncome
	local rarity = weightedPick(odds.weights)
	if not rarity then
		rarity = "common"
	end

	local pool = filterPool(rarity, maxBase)
	if #pool == 0 then
		for i = #RARITY_ORDER, 1, -1 do
			local id = RARITY_ORDER[i]
			pool = filterPool(id, maxBase)
			if #pool > 0 then
				break
			end
		end
	end
	if #pool == 0 then
		return nil
	end

	-- Strong bias to the cheap end of the allowed band.
	local roll = math.random()
	local idx: number
	if roll < 0.78 then
		idx = math.random(1, math.max(1, math.ceil(#pool * 0.22)))
	elseif roll < 0.96 then
		idx = math.random(1, math.max(1, math.ceil(#pool * 0.45)))
	else
		idx = math.random(1, math.max(1, math.ceil(#pool * 0.65)))
	end
	return pool[idx].name
end

return M
