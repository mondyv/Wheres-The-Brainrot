-- [ACTIVE] PlotOutlineController
--[[
	Safezone only, YOUR plot only:
	• Highlight wraps the whole base via invisible mesh proxies (never adorns the live
	  plot — that washes floor textures).
	• Studio PlotGUI "Your Plot" + arrow: one-line text, fades near and far (no hard cut).
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
-- Invisible on the pad.
local FADE_NEAR = 16
-- Fully visible between these distances.
local VISIBLE_NEAR = 28
local VISIBLE_FAR = 78
-- Fully faded out in the distance (soft, not MaxDistance cut).
local FADE_FAR = 125
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
-- Wide + short so "Your Plot" stays on one line.
local MARKER_W = 78
local MARKER_H = 30
local MARKER_TEXT_SIZE = 11

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
	-- Soft far fade handles cutoff — don't hard-kill the billboard.
	bb.MaxDistance = FADE_FAR + 40
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	stripScaleHacks(bb)

	-- Flatten vertical stacks so "Your" / "Plot" sit on one line.
	for _, d in ipairs(bb:GetDescendants()) do
		if d:IsA("UIListLayout") then
			(d :: UIListLayout).FillDirection = Enum.FillDirection.Horizontal
			(d :: UIListLayout).HorizontalAlignment = Enum.HorizontalAlignment.Center
			(d :: UIListLayout).VerticalAlignment = Enum.VerticalAlignment.Center
			(d :: UIListLayout).Padding = UDim.new(0, 4)
		end
	end

	for _, d in ipairs(bb:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local label = d :: TextLabel
			local flat = string.gsub(label.Text, "[\r\n]+", " ")
			flat = string.gsub(flat, "%s+", " ")
			flat = string.gsub(flat, "^%s*(.-)%s*$", "%1")
			if flat ~= "" then
				label.Text = flat
			end
			label.TextScaled = false
			label.TextWrapped = false
			label.TextSize = MARKER_TEXT_SIZE
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.TextYAlignment = Enum.TextYAlignment.Center
			local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
			if not constraint then
				constraint = Instance.new("UITextSizeConstraint")
				constraint.Parent = label
			end
			constraint.MaxTextSize = MARKER_TEXT_SIZE
			constraint.MinTextSize = 8
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
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
				-- Fade fill + stroke together (stroke lagging made it look darker up close).
				text.TextTransparency = transparency
				text.TextStrokeTransparency = transparency
			end
		end
	end
end

local function ensureOutlineProxyModel(plot: Instance): Model?
	if outlineProxyModel and outlineProxyModel.Parent and outlineBuiltFor == plot then
		return outlineProxyModel
	end
	if outlineProxyModel then
		outlineProxyModel:Destroy()
		outlineProxyModel = nil
	end
	local model = PlotSpawnUtil.buildInvisibleOutlineProxy(plot, Workspace.CurrentCamera or plot)
	outlineProxyModel = model
	outlineBuiltFor = if model then plot else nil
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

-- 0 = fully visible, 1 = gone. Fades near the pad AND in the distance.
local function outlineTransparencyForDistance(dist: number): number
	if dist <= FADE_NEAR or dist >= FADE_FAR then
		return 1
	end
	if dist >= VISIBLE_NEAR and dist <= VISIBLE_FAR then
		return 0
	end
	if dist < VISIBLE_NEAR then
		local t = (dist - FADE_NEAR) / (VISIBLE_NEAR - FADE_NEAR)
		return 1 - t
	end
	local t = (dist - VISIBLE_FAR) / (FADE_FAR - VISIBLE_FAR)
	return t
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
