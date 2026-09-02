-- [ACTIVE] AnalyticsFunnelConfig
--[[
	Creator Hub Analytics funnel step definitions.

	Onboarding  = LogOnboardingFunnelStepEvent (one-time FTUE)
	Other funnels = LogFunnelStepEvent with a stable per-player session id
	                (except Shop + WaveChase, which use per-attempt sessions)
]]

local M = {}

export type OnboardingStep = {
	step: number,
	id: string,
	name: string,
}

export type FunnelStep = {
	step: number,
	id: string,
	name: string,
	land: number?,
	questIndex: number?,
	rebirthCount: number?,
	sec: number?,
}

----------------------------------------------------------------
-- Onboarding (FTUE) — mirrors TutorialConfig.STEPS
----------------------------------------------------------------

M.ONBOARDING = {
	{ step = 1, id = "player_joined", name = "Player Joined" },
	{ step = 2, id = "got_starter_cash", name = "Got Starter Cash" },
	{ step = 3, id = "visited_upgrade", name = "Visited Upgrade Stand" },
	{ step = 4, id = "bought_power", name = "Bought First Power" },
	{ step = 5, id = "equipped_gear", name = "Equipped Gear" },
	{ step = 6, id = "used_workout", name = "Used Workout" },
	{ step = 7, id = "swung_vine", name = "Swung Across Vine" },
	{ step = 8, id = "opened_bush", name = "Opened Bush" },
	{ step = 9, id = "claimed_brainrot", name = "Claimed Brainrot" },
	{ step = 10, id = "returned_to_base", name = "Returned to Base" },
	{ step = 11, id = "placed_on_stand", name = "Placed on Stand" },
	{ step = 12, id = "upgraded_brainrot", name = "Upgraded Brainrot" },
	{ step = 13, id = "tutorial_completed", name = "Tutorial Completed" },
	{ step = 14, id = "opened_starter_lucky_block", name = "Opened Starter Lucky Block" },
} :: { OnboardingStep }

M.TUTORIAL_ID_TO_ONBOARDING = {
	grantCash = "got_starter_cash",
	visitUpgrade = "visited_upgrade",
	buyPower = "bought_power",
	equipGear = "equipped_gear",
	useWorkout = "used_workout",
	swingLand1 = "swung_vine",
	searchBush = "opened_bush",
	claimBrainrot = "claimed_brainrot",
	goToBase = "returned_to_base",
	placeOnPlot = "placed_on_stand",
	upgradeBrainrot = "upgraded_brainrot",
}

M.ONBOARDING_MAX_STEP = 14

----------------------------------------------------------------
-- World progression — land depth (stable across joins)
----------------------------------------------------------------

M.WORLD_FUNNEL = "WorldProgression_v3"
-- Keep PROGRESSION_FUNNEL alias for older call sites.
M.PROGRESSION_FUNNEL = M.WORLD_FUNNEL

M.WORLD = {
	{ step = 1, id = "land_1", name = "Reached Land 1", land = 1 },
	{ step = 2, id = "land_2", name = "Reached Land 2", land = 2 },
	{ step = 3, id = "land_3", name = "Reached Land 3", land = 3 },
	{ step = 4, id = "land_4", name = "Reached Land 4", land = 4 },
	{ step = 5, id = "land_5", name = "Reached Land 5", land = 5 },
	{ step = 6, id = "land_6", name = "Reached Land 6", land = 6 },
	{ step = 7, id = "land_7", name = "Reached Land 7", land = 7 },
	{ step = 8, id = "land_8", name = "Reached Land 8", land = 8 },
	{ step = 9, id = "land_9", name = "Reached Land 9", land = 9 },
	{ step = 10, id = "land_10", name = "Reached Land 10", land = 10 },
} :: { FunnelStep }

-- Back-compat alias used by older service helpers.
M.PROGRESSION = M.WORLD

----------------------------------------------------------------
-- Tim Cheese quests — every claim (stable across joins)
----------------------------------------------------------------

M.TIM_QUEST_FUNNEL = "TimCheeseQuests_v2"
M.TIM_QUEST_COUNT = 32

local timQuestSteps: { FunnelStep } = {}
for i = 1, M.TIM_QUEST_COUNT do
	table.insert(timQuestSteps, {
		step = i,
		id = ("tim_quest_%d"):format(i),
		name = ("Tim Quest %d"):format(i),
		questIndex = i,
	})
end
table.insert(timQuestSteps, {
	step = M.TIM_QUEST_COUNT + 1,
	id = "tim_all_quests",
	name = "All Tim Quests Complete",
})
M.TIM_QUEST = timQuestSteps

----------------------------------------------------------------
-- Rebirth depth
----------------------------------------------------------------

M.REBIRTH_FUNNEL = "Rebirth_v2"
M.REBIRTH = {
	{ step = 1, id = "rebirth_1", name = "Rebirth 1", rebirthCount = 1 },
	{ step = 2, id = "rebirth_2", name = "Rebirth 2", rebirthCount = 2 },
	{ step = 3, id = "rebirth_3", name = "Rebirth 3", rebirthCount = 3 },
	{ step = 4, id = "rebirth_5", name = "Rebirth 5", rebirthCount = 5 },
	{ step = 5, id = "rebirth_10", name = "Rebirth 10", rebirthCount = 10 },
	{ step = 6, id = "rebirth_15", name = "Rebirth 15", rebirthCount = 15 },
	{ step = 7, id = "rebirth_20", name = "Rebirth 20", rebirthCount = 20 },
} :: { FunnelStep }

----------------------------------------------------------------
-- Core economy loop (first-time milestones, typical order)
----------------------------------------------------------------

M.CORE_LOOP_FUNNEL = "CoreLoop_v2"
M.CORE_LOOP = {
	{ step = 1, id = "first_sell", name = "First Sell" },
	{ step = 2, id = "first_return", name = "First Return Home" },
	{ step = 3, id = "first_daily", name = "First Daily Claim" },
	{ step = 4, id = "first_lucky_block", name = "Opened Non-Starter Lucky Block" },
} :: { FunnelStep }

-- Wave Web chase (per-chase). Death / quit = drop-off after Started.
M.WAVE_CHASE_FUNNEL = "WaveChase_v2"
M.WAVE_CHASE = {
	{ step = 1, id = "wave_started", name = "Chase Started" },
	{ step = 2, id = "wave_escaped", name = "Escaped to Safezone" },
} :: { FunnelStep }

----------------------------------------------------------------
-- Store checkout (per-checkout session)
----------------------------------------------------------------

M.SHOP_FUNNEL = "StoreCheckout_v2"
M.SHOP = {
	{ step = 1, name = "Opened Store" },
	{ step = 2, name = "Prompted Purchase" },
	{ step = 3, name = "Purchase Completed" },
}

----------------------------------------------------------------
-- Session stay — drop-off = they left. New session each join.
----------------------------------------------------------------

M.SESSION_STAY_FUNNEL = "SessionStay_v2"
M.SESSION_STAY = {
	{ step = 1, id = "joined", name = "Joined", sec = 0 },
	{ step = 2, id = "stay_30s", name = "Still here 30s", sec = 30 },
	{ step = 3, id = "stay_2m", name = "Still here 2 min", sec = 120 },
	{ step = 4, id = "stay_5m", name = "Still here 5 min", sec = 300 },
	{ step = 5, id = "stay_10m", name = "Still here 10 min", sec = 600 },
	{ step = 6, id = "stay_20m", name = "Still here 20 min", sec = 1200 },
} :: { FunnelStep }

----------------------------------------------------------------
-- One visit of the harvest loop. Leave / die = drop-off.
----------------------------------------------------------------

M.SESSION_LOOP_FUNNEL = "SessionLoop_v2"
M.SESSION_LOOP = {
	{ step = 1, id = "joined", name = "Joined" },
	{ step = 2, id = "opened_bush", name = "Opened a Bush" },
	{ step = 3, id = "chase_started", name = "Cobweb Chase Started" },
	{ step = 4, id = "chase_escaped", name = "Escaped Cobweb" },
	{ step = 5, id = "claimed_brainrot", name = "Claimed a Brainrot" },
	{ step = 6, id = "placed_on_stand", name = "Placed on Stand" },
} :: { FunnelStep }

----------------------------------------------------------------
-- Lookups
----------------------------------------------------------------

function M.onboardingById(id: string): OnboardingStep?
	for _, def in M.ONBOARDING do
		if def.id == id then
			return def
		end
	end
	return nil
end

function M.onboardingByStep(step: number): OnboardingStep?
	for _, def in M.ONBOARDING do
		if def.step == step then
			return def
		end
	end
	return nil
end

local function findIn(list: { FunnelStep }, id: string): FunnelStep?
	for _, def in list do
		if def.id == id then
			return def
		end
	end
	return nil
end

function M.progressionById(id: string): FunnelStep?
	return findIn(M.WORLD, id)
end

function M.progressionForLand(land: number): FunnelStep?
	for _, def in M.WORLD do
		if def.land == land then
			return def
		end
	end
	return nil
end

function M.timQuestById(id: string): FunnelStep?
	return findIn(M.TIM_QUEST, id)
end

function M.timQuestForIndex(questIndex: number): FunnelStep?
	for _, def in M.TIM_QUEST do
		if def.questIndex == questIndex then
			return def
		end
	end
	return nil
end

function M.rebirthForCount(count: number): FunnelStep?
	for _, def in M.REBIRTH do
		if def.rebirthCount == count then
			return def
		end
	end
	return nil
end

function M.coreLoopById(id: string): FunnelStep?
	return findIn(M.CORE_LOOP, id)
end

function M.waveChaseById(id: string): FunnelStep?
	return findIn(M.WAVE_CHASE, id)
end

function M.sessionStayById(id: string): FunnelStep?
	return findIn(M.SESSION_STAY, id)
end

function M.sessionLoopById(id: string): FunnelStep?
	return findIn(M.SESSION_LOOP, id)
end

return M
