-- [ACTIVE] BushPromptStyle
--[[
	Minimal bush search prompt: floating icon/E + thin circular hold ring.
	Mobile: icon only. PC: small E + quiet "Hold" label that fades while holding.
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
		stroke.Transparency = if p > 0.02 then 0.12 else 0.62
		stroke.Color = C.ACCENT:Lerp(C.ACCENT_BRIGHT, p * 0.55)
	end
end

function M.setInteractVisible(parts: { actionLabel: TextLabel, objectLabel: TextLabel }, visible: boolean, instant: boolean?)
	if not parts.actionLabel.Visible and not visible then
		return
	end
	local targetT = if visible then 0.15 else 1
	if instant then
		parts.actionLabel.TextTransparency = targetT
		parts.objectLabel.TextTransparency = 1
		parts.actionLabel.Visible = visible
		return
	end
	parts.actionLabel.Visible = true
	parts.actionLabel.TextTransparency = if visible then 1 else 0.15
	TweenService:Create(parts.actionLabel, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = targetT,
	}):Play()
	if not visible then
		task.delay(0.13, function()
			if parts.actionLabel.Parent and parts.actionLabel.TextTransparency >= 0.95 then
				parts.actionLabel.Visible = false
			end
		end)
	end
end

function M.applyIdleStyle(parts: BushCardParts, isTouch: boolean)
	parts.root.BackgroundTransparency = 1
	parts.rootStroke.Transparency = 1
	parts.glow.BackgroundTransparency = 1
	parts.glow.Visible = false
	parts.holdTrack.Visible = false
	parts.holdFill.Visible = false
	parts.objectLabel.Text = ""
	parts.objectLabel.Visible = false
	parts.objectLabel.TextTransparency = 1

	parts.holdRing.Visible = true
	parts.holdRingStroke.Transparency = 0.62
	parts.holdRingStroke.Color = C.ACCENT_STROKE
	setRingProgress(parts.holdRingGradient, 0)

	if isTouch then
		-- Mobile: bare hold icon, no badge plate / label.
		parts.keyBadge.BackgroundTransparency = 1
		parts.keyStroke.Transparency = 1
		parts.keyLabel.Visible = false
		parts.keyIcon.Visible = true
		parts.actionLabel.Visible = false
		parts.actionLabel.TextTransparency = 1
	else
		parts.keyBadge.BackgroundColor3 = Color3.fromRGB(14, 18, 16)
		parts.keyBadge.BackgroundTransparency = 0.35
		parts.keyStroke.Color = C.ACCENT_STROKE
		parts.keyStroke.Transparency = 0.4
		parts.keyStroke.Thickness = 1.5
		parts.keyLabel.Visible = true
		parts.keyLabel.TextColor3 = C.TEXT_PRIMARY
		parts.keyIcon.Visible = false
		parts.actionLabel.Text = "Hold"
		parts.actionLabel.TextTransparency = 0.15
		parts.actionLabel.Visible = true
	end
end

function M.applyHoldActive(parts: BushCardParts)
	parts.holdRing.Visible = true
	parts.holdRingStroke.Transparency = 0.12
	if parts.keyBadge.BackgroundTransparency < 1 then
		parts.keyBadge.BackgroundTransparency = 0.2
		parts.keyStroke.Transparency = 0.2
	end
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
	local badgeSize = if opts.isTouch then C.BUSH_POKE_MOBILE_ICON_SIZE else C.BUSH_POKE_BADGE_SIZE
	local ringPad = C.BUSH_POKE_RING_PAD
	local board = if opts.isTouch then C.BUSH_POKE_MOBILE_BOARD_SIZE else C.BUSH_POKE_BOARD_SIZE
	local centerY = 0.5

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

	-- Kept for PromptView compatibility; unused visually.
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.Visible = false
	glow.BackgroundTransparency = 1
	glow.Size = UDim2.fromOffset(0, 0)
	glow.Parent = root

	local holdRing = Instance.new("Frame")
	holdRing.Name = "HoldRing"
	holdRing.AnchorPoint = Vector2.new(0.5, 0.5)
	holdRing.Position = UDim2.fromScale(0.5, centerY)
	holdRing.Size = UDim2.fromOffset(badgeSize + ringPad * 2, badgeSize + ringPad * 2)
	holdRing.BackgroundTransparency = 1
	holdRing.BorderSizePixel = 0
	holdRing.ZIndex = 2
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
	holdRingStroke.Transparency = 0.62
	holdRingStroke.Parent = holdRing

	local holdRingGradient = Instance.new("UIGradient")
	holdRingGradient.Name = "RingProgress"
	holdRingGradient.Rotation = -90
	holdRingGradient.Color = ColorSequence.new(C.ACCENT, C.ACCENT_BRIGHT)
	holdRingGradient.Transparency = NumberSequence.new(1)
	holdRingGradient.Parent = holdRingStroke

	local keyBadge = Instance.new("Frame")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0.5, 0.5)
	keyBadge.Position = UDim2.fromScale(0.5, centerY)
	keyBadge.Size = UDim2.fromOffset(badgeSize, badgeSize)
	keyBadge.BackgroundColor3 = Color3.fromRGB(14, 18, 16)
	keyBadge.BackgroundTransparency = if opts.isTouch then 1 else 0.35
	keyBadge.BorderSizePixel = 0
	keyBadge.ZIndex = 4
	keyBadge.Parent = root

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = keyBadge

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = C.ACCENT_STROKE
	keyStroke.Thickness = 1.5
	keyStroke.Transparency = if opts.isTouch then 1 else 0.4
	keyStroke.Parent = keyBadge

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
	keyLabel.Size = UDim2.new(1, -6, 1, -6)
	keyLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(keyLabel, C.BUSH_POKE_KEY_TEXT_SIZE, 14)
	keyLabel.Text = "E"
	keyLabel.TextColor3 = C.TEXT_PRIMARY
	keyLabel.AutoLocalize = false
	keyLabel.Visible = not opts.isTouch
	keyLabel.ZIndex = 6
	keyLabel.Parent = keyBadge

	local keyIcon = Instance.new("ImageLabel")
	keyIcon.Name = "KeyIcon"
	keyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	keyIcon.Position = UDim2.fromScale(0.5, 0.5)
	keyIcon.Size = UDim2.fromOffset(C.BUSH_POKE_MOBILE_ICON_GLYPH, C.BUSH_POKE_MOBILE_ICON_GLYPH + 4)
	keyIcon.BackgroundTransparency = 1
	keyIcon.ScaleType = Enum.ScaleType.Fit
	keyIcon.Image = C.TOUCH_HOLD_ICON
	keyIcon.ImageColor3 = Color3.new(1, 1, 1)
	keyIcon.Visible = opts.isTouch
	keyIcon.ZIndex = 7
	keyIcon.Parent = keyBadge

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "Action"
	actionLabel.AnchorPoint = Vector2.new(0.5, 0)
	actionLabel.Position = UDim2.new(0.5, 0, centerY, math.floor(badgeSize * 0.5) + ringPad + 4)
	actionLabel.Size = UDim2.new(1, -8, 0, 16)
	actionLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(actionLabel, C.BUSH_POKE_INTERACT_TEXT_SIZE, 9)
	actionLabel.Text = "Hold"
	actionLabel.TextColor3 = C.TEXT_SECONDARY
	actionLabel.TextXAlignment = Enum.TextXAlignment.Center
	actionLabel.TextYAlignment = Enum.TextYAlignment.Top
	actionLabel.AutoLocalize = false
	actionLabel.Visible = not opts.isTouch
	actionLabel.TextTransparency = if opts.isTouch then 1 else 0.15
	actionLabel.ZIndex = 5
	actionLabel.Parent = root

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
