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
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local player = Players.LocalPlayer

local FLOAT_ENDS_AT_ATTR = "BrainrotFloatEndsAt"
local FLOAT_ANCHOR_ATTR = "BrainrotFloatAnchorPos"
local FLOATING_PHASE = "Floating"
local OWNER_ATTR = "OwnerUserId"
local BUSH_HARVEST_KEY_ATTR = "BrainrotHarvestBushKey"
local BUSH_FLOATING_CLAIM_ATTR = "BushFloatingClaimActive"
local DECLINING_ATTR = "BrainrotFloatDeclining"
local BUSH_OUTLINE_COLOR = Color3.fromRGB(255, 45, 45)
local OFFER_UI_HIDE_DISTANCE = 28
local OFFER_UI_MAX_DISTANCE = 36
local DEFAULT_OFFER_DURATION = 15
local FLOAT_DURATION = DEFAULT_OFFER_DURATION
local FLANK_OFFSET_X = 4.2
local FLANK_OFFSET_Y = 1.65
local TIMER_OFFSET_Y = -0.55
local FLANK_EDGE_PAD = 0.45
local TIMER_EDGE_PAD = 0.08
local TIMER_BELOW_SCALE = 0.38
local UI_ANCHOR_LIFT = 1.85
local CHOICE_BILLBOARD_SIZE = Vector2.new(68, 32)
local TIMER_BILLBOARD_SIZE = Vector2.new(62, 18)
local CHOICE_TEXT_MAX = 12
local TIMER_TEXT_MAX = 11
local TIMER_CAMERA_HIDE_DIST = 38

local BushFloatingClaimController = {}

type TrackedOffer = {
	model: Model,
	bush: Instance?,
	bushHighlight: Highlight?,
	restoreBushCooldownOnRelease: boolean,
	uiAnchor: BasePart,
	fixedUiWorldPos: Vector3,
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
	acceptDistanceScale: UIScale,
	declineDistanceScale: UIScale,
	timerDistanceScale: UIScale,
	timeLabel: TextLabel,
	ring: Frame,
	timerTrack: Frame?,
	decisionLocked: boolean,
	expiring: boolean,
	hoverCount: number,
	layoutHalfWidth: number,
	layoutFlankY: number,
	layoutTimerY: number,
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
local VANISH_OUT = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

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

local function resolveFixedUiWorldPos(model: Model): Vector3?
	local anchorAttr = model:GetAttribute(FLOAT_ANCHOR_ATTR)
	if typeof(anchorAttr) == "Vector3" then
		return (anchorAttr :: Vector3) + Vector3.new(0, UI_ANCHOR_LIFT, 0)
	end
	return modelPivotPosition(model)
end

local function createUiAnchor(worldPos: Vector3): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "FloatingClaimUiAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.15, 0.15, 0.15)
	anchor.CFrame = CFrame.new(worldPos)
	anchor.Parent = Workspace.CurrentCamera
	return anchor
end

local function syncUiAnchorPosition(entry: TrackedOffer)
	if not entry.uiAnchor.Parent then
		return
	end
	entry.uiAnchor.CFrame = CFrame.new(entry.fixedUiWorldPos)
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

local function cameraRelativeFlankOffset(sideSign: number, liftY: number, halfWidthStuds: number): Vector3
	local right = cameraFlatRight()
	return right * (sideSign * halfWidthStuds) + Vector3.yAxis * liftY
end

local function modelFlankLayout(model: Model): (number, number, number)
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return FLANK_OFFSET_X, FLANK_OFFSET_Y, TIMER_OFFSET_Y
	end

	local right = cameraFlatRight()
	local half = size * 0.5
	local halfWidth = math.abs(cf.RightVector:Dot(right)) * half.X
		+ math.abs(cf.LookVector:Dot(right)) * half.Z
		+ math.abs(cf.UpVector:Dot(right)) * half.Y

	local pivot = modelPivotPosition(model)
	local centerY = if pivot then pivot.Y else cf.Position.Y
	local topY = cf.Position.Y + half.Y
	local bottomY = cf.Position.Y - half.Y
	local aboveCenter = topY - centerY
	local belowCenter = centerY - bottomY

	return halfWidth + FLANK_EDGE_PAD, aboveCenter * 0.72 + 0.2, -(belowCenter * TIMER_BELOW_SCALE + TIMER_EDGE_PAD)
end

local function snapOfferLayout(entry: TrackedOffer)
	local hw, fy, ty = modelFlankLayout(entry.model)
	entry.layoutHalfWidth = hw
	entry.layoutFlankY = fy
	entry.layoutTimerY = ty
end

local function cameraDistanceToFixedAnchor(entry: TrackedOffer): number?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	return (camera.CFrame.Position - entry.fixedUiWorldPos).Magnitude
end

local function updateOfferUiVisibility(entry: TrackedOffer)
	local dist = playerDistanceToOffer(entry)
	if typeof(dist) ~= "number" then
		return
	end
	local camDist = cameraDistanceToFixedAnchor(entry)
	local showChoices = dist <= OFFER_UI_HIDE_DISTANCE
	local showTimer = dist <= OFFER_UI_MAX_DISTANCE
		and (typeof(camDist) ~= "number" or camDist <= TIMER_CAMERA_HIDE_DIST)
	entry.acceptBb.Enabled = showChoices
	entry.declineBb.Enabled = showChoices
	entry.timerBb.Enabled = showTimer
end

local function applyDistanceScale(entry: TrackedOffer)
	local scale = 1
	entry.acceptDistanceScale.Scale = scale
	entry.declineDistanceScale.Scale = scale
	entry.timerDistanceScale.Scale = scale
end

local function updateBillboardPositions(entry: TrackedOffer)
	syncUiAnchorPosition(entry)
	local anchor = getUiAnchor(entry)
	if not anchor then
		return
	end

	local acceptLift = getBillboardLiftValue(entry.acceptBb).Value
	local declineLift = getBillboardLiftValue(entry.declineBb).Value

	entry.acceptBb.StudsOffset = Vector3.zero
	entry.declineBb.StudsOffset = Vector3.zero
	entry.timerBb.StudsOffset = Vector3.zero
	entry.acceptBb.StudsOffsetWorldSpace =
		cameraRelativeFlankOffset(-1, entry.layoutFlankY + acceptLift, entry.layoutHalfWidth)
	entry.declineBb.StudsOffsetWorldSpace =
		cameraRelativeFlankOffset(1, entry.layoutFlankY + declineLift, entry.layoutHalfWidth)
	entry.timerBb.StudsOffsetWorldSpace = Vector3.new(0, entry.layoutTimerY, 0)

	applyDistanceScale(entry)
end

local function releaseBushForOffer(entry: TrackedOffer, restoreBushCooldown: boolean)
	local bush = entry.bush
	if not bush then
		return
	end
	entry.bush = nil
	if bush.Parent then
		bush:SetAttribute(BUSH_FLOATING_CLAIM_ATTR, nil)
	end
	if entry.bushHighlight then
		if entry.bushHighlight.Parent then
			entry.bushHighlight:Destroy()
		end
		entry.bushHighlight = nil
	end
	if bush.Parent then
		if restoreBushCooldown then
			ProximityPromptEffects.releaseBushCooldownBanner(bush)
		else
			ProximityPromptEffects.clearBushCooldownBannerSuppression(bush)
		end
		BushHoldInteraction.refreshCooldownVisuals()
	end
end

local function applyBushVisualsToEntry(entry: TrackedOffer, bush: Instance)
	local prompt = BushHoldInteraction.getPromptForBush(bush)
	bush:SetAttribute(BUSH_FLOATING_CLAIM_ATTR, true)
	ProximityPromptEffects.suppressBushCooldownBanner(bush, prompt)

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	if entry.bushHighlight and entry.bushHighlight.Parent then
		entry.bushHighlight:Destroy()
	end

	local bushHl = Instance.new("Highlight")
	bushHl.Name = "FloatingClaimBushHighlight"
	bushHl.Adornee = bush
	bushHl.FillTransparency = 1
	bushHl.OutlineTransparency = 0.05
	bushHl.OutlineColor = BUSH_OUTLINE_COLOR
	bushHl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	bushHl.Parent = cam

	entry.bush = bush
	entry.bushHighlight = bushHl
	BushHoldInteraction.refreshCooldownVisuals()
end

local function attachBushOfferVisuals(entry: TrackedOffer, model: Model)
	local bushKey = model:GetAttribute(BUSH_HARVEST_KEY_ATTR)
	if typeof(bushKey) ~= "string" or bushKey == "" then
		return
	end

	local function tryAttach()
		local bush = BushHoldInteraction.findBushByHarvestKey(bushKey)
		if bush and bush.Parent then
			applyBushVisualsToEntry(entry, bush)
			return true
		end
		return false
	end

	if tryAttach() then
		return
	end

	task.defer(function()
		if tracked[entry.model] ~= entry or entry.bush then
			return
		end
		tryAttach()
	end)
end

local function applyUrgencyFlash(entry: TrackedOffer, urgency: number, now: number)
	if entry.expiring then
		return
	end

	if urgency > 0.65 then
		local flash = 0.5 + math.sin(now * 14) * 0.5
		entry.timeLabel.TextColor3 =
			Color3.fromRGB(255, math.floor(170 + flash * 85), math.floor(140 + flash * 60))
		entry.highlight.OutlineTransparency = 0.05 + urgency * 0.25
		if entry.bushHighlight then
			entry.bushHighlight.OutlineTransparency = 0.05 + (1 - flash) * 0.35
			entry.bushHighlight.OutlineColor =
				Color3.fromRGB(255, math.floor(45 + flash * 120), math.floor(45 + flash * 40))
		end
		if not entry.decisionLocked and entry.hoverCount == 0 then
			local pulseStroke = 1 + math.sin(now * 10) * 0.025
			for _, btn in { entry.acceptBtn, entry.declineBtn } do
				local panel = btn:FindFirstChild("Panel")
				local stroke = if panel then panel:FindFirstChildOfClass("UIStroke") else nil
				if stroke then
					stroke.Thickness = 1.2 * pulseStroke
				end
			end
		end
	else
		entry.timeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		entry.highlight.OutlineTransparency = 0.05 + urgency * 0.25
		if entry.bushHighlight then
			entry.bushHighlight.OutlineTransparency = 0.05
			entry.bushHighlight.OutlineColor = BUSH_OUTLINE_COLOR
		end
		if not entry.decisionLocked and entry.hoverCount == 0 then
			for _, btn in { entry.acceptBtn, entry.declineBtn } do
				local panel = btn:FindFirstChild("Panel")
				local stroke = if panel then panel:FindFirstChildOfClass("UIStroke") else nil
				if stroke then
					stroke.Thickness = 1.2
					stroke.Transparency = 0.12
				end
			end
		end
	end
end

local function parentBillboard(bb: BillboardGui)
	local pg = player:FindFirstChild("PlayerGui")
	bb.Parent = pg or Workspace.CurrentCamera
end

local function disconnectTracked(entry: TrackedOffer)
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

local function untrack(model: Model, restoreBushCooldown: boolean?)
	local entry = tracked[model]
	if not entry then
		return
	end
	local restore = restoreBushCooldown
	if restore == nil then
		restore = entry.restoreBushCooldownOnRelease
			or model:GetAttribute(DECLINING_ATTR) == true
	end
	releaseBushForOffer(entry, restore == true)
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
	textColor: Color3,
	parent: Instance
)
	btn.Name = label
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBlack
	btn.TextScaled = true
	btn.Text = label
	btn.TextColor3 = textColor
	btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	btn.TextStrokeTransparency = 0
	btn.AutoButtonColor = false
	btn.ZIndex = 3

	local textBounds = Instance.new("UITextSizeConstraint")
	textBounds.MaxTextSize = CHOICE_TEXT_MAX
	textBounds.MinTextSize = 8
	textBounds.Parent = btn

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	panel.BackgroundTransparency = 0.42
	panel.BorderSizePixel = 0
	panel.ZIndex = 1
	panel.Parent = btn

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.28, 0)
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
	stroke.Thickness = 1.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Transparency = 0.12
	stroke.Parent = panel

	local scale = getOrAddUIScale(btn)
	scale.Scale = 0.01

	local panelScale = getOrAddUIScale(panel)
	panelScale.Scale = 1

	btn.Parent = parent

	return btn, scale, panelScale
end

local function styleMinimalTimer(accent: Color3, parent: Instance): (TextLabel, Frame, Frame)
	local label = Instance.new("TextLabel")
	label.Name = "Time"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.new(1, 0, 0.62, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.Text = string.format("%.1fs", DEFAULT_OFFER_DURATION)
	label.Parent = parent

	local textBounds = Instance.new("UITextSizeConstraint")
	textBounds.MaxTextSize = TIMER_TEXT_MAX
	textBounds.MinTextSize = 8
	textBounds.Parent = label

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(0.82, 0, 0.14, 0)
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

	return label, ring, track
end

local function addBillboardRoot(bb: BillboardGui): UIScale
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = bb

	local distanceScale = Instance.new("UIScale")
	distanceScale.Name = "DistanceScale"
	distanceScale.Scale = 1
	distanceScale.Parent = root

	return distanceScale, root
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
	acceptDistanceScale: UIScale,
	declineDistanceScale: UIScale,
	timerDistanceScale: UIScale,
	timeLabel: TextLabel,
	ring: Frame,
	timerTrack: Frame,
}

local function buildChoiceUi(_model: Model, rarity: string): ChoiceUiParts
	local accent = pulseColorForRarity(rarity)

	local acceptBb = makeFlankBillboard(
		"FloatingClaimAccept",
		Vector3.new(-FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
		CHOICE_BILLBOARD_SIZE
	)
	local acceptDistanceScale, acceptRoot = addBillboardRoot(acceptBb)
	local acceptBtn, acceptScale, acceptPanelScale = styleChoiceButton(
		Instance.new("TextButton"),
		"Accept",
		Color3.fromRGB(70, 255, 140),
		{ Color3.fromRGB(18, 42, 28), Color3.fromRGB(8, 18, 12) },
		Color3.fromRGB(170, 255, 200),
		acceptRoot
	)

	local declineBb = makeFlankBillboard(
		"FloatingClaimDecline",
		Vector3.new(FLANK_OFFSET_X, FLANK_OFFSET_Y, 0),
		CHOICE_BILLBOARD_SIZE
	)
	local declineDistanceScale, declineRoot = addBillboardRoot(declineBb)
	local declineBtn, declineScale, declinePanelScale = styleChoiceButton(
		Instance.new("TextButton"),
		"Decline",
		Color3.fromRGB(255, 95, 85),
		{ Color3.fromRGB(42, 14, 14), Color3.fromRGB(18, 6, 8) },
		Color3.fromRGB(255, 190, 185),
		declineRoot
	)

	local timerBb = makeFlankBillboard(
		"FloatingClaimTimer",
		Vector3.new(0, TIMER_OFFSET_Y, 0),
		TIMER_BILLBOARD_SIZE
	)
	local timerDistanceScale, timerRoot = addBillboardRoot(timerBb)
	local label, ring, track = styleMinimalTimer(accent, timerRoot)

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
		acceptDistanceScale = acceptDistanceScale,
		declineDistanceScale = declineDistanceScale,
		timerDistanceScale = timerDistanceScale,
		timeLabel = label,
		ring = ring,
		timerTrack = track,
	}
end

local function animateOfferIn(entry: TrackedOffer)
	applyDistanceScale(entry)
	updateBillboardPositions(entry)

	TweenService:Create(entry.acceptScale, POP_IN, { Scale = 1 }):Play()
	TweenService:Create(entry.declineScale, POP_IN, { Scale = 1 }):Play()
end

local function fadeButtonPanel(btn: TextButton)
	local panel = btn:FindFirstChild("Panel")
	if not panel or not panel:IsA("Frame") then
		return
	end
	TweenService:Create(panel, VANISH_OUT, { BackgroundTransparency = 1 }):Play()
	local stroke = panel:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, VANISH_OUT, { Transparency = 1 }):Play()
	end
end

local function animateOfferOut(entry: TrackedOffer, restoreBushCooldown: boolean?)
	if entry.expiring then
		return
	end
	entry.expiring = true
	lockDecision(entry)
	releaseBushForOffer(entry, restoreBushCooldown == true)

	local sinkScale = 0.02
	TweenService:Create(entry.acceptScale, VANISH_OUT, { Scale = sinkScale }):Play()
	TweenService:Create(entry.declineScale, VANISH_OUT, { Scale = sinkScale }):Play()
	TweenService:Create(entry.acceptDistanceScale, VANISH_OUT, { Scale = 0.01 }):Play()
	TweenService:Create(entry.declineDistanceScale, VANISH_OUT, { Scale = 0.01 }):Play()
	TweenService:Create(entry.timerDistanceScale, VANISH_OUT, { Scale = 0.01 }):Play()

	fadeButtonPanel(entry.acceptBtn)
	fadeButtonPanel(entry.declineBtn)
	TweenService:Create(entry.acceptBtn, VANISH_OUT, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	TweenService:Create(entry.declineBtn, VANISH_OUT, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	TweenService:Create(entry.timeLabel, VANISH_OUT, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	TweenService:Create(entry.ring, VANISH_OUT, { BackgroundTransparency = 1 }):Play()
	if entry.timerTrack then
		TweenService:Create(entry.timerTrack, VANISH_OUT, { BackgroundTransparency = 1 }):Play()
	end

	if entry.highlight.Parent then
		TweenService:Create(entry.highlight, VANISH_OUT, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
	end

	task.delay(VANISH_OUT.Time + 0.04, function()
		if tracked[entry.model] ~= entry then
			return
		end
		for _, bb in entry.billboards do
			bb.Enabled = false
		end
	end)
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
		entry.hoverCount += 1
		tweenBillboardLift(bb, true)

		TweenService:Create(scale, HOVER_SCALE, { Scale = 1.05 }):Play()
		TweenService:Create(panelScale, HOVER_SCALE, { Scale = 1.02 }):Play()
		if stroke then
			TweenService:Create(stroke, HOVER_POP, {
				Thickness = 1.5,
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
				Thickness = 1.2,
				Color = accent,
				Transparency = 0.12,
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
	end)
end

local function ensureTicker()
	if tickerConn then
		return
	end
	tickerConn = RunService.Heartbeat:Connect(function(dt)
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
			updateOfferUiVisibility(entry)
			if entry.expiring then
				continue
			end
			local endsAt = model:GetAttribute(FLOAT_ENDS_AT_ATTR)
			if typeof(endsAt) ~= "number" then
				continue
			end
			local remaining = math.max(0, endsAt - now)
			entry.timeLabel.Text = string.format("%.1fs", remaining)
			local frac = math.clamp(remaining / FLOAT_DURATION, 0, 1)
			entry.ring.Size = UDim2.fromScale(frac, 1)
			local urgency = 1 - frac
			applyUrgencyFlash(entry, urgency, now)
			if remaining <= 0 then
				animateOfferOut(entry, false)
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

	local fixedPos = resolveFixedUiWorldPos(model)
	if not fixedPos then
		return
	end

	local anchor = createUiAnchor(fixedPos)

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
		bush = nil,
		bushHighlight = nil,
		restoreBushCooldownOnRelease = false,
		uiAnchor = anchor,
		fixedUiWorldPos = fixedPos,
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
		acceptDistanceScale = ui.acceptDistanceScale,
		declineDistanceScale = ui.declineDistanceScale,
		timerDistanceScale = ui.timerDistanceScale,
		timeLabel = ui.timeLabel,
		ring = ui.ring,
		timerTrack = ui.timerTrack,
		decisionLocked = false,
		expiring = false,
		hoverCount = 0,
		layoutHalfWidth = FLANK_OFFSET_X,
		layoutFlankY = FLANK_OFFSET_Y,
		layoutTimerY = TIMER_OFFSET_Y,
		conns = {},
	}
	tracked[model] = entry
	snapOfferLayout(entry)
	attachBushOfferVisuals(entry, model)
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
			BushHoldInteraction.suppressBushSearchBriefly(2.5)
			ProximityPromptEffects.hideBushSearch()
			fireDecision(model, "accept")
		end)
	)

	table.insert(
		entry.conns,
		entry.declineBtn.MouseButton1Click:Connect(function()
			if entry.decisionLocked then
				return
			end
			entry.restoreBushCooldownOnRelease = true
			punchButton(entry.declineScale, entry.declineBtn, Color3.fromRGB(255, 170, 160))
			GameSoundEffects.playErrorNotif()
			animateOfferOut(entry, true)
			fireDecision(model, "decline")
		end)
	)

	table.insert(
		entry.conns,
		model:GetAttributeChangedSignal("BrainrotCarryPhase"):Connect(function()
			local phase = model:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" then
				GameSoundEffects.playProximityPromptAppear()
				if not entry.expiring then
					animateOfferOut(entry, false)
				end
				task.delay(VANISH_OUT.Time + 0.06, function()
					untrack(model, false)
				end)
			elseif phase ~= FLOATING_PHASE then
				untrack(model, false)
			end
		end)
	)

	table.insert(
		entry.conns,
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				if entry.expiring then
					task.delay(VANISH_OUT.Time + 0.06, function()
						untrack(model)
					end)
				else
					untrack(model)
				end
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
	updateOfferUiVisibility(tracked[model] :: TrackedOffer)
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
				spawnVanishBurst(worldPos, if typeof(rarity) == "string" then rarity else "common", true)
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
