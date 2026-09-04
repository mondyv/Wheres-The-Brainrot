-- [ACTIVE] StreamingSettings
--[[
	ONE SWITCH for custom land cull + radius overrides + look-ahead streams:
	M.CUSTOM_ENABLED. False = leave streaming to Roblox (no park/restore, no
	radius shrink). Flip true to restore the custom system.

	Studio play-solo: apply() never touches Workspace. The whole place is already
	in-process; shrinking the bubble cannot free ~9GB and froze the character.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local M = {}

-- Set true to turn custom streaming / GrassCull back on.
M.CUSTOM_ENABLED = false

function M.isCustomEnabled(): boolean
	return M.CUSTOM_ENABLED == true
end

function M.gameplayMin(): number
	if RunService:IsStudio() then
		return 64
	end
	if UserInputService.TouchEnabled then
		return 80
	end
	return 96
end

function M.gameplayTarget(): number
	-- Current land + ~2–3 ahead so trees fill before you land.
	if RunService:IsStudio() then
		return 140
	end
	if UserInputService.TouchEnabled then
		return 280
	end
	return 360
end

function M.apply(workspaceInst: Workspace)
	-- Play-solo already has the whole place in-process. Shrinking the bubble
	-- and reparenting grass is what froze movement and did not free RAM.
	if not M.isCustomEnabled() then
		return
	end
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
		-- Stream along velocity so trees appear while swinging, not after landing.
		if pred and pred.Enabled then
			wsAny.PredictiveStreamingMode = pred.Enabled
		end
	end)
end

return M
