-- [ACTIVE] PlotOutlineController
--[[
	While the local player is in the shared safezone, THEIR owned plot gets a
	faint outline around the full floor pad. It fades out as they walk toward it.
	Same distance fade for the "Your Plot" image above the base (size-capped).
	Never outlines other players' plots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))

local player = Players.LocalPlayer

local POLL_INTERVAL = 0.12
-- Full faint outline beyond this XZ distance from plot floor center.
local FADE_START_DIST = 72
-- Fully invisible at/inside this distance (on the pad).
local FADE_END_DIST = 18
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
-- Farthest visible outline (still a bit transparent).
local OUTLINE_FAR_TRANSPARENCY = 0.42
-- SelectionBox line thickness (Highlight has no thickness API).
local BOX_LINE_THICKNESS = 0.22
-- Cap "Your Plot" marker (billboards are offset px; SurfaceGuis use PixelsPerStud).
local MARKER_MAX_TEXT_SIZE = 18
local MARKER_MIN_TEXT_SIZE = 10
local MARKER_MAX_BILLBOARD_PX = 44
local MARKER_MAX_GUI_SCALE = 0.62
local MARKER_MAX_PIXELS_PER_STUD = 18

local PlotOutlineController = {}

local selectionBox: SelectionBox? = nil
local outlineProxy: BasePart? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local cachedMarkerBillboards: { BillboardGui } = {}
local cachedMarkerSurfaceGuis: { SurfaceGui } = {}
local wired = false

local function destroyOutline()
	if selectionBox then
		selectionBox:Destroy()
		selectionBox = nil
	end
	if outlineProxy then
		outlineProxy:Destroy()
		outlineProxy = nil
	end
end

local function isOwnedByLocalPlayer(plot: Instance): boolean
	local uid = plot:GetAttribute("PlotOwnerUserId")
	return typeof(uid) == "number" and uid == player.UserId
end

local function isUnderPlotUsername(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "PlotUsername" or string.gsub(string.lower(x.Name), "%s+", "") == "plotusername" then
			return true
		end
		x = x.Parent
	end
	return false
end

local function isOwnershipMarkerBillboard(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "PlotGUI" then
			return true
		end
		x = x.Parent
	end
	if isUnderPlotUsername(inst, plotRoot) then
		-- Name-plate SurfaceGui lives under PlotUsername.Name — markers live elsewhere.
		local parent = inst.Parent
		if parent and parent.Name == "Name" and parent:IsA("BasePart") then
			return false
		end
		return true
	end
	local ak = string.gsub(string.lower(inst.Name), "[^a-z0-9]", "")
	if string.find(ak, "yourplot", 1, true) or string.find(ak, "thisplot", 1, true) or ak == "plotmarker" then
		return true
	end
	for _, d in ipairs(inst:GetDescendants()) do
		local dn = string.gsub(string.lower(d.Name), "[^a-z0-9]", "")
		if string.find(dn, "yourplot", 1, true) or string.find(dn, "thisplot", 1, true) then
			return true
		end
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local t = string.gsub(string.lower((d :: TextLabel).Text), "%s+", "")
			if string.find(t, "yourplot", 1, true) or string.find(t, "thisplot", 1, true) or t == "plot" then
				return true
			end
		end
	end
	return false
end

local function refreshMarkerBillboards(plot: Instance?)
	table.clear(cachedMarkerBillboards)
	table.clear(cachedMarkerSurfaceGuis)
	if not plot then
		return
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BillboardGui") and isOwnershipMarkerBillboard(d, plot) then
			table.insert(cachedMarkerBillboards, d)
		elseif d:IsA("SurfaceGui") and isOwnershipMarkerBillboard(d, plot) then
			table.insert(cachedMarkerSurfaceGuis, d)
		end
	end
end

local function ensureMarkerGuiScale(gui: GuiObject)
	local sc = gui:FindFirstChild("PlotMarkerScaleCap")
	if not sc or not sc:IsA("UIScale") then
		if sc then
			sc:Destroy()
		end
		sc = Instance.new("UIScale")
		sc.Name = "PlotMarkerScaleCap"
		sc.Parent = gui
	end
	(sc :: UIScale).Scale = MARKER_MAX_GUI_SCALE
end

local function capMarkerTextLabel(label: TextLabel)
	local maxSize = MARKER_MAX_TEXT_SIZE
	local minSize = MARKER_MIN_TEXT_SIZE
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	constraint.MaxTextSize = maxSize
	constraint.MinTextSize = minSize
	if label.TextSize > maxSize then
		label.TextSize = maxSize
	end
	label.TextScaled = false
end

local function capMarkerBillboardSize(bb: BillboardGui)
	bb.Size = UDim2.fromOffset(MARKER_MAX_BILLBOARD_PX, MARKER_MAX_BILLBOARD_PX)
	bb.MaxDistance = 140
	ensureMarkerGuiScale(bb)
	for _, d in ipairs(bb:GetDescendants()) do
		if d:IsA("GuiObject") then
			ensureMarkerGuiScale(d :: GuiObject)
		end
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			capMarkerTextLabel(d :: TextLabel)
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
			img.Size = UDim2.fromScale(1, 1)
		end
	end
end

local function capMarkerSurfaceGui(sg: SurfaceGui)
	if sg.SizingMode == Enum.SurfaceGuiSizingMode.PixelsPerStud then
		sg.PixelsPerStud = math.min(sg.PixelsPerStud, MARKER_MAX_PIXELS_PER_STUD)
	end
	ensureMarkerGuiScale(sg)
	for _, d in ipairs(sg:GetDescendants()) do
		if d:IsA("GuiObject") then
			ensureMarkerGuiScale(d :: GuiObject)
		end
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			capMarkerTextLabel(d :: TextLabel)
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
			img.Size = UDim2.fromScale(1, 1)
		end
	end
end

local function applyMarkerFade(transparency: number, visible: boolean)
	if visible and (not cachedPlot or not isOwnedByLocalPlayer(cachedPlot)) then
		visible = false
		transparency = 1
	end
	for _, bb in ipairs(cachedMarkerBillboards) do
		if not bb.Parent then
			continue
		end
		capMarkerBillboardSize(bb)
		bb.Enabled = visible
		if not visible then
			continue
		end
		for _, d in ipairs(bb:GetDescendants()) do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				local img = d :: ImageLabel
				img.ImageTransparency = transparency
				img.BackgroundTransparency = math.max(img.BackgroundTransparency, transparency)
			elseif d:IsA("TextLabel") or d:IsA("TextButton") then
				local text = d :: TextLabel
				text.TextTransparency = transparency
				text.TextStrokeTransparency = math.clamp(transparency + 0.2, 0, 1)
			elseif d:IsA("Frame") then
				local frame = d :: Frame
				frame.BackgroundTransparency = math.max(frame.BackgroundTransparency, transparency)
			end
		end
	end
	for _, sg in ipairs(cachedMarkerSurfaceGuis) do
		if not sg.Parent then
			continue
		end
		capMarkerSurfaceGui(sg)
		sg.Enabled = visible
		if not visible then
			continue
		end
		for _, d in ipairs(sg:GetDescendants()) do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				local img = d :: ImageLabel
				img.ImageTransparency = transparency
				img.BackgroundTransparency = math.max(img.BackgroundTransparency, transparency)
			elseif d:IsA("TextLabel") or d:IsA("TextButton") then
				local text = d :: TextLabel
				text.TextTransparency = transparency
				text.TextStrokeTransparency = math.clamp(transparency + 0.2, 0, 1)
			elseif d:IsA("Frame") then
				local frame = d :: Frame
				frame.BackgroundTransparency = math.max(frame.BackgroundTransparency, transparency)
			end
		end
	end
end

-- Invisible part matching the full floor AABB so SelectionBox wraps the whole pad.
local function ensureFloorOutlineProxy(plot: Instance): BasePart?
	local cf, size = PlotSpawnUtil.getPlotFloorOutlineCFrameSize(plot)
	if not cf or not size then
		return nil
	end

	local proxy = outlineProxy
	if not proxy or not proxy.Parent then
		if proxy then
			proxy:Destroy()
		end
		proxy = Instance.new("Part")
		proxy.Name = "PlotSafezoneOutlineProxy"
		proxy.Anchored = true
		proxy.CanCollide = false
		proxy.CanQuery = false
		proxy.CanTouch = false
		proxy.CastShadow = false
		proxy.Massless = true
		proxy.Transparency = 1
		proxy.Material = Enum.Material.SmoothPlastic
		proxy.Parent = Workspace.CurrentCamera or plot
		outlineProxy = proxy
	end

	proxy.Size = size
	proxy.CFrame = cf
	return proxy
end

local function ensureOutline(plot: Instance): SelectionBox?
	local proxy = ensureFloorOutlineProxy(plot)
	if not proxy then
		return nil
	end

	local box = selectionBox
	if not box or not box.Parent or box.Adornee ~= proxy then
		if box then
			box:Destroy()
		end
		box = Instance.new("SelectionBox")
		box.Name = "PlotSafezoneOutlineBox"
		box.Color3 = OUTLINE_COLOR
		box.SurfaceColor3 = OUTLINE_COLOR
		box.SurfaceTransparency = 1
		box.LineThickness = BOX_LINE_THICKNESS
		box.Transparency = 1
		box.Visible = false
		box.Adornee = proxy
		box.Parent = Workspace.CurrentCamera or plot
		selectionBox = box
	end

	return box
end

local function resolvePlotCenter(plot: Instance): Vector3?
	local minV, maxV = PlotSpawnUtil.getPlotOutlineBounds(plot)
	if minV and maxV then
		return Vector3.new((minV.X + maxV.X) * 0.5, (minV.Y + maxV.Y) * 0.5, (minV.Z + maxV.Z) * 0.5)
	end
	if plot:IsA("Model") then
		return (plot :: Model):GetPivot().Position
	end
	local part = plot:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function hideAllCachedMarkers()
	applyMarkerFade(1, false)
end

local function refreshCachedPlot()
	-- Owned plot only — never outline someone else's base.
	local plot = PlotPaths.findPlotOwnedByPlayer(player)
	if not plot then
		local bySlot = PlotPaths.findPlotForAssignedSlot(player)
		if bySlot and isOwnedByLocalPlayer(bySlot) then
			plot = bySlot
		end
	end
	if plot and not isOwnedByLocalPlayer(plot) then
		plot = nil
	end
	if cachedPlot ~= plot then
		hideAllCachedMarkers()
	end
	cachedPlot = plot
	cachedCenter = if plot then resolvePlotCenter(plot) else nil
	refreshMarkerBillboards(plot)
	if not plot then
		destroyOutline()
		hideAllCachedMarkers()
	end
end

local function xzDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function outlineTransparencyForDistance(dist: number): number
	if dist <= FADE_END_DIST then
		return 1
	end
	if dist >= FADE_START_DIST then
		return OUTLINE_FAR_TRANSPARENCY
	end
	local t = (dist - FADE_END_DIST) / (FADE_START_DIST - FADE_END_DIST)
	return OUTLINE_FAR_TRANSPARENCY + (1 - OUTLINE_FAR_TRANSPARENCY) * (1 - t)
end

local function tickOutline()
	local character = player.Character
	if not character or not SafezoneUtil.isCharacterInSafezone(character) then
		if selectionBox then
			selectionBox.Visible = false
			selectionBox.Transparency = 1
		end
		applyMarkerFade(1, false)
		return
	end

	if not cachedPlot or not cachedPlot.Parent or not isOwnedByLocalPlayer(cachedPlot) then
		refreshCachedPlot()
	elseif #cachedMarkerBillboards == 0 and #cachedMarkerSurfaceGuis == 0 then
		refreshMarkerBillboards(cachedPlot)
	end
	local plot = cachedPlot
	local center = cachedCenter
	if not plot or not center or not isOwnedByLocalPlayer(plot) then
		destroyOutline()
		hideAllCachedMarkers()
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local dist = xzDist(hrp.Position, center)
	local transparency = outlineTransparencyForDistance(dist)
	local box = ensureOutline(plot)
	local visible = transparency < 0.995
	if box then
		box.Visible = visible
		box.Transparency = transparency
		box.LineThickness = BOX_LINE_THICKNESS
		box.Color3 = OUTLINE_COLOR
	end
	applyMarkerFade(transparency, visible)
end

local function watchPlotOwnership()
	local folder = PlotPaths.waitForSpawnAndBasesFolder(120)
	if not folder then
		return
	end
	local hooked: { [Instance]: boolean } = {}
	local function hookPlot(plot: Instance)
		if hooked[plot] or not PlotPaths.isPlotRoot(plot) then
			return
		end
		hooked[plot] = true
		plot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(function()
			refreshCachedPlot()
			task.defer(tickOutline)
		end)
		plot.Destroying:Once(function()
			hooked[plot] = nil
		end)
	end
	for _, ch in ipairs(folder:GetChildren()) do
		hookPlot(ch)
	end
	folder.ChildAdded:Connect(hookPlot)
end

local function onHeartbeat(dt: number)
	accum += dt
	if accum < POLL_INTERVAL then
		return
	end
	accum = 0
	tickOutline()
end

function PlotOutlineController.init()
	if wired then
		return
	end
	wired = true

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(8)
		watchPlotOwnership()
		refreshCachedPlot()
	end)

	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		refreshCachedPlot()
		tickOutline()
	end)

	player.CharacterAdded:Connect(function()
		task.defer(tickOutline)
	end)

	pollConn = RunService.Heartbeat:Connect(onHeartbeat)
end

return PlotOutlineController
