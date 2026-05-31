--[[
	Ensures PlayerGui.Main exists by cloning StarterGui.Main when Roblox
	does not replicate it automatically (common in Studio / long load flows).
--]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local PlayerGuiMain = {}

function PlayerGuiMain.ensure(player: Player?): ScreenGui
	local plr = player or Players.LocalPlayer
	local playerGui = plr:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("Main")
	if existing and existing:IsA("ScreenGui") then
		existing.ResetOnSpawn = false
		return existing
	end

	local template = StarterGui:FindFirstChild("Main")
	if not template or not template:IsA("ScreenGui") then
		template = StarterGui:WaitForChild("Main", 60)
	end
	if not template or not template:IsA("ScreenGui") then
		error("[PlayerGuiMain] StarterGui.Main ScreenGui missing")
	end

	local main = template:Clone()
	main.Name = "Main"
	main.ResetOnSpawn = false
	main.Parent = playerGui
	return main
end

return PlayerGuiMain
