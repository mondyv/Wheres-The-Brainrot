-- [ACTIVE] TimCheeseQuestConfig
--[[
	Tim Cheese quest NPC: 3 starter quests, head-speech intro, map paths.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local M = {}

M.MAP_FOLDER_NAME = "Booster Pack Showers"
M.TIM_NAME = "TimCheese"
M.QUEST_TRIGGER_NAME = "Quest Trigger"
M.QUEST_HITBOX_NAME = "QuestHitbox"
M.QUEST_FLOAT_UI_NAME = "QuestFLoatUI" -- Studio spelling
M.IDLE_ANIM_NAME = "TimCheese"

M.DROP_HEIGHT = 78
M.FALL_DURATION = 0.78
M.WALKBY_COOLDOWN_SEC = 22
M.PROGRESS_POLL_SEC = 0.85

export type QuestKind = "harvest" | "accept_claims" | "reach_land"
export type RewardKind = "cash" | "lucky_block" | "brainrot"

export type QuestDef = {
	id: string,
	title: string,
	description: string,
	kind: QuestKind,
	target: number,
	showBar: boolean,
	rewardKind: RewardKind,
	rewardCash: number?,
	rewardLuckyBlock: string?,
	rewardLuckyBlockCount: number?,
	rewardBrainrotRarity: string?,
}

local QUESTS: { QuestDef } = {
	{
		id = "search_15",
		title = "Bush Scout",
		description = "Search 15 bushes for brainrots.",
		kind = "harvest",
		target = 15,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 200_000,
	},
	{
		id = "claim_5",
		title = "Brainrot Collector",
		description = "Accept 5 brainrots from bushes.",
		kind = "accept_claims",
		target = 5,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "Starter Lucky Block",
		rewardLuckyBlockCount = 2,
	},
	{
		id = "land_2",
		title = "Land Hopper",
		description = "Upgrade your Power and swing over to Land 2!",
		kind = "reach_land",
		target = 2,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 500_000,
	},
}

M.QUESTS = QUESTS

-- Intro: head text only (no speech-box / buttons).
M.INTRO_LINES = {
	{ text = "Hey!! My name is Tim Cheese!", shake = true },
	{ text = "I need your help collecting brainrots!", shake = false },
	{ text = "Please search 15 bushes and come back to me after!", shake = true },
}

M.COMPLETE_LINES = {
	{ text = "QUEST COMPLETE!! You actually did it!!", shake = true },
	{ text = "Here's your reward — don't waste it!!", shake = false },
}

M.OFFER_LINES = {
	{ text = "Want another quest? I got a fresh one lined up.", shake = false },
}

M.DECLINE_LINES = {
	{ text = "All good. Come back whenever you feel that quest itch.", shake = false },
}

M.ALL_DONE_LINES = {
	{ text = "That's every quest I got for now. Absolute legend.", shake = true },
	{ text = "Hang around — I might cook up more jobs later.", shake = false },
}

M.WALKBY_LINES = {
	"Are you ready for the quest?",
	"Psst... Tim Cheese has work for you.",
	"Don't leave me hanging with empty quests!",
	"Hey! Yeah you. Quest time?",
}

M.IN_PROGRESS_LINES = {
	"Finish your job and then come back to me!!",
	"Still working? Get that quest DONE first!!",
	"Come back when the quest is DONE. I'm watching...",
	"Chop chop!! Finish your quest before we chat!!",
}

M.STUD_TEXTURE = "rbxassetid://6065821980"

M.NO_QUEST_OVERHEAD = "Quests"
M.HAS_QUEST_OVERHEAD = "Quest Active"
M.READY_OVERHEAD = "Visit me!"
M.VISIT_OVERHEAD = "Talk to me!"

function M.formatRewardLabel(quest: QuestDef): string
	if quest.rewardKind == "cash" then
		return BrainrotEconomy.formatCashShort(quest.rewardCash or 0)
	elseif quest.rewardKind == "lucky_block" then
		local name = quest.rewardLuckyBlock or "Lucky Block"
		local count = math.max(1, math.floor(quest.rewardLuckyBlockCount or 1))
		local short = if string.find(name, "Starter", 1, true)
			then "Starter Block"
			elseif string.find(name, "Mythic", 1, true) then "Mythic Block"
			elseif string.find(name, "Secret", 1, true) then "Secret Block"
			else name
		if count > 1 then
			return string.format("%dx %s", count, short)
		end
		return short
	elseif quest.rewardKind == "brainrot" then
		local rarity = quest.rewardBrainrotRarity or "common"
		local nice = string.upper(string.sub(rarity, 1, 1)) .. string.sub(rarity, 2)
		return nice .. " Brainrot"
	end
	return "Reward"
end

function M.getQuest(index: number): QuestDef?
	return M.QUESTS[index]
end

function M.questCount(): number
	return #M.QUESTS
end

return M
