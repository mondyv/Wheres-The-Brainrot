-- [ACTIVE] PlotDiagnostics.client
--[[
	PlotDiagnostics (client) — tracks stand display models + heavy client scans.
	Disabled by default; when off, this script returns immediately so boot stays fast.
--]]

task.defer(function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local shared = ReplicatedStorage:WaitForChild("Shared", 30)
	if not shared then
		return
	end
	local plotDiagModule = shared:WaitForChild("PlotDiagnostics", 10)
	if not plotDiagModule then
		return
	end
	local PlotDiagnostics = require(plotDiagModule)
	if not PlotDiagnostics.ENABLED then
		return
	end

	local CollectionService = game:GetService("CollectionService")
	local Players = game:GetService("Players")
	local PlotPaths = require(shared:WaitForChild("PlotPaths"))

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

	local function scanPlotDescendants(plotRoot: Instance)
		local scanned = 0
		for _, d in plotRoot:GetDescendants() do
			scanned += 1
			if scanned % 4000 == 0 then
				task.wait()
			end
			if d:IsA("Model") and CollectionService:HasTag(d, STAND_TAG) then
				scanStand(d :: Model)
			end
		end
	end

	local function boot()
		local folder = PlotPaths.waitForSpawnAndBasesFolder(60)
		if not folder then
			PlotDiagnostics.warn("Boot", "Spawn And Bases folder missing on client")
			return
		end
		for _, ch in folder:GetChildren() do
			if PlotPaths.isPlotRoot(ch) then
				scanPlotDescendants(ch)
			end
		end
		folder.ChildAdded:Connect(function(ch)
			if not PlotPaths.isPlotRoot(ch) then
				return
			end
			task.defer(function()
				scanPlotDescendants(ch)
			end)
		end)
		PlotDiagnostics.log("Boot", "Client diagnostics active — filter Output with PlotDiag")
	end

	task.defer(boot)
end)
