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
}

local M = {}

M.VERSION = 1
M.TOTAL_PLAY_TIME_ATTR = "TotalPlayTimeSeconds"
M.LOADED_ATTR = "PlayerDataLoaded"

return M
