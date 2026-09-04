-- [ACTIVE] StreamingSettings
--[[
	Live always applies a real stream bubble + predictive fill + no pause.
	Turning that off last time left the published place on PauseOutsideLoadedArea
	with a tiny bubble, so swinging showed empty air.

	CUSTOM_CULL_ENABLED parks grass/trees. Leave that false unless we need it again.

	Studio play-solo: apply() never touches Workspace.
]]

local RunService = game:GetService("RunService")

local M = {}

-- Park/restore land grass. Streaming radii still apply when this is false.
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
	-- Play-solo already has the whole place in-process. Shrinking the bubble
	-- and reparenting grass is what froze movement and did not free RAM.
	if RunService:IsStudio() then
		return
	end
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
end

return M
