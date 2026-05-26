-- Shared config: cash swing upgrades (must match server + client)
export type UpgradeId = "Power10" | "Power25" | "Reach10" | "Reach25" | "Carry1"

export type UpgradeDef = {
	attr: string,
	add: number, -- real stat gain (authoritative, balanced)
	displayAdd: number?, -- UI only: Amount label shows +10 / +25; gameplay tuning is separate in SwingSystem
	cost: number,
	priceGrowth: number?,
}

local DEFS: { [string]: UpgradeDef } = {
	-- `add` = authoritative gameplay (halved vs earlier tuning); `displayAdd` = UI labels + before→after counters.
	Power10 = { attr = "SwingForce", add = 1, displayAdd = 10, cost = 10_000, priceGrowth = 1.14 } :: UpgradeDef,
	Power25 = { attr = "SwingForce", add = 2, displayAdd = 25, cost = 30_000, priceGrowth = 1.14 } :: UpgradeDef,
	Reach10 = { attr = "SwingRange", add = 1, displayAdd = 10, cost = 10_000, priceGrowth = 1.14 } :: UpgradeDef,
	Reach25 = { attr = "SwingRange", add = 2, displayAdd = 25, cost = 30_000, priceGrowth = 1.14 } :: UpgradeDef,
	Carry1 = { attr = "Carry", add = 1, displayAdd = 1, cost = 500_000, priceGrowth = 1.12 } :: UpgradeDef,
}

local ALL_IDS = { "Power10", "Power25", "Reach10", "Reach25", "Carry1" }

local function growth(def: UpgradeDef): number
	return def.priceGrowth or 1.14
end

local M = {}

M.SKIP_UPGRADE_DEV_PRODUCT_ID = 3598819972

function M.priceAtTier(def: UpgradeDef, purchaseCount: number): number
	local n = math.max(0, math.floor(purchaseCount))
	return math.floor(def.cost * (growth(def) ^ n))
end

function M.buysAttributeName(upgradeId: string): string
	return "Buys_" .. upgradeId
end

function M.displayBonus(def: UpgradeDef): number
	return if typeof(def.displayAdd) == "number" then def.displayAdd else def.add
end

-- UI stat total (1 base + sum of display bonuses purchased for that attribute).
function M.displayStatTotal(attr: string, getBuyCount: (string) -> number): number
	local total = 1
	for _, id in ALL_IDS do
		local def = DEFS[id]
		if def and def.attr == attr then
			total += M.displayBonus(def) * math.max(0, math.floor(getBuyCount(id)))
		end
	end
	return total
end

for id, def in DEFS do
	M[id] = def
end

-- ── Plot / land luck (display ÷ 3 = actual; 1x = no gradient) ─────────────────

local PlotLuck = {}

PlotLuck.DISPLAY_TIERS = { 1, 10, 50, 150, 450, 750, 1250, 1750 } :: { number }
PlotLuck.HITBOX_NAME_PATTERN = "^(%d+)xHitbox$"

function PlotLuck.parseHitboxDisplayLuck(hitboxName: string): number?
	local raw = string.match(hitboxName, PlotLuck.HITBOX_NAME_PATTERN)
	if not raw then
		return nil
	end
	local n = tonumber(raw)
	if not n or n < 1 then
		return nil
	end
	return n
end

function PlotLuck.gradientNameForDisplay(displayLuck: number): string?
	if displayLuck <= 1 then
		return nil
	end
	return tostring(math.floor(displayLuck + 0.5)) .. "X"
end

function PlotLuck.actualLuck(displayLuck: number): number
	if displayLuck <= 1 then
		return 1
	end
	return displayLuck / 3
end

function PlotLuck.tierIndex(displayLuck: number): number
	local bestIdx = 1
	local bestDiff = math.huge
	for i, tier in ipairs(PlotLuck.DISPLAY_TIERS) do
		local diff = math.abs(tier - displayLuck)
		if diff < bestDiff then
			bestDiff = diff
			bestIdx = i
		end
	end
	return bestIdx
end

function PlotLuck.effectivePlot(basePlot: number, displayLuck: number, maxPlot: number): number
	local base = math.clamp(math.floor(basePlot), 1, maxPlot)
	local actual = PlotLuck.actualLuck(displayLuck)
	if actual <= 1 then
		return base
	end
	local boost = math.log10(actual) * 1.35
	return math.clamp(math.floor(base + boost + 0.5), 1, maxPlot)
end

M.PlotLuck = PlotLuck

return M
