-- [ACTIVE] WebTrapConfig
--[[
	Spider-web hazard under Workspace.Map.Webs — stuck, slide, bleed out.
--]]

local M = {}

M.TRAPPED_ATTR = "WebTrapped"
M.WEBS_FOLDER_PATH = { "Map", "Webs" }

M.TOUCH_DEBOUNCE = 1.25
M.BLEED_DURATION = 7
M.SLIDE_SPEED = 1.35
M.MAX_SLIDE_DISTANCE = 10
M.STICK_OFFSET = 0.45

return M
