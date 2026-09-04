-- [ACTIVE] StreamingSettings
--[[
	Place-file streaming is what the client boots with. Opportunistic + a small
	bubble + MinimumRadiusPause dumps Huge trees and pauses join.

	apply() runs in Studio and live so Play-solo matches the published game.
	CUSTOM_CULL_ENABLED stays off. Persist of trees is a separate live pin.
]]

local M = {}

M.CUSTOM_CULL_ENABLED = false

function M.isCustomEnabled(): boolean
	return M.CUSTOM_CULL_ENABLED == true
end

function M.gameplayMin(): number
	return 4096
end

function M.gameplayTarget(): number
	return 4096
end

function M.apply(workspaceInst: Workspace)
	if workspaceInst.StreamingEnabled ~= true then
		workspaceInst.StreamingEnabled = true
	end
	local wsAny = workspaceInst :: any
	pcall(function()
		wsAny.StreamingMinRadius = M.gameplayMin()
		wsAny.StreamingTargetRadius = M.gameplayTarget()
	end)
	pcall(function()
		local behavior = Enum.StreamOutBehavior
		if behavior.LowMemory then
			workspaceInst.StreamOutBehavior = behavior.LowMemory
		elseif behavior.Default then
			workspaceInst.StreamOutBehavior = behavior.Default
		end
	end)
	pcall(function()
		local mode = (Enum :: any).StreamingIntegrityMode
		if mode and mode.Disabled then
			wsAny.StreamingIntegrityMode = mode.Disabled
		end
	end)
	pcall(function()
		local pred = (Enum :: any).PredictiveStreamingMode
		if pred and pred.Enabled then
			wsAny.PredictiveStreamingMode = pred.Enabled
		end
	end)
	pcall(function()
		local msb = (Enum :: any).ModelStreamingBehavior
		if msb and msb.Improved then
			wsAny.ModelStreamingBehavior = msb.Improved
		end
	end)
end

return M
