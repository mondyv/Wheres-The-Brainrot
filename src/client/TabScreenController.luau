-- [ACTIVE] TabScreenController
--[[
	Roblox's built-in Tab player list reads leaderstats (see PlayerListStats.server.luau).
	Cash + Rebirth columns appear next to each player's name automatically.
--]]

local StarterGui = game:GetService("StarterGui")

local TabScreenController = {}

function TabScreenController.init()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
	end)
end

return TabScreenController
