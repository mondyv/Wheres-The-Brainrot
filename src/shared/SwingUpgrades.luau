-- Shared config: cash swing upgrades (must match server + client)
local SwingProgression = require(script.Parent.SwingProgression)

export type UpgradeId = "Power10" | "Power25" | "Reach10" | "Reach25" | "Carry1" | "Power1" | "Reach1"

export type UpgradeLevels = {
	power: number,
	rope: number,
	carry: number,
}

export type UpgradeDef = {
	attr: string,
	units: number,
	levelAttr: string,
}

local DEFS: { [string]: UpgradeDef } = {
	Power10 = { attr = "SwingForce", units = 10, levelAttr = "PowerUpgradeLevel" } :: UpgradeDef,
	Power25 = { attr = "SwingForce", units = 25, levelAttr = "PowerUpgradeLevel" } :: UpgradeDef,
	Reach10 = { attr = "SwingRange", units = 10, levelAttr = "RopeUpgradeLevel" } :: UpgradeDef,
	Reach25 = { attr = "SwingRange", units = 25, levelAttr = "RopeUpgradeLevel" } :: UpgradeDef,
	Carry1 = { attr = "Carry", units = 1, levelAttr = "CarryUpgradeLevel" } :: UpgradeDef,
	-- Legacy ids (Robux receipts)
	Power1 = { attr = "SwingForce", units = 1, levelAttr = "PowerUpgradeLevel" } :: UpgradeDef,
	Reach1 = { attr = "SwingRange", units = 1, levelAttr = "RopeUpgradeLevel" } :: UpgradeDef,
}

local M = {}

M.SKIP_UPGRADE_DEV_PRODUCT_ID = 3598819972

M.POWER_LEVEL_ATTR = "PowerUpgradeLevel"
M.ROPE_LEVEL_ATTR = "RopeUpgradeLevel"
M.CARRY_LEVEL_ATTR = "CarryUpgradeLevel"

M.MAX_CARRY_UPGRADE_LEVEL = 10

M.POWER_COST_BASE = 20
M.POWER_COST_GROWTH = 1.07

M.ROPE_COST_BASE = 20
M.ROPE_COST_GROWTH = 1.075

M.CARRY_COST_BASE = 1_000_000
M.CARRY_COST_GROWTH = 2.5

local function floorLevel(n: number): number
	return math.max(0, math.floor(n))
end

function M.readLevels(getAttr: (name: string) -> any): UpgradeLevels
	local function level(name: string): number
		local v = getAttr(name)
		return if typeof(v) == "number" then floorLevel(v) else 0
	end
	return {
		power = level(M.POWER_LEVEL_ATTR),
		rope = level(M.ROPE_LEVEL_ATTR),
		carry = level(M.CARRY_LEVEL_ATTR),
	}
end

function M.levelForUpgradeId(upgradeId: string, levels: UpgradeLevels): number
	local def = DEFS[upgradeId]
	if not def then
		return 0
	end
	if def.levelAttr == M.POWER_LEVEL_ATTR then
		return levels.power
	end
	if def.levelAttr == M.ROPE_LEVEL_ATTR then
		return levels.rope
	end
	if def.levelAttr == M.CARRY_LEVEL_ATTR then
		return levels.carry
	end
	return 0
end

function M.powerUnitCost(powerUpgradeLevel: number): number
	local level = floorLevel(powerUpgradeLevel)
	return math.floor(M.POWER_COST_BASE * (M.POWER_COST_GROWTH ^ level) + 0.5)
end

function M.ropeUnitCost(ropeUpgradeLevel: number): number
	local level = floorLevel(ropeUpgradeLevel)
	return math.floor(M.ROPE_COST_BASE * (M.ROPE_COST_GROWTH ^ level) + 0.5)
end

function M.carryUnitCost(carryUpgradeLevel: number): number
	local level = floorLevel(carryUpgradeLevel)
	return math.floor(M.CARRY_COST_BASE * (M.CARRY_COST_GROWTH ^ level) + 0.5)
end

function M.sumUnitCosts(unitCost: (level: number) -> number, startLevel: number, count: number): number
	local start = floorLevel(startLevel)
	local n = math.max(0, math.floor(count))
	local total = 0
	for i = 0, n - 1 do
		total += unitCost(start + i)
	end
	return total
end

function M.unitCostForLevelAttr(levelAttr: string, level: number): number
	if levelAttr == M.POWER_LEVEL_ATTR then
		return M.powerUnitCost(level)
	end
	if levelAttr == M.ROPE_LEVEL_ATTR then
		return M.ropeUnitCost(level)
	end
	if levelAttr == M.CARRY_LEVEL_ATTR then
		return M.carryUnitCost(level)
	end
	return 0
end

function M.batchPriceForUpgradeId(upgradeId: string, levels: UpgradeLevels): number
	local def = DEFS[upgradeId]
	if not def then
		return 0
	end
	local current = M.levelForUpgradeId(upgradeId, levels)
	return M.sumUnitCosts(function(level: number)
		return M.unitCostForLevelAttr(def.levelAttr, level)
	end, current, def.units)
end

function M.wouldExceedMax(upgradeId: string, levels: UpgradeLevels): boolean
	local def = DEFS[upgradeId]
	if not def then
		return true
	end
	if def.levelAttr == M.CARRY_LEVEL_ATTR then
		return levels.carry + def.units > M.MAX_CARRY_UPGRADE_LEVEL
	end
	return false
end

function M.isUpgradeMaxed(upgradeId: string, levels: UpgradeLevels): boolean
	return M.wouldExceedMax(upgradeId, levels)
end

function M.priceForUpgradeId(upgradeId: string, levels: UpgradeLevels): number
	if M.isUpgradeMaxed(upgradeId, levels) then
		return 0
	end
	return M.batchPriceForUpgradeId(upgradeId, levels)
end

function M.displayStatForLevel(level: number, levelAttr: string?): number
	local lv = floorLevel(level)
	if levelAttr == M.POWER_LEVEL_ATTR then
		return SwingProgression.displayPower(lv)
	end
	if levelAttr == M.ROPE_LEVEL_ATTR then
		return SwingProgression.displayReach(lv)
	end
	if levelAttr == M.CARRY_LEVEL_ATTR then
		return SwingProgression.displayCarry(lv)
	end
	return SwingProgression.displayPower(lv)
end

function M.displayStatAfterPurchase(currentLevel: number, units: number, levelAttr: string?): number
	return M.displayStatForLevel(floorLevel(currentLevel) + math.max(0, math.floor(units)), levelAttr)
end

function M.displayBonus(def: UpgradeDef): number
	return SwingProgression.displayBonusForUnits(def.levelAttr, def.units)
end

function M.syncGameplayStatsFromLevels(player: Player, levels: UpgradeLevels)
	player:SetAttribute("SwingForce", M.displayStatForLevel(levels.power, M.POWER_LEVEL_ATTR))
	player:SetAttribute("SwingRange", M.displayStatForLevel(levels.rope, M.ROPE_LEVEL_ATTR))
	player:SetAttribute("Carry", M.displayStatForLevel(levels.carry, M.CARRY_LEVEL_ATTR))
end

function M.grantUpgrade(player: Player, upgradeId: string): boolean
	local def = DEFS[upgradeId]
	if not def then
		return false
	end
	local levels = M.readLevels(function(name: string)
		return player:GetAttribute(name)
	end)
	if M.wouldExceedMax(upgradeId, levels) then
		return false
	end

	if def.levelAttr == M.POWER_LEVEL_ATTR then
		levels.power += def.units
		player:SetAttribute(M.POWER_LEVEL_ATTR, levels.power)
	elseif def.levelAttr == M.ROPE_LEVEL_ATTR then
		levels.rope += def.units
		player:SetAttribute(M.ROPE_LEVEL_ATTR, levels.rope)
	elseif def.levelAttr == M.CARRY_LEVEL_ATTR then
		levels.carry += def.units
		player:SetAttribute(M.CARRY_LEVEL_ATTR, levels.carry)
	end

	M.syncGameplayStatsFromLevels(player, levels)
	return true
end

function M.initLevelAttributes(player: Player)
	if player:GetAttribute(M.POWER_LEVEL_ATTR) == nil then
		local legacy = SwingProgression.levelFromLegacyDisplay("SwingForce", player:GetAttribute("SwingForce"))
		player:SetAttribute(M.POWER_LEVEL_ATTR, legacy)
	end
	if player:GetAttribute(M.ROPE_LEVEL_ATTR) == nil then
		local legacy = SwingProgression.levelFromLegacyDisplay("SwingRange", player:GetAttribute("SwingRange"))
		player:SetAttribute(M.ROPE_LEVEL_ATTR, legacy)
	end
	if player:GetAttribute(M.CARRY_LEVEL_ATTR) == nil then
		local legacy = SwingProgression.levelFromLegacyDisplay("Carry", player:GetAttribute("Carry"))
		player:SetAttribute(M.CARRY_LEVEL_ATTR, legacy)
	end

	local levels = M.readLevels(function(name: string)
		return player:GetAttribute(name)
	end)
	M.syncGameplayStatsFromLevels(player, levels)
end

function M.resetLevels(player: Player)
	player:SetAttribute(M.POWER_LEVEL_ATTR, 0)
	player:SetAttribute(M.ROPE_LEVEL_ATTR, 0)
	player:SetAttribute(M.CARRY_LEVEL_ATTR, 0)
	player:SetAttribute("RopeLength", 0)
	M.syncGameplayStatsFromLevels(player, { power = 0, rope = 0, carry = 0 })
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
