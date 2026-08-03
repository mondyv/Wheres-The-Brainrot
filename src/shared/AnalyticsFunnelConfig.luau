-- [ACTIVE] AnalyticsFunnelConfig
--[[
	Creator Hub Analytics funnel step definitions.
	Onboarding = one-time FTUE (LogOnboardingFunnelStepEvent).
	Progression / Shop = LogFunnelStepEvent (shop uses a per-checkout session id).
]]

local M = {}

export type OnboardingStep = {
	step: number,
	id: string,
	name: string,
}

-- Detailed FTUE funnel — mirrors TutorialConfig.STEPS plus join / complete.
M.ONBOARDING = {
	{ step = 1, id = "player_joined", name = "Player Joined" },
	{ step = 2, id = "got_starter_cash", name = "Got Starter Cash" },
	{ step = 3, id = "visited_upgrade", name = "Visited Upgrade Stand" },
	{ step = 4, id = "bought_power", name = "Bought First Power" },
	{ step = 5, id = "swung_vine", name = "Swung Across Vine" },
	{ step = 6, id = "opened_bush", name = "Opened Bush" },
	{ step = 7, id = "claimed_brainrot", name = "Claimed Brainrot" },
	{ step = 8, id = "returned_to_base", name = "Returned to Base" },
	{ step = 9, id = "placed_on_stand", name = "Placed on Stand" },
	{ step = 10, id = "upgraded_brainrot", name = "Upgraded Brainrot" },
	{ step = 11, id = "tutorial_completed", name = "Tutorial Completed" },
	{ step = 12, id = "opened_starter_lucky_block", name = "Opened Starter Lucky Block" },
} :: { OnboardingStep }

-- Tutorial objective id → onboarding step id (fired when that objective completes).
M.TUTORIAL_ID_TO_ONBOARDING = {
	grantCash = "got_starter_cash",
	visitUpgrade = "visited_upgrade",
	buyPower = "bought_power",
	swingLand1 = "swung_vine",
	searchBush = "opened_bush",
	claimBrainrot = "claimed_brainrot",
	goToBase = "returned_to_base",
	placeOnPlot = "placed_on_stand",
	upgradeBrainrot = "upgraded_brainrot",
}

M.PROGRESSION_FUNNEL = "WorldProgression"

M.PROGRESSION = {
	{ step = 1, id = "land_2", name = "Reached Land 2", land = 2 },
	{ step = 2, id = "land_3", name = "Reached Land 3", land = 3 },
	{ step = 3, id = "land_4", name = "Reached Land 4", land = 4 },
	{ step = 4, id = "land_5", name = "Reached Land 5", land = 5 },
	{ step = 5, id = "land_6", name = "Reached Land 6", land = 6 },
	{ step = 6, id = "land_7", name = "Reached Land 7", land = 7 },
	{ step = 7, id = "land_8", name = "Reached Land 8", land = 8 },
	{ step = 8, id = "land_9", name = "Reached Land 9", land = 9 },
	{ step = 9, id = "land_10", name = "Reached Land 10", land = 10 },
	{ step = 10, id = "first_rebirth", name = "First Rebirth" },
	{ step = 11, id = "tim_quest_1", name = "Tim Quest 1 Complete", questIndex = 1 },
	{ step = 12, id = "tim_quest_3", name = "Tim Quest 3 Complete", questIndex = 3 },
	{ step = 13, id = "tim_quest_5", name = "Tim Quest 5 Complete", questIndex = 5 },
	{ step = 14, id = "tim_quest_10", name = "Tim Quest 10 Complete", questIndex = 10 },
	{ step = 15, id = "tim_all_quests", name = "All Tim Quests Complete" },
}

M.SHOP_FUNNEL = "StoreCheckout"

M.SHOP = {
	{ step = 1, name = "Opened Store" },
	{ step = 2, name = "Prompted Purchase" },
	{ step = 3, name = "Purchase Completed" },
}

M.ONBOARDING_MAX_STEP = 12

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

function M.progressionById(id: string): any?
	for _, def in M.PROGRESSION do
		if def.id == id then
			return def
		end
	end
	return nil
end

function M.progressionForLand(land: number): any?
	for _, def in M.PROGRESSION do
		if def.land == land then
			return def
		end
	end
	return nil
end

function M.progressionForQuest(questIndex: number): any?
	for _, def in M.PROGRESSION do
		if def.questIndex == questIndex then
			return def
		end
	end
	return nil
end

return M
