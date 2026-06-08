-- [ACTIVE] 0_BasePlotSpawner.server
--[[
	0_BasePlotSpawner (server, runs early by name)
	• Unclaimed slots: lightweight floor stub only (fast load).
	• Claimed slot: full ServerStorage.Templates.Base clone.
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
local SPAWN_VERSION = 14
local STUB_ATTR = "PlotFloorStub"

local slotToBase: { [number]: Instance } = {}
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

local function plotUsernameNamePart(plot: Instance, story1: Instance): BasePart?
	local function findIn(root: Instance): BasePart?
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("Folder") or d:IsA("Model")) and string.gsub(string.lower(d.Name), "%s+", "") == "plotusername" then
				local namePart = d:FindFirstChild("Name")
				if namePart and namePart:IsA("BasePart") then
					return namePart :: BasePart
				end
			end
		end
		return nil
	end
	return findIn(story1) or findIn(plot)
end

local function findPlotGui(plot: Instance): Instance?
	local story1 = firstStoryFolder(plot)
	if story1 then
		local spawn = story1:FindFirstChild("Spawn")
		if spawn then
			local underSpawn = spawn:FindFirstChild("PlotGUI")
			if underSpawn then
				return underSpawn
			end
		end
	end
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
	local anchor = plotUsernameNamePart(plot, story1)
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
			setupPlotGuiOnStory1(plot)
			slotToBase[slot] = plot
			any = true
		end
	end
	return any
end

local function sanitizeStubFloor(floorFolder: Instance)
	local toDestroy: { Instance } = {}
	for _, d in ipairs(floorFolder:GetDescendants()) do
		if d.Name == "Stands" or d.Name == "stands" then
			table.insert(toDestroy, d)
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			table.insert(toDestroy, d)
		elseif d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then
			table.insert(toDestroy, d)
		elseif d:IsA("BasePart") then
			local n = string.lower(d.Name)
			if n == "spawn" or n == "guipart" or n == "buttonpart" then
				table.insert(toDestroy, d)
			end
		elseif d:IsA("Model") then
			if d:FindFirstChild("Spawn", true) and (d:FindFirstChild("LevelPanel", true) or d:FindFirstChild("Button", true)) then
				table.insert(toDestroy, d)
			elseif d:FindFirstChild("GUIPart", true) and d:FindFirstChildWhichIsA("SurfaceGui", true) then
				table.insert(toDestroy, d)
			end
		end
	end
	for _, inst in ipairs(toDestroy) do
		inst:Destroy()
	end
end

local function spawnFloorStub(template: Instance, pos: BasePart, slot: number, folder: Instance): Model
	local plot = Instance.new("Model")
	plot.Name = "Plot_" .. tostring(slot)
	plot:SetAttribute("PlotSlotId", slot)
	plot:SetAttribute(STUB_ATTR, true)

	local story1 = firstStoryFolder(template)
	if story1 then
		local storyClone = story1:Clone()
		for _, ch in ipairs(storyClone:GetChildren()) do
			if string.lower(ch.Name) ~= "floor" then
				ch:Destroy()
			end
		end
		local floorFolder = storyClone:FindFirstChild("Floor") or storyClone:FindFirstChild("floor")
		if floorFolder then
			sanitizeStubFloor(floorFolder)
		end
		storyClone.Parent = plot
	else
		local p = Instance.new("Part")
		p.Name = "Floor"
		p.Anchored = true
		p.Size = Vector3.new(48, 1, 48)
		p.Color = Color3.fromRGB(80, 80, 80)
		p.Parent = plot
	end

	plot.Parent = folder
	pivotBottomToAnchor(plot, pos)
	hideAnchorPart(pos)
	return plot
end

local function spawnFullPlot(template: Instance, pos: BasePart, slot: number, folder: Instance, ownerUserId: number?): Model
	local clone = template:Clone() :: Model
	clone.Name = "Plot_" .. tostring(slot)
	clone:SetAttribute("PlotSlotId", slot)
	clone:SetAttribute(STUB_ATTR, nil)
	if typeof(ownerUserId) == "number" then
		clone:SetAttribute("PlotOwnerUserId", ownerUserId)
	end
	setupPlotGuiOnStory1(clone)
	PlotRuntimeTune.tune(clone)
	clone.Parent = folder
	pivotBottomToAnchor(clone, pos)
	hideAnchorPart(pos)
	return clone
end

local function replacePlotSlot(slot: number, plot: Model)
	slotToBase[slot] = plot
	scheduleReplaceNotifications(plot)
end

local function promoteStubToFullPlot(slot: number, player: Player)
	local folder = findSpawnFolder()
	local template = getBaseTemplate()
	if not folder or not template then
		return
	end
	local pos = folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
	if not pos or not pos:IsA("BasePart") then
		return
	end
	local existing = folder:FindFirstChild("Plot_" .. tostring(slot))
	if existing then
		existing:Destroy()
	end
	task.defer(function()
		if not player.Parent then
			return
		end
		local plot = spawnFullPlot(template, pos, slot, folder, player.UserId)
		replacePlotSlot(slot, plot)
		player:SetAttribute("AssignedPlotSlot", slot)
		playerToSlot[player] = slot
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
		folder:SetAttribute(SPAWNED_ATTR, false)
	end

	if folder:GetAttribute(SPAWNED_ATTR) == true then
		if collectExistingPlots(folder) then
			return true
		end
		folder:SetAttribute(SPAWNED_ATTR, false)
	end

	local template = getBaseTemplate()
	if not template then
		return false
	end

	local any = false
	local stubCount = 0
	for slot = 1, MAX_SLOTS do
		local pos = folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
		if not pos or not pos:IsA("BasePart") then
			continue
		end
		local existing = folder:FindFirstChild("Plot_" .. tostring(slot))
		if existing then
			existing:Destroy()
		end
		local stub = spawnFloorStub(template, pos, slot, folder)
		slotToBase[slot] = stub
		stubCount += 1
		any = true
		if slot < MAX_SLOTS then
			task.wait()
		end
	end

	if any then
		folder:SetAttribute(SPAWNED_ATTR, true)
		folder:SetAttribute(SPAWN_VERSION_ATTR, SPAWN_VERSION)
	end
	return any
end

local function tryAssignPlayer(player: Player)
	if playerToSlot[player] ~= nil then
		return
	end
	if next(slotToBase) == nil then
		return
	end
	for slot = 1, MAX_SLOTS do
		local base = slotToBase[slot]
		if base and base.Parent then
			local owner = base:GetAttribute("PlotOwnerUserId")
			if owner == nil then
				if base:GetAttribute(STUB_ATTR) == true then
					promoteStubToFullPlot(slot, player)
				else
					base:SetAttribute("PlotOwnerUserId", player.UserId)
					player:SetAttribute("AssignedPlotSlot", slot)
					playerToSlot[player] = slot
					notifyPlotVisibilityRefresh(base)
				end
				return
			end
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
	-- Defer plot teardown so PlayerDataService can export stand brainrots before models are destroyed.
	task.defer(function()
		player:SetAttribute("AssignedPlotSlot", nil)
		if typeof(slot) ~= "number" then
			return
		end
		local folder = findSpawnFolder()
		local template = getBaseTemplate()
		local pos = folder and folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
		if folder and template and pos and pos:IsA("BasePart") then
			local existing = slotToBase[slot]
			if existing and existing.Parent then
				existing:Destroy()
			end
			local stub = spawnFloorStub(template, pos, slot, folder)
			slotToBase[slot] = stub
			notifyPlotVisibilityRefresh(stub)
		else
			local base = slotToBase[slot]
			if base and base.Parent then
				base:SetAttribute("PlotOwnerUserId", nil)
				notifyPlotVisibilityRefresh(base)
			end
		end
	end)
end)

hookTemplateWatchers()
