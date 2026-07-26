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
	freeStealCount: number,
	packPurchases: { [string]: number },
}

export type GiftedGamepassesSaveData = { [string]: boolean }

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
}

export type PlayerSaveData = {
	version: number,
	cash: number,
	rebirthCount: number,
	powerLevel: number,
	ropeLevel: number,
	carryLevel: number,
	totalPlayTimeSeconds: number,
	baseFloorLevel: number,
	dailyDayClaimed: number,
	dailyClaimedMask: number,
	dailyNextAt: number,
	dailySkipAllOwned: boolean,
	dailyCashBoostPercent: number,
	indexUnlocks: { string },
	goldenNames: { string },
	inventory: { BrainrotInvSaveEntry },
	parkedSlots: { number },
	equipSlot: number?,
	stands: { StandSaveEntry },
	lastSavedAt: number,
	storePurchases: StorePurchasesSaveData?,
	giftedGamepasses: GiftedGamepassesSaveData?,
	settings: PlayerSettingsSaveData?,
	tutorialCompleted: boolean?,
	tutorialCashGranted: boolean?,
}

local M = {}

M.VERSION = 1
M.TOTAL_PLAY_TIME_ATTR = "TotalPlayTimeSeconds"
M.LOADED_ATTR = "PlayerDataLoaded"
M.TUTORIAL_COMPLETED_ATTR = "TutorialCompleted"
M.TUTORIAL_REPLAY_ATTR = "TutorialReplayNonce"
M.TUTORIAL_CASH_GRANTED_ATTR = "TutorialCashGranted"

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
M.DEFAULT_SETTINGS = {
	musicVolume = 0.5,
	sfxVolume = 0.5,
	uiSoundsEnabled = true,
	slowWalkEnabled = false,
	showOtherBrainrots = true,
	brainrotVfxEnabled = true,
	globalMessagesEnabled = true,
	spiderCutsceneEnabled = true,
	shopCutsceneEnabled = true,
	lowGraphicsEnabled = false,
} :: PlayerSettingsSaveData

return M
