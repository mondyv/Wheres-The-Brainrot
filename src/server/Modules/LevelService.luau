-- [ACTIVE] LevelService
-- Server authority for player XP / level-ups / auto-granted rewards.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LevelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LevelConfig"))

local LevelService = {}

local levelUpRE: RemoteEvent? = nil
local xpGainRE: RemoteEvent? = nil

local function addCash(player: Player, amount: number)
	local n = math.max(0, math.floor(amount))
	if n <= 0 then
		return
	end
	local c = player:GetAttribute("Cash")
	local cur = if typeof(c) == "number" then c else 0
	player:SetAttribute("Cash", cur + n)
end

local function syncAttrs(player: Player, level: number, xp: number)
	local needed = LevelConfig.xpRequiredForLevel(level)
	player:SetAttribute(LevelConfig.LEVEL_ATTR, level)
	player:SetAttribute(LevelConfig.XP_ATTR, xp)
	player:SetAttribute(LevelConfig.XP_NEEDED_ATTR, needed)
end

function LevelService.bindRemotes(levelUp: RemoteEvent, xpGain: RemoteEvent)
	levelUpRE = levelUp
	xpGainRE = xpGain
end

function LevelService.readLevel(player: Player): number
	local v = player:GetAttribute(LevelConfig.LEVEL_ATTR)
	return if typeof(v) == "number" then math.max(1, math.floor(v)) else 1
end

function LevelService.readXp(player: Player): number
	local v = player:GetAttribute(LevelConfig.XP_ATTR)
	return if typeof(v) == "number" then math.max(0, math.floor(v)) else 0
end

function LevelService.applyLoaded(player: Player, level: number?, xp: number?)
	local lv = math.max(1, math.floor(if typeof(level) == "number" then level else 1))
	local x = math.max(0, math.floor(if typeof(xp) == "number" then xp else 0))
	syncAttrs(player, lv, x)
end

local function grantLevelRewards(player: Player, newLevel: number)
	local rewards = LevelConfig.rewardsForLevel(newLevel)
	for _, reward in rewards do
		if reward.kind == "cash" then
			addCash(player, reward.amount)
		end
	end
end

function LevelService.addXp(player: Player, amount: number, _reason: string?): number
	if not player.Parent then
		return 0
	end
	local gain = math.max(0, math.floor(amount))
	if gain <= 0 then
		return 0
	end

	local level = LevelService.readLevel(player)
	local xp = LevelService.readXp(player) + gain
	local leveled = false
	local reached = level

	-- Cap runaway multi-level from huge grants (safety).
	local guard = 0
	while guard < 50 do
		guard += 1
		local needed = LevelConfig.xpRequiredForLevel(level)
		if xp < needed then
			break
		end
		xp -= needed
		level += 1
		reached = level
		leveled = true
		grantLevelRewards(player, level)
	end

	syncAttrs(player, level, xp)

	player:SetAttribute(LevelConfig.LAST_XP_GAIN_ATTR, gain)
	local pulse = player:GetAttribute(LevelConfig.XP_GAIN_PULSE_ATTR)
	player:SetAttribute(LevelConfig.XP_GAIN_PULSE_ATTR, (if typeof(pulse) == "number" then pulse else 0) + 1)
	if xpGainRE then
		xpGainRE:FireClient(player, gain, level, xp, LevelConfig.xpRequiredForLevel(level))
	end

	if leveled then
		player:SetAttribute(LevelConfig.LEVEL_UP_TO_ATTR, reached)
		local up = player:GetAttribute(LevelConfig.LEVEL_UP_PULSE_ATTR)
		player:SetAttribute(LevelConfig.LEVEL_UP_PULSE_ATTR, (if typeof(up) == "number" then up else 0) + 1)
		if levelUpRE then
			levelUpRE:FireClient(player, reached, LevelConfig.rewardsForLevel(reached))
		end
	end

	return gain
end

return LevelService
