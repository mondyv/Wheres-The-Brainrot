-- Shared config: cash swing upgrades (must match server + client)
local SwingProgression = require(script.Parent.SwingProgression)

export type UpgradeId = "Power10" | "Reach25" | "Carry1" | "Power1" | "Power25" | "Reach1" | "Reach10"

export type UpgradeLevels = {
	power: number,
	rope: number,
	carry: number,
}

export type UpgradeDef = {
	attr: string,
	levelAttr: string,
	statBonus: number, -- display stat added per purchase (+10 power, +25 reach, etc.)
}

local DEFS: { [string]: UpgradeDef } = {
	Power10 = { attr = "SwingForce", levelAttr = "PowerUpgradeLevel", statBonus = 10 } :: UpgradeDef,
	Reach25 = { attr = "SwingRange", levelAttr = "RopeUpgradeLevel", statBonus = 25 } :: UpgradeDef,
	Carry1 = { attr = "Carry", levelAttr = "CarryUpgradeLevel", statBonus = 1 } :: UpgradeDef,
	-- Legacy ids (Robux / old UI): same +1 purchase level as the primary rows
	Power1 = { attr = "SwingForce", levelAttr = "PowerUpgradeLevel", statBonus = 10 } :: UpgradeDef,
	Power25 = { attr = "SwingForce", levelAttr = "PowerUpgradeLevel", statBonus = 10 } :: UpgradeDef,
	Reach1 = { attr = "SwingRange", levelAttr = "RopeUpgradeLevel", statBonus = 25 } :: UpgradeDef,
	Reach10 = { attr = "SwingRange", levelAttr = "RopeUpgradeLevel", statBonus = 25 } :: UpgradeDef,
}

local ALL_IDS = { "Power10", "Reach25", "Carry1", "Power1", "Power25", "Reach1", "Reach10" }

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

function M.maxLevelForUpgradeId(upgradeId: string): number
	local def = DEFS[upgradeId]
	if not def then
		return 0
	end
	if def.levelAttr == M.CARRY_LEVEL_ATTR then
		return M.MAX_CARRY_UPGRADE_LEVEL
	end
	return math.huge
end

function M.powerUpgradeCost(powerUpgradeLevel: number): number
	local level = floorLevel(powerUpgradeLevel)
	return math.floor(M.POWER_COST_BASE * (M.POWER_COST_GROWTH ^ level) + 0.5)
end

function M.ropeUpgradeCost(ropeUpgradeLevel: number): number
	local level = floorLevel(ropeUpgradeLevel)
	return math.floor(M.ROPE_COST_BASE * (M.ROPE_COST_GROWTH ^ level) + 0.5)
end

function M.carryUnitCost(carryUpgradeLevel: number): number
	local level = floorLevel(carryUpgradeLevel)
	return math.floor(M.CARRY_COST_BASE * (M.CARRY_COST_GROWTH ^ level) + 0.5)
end

function M.unitCostForLevelAttr(levelAttr: string, level: number): number
	if levelAttr == M.POWER_LEVEL_ATTR then
		return M.powerUpgradeCost(level)
	end
	if levelAttr == M.ROPE_LEVEL_ATTR then
		return M.ropeUpgradeCost(level)
	end
	if levelAttr == M.CARRY_LEVEL_ATTR then
		return M.carryUnitCost(level)
	end
	return 0
end

function M.wouldExceedMax(upgradeId: string, levels: UpgradeLevels): boolean
	local def = DEFS[upgradeId]
	if not def then
		return true
	end
	if def.levelAttr == M.CARRY_LEVEL_ATTR then
		return levels.carry + 1 > M.MAX_CARRY_UPGRADE_LEVEL
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
	local def = DEFS[upgradeId]
	if not def then
		return 0
	end
	local current = M.levelForUpgradeId(upgradeId, levels)
	return M.unitCostForLevelAttr(def.levelAttr, current)
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

function M.displayStatAfterPurchase(currentLevel: number, _units: number, levelAttr: string?): number
	return M.displayStatForLevel(floorLevel(currentLevel) + 1, levelAttr)
end

function M.displayBonus(def: UpgradeDef): number
	return def.statBonus
end

function M.syncGameplayStatsFromLevels(player: Player, levels: UpgradeLevels)
	player:SetAttribute("SwingForce", M.displayStatForLevel(levels.power, M.POWER_LEVEL_ATTR))
	player:SetAttribute("SwingRange", M.displayStatForLevel(levels.rope, M.ROPE_LEVEL_ATTR))
	player:SetAttribute("Carry", M.displayStatForLevel(levels.carry, M.CARRY_LEVEL_ATTR))
end

local function purchaseLevelFromDisplay(display: number, base: number, step: number, rawLevel: number?): number
	local delta = math.max(0, math.floor(display) - base)
	if delta == 0 then
		return 0
	end
	if delta % step == 0 then
		local asNew = delta // step
		if typeof(rawLevel) == "number" and floorLevel(rawLevel) == delta then
			return delta
		end
		return asNew
	end
	return delta
end

local function migrateLevelFromDisplay(player: Player, levelAttr: string, displayAttr: string, step: number, base: number)
	local display = player:GetAttribute(displayAttr)
	if typeof(display) ~= "number" then
		return
	end
	local raw = player:GetAttribute(levelAttr)
	local derived = purchaseLevelFromDisplay(display, base, step, if typeof(raw) == "number" then raw else nil)
	player:SetAttribute(levelAttr, derived)
end

local function migrateLegacyUnitLevels(player: Player, levelAttr: string, displayAttr: string, step: number)
	if player:GetAttribute(displayAttr) ~= nil then
		return
	end
	local raw = player:GetAttribute(levelAttr)
	if typeof(raw) ~= "number" or raw <= 0 then
		return
	end
	local floored = floorLevel(raw)
	if floored >= step and floored % step == 0 then
		player:SetAttribute(levelAttr, math.floor(floored / step + 0.5))
	end
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
		levels.power += 1
		player:SetAttribute(M.POWER_LEVEL_ATTR, levels.power)
	elseif def.levelAttr == M.ROPE_LEVEL_ATTR then
		levels.rope += 1
		player:SetAttribute(M.ROPE_LEVEL_ATTR, levels.rope)
	elseif def.levelAttr == M.CARRY_LEVEL_ATTR then
		levels.carry += 1
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

	migrateLevelFromDisplay(player, M.POWER_LEVEL_ATTR, "SwingForce", SwingProgression.POWER_DISPLAY_STEP, SwingProgression.POWER_DISPLAY_BASE)
	migrateLevelFromDisplay(player, M.ROPE_LEVEL_ATTR, "SwingRange", SwingProgression.REACH_DISPLAY_STEP, SwingProgression.REACH_DISPLAY_BASE)
	migrateLegacyUnitLevels(player, M.POWER_LEVEL_ATTR, "SwingForce", 10)
	migrateLegacyUnitLevels(player, M.ROPE_LEVEL_ATTR, "SwingRange", 25)

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
