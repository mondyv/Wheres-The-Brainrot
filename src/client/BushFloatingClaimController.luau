-- [ACTIVE] BushFloatingClaimController
--[[
	Floating bush brainrot offers — accept / decline flanking the model, countdown ring,
	pulse highlight, and vanish / decline FX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local RaritySpawnStyle = require(script.Parent.RaritySpawnStyle)

local player = Players.LocalPlayer

local FLOAT_ENDS_AT_ATTR = "BrainrotFloatEndsAt"
local FLOATING_PHASE = "Floating"
local OWNER_ATTR = "OwnerUserId"
local FLOAT_DURATION = 15
local FLANK_OFFSET_X = 4.2
local FLANK_OFFSET_Y = 1.65
local TIMER_OFFSET_Y = -1.05
-- Keep the buttons a consistent visual gap from the model regardless of camera distance, but
-- smooth the scale so small camera/model motion can't make them jitter or slide.
local FLANK_DISTANCE_REF = 20
local FLANK_DISTANCE_SCALE_MIN = 1.0
local FLANK_DISTANCE_SCALE_MAX = 2.4
local FLANK_SCALE_SMOOTHING = 0.15

local BushFloatingClaimController = {}

type TrackedOffer = {
	model: Model,
	uiAnchor: BasePart,
	highlight: Highlight,
	billboards: { BillboardGui },
	acceptBb: BillboardGui,
	declineBb: BillboardGui,
	timerBb: BillboardGui,
	acceptBtn: TextButton,
	declineBtn: TextButton,
	acceptScale: UIScale,
	declineScale: UIScale,
	acceptPanelScale: UIScale,
	declinePanelScale: UIScale,
	timeLabel: TextLabel,
	ring: Frame,
	decisionLocked: boolean,
	hoverCount: number,
	uiHoverFrozen: boolean,
	frozenWorldPositions: { [BillboardGui]: Vector3 }?,
	hoverFreezeConn: RBXScriptConnection?,
	unfreezeToken: number,
	bbOffsets: { [BillboardGui]: Vector3 },
	flankScaleSmoothed: number?,
	conns: { RBXScriptConnection },
}

local tracked: { [Model]: TrackedOffer } = {}
local tickerConn: RBXScriptConnection? = nil
local decisionRE: RemoteEvent? = nil

local HOVER_POP = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOVER_SCALE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_OUT = TweenInfo.new(0.26, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HOVER_LIFT = 0.22
local POP_IN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PUNCH = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function pulseColorForRarity(rarity: string?): Color3
	if typeof(rarity) == "string" then
		return RaritySpawnStyle.accentColor(rarity)
	end
	return Color3.fromRGB(120, 255, 160)
end

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

local function adorneeFor(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function modelPivotPosition(model: Model): Vector3?
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok and typeof(pivot) == "CFrame" then
		return (pivot :: CFrame).Position
	end
	local adornee = adorneeFor(model)
	return if adornee then adornee.Position else nil
end

local function createUiAnchor(model: Model): BasePart?
	local pos = modelPivotPosition(model)
	if not pos then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "FloatingClaimUiAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.15, 0.15, 0.15)
	anchor.CFrame = CFrame.new(pos)
	anchor.Parent = Workspace.CurrentCamera
	return anchor
end

local function syncUiAnchorPosition(entry: TrackedOffer)
	local pos = modelPivotPosition(entry.model)
	if not pos or not entry.uiAnchor.Parent then
		return
	end
	entry.uiAnchor.CFrame = CFrame.new(pos)
end

local function attachBillboardToAnchor(billboard: BillboardGui, anchor: BasePart, worldOffset: Vector3)
	billboard.Adornee = anchor
	billboard.StudsOffset = Vector3.zero
	billboard.StudsOffsetWorldSpace = worldOffset
end

local function getUiAnchor(entry: TrackedOffer): BasePart?
	if entry.uiAnchor and entry.uiAnchor.Parent then
		return entry.uiAnchor
	end
	return nil
end

local function getBillboardLiftValue(billboard: BillboardGui): NumberValue
	local lift = billboard:FindFirstChild("HoverLift")
	if lift and lift:IsA("NumberValue") then
		return lift
	end
	lift = Instance.new("NumberValue")
	lift.Name = "HoverLift"
	lift.Value = 0
	lift.Parent = billboard
	return lift
end

local function billboardWorldPosition(billboard: BillboardGui, anchor: BasePart): Vector3
	return anchor.Position + billboard.StudsOffsetWorldSpace
end

local function cameraFlatRight(): Vector3
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.new(1, 0, 0)
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(1, 0, 0)
	end
	return flat:Cross(Vector3.yAxis).Unit
end

local function cameraRelativeFlankOffset(sideSign: number, liftY: number, distanceScale: number): Vector3
	local right = cameraFlatRight()
	local scale = math.clamp(distanceScale, FLANK_DISTANCE_SCALE_MIN, FLANK_DISTANCE_SCALE_MAX)
	return right * (sideSign * FLANK_OFFSET_X * scale) + Vector3.yAxis * liftY
end

local function flankTargetScaleForEntry(entry: TrackedOffer): number
	local camera = Workspace.CurrentCamera
	local pos = modelPivotPosition(entry.model)
	if not camera or not pos then
		return entry.flankScaleSmoothed or 1
	end
	local dist = (camera.CFrame.Position - pos).Magnitude
	return math.clamp(dist / FLANK_DISTANCE_REF, FLANK_DISTANCE_SCALE_MIN, FLANK_DISTANCE_SCALE_MAX)
end

local function smoothedFlankScale(entry: TrackedOffer): number
	local target = flankTargetScaleForEntry(entry)
	local current = entry.flankScaleSmoothed
	if typeof(current) ~= "number" then
		-- First frame: snap so the buttons don't visibly slide in from a wrong spacing.
		entry.flankScaleSmoothed = target
		return target
	end
	-- Exponential smoothing kills the frame-to-frame distance jitter.
	current += (target - current) * FLANK_SCALE_SMOOTHING
	if math.abs(target - current) < 0.001 then
		current = target
	end
	entry.flankScaleSmoothed = current
	return current
end

local function updateBillboardPositions(entry: TrackedOffer)
	if entry.uiHoverFrozen then
		return
	end

	syncUiAnchorPosition(entry)
	local anchor = getUiAnchor(entry)
	if not anchor then
		return
	end

	local distanceScale = smoothedFlankScale(entry)
	local acceptLift = getBillboardLiftValue(entry.acceptBb).Value
	local declineLift = getBillboardLiftValue(entry.declineBb).Value

	entry.acceptBb.StudsOffset = Vector3.zero
	entry.declineBb.StudsOffset = Vector3.zero
	entry.timerBb.StudsOffset = Vector3.zero
	entry.acceptBb.StudsOffsetWorldSpace =
		cameraRelativeFlankOffset(-1, FLANK_OFFSET_Y + acceptLift, distanceScale)
	entry.declineBb.StudsOffsetWorldSpace =
		cameraRelativeFlankOffset(1, FLANK_OFFSET_Y + declineLift, distanceScale)
	entry.timerBb.StudsOffsetWorldSpace = Vector3.new(0, TIMER_OFFSET_Y * distanceScale, 0)
end

local function parentBillboard(bb: BillboardGui)
	local pg = player:FindFirstChild("PlayerGui")
	bb.Parent = pg or Workspace.CurrentCamera
end

local function disconnectTracked(entry: TrackedOffer)
	if entry.hoverFreezeConn then
		entry.hoverFreezeConn:Disconnect()
		entry.hoverFreezeConn = nil
	end
	for _, conn in entry.conns do
		conn:Disconnect()
	end
	table.clear(entry.conns)
	if entry.highlight.Parent then
		entry.highlight:Destroy()
	end
	if entry.uiAnchor.Parent then
		entry.uiAnchor:Destroy()
	end
	for _, bb in entry.billboards do
		if bb.Parent then
			bb:Destroy()
		end
	end
end

local function untrack(model: Model)
	local entry = tracked[model]
	if not entry then
		return
	end
	disconnectTracked(entry)
	tracked[model] = nil
end

local function fireDecision(model: Model, decision: string)
	if not decisionRE then
		return
	end
	decisionRE:FireServer(model, decision)
end

local function lockDecision(entry: TrackedOffer)
	entry.decisionLocked = true
	entry.acceptBtn.Active = false
	entry.declineBtn.Active = false
end

local function styleChoiceButton(
	btn: TextButton,
	label: string,
	accent: Color3,
	gradColors: { Color3 },
	textColor: Color3
)
	btn.Name = label
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 17
	btn.Text = label
	btn.TextColor3 = textColor
	btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	btn.TextStrokeTransparency = 0
	btn.AutoButtonColor = false
	btn.ZIndex = 3

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	panel.BackgroundTransparency = 0
	panel.BorderSizePixel = 0
	panel.ZIndex = 1
	panel.Parent = btn

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local grad = Instance.new("UIGradient")
	grad.Name = "PanelGrad"
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, gradColors[1]),
		ColorSequenceKeypoint.new(1, gradColors[2]),
	})
	grad.Rotation = 90
	grad.Offset = Vector2.zero
	grad.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = accent
	stroke.Thickness = 3
	stroke.Transparency = 0
	stroke.Parent = panel

	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	shine.BackgroundTransparency = 0.78
	shine.BorderSizePixel = 0
	shine.Size = UDim2.new(0.45, 0, 1.4, 0)
	shine.Rotation = 18
	shine.Position = UDim2.fromScale(-0.5, -0.2)
	shine.ZIndex = 2
	shine.Active = false
	shine.Parent = panel

	local scale = getOrAddUIScale(btn)
	scale.Scale = 0.01

	local panelScale = getOrAddUIScale(panel)
	panelScale.Scale = 1

	return btn, scale, panelScale
end

local function styleMinimalTimer(accent: Color3, parent: Instance): (TextLabel, Frame)
	local label = Instance.new("TextLabel")
	label.Name = "Time"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.new(1, 0, 0, 18)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 17
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.Text = string.format("%.1fs", FLOAT_DURATION)
	label.Parent = parent

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(0.88, 0, 0, 4)
	track.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	track.BackgroundTransparency = 0.55
	track.BorderSizePixel = 0
	track.Parent = parent

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local ring = Instance.new("Frame")
	ring.Name = "Fill"
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundColor3 = accent
	ring.BorderSizePixel = 0
	ring.Parent = track

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring

	return label, ring
end

local function makeFlankBillboard(name: string, worldOffset: Vector3, size: Vector2): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = name
	bb.Size = UDim2.fromOffset(size.X, size.Y)
	bb.StudsOffset = Vector3.zero
	bb.StudsOffsetWorldSpace = worldOffset
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 140
	bb.Active = true
	bb.ResetOnSpawn = false
	return bb
end

type ChoiceUiParts = {
	acceptBb: BillboardGui,
	declineBb: BillboardGui,
	timerBb: BillboardGui,
	acceptBtn: TextButton,
	declineBtn: TextButton,
	acceptScale: UIScale,
	declineScale: UIScale,
	acceptPanelScale: UIScale,
	declinePanelScale: UIScale,
	timeLabel: TextLabel,
	ring: Frame,
}

local function buildChoiceUi(_model: Model, rarity: string): ChoiceUiParts
	local accent = pulseColorForRarity(rarity)

	local acceptBb = makeFlankBillboard(
		"FloatingClaimAccept",
		Vector3.new(-FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
		Vector2.new(84, 46)
	)
	local acceptBtn, acceptScale, acceptPanelScale = styleChoiceButton(
		Instance.new("TextButton"),
		"Accept",
		Color3.fromRGB(70, 255, 140),
		{ Color3.fromRGB(18, 42, 28), Color3.fromRGB(8, 18, 12) },
		Color3.fromRGB(170, 255, 200)
	)
	acceptBtn.Parent = acceptBb

	local declineBb = makeFlankBillboard(
		"FloatingClaimDecline",
		Vector3.new(FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
		Vector2.new(84, 46)
	)
	local declineBtn, declineScale, declinePanelScale = styleChoiceButton(
		Instance.new("TextButton"),
		"Decline",
		Color3.fromRGB(255, 95, 85),
		{ Color3.fromRGB(42, 14, 14), Color3.fromRGB(18, 6, 8) },
		Color3.fromRGB(255, 190, 185)
	)
	declineBtn.Parent = declineBb

	local timerBb = makeFlankBillboard(
		"FloatingClaimTimer",
		Vector3.new(0, TIMER_OFFSET_Y, 0),
		Vector2.new(76, 26)
	)

	local label, ring = styleMinimalTimer(accent, timerBb)

	return {
		acceptBb = acceptBb,
		declineBb = declineBb,
		timerBb = timerBb,
		acceptBtn = acceptBtn,
		declineBtn = declineBtn,
		acceptScale = acceptScale,
		declineScale = declineScale,
		acceptPanelScale = acceptPanelScale,
		declinePanelScale = declinePanelScale,
		timeLabel = label,
		ring = ring,
	}
end

local function animateOfferIn(entry: TrackedOffer)
	updateBillboardPositions(entry)

	TweenService:Create(entry.acceptScale, POP_IN, { Scale = 1 }):Play()
	TweenService:Create(entry.declineScale, POP_IN, { Scale = 1 }):Play()

	for _, btn in { entry.acceptBtn, entry.declineBtn } do
		local panel = btn:FindFirstChild("Panel")
		local shine = if panel then panel:FindFirstChild("Shine") else nil
		if shine and shine:IsA("Frame") then
			TweenService:Create(shine, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromScale(1.2, -0.2),
			}):Play()
		end
	end
end

local function getButtonPanelStroke(btn: TextButton): UIStroke?
	local panel = btn:FindFirstChild("Panel")
	if panel then
		return panel:FindFirstChildOfClass("UIStroke")
	end
	return nil
end

local function punchButton(scale: UIScale, btn: TextButton, bright: Color3)
	TweenService:Create(scale, PUNCH, { Scale = 0.88 }):Play()
	task.delay(0.12, function()
		if scale.Parent then
			TweenService:Create(scale, PUNCH, { Scale = 1 }):Play()
		end
	end)
	local stroke = getButtonPanelStroke(btn)
	if stroke then
		local orig = stroke.Color
		stroke.Color = bright
		task.delay(0.18, function()
			if stroke.Parent then
				TweenService:Create(stroke, FADE, { Color = orig }):Play()
			end
		end)
	end
end

local function captureFrozenWorldPositions(entry: TrackedOffer)
	local anchor = getUiAnchor(entry)
	if not anchor then
		return
	end
	syncUiAnchorPosition(entry)
	entry.frozenWorldPositions = {}
	for _, billboard in entry.billboards do
		entry.frozenWorldPositions[billboard] = billboardWorldPosition(billboard, anchor)
	end
end

local function ensureHoverFreezeLoop(entry: TrackedOffer)
	if entry.hoverFreezeConn then
		return
	end
	entry.hoverFreezeConn = RunService.RenderStepped:Connect(function()
		if not entry.uiHoverFrozen then
			return
		end
		local frozen = entry.frozenWorldPositions
		if not frozen then
			return
		end
		local anchor = getUiAnchor(entry)
		if not anchor then
			return
		end
		syncUiAnchorPosition(entry)
		for billboard, worldPos in frozen do
			if not billboard.Parent then
				continue
			end
			local lift = getBillboardLiftValue(billboard).Value
			local holdPos = worldPos + Vector3.new(0, lift, 0)
			billboard.StudsOffset = Vector3.zero
			billboard.StudsOffsetWorldSpace = holdPos - anchor.Position
		end
	end)
end

local function startHoverFreeze(entry: TrackedOffer)
	if not entry.frozenWorldPositions then
		captureFrozenWorldPositions(entry)
	end
	entry.uiHoverFrozen = true
	ensureHoverFreezeLoop(entry)
end

local function stopHoverFreeze(entry: TrackedOffer)
	entry.uiHoverFrozen = false
	entry.frozenWorldPositions = nil
	if entry.hoverFreezeConn then
		entry.hoverFreezeConn:Disconnect()
		entry.hoverFreezeConn = nil
	end
end

local function tweenBillboardLift(billboard: BillboardGui, lifted: boolean)
	local liftValue = getBillboardLiftValue(billboard)
	TweenService:Create(liftValue, if lifted then HOVER_POP else HOVER_OUT, {
		Value = if lifted then HOVER_LIFT else 0,
	}):Play()
end

local function brightGradientColors(gradColors: { Color3 }, accent: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, gradColors[1]:Lerp(accent, 0.16)),
		ColorSequenceKeypoint.new(1, gradColors[2]:Lerp(accent, 0.1)),
	})
end

local function wireButtonHover(
	entry: TrackedOffer,
	btn: TextButton?,
	scale: UIScale?,
	panelScale: UIScale?,
	bb: BillboardGui?,
	accent: Color3,
	textColor: Color3,
	gradColors: { Color3 }
)
	if not btn or not scale or not panelScale or not bb then
		return
	end

	local panel = btn:FindFirstChild("Panel")
	local stroke = if panel then panel:FindFirstChildOfClass("UIStroke") else nil
	local grad = if panel then panel:FindFirstChild("PanelGrad") else nil
	local strokeBright = accent:Lerp(Color3.fromRGB(255, 255, 255), 0.55)
	local restGradient = ColorSequence.new({
		ColorSequenceKeypoint.new(0, gradColors[1]),
		ColorSequenceKeypoint.new(1, gradColors[2]),
	})
	local hoverGradient = brightGradientColors(gradColors, accent)

	btn.MouseEnter:Connect(function()
		if scale.Scale < 0.5 then
			return
		end
		entry.unfreezeToken += 1
		entry.hoverCount += 1
		startHoverFreeze(entry)
		tweenBillboardLift(bb, true)

		TweenService:Create(scale, HOVER_SCALE, { Scale = 1.05 }):Play()
		TweenService:Create(panelScale, HOVER_SCALE, { Scale = 1.02 }):Play()
		if stroke then
			TweenService:Create(stroke, HOVER_POP, {
				Thickness = 3.5,
				Color = strokeBright,
				Transparency = 0,
			}):Play()
		end
		if grad and grad:IsA("UIGradient") then
			grad.Color = hoverGradient
			TweenService:Create(grad, HOVER_POP, {
				Rotation = 82,
				Offset = Vector2.new(0.1, 0.02),
			}):Play()
		end
		TweenService:Create(btn, HOVER_POP, { TextColor3 = Color3.fromRGB(255, 255, 255) }):Play()
	end)

	btn.MouseLeave:Connect(function()
		entry.hoverCount = math.max(0, entry.hoverCount - 1)
		tweenBillboardLift(bb, false)
		TweenService:Create(scale, HOVER_SCALE, { Scale = 1 }):Play()
		TweenService:Create(panelScale, HOVER_SCALE, { Scale = 1 }):Play()
		if stroke then
			TweenService:Create(stroke, HOVER_OUT, {
				Thickness = 3,
				Color = accent,
				Transparency = 0,
			}):Play()
		end
		if grad and grad:IsA("UIGradient") then
			grad.Color = restGradient
			TweenService:Create(grad, HOVER_OUT, {
				Rotation = 90,
				Offset = Vector2.zero,
			}):Play()
		end
		TweenService:Create(btn, HOVER_OUT, { TextColor3 = textColor }):Play()

		if entry.hoverCount == 0 then
			entry.unfreezeToken += 1
			local token = entry.unfreezeToken
			task.delay(0.28, function()
				if entry.unfreezeToken ~= token or entry.hoverCount > 0 then
					return
				end
				stopHoverFreeze(entry)
			end)
		end
	end)
end

local function ensureTicker()
	if tickerConn then
		return
	end
	tickerConn = RunService.RenderStepped:Connect(function()
		if next(tracked) == nil then
			if tickerConn then
				tickerConn:Disconnect()
				tickerConn = nil
			end
			return
		end

		local now = Workspace:GetServerTimeNow()
		for model, entry in tracked do
			if not model.Parent then
				untrack(model)
				continue
			end
			updateBillboardPositions(entry)
			local endsAt = model:GetAttribute(FLOAT_ENDS_AT_ATTR)
			if typeof(endsAt) ~= "number" then
				continue
			end
			local remaining = math.max(0, endsAt - now)
			entry.timeLabel.Text = string.format("%.1fs", remaining)
			local frac = math.clamp(remaining / FLOAT_DURATION, 0, 1)
			entry.ring.Size = UDim2.fromScale(frac, 1)
			local urgency = 1 - frac
			entry.highlight.OutlineTransparency = 0.05 + urgency * 0.25
			if urgency > 0.65 then
				local flash = 0.5 + math.sin(now * 14) * 0.5
				entry.timeLabel.TextColor3 = Color3.fromRGB(255, math.floor(170 + flash * 85), math.floor(140 + flash * 60))
				local pulse = 1 + math.sin(now * 10) * 0.04
				if not entry.decisionLocked and not entry.uiHoverFrozen then
					entry.acceptScale.Scale = pulse
					entry.declineScale.Scale = pulse
				end
			else
				entry.timeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			end
		end
	end)
end

local pendingWatches: { [Model]: { RBXScriptConnection } } = {}

local function clearWatch(model: Model)
	local conns = pendingWatches[model]
	if not conns then
		return
	end
	for _, conn in conns do
		conn:Disconnect()
	end
	pendingWatches[model] = nil
end

local function ownsOffer(model: Model): boolean
	local ownerId = model:GetAttribute(OWNER_ATTR)
	return typeof(ownerId) == "number" and ownerId == player.UserId
end

local function isOfferBrainrotModel(model: Model): boolean
	return model:GetAttribute("BrainrotCarryPhase") ~= nil
		or model:GetAttribute(OWNER_ATTR) ~= nil
		or typeof(model:GetAttribute("BrainrotName")) == "string"
end

local function trackModel(model: Model)
	if tracked[model] then
		return
	end
	if not ownsOffer(model) then
		return
	end
	if model:GetAttribute("BrainrotCarryPhase") ~= FLOATING_PHASE then
		return
	end

	local anchor = createUiAnchor(model)
	if not anchor then
		return
	end

	local rarity = model:GetAttribute("BrainrotRarity")
	local rarityStr = if typeof(rarity) == "string" then rarity else "common"
	local color = pulseColorForRarity(rarityStr)

	local hl = Instance.new("Highlight")
	hl.Name = "FloatingClaimHighlight"
	hl.Adornee = model
	hl.FillTransparency = 0.82
	hl.OutlineTransparency = 0.05
	hl.OutlineColor = color
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = Workspace.CurrentCamera

	local ui = buildChoiceUi(model, rarityStr)
	for _, billboard in { ui.acceptBb, ui.declineBb, ui.timerBb } do
		attachBillboardToAnchor(billboard, anchor, Vector3.zero)
		parentBillboard(billboard)
	end

	local entry: TrackedOffer = {
		model = model,
		uiAnchor = anchor,
		highlight = hl,
		billboards = { ui.acceptBb, ui.declineBb, ui.timerBb },
		acceptBb = ui.acceptBb,
		declineBb = ui.declineBb,
		timerBb = ui.timerBb,
		acceptBtn = ui.acceptBtn,
		declineBtn = ui.declineBtn,
		acceptScale = ui.acceptScale,
		declineScale = ui.declineScale,
		acceptPanelScale = ui.acceptPanelScale,
		declinePanelScale = ui.declinePanelScale,
		timeLabel = ui.timeLabel,
		ring = ui.ring,
		decisionLocked = false,
		hoverCount = 0,
		uiHoverFrozen = false,
		frozenWorldPositions = nil,
		hoverFreezeConn = nil,
		unfreezeToken = 0,
		bbOffsets = {
			[ui.acceptBb] = Vector3.new(-FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
			[ui.declineBb] = Vector3.new(FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
			[ui.timerBb] = Vector3.new(0, TIMER_OFFSET_Y, 0),
		},
		flankScaleSmoothed = nil,
		conns = {},
	}
	tracked[model] = entry
	updateBillboardPositions(entry)

	local acceptAccent = Color3.fromRGB(70, 255, 140)
	local declineAccent = Color3.fromRGB(255, 95, 85)
	local acceptText = Color3.fromRGB(170, 255, 200)
	local declineText = Color3.fromRGB(255, 190, 185)

	table.insert(
		entry.conns,
		entry.acceptBtn.MouseButton1Click:Connect(function()
			if entry.decisionLocked then
				return
			end
			lockDecision(entry)
			punchButton(entry.acceptScale, entry.acceptBtn, Color3.fromRGB(160, 255, 190))
			GameSoundEffects.playProximityPromptAppear()
			fireDecision(model, "accept")
		end)
	)

	table.insert(
		entry.conns,
		entry.declineBtn.MouseButton1Click:Connect(function()
			if entry.decisionLocked then
				return
			end
			lockDecision(entry)
			punchButton(entry.declineScale, entry.declineBtn, Color3.fromRGB(255, 170, 160))
			GameSoundEffects.playErrorNotif()
			fireDecision(model, "decline")
		end)
	)

	table.insert(
		entry.conns,
		model:GetAttributeChangedSignal("BrainrotCarryPhase"):Connect(function()
			local phase = model:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" then
				GameSoundEffects.playProximityPromptAppear()
				untrack(model)
			elseif phase ~= FLOATING_PHASE then
				untrack(model)
			end
		end)
	)

	table.insert(
		entry.conns,
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				untrack(model)
			end
		end)
	)

	clearWatch(model)
	animateOfferIn(entry)
	local acceptGrad = { Color3.fromRGB(18, 42, 28), Color3.fromRGB(8, 18, 12) }
	local declineGrad = { Color3.fromRGB(42, 14, 14), Color3.fromRGB(18, 6, 8) }

	wireButtonHover(entry, entry.acceptBtn, entry.acceptScale, entry.acceptPanelScale, entry.acceptBb, acceptAccent, acceptText, acceptGrad)
	wireButtonHover(entry, entry.declineBtn, entry.declineScale, entry.declinePanelScale, entry.declineBb, declineAccent, declineText, declineGrad)
	ensureTicker()
end

local function tryTrackModel(model: Model)
	if tracked[model] then
		clearWatch(model)
		return
	end
	if not ownsOffer(model) then
		return
	end
	if model:GetAttribute("BrainrotCarryPhase") ~= FLOATING_PHASE then
		return
	end
	trackModel(model)
end

local function watchModel(model: Model)
	if tracked[model] or pendingWatches[model] then
		return
	end
	if not model:IsA("Model") or not isOfferBrainrotModel(model) then
		return
	end

	local conns: { RBXScriptConnection } = {}
	pendingWatches[model] = conns

	local function refresh()
		tryTrackModel(model)
	end

	refresh()
	table.insert(conns, model:GetAttributeChangedSignal("BrainrotCarryPhase"):Connect(refresh))
	table.insert(conns, model:GetAttributeChangedSignal(OWNER_ATTR):Connect(refresh))
	table.insert(
		conns,
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				clearWatch(model)
				untrack(model)
			end
		end)
	)
end

local function onBrainrotModelSeen(model: Model)
	if not model.Parent then
		return
	end
	watchModel(model)
end

local function scanRoot(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("Model") and isOfferBrainrotModel(desc) then
			onBrainrotModelSeen(desc)
		end
	end
end

local function spawnVanishBurst(worldPos: Vector3, rarity: string, declined: boolean)
	local anchor = Instance.new("Part")
	anchor.Name = if declined then "FloatingClaimDeclineFX" else "FloatingClaimVanishFX"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(worldPos)
	anchor.Parent = Workspace

	local color = if declined then Color3.fromRGB(255, 110, 95) else pulseColorForRarity(rarity)
	local count = if declined then 8 else 10

	for i = 1, count do
		local p = Instance.new("Part")
		p.Name = "Spark"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Size = Vector3.new(0.25, 0.25, 0.25)
		p.Color = color
		p.Material = Enum.Material.Neon
		p.CFrame = anchor.CFrame
		p.Parent = anchor

		local offset = Vector3.new(math.random() - 0.5, if declined then -0.2 else math.random() * 0.5, math.random() - 0.5).Unit
			* (1.2 + math.random() * 2)
		TweenService:Create(p, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(worldPos + offset),
			Transparency = 1,
			Size = Vector3.new(0.05, 0.05, 0.05),
		}):Play()
	end

	task.delay(0.5, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

function BushFloatingClaimController.hasActiveOffer(): boolean
	for model, entry in tracked do
		if model.Parent and not entry.decisionLocked then
			return true
		end
	end
	return false
end

function BushFloatingClaimController.init()
	scanRoot(Workspace)

	Workspace.DescendantAdded:Connect(function(desc)
		if desc:IsA("Model") then
			task.defer(function()
				onBrainrotModelSeen(desc)
			end)
		end
	end)

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("BushRemotes", 120)
		if not folder then
			warn("[BushFloatingClaimController] BushRemotes folder missing")
			return
		end
		local decision = folder:WaitForChild("FloatingClaimDecision", 120)
		if decision and decision:IsA("RemoteEvent") then
			decisionRE = decision
		else
			warn("[BushFloatingClaimController] FloatingClaimDecision remote missing")
		end

		local vanish = folder:WaitForChild("FloatingClaimVanish", 30)
		if vanish and vanish:IsA("RemoteEvent") then
			vanish.OnClientEvent:Connect(function(worldPos: any, rarity: any)
				if typeof(worldPos) ~= "Vector3" then
					return
				end
				spawnVanishBurst(worldPos, if typeof(rarity) == "string" then rarity else "common", false)
				GameSoundEffects.playErrorNotif()
			end)
		end

		local declined = folder:WaitForChild("FloatingClaimDeclineFX", 30)
		if declined and declined:IsA("RemoteEvent") then
			declined.OnClientEvent:Connect(function(worldPos: any, rarity: any)
				if typeof(worldPos) ~= "Vector3" then
					return
				end
				spawnVanishBurst(worldPos, if typeof(rarity) == "string" then rarity else "common", true)
			end)
		end
	end)
end

return BushFloatingClaimController
