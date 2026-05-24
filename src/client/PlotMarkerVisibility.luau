--[[
	PlotMarkerVisibility (client)
	• All BillboardGuis on plots are forced off (empty-stand floating markers).
	• Decorative SurfaceGuis are forced off; stand Button / LevelPanel / floor-unlock signs stay on your plot only.

	Plot roots are direct children of Map.Spawn And Bases (e.g. Plot_1 … Plot_7).

	Must be a ModuleScript (.luau) — not .client.luau — so init.client can require it.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

local STAND_TAG = "BrainrotStand"

local baseMarkerConns: { [Instance]: { RBXScriptConnection } } = {}
local standNameWatch: { [Model]: RBXScriptConnection } = {}

local function plotIsUnclaimed(plotRoot: Instance): boolean
	return typeof(plotRoot:GetAttribute("PlotOwnerUserId")) ~= "number"
end

local function findBrainrotStandAncestor(inst: Instance): Model?
	local x: Instance? = inst
	while x do
		if x:IsA("Model") and CollectionService:HasTag(x, STAND_TAG) then
			return x :: Model
		end
		x = x.Parent
	end
	return nil
end

local function standIsEmpty(stand: Model): boolean
	local n = stand:GetAttribute("BrainrotName")
	return typeof(n) ~= "string" or n == ""
end

local function isUnderLevelPanel(inst: Instance): boolean
	local x: Instance? = inst
	while x do
		if x.Name == "LevelPanel" then
			return true
		end
		x = x.Parent
	end
	return false
end

local function ensureStandBrainrotNameWatcher(plotRoot: Instance, stand: Model, refresh: () -> ())
	if standNameWatch[stand] then
		return
	end
	standNameWatch[stand] = stand:GetAttributeChangedSignal("BrainrotName"):Connect(function()
		task.defer(refresh)
	end)
	stand.Destroying:Once(function()
		local c = standNameWatch[stand]
		if c then
			c:Disconnect()
			standNameWatch[stand] = nil
		end
	end)
end

local function isProtectedPlotUi(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "LevelPanel" or x.Name == "Button" then
			return true
		end
		if x:IsA("Model") then
			local ak = string.gsub(string.lower(x.Name), "[^a-z0-9]", "")
			if ak == "upgradeadd" or (string.find(ak, "upgrade", 1, true) and string.find(ak, "add", 1, true)) then
				return true
			end
		end
		x = x.Parent
	end
	return false
end

local function applyPlotMarker(plotRoot: Instance)
	local uid = plotRoot:GetAttribute("PlotOwnerUserId")
	local mine = typeof(uid) == "number" and uid == player.UserId
	local unclaimed = plotIsUnclaimed(plotRoot)
	for _, d in ipairs(plotRoot:GetDescendants()) do
		if d:IsA("Model") and CollectionService:HasTag(d, STAND_TAG) then
			ensureStandBrainrotNameWatcher(plotRoot, d :: Model, function()
				applyPlotMarker(plotRoot)
			end)
		end
		if d:IsA("BillboardGui") then
			(d :: LayerCollector).Enabled = false
		elseif d:IsA("SurfaceGui") then
			if not isProtectedPlotUi(d, plotRoot) then
				(d :: LayerCollector).Enabled = false
			elseif unclaimed or not mine then
				(d :: LayerCollector).Enabled = false
			else
				local stand = findBrainrotStandAncestor(d)
				if stand and standIsEmpty(stand) and not isUnderLevelPanel(d) then
					(d :: LayerCollector).Enabled = false
				else
					(d :: LayerCollector).Enabled = true
				end
			end
		end
	end
end

local function hookPlotRoot(plotRoot: Instance)
	if not (plotRoot:IsA("Model") or plotRoot:IsA("Folder")) then
		return
	end
	if baseMarkerConns[plotRoot] then
		return
	end
	local list: { RBXScriptConnection } = {}
	local function refresh()
		applyPlotMarker(plotRoot)
	end
	table.insert(list, plotRoot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(refresh))
	table.insert(list, plotRoot.DescendantAdded:Connect(function(desc)
		if desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") then
			task.defer(refresh)
		end
	end))
	plotRoot.Destroying:Once(function()
		for _, c in ipairs(list) do
			c:Disconnect()
		end
		baseMarkerConns[plotRoot] = nil
	end)
	baseMarkerConns[plotRoot] = list
	refresh()
end

local function refreshAllMarkersInFolder(folder: Instance)
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("Model") or ch:IsA("Folder") then
			applyPlotMarker(ch)
		end
	end
end

local M = {}

function M.init()
	local map = workspace:WaitForChild("Map", 60)
	if not map then
		warn("[PlotMarkerVisibility] workspace.Map missing")
		return
	end
	local folder = map:WaitForChild("Spawn And Bases", 60)
	if not folder then
		warn("[PlotMarkerVisibility] Spawn And Bases missing")
		return
	end
	for _, ch in ipairs(folder:GetChildren()) do
		hookPlotRoot(ch)
	end
	folder.ChildAdded:Connect(function(ch)
		hookPlotRoot(ch)
	end)
	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		refreshAllMarkersInFolder(folder)
	end)
	refreshAllMarkersInFolder(folder)
end

return M
