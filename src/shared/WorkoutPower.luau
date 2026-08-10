-- [ACTIVE] WorkoutPower
-- Workout Power drives swing force + reach (combined). Carry stays fixed at 1.
local SwingProgression = require(script.Parent.SwingProgression)
local SwingUpgrades = require(script.Parent.SwingUpgrades)
local GearConfig = require(script.Parent.GearConfig)

local M = {}

M.POWER_ATTR = GearConfig.POWER_ATTR
M.POWER_EDITED_ATTR = GearConfig.POWER_EDITED_ATTR
M.FIXED_CARRY = 1

-- Map absolute workout Power → swing upgrade level used by SwingProgression.
-- Soft log so early Tree Branch (+2/s) matters and late Jupiter (+300k/s) does not explode.
function M.swingLevelFromPower(power: number): number
	local p = math.max(0, power)
	if p <= 0 then
		return 0
	end
	-- ~Power 10 → ~8, Power 100 → ~40, Power 10k → ~120, Power 1e6 → ~200, Power 1e8 → ~280
	local level = math.floor(55 * math.log10(1 + p / 8))
	return math.clamp(level, 0, 100_000)
end

function M.readPower(player: Player): number
	local v = player:GetAttribute(M.POWER_ATTR)
	if typeof(v) == "number" then
		return math.max(0, v)
	end
	return 0
end

function M.isEdited(player: Player): boolean
	return player:GetAttribute(M.POWER_EDITED_ATTR) == true
end

function M.migratePowerFromLegacyLevels(powerLevel: number, ropeLevel: number): number
	local p = SwingProgression.displayPower(powerLevel)
	local r = SwingProgression.displayReach(ropeLevel)
	-- Combined seed so existing players keep roughly the same swing feel.
	return math.max(0, (p - 10) + (r - 10))
end

function M.syncSwingFromPower(player: Player)
	local power = M.readPower(player)
	local level = M.swingLevelFromPower(power)
	player:SetAttribute(SwingUpgrades.POWER_LEVEL_ATTR, level)
	player:SetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR, level)
	-- Carry upgrade removed — always 1 brainrot.
	player:SetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR, 0)
	player:SetAttribute("SwingForce", SwingProgression.displayPower(level))
	player:SetAttribute("SwingRange", SwingProgression.displayReach(level))
	player:SetAttribute("Carry", M.FIXED_CARRY)
end

function M.setPower(player: Player, amount: number, edited: boolean?)
	local n = math.max(0, math.floor(amount))
	player:SetAttribute(M.POWER_ATTR, n)
	if edited == true then
		player:SetAttribute(M.POWER_EDITED_ATTR, true)
	elseif edited == false then
		player:SetAttribute(M.POWER_EDITED_ATTR, false)
	end
	M.syncSwingFromPower(player)
end

function M.addPower(player: Player, delta: number)
	if delta == 0 then
		return M.readPower(player)
	end
	-- Manual edits stick until cleared; workout still adds on top.
	local nextPower = M.readPower(player) + delta
	player:SetAttribute(M.POWER_ATTR, math.max(0, math.floor(nextPower)))
	M.syncSwingFromPower(player)
	return M.readPower(player)
end

function M.initPlayerPower(player: Player)
	if player:GetAttribute(M.POWER_ATTR) == nil then
		local powerLevel = player:GetAttribute(SwingUpgrades.POWER_LEVEL_ATTR)
		local ropeLevel = player:GetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR)
		local pl = if typeof(powerLevel) == "number" then powerLevel else 0
		local rl = if typeof(ropeLevel) == "number" then ropeLevel else 0
		player:SetAttribute(M.POWER_ATTR, M.migratePowerFromLegacyLevels(pl, rl))
	end
	if player:GetAttribute(M.POWER_EDITED_ATTR) == nil then
		player:SetAttribute(M.POWER_EDITED_ATTR, false)
	end
	if player:GetAttribute(GearConfig.OWNED_GEARS_ATTR) == nil then
		player:SetAttribute(GearConfig.OWNED_GEARS_ATTR, "")
	end
	if player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR) == nil then
		player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, 0)
	end
	M.syncSwingFromPower(player)
end

return M
