-- [ACTIVE] StreamingSettings
--[[
	Custom streaming / lag-avoidance overrides are OFF.
	Workspace uses the place-file / Roblox defaults so we can test without
	our radii, persist pins, or integrity tweaks.
]]

local M = {}

M.CUSTOM_CULL_ENABLED = false

function M.isCustomEnabled(): boolean
	return false
end

function M.gameplayMin(): number
	return 64
end

function M.gameplayTarget(): number
	return 1024
end

function M.apply(_workspaceInst: Workspace)
end

return M
