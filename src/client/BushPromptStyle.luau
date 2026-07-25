-- [ACTIVE] BushPromptStyle
--[[
	Pokémon-style bush search prompt: floating key/tap badge + circular hold ring.
	Used only for managed bush display-only billboards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local C = require(script.Parent.ProximityPromptEffectsConfig)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local M = {}

export type BushCardParts = {
	root: Frame,
	rootScale: UIScale,
	rootStroke: UIStroke,
	keyBadge: Frame,
	keyStroke: UIStroke,
	holdTrack: Frame,
	holdFill: Frame,
	holdRing: Frame,
	holdRingStroke: UIStroke,
	holdRingGradient: UIGradient,
	keyLabel: TextLabel,
	keyIcon: ImageLabel,
	actionLabel: TextLabel,
	objectLabel: TextLabel,
	glow: Frame,
}

local function setRingProgress(grad: UIGradient, progress: number)
	local p = math.clamp(progress, 0, 1)
	if p <= 0.001 then
		grad.Transparency = NumberSequence.new(1)
		return
	end
	if p >= 0.999 then
		grad.Transparency = NumberSequence.new(0)
		return
	end
	local edge = math.clamp(p + 0.002, 0.002, 1)
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(p, 0),
		NumberSequenceKeypoint.new(edge, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

function M.setHoldRingProgress(parts: { holdRingGradient: UIGradient, holdRingStroke: UIStroke? }, progress: number)
	local p = math.clamp(progress, 0, 1)
	setRingProgress(parts.holdRingGradient, p)
	local stroke = parts.holdRingStroke
	if stroke then
		stroke.Transparency = if p > 0.02 then 0.05 else 0.55
		stroke.Color = C.HOLD_GREEN_BRIGHT:Lerp(C.ACCENT_BRIGHT, p)
	end
end

function M.setInteractVisible(parts: { actionLabel: TextLabel, objectLabel: TextLabel }, visible: boolean, instant: boolean?)
	local targetT = if visible then 0 else 1
	if instant then
		parts.actionLabel.TextTransparency = targetT
		parts.objectLabel.TextTransparency = 1
		parts.actionLabel.Visible = visible
		return
	end
	parts.actionLabel.Visible = true
	parts.actionLabel.TextTransparency = if visible then 1 else 0
	TweenService:Create(parts.actionLabel, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = targetT,
	}):Play()
	if not visible then
		task.delay(0.15, function()
			if parts.actionLabel.Parent and parts.actionLabel.TextTransparency >= 0.95 then
				parts.actionLabel.Visible = false
			end
		end)
	end
end

function M.applyIdleStyle(parts: BushCardParts, isTouch: boolean)
	parts.root.BackgroundTransparency = 1
	parts.rootStroke.Transparency = 1
	parts.keyBadge.BackgroundColor3 = Color3.fromRGB(12, 28, 18)
	parts.keyBadge.BackgroundTransparency = 0.22
	parts.keyStroke.Color = C.ACCENT_STROKE
	parts.keyStroke.Transparency = 0.2
	parts.keyStroke.Thickness = 2.4
	parts.keyLabel.TextColor3 = C.TEXT_PRIMARY
	parts.keyIcon.ImageColor3 = Color3.new(1, 1, 1)
	parts.glow.BackgroundTransparency = 0.72
	parts.holdRingStroke.Transparency = 0.55
	parts.holdRingStroke.Color = C.ACCENT_STROKE
	setRingProgress(parts.holdRingGradient, 0)
	parts.holdRing.Visible = not isTouch
	parts.holdTrack.Visible = false
	parts.holdFill.Visible = false
	parts.actionLabel.Text = if isTouch then "TAP" else "INTERACT"
	parts.actionLabel.TextTransparency = 0
	parts.actionLabel.Visible = true
	parts.objectLabel.Text = ""
	parts.objectLabel.Visible = false
	parts.objectLabel.TextTransparency = 1
end

function M.applyHoldActive(parts: BushCardParts)
	parts.keyBadge.BackgroundColor3 = C.HOLD_GREEN_BRIGHT
	parts.keyBadge.BackgroundTransparency = 0.08
	parts.keyStroke.Color = C.ACCENT_BRIGHT
	parts.keyStroke.Transparency = 0.05
	parts.keyLabel.TextColor3 = Color3.fromRGB(12, 28, 18)
	parts.glow.BackgroundTransparency = 0.55
	parts.holdRing.Visible = true
	parts.holdRingStroke.Transparency = 0.05
	M.setInteractVisible(parts, false, false)
end

function M.build(
	billboard: BillboardGui,
	opts: {
		isTouch: boolean,
		getOrAddUIScale: (Instance) -> UIScale,
	}
): BushCardParts
	local getScale = opts.getOrAddUIScale
	local badgeSize = C.BUSH_POKE_BADGE_SIZE
	local ringPad = C.BUSH_POKE_RING_PAD
	local board = C.BUSH_POKE_BOARD_SIZE

	billboard.Size = UDim2.fromOffset(board, board)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Active = true
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = billboard

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Transparency = 1
	rootStroke.Parent = root

	local rootScale = getScale(root)
	rootScale.Scale = 1

	-- Soft aura behind the badge (Pokémon select glow).
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.new(0.5, 0, 0.46, 0)
	glow.Size = UDim2.fromOffset(badgeSize + ringPad * 2 + 28, badgeSize + ringPad * 2 + 28)
	glow.BackgroundColor3 = C.ACCENT
	glow.BackgroundTransparency = 0.72
	glow.BorderSizePixel = 0
	glow.ZIndex = 1
	glow.Parent = root

	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = glow

	local holdRing = Instance.new("Frame")
	holdRing.Name = "HoldRing"
	holdRing.AnchorPoint = Vector2.new(0.5, 0.5)
	holdRing.Position = UDim2.new(0.5, 0, 0.46, 0)
	holdRing.Size = UDim2.fromOffset(badgeSize + ringPad * 2, badgeSize + ringPad * 2)
	holdRing.BackgroundTransparency = 1
	holdRing.BorderSizePixel = 0
	holdRing.ZIndex = 2
	holdRing.Visible = not opts.isTouch
	holdRing.Parent = root

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = holdRing

	local holdRingStroke = Instance.new("UIStroke")
	holdRingStroke.Name = "RingStroke"
	holdRingStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	holdRingStroke.LineJoinMode = Enum.LineJoinMode.Round
	holdRingStroke.Thickness = C.BUSH_POKE_RING_THICKNESS
	holdRingStroke.Color = C.ACCENT_STROKE
	holdRingStroke.Transparency = 0.55
	holdRingStroke.Parent = holdRing

	local holdRingGradient = Instance.new("UIGradient")
	holdRingGradient.Name = "RingProgress"
	holdRingGradient.Rotation = -90
	holdRingGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.HOLD_GREEN_BRIGHT),
		ColorSequenceKeypoint.new(0.55, C.ACCENT),
		ColorSequenceKeypoint.new(1, C.ACCENT_BRIGHT),
	})
	holdRingGradient.Transparency = NumberSequence.new(1)
	holdRingGradient.Parent = holdRingStroke

	local keyBadge = Instance.new("Frame")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0.5, 0.5)
	keyBadge.Position = UDim2.new(0.5, 0, 0.46, 0)
	keyBadge.Size = UDim2.fromOffset(badgeSize, badgeSize)
	keyBadge.BackgroundColor3 = Color3.fromRGB(12, 28, 18)
	keyBadge.BackgroundTransparency = 0.22
	keyBadge.BorderSizePixel = 0
	keyBadge.ZIndex = 4
	keyBadge.Parent = root

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = keyBadge

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = C.ACCENT_STROKE
	keyStroke.Thickness = 2.4
	keyStroke.Transparency = 0.2
	keyStroke.Parent = keyBadge

	-- Legacy vertical hold track kept for PromptView compatibility (hidden on bush UI).
	local holdTrack = Instance.new("Frame")
	holdTrack.Name = "HoldTrack"
	holdTrack.Visible = false
	holdTrack.BackgroundTransparency = 1
	holdTrack.Size = UDim2.fromScale(1, 1)
	holdTrack.Parent = keyBadge

	local holdFill = Instance.new("Frame")
	holdFill.Name = "HoldFill"
	holdFill.Visible = false
	holdFill.BackgroundTransparency = 1
	holdFill.Size = UDim2.fromScale(1, 0)
	holdFill.Parent = holdTrack

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Key"
	keyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	keyLabel.Position = UDim2.fromScale(0.5, 0.5)
	keyLabel.Size = UDim2.new(1, -8, 1, -8)
	keyLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(keyLabel, C.BUSH_POKE_KEY_TEXT_SIZE, 18)
	keyLabel.Text = "E"
	keyLabel.TextColor3 = C.TEXT_PRIMARY
	keyLabel.AutoLocalize = false
	keyLabel.ZIndex = 6
	keyLabel.Parent = keyBadge

	local keyIcon = Instance.new("ImageLabel")
	keyIcon.Name = "KeyIcon"
	keyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	keyIcon.Position = UDim2.fromScale(0.5, 0.5)
	keyIcon.Size = UDim2.fromOffset(C.BUSH_POKE_TAP_ICON_SIZE, C.BUSH_POKE_TAP_ICON_SIZE + 8)
	keyIcon.BackgroundTransparency = 1
	keyIcon.ScaleType = Enum.ScaleType.Fit
	keyIcon.Image = C.TOUCH_TAP_ICON
	keyIcon.ImageColor3 = Color3.new(1, 1, 1)
	keyIcon.Visible = false
	keyIcon.ZIndex = 7
	keyIcon.Parent = keyBadge

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "Action"
	actionLabel.AnchorPoint = Vector2.new(0.5, 0)
	actionLabel.Position = UDim2.new(0.5, 0, 0.46, math.floor(badgeSize * 0.5) + ringPad + 10)
	actionLabel.Size = UDim2.new(1, -12, 0, 22)
	actionLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(actionLabel, C.BUSH_POKE_INTERACT_TEXT_SIZE, 10)
	actionLabel.Text = if opts.isTouch then "TAP" else "INTERACT"
	actionLabel.TextColor3 = C.ACCENT_BRIGHT
	actionLabel.TextXAlignment = Enum.TextXAlignment.Center
	actionLabel.TextYAlignment = Enum.TextYAlignment.Top
	actionLabel.AutoLocalize = false
	actionLabel.ZIndex = 5
	actionLabel.Parent = root

	local actionStroke = Instance.new("UIStroke")
	actionStroke.Color = Color3.fromRGB(8, 18, 12)
	actionStroke.Thickness = 1.6
	actionStroke.Transparency = 0.25
	actionStroke.Parent = actionLabel

	-- Unused on bush UI; kept so PromptView / applyLabels stay typed.
	local objectLabel = Instance.new("TextLabel")
	objectLabel.Name = "Object"
	objectLabel.Visible = false
	objectLabel.BackgroundTransparency = 1
	objectLabel.Size = UDim2.fromOffset(0, 0)
	objectLabel.Text = ""
	objectLabel.Parent = root

	return {
		root = root,
		rootScale = rootScale,
		rootStroke = rootStroke,
		keyBadge = keyBadge,
		keyStroke = keyStroke,
		holdTrack = holdTrack,
		holdFill = holdFill,
		holdRing = holdRing,
		holdRingStroke = holdRingStroke,
		holdRingGradient = holdRingGradient,
		keyLabel = keyLabel,
		keyIcon = keyIcon,
		actionLabel = actionLabel,
		objectLabel = objectLabel,
		glow = glow,
	}
end

return M
