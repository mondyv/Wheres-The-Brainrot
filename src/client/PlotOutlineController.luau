-- [ACTIVE] PlotOutlineController
--[[
	Safezone only, YOUR plot only:
	• SelectionBox around the full base footprint (no Highlight — that washed floor textures).
	• Studio PlotGUI "Your Plot" + arrow, hard size-capped, same distance fade.
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
local FADE_START_DIST = 72
local FADE_END_DIST = 18
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local OUTLINE_FAR_TRANSPARENCY = 0.38
local BOX_LINE_THICKNESS = 0.14
-- Hard pixel lock — Studio PlotGUI grows huge with Scale/TextScaled.
local MARKER_W = 56
local MARKER_H = 48
local MARKER_TEXT_SIZE = 12
local MARKER_MAX_DISTANCE = 140

local PlotOutlineController = {}

local selectionBox: SelectionBox? = nil
local outlineProxy: BasePart? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local cachedMarkers: { BillboardGui } = {}
local wired = false

local function isOwnedByLocalPlayer(plot: Instance): boolean
	local uid = plot:GetAttribute("PlotOwnerUserId")
	return typeof(uid) == "number" and uid == player.UserId
end

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

local function isYourPlotMarker(inst: Instance, plotRoot: Instance): boolean
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

local function refreshMarkers(plot: Instance?)
	table.clear(cachedMarkers)
	if not plot then
		return
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BillboardGui") and isYourPlotMarker(d, plot) then
			table.insert(cachedMarkers, d)
		elseif d:IsA("SurfaceGui") and isYourPlotMarker(d, plot) then
			-- SurfaceGui markers balloon with part size — keep off.
			(d :: SurfaceGui).Enabled = false
		end
	end
end

local function stripScaleHacks(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("UIScale") then
			d:Destroy()
		end
	end
	local rootScale = root:FindFirstChildOfClass("UIScale")
	if rootScale then
		rootScale:Destroy()
	end
end

local function lockMarkerLook(bb: BillboardGui)
	-- Force offset pixels every tick so Studio Scale size cannot win.
	bb.Size = UDim2.new(0, MARKER_W, 0, MARKER_H)
	bb.MaxDistance = MARKER_MAX_DISTANCE
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	stripScaleHacks(bb)
	for _, d in ipairs(bb:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local label = d :: TextLabel
			label.TextScaled = false
			label.TextSize = MARKER_TEXT_SIZE
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if not constraint then
				constraint = Instance.new("UITextSizeConstraint")
				constraint.Parent = label
			end
			constraint.MaxTextSize = MARKER_TEXT_SIZE
			constraint.MinTextSize = 8
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
			-- Keep authored relative layout; don't stretch images past the billboard.
			if img.Size.X.Scale > 1 or img.Size.Y.Scale > 1 then
				img.Size = UDim2.fromScale(1, 1)
			end
			img.ScaleType = Enum.ScaleType.Fit
		end
	end
end

local function applyMarkerFade(transparency: number, visible: boolean)
	if visible and (not cachedPlot or not isOwnedByLocalPlayer(cachedPlot)) then
		visible = false
		transparency = 1
	end
	for _, bb in ipairs(cachedMarkers) do
		if not bb.Parent then
			continue
		end
		lockMarkerLook(bb)
		bb.Enabled = visible
		if not visible then
			continue
		end
		for _, d in ipairs(bb:GetDescendants()) do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				(d :: ImageLabel).ImageTransparency = transparency
			elseif d:IsA("TextLabel") or d:IsA("TextButton") then
				local text = d :: TextLabel
				text.TextTransparency = transparency
				text.TextStrokeTransparency = math.clamp(transparency + 0.2, 0, 1)
			end
		end
	end
end

-- Invisible proxy for SelectionBox — does not touch plot materials/textures.
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
		applyMarkerFade(1, false)
		destroyOutline()
	end
	cachedPlot = plot
	cachedCenter = if plot then resolvePlotCenter(plot) else nil
	refreshMarkers(plot)
	if not plot then
		destroyOutline()
		applyMarkerFade(1, false)
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
	elseif #cachedMarkers == 0 then
		refreshMarkers(cachedPlot)
	end

	local plot = cachedPlot
	local center = cachedCenter
	if not plot or not center or not isOwnedByLocalPlayer(plot) then
		destroyOutline()
		applyMarkerFade(1, false)
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local dist = xzDist(hrp.Position, center)
	local transparency = outlineTransparencyForDistance(dist)
	local visible = transparency < 0.995

	local box = ensureOutline(plot)
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
