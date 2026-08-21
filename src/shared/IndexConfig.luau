-- [ACTIVE] IndexConfig
--[[
	Index UI + golden quest tuning (shared client/server).
--]]

local M = {}

M.GOLDEN_QUEST_TARGET = 25
M.CASH_BOOST_MULT = 1.25

M.MUTATION_TABS = { "normal", "golden", "diamond", "lava", "galaxy", "rainbow" }

M.LUCKY_BLOCK_TAB = "luckyblock"

M.TAB_BUTTON_NAME = {
	normal = "Normal",
	golden = "Gold",
	diamond = "Diamond",
	lava = "Lava",
	galaxy = "Galaxy",
	rainbow = "Rainbow",
}

M.TAB_DISPLAY_NAME = {
	normal = "Normal",
	golden = "Gold",
	diamond = "Diamond",
	lava = "Lava",
	galaxy = "Galaxy",
	rainbow = "Rainbow",
	luckyblock = "Lucky Blocks",
}

M.TAB_NOTIF_NAME = {
	normal = "Notif Normal",
	golden = "Notif Gold",
	diamond = "Notif Diamond",
	lava = "Notif Lava",
	galaxy = "Notif Galaxy",
	rainbow = "Notif Rainbow",
	luckyblock = "Notif LuckyBlock",
}

M.HEADER_LUCKY_BLOCK_ICON = "Lucky Block Icon"

M.RARITY_SORT = {
	common = 1,
	uncommon = 2,
	rare = 3,
	epic = 4,
	mythic = 5,
	legendary = 6,
	["brainrot god"] = 7,
	secret = 8,
}

function M.unlockKey(name: string, mutationId: string): string
	return name .. ":" .. mutationId
end

-- One-time Index Collect XP (modest vs sell/lucky-block grants).
M.COLLECT_XP_BY_RARITY = {
	common = 6,
	uncommon = 10,
	rare = 16,
	epic = 24,
	mythic = 36,
	legendary = 50,
	["brainrot god"] = 70,
	secret = 90,
}

M.COLLECT_MUTATION_BONUS = {
	normal = 0,
	golden = 3,
	diamond = 5,
	lava = 6,
	galaxy = 8,
	rainbow = 10,
	luckyblock = 4,
}

function M.collectXpFor(rarity: string?, mutationId: string?): number
	local r = string.lower(if typeof(rarity) == "string" then rarity else "common")
	local base = M.COLLECT_XP_BY_RARITY[r] or 8
	local mut = if typeof(mutationId) == "string" then mutationId else "normal"
	local bonus = M.COLLECT_MUTATION_BONUS[mut] or 0
	return math.clamp(math.floor(base + bonus), 4, 120)
end

return M
