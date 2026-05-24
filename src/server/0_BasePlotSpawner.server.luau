--[[
	0_BasePlotSpawner (server, runs early by name)
	• Clones ServerStorage.Templates.Base onto workspace.Map["Spawn And Bases"].BasePOSPart1..7.
	• Names instances Plot_1 … Plot_7 and sets PlotSlotId + PlotOwnerUserId (on join).
	• Sets player attribute AssignedPlotSlot (1–7) so gameplay scripts can reject wrong-plot actions.
	• Clears PlotOwnerUserId on leave so the slot can be reassigned next session.

	Map / anchors live in Studio; the Base template should be a Model (or Folder) with story content inside.
--]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))

local TEMPLATE_NAME = "Base"
local MAX_SLOTS = 7
local POS_NAME_PREFIX = "BasePOSPart"
local SPAWNED_ATTR = "_PlotTemplatesSpawned"

local slotToBase: { [number]: Instance } = {}
local playerToSlot: { [Player]: number } = {}
local templateWatchHooked = false
local plotsStripped: { [Instance]: boolean } = {}

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
	-- Rojo may sync an empty Model shell; need actual story/stand content from Studio.
	for _, ch in ipairs(template:GetChildren()) do
		if ch:IsA("Model") or ch:IsA("Folder") then
			return true
		end
	end
	return #template:GetDescendants() > 0
end

local function pivotTemplateToPart(template: Instance, posPart: BasePart)
	if template:IsA("Model") then
		local model = template :: Model
		if not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
		if model.PrimaryPart then
			model:PivotTo(posPart.CFrame)
		else
			warn("[0_BasePlotSpawner] Base model has no BasePart — cannot pivot Plot_" .. model.Name)
		end
	elseif template:IsA("Folder") then
		-- Folder templates: move first BasePart to anchor, shift the rest by delta.
		local firstPart: BasePart? = template:FindFirstChildWhichIsA("BasePart", true)
		if not firstPart then
			warn("[0_BasePlotSpawner] Base folder has no BasePart — cannot position Plot_" .. template.Name)
			return
		end
		local delta = posPart.CFrame * firstPart.CFrame:Inverse()
		for _, d in ipairs(template:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end
	end
end

local function normalizeKey(name: string): string
	return string.gsub(string.lower(name), "%s+", "")
end

local function alphaNumericKey(name: string): string
	return string.gsub(string.lower(name), "[^a-z0-9]", "")
end

local PLOT_SIGN_NAME_KEYS: { [string]: boolean } = {
	plotusername = true,
	plot_username = true,
	plotusernamelabel = true,
	usernamesign = true,
	plotsign = true,
}

local SIGN_FOLDER_ALPHA_KEYS: { [string]: boolean } = {
	plotusername = true,
	plotusernamelabel = true,
	plotsign = true,
	usernamesign = true,
}

local function isPlotSignFolder(inst: Instance): boolean
	if not (inst:IsA("Folder") or inst:IsA("Model")) then
		return false
	end
	if PLOT_SIGN_NAME_KEYS[normalizeKey(inst.Name)] == true then
		return true
	end
	return SIGN_FOLDER_ALPHA_KEYS[alphaNumericKey(inst.Name)] == true
end

local function isFirstStoryName(name: string): boolean
	local key = normalizeKey(name)
	return key == "1story" or key == "1ststory"
end

local function firstStoryOf(plot: Instance): Instance?
	for _, ch in ipairs(plot:GetChildren()) do
		if isFirstStoryName(ch.Name) then
			return ch
		end
	end
	return nil
end

local function looksLikePlotRoot(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("Folder")) then
		return false
	end
	if string.match(inst.Name, "^" .. POS_NAME_PREFIX) then
		return false
	end
	if typeof(inst:GetAttribute("PlotSlotId")) == "number" then
		return true
	end
	if string.match(inst.Name, "^Plot_%d+$") then
		return true
	end
	if firstStoryOf(inst) ~= nil then
		return true
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if (d:IsA("Folder") or d:IsA("Model")) and normalizeKey(d.Name) == "floor" then
			return true
		end
	end
	return false
end

local function isProtectedPlotUi(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "LevelPanel" or x.Name == "Button" then
			return true
		end
		if x:IsA("Model") then
			local ak = alphaNumericKey(x.Name)
			if ak == "upgradeadd" or (string.find(ak, "upgrade", 1, true) and string.find(ak, "add", 1, true)) then
				return true
			end
		end
		x = x.Parent
	end
	return false
end

local function shouldStripDescendant(desc: Instance, plot: Instance): boolean
	if desc:IsA("BillboardGui") then
		return true
	end
	if desc.Name == "PlotGUI" and desc:IsA("SurfaceGui") then
		return true
	end
	if desc:IsA("SurfaceGui") and not isProtectedPlotUi(desc, plot) then
		return true
	end
	if isPlotSignFolder(desc) then
		return true
	end
	return false
end

local function removePlotDecorations(plot: Instance)
	local toDestroy: { Instance } = {}
	for _, d in ipairs(plot:GetDescendants()) do
		if shouldStripDescendant(d, plot) then
			table.insert(toDestroy, d)
		end
	end
	for _, inst in ipairs(toDestroy) do
		inst:Destroy()
	end
end

local function hookPlotStrip(plot: Instance)
	if plotsStripped[plot] then
		return
	end
	plotsStripped[plot] = true
	removePlotDecorations(plot)
	plot.DescendantAdded:Connect(function(desc)
		task.defer(function()
			if plot.Parent and shouldStripDescendant(desc, plot) then
				desc:Destroy()
			end
		end)
	end)
	plot.Destroying:Once(function()
		plotsStripped[plot] = nil
	end)
end

local function cleanupAllPlotsInFolder(folder: Instance)
	for _, ch in ipairs(folder:GetChildren()) do
		if looksLikePlotRoot(ch) then
			hookPlotStrip(ch)
		end
	end
end

local function collectExistingPlots(folder: Instance): boolean
	table.clear(slotToBase)
	local any = false
	for slot = 1, MAX_SLOTS do
		local plot = folder:FindFirstChild("Plot_" .. tostring(slot))
		if plot and (plot:IsA("Model") or plot:IsA("Folder")) then
			removePlotDecorations(plot)
			slotToBase[slot] = plot
			any = true
		end
	end
	return any
end

local function spawnBasesOnce(folder: Instance): boolean
	if folder:GetAttribute(SPAWNED_ATTR) == true then
		if collectExistingPlots(folder) then
			return true
		end
		-- Undo / manual delete removed Plot_* but the flag stayed — allow respawn.
		warn("[0_BasePlotSpawner] Plots missing but _PlotTemplatesSpawned was set — respawning")
		folder:SetAttribute(SPAWNED_ATTR, false)
	end

	local templates = Brainrots.waitTemplatesFolder(0)
	if not templates then
		return false
	end
	local template = templates:FindFirstChild(TEMPLATE_NAME)
	if not template then
		warn("[0_BasePlotSpawner] ServerStorage.Templates.Base missing — add your base model there in Studio, save, then play")
		return false
	end
	if not isUsableBaseTemplate(template) then
		warn("[0_BasePlotSpawner] ServerStorage.Templates.Base is empty — restore your base model content in Studio (stories/stands), save the place, then play")
		return false
	end

	local any = false
	local missingAnchors = 0
	local spawnedCount = 0
	for slot = 1, MAX_SLOTS do
		local pos = folder:FindFirstChild(POS_NAME_PREFIX .. tostring(slot))
		if not pos or not pos:IsA("BasePart") then
			missingAnchors += 1
			if missingAnchors <= 3 then
				warn("[0_BasePlotSpawner] Missing anchor " .. POS_NAME_PREFIX .. tostring(slot) .. " under Map.Spawn And Bases")
			end
			continue
		end
		local existing = folder:FindFirstChild("Plot_" .. tostring(slot))
		if existing then
			existing:Destroy()
		end
		local clone = template:Clone()
		clone.Name = "Plot_" .. tostring(slot)
		clone:SetAttribute("PlotSlotId", slot)
		clone.Parent = folder
		pivotTemplateToPart(clone, pos)
		removePlotDecorations(clone)
		pos.Transparency = 1
		pos.CanCollide = false
		pos.CanQuery = false
		pos.CanTouch = false
		slotToBase[slot] = clone
		any = true
		spawnedCount += 1
	end

	if missingAnchors > 0 and not any then
		warn("[0_BasePlotSpawner] No BasePOSPart anchors found — add BasePOSPart1..7 under Map.Spawn And Bases in Studio")
	end

	if any then
		folder:SetAttribute(SPAWNED_ATTR, true)
		print(string.format("[0_BasePlotSpawner] Spawned %d plot(s) from ServerStorage.Templates.Base", spawnedCount))
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
				base:SetAttribute("PlotOwnerUserId", player.UserId)
				player:SetAttribute("AssignedPlotSlot", slot)
				playerToSlot[player] = slot
				return
			end
		end
	end
	player:SetAttribute("AssignedPlotSlot", nil)
	warn("[0_BasePlotSpawner] No free plot for " .. player.Name)
end

local function bootIfPossible(): boolean
	local folder = findSpawnFolder()
	if not folder then
		return false
	end
	local ok = spawnBasesOnce(folder)
	cleanupAllPlotsInFolder(folder)
	if ok then
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
				task.defer(bootIfPossible)
			end
		end)
		local function watchBaseContent(base: Instance)
			base.DescendantAdded:Connect(function()
				task.defer(bootIfPossible)
			end)
		end
		local base = templates:FindFirstChild(TEMPLATE_NAME)
		if base then
			watchBaseContent(base)
		end
	end)

	local map = Workspace:WaitForChild("Map", 120)
	if not map then
		return
	end
	local folder = map:WaitForChild("Spawn And Bases", 120)
	if folder then
		folder.ChildAdded:Connect(function(ch)
			if ch.Name == POS_NAME_PREFIX .. "1" or string.match(ch.Name, "^" .. POS_NAME_PREFIX) then
				task.defer(bootIfPossible)
			elseif looksLikePlotRoot(ch) then
				task.defer(function()
					hookPlotStrip(ch)
				end)
			end
		end)
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	task.defer(function()
		bootIfPossible()
		tryAssignPlayer(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local slot = playerToSlot[player]
	playerToSlot[player] = nil
	player:SetAttribute("AssignedPlotSlot", nil)
	if typeof(slot) == "number" then
		local base = slotToBase[slot]
		if base and base.Parent then
			base:SetAttribute("PlotOwnerUserId", nil)
		end
	end
end)

hookTemplateWatchers()

task.spawn(function()
	for _ = 1, 480 do
		if bootIfPossible() then
			return
		end
		task.wait(0.25)
	end
	warn("[0_BasePlotSpawner] Gave up waiting — check ServerStorage.Templates.Base and Map.Spawn And Bases.BasePOSPart1..7")
end)
