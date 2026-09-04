-- [ACTIVE] EventBillboardController
--[[
	Map.EventBillboard: world countdown, nearby Highlight, custom proximity prompt.
	Prompt opens Roblox's in-experience event RSVP / join UI (SocialService).
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventBillboardConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EventBillboardConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local PROMPT_NAME = "EventJoinPrompt"
local HIGHLIGHT_NAME = "EventBillboardHighlight"
local TIMER_GUI_NAME = "EventCountdownGui"
local LIVE_GOLD = Color3.fromRGB(255, 214, 74)
local LIVE_GREEN = Color3.fromRGB(90, 230, 160)
local ENDED_GRAY = Color3.fromRGB(168, 178, 192)

local EventBillboardController = {}

local boundRoot: Instance? = nil
local prompt: ProximityPrompt? = nil
local highlight: Highlight? = nil
local timerGui: BillboardGui? = nil
local titleLabel: TextLabel? = nil
local timeLabel: TextLabel? = nil
local promptConn: RBXScriptConnection? = nil
local shownConn: RBXScriptConnection? = nil
local hiddenConn: RBXScriptConnection? = nil
local ancestryConn: RBXScriptConnection? = nil
local swayConn: RBXScriptConnection? = nil
local restCf: CFrame? = nil
local timerToken = 0
local prompting = false
local studioHintShown = false

local function resolveHostPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	local guiPart = root:FindFirstChild("GUIPart")
	if guiPart and guiPart:IsA("BasePart") then
		return guiPart
	end
	if root:IsA("Model") then
		return root.PrimaryPart or root:FindFirstChildWhichIsA("BasePart", true)
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function restCFrame(): CFrame
	local ori = EventBillboardConfig.REST_ORIENTATION_DEG
	return CFrame.new(EventBillboardConfig.REST_POSITION)
		* CFrame.fromOrientation(math.rad(ori.X), math.rad(ori.Y), math.rad(ori.Z))
end

local function setOutlineVisible(on: boolean)
	if highlight and highlight.Parent then
		highlight.Enabled = on
	end
end

local function formatRemain(sec: number): string
	local n = math.max(0, math.floor(sec + 0.5))
	local d = math.floor(n / 86400)
	local h = math.floor((n % 86400) / 3600)
	local m = math.floor((n % 3600) / 60)
	local s = n % 60
	if d > 0 then
		return string.format("%dd %02dh %02dm", d, h, m)
	end
	if h > 0 then
		return string.format("%dh %02dm %02ds", h, m, s)
	end
	return string.format("%02dm %02ds", m, s)
end

local function eventPhase(): ("upcoming" | "live" | "ended", number)
	local now = Workspace:GetServerTimeNow()
	if now < EventBillboardConfig.START_UNIX then
		return "upcoming", EventBillboardConfig.START_UNIX - now
	end
	if now < EventBillboardConfig.END_UNIX then
		return "live", EventBillboardConfig.END_UNIX - now
	end
	return "ended", 0
end

local function paintTimer()
	local title = titleLabel
	local clock = timeLabel
	if not (title and clock) then
		return
	end
	local phase, remain = eventPhase()
	if phase == "upcoming" then
		title.Text = "STARTS IN"
		title.TextColor3 = LIVE_GOLD
		clock.Text = formatRemain(remain)
		clock.TextColor3 = Color3.fromRGB(255, 246, 220)
	elseif phase == "live" then
		title.Text = "LIVE — ENDS IN"
		title.TextColor3 = LIVE_GREEN
		clock.Text = formatRemain(remain)
		clock.TextColor3 = LIVE_GREEN
	else
		title.Text = "EVENT ENDED"
		title.TextColor3 = ENDED_GRAY
		clock.Text = "Thanks for coming"
		clock.TextColor3 = ENDED_GRAY
	end
	if prompt and prompt.Parent then
		prompt.Enabled = phase ~= "ended"
	end
end

local function destroyBound()
	timerToken += 1
	if promptConn then
		promptConn:Disconnect()
		promptConn = nil
	end
	if shownConn then
		shownConn:Disconnect()
		shownConn = nil
	end
	if hiddenConn then
		hiddenConn:Disconnect()
		hiddenConn = nil
	end
	if ancestryConn then
		ancestryConn:Disconnect()
		ancestryConn = nil
	end
	if swayConn then
		swayConn:Disconnect()
		swayConn = nil
	end
	if boundRoot and boundRoot:IsA("Model") and restCf then
		(boundRoot :: Model):PivotTo(restCf)
	end
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if prompt then
		prompt:Destroy()
		prompt = nil
	end
	if timerGui then
		timerGui:Destroy()
		timerGui = nil
	end
	titleLabel = nil
	timeLabel = nil
	restCf = nil
	boundRoot = nil
end

local function ensureTimerGui(host: BasePart)
	local existing = host:FindFirstChild(TIMER_GUI_NAME)
	if existing then
		existing:Destroy()
	end

	-- Hang the countdown under the panel so it never covers the poster art.
	local below = host.Size.Y * 0.5 + 2.35
	if boundRoot and boundRoot:IsA("Model") then
		local _, size = (boundRoot :: Model):GetBoundingBox()
		below = size.Y * 0.5 + 2.2
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = TIMER_GUI_NAME
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 110
	bb.Size = UDim2.fromScale(8.6, 2.7)
	bb.StudsOffset = Vector3.new(0, -below, 0)
	bb.Adornee = host
	bb.ResetOnSpawn = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
	root.BackgroundTransparency = 0.18
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.16, 0)
	corner.Parent = root
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 214, 74)
	stroke.Thickness = 1.6
	stroke.Transparency = 0.18
	stroke.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.Parent = root
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0.02, 0)
	list.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.28, 0)
	title.Text = "STARTS IN"
	title.TextColor3 = LIVE_GOLD
	title.TextScaled = true
	title.ZIndex = 2
	title.Parent = root
	UiFonts.applyDisplay(title)

	local clock = Instance.new("TextLabel")
	clock.Name = "Time"
	clock.BackgroundTransparency = 1
	clock.Size = UDim2.new(1, 0, 0.42, 0)
	clock.Text = "—"
	clock.TextColor3 = Color3.fromRGB(255, 246, 220)
	clock.TextScaled = true
	clock.ZIndex = 2
	clock.Parent = root
	UiFonts.applyDisplay(clock)

	local sub = Instance.new("TextLabel")
	sub.Name = "Window"
	sub.BackgroundTransparency = 1
	sub.Size = UDim2.new(1, 0, 0.24, 0)
	sub.Text = EventBillboardConfig.WINDOW_LABEL
	sub.TextColor3 = Color3.fromRGB(200, 208, 220)
	sub.TextScaled = true
	sub.ZIndex = 2
	sub.Parent = root
	UiFonts.applyDisplay(sub)

	bb.Parent = host
	timerGui = bb
	titleLabel = title
	timeLabel = clock
	paintTimer()
end

local function startFloatSway(root: Instance)
	if swayConn then
		swayConn:Disconnect()
		swayConn = nil
	end
	if not root:IsA("Model") then
		return
	end
	local model = root :: Model
	local base = restCFrame()
	restCf = base
	model:PivotTo(base)

	swayConn = RunService.Heartbeat:Connect(function()
		if not model.Parent or restCf ~= base then
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			if (hrp.Position - base.Position).Magnitude > EventBillboardConfig.SWAY_MAX_DISTANCE then
				model:PivotTo(base)
				return
			end
		end
		local t = os.clock()
		local bob = math.sin(t * EventBillboardConfig.FLOAT_BOB_SPEED) * EventBillboardConfig.FLOAT_BOB_STUDS
		local drift = math.sin(t * EventBillboardConfig.FLOAT_DRIFT_SPEED + 0.7)
			* EventBillboardConfig.FLOAT_DRIFT_STUDS
		local yaw = math.rad(EventBillboardConfig.FLOAT_YAW_DEG)
			* math.sin(t * EventBillboardConfig.FLOAT_YAW_SPEED)
		local roll = math.rad(EventBillboardConfig.FLOAT_ROLL_DEG)
			* math.sin(t * EventBillboardConfig.FLOAT_ROLL_SPEED + 1.1)
		model:PivotTo(base * CFrame.new(drift, bob, 0) * CFrame.Angles(roll, yaw, 0))
	end)
end

local function startTimerLoop()
	timerToken += 1
	local token = timerToken
	task.spawn(function()
		while token == timerToken do
			paintTimer()
			task.wait(0.25)
		end
	end)
end

local function openEventJoin()
	if prompting then
		return
	end
	local phase = eventPhase()
	if phase == "ended" then
		TopNotifController.showPersonal("This event has ended.", "legendary", 2.8)
		return
	end
	prompting = true
	task.spawn(function()
		if RunService:IsStudio() and not studioHintShown then
			studioHintShown = true
			TopNotifController.showPersonal("Event join opens in the published game (not Studio).", "legendary", 3.2)
		end
		local ok, result = pcall(function()
			return SocialService:PromptRsvpToEventAsync(EventBillboardConfig.EVENT_ID)
		end)
		if not ok then
			warn("[EventBillboardController] PromptRsvpToEventAsync:", result)
			if phase == "live" then
				TopNotifController.showPersonal("The event is live — you're already in the game!", "legendary", 3.2)
			else
				TopNotifController.showPersonal("Couldn't open the event page. Try again in a moment.", "legendary", 3.2)
			end
		end
		prompting = false
	end)
end

local function bindBillboard(root: Instance)
	if boundRoot == root and prompt and prompt.Parent then
		return
	end
	destroyBound()
	boundRoot = root

	local host = resolveHostPart(root)
	if not host then
		warn("[EventBillboardController] EventBillboard has no BasePart")
		boundRoot = nil
		return
	end

	local existing = host:FindFirstChild(PROMPT_NAME)
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		local pp = Instance.new("ProximityPrompt")
		pp.Name = PROMPT_NAME
		pp.ActionText = EventBillboardConfig.PROMPT_ACTION
		pp.ObjectText = EventBillboardConfig.PROMPT_OBJECT
		pp.HoldDuration = 0
		pp.MaxActivationDistance = EventBillboardConfig.MAX_DISTANCE
		pp.RequiresLineOfSight = false
		pp.KeyboardKeyCode = Enum.KeyCode.E
		pp.GamepadKeyCode = Enum.KeyCode.ButtonX
		pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		pp.Style = Enum.ProximityPromptStyle.Custom
		pp:SetAttribute("CustomPromptFX", true)
		pp.Parent = host
		prompt = pp
	end

	local pp = prompt :: ProximityPrompt
	pp.ActionText = EventBillboardConfig.PROMPT_ACTION
	pp.ObjectText = EventBillboardConfig.PROMPT_OBJECT
	pp.HoldDuration = 0
	pp.MaxActivationDistance = EventBillboardConfig.MAX_DISTANCE
	pp.RequiresLineOfSight = false
	pp.Style = Enum.ProximityPromptStyle.Custom
	pp:SetAttribute("CustomPromptFX", true)
	pp.Enabled = true

	local hl = Instance.new("Highlight")
	hl.Name = HIGHLIGHT_NAME
	hl.FillTransparency = 1
	hl.OutlineColor = LIVE_GOLD
	hl.OutlineTransparency = 0.05
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	if root:IsA("Model") or root:IsA("BasePart") then
		hl.Adornee = root
	else
		hl.Adornee = host
	end
	hl.Parent = root
	highlight = hl

	ensureTimerGui(host)
	startTimerLoop()
	startFloatSway(root)

	pcall(function()
		ProximityPromptEffects.stylePrompt(pp)
	end)

	promptConn = pp.Triggered:Connect(function(who)
		if who ~= player then
			return
		end
		openEventJoin()
	end)
	shownConn = pp.PromptShown:Connect(function()
		setOutlineVisible(true)
	end)
	hiddenConn = pp.PromptHidden:Connect(function()
		setOutlineVisible(false)
	end)
	ancestryConn = root.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBound()
		end
	end)
end

function EventBillboardController.init()
	task.spawn(function()
		local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 120)
		if not map then
			warn("[EventBillboardController] Map missing")
			return
		end
		local board = map:FindFirstChild(EventBillboardConfig.MODEL_NAME)
			or map:WaitForChild(EventBillboardConfig.MODEL_NAME, 60)
		if board then
			bindBillboard(board)
		else
			warn("[EventBillboardController] EventBillboard missing")
		end
	end)

	local map = Workspace:FindFirstChild("Map")
	if map then
		map.ChildAdded:Connect(function(child)
			if child.Name == EventBillboardConfig.MODEL_NAME then
				bindBillboard(child)
			end
		end)
	else
		Workspace.ChildAdded:Connect(function(child)
			if child.Name ~= "Map" then
				return
			end
			child.ChildAdded:Connect(function(desc)
				if desc.Name == EventBillboardConfig.MODEL_NAME then
					bindBillboard(desc)
				end
			end)
			local board = child:FindFirstChild(EventBillboardConfig.MODEL_NAME)
			if board then
				bindBillboard(board)
			end
		end)
	end

	ProximityPromptService.PromptShown:Connect(function(shownPrompt)
		if shownPrompt == prompt then
			setOutlineVisible(true)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(hiddenPrompt)
		if hiddenPrompt == prompt then
			setOutlineVisible(false)
		end
	end)
end

return EventBillboardController
