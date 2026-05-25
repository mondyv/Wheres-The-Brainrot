--[[
	0_BasePlotSpawner (server, runs early by name)
	• Pre-clones all 7 plot slots at server start (clone + tune + park upper floors once).
	• Unclaimed slots stay in ServerStorage.__PreBakedPlots (not replicated).
	• Claimed slot: move pre-built plot into Workspace (Parent change only — no join-time clone).
	• Bottom of plot aligned to BasePOSPart anchor (not model pivot / random part).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local PlotRuntimeTune = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotRuntimeTune"))

local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))

local TEMPLATE_NAME = "Base"
local MAX_SLOTS = 7
local POS_NAME_PREFIX = "BasePOSPart"
local SPAWNED_ATTR = "_PlotTemplatesSpawned"
local SPAWN_VERSION_ATTR = "_PlotSpawnVersion"
local SPAWN_VERSION = 13
local PREBAKE_FOLDER_NAME = "__PreBakedPlots"
local HIDDEN_FLOORS_NAME = "__HiddenBaseFloors"

local slotToBase: { [number]: Instance } = {}
local preBakedPlots: { [number]: Model } = {}
local playerToSlot: { [Player]: number } = {}
local templateWatchHooked = false
local bootComplete = false
local bootInProgress = false

local function notifyStandRescan()
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local bf = folder and folder:FindFirstChild("RequestStandRescan")
	if bf and bf:IsA("BindableFunction") then
		pcall(function()
			(bf :: BindableFunction):Invoke()
		end)
	end
end

local replaceNotifyScheduled = false

local function notifyPlotVisibilityRefresh(plot: Instance?)
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local bf = folder and folder:FindFirstChild("RequestPlotVisibilityRefresh")
	if bf and bf:IsA("BindableFunction") then
		pcall(function()
			(bf :: BindableFunction):Invoke(plot)
		end)
	end
end

local function scheduleReplaceNotifications(plot: Instance?)
	if replaceNotifyScheduled then
		return
	end
	replaceNotifyScheduled = true
	task.defer(function()
		replaceNotifyScheduled = false
		notifyStandRescan()
		notifyPlotVisibilityRefresh(plot)
	end)
end

local function findSpawnFolder(): Instance?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	return map:FindFirstChild("Spawn And Bases")
end

local function isUsableBaseTemplate(template: Instance): boolean
	if not (template:IsA("Model") or template:IsA("Folder")) then
		return false
	end
	for _, ch in ipairs(template:GetChildren()) do
		if ch:IsA("Model") or ch:IsA("Folder") then
			return true
		end
	end
	return #template:GetDescendants() > 0
end

local function getBaseTemplate(): Instance?
	local templates = ServerStorage:FindFirstChild("Templates") or Brainrots.waitTemplatesFolder(0)
	if not templates then
		return nil
	end
	local template = templates:FindFirstChild(TEMPLATE_NAME)
	if template and isUsableBaseTemplate(template) then
		return template
	end
	return nil
end

local function getStoryNumber(name: string): number?
	local digits = string.match(name, "^(%d+)")
	if not digits then
		return nil
	end
	local n = tonumber(digits)
	if n and n >= 1 and n <= 4 then
		return n
	end
	return nil
end

local function getHiddenFloorsRoot(): Folder
	local f = ServerStorage:FindFirstChild(HIDDEN_FLOORS_NAME)
	if not f then
		f = Instance.new("Folder")
		f.Name = HIDDEN_FLOORS_NAME
		f.Parent = ServerStorage
	end
	return f :: Folder
end

local function getPreBakeRoot(): Folder
	local f = ServerStorage:FindFirstChild(PREBAKE_FOLDER_NAME)
	if not f then
		f = Instance.new("Folder")
		f.Name = PREBAKE_FOLDER_NAME
		f.Parent = ServerStorage
	end
	return f :: Folder
end

local function firstStoryFolder(root: Instance): Instance?
	local s = root:FindFirstChild("1 Story")
	if s then
		return s
	end
	return root:FindFirstChild("1st Story")
end

local function hideAnchorPart(pos: BasePart)
	pos.Transparency = 1
	pos.CanCollide = false
	pos.CanQuery = false
	pos.CanTouch = false
end

local function pivotBottomToAnchor(root: Instance, posPart: BasePart)
	if not root:IsA("Model") then
		return
	end
	local model = root :: Model
	local bbCF, bbSize = model:GetBoundingBox()
	local bottomWorld = bbCF.Position - bbCF.UpVector * (bbSize.Y * 0.5)
	local anchorTop = posPart.CFrame.Position + posPart.CFrame.UpVector * (posPart.Size.Y * 0.5)
	model:PivotTo(model:GetPivot() + (anchorTop - bottomWorld))
end

local function plotUsernameNamePart(story1: Instance): BasePart?
	local plotUsername = story1:FindFirstChild("PlotUsername")
	if not plotUsername then
		return nil
	end
	local namePart = plotUsername:FindFirstChild("Name")
	if namePart and namePart:IsA("BasePart") then
		return namePart :: BasePart
	end
	return nil
end

local function findPlotGui(plot: Instance): Instance?
	for i = 4, 1, -1 do
		local story = plot:FindFirstChild(tostring(i) .. " Story")
		if story then
			local gui = story:FindFirstChild("PlotGUI", true)
			if gui then
				return gui
			end
		end
	end
	return plot:FindFirstChild("PlotGUI", true)
end

local function setupPlotGuiOnStory1(plot: Instance)
	local story1 = firstStoryFolder(plot)
	if not story1 then
		return
	end
	local anchor = plotUsernameNamePart(story1)
	if not anchor then
		return
	end
	local plotGui = findPlotGui(plot)
	if not plotGui then
		return
	end
	plotGui.Parent = anchor
	for _, desc in ipairs(plotGui:GetDescendants()) do
		if desc:IsA("BillboardGui") then
			(desc :: BillboardGui).Adornee = anchor
		end
	end
end

local function tagPlotStories(plot: Instance, slot: number)
	plot:SetAttribute("PlotSlotId", slot)
	for _, ch in ipairs(plot:GetChildren()) do
		local n = getStoryNumber(ch.Name)
		if n then
			ch:SetAttribute("PlotSlotId", slot)
		end
	end
end

local function parkStoriesAbove(plot: Instance, slot: number, unlockedFloor: number)
	local hidden = getHiddenFloorsRoot()
	for _, ch in ipairs(plot:GetChildren()) do
		local n = getStoryNumber(ch.Name)
		if n and n > unlockedFloor then
			ch:SetAttribute("PlotSlotId", slot)
			ch.Parent = hidden
		end
	end
end

local function collectExistingPlots(folder: Instance): boolean
	table.clear(slotToBase)
	local any = false
	for slot = 1, MAX_SLOTS do
		local plot = folder:FindFirstChild("Plot_" .. tostring(slot))
		if plot and (plot:IsA("Model") or plot:IsA("Folder")) then
			local owner = plot:GetAttribute("PlotOwnerUserId")
			if typeof(owner) == "number" and not Players:GetPlayerByUserId(owner) then
				plot:SetAttribute("PlotOwnerUserId", nil)
			end
			slotToBase[slot] = plot
			any = true
		end
	end
	return any
end

local function clearPreBakeStorage()
	table.clear(preBakedPlots)
	local root = ServerStorage:FindFirstChild(PREBAKE_FOLDER_NAME)
	if root then
		root:ClearAllChildren()
	end
end

local function buildPreBakedPlot(template: Instance, slot: number): Model
	local clone = template:Clone() :: Model
	clone.Name = "Plot_" .. tostring(slot)
	tagPlotStories(clone, slot)
	setupPlotGuiOnStory1(clone)
	PlotRuntimeTune.tune(clone)
	parkStoriesAbove(clone, slot, 1)
	return clone
end

local function prebakeAllSlots(template: Instance)
	local root = getPreBakeRoot()
	local baked = 0
	for slot = 1, MAX_SLOTS do
		if slotToBase[slot] then
			continue
		end
		if preBakedPlots[slot] then
			continue
		end
		local plot = buildPreBakedPlot(template, slot)
		plot.Parent = root
		preBakedPlots[slot] = plot
		baked += 1
		if slot < MAX_SLOTS then
			task.wait()
		end
	end
	if baked > 0 then
		print(string.format("[0_BasePlotSpawner] Pre-baked %d plot slot(s)", baked))
	end
end

local function replacePlotSlot(slot: number, plot: Model)
	slotToBase[slot] = plot
	scheduleReplaceNotifications(plot)
end

local function assignPreBakedPlot(slot: number, player: Player)
	local folder = findSpawnFolder()
	if not folder then
		return
	end
	local pos = folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
	if not pos or not pos:IsA("BasePart") then
		return
	end

	local plot = preBakedPlots[slot]
	if not plot then
		return
	end
	preBakedPlots[slot] = nil

	local existing = folder:FindFirstChild("Plot_" .. tostring(slot))
	if existing then
		existing:Destroy()
	end

	plot:SetAttribute("PlotOwnerUserId", player.UserId)
	plot.Parent = folder
	pivotBottomToAnchor(plot, pos)
	hideAnchorPart(pos)
	replacePlotSlot(slot, plot)
	player:SetAttribute("AssignedPlotSlot", slot)
	playerToSlot[player] = slot
	print(string.format("[0_BasePlotSpawner] Assigned %s to Plot_%d (pre-baked)", player.Name, slot))
end

local function returnSlotToPool(slot: number)
	local folder = findSpawnFolder()
	local template = getBaseTemplate()
	if not template then
		return
	end

	local existing = slotToBase[slot]
	if existing and existing.Parent then
		existing:Destroy()
	end
	slotToBase[slot] = nil

	task.spawn(function()
		local plot = buildPreBakedPlot(template, slot)
		plot.Parent = getPreBakeRoot()
		preBakedPlots[slot] = plot
		notifyPlotVisibilityRefresh(nil)
	end)
end

local function spawnBasesOnce(folder: Instance): boolean
	if folder:GetAttribute(SPAWN_VERSION_ATTR) ~= SPAWN_VERSION then
		for slot = 1, MAX_SLOTS do
			local plot = folder:FindFirstChild("Plot_" .. tostring(slot))
			if plot then
				plot:Destroy()
			end
		end
		table.clear(slotToBase)
		clearPreBakeStorage()
		folder:SetAttribute(SPAWNED_ATTR, false)
	end

	if folder:GetAttribute(SPAWNED_ATTR) == true and folder:GetAttribute(SPAWN_VERSION_ATTR) == SPAWN_VERSION then
		collectExistingPlots(folder)
	end

	local template = getBaseTemplate()
	if not template then
		return false
	end

	prebakeAllSlots(template)

	for slot = 1, MAX_SLOTS do
		local pos = folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
		if pos and pos:IsA("BasePart") then
			hideAnchorPart(pos)
		end
	end

	folder:SetAttribute(SPAWNED_ATTR, true)
	folder:SetAttribute(SPAWN_VERSION_ATTR, SPAWN_VERSION)
	return true
end

local function tryAssignPlayer(player: Player)
	if playerToSlot[player] ~= nil then
		return
	end
	if next(preBakedPlots) == nil and next(slotToBase) == nil then
		return
	end
	for slot = 1, MAX_SLOTS do
		if slotToBase[slot] then
			local base = slotToBase[slot]
			if base and base.Parent then
				local owner = base:GetAttribute("PlotOwnerUserId")
				if owner == nil then
					base:SetAttribute("PlotOwnerUserId", player.UserId)
					player:SetAttribute("AssignedPlotSlot", slot)
					playerToSlot[player] = slot
					notifyPlotVisibilityRefresh(base)
					print(string.format("[0_BasePlotSpawner] Assigned %s to Plot_%d", player.Name, slot))
					return
				end
			end
		elseif preBakedPlots[slot] then
			assignPreBakedPlot(slot, player)
			return
		end
	end
	player:SetAttribute("AssignedPlotSlot", nil)
end

local function bootOnce(): boolean
	if bootComplete then
		return true
	end
	if bootInProgress then
		return false
	end
	local folder = findSpawnFolder()
	if not folder then
		return false
	end
	if not getBaseTemplate() then
		return false
	end

	bootInProgress = true
	local ok = spawnBasesOnce(folder)
	bootInProgress = false
	if ok then
		bootComplete = true
		for _, p in Players:GetPlayers() do
			tryAssignPlayer(p)
		end
	end
	return ok
end

local function hookTemplateWatchers()
	if templateWatchHooked then
		return
	end
	templateWatchHooked = true

	task.spawn(function()
		local templates = Brainrots.waitTemplatesFolder(120)
		if not templates then
			return
		end
		templates.ChildAdded:Connect(function(ch)
			if ch.Name == TEMPLATE_NAME then
				task.defer(bootOnce)
			end
		end)
		bootOnce()
	end)

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 120)
		if not map then
			return
		end
		map:WaitForChild("Spawn And Bases", 120)
		bootOnce()
	end)
end

Players.PlayerAdded:Connect(function(player: Player)
	task.defer(function()
		if not bootComplete then
			bootOnce()
		end
		tryAssignPlayer(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local slot = playerToSlot[player]
	playerToSlot[player] = nil
	player:SetAttribute("AssignedPlotSlot", nil)
	if typeof(slot) ~= "number" then
		return
	end
	returnSlotToPool(slot)
end)

hookTemplateWatchers()
