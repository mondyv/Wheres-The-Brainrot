-- [ACTIVE] GlobalRaritySpawnConfig
--[[
	Per-server rarity spawn timers — each new server starts its own countdown.
	Mythical 10:00, Legendary 20:00, Godly 30:00, Secret 40:00.
]]

local M = {}

export type TierId = "mythic" | "legendary" | "brainrot god" | "secret"

export type TierDef = {
	id: TierId,
	intervalSec: number,
	displayName: string,
	timerRowName: string,
	timerRowAliases: { string },
	spawnMessage: string,
	-- Sign spawns only on bushes inside hitboxes with at least this display luck (e.g. 1250x).
	minDisplayLuck: number,
}

M.TIERS = {
	{
		id = "mythic",
		intervalSec = 600,
		displayName = "Mythical",
		timerRowName = "Mythical",
		timerRowAliases = { "Mythical" },
		spawnMessage = "A Mythical brainrot has spawned!",
		minDisplayLuck = 150,
	},
	{
		id = "legendary",
		intervalSec = 1200,
		displayName = "Legendary",
		timerRowName = "Legendary",
		timerRowAliases = { "Legendary" },
		spawnMessage = "A Legendary brainrot has spawned!",
		minDisplayLuck = 450,
	},
	{
		id = "brainrot god",
		intervalSec = 1800,
		displayName = "GODLY",
		timerRowName = "BrainrotGod",
		timerRowAliases = { "BrainrotGod", "Godly", "GODLY" },
		spawnMessage = "A GODLY brainrot has spawned!",
		minDisplayLuck = 1000,
	},
	{
		id = "secret",
		intervalSec = 2400,
		displayName = "Secret",
		timerRowName = "Secret",
		timerRowAliases = { "Secret" },
		spawnMessage = "A Secret brainrot has spawned!",
		minDisplayLuck = 1000,
	},
} :: { TierDef }

M.MARKER_DURATION_SEC = 60
M.MIN_SPAWN_LAND = 3
M.MAX_SPAWN_LAND = 10

M.SPAWN_CMD_TOPIC = "GlobalRaritySpawnCmd_v1"

M.REMOTE_FOLDER = "GlobalRaritySpawnRemotes"
M.UPDATED_REMOTE = "Updated"

M.ACTIVE_RARITY_ATTR = "GlobalRarityActiveRarity"
M.ACTIVE_BUSH_KEY_ATTR = "GlobalRarityActiveBushKey"
M.ACTIVE_ENDS_ATTR = "GlobalRarityActiveEndsAt"
M.ACTIVE_NAME_ATTR = "GlobalRarityActiveBrainrotName"
M.ACTIVE_MUTATION_ATTR = "GlobalRarityActiveMutation"
M.ACTIVE_ICON_ATTR = "GlobalRarityActiveIcon"
M.ACTIVE_POS_ATTR = "GlobalRarityActivePos"

M.BUSH_GLOBAL_SPAWN_ATTR = "GlobalRaritySpawn"
M.BUSH_GLOBAL_KEY_ATTR = "GlobalRaritySpawnKey"
M.BUSH_GLOBAL_RARITY_ATTR = "GlobalRaritySpawnRarity"
M.BUSH_TAG = "GlobalRaritySpawnBush"

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
