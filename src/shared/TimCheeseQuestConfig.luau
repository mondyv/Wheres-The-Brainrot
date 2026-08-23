-- [ACTIVE] TimCheeseQuestConfig
--[[
	Tim Cheese quest NPC: intro, 32-quest line, head-speech, map paths.
	Even quests 2–20 are reach the next land (Land 1 → Land 10).
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
-- Prefer waiting until the starter lucky block is actually opened; this is the fallback.
M.POST_TUTORIAL_QUEST_DELAY_SEC = 5
M.POST_TUTORIAL_LUCKY_OPEN_FALLBACK_SEC = 55
M.POST_TUTORIAL_AFTER_OPEN_SEC = 0.55

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

local function landQuest(land: number, blockId: string, title: string, offer: string, done: string, blockCount: number?): QuestDef
	local n = math.clamp(math.floor(land), 1, 10)
	return {
		id = "land_" .. tostring(n),
		title = title,
		description = if n == 1
			then "Get over to Land 1!"
			else string.format("Upgrade your Power and swing over to Land %d!", n),
		kind = "reach_land",
		target = n,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = blockId,
		rewardLuckyBlockCount = blockCount or 1,
		offerLine = offer,
		completeLine = done,
	}
end

-- 32 quests. Even slots 2,4,…,20 = Land 1 through Land 10.
local QUESTS: { QuestDef } = {
	{
		id = "search_8",
		title = "Grass Toucher",
		description = "Search 8 bushes. Tim calls it orientation.",
		kind = "harvest",
		target = 8,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 50_000,
		offerLine = "Warmup: poke some bushes. Don't eat the leaves.",
		completeLine = "Orientation complete!! Now the REAL jobs.",
	},
	landQuest(
		1,
		"troll",
		"First Land",
		"Swing out to Land 1. Go go go!!",
		"You made Land 1!! Here's a Troll Lucky Block!!"
	),
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
		offerLine = "See a brainrot? TAKE IT. Intern handbook page 1.",
		completeLine = "Five accepts!! You're hired. Kind of.",
	},
	landQuest(
		2,
		"neon",
		"Land Hopper",
		"Land 2 is waiting. Power up and swing over!!",
		"You made Land 2!! Tim Cheese is so proud!!"
	),
	{
		id = "search_12",
		title = "Bush Addict",
		description = "Search 12 bushes. Tim calls it research.",
		kind = "harvest",
		target = 12,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "uncommon",
		offerLine = "I need MORE bush data. Go touch grass. Literally.",
		completeLine = "Twelve bushes?! You're hired forever!!",
	},
	landQuest(
		3,
		"1",
		"Sky Tourist",
		"Land 3 has better vibes. Go check it out.",
		"You made it!! Tim Cheese tourism board approves!!"
	),
	{
		id = "claim_8",
		title = "No Refunds",
		description = "Accept 8 brainrots from bushes.",
		kind = "accept_claims",
		target = 8,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "neon",
		rewardLuckyBlockCount = 1,
		offerLine = "Every brainrot you see? TAKE IT. Tim's orders.",
		completeLine = "Eight accepts! That's the Tim Cheese way!!",
	},
	landQuest(
		4,
		"Mythic Lucky Block",
		"Cloud Walker",
		"Land 4. Tim is already impressed if you try.",
		"Land 4!! Genuinely impressed. Don't let it go to your head."
	),
	{
		id = "search_18",
		title = "Leaf Pusher",
		description = "Search 18 bushes. Your hands smell like grass now.",
		kind = "harvest",
		target = 18,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 200_000,
	},
	landQuest(
		5,
		"yellow",
		"Peak Cheese",
		"Land 5. That's where the real cheese lives.",
		"PEAK CHEESE ACHIEVED!! I'm not crying!!"
	),
	{
		id = "place_4",
		title = "Stand Builder",
		description = "Place 4 brainrots on your stands.",
		kind = "place_stands",
		target = 4,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "rare",
	},
	landQuest(
		6,
		"purple",
		"Far Side",
		"Land 6. Don't look down. Look CHEESE.",
		"Land 6!! Tim's map has you on it now!!"
	),
	{
		id = "claim_12",
		title = "Yes Man",
		description = "Accept 12 brainrots from bushes.",
		kind = "accept_claims",
		target = 12,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "rare",
	},
	landQuest(
		7,
		"heart",
		"High Cheese",
		"Land 7. Pack a snack. And Power.",
		"Land 7!! Heart Lucky Block because I have feelings!!"
	),
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
	landQuest(
		8,
		"Godly Luckyblock",
		"Almost Orbit",
		"Land 8. The air is weird up there. I like it.",
		"Land 8!! Godly block. You earned the sparkle."
	),
	{
		id = "income_500",
		title = "Money Printer",
		description = "Earn $500/sec from placed brainrots.",
		kind = "income_rate",
		target = 500,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 400_000,
	},
	landQuest(
		9,
		"chamber",
		"Cheese Stratosphere",
		"Land 9. Almost the top of the cheese.",
		"Land 9!! Chamber block. Don't open it in my face."
	),
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
	landQuest(
		10,
		"Secret Lucky Block",
		"Final Land",
		"Land 10. The last stop. Make Tim proud.",
		"LAND 10!! That's the whole map!! SECRET BLOCK TIME!!"
	),
	{
		id = "own_epic_2",
		title = "Epic Squad",
		description = "Own 2 Epic brainrots (bag or stands).",
		kind = "own_rarity",
		target = 2,
		showBar = true,
		rewardKind = "brainrot",
		rewardBrainrotRarity = "epic",
		trackRarity = "epic",
	},
	{
		id = "open_block_3",
		title = "Crack Open",
		description = "Open 3 Lucky Blocks. Tim wants to watch.",
		kind = "open_lucky_blocks",
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
		id = "power_3",
		title = "Power Trip",
		description = "Upgrade your Power to level 3.",
		kind = "upgrade_power",
		target = 3,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "troll",
		rewardLuckyBlockCount = 1,
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
		id = "harvest_land_15",
		title = "Homebody",
		description = "Search 15 bushes on Land 1.",
		kind = "harvest_land",
		target = 15,
		showBar = true,
		rewardKind = "cash",
		rewardCash = 250_000,
		trackLand = 1,
	},
	{
		id = "talk_tim_4",
		title = "Tim's Best Friend",
		description = "Talk to Tim 4 times while on a quest.",
		kind = "talk_while_quest",
		target = 4,
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
	{
		id = "rebirth_1",
		title = "Born Again",
		description = "Rebirth once. Tim says you're resetting the cheese.",
		kind = "rebirth_count",
		target = 1,
		showBar = true,
		rewardKind = "lucky_block",
		rewardLuckyBlock = "chamber",
		rewardLuckyBlockCount = 1,
		offerLine = "Rebirth once. Fresh start. Like a new cheese wheel.",
		completeLine = "REBORN!! The cheese has been reset!!",
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
	{ text = "Warmup bushes first — then we hop lands!!", shake = true },
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
