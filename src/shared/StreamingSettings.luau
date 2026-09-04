-- [ACTIVE] StreamingSettings
--[[
	Place files often still have Studio's 256/512 + LowMemory + PauseOutsideLoadedArea.
	That keeps half the map resident and pauses you when you swing into an
	unloaded land. Gameplay uses a small guaranteed bubble and opportunistic fill.
]]

local RunService = game:GetService("RunService")

local M = {}

function M.gameplayMin(): number
	return if RunService:IsStudio() then 80 else 112
end

function M.gameplayTarget(): number
	return if RunService:IsStudio() then 200 else 320
end

function M.apply(workspaceInst: Workspace)
	if workspaceInst.StreamingEnabled ~= true then
		workspaceInst.StreamingEnabled = true
	end
	local wsAny = workspaceInst :: any
	local minR = M.gameplayMin()
	local targetR = M.gameplayTarget()
	pcall(function()
		wsAny.StreamingMinRadius = minR
		wsAny.StreamingTargetRadius = targetR
	end)
	pcall(function()
		workspaceInst.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
	end)
	pcall(function()
		local mode = (Enum :: any).StreamingIntegrityMode
		if mode and mode.MinimumRadiusPause then
			wsAny.StreamingIntegrityMode = mode.MinimumRadiusPause
		end
	end)
	pcall(function()
		local pred = (Enum :: any).PredictiveStreamingMode
		if pred and pred.Enabled then
			wsAny.PredictiveStreamingMode = pred.Enabled
		end
	end)
end

return M
