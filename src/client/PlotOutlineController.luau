-- [ACTIVE] PlotOutlineController
--[[
	While the local player is in the shared safezone, THEIR owned plot gets a
	white Highlight outline that wraps plot meshes (not a giant SelectionBox).
	Fades out as they walk onto the pad. Same fade for a clean client "Your Plot"
	billboard — Studio PlotGUI markers stay disabled (they look blown-out).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local POLL_INTERVAL = 0.12
local FADE_START_DIST = 72
local FADE_END_DIST = 18
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local OUTLINE_FAR_TRANSPARENCY = 0.35
-- Occluded wraps meshes without AlwaysOnTop GPU cost on every plot part.
local MARKER_BILLBOARD_SIZE = UDim2.fromOffset(90, 36)
local MARKER_TEXT_SIZE = 16
local MARKER_STUDS_OFFSET = Vector3.new(0, 10, 0)

local PlotOutlineController = {}

local plotHighlight: Highlight? = nil
local markerBb: BillboardGui? = nil
local markerLabel: TextLabel? = nil
local markerAdornee: BasePart? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local wired = false

local function isOwnedByLocalPlayer(plot: Instance): boolean
	local uid = plot:GetAttribute("PlotOwnerUserId")
	return typeof(uid) == "number" and uid == player.UserId
end

local function destroyOutline()
	if plotHighlight then
		plotHighlight:Destroy()
		plotHighlight = nil
	end
end

local function destroyMarker()
	if markerBb then
		markerBb:Destroy()
		markerBb = nil
	end
	markerLabel = nil
	markerAdornee = nil
end

local function isStudioOwnershipMarker(inst: Instance, plotRoot: Instance): boolean
	local x: Instance? = inst
	while x and x ~= plotRoot do
		if x.Name == "PlotGUI" then
			return true
		end
		x = x.Parent
	end
	local ak = string.gsub(string.lower(inst.Name), "[^a-z0-9]", "")
	if string.find(ak, "yourplot", 1, true) or string.find(ak, "thisplot", 1, true) or ak == "plotmarker" then
		return true
	end
	if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
		for _, d in ipairs(inst:GetDescendants()) do
			local dn = string.gsub(string.lower(d.Name), "[^a-z0-9]", "")
			if string.find(dn, "yourplot", 1, true) or string.find(dn, "thisplot", 1, true) then
				return true
			end
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				local t = string.gsub(string.lower((d :: TextLabel).Text), "%s+", "")
				if string.find(t, "yourplot", 1, true) or string.find(t, "thisplot", 1, true) then
					return true
				end
			end
		end
	end
	return false
end

-- Studio markers look bad when scaled — keep them permanently off; we draw our own.
local function suppressStudioMarkers(plot: Instance?)
	if not plot then
		return
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if (d:IsA("BillboardGui") or d:IsA("SurfaceGui")) and isStudioOwnershipMarker(d, plot) then
			(d :: LayerCollector).Enabled = false
		end
	end
end

local function resolveMarkerAdornee(plot: Instance): BasePart?
	local story1 = PlotPaths.firstStoryFolder(plot)
	local searchRoot: Instance = if story1 then story1 else plot
	for _, d in ipairs(searchRoot:GetDescendants()) do
		if d:IsA("BasePart") then
			local n = string.gsub(string.lower(d.Name), "%s+", "")
			if n == "name" or string.find(n, "plotusername", 1, true) or n == "guipart" then
				return d
			end
		end
	end
	if plot:IsA("Model") then
		local m = plot :: Model
		if m.PrimaryPart then
			return m.PrimaryPart
		end
	end
	return plot:FindFirstChildWhichIsA("BasePart", true)
end

local function ensureMarker(plot: Instance): BillboardGui?
	local adornee = resolveMarkerAdornee(plot)
	if not adornee then
		return nil
	end

	local bb = markerBb
	if not bb or not bb.Parent or markerAdornee ~= adornee then
		if bb then
			bb:Destroy()
		end
		bb = Instance.new("BillboardGui")
		bb.Name = "YourPlotMarker"
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.Size = MARKER_BILLBOARD_SIZE
		bb.StudsOffset = MARKER_STUDS_OFFSET
		bb.MaxDistance = 160
		bb.Enabled = false
		bb.Adornee = adornee
		bb.Parent = Workspace.CurrentCamera or player:FindFirstChildOfClass("PlayerGui")

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Text = "Your Plot"
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeColor3 = Color3.fromRGB(20, 20, 30)
		label.TextStrokeTransparency = 0.35
		label.TextScaled = false
		label.TextSize = MARKER_TEXT_SIZE
		label.Font = Enum.Font.GothamBold
		UiFonts.applyBodyLabel(label, MARKER_TEXT_SIZE, 10)
		label.Parent = bb

		markerBb = bb
		markerLabel = label
		markerAdornee = adornee
	end

	return bb
end

local function applyMarkerFade(transparency: number, visible: boolean)
	local bb = markerBb
	local label = markerLabel
	if not bb or not label then
		return
	end
	if visible and (not cachedPlot or not isOwnedByLocalPlayer(cachedPlot)) then
		visible = false
		transparency = 1
	end
	bb.Enabled = visible
	if not visible then
		return
	end
	label.TextTransparency = transparency
	label.TextStrokeTransparency = math.clamp(transparency + 0.25, 0, 1)
end

-- Highlight wraps each mesh silhouette on the owned plot only.
local function ensureOutline(plot: Instance): Highlight?
	local hl = plotHighlight
	if not hl or not hl.Parent or hl.Adornee ~= plot then
		if hl then
			hl:Destroy()
		end
		hl = Instance.new("Highlight")
		hl.Name = "PlotSafezoneOutline"
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.OutlineColor = OUTLINE_COLOR
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Enabled = false
		hl.Adornee = plot
		hl.Parent = Workspace.CurrentCamera or plot
		plotHighlight = hl
	end
	return hl
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

local function refreshCachedPlot()
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
		destroyOutline()
		destroyMarker()
	end
	cachedPlot = plot
	cachedCenter = if plot then resolvePlotCenter(plot) else nil
	if plot then
		suppressStudioMarkers(plot)
	else
		destroyOutline()
		destroyMarker()
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
		if plotHighlight then
			plotHighlight.Enabled = false
			plotHighlight.OutlineTransparency = 1
		end
		applyMarkerFade(1, false)
		return
	end

	if not cachedPlot or not cachedPlot.Parent or not isOwnedByLocalPlayer(cachedPlot) then
		refreshCachedPlot()
	end
	local plot = cachedPlot
	local center = cachedCenter
	if not plot or not center or not isOwnedByLocalPlayer(plot) then
		destroyOutline()
		destroyMarker()
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	suppressStudioMarkers(plot)

	local dist = xzDist(hrp.Position, center)
	local transparency = outlineTransparencyForDistance(dist)
	local visible = transparency < 0.995

	local hl = ensureOutline(plot)
	if hl then
		hl.Enabled = visible
		hl.OutlineTransparency = transparency
		hl.OutlineColor = OUTLINE_COLOR
		hl.FillTransparency = 1
	end

	if visible then
		ensureMarker(plot)
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
