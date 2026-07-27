-- [ACTIVE] TimCheeseQuest.server
--[[
	Tim Cheese quests: intro flag, progress polling, claim/accept/decline remotes.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local Brainrots = require(script.Parent.Modules:WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent.Modules:WaitForChild("PlayerDataService"))
local ItemService = require(script.Parent.Modules:WaitForChild("ItemService"))

local STAND_TAG = "BrainrotStand"
local REMOTES_FOLDER = "TimCheeseQuestRemotes"

local function isOwnedByPlayer(stand: Instance, uid: number): boolean
	local owner = stand:GetAttribute("StandOwnerUserId")
	if owner == uid then
		return true
	end
	local asNum = tonumber(owner)
	return typeof(asNum) == "number" and asNum == uid
end

local function ensureRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = REMOTES_FOLDER
	created.Parent = ReplicatedStorage
	return created
end

local function ensureRE(name: string): RemoteEvent
	local folder = ensureRemotes()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = folder
	return ev
end

local function ensureRF(name: string): RemoteFunction
	local folder = ensureRemotes()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

local introDoneRE = ensureRE("IntroDone")
local acceptQuestRF = ensureRF("AcceptQuest")
local declineQuestRF = ensureRF("DeclineQuest")
local claimQuestRF = ensureRF("ClaimQuest")

local function getBrainrotInternal(): Folder?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function countPlacedStands(player: Player): number
	-- Prefer StandManager's live state — CollectionService tags can lag / miss Studio stands.
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
			warn("[TimCheeseQuest] CountPlacedBrainrots error:", n)
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
			warn("[TimCheeseQuest] GetPlacedIncomePerSecond error:", total)
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

local function addCash(player: Player, amount: number)
	local c = player:GetAttribute("Cash")
	if typeof(c) ~= "number" then
		c = 0
	end
	player:SetAttribute("Cash", c + math.max(0, math.floor(amount)))
end

local function grantLuckyBlock(player: Player, blockName: string): boolean
	local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
	local bf = folder and folder:FindFirstChild("GrantLuckyBlock")
	if not (bf and bf:IsA("BindableFunction")) then
		warn("[TimCheeseQuest] GrantLuckyBlock missing")
		return false
	end
	local ok, success = pcall(function()
		return (bf :: BindableFunction):Invoke(player, blockName, { equip = true })
	end)
	if not ok then
		warn("[TimCheeseQuest] GrantLuckyBlock error:", success)
		return false
	end
	return success == true
end

local function grantQuestReward(player: Player, quest: TimCheeseQuestConfig.QuestDef): (boolean, string)
	local label = TimCheeseQuestConfig.formatRewardLabel(quest)
	if quest.rewardKind == "cash" then
		local amt = quest.rewardCash or 0
		addCash(player, amt)
		return true, "+" .. BrainrotEconomy.formatCashShort(amt)
	elseif quest.rewardKind == "lucky_block" then
		local blockName = quest.rewardLuckyBlock or "Starter Lucky Block"
		if grantLuckyBlock(player, blockName) then
			return true, label
		end
		-- Fallback cash so claim never soft-locks.
		addCash(player, 200_000)
		warn("[TimCheeseQuest] lucky block grant failed; gave $200K fallback")
		return true, "+$200K (fallback)"
	elseif quest.rewardKind == "brainrot" then
		local rarity = quest.rewardBrainrotRarity or "common"
		local ok, err = ItemService:GiveRandomBrainrot(player, rarity, { equip = true })
		if ok then
			return true, label
		end
		warn("[TimCheeseQuest] brainrot grant failed:", err)
		addCash(player, 200_000)
		return true, "+$200K (fallback)"
	end
	return false, "no reward"
end

local function computeProgress(player: Player, quest: TimCheeseQuestConfig.QuestDef): number
	if quest.kind == "place_stands" then
		return countPlacedStands(player)
	elseif quest.kind == "cash" then
		local cash = player:GetAttribute("Cash")
		return if typeof(cash) == "number" then math.floor(cash) else 0
	elseif quest.kind == "income" then
		return math.floor(placedIncomePerSecond(player))
	elseif quest.kind == "harvest" then
		local h = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR)
		return if typeof(h) == "number" then math.floor(h) else 0
	end
	return 0
end

local function syncQuestProgress(player: Player)
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
	local progress = computeProgress(player, quest)
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

introDoneRE.OnServerEvent:Connect(function(player: Player)
	if not PlayerDataService.waitUntilLoaded(player) then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
		return
	end
	PlayerDataService.setTimCheeseIntroDone(player, true)
end)

acceptQuestRF.OnServerInvoke = function(player: Player): boolean
	if not PlayerDataService.waitUntilLoaded(player) then
		return false
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return false
	end
	-- Accept may arrive before IntroDone replicates — complete intro here too.
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) ~= true then
		PlayerDataService.setTimCheeseIntroDone(player, true)
	end
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then math.floor(completed) else 0
	local nextIndex = doneCount + 1
	if nextIndex > TimCheeseQuestConfig.questCount() then
		return false
	end
	local active = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	-- Idempotent: already on a quest counts as success (Studio retests / double-fire).
	if typeof(active) == "number" and active >= 1 then
		return true
	end
	PlayerDataService.setTimCheeseQuestState(player, {
		questIndex = nextIndex,
		questProgress = 0,
		harvestProgress = 0,
		questReady = false,
	})
	syncQuestProgress(player)
	return true
end

declineQuestRF.OnServerInvoke = function(player: Player): boolean
	if not PlayerDataService.waitUntilLoaded(player) then
		return false
	end
	-- Decline only clears a pending offer — active quests stay until claimed/finished.
	return true
end

claimQuestRF.OnServerInvoke = function(player: Player): (boolean, string?)
	if not PlayerDataService.waitUntilLoaded(player) then
		return false, nil
	end
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) ~= "number" or idx < 1 then
		return false, nil
	end
	local quest = TimCheeseQuestConfig.getQuest(math.floor(idx))
	if not quest then
		return false, nil
	end
	syncQuestProgress(player)
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) ~= true then
		return false, nil
	end
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then math.floor(completed) else 0
	if doneCount >= math.floor(idx) then
		return false, nil
	end
	local granted, label = grantQuestReward(player, quest)
	if not granted then
		return false, nil
	end
	PlayerDataService.setTimCheeseQuestState(player, {
		questIndex = 0,
		questProgress = 0,
		harvestProgress = 0,
		completedCount = math.floor(idx),
		questReady = false,
	})
	return true, label
end

-- BushHarvest fires this when a search attempt succeeds (found or empty).
local bushEvt = ServerStorage:FindFirstChild("TimCheeseBushSearched")
if not (bushEvt and bushEvt:IsA("BindableEvent")) then
	bushEvt = Instance.new("BindableEvent")
	bushEvt.Name = "TimCheeseBushSearched"
	bushEvt.Parent = ServerStorage
end
(bushEvt :: BindableEvent).Event:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) ~= "number" or idx < 1 then
		return
	end
	local quest = TimCheeseQuestConfig.getQuest(math.floor(idx))
	if not quest or quest.kind ~= "harvest" then
		return
	end
	local h = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR)
	local nextH = (if typeof(h) == "number" then h else 0) + 1
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR, nextH)
	syncQuestProgress(player)
end)

task.spawn(function()
	while true do
		task.wait(TimCheeseQuestConfig.PROGRESS_POLL_SEC)
		for _, player in Players:GetPlayers() do
			local ok, err = pcall(syncQuestProgress, player)
			if not ok then
				warn("[TimCheeseQuest] sync error:", err)
			end
		end
	end
end)

-- Instant progress when a stand gains/loses a brainrot (bar shouldn't wait on poll).
local function watchStandForQuest(stand: Instance)
	if not stand:IsA("Model") then
		return
	end
	local function bump()
		local owner = stand:GetAttribute("StandOwnerUserId")
		local ownerId = if owner == nil then nil else (if typeof(owner) == "number" then owner else tonumber(owner))
		if typeof(ownerId) ~= "number" then
			-- Cleared stand: refresh every player with an active place/income quest.
			for _, plr in Players:GetPlayers() do
				local idx = plr:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
				if typeof(idx) == "number" and idx >= 1 then
					local quest = TimCheeseQuestConfig.getQuest(math.floor(idx))
					if quest and (quest.kind == "place_stands" or quest.kind == "income") then
						syncQuestProgress(plr)
					end
				end
			end
			return
		end
		local plr = Players:GetPlayerByUserId(ownerId)
		if plr then
			syncQuestProgress(plr)
		end
	end
	stand:GetAttributeChangedSignal("BrainrotName"):Connect(bump)
	stand:GetAttributeChangedSignal("StandOwnerUserId"):Connect(bump)
	stand:GetAttributeChangedSignal("BrainrotBaseIncome"):Connect(bump)
end

for _, stand in CollectionService:GetTagged(STAND_TAG) do
	watchStandForQuest(stand)
end
CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(watchStandForQuest)

-- StandManager fires this on place/pickup so progress never waits on the poll.
do
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BrainrotInternal"
		folder.Parent = ServerStorage
	end
	local ev = folder:FindFirstChild("StandBrainrotChanged")
	if not (ev and ev:IsA("BindableEvent")) then
		ev = Instance.new("BindableEvent")
		ev.Name = "StandBrainrotChanged"
		ev.Parent = folder
	end
	(ev :: BindableEvent).Event:Connect(function(player: Player)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		syncQuestProgress(player)
	end)
end

-- Keep map TimCheese present (streaming).
task.spawn(function()
	local map = Workspace:WaitForChild("Map", 120)
	if not map then
		warn("[TimCheeseQuest] Map missing")
		return
	end
	local folder = map:WaitForChild(TimCheeseQuestConfig.MAP_FOLDER_NAME, 120)
	if not folder then
		warn("[TimCheeseQuest] Booster Pack Showers missing")
		return
	end
	local tim = folder:WaitForChild(TimCheeseQuestConfig.TIM_NAME, 60)
	if not tim then
		warn("[TimCheeseQuest] TimCheese missing")
	end
end)
