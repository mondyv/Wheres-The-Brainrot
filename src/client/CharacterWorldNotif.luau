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
		TweenService:Create(label, FADE_OUT, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
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

-- Level-up / big reward: pop + rock + float beside the body (no top toast).
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

	local offset = if opts and opts.offset then opts.offset else Vector3.new(0, 3.1, 0)
	local textColor = if opts and opts.color then opts.color else Color3.fromRGB(255, 220, 90)
	local lifetimeSec = if opts and typeof(opts.lifetimeSec) == "number" then opts.lifetimeSec else 3.4
	local hideBadges = not (opts and opts.hideRankBadges == false)
	local subtitle = if opts and typeof(opts.subtitle) == "string" then opts.subtitle else nil

	baseText = title
	if hideBadges then
		setRankBadgeSuppress(true)
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "CharacterWorldNotifCelebrate"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 160
	bb.Size = UDim2.fromOffset(420, if subtitle and subtitle ~= "" then 72 else 48)
	bb.StudsOffset = offset
	bb.Adornee = adornee
	bb.Parent = char

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb

	local scale = Instance.new("UIScale")
	scale.Scale = 0.35
	scale.Parent = root

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.BackgroundTransparency = 1
	titleLabel.AnchorPoint = Vector2.new(0.5, 0)
	titleLabel.Position = UDim2.fromScale(0.5, 0)
	titleLabel.Size = UDim2.new(1, 0, 0, if subtitle and subtitle ~= "" then 34 else 48)
	titleLabel.Font = UiFonts.BODY_LEGACY
	UiFonts.applyBody(titleLabel)
	titleLabel.TextSize = 22
	titleLabel.TextColor3 = textColor
	titleLabel.TextStrokeColor3 = Color3.fromRGB(20, 10, 0)
	titleLabel.TextStrokeTransparency = 0.25
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.Text = title
	titleLabel.TextTransparency = 1
	titleLabel.Rotation = -12
	titleLabel.Parent = root

	local subLabel: TextLabel? = nil
	if subtitle and subtitle ~= "" then
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.BackgroundTransparency = 1
		sub.AnchorPoint = Vector2.new(0.5, 1)
		sub.Position = UDim2.fromScale(0.5, 1)
		sub.Size = UDim2.new(1, 0, 0, 32)
		sub.Font = UiFonts.BODY_LEGACY
		UiFonts.applyBody(sub)
		sub.TextSize = 15
		sub.TextColor3 = Color3.fromRGB(170, 255, 190)
		sub.TextStrokeColor3 = Color3.fromRGB(10, 18, 12)
		sub.TextStrokeTransparency = 0.3
		sub.TextXAlignment = Enum.TextXAlignment.Center
		sub.TextWrapped = true
		sub.Text = subtitle
		sub.TextTransparency = 1
		sub.Parent = root
		subLabel = sub
	end

	activeBillboard = bb
	activeLabel = titleLabel

	TweenService:Create(scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 }):Play()
	task.delay(0.32, function()
		if scale.Parent then
			TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end)

	TweenService:Create(titleLabel, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = 0.25,
		Rotation = 8,
	}):Play()
	task.delay(0.22, function()
		if titleLabel.Parent then
			TweenService:Create(titleLabel, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Rotation = -5,
			}):Play()
			task.delay(0.14, function()
				if titleLabel.Parent then
					TweenService:Create(titleLabel, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Rotation = 0,
					}):Play()
				end
			end)
		end
	end)
	if subLabel then
		TweenService:Create(subLabel, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			TextTransparency = 0,
			TextStrokeTransparency = 0.3,
		}):Play()
	end

	local startOffset = offset
	local endOffset = offset + Vector3.new(0, 1.15, 0)
	local floatStart = os.clock()
	local floatDur = math.max(0.8, lifetimeSec - 0.35)
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
