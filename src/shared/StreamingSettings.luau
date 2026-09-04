-- [ACTIVE] StreamingSettings
--[[
	Keep a playable bubble and dump far islands. 4096 + LowMemory held the
	whole map and ran at ~12 FPS.

	Huge trees stay Persistent (separate pin) so the forest does not vanish
	on swing. Integrity Disabled so join does not pause. Predictive on so
	the next island fills while you fly.
]]

local M = {}

M.CUSTOM_CULL_ENABLED = false

function M.isCustomEnabled(): boolean
	return M.CUSTOM_CULL_ENABLED == true
end

function M.gameplayMin(): number
	return 512
end

function M.gameplayTarget(): number
	return 1080
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
		workspaceInst.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
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
