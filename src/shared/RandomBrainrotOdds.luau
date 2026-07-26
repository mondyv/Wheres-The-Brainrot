-- [ACTIVE] RandomBrainrotOdds
--[[
	Scales Random Brainrot product odds by the player's current plot $/s.
	Shared by server grants and client Chances UI so they stay in sync.
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

-- Same land-style tables as bush harvest, keyed by income tier 1–10.
-- Late tiers keep mythic/legendary playable but crush god/secret vs older tables.
local TIER_WEIGHTS: { [number]: { [RarityId]: number } } = {
	[1] = { common = 75, uncommon = 25, rare = 0, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[2] = { common = 55, uncommon = 35, rare = 10, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[3] = { common = 35, uncommon = 35, rare = 22, epic = 8, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[4] = { common = 25, uncommon = 28, rare = 25, epic = 15, mythic = 7, legendary = 0, ["brainrot god"] = 0, secret = 0 },
	[5] = { common = 5, uncommon = 22, rare = 28, epic = 25, mythic = 18, legendary = 2, ["brainrot god"] = 0, secret = 0 },
	[6] = { common = 0, uncommon = 8, rare = 28, epic = 30, mythic = 24, legendary = 10, ["brainrot god"] = 0, secret = 0 },
	[7] = { common = 0, uncommon = 0, rare = 12, epic = 32, mythic = 32, legendary = 20, ["brainrot god"] = 4, secret = 0 },
	[8] = { common = 0, uncommon = 0, rare = 0, epic = 18, mythic = 38, legendary = 32, ["brainrot god"] = 10, secret = 2 },
	[9] = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 28, legendary = 42, ["brainrot god"] = 22, secret = 8 },
	[10] = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 15, legendary = 45, ["brainrot god"] = 28, secret = 12 },
}

-- Plot $/s thresholds → tier (must keep Random Brainrot below runaway god/secret rolls early).
local TIER_INCOME: { number } = {
	0,
	40,
	120,
	350,
	900,
	2500,
	10000,
	40000,
	150000,
	500000,
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

function M.maxAllowedBaseIncome(plotIncomePerSecond: number): number
	local ips = math.max(0, plotIncomePerSecond)
	-- Early game floor so empty plots still get commons; hard ceiling vs current gen.
	return math.max(45, ips * 1.35 + 20)
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
		-- Normalize mythic/god aliases
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

	-- Guarantee at least one viable rarity (commons always exist under the floor).
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

	-- Prefer mid/low incomes inside the allowed band (not always the top of the cap).
	local roll = math.random()
	local idx: number
	if roll < 0.55 then
		idx = math.random(1, math.max(1, math.ceil(#pool * 0.45)))
	elseif roll < 0.9 then
		idx = math.random(1, math.max(1, math.ceil(#pool * 0.8)))
	else
		idx = math.random(1, #pool)
	end
	return pool[idx].name
end

return M
