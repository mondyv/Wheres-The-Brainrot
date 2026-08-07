-- [ACTIVE] TimCheeseQuestConfig
--[[
	Tim Cheese quest NPC: intro, 32-quest line, head-speech, map paths.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))

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
-- After tutorial completes, wait this long then show the quest-accept appearance (no Tim fall).
M.POST_TUTORIAL_QUEST_DELAY_SEC = 5

export type QuestKind =
	"harvest"
	| "accept_claims"
	| "decline_claims"
	| "reach_land"
	| "place_stands"
	| "upgrade_power"
	| "upgrade_rope"
	| "upgrade_carry"
	| "income_rate"
	| "own_rarity"
	| "rebirth_count"
	| "open_lucky_blocks"
	| "spider_survive"
	| "steal_brainrot"
	| "find_mutation"
	| "fill_stands"
	| "harvest_land"
	| "talk_while_quest"
	| "claim_min_rarity"

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
	trackLand: number?,
	trackRarity: string?,
	trackMutation: string?,
	offerLine: string?,
	completeLine: string?,
}

local QUESTS: { QuestDef } = {
	-- Act 1 — Tim's Intern
	{
		id = "land_1",
		title = "First Land",
		description = "Get over to Land 1!",
		kind = "reach_land",
		target = 1,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "troll",
		rewardLuckyBlockCount = 1,
		offerLine = "First job: swing out to Land 1. Go go go!!",
		completeLine = "You made Land 1!! Here's a Troll Lucky Block!!",
	},
	{
		id = "land_2",
		title = "Land Hopper",
		description = "Upgrade your Power and swing over to Land 2!",
		kind = "reach_land",
		target = 2,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "neon",
		rewardLuckyBlockCount = 1,
		offerLine = "Land 2 is waiting. Power up and swing over!!",
		completeLine = "You made Land 2!! Tim Cheese is so proud!!",
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
		id = "search_10",
		title = "Bush Addict",
		description = "Search 10 bushes. Tim calls it \"research.\"",
		kind = "harvest",
		target = 10,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "uncommon",
		offerLine = "I need MORE bush data. Go touch grass. Literally.",
		completeLine = "Ten bushes?! You're hired forever!!",
	},
	{
		id = "claim_6",
		title = "No Refunds",
		description = "Accept 6 brainrots from bushes.",
		kind = "accept_claims",
		target = 6,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "neon",
		rewardLuckyBlockCount = 1,
		offerLine = "Every brainrot you see? TAKE IT. Tim's orders.",
		completeLine = "Six accepts! That's the Tim Cheese way!!",
	},
	{
		id = "search_15",
		title = "Leaf Pusher",
		description = "Search 15 bushes. Your hands smell like grass now.",
		kind = "harvest",
		target = 15,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 200_000,
	},
	-- Act 2 — Tim's Partner
	{
		id = "land_3",
		title = "Sky Tourist",
		description = "Reach Land 3. Tim wants a photo.",
		kind = "reach_land",
		target = 3,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "1",
		rewardLuckyBlockCount = 1,
		offerLine = "Land 3 has better vibes. Go check it out.",
		completeLine = "You made it!! Tim Cheese tourism board approves!!",
	},
	{
		id = "claim_10",
		title = "Yes Man",
		description = "Accept 10 brainrots from bushes.",
		kind = "accept_claims",
		target = 10,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "rare",
	},
	{
		id = "search_25",
		title = "Bush Connoisseur",
		description = "Search 25 bushes. Tim thinks you're obsessed.",
		kind = "harvest",
		target = 25,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 350_000,
	},
	{
		id = "land_4",
		title = "Cloud Walker",
		description = "Reach Land 4. Tim is genuinely impressed.",
		kind = "reach_land",
		target = 4,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "Mythic Lucky Block",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "claim_15",
		title = "Brainrot Believer",
		description = "Accept 15 brainrots. Tim trusts you now.",
		kind = "accept_claims",
		target = 15,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "epic",
	},
	{
		id = "search_40",
		title = "Tim's Favorite Employee",
		description = "Search 40 bushes. Tim put your name on a plaque.",
		kind = "harvest",
		target = 40,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "purple",
		rewardLuckyBlockCount = 1,
		completeLine = "LEGEND STATUS UNLOCKED!!",
	},
	-- Act 3 — Tim's Legend
	{
		id = "land_5",
		title = "Peak Cheese",
		description = "Reach Land 5. Tim's final geography lesson.",
		kind = "reach_land",
		target = 5,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "yellow",
		rewardLuckyBlockCount = 1,
		offerLine = "Land 5. That's where the real cheese lives.",
		completeLine = "PEAK CHEESE ACHIEVED!! I'm not crying!!",
	},
	{
		id = "claim_20",
		title = "Accept Everything",
		description = "Accept 20 brainrots. Tim stopped counting.",
		kind = "accept_claims",
		target = 20,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 750_000,
	},
	{
		id = "place_5",
		title = "Stand Builder",
		description = "Place 5 brainrots on your stands.",
		kind = "place_stands",
		target = 5,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "rare",
	},
	{
		id = "power_3",
		title = "Power Trip",
		description = "Upgrade your Power to level 3.",
		kind = "upgrade_power",
		target = 3,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "heart",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "income_1k",
		title = "Money Printer",
		description = "Earn $1,000/sec from placed brainrots.",
		kind = "income_rate",
		target = 1000,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 500_000,
	},
	{
		id = "open_block_3",
		title = "Crack Open",
		description = "Open 3 Lucky Blocks. Tim wants to watch.",
		kind = "open_lucky_blocks",
		target = 3,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "Godly Luckyblock",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "own_epic_3",
		title = "Epic Squad",
		description = "Own 3 Epic brainrots (bag or stands).",
		kind = "own_rarity",
		target = 3,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "epic",
		trackRarity = "epic",
	},
	{
		id = "rebirth_1",
		title = "Born Again",
		description = "Rebirth once. Tim says you're \"resetting the cheese.\"",
		kind = "rebirth_count",
		target = 1,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "chamber",
		rewardLuckyBlockCount = 1,
		offerLine = "Rebirth once. Fresh start. Like a new cheese wheel.",
		completeLine = "REBORN!! The cheese has been reset!!",
	},
	-- Bonus jobs
	{
		id = "spider_survive_1",
		title = "Eight Legs, Zero Fear",
		description = "Survive a bush spider encounter.",
		kind = "spider_survive",
		target = 1,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 150_000,
		offerLine = "Heard there's spiders in the bushes. Go say hi.",
		completeLine = "You LIVED?! Okay you're actually tough!!",
	},
	{
		id = "spider_survive_3",
		title = "Arachnid Veteran",
		description = "Survive 3 spider encounters.",
		kind = "spider_survive",
		target = 3,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "Mythic Lucky Block",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "decline_5",
		title = "Hard Pass",
		description = "Decline 5 floating brainrot claims.",
		kind = "decline_claims",
		target = 5,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "uncommon",
		offerLine = "Decline some brainrots. Be picky. Like me.",
		completeLine = "Wow, standards?? Respect.",
	},
	{
		id = "golden_1",
		title = "Shiny Finder",
		description = "Discover 1 Golden mutation brainrot.",
		kind = "find_mutation",
		target = 1,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "rainbow",
		rewardLuckyBlockCount = 1,
		trackMutation = "golden",
	},
	{
		id = "steal_1",
		title = "Cheese Thief",
		description = "Successfully steal 1 brainrot.",
		kind = "steal_brainrot",
		target = 1,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 400_000,
	},
	{
		id = "rope_2",
		title = "Long Reach",
		description = "Upgrade your Rope to level 2.",
		kind = "upgrade_rope",
		target = 2,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "troll",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "carry_2",
		title = "Heavy Hauler",
		description = "Upgrade your Carry to level 2.",
		kind = "upgrade_carry",
		target = 2,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "rare",
	},
	{
		id = "fill_stands",
		title = "No Empty Slots",
		description = "Fill every stand slot on your plot.",
		kind = "fill_stands",
		target = 1,
		showBar = false,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "epic",
	},
	{
		id = "open_block_2",
		title = "Double Crack",
		description = "Open 2 Lucky Blocks.",
		kind = "open_lucky_blocks",
		target = 2,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "Secret Lucky Block",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "harvest_land_20",
		title = "Homebody",
		description = "Search 20 bushes on Land 1.",
		kind = "harvest_land",
		target = 20,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 250_000,
		trackLand = 1,
	},
	{
		id = "talk_tim_5",
		title = "Tim's Best Friend",
		description = "Talk to Tim 5 times while on a quest.",
		kind = "talk_while_quest",
		target = 5,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "star",
		rewardLuckyBlockCount = 1,
	},
	{
		id = "claim_rare_1",
		title = "Jackpot Pull",
		description = "Accept a Rare-or-higher brainrot from a bush.",
		kind = "claim_min_rarity",
		target = 1,
		showBar = false,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "1 opposite",
		rewardLuckyBlockCount = 1,
		trackRarity = "rare",
	},
}

M.QUESTS = QUESTS

M.COUNTER_QUEST_KINDS = {
	harvest = true,
	accept_claims = true,
	decline_claims = true,
	spider_survive = true,
	open_lucky_blocks = true,
	harvest_land = true,
	talk_while_quest = true,
	claim_min_rarity = true,
	steal_brainrot = true,
} :: { [QuestKind]: boolean }

M.INTRO_LINES = {
	{ text = "Hey!! My name is Tim Cheese!", shake = true },
	{ text = "I need your help collecting brainrots!", shake = false },
	{ text = "First job: get over to Land 1!!", shake = true },
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
		local def = LuckyBlockCatalog.get(name)
		local short = if def then def.displayName else name
		local count = math.max(1, math.floor(quest.rewardLuckyBlockCount or 1))
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

function M.formatProgressLabel(quest: QuestDef, progress: number): string
	local p = math.floor(progress)
	local t = quest.target
	if quest.kind == "reach_land" then
		return if p >= t then string.format("Land %d reached!", t) else string.format("Reach Land %d", t)
	elseif quest.kind == "upgrade_power" then
		return string.format("Power %d / %d", p, t)
	elseif quest.kind == "upgrade_rope" then
		return string.format("Rope %d / %d", p, t)
	elseif quest.kind == "upgrade_carry" then
		return string.format("Carry %d / %d", p, t)
	elseif quest.kind == "income_rate" then
		return string.format("$%s/s / $%s/s", BrainrotEconomy.formatCashShort(p), BrainrotEconomy.formatCashShort(t))
	elseif quest.kind == "own_rarity" then
		local label = quest.trackRarity or quest.rewardBrainrotRarity or "brainrot"
		return string.format("%s %s / %d", p, label, t)
	elseif quest.kind == "rebirth_count" then
		return string.format("Rebirths %d / %d", p, t)
	elseif quest.kind == "place_stands" then
		return string.format("Placed %d / %d", p, t)
	elseif quest.kind == "fill_stands" then
		return if p >= t then "All stands filled!" else "Fill every stand slot"
	elseif quest.kind == "find_mutation" then
		return if p >= t then "Golden found!" else "Find a Golden brainrot"
	elseif quest.kind == "claim_min_rarity" then
		return if p >= t then "Rare+ claimed!" else "Claim a Rare+ brainrot"
	elseif quest.kind == "harvest_land" then
		local land = quest.trackLand or 1
		return string.format("Land %d: %d / %d", land, p, t)
	else
		return string.format("%d / %d", p, t)
	end
end

function M.getQuest(index: number): QuestDef?
	return M.QUESTS[index]
end

function M.questCount(): number
	return #M.QUESTS
end

function M.isCounterKind(kind: QuestKind): boolean
	return M.COUNTER_QUEST_KINDS[kind] == true
end

return M
