-- [ACTIVE] LevelService
-- Server authority for player XP / level-ups / auto-granted rewards.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local LevelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LevelConfig"))

local LevelService = {}

local levelUpRE: RemoteEvent? = nil
local xpGainRE: RemoteEvent? = nil
local grantLuckyBlockBF: BindableFunction? = nil

local function resolveGrantLuckyBlock(): BindableFunction?
	if grantLuckyBlockBF and grantLuckyBlockBF.Parent then
		return grantLuckyBlockBF
	end
	local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
	local bf = folder and folder:FindFirstChild("GrantLuckyBlock")
	if bf and bf:IsA("BindableFunction") then
		grantLuckyBlockBF = bf
		return bf
	end
	return nil
end

local function addCash(player: Player, amount: number)
	local n = math.max(0, math.floor(amount))
	if n <= 0 then
		return
	end
	local c = player:GetAttribute("Cash")
	local cur = if typeof(c) == "number" then c else 0
	player:SetAttribute("Cash", cur + n)
end

local function grantLuckyBlock(player: Player, blockId: string): boolean
	local bf = resolveGrantLuckyBlock()
	if not bf then
		warn("[LevelService] GrantLuckyBlock missing — skipping lucky block reward")
		return false
	end
	local ok, success = pcall(function()
		return bf:Invoke(player, blockId, { equip = true })
	end)
	if not ok then
		warn("[LevelService] GrantLuckyBlock error:", success)
		return false
	end
	if success ~= true then
		warn("[LevelService] GrantLuckyBlock returned false for", blockId)
		return false
	end
	return true
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

local function grantLevelRewards(player: Player, newLevel: number): { LevelConfig.LevelReward }
	local rewards = LevelConfig.rewardsForLevel(newLevel)
	local cashTotal = 0
	for _, reward in rewards do
		if reward.kind == "cash" then
			local amt = if typeof(reward.amount) == "number" then reward.amount else 0
			addCash(player, amt)
			cashTotal += math.max(0, math.floor(amt))
		elseif reward.kind == "lucky_block" then
			local blockId = reward.luckyBlockId
			if typeof(blockId) == "string" and blockId ~= "" then
				if not grantLuckyBlock(player, blockId) then
					-- Soft fallback so the level-up still feels rewarding.
					local fallback = math.max(50_000, math.floor(8_000 * newLevel * newLevel))
					addCash(player, fallback)
					cashTotal += fallback
					warn("[LevelService] lucky block grant failed; gave cash fallback", fallback)
				end
			end
		end
	end
	player:SetAttribute(LevelConfig.LAST_LEVEL_CASH_ATTR, cashTotal)
	return rewards
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
	local lastRewards: { LevelConfig.LevelReward }? = nil

	-- Cap at MAX_LEVEL; ignore leftover XP once capped.
	local guard = 0
	while level < LevelConfig.MAX_LEVEL and guard < 200 do
		guard += 1
		local needed = LevelConfig.xpRequiredForLevel(level)
		if xp < needed then
			break
		end
		xp -= needed
		level += 1
		reached = level
		leveled = true
		lastRewards = grantLevelRewards(player, level)
	end
	if level >= LevelConfig.MAX_LEVEL then
		level = LevelConfig.MAX_LEVEL
		xp = math.min(xp, LevelConfig.xpRequiredForLevel(level))
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
		local rewards = lastRewards or LevelConfig.rewardsForLevel(reached)
		if levelUpRE then
			levelUpRE:FireClient(player, reached, rewards)
		end
	end

	return gain
end

-- Grant N account levels in one XP apply (one level-up VFX for the final level).
function LevelService.grantLevels(player: Player, count: number): number
	if not player.Parent then
		return 0
	end
	local n = math.clamp(math.floor(count), 1, 50)
	local startLevel = LevelService.readLevel(player)
	if startLevel >= LevelConfig.MAX_LEVEL then
		return 0
	end
	local xp = LevelService.readXp(player)
	local level = startLevel
	local remaining = n
	local total = 0
	while remaining > 0 and level < LevelConfig.MAX_LEVEL do
		local needed = LevelConfig.xpRequiredForLevel(level)
		total += math.max(0, needed - xp)
		xp = 0
		level += 1
		remaining -= 1
	end
	if total <= 0 then
		return 0
	end
	LevelService.addXp(player, total, "admin")
	return math.max(0, LevelService.readLevel(player) - startLevel)
end

return LevelService
