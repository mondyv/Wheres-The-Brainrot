-- [ACTIVE] IndexConfig
--[[
	Index UI + golden quest tuning (shared client/server).
--]]

local M = {}

M.GOLDEN_QUEST_TARGET = 25
M.CASH_BOOST_MULT = 1.25

M.MUTATION_TABS = { "normal", "golden", "diamond", "lava", "galaxy", "rainbow" }

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
}

M.TAB_NOTIF_NAME = {
	normal = "Notif Normal",
	golden = "Notif Gold",
	diamond = "Notif Diamond",
	lava = "Notif Lava",
	galaxy = "Notif Galaxy",
	rainbow = "Notif Rainbow",
}

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

return M
