--[[
	PlotDiagnostics (client) — tracks stand display models + heavy client scans.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlotDiagnostics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotDiagnostics"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))

local player = Players.LocalPlayer
local STAND_TAG = "BrainrotStand"
local watchedDisplays: { [Model]: boolean } = {}

local function watchDisplayModel(model: Model)
	if watchedDisplays[model] then
		return
	end
	watchedDisplays[model] = true
	PlotDiagnostics.log("Display", "spawned " .. PlotDiagnostics.modelSummary(model))
	model.Destroying:Once(function()
		watchedDisplays[model] = nil
		PlotDiagnostics.warn("Display", "destroyed " .. model:GetFullName())
	end)
	model:GetPropertyChangedSignal("Parent"):Connect(function()
		if not model.Parent then
			PlotDiagnostics.warn("Display", "unparented " .. model:GetFullName())
		end
	end)
end

local function scanStand(stand: Model)
	for _, ch in stand:GetChildren() do
		if ch:IsA("Model") and ch:GetAttribute("BrainrotStandDisplay") == true then
			watchDisplayModel(ch :: Model)
		end
	end
	stand.ChildAdded:Connect(function(ch)
		if ch:IsA("Model") and ch:GetAttribute("BrainrotStandDisplay") == true then
			task.defer(function()
				watchDisplayModel(ch :: Model)
			end)
		end
	end)
end

local function boot()
	local folder = PlotPaths.waitForSpawnAndBasesFolder(60)
	if not folder then
		PlotDiagnostics.warn("Boot", "Spawn And Bases folder missing on client")
		return
	end
	for _, ch in folder:GetChildren() do
		if PlotPaths.isPlotRoot(ch) then
			for _, d in ch:GetDescendants() do
				if d:IsA("Model") and CollectionService:HasTag(d, STAND_TAG) then
					scanStand(d :: Model)
				end
			end
		end
	end
	folder.ChildAdded:Connect(function(ch)
		if not PlotPaths.isPlotRoot(ch) then
			return
		end
		task.defer(function()
			for _, d in ch:GetDescendants() do
				if d:IsA("Model") and CollectionService:HasTag(d, STAND_TAG) then
					scanStand(d :: Model)
				end
			end
		end)
	end)
	PlotDiagnostics.log("Boot", "Client diagnostics active — filter Output with PlotDiag")
end

if PlotDiagnostics.ENABLED then
	task.defer(boot)
end
