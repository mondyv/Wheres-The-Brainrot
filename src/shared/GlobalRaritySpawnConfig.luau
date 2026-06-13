-- [ACTIVE] GlobalRaritySpawnConfig
--[[
	Global timed rarity spawns — same countdown across all servers.
	Mythical 5:00, Legendary 10:00, Godly 15:00, Secret 20:00.
]]

local M = {}

export type TierId = "mythic" | "legendary" | "brainrot god" | "secret"

export type TierDef = {
	id: TierId,
	intervalSec: number,
	displayName: string,
	timerRowName: string,
	spawnMessage: string,
}

M.TIERS = {
	{
		id = "mythic",
		intervalSec = 300,
		displayName = "Mythical",
		timerRowName = "Mythical",
		spawnMessage = "A Mythical brainrot has spawned!",
	},
	{
		id = "legendary",
		intervalSec = 600,
		displayName = "Legendary",
		timerRowName = "Legendary",
		spawnMessage = "A Legendary brainrot has spawned!",
	},
	{
		id = "brainrot god",
		intervalSec = 900,
		displayName = "GODLY",
		timerRowName = "BrainrotGod",
		spawnMessage = "A GODLY brainrot has spawned!",
	},
	{
		id = "secret",
		intervalSec = 1200,
		displayName = "Secret",
		timerRowName = "Secret",
		spawnMessage = "A Secret brainrot has spawned!",
	},
} :: { TierDef }

M.MARKER_DURATION_SEC = 60
M.MIN_SPAWN_LAND = 3
M.MAX_SPAWN_LAND = 8

M.DATASTORE_NAME = "GlobalRaritySpawn_v1"
M.STATE_KEY = "state"
M.MESSAGING_TOPIC = "GlobalRaritySpawn_v1"

M.REMOTE_FOLDER = "GlobalRaritySpawnRemotes"
M.UPDATED_REMOTE = "Updated"

M.ACTIVE_RARITY_ATTR = "GlobalRarityActiveRarity"
M.ACTIVE_BUSH_KEY_ATTR = "GlobalRarityActiveBushKey"
M.ACTIVE_ENDS_ATTR = "GlobalRarityActiveEndsAt"
M.ACTIVE_NAME_ATTR = "GlobalRarityActiveBrainrotName"
M.ACTIVE_MUTATION_ATTR = "GlobalRarityActiveMutation"
M.ACTIVE_ICON_ATTR = "GlobalRarityActiveIcon"

M.BUSH_GLOBAL_SPAWN_ATTR = "GlobalRaritySpawn"
M.BUSH_GLOBAL_KEY_ATTR = "GlobalRaritySpawnKey"
M.BUSH_GLOBAL_RARITY_ATTR = "GlobalRaritySpawnRarity"

M.TIMER_ATTR_PREFIX = "GlobalRarityTimer_"

function M.timerAttrForTier(tierId: TierId): string
	return M.TIMER_ATTR_PREFIX .. string.gsub(tierId, " ", "_")
end

function M.tierById(tierId: string): TierDef?
	local key = string.lower(tierId)
	for _, tier in M.TIERS do
		if tier.id == key or string.lower(tier.displayName) == key then
			return tier
		end
		if key == "godly" or key == "brainrotgod" or key == "god" then
			if tier.id == "brainrot god" then
				return tier
			end
		end
		if key == "mythical" and tier.id == "mythic" then
			return tier
		end
	end
	return nil
end

function M.formatCountdown(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	local m = math.floor(s / 60)
	local r = s % 60
	return string.format("%d:%02d", m, r)
end

return M
