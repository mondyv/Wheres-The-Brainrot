-- [ACTIVE] CharacterWorldNotif
--[[
	Plain floating text beside the local player's character (no panel chrome).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UiFonts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local CharacterWorldNotif = {}

local activeBillboard: BillboardGui? = nil
local activeLabel: TextLabel? = nil
local dotsConn: RBXScriptConnection? = nil
local followConn: RBXScriptConnection? = nil
local baseText = ""
local dismissToken = 0

local FADE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

export type ShowOpts = {
	offset: Vector3?,
	color: Color3?,
	lifetimeSec: number?,
	ellipsis: boolean?,
	hideRankBadges: boolean?,
	textSize: number?,
	heightPx: number?,
}

export type CelebrateOpts = {
	offset: Vector3?,
	color: Color3?,
	lifetimeSec: number?,
	hideRankBadges: boolean?,
	subtitle: string?,
	headline: string?, -- big number under the tag, e.g. "12"
}

local function resolveAdornee(character: Model?): BasePart?
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return character:FindFirstChildWhichIsA("BasePart", true)
end

local function stopDots()
	if dotsConn then
		dotsConn:Disconnect()
		dotsConn = nil
	end
end

local function stopFollow()
	if followConn then
		followConn:Disconnect()
		followConn = nil
	end
end

local function setRankBadgeSuppress(suppressed: boolean)
	local ok, RankController = pcall(function()
		return require(script.Parent.LeaderboardRankController)
	end)
	if not ok or not RankController then
		return
	end
	if typeof(RankController.setLocalWorldNotifSuppress) == "function" then
		RankController.setLocalWorldNotifSuppress(suppressed)
	end
end

local function destroyActive()
	stopDots()
	stopFollow()
	dismissToken += 1
	if activeBillboard then
		activeBillboard:Destroy()
	end
	activeBillboard = nil
	activeLabel = nil
	baseText = ""
	setRankBadgeSuppress(false)
end

local function startEllipsis(label: TextLabel)
	stopDots()
	local phase = 0
	dotsConn = RunService.Heartbeat:Connect(function(dt)
		if not label.Parent then
			stopDots()
			return
		end
		phase += dt
		local step = math.floor(phase * 2.2) % 4
		local dots = if step == 0 then "" elseif step == 1 then "." elseif step == 2 then ".." else "..."
		label.Text = baseText .. dots
	end)
end

function CharacterWorldNotif.dismiss()
	if not activeBillboard or not activeLabel then
		destroyActive()
		return
	end
	local bb = activeBillboard
	local label = activeLabel
	stopDots()
	stopFollow()
	dismissToken += 1
	activeBillboard = nil
	activeLabel = nil
	baseText = ""
	setRankBadgeSuppress(false)

	if label.Parent then
		local canvas = bb:FindFirstChild("Canvas")
		if canvas and canvas:IsA("CanvasGroup") then
			TweenService:Create(canvas, FADE_OUT, { GroupTransparency = 1 }):Play()
		else
			TweenService:Create(label, FADE_OUT, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
		end
	end
	task.delay(FADE_OUT.Time + 0.03, function()
		if bb.Parent then
			bb:Destroy()
		end
	end)
end

function CharacterWorldNotif.isActive(): boolean
	return activeBillboard ~= nil and activeBillboard.Parent ~= nil
end

function CharacterWorldNotif.getBaseText(): string
	return baseText
end

function CharacterWorldNotif.show(character: Model?, message: string, opts: ShowOpts?)
	if typeof(message) ~= "string" or message == "" then
		return
	end
	local char = character or player.Character
	local adornee = resolveAdornee(char)
	if not adornee then
		return
	end

	CharacterWorldNotif.dismiss()

	local offset = if opts and opts.offset then opts.offset else Vector3.new(2.8, 1.35, 0)
	local textColor = if opts and opts.color then opts.color else Color3.fromRGB(255, 228, 170)
	local useEllipsis = not (opts and opts.ellipsis == false)
	local lifetimeSec = if opts and typeof(opts.lifetimeSec) == "number" then opts.lifetimeSec else nil
	local hideBadges = not (opts and opts.hideRankBadges == false)

	baseText = message
	if hideBadges then
		setRankBadgeSuppress(true)
	end

	local heightPx = if opts and typeof(opts.heightPx) == "number" then opts.heightPx else 40
	local textSize = if opts and typeof(opts.textSize) == "number" then opts.textSize else 16

	local bb = Instance.new("BillboardGui")
	bb.Name = "CharacterWorldNotif"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 140
	bb.Size = UDim2.fromOffset(360, heightPx)
	bb.StudsOffset = offset
	bb.Adornee = adornee
	bb.Parent = char

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = UiFonts.BODY_LEGACY
	UiFonts.applyBody(label)
	label.TextSize = textSize
	label.TextColor3 = textColor
	label.TextStrokeColor3 = Color3.fromRGB(18, 12, 8)
	label.TextStrokeTransparency = 0.35
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = message
	label.TextTransparency = 1
	label.Parent = bb

	activeBillboard = bb
	activeLabel = label

	TweenService:Create(label, FADE_IN, {
		TextTransparency = 0,
		TextStrokeTransparency = 0.35,
	}):Play()
	if useEllipsis then
		startEllipsis(label)
	end

	local token = dismissToken
	followConn = RunService.RenderStepped:Connect(function()
		if token ~= dismissToken or not bb.Parent then
			stopFollow()
			return
		end
		local liveChar = player.Character
		local liveAdornee = resolveAdornee(liveChar)
		if liveAdornee and liveAdornee ~= bb.Adornee then
			bb.Adornee = liveAdornee
			if bb.Parent ~= liveChar and liveChar then
				bb.Parent = liveChar
			end
		end
	end)

	if typeof(lifetimeSec) == "number" and lifetimeSec > 0 then
		task.delay(lifetimeSec, function()
			if token ~= dismissToken then
				return
			end
			if activeBillboard == bb then
				CharacterWorldNotif.dismiss()
			end
		end)
	end
end

-- Level-up / big reward: gold plate over the body, no wiggle.
function CharacterWorldNotif.showCelebration(character: Model?, title: string, opts: CelebrateOpts?)
	if typeof(title) ~= "string" or title == "" then
		return
	end
	local char = character or player.Character
	local adornee = resolveAdornee(char)
	if not adornee then
		return
	end

	CharacterWorldNotif.dismiss()

	local offset = if opts and opts.offset then opts.offset else Vector3.new(0, 3.45, 0)
	local gold = if opts and opts.color then opts.color else Color3.fromRGB(255, 214, 70)
	local lifetimeSec = if opts and typeof(opts.lifetimeSec) == "number" then opts.lifetimeSec else 3.6
	local hideBadges = not (opts and opts.hideRankBadges == false)
	local subtitle = if opts and typeof(opts.subtitle) == "string" then opts.subtitle else nil
	local headline = if opts and typeof(opts.headline) == "string" and opts.headline ~= "" then opts.headline else nil
	if not headline then
		local n = string.match(title, "(%d+)")
		if n then
			headline = n
		end
	end
	local tagText = if headline then "LEVEL UP" else string.upper(title)
	local hasSub = subtitle ~= nil and subtitle ~= ""
	local hasHeadline = headline ~= nil

	baseText = title
	if hideBadges then
		setRankBadgeSuppress(true)
	end

	local heightPx = 78
	if hasHeadline then
		heightPx += 52
	end
	if hasSub then
		heightPx += 36
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "CharacterWorldNotifCelebrate"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 180
	bb.Size = UDim2.fromOffset(280, heightPx)
	bb.StudsOffset = offset
	bb.Adornee = adornee

	local canvas = Instance.new("CanvasGroup")
	canvas.Name = "Canvas"
	canvas.BackgroundTransparency = 1
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.GroupTransparency = 1
	canvas.Parent = bb

	local scale = Instance.new("UIScale")
	scale.Scale = 0.42
	scale.Parent = canvas

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	plate.Size = UDim2.new(1, -8, 1, -6)
	plate.BackgroundColor3 = Color3.fromRGB(16, 10, 6)
	plate.BackgroundTransparency = 0.12
	plate.BorderSizePixel = 0
	plate.Parent = canvas

	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0, 18)
	plateCorner.Parent = plate

	local plateStroke = Instance.new("UIStroke")
	plateStroke.Color = gold
	plateStroke.Thickness = 2.4
	plateStroke.Transparency = 0.15
	plateStroke.Parent = plate

	local platePad = Instance.new("UIPadding")
	platePad.PaddingTop = UDim.new(0, 10)
	platePad.PaddingBottom = UDim.new(0, 10)
	platePad.PaddingLeft = UDim.new(0, 12)
	platePad.PaddingRight = UDim.new(0, 12)
	platePad.Parent = plate

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 2)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = plate

	local tag = Instance.new("TextLabel")
	tag.Name = "Tag"
	tag.BackgroundTransparency = 1
	tag.LayoutOrder = 1
	tag.Size = UDim2.new(1, 0, 0, 18)
	tag.Font = UiFonts.DISPLAY_LEGACY
	UiFonts.applyDisplay(tag)
	tag.TextSize = 13
	tag.TextColor3 = Color3.fromRGB(255, 236, 170)
	tag.TextStrokeColor3 = Color3.fromRGB(40, 22, 4)
	tag.TextStrokeTransparency = 0.35
	tag.TextXAlignment = Enum.TextXAlignment.Center
	tag.TextYAlignment = Enum.TextYAlignment.Center
	tag.Text = tagText
	tag.Parent = plate

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.BackgroundTransparency = 1
	titleLabel.LayoutOrder = 2
	titleLabel.Size = UDim2.new(1, 0, 0, if hasHeadline then 52 else 36)
	titleLabel.Font = UiFonts.DISPLAY_LEGACY
	UiFonts.applyDisplay(titleLabel)
	titleLabel.TextSize = if hasHeadline then 48 else 26
	titleLabel.TextColor3 = gold
	titleLabel.TextStrokeColor3 = Color3.fromRGB(18, 8, 0)
	titleLabel.TextStrokeTransparency = 0.05
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.TextYAlignment = Enum.TextYAlignment.Center
	titleLabel.TextWrapped = false
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Text = if hasHeadline then headline :: string else title
	titleLabel.Parent = plate

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(12, 6, 0)
	titleStroke.Thickness = 3.2
	titleStroke.Transparency = 0.05
	titleStroke.LineJoinMode = Enum.LineJoinMode.Round
	titleStroke.Parent = titleLabel

	local titleGrad = Instance.new("UIGradient")
	titleGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248, 210)),
		ColorSequenceKeypoint.new(0.45, gold),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 168, 40)),
	})
	titleGrad.Rotation = 90
	titleGrad.Parent = titleLabel

	if hasSub then
		local chip = Instance.new("Frame")
		chip.Name = "SubChip"
		chip.LayoutOrder = 3
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.Size = UDim2.fromOffset(0, 26)
		chip.BackgroundColor3 = Color3.fromRGB(8, 22, 14)
		chip.BackgroundTransparency = 0.12
		chip.BorderSizePixel = 0
		chip.Parent = plate

		local chipCorner = Instance.new("UICorner")
		chipCorner.CornerRadius = UDim.new(1, 0)
		chipCorner.Parent = chip

		local chipStroke = Instance.new("UIStroke")
		chipStroke.Color = Color3.fromRGB(120, 255, 170)
		chipStroke.Thickness = 1.2
		chipStroke.Transparency = 0.35
		chipStroke.Parent = chip

		local chipPad = Instance.new("UIPadding")
		chipPad.PaddingLeft = UDim.new(0, 12)
		chipPad.PaddingRight = UDim.new(0, 12)
		chipPad.Parent = chip

		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.BackgroundTransparency = 1
		sub.AnchorPoint = Vector2.new(0.5, 0.5)
		sub.Position = UDim2.fromScale(0.5, 0.5)
		sub.Size = UDim2.fromScale(1, 1)
		sub.AutomaticSize = Enum.AutomaticSize.X
		sub.Font = UiFonts.DISPLAY_LEGACY
		UiFonts.applyDisplay(sub)
		sub.TextSize = 13
		sub.TextColor3 = Color3.fromRGB(190, 255, 210)
		sub.TextStrokeColor3 = Color3.fromRGB(6, 16, 10)
		sub.TextStrokeTransparency = 0.4
		sub.TextXAlignment = Enum.TextXAlignment.Center
		sub.TextYAlignment = Enum.TextYAlignment.Center
		sub.Text = subtitle :: string
		sub.Parent = chip
	end

	bb.Parent = char

	activeBillboard = bb
	activeLabel = titleLabel

	TweenService:Create(canvas, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		GroupTransparency = 0,
	}):Play()
	TweenService:Create(scale, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.08,
	}):Play()
	task.delay(0.38, function()
		if scale.Parent then
			TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end)

	local startOffset = offset
	local endOffset = offset + Vector3.new(0, 0.85, 0)
	local floatStart = os.clock()
	local floatDur = math.max(0.9, lifetimeSec - 0.25)
	local token = dismissToken
	followConn = RunService.RenderStepped:Connect(function()
		if token ~= dismissToken or not bb.Parent then
			stopFollow()
			return
		end
		local liveChar = player.Character
		local liveAdornee = resolveAdornee(liveChar)
		if liveAdornee and liveAdornee ~= bb.Adornee then
			bb.Adornee = liveAdornee
			if bb.Parent ~= liveChar and liveChar then
				bb.Parent = liveChar
			end
		end
		local t = math.clamp((os.clock() - floatStart) / floatDur, 0, 1)
		local ease = 1 - (1 - t) * (1 - t)
		bb.StudsOffset = startOffset:Lerp(endOffset, ease)
	end)

	if lifetimeSec > 0 then
		task.delay(lifetimeSec, function()
			if token ~= dismissToken then
				return
			end
			if activeBillboard == bb then
				CharacterWorldNotif.dismiss()
			end
		end)
	end
end

return CharacterWorldNotif
