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

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HUD_NAME = "ServerResetHud"
local REMOTE_NAME = "ServerResetCountdown"
local PULSE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_BACK = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local gui: ScreenGui? = nil
local root: Frame? = nil
local titleLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local subLabel: TextLabel? = nil
local fillBar: Frame? = nil
local timerScale: UIScale? = nil

local heartbeatConn: RBXScriptConnection? = nil
local pulseTween: Tween? = nil
local endsAt = 0
local totalSeconds = 30
local lastShownSec = -1

local ServerResetHud = {}

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
	endsAt = 0
	lastShownSec = -1
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	if timerScale then
		timerScale.Scale = 1
	end
	if root then
		root.Visible = false
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
	local remaining = endsAt - Workspace:GetServerTimeNow()
	if remaining <= 0 then
		timerLabel.Text = "NOW"
		subLabel.Text = "Saving your data — sending you to a fresh server"
		fillBar.Size = UDim2.new(0, 0, 1, 0)
		applyUrgentStyle(true)
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
	endsAt = newEndsAt
	totalSeconds = if typeof(barTotal) == "number" and barTotal > 0 then barTotal else 30
	lastShownSec = -1
	if root then
		root.Visible = true
	end
	if subLabel then
		subLabel.Text = "New update incoming — your data is safe"
	end
	refreshHud()
	if not heartbeatConn then
		heartbeatConn = RunService.Heartbeat:Connect(refreshHud)
	end
end

local function buildHud()
	local compact = UserInputService.TouchEnabled
	local bannerH = if compact then 118 else 136

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
	banner.Position = UDim2.new(0.5, 0, 0, 0)
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

	local goldGlow = Instance.new("UIGradient")
	goldGlow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	goldGlow.Parent = goldLine

	local kicker = Instance.new("TextLabel")
	kicker.Name = "Kicker"
	kicker.BackgroundTransparency = 1
	kicker.AnchorPoint = Vector2.new(0.5, 0)
	kicker.Position = UDim2.new(0.5, 0, 0, if compact then 10 else 12)
	kicker.Size = UDim2.new(0.92, 0, 0, if compact then 14 else 16)
	kicker.Text = "LIVE UPDATE"
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
	title.Text = "ALL SERVERS RESETTING"
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
	sub.Text = "Moving you to the latest published update — your data is safe"
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
	titleLabel = title
	timerLabel = timer
	subLabel = sub
	fillBar = fill
	timerScale = scale
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
