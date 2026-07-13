-- [ACTIVE] ProximityPromptTheme
--[[
	Visual builder for custom proximity prompt billboards (pre-retro game style).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(script.Parent.ProximityPromptEffectsConfig)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local M = {}

export type CardParts = {
	root: Frame,
	rootScale: UIScale,
	rootStroke: UIStroke,
	keyBadge: Frame,
	keyStroke: UIStroke,
	holdTrack: Frame,
	holdFill: Frame,
	keyLabel: TextLabel,
	keyIcon: ImageLabel,
	actionLabel: TextLabel,
	objectLabel: TextLabel,
}

function M.buildCard(
	billboard: BillboardGui,
	prompt: ProximityPrompt,
	opts: {
		isMobile: boolean,
		isDisplayOnly: boolean,
		isManagedBush: boolean,
		isFloatingClaim: boolean,
		getOrAddUIScale: (Instance) -> UIScale,
	}
): CardParts
	local getScale = opts.getOrAddUIScale

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Active = not opts.isDisplayOnly
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = C.BG_COLOR
	root.BackgroundTransparency = C.BG_TRANSPARENCY
	root.BorderSizePixel = 0
	root.Parent = billboard

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 10)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Color = C.ACCENT
	rootStroke.Thickness = 1.5
	rootStroke.Transparency = 0.25
	rootStroke.Parent = root

	local rootGrad = Instance.new("UIGradient")
	rootGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 22, 28)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 10, 14)),
	})
	rootGrad.Rotation = 90
	rootGrad.Parent = root

	local rootScale = getScale(root)
	rootScale.Scale = if opts.isDisplayOnly and opts.isManagedBush then 1 else 0.82

	local keyBadge = Instance.new("Frame")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0, 0.5)
	keyBadge.Position = UDim2.new(0, C.PAD_LEFT, 0.5, 0)
	keyBadge.Size = UDim2.fromOffset(C.BADGE_SIZE, C.BADGE_SIZE)
	keyBadge.BackgroundColor3 = C.BADGE_BG
	keyBadge.BackgroundTransparency = C.BADGE_BG_TRANSPARENCY
	keyBadge.BorderSizePixel = 0
	keyBadge.Parent = root

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 8)
	badgeCorner.Parent = keyBadge

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = C.ACCENT_STROKE
	keyStroke.Thickness = 1.5
	keyStroke.Transparency = 0.35
	keyStroke.Parent = keyBadge

	if opts.isFloatingClaim then
		local gold = Color3.fromRGB(255, 210, 80)
		rootStroke.Color = gold
		keyStroke.Color = gold
	end

	local holdTrack = Instance.new("Frame")
	holdTrack.Name = "HoldTrack"
	holdTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	holdTrack.Position = UDim2.fromScale(0.5, 0.5)
	holdTrack.Size = UDim2.new(1, -C.BADGE_HOLD_PAD * 2, 1, -C.BADGE_HOLD_PAD * 2)
	holdTrack.BackgroundColor3 = Color3.fromRGB(8, 20, 12)
	holdTrack.BackgroundTransparency = 0.15
	holdTrack.BorderSizePixel = 0
	holdTrack.ClipsDescendants = true
	holdTrack.ZIndex = 1
	holdTrack.Visible = prompt.HoldDuration > 0
	holdTrack.Parent = keyBadge

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 6)
	trackCorner.Parent = holdTrack

	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = C.ACCENT_STROKE
	trackStroke.Thickness = 1.25
	trackStroke.Transparency = 0.35
	trackStroke.Parent = holdTrack

	local holdFill = Instance.new("Frame")
	holdFill.Name = "HoldFill"
	holdFill.AnchorPoint = Vector2.new(0.5, 1)
	holdFill.Position = UDim2.new(0.5, 0, 1, 0)
	holdFill.Size = UDim2.new(1, 0, 0, 0)
	holdFill.BackgroundColor3 = C.HOLD_GREEN_BRIGHT
	holdFill.BackgroundTransparency = 0.08
	holdFill.BorderSizePixel = 0
	holdFill.ZIndex = 2
	holdFill.Visible = prompt.HoldDuration > 0
	holdFill.Parent = holdTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = holdFill

	local fillGrad = Instance.new("UIGradient")
	fillGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.HOLD_GREEN),
		ColorSequenceKeypoint.new(0.5, C.HOLD_GREEN_BRIGHT),
		ColorSequenceKeypoint.new(1, C.ACCENT_BRIGHT),
	})
	fillGrad.Rotation = 90
	fillGrad.Parent = holdFill

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Key"
	keyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	keyLabel.Position = UDim2.fromScale(0.5, 0.5)
	keyLabel.Size = UDim2.new(1, -6, 1, -6)
	keyLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(keyLabel, if opts.isMobile then C.KEY_TEXT_SIZE_MOBILE else C.KEY_TEXT_SIZE, 14)
	keyLabel.Text = ""
	keyLabel.TextColor3 = C.TEXT_PRIMARY
	keyLabel.AutoLocalize = false
	keyLabel.ZIndex = 5
	keyLabel.Parent = keyBadge

	local keyIcon = Instance.new("ImageLabel")
	keyIcon.Name = "KeyIcon"
	keyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	keyIcon.Position = UDim2.fromScale(0.5, 0.5)
	keyIcon.Size = UDim2.new(1, -10, 1, -10)
	keyIcon.BackgroundTransparency = 1
	keyIcon.ScaleType = Enum.ScaleType.Fit
	keyIcon.ImageColor3 = Color3.new(1, 1, 1)
	keyIcon.ImageTransparency = 0
	keyIcon.Visible = false
	keyIcon.ZIndex = 10
	keyIcon.Parent = keyBadge

	local textCol = Instance.new("Frame")
	textCol.Name = "TextColumn"
	textCol.AnchorPoint = Vector2.new(0, 0.5)
	textCol.Position = UDim2.new(0, C.PAD_LEFT + C.BADGE_SIZE + C.BADGE_TEXT_GAP, 0.5, 0)
	textCol.Size = UDim2.new(1, -(C.PAD_LEFT + C.BADGE_SIZE + C.BADGE_TEXT_GAP + C.PAD_RIGHT), 1, -8)
	textCol.BackgroundTransparency = 1
	textCol.Parent = root

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "Action"
	actionLabel.Size = UDim2.new(1, 0, 0.52, 0)
	actionLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(actionLabel, C.ACTION_TEXT_SIZE, 12)
	actionLabel.Text = ""
	actionLabel.AutoLocalize = false
	actionLabel.TextXAlignment = Enum.TextXAlignment.Left
	actionLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	actionLabel.TextColor3 = C.TEXT_PRIMARY
	actionLabel.TextTruncate = Enum.TextTruncate.AtEnd
	actionLabel.TextWrapped = true
	actionLabel.Parent = textCol

	local objectLabel = Instance.new("TextLabel")
	objectLabel.Name = "Object"
	objectLabel.Position = UDim2.fromScale(0, 0.48)
	objectLabel.Size = UDim2.new(1, 0, 0.52, 0)
	objectLabel.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(objectLabel, C.OBJECT_TEXT_SIZE, 10)
	objectLabel.Text = ""
	objectLabel.AutoLocalize = false
	objectLabel.TextXAlignment = Enum.TextXAlignment.Left
	objectLabel.TextYAlignment = Enum.TextYAlignment.Top
	objectLabel.TextColor3 = C.TEXT_SECONDARY
	objectLabel.TextTruncate = Enum.TextTruncate.AtEnd
	objectLabel.TextWrapped = true
	objectLabel.Parent = textCol

	if opts.isManagedBush then
		M.applyBushSearchStyle({
			root = root,
			rootScale = rootScale,
			rootStroke = rootStroke,
			keyBadge = keyBadge,
			keyStroke = keyStroke,
			holdTrack = holdTrack,
			holdFill = holdFill,
			keyLabel = keyLabel,
			keyIcon = keyIcon,
			actionLabel = actionLabel,
			objectLabel = objectLabel,
		})
	end

	return {
		root = root,
		rootScale = rootScale,
		rootStroke = rootStroke,
		keyBadge = keyBadge,
		keyStroke = keyStroke,
		holdTrack = holdTrack,
		holdFill = holdFill,
		keyLabel = keyLabel,
		keyIcon = keyIcon,
		actionLabel = actionLabel,
		objectLabel = objectLabel,
	}
end

function M.applyBushSearchStyle(parts: CardParts)
	parts.keyBadge.BackgroundTransparency = C.BUSH_SEARCH_BADGE_BG_TRANSPARENCY
	parts.keyStroke.Transparency = C.BUSH_SEARCH_BADGE_STROKE_TRANSPARENCY
	parts.keyLabel.TextColor3 = C.TEXT_PRIMARY
	parts.keyIcon.ImageColor3 = C.TEXT_PRIMARY
end

function M.resetBadgeVisuals(parts: CardParts, isBush: boolean, hasStandStrokeGradient: boolean)
	parts.keyBadge.BackgroundColor3 = C.BADGE_BG
	if isBush then
		parts.keyBadge.BackgroundTransparency = C.BUSH_SEARCH_BADGE_BG_TRANSPARENCY
		parts.keyStroke.Color = C.ACCENT_STROKE
		parts.keyStroke.Transparency = C.BUSH_SEARCH_BADGE_STROKE_TRANSPARENCY
		parts.keyLabel.TextColor3 = C.TEXT_PRIMARY
	else
		parts.keyBadge.BackgroundTransparency = C.BADGE_BG_TRANSPARENCY
		if hasStandStrokeGradient then
			parts.keyStroke.Color = Color3.new(1, 1, 1)
			parts.keyStroke.Transparency = 0.2
		else
			parts.keyStroke.Color = C.ACCENT_STROKE
			parts.keyStroke.Transparency = 0.35
		end
		parts.keyLabel.TextColor3 = C.TEXT_PRIMARY
	end
	parts.keyIcon.ImageColor3 = if isBush then C.TEXT_PRIMARY else Color3.new(1, 1, 1)
end

function M.applyHoldBadgeActive(parts: CardParts, isBush: boolean)
	parts.keyBadge.BackgroundColor3 = C.HOLD_GREEN_BRIGHT
	if isBush then
		parts.keyBadge.BackgroundTransparency = 0.18
		parts.keyStroke.Transparency = 0.15
		parts.keyLabel.TextColor3 = Color3.fromRGB(16, 28, 20)
	else
		parts.keyBadge.BackgroundTransparency = 0.05
		parts.keyStroke.Transparency = 0.05
		parts.keyLabel.TextColor3 = Color3.fromRGB(16, 28, 20)
	end
	parts.holdTrack.BackgroundTransparency = 0.2
end

return M
