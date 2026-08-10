-- [ACTIVE] WorkoutPower
-- Workout Power drives swing force + reach (combined). Carry stays fixed at 1.
-- PowerMax = true ceiling from workouts; Power = active (may be edited down).
local SwingProgression = require(script.Parent.SwingProgression)
local SwingUpgrades = require(script.Parent.SwingUpgrades)
local GearConfig = require(script.Parent.GearConfig)

local M = {}

M.POWER_ATTR = GearConfig.POWER_ATTR
M.POWER_MAX_ATTR = GearConfig.POWER_MAX_ATTR
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

function M.readPowerMax(player: Player): number
	local v = player:GetAttribute(M.POWER_MAX_ATTR)
	if typeof(v) == "number" then
		return math.max(0, v)
	end
	-- Legacy: no max stored yet — treat active Power as the ceiling.
	return M.readPower(player)
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

local function ensureMaxAtLeast(player: Player, floorValue: number)
	local maxP = math.max(M.readPowerMax(player), math.max(0, math.floor(floorValue)))
	player:SetAttribute(M.POWER_MAX_ATTR, maxP)
	return maxP
end

-- Set active Power (clamped to PowerMax). edited=true keeps (Edited); full max clears it.
function M.setPower(player: Player, amount: number, edited: boolean?)
	local maxP = ensureMaxAtLeast(player, M.readPower(player))
	local n = math.clamp(math.floor(amount), 0, math.floor(maxP))
	player:SetAttribute(M.POWER_ATTR, n)
	local atMax = n >= math.floor(maxP)
	if edited == false or atMax then
		player:SetAttribute(M.POWER_EDITED_ATTR, false)
		-- Restoring to max keeps active in sync with ceiling.
		if atMax then
			player:SetAttribute(M.POWER_ATTR, math.floor(maxP))
		end
	elseif edited == true then
		player:SetAttribute(M.POWER_EDITED_ATTR, true)
	end
	M.syncSwingFromPower(player)
end

-- Absolute set used by admin / migrations: raises ceiling and active together.
function M.setPowerAbsolute(player: Player, amount: number, edited: boolean?)
	local n = math.max(0, math.floor(amount))
	player:SetAttribute(M.POWER_MAX_ATTR, n)
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
	local maxP = math.max(0, math.floor(M.readPowerMax(player) + delta))
	player:SetAttribute(M.POWER_MAX_ATTR, maxP)
	-- Edited players keep their chosen active Power; workouts only raise the ceiling.
	if not M.isEdited(player) then
		player:SetAttribute(M.POWER_ATTR, maxP)
	end
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
	if player:GetAttribute(M.POWER_MAX_ATTR) == nil then
		player:SetAttribute(M.POWER_MAX_ATTR, M.readPower(player))
	else
		ensureMaxAtLeast(player, M.readPower(player))
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
	-- Unedited: keep active and max glued together.
	if not M.isEdited(player) then
		local maxP = M.readPowerMax(player)
		player:SetAttribute(M.POWER_ATTR, maxP)
	end
	M.syncSwingFromPower(player)
end

return M
