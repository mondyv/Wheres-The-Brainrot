-- [ACTIVE] ServerResetHud
--[[
	Full-width HUD countdown when admins run resetservers.
	UI is created once and reused. Heartbeat is disconnected when the banner hides.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HUD_NAME = "ServerResetHud"
local REMOTE_NAME = "ServerResetCountdown"
local PULSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_BACK = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local KICKER_TEXT = "LIVE UPDATE"
local TITLE_TEXT = "ALL SERVERS RESETTING"
local SUB_IDLE = "New update incoming — your data is safe"
local SUB_NOW = "Saving your data — sending you to a fresh server"

local gui: ScreenGui? = nil
local root: Frame? = nil
local kickerLabel: TextLabel? = nil
local titleLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local subLabel: TextLabel? = nil
local fillBar: Frame? = nil
local timerScale: UIScale? = nil
local goldGlow: UIGradient? = nil
local bannerHeight = 136

local heartbeatConn: RBXScriptConnection? = nil
local pulseTween: Tween? = nil
local slideTween: Tween? = nil
local typewriterThread: thread? = nil
local typewriterToken = 0
local endsAt = 0
local totalSeconds = 30
local lastShownSec = -1
local typedNowCopy = false

local ServerResetHud = {}

local function stopTypewriter()
	if typewriterThread then
		task.cancel(typewriterThread)
		typewriterThread = nil
	end
end

local function typeGraphemes(label: TextLabel, text: string, delaySec: number, token: number)
	label.Text = text
	label.MaxVisibleGraphemes = 0
	local i = 0
	for first, last in utf8.graphemes(text) do
		if token ~= typewriterToken or not label.Parent then
			return
		end
		i += 1
		label.MaxVisibleGraphemes = i
		local g = string.sub(text, first, last)
		if g ~= " " and g ~= "\n" and g ~= "\t" then
			UIInteractionSounds.playTypewriterTick()
		end
		task.wait(delaySec)
	end
	if token == typewriterToken and label.Parent then
		label.MaxVisibleGraphemes = -1
	end
end

local function playIntroTypewriter()
	stopTypewriter()
	typewriterToken += 1
	local token = typewriterToken
	if kickerLabel then
		kickerLabel.MaxVisibleGraphemes = 0
		kickerLabel.Text = KICKER_TEXT
	end
	if titleLabel then
		titleLabel.MaxVisibleGraphemes = 0
		titleLabel.Text = TITLE_TEXT
	end
	if subLabel then
		subLabel.MaxVisibleGraphemes = 0
		subLabel.Text = SUB_IDLE
	end
	typewriterThread = task.spawn(function()
		task.wait(0.12)
		if kickerLabel then
			typeGraphemes(kickerLabel, KICKER_TEXT, 0.038, token)
		end
		if token ~= typewriterToken then
			return
		end
		task.wait(0.06)
		if titleLabel then
			typeGraphemes(titleLabel, TITLE_TEXT, 0.028, token)
		end
		if token ~= typewriterToken then
			return
		end
		task.wait(0.08)
		if subLabel then
			typeGraphemes(subLabel, SUB_IDLE, 0.018, token)
		end
	end)
end

local function playNowTypewriter()
	if typedNowCopy or not subLabel then
		return
	end
	typedNowCopy = true
	stopTypewriter()
	typewriterToken += 1
	local token = typewriterToken
	typewriterThread = task.spawn(function()
		typeGraphemes(subLabel, SUB_NOW, 0.02, token)
	end)
end

local function disconnectHeartbeat()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
end

local function formatHudTime(sec: number): string
	local remain = math.max(0, math.ceil(sec))
	local minutes = math.floor(remain / 60)
	local seconds = remain % 60
	return string.format("%d:%02d", minutes, seconds)
end

local function pulseTimer()
	if not timerScale then
		return
	end
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	timerScale.Scale = 1
	local up = TweenService:Create(timerScale, PULSE_INFO, { Scale = 1.16 })
	pulseTween = up
	up:Play()
	up.Completed:Once(function()
		if timerScale and endsAt > 0 then
			pulseTween = TweenService:Create(timerScale, PULSE_BACK, { Scale = 1 })
			pulseTween:Play()
		end
	end)
end

local function hideHud()
	disconnectHeartbeat()
	stopTypewriter()
	typewriterToken += 1
	endsAt = 0
	lastShownSec = -1
	typedNowCopy = false
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	if slideTween then
		slideTween:Cancel()
		slideTween = nil
	end
	if timerScale then
		timerScale.Scale = 1
	end
	if kickerLabel then
		kickerLabel.MaxVisibleGraphemes = -1
	end
	if titleLabel then
		titleLabel.MaxVisibleGraphemes = -1
	end
	if subLabel then
		subLabel.MaxVisibleGraphemes = -1
	end
	if root then
		root.Visible = false
		root.Position = UDim2.new(0.5, 0, 0, -bannerHeight)
	end
end

local function applyUrgentStyle(urgent: boolean)
	if timerLabel then
		timerLabel.TextColor3 = if urgent then Color3.fromRGB(255, 92, 92) else Color3.fromRGB(255, 230, 140)
	end
	if titleLabel then
		titleLabel.TextColor3 = if urgent then Color3.fromRGB(255, 210, 210) else Color3.fromRGB(255, 246, 230)
	end
	if fillBar then
		fillBar.BackgroundColor3 = if urgent then Color3.fromRGB(255, 78, 78) else Color3.fromRGB(255, 196, 72)
	end
end

local function refreshHud()
	if not root or not timerLabel or not fillBar or not subLabel then
		return
	end
	if goldGlow then
		goldGlow.Offset = Vector2.new(math.sin(os.clock() * 1.8) * 0.42, 0)
	end
	local remaining = endsAt - Workspace:GetServerTimeNow()
	if remaining <= 0 then
		timerLabel.Text = "NOW"
		fillBar.Size = UDim2.new(0, 0, 1, 0)
		applyUrgentStyle(true)
		playNowTypewriter()
		disconnectHeartbeat()
		return
	end

	local shown = math.max(0, math.ceil(remaining))
	timerLabel.Text = formatHudTime(remaining)
	local span = math.max(1, totalSeconds)
	fillBar.Size = UDim2.new(math.clamp(remaining / span, 0, 1), 0, 1, 0)
	applyUrgentStyle(shown <= 5)
	if shown ~= lastShownSec then
		lastShownSec = shown
		pulseTimer()
	end
end

local function showHud(newEndsAt: number, barTotal: number)
	if typeof(newEndsAt) ~= "number" or newEndsAt <= Workspace:GetServerTimeNow() then
		return
	end
	local wasVisible = root ~= nil and root.Visible
	endsAt = newEndsAt
	totalSeconds = if typeof(barTotal) == "number" and barTotal > 0 then barTotal else 30
	lastShownSec = -1
	typedNowCopy = false
	if root then
		root.Visible = true
		if not wasVisible then
			if slideTween then
				slideTween:Cancel()
			end
			root.Position = UDim2.new(0.5, 0, 0, -bannerHeight)
			slideTween = TweenService:Create(root, SLIDE_IN, {
				Position = UDim2.new(0.5, 0, 0, 0),
			})
			slideTween:Play()
			playIntroTypewriter()
		end
	end
	refreshHud()
	if not heartbeatConn then
		heartbeatConn = RunService.Heartbeat:Connect(refreshHud)
	end
end

local function buildHud()
	local compact = UserInputService.TouchEnabled
	bannerHeight = if compact then 118 else 136
	local bannerH = bannerHeight

	local screen = Instance.new("ScreenGui")
	screen.Name = HUD_NAME
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 420
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = true

	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, -bannerH)
	banner.Size = UDim2.new(1, 0, 0, bannerH)
	banner.BackgroundColor3 = Color3.fromRGB(18, 8, 10)
	banner.BackgroundTransparency = 0.08
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.ZIndex = 10
	banner.Parent = screen

	local fade = Instance.new("UIGradient")
	fade.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(72, 10, 16)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(22, 8, 12)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(72, 10, 16)),
	})
	fade.Parent = banner

	local goldLine = Instance.new("Frame")
	goldLine.Name = "GoldLine"
	goldLine.AnchorPoint = Vector2.new(0.5, 0)
	goldLine.Position = UDim2.new(0.5, 0, 0, 0)
	goldLine.Size = UDim2.new(1, 0, 0, 3)
	goldLine.BackgroundColor3 = Color3.fromRGB(255, 196, 72)
	goldLine.BorderSizePixel = 0
	goldLine.ZIndex = 12
	goldLine.Parent = banner

	local glow = Instance.new("UIGradient")
	glow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	glow.Parent = goldLine

	local kicker = Instance.new("TextLabel")
	kicker.Name = "Kicker"
	kicker.BackgroundTransparency = 1
	kicker.AnchorPoint = Vector2.new(0.5, 0)
	kicker.Position = UDim2.new(0.5, 0, 0, if compact then 10 else 12)
	kicker.Size = UDim2.new(0.92, 0, 0, if compact then 14 else 16)
	kicker.Text = KICKER_TEXT
	kicker.TextXAlignment = Enum.TextXAlignment.Center
	kicker.TextColor3 = Color3.fromRGB(255, 196, 72)
	kicker.TextTransparency = 0.05
	kicker.TextScaled = true
	kicker.ZIndex = 13
	kicker.Parent = banner
	UiFonts.applyDisplayLabel(kicker, if compact then 12 else 14, 10)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, if compact then 26 else 30)
	title.Size = UDim2.new(0.94, 0, 0, if compact then 22 else 26)
	title.Text = TITLE_TEXT
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextColor3 = Color3.fromRGB(255, 246, 230)
	title.TextScaled = true
	title.ZIndex = 13
	title.Parent = banner
	UiFonts.applyDisplayLabel(title, if compact then 20 else 24, 14)

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 1.4
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Transparency = 0.25
	titleStroke.Parent = title

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.BackgroundTransparency = 1
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0, if compact then 50 else 58)
	timer.Size = UDim2.new(0.5, 0, 0, if compact then 34 else 42)
	timer.Text = "0:30"
	timer.TextXAlignment = Enum.TextXAlignment.Center
	timer.TextColor3 = Color3.fromRGB(255, 230, 140)
	timer.TextScaled = true
	timer.ZIndex = 14
	timer.Parent = banner
	UiFonts.applyDisplayLabel(timer, if compact then 32 else 40, 20)

	local timerStroke = Instance.new("UIStroke")
	timerStroke.Thickness = 2
	timerStroke.Color = Color3.fromRGB(70, 20, 8)
	timerStroke.Transparency = 0.15
	timerStroke.Parent = timer

	local scale = Instance.new("UIScale")
	scale.Name = "TimerPulse"
	scale.Scale = 1
	scale.Parent = timer

	local sub = Instance.new("TextLabel")
	sub.Name = "Subtitle"
	sub.BackgroundTransparency = 1
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.new(0.5, 0, 0, if compact then 86 else 100)
	sub.Size = UDim2.new(0.92, 0, 0, if compact then 16 else 18)
	sub.Text = SUB_IDLE
	sub.TextXAlignment = Enum.TextXAlignment.Center
	sub.TextColor3 = Color3.fromRGB(230, 210, 190)
	sub.TextTransparency = 0.08
	sub.TextScaled = true
	sub.ZIndex = 13
	sub.Parent = banner
	UiFonts.applyDisplayLabel(sub, if compact then 13 else 15, 10)

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -6)
	track.Size = UDim2.new(0.72, 0, 0, 5)
	track.BackgroundColor3 = Color3.fromRGB(40, 16, 18)
	track.BorderSizePixel = 0
	track.ZIndex = 12
	track.Parent = banner

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(255, 196, 72)
	fill.BorderSizePixel = 0
	fill.ZIndex = 13
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	screen.Parent = playerGui

	gui = screen
	root = banner
	kickerLabel = kicker
	titleLabel = title
	timerLabel = timer
	subLabel = sub
	fillBar = fill
	timerScale = scale
	goldGlow = glow
end

local function bindRemote()
	local folder = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 30)
	if not folder then
		warn("[ServerResetHud] Remotes folder missing")
		return
	end
	local ev = folder:FindFirstChild(REMOTE_NAME) or folder:WaitForChild(REMOTE_NAME, 30)
	if not ev or not ev:IsA("RemoteEvent") then
		warn("[ServerResetHud] ServerResetCountdown remote missing")
		return
	end
	ev.OnClientEvent:Connect(function(clientEndsAt: any, barTotal: any)
		if typeof(clientEndsAt) ~= "number" then
			return
		end
		showHud(clientEndsAt, if typeof(barTotal) == "number" then barTotal else 30)
	end)
end

function ServerResetHud.init()
	if gui then
		return
	end
	buildHud()
	bindRemote()
	player.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			hideHud()
		end
	end)
end

return ServerResetHud
