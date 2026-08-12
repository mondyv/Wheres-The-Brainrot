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
local PlayerDataService = require(script.Parent.Modules:WaitForChild("PlayerDataService"))
local TimCheeseQuestTracker = require(script.Parent.Modules:WaitForChild("TimCheeseQuestTracker"))
local AnalyticsFunnelService = require(script.Parent.Modules:WaitForChild("AnalyticsFunnelService"))
local LevelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LevelConfig"))
local LevelService = require(script.Parent.Modules:WaitForChild("LevelService"))

local STAND_TAG = "BrainrotStand"
local REMOTES_FOLDER = "TimCheeseQuestRemotes"
local SPIDER_SURVIVED_REMOTE = "BushSpiderEncounterSurvived"

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
local timTalkedRE = ensureRE("TimTalked")

local function ensureSpiderSurvivedRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local re = folder:FindFirstChild(SPIDER_SURVIVED_REMOTE)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = SPIDER_SURVIVED_REMOTE
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local spiderSurvivedRE = ensureSpiderSurvivedRemote()
local lastSpiderSurvivedAt: { [Player]: number } = {}
local SPIDER_SURVIVE_COOLDOWN = 4

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
	if typeof(active) == "number" and active >= 1 then
		return true
	end
	PlayerDataService.setTimCheeseQuestState(player, {
		questIndex = nextIndex,
		questProgress = 0,
		harvestProgress = 0,
		questReady = false,
	})
	TimCheeseQuestTracker.syncQuestProgress(player)
	return true
end

declineQuestRF.OnServerInvoke = function(player: Player): boolean
	if not PlayerDataService.waitUntilLoaded(player) then
		return false
	end
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
	TimCheeseQuestTracker.syncQuestProgress(player)
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) ~= true then
		return false, nil
	end
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then math.floor(completed) else 0
	if doneCount >= math.floor(idx) then
		return false, nil
	end
	local granted, label = TimCheeseQuestTracker.grantQuestReward(player, quest)
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
	local allDone = math.floor(idx) >= TimCheeseQuestConfig.questCount()
	AnalyticsFunnelService.onTimQuestClaimed(player, math.floor(idx), allDone)
	LevelService.addXp(player, LevelConfig.XP.timQuest, "tim_quest")
	return true, label
end

timTalkedRE.OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	TimCheeseQuestTracker.onTimTalked(player)
end)

spiderSurvivedRE.OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local now = os.clock()
	if (lastSpiderSurvivedAt[player] or 0) + SPIDER_SURVIVE_COOLDOWN > now then
		return
	end
	lastSpiderSurvivedAt[player] = now
	TimCheeseQuestTracker.onSpiderSurvived(player)
end)

Players.PlayerRemoving:Connect(function(plr)
	lastSpiderSurvivedAt[plr] = nil
end)

local bushEvt = ServerStorage:FindFirstChild("TimCheeseBushSearched")
if not (bushEvt and bushEvt:IsA("BindableEvent")) then
	bushEvt = Instance.new("BindableEvent")
	bushEvt.Name = "TimCheeseBushSearched"
	bushEvt.Parent = ServerStorage
end
(bushEvt :: BindableEvent).Event:Connect(function(player: Player, land: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local landNum = if typeof(land) == "number" then math.floor(land) else nil
	TimCheeseQuestTracker.onBushSearched(player, landNum)
end)

task.spawn(function()
	local bushRemotes = ReplicatedStorage:WaitForChild("BushRemotes", 90)
	if not bushRemotes then
		warn("[TimCheeseQuest] BushRemotes missing — claim quests won't track")
		return
	end
	local decision = bushRemotes:WaitForChild("FloatingClaimDecision", 60)
	if not (decision and decision:IsA("RemoteEvent")) then
		warn("[TimCheeseQuest] FloatingClaimDecision missing — claim quests won't track")
		return
	end
	(decision :: RemoteEvent).OnServerEvent:Connect(function(player: Player, clone: any, decisionStr: any)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		if typeof(decisionStr) ~= "string" then
			return
		end
		local rarity: string? = nil
		if typeof(clone) == "Instance" and clone:IsA("Model") then
			local r = clone:GetAttribute("BrainrotRarity")
			if typeof(r) == "string" then
				rarity = r
			end
		end
		TimCheeseQuestTracker.onClaimDecision(player, decisionStr, rarity)
	end)
end)

local stealEvt = ServerStorage:FindFirstChild("TimCheeseStealSuccess")
if not (stealEvt and stealEvt:IsA("BindableEvent")) then
	stealEvt = Instance.new("BindableEvent")
	stealEvt.Name = "TimCheeseStealSuccess"
	stealEvt.Parent = ServerStorage
end
(stealEvt :: BindableEvent).Event:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	TimCheeseQuestTracker.onStealSuccess(player)
end)

local luckyEvt = ServerStorage:FindFirstChild("TimCheeseLuckyBlockOpened")
if not (luckyEvt and luckyEvt:IsA("BindableEvent")) then
	luckyEvt = Instance.new("BindableEvent")
	luckyEvt.Name = "TimCheeseLuckyBlockOpened"
	luckyEvt.Parent = ServerStorage
end
(luckyEvt :: BindableEvent).Event:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	TimCheeseQuestTracker.onLuckyBlockOpened(player)
end)

task.spawn(function()
	while true do
		task.wait(TimCheeseQuestConfig.PROGRESS_POLL_SEC)
		for _, player in Players:GetPlayers() do
			local ok, err = pcall(TimCheeseQuestTracker.syncQuestProgress, player)
			if not ok then
				warn("[TimCheeseQuest] sync error:", err)
			end
		end
	end
end)

local function watchStandForQuest(stand: Instance)
	if not stand:IsA("Model") then
		return
	end
	local function bump()
		local owner = stand:GetAttribute("StandOwnerUserId")
		local ownerId = if owner == nil then nil else (if typeof(owner) == "number" then owner else tonumber(owner))
		if typeof(ownerId) ~= "number" then
			for _, plr in Players:GetPlayers() do
				TimCheeseQuestTracker.syncQuestProgress(plr)
			end
			return
		end
		local plr = Players:GetPlayerByUserId(ownerId)
		if plr then
			TimCheeseQuestTracker.syncQuestProgress(plr)
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
		TimCheeseQuestTracker.syncQuestProgress(player)
	end)
end

Players.PlayerAdded:Connect(function(player)
	TimCheeseQuestTracker.watchPlayerAttributes(player)
end)

for _, player in Players:GetPlayers() do
	TimCheeseQuestTracker.watchPlayerAttributes(player)
end

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
		return
	end
	-- Keep Tim replicated under tight streaming so the quest client can find him.
	if tim:IsA("Model") then
		pcall(function()
			(tim :: Model).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		end)
	end
end)
