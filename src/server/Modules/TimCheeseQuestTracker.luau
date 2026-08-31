-- [ACTIVE] TimCheeseQuestTracker
--[[
	Server-side Tim Cheese quest progress: compute, sync, counter bumps, signal hooks.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local ItemService = require(script.Parent:WaitForChild("ItemService"))
local IndexService = require(script.Parent:WaitForChild("IndexService"))

local STAND_TAG = "BrainrotStand"

local RARITY_RANK: { [string]: number } = {
	common = 1,
	uncommon = 2,
	rare = 3,
	epic = 4,
	mythic = 5,
	legendary = 6,
	["brainrot god"] = 7,
	secret = 8,
}

local M = {}

local function getBrainrotInternal(): Folder?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function isOwnedByPlayer(stand: Instance, uid: number): boolean
	local owner = stand:GetAttribute("StandOwnerUserId")
	if owner == uid then
		return true
	end
	local asNum = tonumber(owner)
	return typeof(asNum) == "number" and asNum == uid
end

local function countPlacedStands(player: Player): number
	local folder = getBrainrotInternal()
	local bf = folder and folder:FindFirstChild("CountPlacedBrainrots")
	if bf and bf:IsA("BindableFunction") then
		local ok, n = pcall(function()
			return (bf :: BindableFunction):Invoke(player)
		end)
		if ok and typeof(n) == "number" then
			return math.max(0, math.floor(n))
		end
		if not ok then
			warn("[TimCheeseQuestTracker] CountPlacedBrainrots error:", n)
		end
	end
	local n = 0
	local uid = player.UserId
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if isOwnedByPlayer(stand, uid) then
			local name = stand:GetAttribute("BrainrotName")
			if typeof(name) == "string" and name ~= "" then
				n += 1
			end
		end
	end
	return n
end

local function countPlotStandSlots(player: Player): number
	local folder = getBrainrotInternal()
	local bf = folder and folder:FindFirstChild("CountPlayerPlotStands")
	if bf and bf:IsA("BindableFunction") then
		local ok, n = pcall(function()
			return (bf :: BindableFunction):Invoke(player)
		end)
		if ok and typeof(n) == "number" then
			return math.max(0, math.floor(n))
		end
	end
	return 0
end

local function placedIncomePerSecond(player: Player): number
	local folder = getBrainrotInternal()
	local bf = folder and folder:FindFirstChild("GetPlacedIncomePerSecond")
	if bf and bf:IsA("BindableFunction") then
		local ok, total = pcall(function()
			return (bf :: BindableFunction):Invoke(player)
		end)
		if ok and typeof(total) == "number" then
			return math.max(0, total)
		end
		if not ok then
			warn("[TimCheeseQuestTracker] GetPlacedIncomePerSecond error:", total)
		end
	end
	local total = 0
	local uid = player.UserId
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if isOwnedByPlayer(stand, uid) then
			local name = stand:GetAttribute("BrainrotName")
			local rarity = stand:GetAttribute("BrainrotRarity")
			if typeof(name) == "string" and typeof(rarity) == "string" then
				local def = {
					name = name,
					rarity = rarity,
					baseIncome = stand:GetAttribute("BrainrotBaseIncome") or 0,
				}
				local level = stand:GetAttribute("BrainrotLevel")
				local mutation = stand:GetAttribute("BrainrotMutation")
				total += Brainrots.incomePerSecond(
					def,
					if typeof(level) == "number" then level else 1,
					if typeof(mutation) == "string" then mutation else "normal"
				)
			end
		end
	end
	return total
end

local function countOwnedBrainrotsOfRarity(player: Player, rarityId: string): number
	if typeof(rarityId) ~= "string" or rarityId == "" then
		return 0
	end
	local want = Brainrots.normalizeRarityId(rarityId)
	local total = 0

	local inventory, err = ItemService:GetInventory(player, 0.5)
	if not err and inventory then
		for _, item in inventory do
			if typeof(item.name) == "string" then
				local def = Brainrots.getByName(item.name)
				if def and Brainrots.normalizeRarityId(def.rarity) == want then
					total += 1
				end
			end
		end
	end

	local uid = player.UserId
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if isOwnedByPlayer(stand, uid) then
			local name = stand:GetAttribute("BrainrotName")
			local rarity = stand:GetAttribute("BrainrotRarity")
			if typeof(name) == "string" and name ~= "" then
				local def = Brainrots.getByName(name)
				local standRarity = if typeof(rarity) == "string" then Brainrots.normalizeRarityId(rarity)
					elseif def then Brainrots.normalizeRarityId(def.rarity)
					else nil
				if standRarity == want then
					total += 1
				end
			end
		end
	end

	return total
end

local function rarityRank(rarity: string?): number
	if typeof(rarity) ~= "string" then
		return 0
	end
	return RARITY_RANK[Brainrots.normalizeRarityId(rarity)] or 0
end

local function rarityMeetsMinimum(rarity: string?, minRarity: string?): boolean
	if typeof(minRarity) ~= "string" then
		return false
	end
	return rarityRank(rarity) >= rarityRank(minRarity)
end

local function counterProgress(player: Player): number
	local h = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR)
	return if typeof(h) == "number" then math.floor(h) else 0
end

local function activeQuest(player: Player): TimCheeseQuestConfig.QuestDef?
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) ~= "number" or idx < 1 then
		return nil
	end
	return TimCheeseQuestConfig.getQuest(math.floor(idx))
end

function M.computeProgress(player: Player, quest: TimCheeseQuestConfig.QuestDef): number
	if TimCheeseQuestConfig.isCounterKind(quest.kind) then
		return counterProgress(player)
	end

	if quest.kind == "reach_land" then
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local land = LandResolver.resolveLandAtPosition(hrp.Position)
			if typeof(land) == "number" and land >= quest.target then
				return quest.target
			end
			return if typeof(land) == "number" then math.max(0, math.floor(land)) else 0
		end
		return 0
	elseif quest.kind == "place_stands" then
		return countPlacedStands(player)
	elseif quest.kind == "upgrade_power" then
		local lvl = player:GetAttribute(SwingUpgrades.POWER_LEVEL_ATTR)
		return if typeof(lvl) == "number" then math.floor(lvl) else 0
	elseif quest.kind == "reach_power" then
		return math.floor(WorkoutPower.readPower(player))
	elseif quest.kind == "own_gear" then
		local owned = GearConfig.parseOwned(player:GetAttribute(GearConfig.OWNED_GEARS_ATTR))
		local gearId = math.floor(quest.target)
		return if owned[gearId] == true then gearId else 0
	elseif quest.kind == "upgrade_rope" then
		local lvl = player:GetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR)
		return if typeof(lvl) == "number" then math.floor(lvl) else 0
	elseif quest.kind == "upgrade_carry" then
		local lvl = player:GetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR)
		return if typeof(lvl) == "number" then math.floor(lvl) else 0
	elseif quest.kind == "income_rate" then
		return math.floor(placedIncomePerSecond(player))
	elseif quest.kind == "own_rarity" then
		local rarity = quest.trackRarity or quest.rewardBrainrotRarity or "common"
		return countOwnedBrainrotsOfRarity(player, rarity)
	elseif quest.kind == "rebirth_count" then
		return RebirthConfig.getRebirthCount(player)
	elseif quest.kind == "fill_stands" then
		local slots = countPlotStandSlots(player)
		local placed = countPlacedStands(player)
		if slots > 0 and placed >= slots then
			return quest.target
		end
		return 0
	elseif quest.kind == "find_mutation" then
		local mutation = quest.trackMutation or "golden"
		if mutation == "golden" then
			return IndexService.getGoldenCount(player)
		end
		return 0
	end

	return 0
end

function M.syncQuestProgress(player: Player)
	if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) ~= "number" or idx < 1 then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR, false)
		return
	end
	local quest = TimCheeseQuestConfig.getQuest(math.floor(idx))
	if not quest then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true then
		local prev = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
		if typeof(prev) == "number" and prev >= quest.target then
			return
		end
	end
	local progress = M.computeProgress(player, quest)
	local capped = math.min(progress, quest.target)
	local prev = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
	if prev ~= capped then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR, capped)
	end
	local ready = capped >= quest.target
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) ~= ready then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR, ready)
	end
end

local function bumpCounterIfKind(player: Player, kind: TimCheeseQuestConfig.QuestKind)
	local quest = activeQuest(player)
	if not quest or quest.kind ~= kind then
		return
	end
	local h = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR)
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR, (if typeof(h) == "number" then h else 0) + 1)
	M.syncQuestProgress(player)
end

function M.onBushSearched(player: Player, land: number?)
	local quest = activeQuest(player)
	if not quest then
		return
	end
	if quest.kind == "harvest" then
		bumpCounterIfKind(player, "harvest")
	elseif quest.kind == "harvest_land" then
		local wantLand = quest.trackLand or 1
		if typeof(land) == "number" and math.floor(land) == wantLand then
			bumpCounterIfKind(player, "harvest_land")
		end
	end
end

function M.onClaimDecision(player: Player, decision: string, rarity: string?)
	local quest = activeQuest(player)
	if not quest then
		return
	end
	if decision == "accept" then
		if quest.kind == "accept_claims" then
			bumpCounterIfKind(player, "accept_claims")
		end
		if quest.kind == "claim_min_rarity" and rarityMeetsMinimum(rarity, quest.trackRarity or "rare") then
			bumpCounterIfKind(player, "claim_min_rarity")
		end
	elseif decision == "decline" and quest.kind == "decline_claims" then
		bumpCounterIfKind(player, "decline_claims")
	end
end

function M.onSpiderSurvived(player: Player)
	bumpCounterIfKind(player, "spider_survive")
end

function M.onStealSuccess(player: Player)
	bumpCounterIfKind(player, "steal_brainrot")
end

function M.onLuckyBlockOpened(player: Player)
	bumpCounterIfKind(player, "open_lucky_blocks")
end

function M.onTimTalked(player: Player)
	bumpCounterIfKind(player, "talk_while_quest")
end

function M.grantQuestReward(player: Player, quest: TimCheeseQuestConfig.QuestDef): (boolean, string)
	local label = TimCheeseQuestConfig.formatRewardLabel(quest)
	if quest.rewardKind == "cash" then
		local amt = quest.rewardCash or 0
		local c = player:GetAttribute("Cash")
		if typeof(c) ~= "number" then
			c = 0
		end
		player:SetAttribute("Cash", c + math.max(0, math.floor(amt)))
		return true, "+" .. BrainrotEconomy.formatCashShort(amt)
	elseif quest.rewardKind == "lucky_block" then
		local blockName = quest.rewardLuckyBlock or "Starter Lucky Block"
		local count = math.max(1, math.floor(quest.rewardLuckyBlockCount or 1))
		local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
		local bf = folder and folder:FindFirstChild("GrantLuckyBlock")
		if not (bf and bf:IsA("BindableFunction")) then
			warn("[TimCheeseQuestTracker] GrantLuckyBlock missing")
		else
			local grantedAny = false
			for _ = 1, count do
				local ok, success = pcall(function()
					return (bf :: BindableFunction):Invoke(player, blockName, { equip = true })
				end)
				if ok and success == true then
					grantedAny = true
				elseif not ok then
					warn("[TimCheeseQuestTracker] GrantLuckyBlock error:", success)
				end
			end
			if grantedAny then
				return true, label
			end
		end
		local c = player:GetAttribute("Cash")
		if typeof(c) ~= "number" then
			c = 0
		end
		player:SetAttribute("Cash", c + 200_000)
		warn("[TimCheeseQuestTracker] lucky block grant failed; gave $200K fallback")
		return true, "+$200K (fallback)"
	elseif quest.rewardKind == "brainrot" then
		local rarity = quest.rewardBrainrotRarity or "common"
		local ok, err = ItemService:GiveRandomBrainrot(player, rarity, { equip = true })
		if ok then
			return true, label
		end
		warn("[TimCheeseQuestTracker] brainrot grant failed:", err)
		local c = player:GetAttribute("Cash")
		if typeof(c) ~= "number" then
			c = 0
		end
		player:SetAttribute("Cash", c + 200_000)
		return true, "+$200K (fallback)"
	end
	return false, "no reward"
end

local POLL_KINDS: { [TimCheeseQuestConfig.QuestKind]: boolean } = {
	reach_land = true,
	place_stands = true,
	upgrade_power = true,
	reach_power = true,
	own_gear = true,
	upgrade_rope = true,
	upgrade_carry = true,
	income_rate = true,
	own_rarity = true,
	rebirth_count = true,
	fill_stands = true,
	find_mutation = true,
}

function M.questNeedsPollSync(quest: TimCheeseQuestConfig.QuestDef?): boolean
	if not quest then
		return false
	end
	return POLL_KINDS[quest.kind] == true or TimCheeseQuestConfig.isCounterKind(quest.kind)
end

function M.watchPlayerAttributes(player: Player)
	local attrs = {
		SwingUpgrades.POWER_LEVEL_ATTR,
		SwingUpgrades.ROPE_LEVEL_ATTR,
		SwingUpgrades.CARRY_LEVEL_ATTR,
		RebirthConfig.REBIRTH_COUNT_ATTR,
		GearConfig.OWNED_GEARS_ATTR,
		"IndexGoldenCount",
	}
	for _, attr in attrs do
		player:GetAttributeChangedSignal(attr):Connect(function()
			M.syncQuestProgress(player)
		end)
	end
end

return M
