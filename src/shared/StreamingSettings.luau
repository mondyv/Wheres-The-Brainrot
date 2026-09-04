-- [ACTIVE] StreamingSettings
--[[
	Small guaranteed bubble, opportunistic fill, never pause the player.
	Studio's 256/512 + LowMemory + PauseOutsideLoadedArea is what froze swings
	and sat at ~9GB. Do not RequestStreamAroundAsync from gameplay — that dumps
	Studio play-solo: do not touch Workspace streaming. The whole place is already
	in-process; shrinking the bubble cannot free ~9GB and froze the character.
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
	-- Current land + ~2 ahead so those islands are not empty shells.
	if RunService:IsStudio() then
		return 140
	end
	if UserInputService.TouchEnabled then
		return 240
	end
	return 300
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
		if pred and pred.Disabled then
			wsAny.PredictiveStreamingMode = pred.Disabled
		end
	end)
end

return M
