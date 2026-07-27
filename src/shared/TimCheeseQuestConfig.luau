-- [ACTIVE] TimCheeseQuestConfig
--[[
	Tim Cheese quest NPC (Booster Pack Showers): quest defs, dialogue, map paths.
]]

local M = {}

M.MAP_FOLDER_NAME = "Booster Pack Showers"
M.TIM_NAME = "TimCheese"
M.QUEST_TRIGGER_NAME = "Quest Trigger"
M.QUEST_HITBOX_NAME = "QuestHitbox"
M.QUEST_FLOAT_UI_NAME = "QuestFLoatUI" -- Studio spelling
M.IDLE_ANIM_NAME = "TimCheese"

M.DROP_HEIGHT = 95
M.FALL_DURATION = 0.7
M.WALKBY_COOLDOWN_SEC = 22
M.PROGRESS_POLL_SEC = 0.85

export type QuestKind = "place_stands" | "harvest" | "cash" | "income"

export type QuestDef = {
	id: string,
	title: string,
	description: string,
	kind: QuestKind,
	target: number,
	rewardCash: number,
	showBar: boolean,
}

local QUESTS: { QuestDef } = {
	{
		id = "place_5",
		title = "Stand Starter",
		description = "Collect 5 brainrots and put them on your stands.",
		kind = "place_stands",
		target = 5,
		rewardCash = 200_000,
		showBar = true,
	},
	{
		id = "harvest_10",
		title = "Bush Scout",
		description = "Search 10 bushes for brainrots.",
		kind = "harvest",
		target = 10,
		rewardCash = 150_000,
		showBar = true,
	},
	{
		id = "cash_500k",
		title = "Pocket Padding",
		description = "Hold at least $500K cash at once.",
		kind = "cash",
		target = 500_000,
		rewardCash = 250_000,
		showBar = true,
	},
	{
		id = "place_8",
		title = "Base Builder",
		description = "Have 8 brainrots placed on your stands.",
		kind = "place_stands",
		target = 8,
		rewardCash = 300_000,
		showBar = true,
	},
	{
		id = "income_1k",
		title = "Passive Hustle",
		description = "Reach $1K/s plot generation.",
		kind = "income",
		target = 1_000,
		rewardCash = 400_000,
		showBar = true,
	},
	{
		id = "harvest_25",
		title = "Leaf Legend",
		description = "Search 25 bushes (lifetime this quest).",
		kind = "harvest",
		target = 25,
		rewardCash = 350_000,
		showBar = true,
	},
	{
		id = "place_12",
		title = "Full House",
		description = "Have 12 brainrots placed on your stands.",
		kind = "place_stands",
		target = 12,
		rewardCash = 500_000,
		showBar = true,
	},
	{
		id = "cash_2m",
		title = "Millionaire Vibes",
		description = "Hold at least $2M cash at once.",
		kind = "cash",
		target = 2_000_000,
		rewardCash = 750_000,
		showBar = true,
	},
	{
		id = "income_10k",
		title = "Generation God",
		description = "Reach $10K/s plot generation.",
		kind = "income",
		target = 10_000,
		rewardCash = 900_000,
		showBar = true,
	},
	{
		id = "place_16",
		title = "Cheese Champion",
		description = "Have 16 brainrots placed on your stands.",
		kind = "place_stands",
		target = 16,
		rewardCash = 1_000_000,
		showBar = true,
	},
}

M.QUESTS = QUESTS

M.INTRO_LINES = {
	{ text = "HEY!! YOU MADE IT OUT OF THE TUTORIAL ALIVE!!", shake = true },
	{ text = "I'm TIM CHEESE. Official quest dealer. Semi-official comedian.", shake = false },
	{ text = "Finish jobs for me and I'll shower you in CASH. Ready when you are.", shake = true },
}

M.COMPLETE_LINES = {
	{ text = "QUEST COMPLETE!! You actually did it!!", shake = true },
	{ text = "Here's your reward — don't spend it all on one lucky block...", shake = false },
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
	"The stands aren't gonna fill themselves...",
}

-- Mid-mission check-in (world speech only — no cutscene).
M.IN_PROGRESS_LINES = {
	"Finish your job and then come back to me!!",
	"Still working? Get that quest DONE first!!",
	"No shortcuts!! Finish the mission, THEN we talk rewards.",
	"You're mid-job!! Go finish it, then hit me up!!",
	"Come back when the quest is DONE. I'm watching...",
	"Chop chop!! Finish your quest before we chat!!",
	"Quest first, cheese later. You got this!!",
	"Don't ghost the job!! Finish it and report back!!",
}

-- Classic Roblox stud tile for the cheese ticket HUD.
M.STUD_TEXTURE = "rbxassetid://6065821980"

M.NO_QUEST_OVERHEAD = "Quests"
M.HAS_QUEST_OVERHEAD = "Quest Active"
M.READY_OVERHEAD = "Talk to claim!"

function M.getQuest(index: number): QuestDef?
	return M.QUESTS[index]
end

function M.questCount(): number
	return #M.QUESTS
end

return M
