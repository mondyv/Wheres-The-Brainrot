-- [ACTIVE] PlotMarkerVisibility
--[[
	PlotMarkerVisibility (client)
	• Unclaimed plots: all plot UI off.
	• Your plot: stand Button / LevelPanel / floor-unlock signs + PlotGUI stay on (interactive).
	• Other players' claimed plots: same UI visible but non-interactive (view-only).
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
local PLOT_GUI_MAX_DISTANCE = 180
local PLOT_GUI_OTHER_MAX_DISTANCE = 85

local baseMarkerConns: { [Instance]: { RBXScriptConnection } } = {}
local standNameWatch: { [Model]: RBXScriptConnection } = {}
local refreshScheduled: { [Instance]: boolean } = {}
local plotLayerCollectors: { [Instance]: { LayerCollector } } = {}
local afterInteractiveApplyCallbacks: { () -> () } = {}

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

local function setLayerCollectorViewOnly(d: LayerCollector)
	if d:IsA("SurfaceGui") then
		d.Active = false
		for _, desc in ipairs(d:GetDescendants()) do
			if desc:IsA("GuiObject") then
				(desc :: GuiObject).Active = false
			end
		end
	elseif d:IsA("BillboardGui") then
		d.Active = false
	end
end

local function setLayerCollectorInteractive(d: LayerCollector)
	if d:IsA("SurfaceGui") then
		d.Active = true
		for _, desc in ipairs(d:GetDescendants()) do
			if desc:IsA("GuiObject") then
				(desc :: GuiObject).Active = true
			end
		end
	elseif d:IsA("BillboardGui") then
		d.Active = true
	end
end

-- LevelPanel upgrade UI: BrainrotStandController owns which descendants receive touches.
local function setLevelPanelSurfaceGuiInteractive(d: SurfaceGui)
	d.Active = true
end

local function notifyAfterInteractiveApply()
	for _, fn in ipairs(afterInteractiveApplyCallbacks) do
		task.defer(fn)
	end
end

local function shouldEnableStandSurfaceGui(d: LayerCollector, plotRoot: Instance): boolean
	local stand = findBrainrotStandAncestor(d)
	if stand and stand:GetAttribute("BrainrotStandLocked") == true then
		return false
	end
	if stand and standIsEmpty(stand) and not isUnderLevelPanel(d) then
		return false
	end
	return true
end

local function applyLayerCollector(d: LayerCollector, plotRoot: Instance, mine: boolean, unclaimed: boolean)
	if unclaimed then
		d.Enabled = false
		return
	end

	if d:IsA("BillboardGui") then
		if isPlotGuiRelated(d, plotRoot) then
			d.Enabled = mine
			if mine then
				d.MaxDistance = PLOT_GUI_MAX_DISTANCE
			end
		elseif isProtectedPlotUi(d, plotRoot) or isStandDisplayModelAncestor(d, plotRoot) then
			d.Enabled = true
		else
			d.Enabled = false
		end
		if mine and d.Enabled then
			setLayerCollectorInteractive(d)
		elseif not mine and d.Enabled then
			setLayerCollectorViewOnly(d)
			d.MaxDistance = PLOT_GUI_OTHER_MAX_DISTANCE
		end
	elseif d:IsA("SurfaceGui") then
		if isPlotGuiRelated(d, plotRoot) then
			d.Enabled = mine
		elseif isProtectedPlotUi(d, plotRoot) then
			d.Enabled = true
		elseif shouldEnableStandSurfaceGui(d, plotRoot) then
			d.Enabled = true
		else
			d.Enabled = false
		end
		if mine and d.Enabled then
			if isUnderLevelPanel(d) then
				setLevelPanelSurfaceGuiInteractive(d :: SurfaceGui)
			else
				setLayerCollectorInteractive(d)
			end
		elseif not mine and d.Enabled then
			setLayerCollectorViewOnly(d)
			if d:IsA("SurfaceGui") then
				(d :: SurfaceGui).MaxDistance = PLOT_GUI_OTHER_MAX_DISTANCE
			end
		end
	end
end

local rebuildPlotGuiCache: (Instance) -> ()
local applyPlotMarker: (Instance) -> ()

applyPlotMarker = function(plotRoot: Instance)
	local uid = plotRoot:GetAttribute("PlotOwnerUserId")
	local mine = typeof(uid) == "number" and uid == player.UserId
	local unclaimed = plotIsUnclaimed(plotRoot)
	local list = plotLayerCollectors[plotRoot]
	if not list then
		rebuildPlotGuiCache(plotRoot)
		return
	end
	for _, d in ipairs(list) do
		if d.Parent then
			applyLayerCollector(d, plotRoot, mine, unclaimed)
		end
	end
	if mine and not unclaimed then
		notifyAfterInteractiveApply()
	end
end

rebuildPlotGuiCache = function(plotRoot: Instance)
	task.spawn(function()
		local list: { LayerCollector } = {}
		local stack = { plotRoot }
		local processed = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
				table.insert(list, inst :: LayerCollector)
			end
			for _, child in inst:GetChildren() do
				table.insert(stack, child)
			end
			processed += 1
			if processed % 400 == 0 then
				task.wait()
			end
		end
		plotLayerCollectors[plotRoot] = list
		if plotRoot.Parent then
			applyPlotMarker(plotRoot)
		end
	end)
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

local function hookStandsInPlot(plotRoot: Instance, refresh: () -> ())
	task.spawn(function()
		local stack = { plotRoot }
		local processed = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			if inst:IsA("Model") and CollectionService:HasTag(inst, STAND_TAG) then
				ensureStandBrainrotNameWatcher(plotRoot, inst :: Model, refresh)
			end
			for _, child in inst:GetChildren() do
				table.insert(stack, child)
			end
			processed += 1
			if processed % 400 == 0 then
				task.wait()
			end
		end
	end)
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

function M.onAfterInteractiveApply(fn: () -> ())
	table.insert(afterInteractiveApplyCallbacks, fn)
end

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
