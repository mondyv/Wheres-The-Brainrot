-- [ACTIVE] StreamingSettings
--[[
	Small guaranteed bubble, opportunistic fill, never pause the player.
	Studio's 256/512 + LowMemory + PauseOutsideLoadedArea is what froze swings
	and sat at ~9GB. Do not RequestStreamAroundAsync from gameplay — that dumps
	the next land's grass in one hitch.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local M = {}

function M.gameplayMin(): number
	if RunService:IsStudio() then
		return 64
	end
	if UserInputService.TouchEnabled then
		return 64
	end
	return 80
end

function M.gameplayTarget(): number
	-- Far enough to see the next island shell (~150–180 studs), not 3 lands of grass.
	if RunService:IsStudio() then
		return 140
	end
	if UserInputService.TouchEnabled then
		return 140
	end
	return 180
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
		if pred and pred.Disabled then
			wsAny.PredictiveStreamingMode = pred.Disabled
		end
	end)
end

return M
