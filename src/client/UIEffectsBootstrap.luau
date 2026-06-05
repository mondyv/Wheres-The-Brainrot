-- [ACTIVE] UIEffectsBootstrap
-- Wires shared UI polish on frames/buttons not covered by a dedicated controller.
local Players = game:GetService("Players")

local UIButtonEffects = require(script.Parent.UIButtonEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local M = {}

function M.init()
	local main = PlayerGuiMain.ensure(player)
	local frames = main:WaitForChild("Frames", 30)
	if not frames then
		return
	end

	local HUDController = require(script.Parent.HUDController)

	UIButtonEffects.wireAllFrameCloseButtons(frames, function(frame: Frame)
		if HUDController.getCurrentFrame() == frame then
			HUDController.closeCurrentFrame()
		else
			frame.Visible = false
		end
	end)
end

return M
