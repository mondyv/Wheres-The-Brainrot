--[[
	PlotMarkerVisibility (client)
	• Other players' plots: all plot UI off.
	• Your plot: stand Button / LevelPanel / floor-unlock signs + PlotGUI stay on.
	• Empty-stand billboard markers stay off everywhere.

	Plot roots are direct children of Map.Spawn And Bases (e.g. Plot_1 … Plot_7).

	Must be a ModuleScript (.luau) — not .client.luau — so init.client can require it.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))

local player = Players.LocalPlayer

local STAND_TAG = "BrainrotStand"

local baseMarkerConns: { [Instance]: { RBXScriptConnection } } = {}
local standNameWatch: { [Model]: RBXScriptConnection } = {}
local refreshScheduled: { [Instance]: boolean } = {}
local plotLayerCollectors: { [Instance]: { LayerCollector } } = {}

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

local function ensureStandBrainrotNameWatcher(_plotRoot: Instance, stand: Model, refresh: () -> ())
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

local function isPlotGuiRelated(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "PlotGUI" then
			return true
		end
		x = x.Parent
	end
	return false
end

local function isStandDisplayModelAncestor(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x:IsA("Model") and x:GetAttribute("BrainrotStandDisplay") == true then
			return true
		end
		x = x.Parent
	end
	return false
end

local function isProtectedPlotUi(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "LevelPanel" or x.Name == "Button" or x.Name == "PlotUsername" then
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

local function applyLayerCollector(d: LayerCollector, plotRoot: Instance, mine: boolean, unclaimed: boolean)
	if d:IsA("BillboardGui") then
		if unclaimed or not mine then
			d.Enabled = false
		elseif isPlotGuiRelated(d, plotRoot) or isProtectedPlotUi(d, plotRoot) or isStandDisplayModelAncestor(d, plotRoot) then
			d.Enabled = true
		else
			d.Enabled = false
		end
	elseif d:IsA("SurfaceGui") then
		if unclaimed then
			d.Enabled = false
		elseif isProtectedPlotUi(d, plotRoot) then
			d.Enabled = mine
		elseif not mine then
			d.Enabled = false
		else
			local stand = findBrainrotStandAncestor(d)
			if stand and stand:GetAttribute("BrainrotStandLocked") == true then
				d.Enabled = false
			elseif stand and standIsEmpty(stand) and not isUnderLevelPanel(d) then
				d.Enabled = false
			else
				d.Enabled = true
			end
		end
	end
end

local function rebuildPlotGuiCache(plotRoot: Instance)
	local list: { LayerCollector } = {}
	for _, d in ipairs(plotRoot:GetDescendants()) do
		if d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			table.insert(list, d :: LayerCollector)
		end
	end
	plotLayerCollectors[plotRoot] = list
end

local function trackLayerCollector(plotRoot: Instance, inst: Instance)
	if not (inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")) then
		return
	end
	local list = plotLayerCollectors[plotRoot]
	if not list then
		rebuildPlotGuiCache(plotRoot)
		return
	end
	table.insert(list, inst :: LayerCollector)
end

local function applyPlotMarker(plotRoot: Instance)
	local uid = plotRoot:GetAttribute("PlotOwnerUserId")
	local mine = typeof(uid) == "number" and uid == player.UserId
	local unclaimed = plotIsUnclaimed(plotRoot)
	local list = plotLayerCollectors[plotRoot]
	if not list then
		rebuildPlotGuiCache(plotRoot)
		list = plotLayerCollectors[plotRoot] or {}
	end
	for _, d in ipairs(list) do
		if d.Parent then
			applyLayerCollector(d, plotRoot, mine, unclaimed)
		end
	end
end

local function hookStandsInPlot(plotRoot: Instance, refresh: () -> ())
	for _, d in ipairs(plotRoot:GetDescendants()) do
		if d:IsA("Model") and CollectionService:HasTag(d, STAND_TAG) then
			ensureStandBrainrotNameWatcher(plotRoot, d :: Model, refresh)
		end
	end
end

local function hookPlotRoot(plotRoot: Instance)
	if not PlotPaths.isPlotRoot(plotRoot) then
		return
	end
	if baseMarkerConns[plotRoot] then
		return
	end
	rebuildPlotGuiCache(plotRoot)
	local list: { RBXScriptConnection } = {}
	local function refresh()
		if refreshScheduled[plotRoot] then
			return
		end
		refreshScheduled[plotRoot] = true
		task.defer(function()
			refreshScheduled[plotRoot] = nil
			if plotRoot.Parent then
				applyPlotMarker(plotRoot)
			end
		end)
	end
	table.insert(list, plotRoot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(refresh))
	table.insert(list, plotRoot.DescendantAdded:Connect(function(desc)
		if desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") then
			trackLayerCollector(plotRoot, desc)
		end
	end))
	plotRoot.Destroying:Once(function()
		for _, c in ipairs(list) do
			c:Disconnect()
		end
		baseMarkerConns[plotRoot] = nil
		refreshScheduled[plotRoot] = nil
		plotLayerCollectors[plotRoot] = nil
	end)
	baseMarkerConns[plotRoot] = list
	hookStandsInPlot(plotRoot, refresh)
	refresh()
end

local function refreshAllMarkersInFolder(folder: Instance)
	for _, ch in ipairs(folder:GetChildren()) do
		if PlotPaths.isPlotRoot(ch) then
			applyPlotMarker(ch)
		end
	end
end

local M = {}

function M.init()
	local folder = PlotPaths.waitForSpawnAndBasesFolder(120)
	if not folder then
		warn("[PlotMarkerVisibility] Spawn And Bases missing (expected workspace.Lands.Spawn And Bases)")
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
