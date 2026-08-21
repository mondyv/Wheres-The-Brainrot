-- [ACTIVE] WorkoutPower
-- Workout Power drives swing force + reach (combined). Carry stays fixed at 1.
-- PowerMax = true ceiling from workouts; Power = active (may be edited down).
local SwingProgression = require(script.Parent:WaitForChild("SwingProgression"))
local SwingUpgrades = require(script.Parent:WaitForChild("SwingUpgrades"))
local GearConfig = require(script.Parent:WaitForChild("GearConfig"))
local LandPowerConfig = require(script.Parent:WaitForChild("LandPowerConfig"))

local M = {}

M.POWER_ATTR = GearConfig.POWER_ATTR
M.POWER_MAX_ATTR = GearConfig.POWER_MAX_ATTR
M.POWER_EDITED_ATTR = GearConfig.POWER_EDITED_ATTR
M.FIXED_CARRY = 1

-- Map absolute workout Power → swing force/speed level.
-- Slow log: early Tree Branch still moves the needle; Jupiter does not max the rope.
-- Near the next land lock, swing ramps up so you can actually cross the gap.
function M.swingLevelFromPower(power: number): number
	local p = math.max(0, power)
	if p <= 0 then
		return 0
	end
	-- ~20 → 4, ~200 → 20, ~2k → 45, ~50k → 84, ~1e6 → 120
	local level = math.floor(28 * math.log10(1 + p / 50))
	local peak = LandPowerConfig.swingPeakAlpha(p)
	level = math.floor(level * (0.48 + 0.52 * peak) + 0.5)
	return math.clamp(level, 0, 100_000)
end

-- Reach climbs much slower than force so Land 1 stays swingable without covering the whole map.
function M.reachLevelFromPower(power: number): number
	local p = math.max(0, power)
	if p <= 0 then
		return 0
	end
	-- ~20 → 0, ~200 → 5, ~2k → 16, ~50k → 35, ~1e6 → 53, ~1e8 → 81
	local level = math.floor(14 * math.log10(1 + p / 150))
	local peak = LandPowerConfig.swingPeakAlpha(p)
	level = math.floor(level * (0.42 + 0.58 * peak) + 0.5)
	return math.clamp(level, 0, 100_000)
end

-- Late workouts grant less Power so the number (and reach) do not explode on Jupiter.
function M.scaleWorkoutGain(rawGain: number, currentMax: number): number
	local raw = math.max(0, rawGain)
	if raw <= 0 then
		return 0
	end
	local maxP = math.max(0, currentMax)
	local scale = 1 / (1 + (maxP / 8000) ^ 0.55)
	scale = math.clamp(scale, 0.08, 1)
	return math.max(1, math.floor(raw * scale + 0.5))
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
	local forceLevel = M.swingLevelFromPower(power)
	local reachLevel = M.reachLevelFromPower(power)
	player:SetAttribute(SwingUpgrades.POWER_LEVEL_ATTR, forceLevel)
	player:SetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR, reachLevel)
	-- Carry upgrade removed — always 1 brainrot.
	player:SetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR, 0)
	player:SetAttribute("SwingForce", SwingProgression.displayPower(forceLevel))
	player:SetAttribute("SwingRange", SwingProgression.displayReach(reachLevel))
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
