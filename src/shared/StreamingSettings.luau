-- [ACTIVE] StreamingSettings
--[[
	Do not write StreamOutBehavior / PredictiveStreamingMode — this Studio
	build does not expose those Workspace members (apply used to warn every join).
	Radii live in the place file / default.project.json.
]]

local M = {}

M.CUSTOM_CULL_ENABLED = false

function M.isCustomEnabled(): boolean
	return false
end

function M.gameplayMin(): number
	return 512
end

function M.gameplayTarget(): number
	return 1024
end

function M.apply(_workspaceInst: Workspace)
end

return M
