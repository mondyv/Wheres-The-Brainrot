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
	-- Cash prices for Power / Reach come from upgradeLevelForAttr + cost formulas below (not per-row `cost`).
	Power10 = { attr = "SwingForce", add = 1, displayAdd = 10 } :: UpgradeDef,
	Power25 = { attr = "SwingForce", add = 2, displayAdd = 25 } :: UpgradeDef,
	Reach10 = { attr = "SwingRange", add = 1, displayAdd = 10 } :: UpgradeDef,
	Reach25 = { attr = "SwingRange", add = 2, displayAdd = 25 } :: UpgradeDef,
	Carry1 = { attr = "Carry", add = 1, displayAdd = 1, cost = 500_000, priceGrowth = 1.5 } :: UpgradeDef,
}

local ALL_IDS = { "Power10", "Power25", "Reach10", "Reach25", "Carry1" }

local function growth(def: UpgradeDef): number
	return def.priceGrowth or 1.5
end

local M = {}

M.SKIP_UPGRADE_DEV_PRODUCT_ID = 3598819972

-- Power (SwingForce): separate level from rope; +10 / +25 share PowerUpgradeLevel.
M.MAX_POWER_UPGRADE_LEVEL = 300
M.POWER_COST_BASE = 100
M.POWER_COST_GROWTH = 1.11

-- Rope distance (SwingRange): separate level from power; +10 / +25 share RopeUpgradeLevel.
M.MAX_ROPE_UPGRADE_LEVEL = 100
M.ROPE_COST_BASE = 2500
M.ROPE_COST_GROWTH = 1.22

function M.priceAtTier(def: UpgradeDef, purchaseCount: number): number
	local n = math.max(0, math.floor(purchaseCount))
	return math.floor((def.cost or 0) * (growth(def) ^ n))
end

-- How many cash upgrades already bought for this stat (+10 and +25 rows count together).
function M.upgradeLevelForAttr(attr: string, getBuyCount: (string) -> number): number
	local sum = 0
	for _, id in ALL_IDS do
		local def = DEFS[id]
		if def and def.attr == attr then
			sum += math.max(0, math.floor(getBuyCount(id)))
		end
	end
	return sum
end

function M.totalBuysForAttr(attr: string, getBuyCount: (string) -> number): number
	return M.upgradeLevelForAttr(attr, getBuyCount)
end

function M.powerUpgradeCost(powerUpgradeLevel: number): number
	local level = math.max(0, math.floor(powerUpgradeLevel))
	return math.floor(M.POWER_COST_BASE * (M.POWER_COST_GROWTH ^ level) + 0.5)
end

function M.ropeUpgradeCost(ropeUpgradeLevel: number): number
	local level = math.max(0, math.floor(ropeUpgradeLevel))
	return math.floor(M.ROPE_COST_BASE * (M.ROPE_COST_GROWTH ^ level) + 0.5)
end

function M.maxLevelForAttr(attr: string): number?
	if attr == "SwingForce" then
		return M.MAX_POWER_UPGRADE_LEVEL
	end
	if attr == "SwingRange" then
		return M.MAX_ROPE_UPGRADE_LEVEL
	end
	return nil
end

function M.isUpgradeMaxed(upgradeId: string, getBuyCount: (string) -> number): boolean
	local def = DEFS[upgradeId]
	if not def then
		return true
	end
	local cap = M.maxLevelForAttr(def.attr)
	if not cap then
		return false
	end
	return M.upgradeLevelForAttr(def.attr, getBuyCount) >= cap
end

function M.priceForUpgradeId(upgradeId: string, getBuyCount: (string) -> number): number
	local def = DEFS[upgradeId]
	if not def then
		return 0
	end
	if M.isUpgradeMaxed(upgradeId, getBuyCount) then
		return 0
	end
	if def.attr == "SwingForce" then
		return M.powerUpgradeCost(M.upgradeLevelForAttr("SwingForce", getBuyCount))
	end
	if def.attr == "SwingRange" then
		return M.ropeUpgradeCost(M.upgradeLevelForAttr("SwingRange", getBuyCount))
	end
	return M.priceAtTier(def, math.max(0, math.floor(getBuyCount(upgradeId))))
end

function M.buysAttributeName(upgradeId: string): string
	return "Buys_" .. upgradeId
end

function M.displayBonus(def: UpgradeDef): number
	return if typeof(def.displayAdd) == "number" then def.displayAdd else def.add
end

-- UI stat total: starter shows 1; after any purchase, sum display bonuses for that attribute.
function M.displayStatTotal(attr: string, getBuyCount: (string) -> number): number
	local sum = 0
	for _, id in ALL_IDS do
		local def = DEFS[id]
		if def and def.attr == attr then
			sum += M.displayBonus(def) * math.max(0, math.floor(getBuyCount(id)))
		end
	end
	return if sum > 0 then sum else 1
end

-- Next tier label: 1 → +25 shows 25 (not 26); +1 carry still goes 1 → 2.
function M.displayStatAfterPurchase(current: number, bonus: number): number
	local cur = math.floor(current)
	if cur <= 1 and bonus > 1 then
		return bonus
	end
	return cur + bonus
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
