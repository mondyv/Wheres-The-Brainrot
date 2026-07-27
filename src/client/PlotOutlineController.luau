-- [ACTIVE] PlotOutlineController
--[[
	Safezone only, YOUR plot only:
	• Highlight wraps plot silhouettes via an invisible proxy Model (never adorns the
	  real plot — Highlight on the live base washes floor textures).
	• Studio PlotGUI "Your Plot" + arrow, small hard size lock, same distance fade.
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
local OUTLINE_FAR_TRANSPARENCY = 0.35
local MAX_PROXY_PARTS = 80
-- Small hard lock — Studio PlotGUI blows up with Scale/TextScaled.
local MARKER_W = 40
local MARKER_H = 34
local MARKER_TEXT_SIZE = 9
local MARKER_MAX_DISTANCE = 140

local PlotOutlineController = {}

local plotHighlight: Highlight? = nil
local outlineProxyModel: Model? = nil
local outlineBuiltFor: Instance? = nil
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
	if plotHighlight then
		plotHighlight:Destroy()
		plotHighlight = nil
	end
	if outlineProxyModel then
		outlineProxyModel:Destroy()
		outlineProxyModel = nil
	end
	outlineBuiltFor = nil
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
			constraint.MinTextSize = 7
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
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

local function shouldMirrorPart(part: BasePart): boolean
	if part.Transparency >= 0.98 then
		return false
	end
	local vol = part.Size.X * part.Size.Y * part.Size.Z
	if vol < 1.5 then
		return false
	end
	local n = string.lower(part.Name)
	if string.find(n, "humanoid", 1, true) or n == "handle" then
		return false
	end
	return true
end

local function mirrorPartInto(model: Model, src: BasePart)
	local clone = src:Clone()
	for _, ch in ipairs(clone:GetChildren()) do
		if
			ch:IsA("Texture")
			or ch:IsA("Decal")
			or ch:IsA("SurfaceAppearance")
			or ch:IsA("SurfaceGui")
			or ch:IsA("BillboardGui")
			or ch:IsA("ProximityPrompt")
			or ch:IsA("ClickDetector")
			or ch:IsA("Script")
			or ch:IsA("LocalScript")
			or ch:IsA("Highlight")
		then
			ch:Destroy()
		end
	end
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Massless = true
	clone.Transparency = 1
	clone.Parent = model
end

-- Invisible clones of story meshes — Highlight adorns these, not the live plot.
local function ensureOutlineProxyModel(plot: Instance): Model?
	if outlineProxyModel and outlineProxyModel.Parent and outlineBuiltFor == plot then
		return outlineProxyModel
	end

	if outlineProxyModel then
		outlineProxyModel:Destroy()
		outlineProxyModel = nil
	end

	local story1 = PlotPaths.firstStoryFolder(plot) or plot
	local model = Instance.new("Model")
	model.Name = "PlotSafezoneOutlineProxy"
	model.Parent = Workspace.CurrentCamera or plot

	local scored: { { part: BasePart, vol: number } } = {}
	for _, d in ipairs(story1:GetDescendants()) do
		if d:IsA("BasePart") and shouldMirrorPart(d) then
			local p = d :: BasePart
			local vol = p.Size.X * p.Size.Y * p.Size.Z
			table.insert(scored, { part = p, vol = vol })
		end
	end
	table.sort(scored, function(a, b)
		return a.vol > b.vol
	end)

	local n = math.min(#scored, MAX_PROXY_PARTS)
	for i = 1, n do
		mirrorPartInto(model, scored[i].part)
	end

	if n == 0 then
		model:Destroy()
		return nil
	end

	outlineProxyModel = model
	outlineBuiltFor = plot
	return model
end

local function ensureOutline(plot: Instance): Highlight?
	local proxy = ensureOutlineProxyModel(plot)
	if not proxy then
		return nil
	end

	local hl = plotHighlight
	if not hl or not hl.Parent or hl.Adornee ~= proxy then
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
		hl.Adornee = proxy
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
		if plotHighlight then
			plotHighlight.Enabled = false
			plotHighlight.OutlineTransparency = 1
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

	local hl = ensureOutline(plot)
	if hl then
		hl.Enabled = visible
		hl.OutlineTransparency = transparency
		hl.OutlineColor = OUTLINE_COLOR
		hl.FillTransparency = 1
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
