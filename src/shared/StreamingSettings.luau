-- [ACTIVE] StreamingSettings
--[[
	Never writes Workspace streaming properties. Studio / the place file owns
	MinRadius, TargetRadius, StreamOutBehavior, and PredictiveStreamingMode.
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
