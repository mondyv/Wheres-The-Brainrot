--[[
	PlotDiagnostics (server) — perf counters + stand placement traces.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotDiagnostics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotDiagnostics"))

Players.PlayerAdded:Connect(function(player)
	task.defer(function()
		local slot = player:GetAttribute("AssignedPlotSlot")
		PlotDiagnostics.log("Player", string.format("%s joined slot=%s", player.Name, tostring(slot)))
	end)
end)

PlotDiagnostics.log("Boot", "Server diagnostics active — filter Output with PlotDiag")
