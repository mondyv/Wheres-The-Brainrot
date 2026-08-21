-- [ACTIVE] PlayerDataSchema
--[[
	Serialized player save shape for PlayerDataService (DataStore key owned by PlayerDataService only).
--]]

export type BrainrotInvSaveEntry = {
	name: string,
	icon: string,
	sourcePath: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

export type StandSaveEntry = {
	standName: string,
	storyName: string?,
	brainrotName: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
	sourcePath: string,
	accumulated: number,
}

export type StorePurchasesSaveData = {
	exclusiveOwned: boolean,
	freeUncommonClaimed: boolean,
	groupRewardClaimed: boolean,
	groupRewardLiked: boolean,
	freeStealCount: number,
	packPurchases: { [string]: number },
}

export type GiftedGamepassesSaveData = { [string]: boolean }
export type PurchasedGamepassesSaveData = { [string]: boolean }

export type PlayerSettingsSaveData = {
	musicVolume: number,
	sfxVolume: number,
	uiSoundsEnabled: boolean,
	slowWalkEnabled: boolean,
	showOtherBrainrots: boolean,
	brainrotVfxEnabled: boolean,
	globalMessagesEnabled: boolean,
	spiderCutsceneEnabled: boolean,
	shopCutsceneEnabled: boolean,
	lowGraphicsEnabled: boolean,
	holdToSwingEnabled: boolean,
}

export type PlayerSaveData = {
	version: number,
	cash: number,
	rebirthCount: number,
	powerLevel: number,
	ropeLevel: number,
	carryLevel: number,
	workoutPower: number?,
	workoutPowerMax: number?, -- true ceiling; Edit can restore active Power up to this
	ownedGears: string?, -- comma-separated gear ids
	equippedGearId: number?,
	powerEdited: boolean?,
	powerForceResetV1: boolean?, -- one-time wipe of test workout Power
	totalPlayTimeSeconds: number,
	baseFloorLevel: number,
	dailyDayClaimed: number,
	dailyClaimedMask: number,
	dailyNextAt: number,
	dailySkipAllOwned: boolean,
	dailyCashBoostPercent: number,
	indexUnlocks: { string },
	indexCollected: { string }?,
	goldenNames: { string },
	inventory: { BrainrotInvSaveEntry },
	parkedSlots: { number },
	equipSlot: number?,
	stands: { StandSaveEntry },
	lastSavedAt: number,
	storePurchases: StorePurchasesSaveData?,
	giftedGamepasses: GiftedGamepassesSaveData?,
	purchasedGamepasses: PurchasedGamepassesSaveData?,
	settings: PlayerSettingsSaveData?,
	tutorialCompleted: boolean?,
	tutorialCashGranted: boolean?,
	tutorialFirstBushClaimed: boolean?,
	timCheeseIntroDone: boolean?,
	timCheeseQuestIndex: number?, -- 1..N active quest, 0 = none
	timCheeseQuestProgress: number?,
	timCheeseCompletedCount: number?, -- how many quests fully claimed
	timCheeseHarvestProgress: number?, -- progress counter for harvest-kind quests
	brainrotAcceptCount: number?, -- career floating-claim accepts (base-return guide)
	playerLevel: number?,
	playerXp: number?, -- XP into current playerLevel
}

local M = {}

M.VERSION = 1
M.TOTAL_PLAY_TIME_ATTR = "TotalPlayTimeSeconds"
M.LOADED_ATTR = "PlayerDataLoaded"
M.LOAD_FAILED_ATTR = "PlayerDataLoadFailed"
M.TUTORIAL_COMPLETED_ATTR = "TutorialCompleted"
M.TUTORIAL_REPLAY_ATTR = "TutorialReplayNonce"
M.TUTORIAL_CASH_GRANTED_ATTR = "TutorialCashGranted"
M.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR = "TutorialFirstBushClaimed"
M.TUTORIAL_SOFT_RESPAWN_ATTR = "TutorialSoftRespawn"
-- Workspace:GetServerTimeNow() deadline for frictionless death (plot soft-respawn, no revive UI).
M.FRICTIONLESS_DEATH_UNTIL_ATTR = "FrictionlessDeathUntil"
M.FRICTIONLESS_DEATH_SECONDS = 600
M.TIM_CHEESE_INTRO_ATTR = "TimCheeseIntroDone"
M.TIM_CHEESE_QUEST_INDEX_ATTR = "TimCheeseQuestIndex"
M.TIM_CHEESE_QUEST_PROGRESS_ATTR = "TimCheeseQuestProgress"
M.TIM_CHEESE_COMPLETED_ATTR = "TimCheeseCompletedCount"
M.TIM_CHEESE_QUEST_READY_ATTR = "TimCheeseQuestReady" -- true when active quest is complete, claim pending
M.TIM_CHEESE_HARVEST_ATTR = "TimCheeseHarvestProgress"
M.BRAINROT_ACCEPT_COUNT_ATTR = "BrainrotAcceptCount"
M.BASE_RETURN_GUIDE_ACCEPTS = 20

M.SETTINGS_MUSIC_VOLUME_ATTR = "SettingsMusicVolume"
M.SETTINGS_SFX_VOLUME_ATTR = "SettingsSfxVolume"
M.SETTINGS_UI_SOUNDS_ATTR = "SettingsUiSoundsEnabled"
M.SETTINGS_SLOW_WALK_ATTR = "SettingsSlowWalkEnabled"
M.SETTINGS_SHOW_OTHERS_ATTR = "SettingsShowOtherBrainrots"
M.SETTINGS_BRAINROT_VFX_ATTR = "SettingsBrainrotVfxEnabled"
M.SETTINGS_GLOBAL_MESSAGES_ATTR = "SettingsGlobalMessagesEnabled"
M.SETTINGS_SPIDER_CUTSCENE_ATTR = "SettingsSpiderCutsceneEnabled"
M.SETTINGS_SHOP_CUTSCENE_ATTR = "SettingsShopCutsceneEnabled"
M.SETTINGS_LOW_GRAPHICS_ATTR = "SettingsLowGraphicsEnabled"
M.SETTINGS_HOLD_TO_SWING_ATTR = "SettingsHoldToSwingEnabled"
M.DEFAULT_SETTINGS = {
	musicVolume = 0.5,
	sfxVolume = 0.5,
	uiSoundsEnabled = true,
	slowWalkEnabled = false,
	showOtherBrainrots = true,
	brainrotVfxEnabled = true,
	globalMessagesEnabled = true,
	spiderCutsceneEnabled = true,
	-- Off by default: charge bar + overhead welcome, then open the panel (no Undertale cutscene).
	shopCutsceneEnabled = false,
	lowGraphicsEnabled = false,
	-- Default off: press jump to attach, press jump again to release.
	holdToSwingEnabled = false,
} :: PlayerSettingsSaveData

return M
