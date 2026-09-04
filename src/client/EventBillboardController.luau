-- [ACTIVE] EventBillboardController
--[[
	Map.EventBillboard: world countdown, nearby Highlight, custom proximity prompt.
	Prompt opens Roblox's in-experience event RSVP / join UI (SocialService).
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalizationService = game:GetService("LocalizationService")

local EventBillboardConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("EventBillboardConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local PROMPT_NAME = "EventJoinPrompt"
local HIGHLIGHT_NAME = "EventBillboardHighlight"
local TIMER_GUI_NAME = "EventCountdownGui"
local SHINE_GUI_NAME = "EventBillboardShineGui"
-- Match the studded maroon frame on Map.EventBillboard.
local FRAME = Color3.fromRGB(68, 26, 42)
local FRAME_EDGE = Color3.fromRGB(32, 10, 20)
local FRAME_GLOW = Color3.fromRGB(214, 132, 156)
local STUD = Color3.fromRGB(108, 46, 66)
local SCREEN = Color3.fromRGB(14, 8, 12)
local INK = Color3.fromRGB(255, 250, 246)
local DUST = Color3.fromRGB(214, 176, 186)
local LIVE_ROSE = Color3.fromRGB(255, 108, 128)
local ENDED_GRAY = Color3.fromRGB(168, 150, 158)

local EventBillboardController = {}

local boundRoot: Instance? = nil
local prompt: ProximityPrompt? = nil
local highlight: Highlight? = nil
local timerGui: BillboardGui? = nil
local titleLabel: TextLabel? = nil
local windowLabel: TextLabel? = nil
local endedLabel: TextLabel? = nil
local chipRow: Frame? = nil
local livePip: Frame? = nil
local chipNums: { TextLabel } = {}
local chipUnits: { TextLabel } = {}
local promptConn: RBXScriptConnection? = nil
local shownConn: RBXScriptConnection? = nil
local hiddenConn: RBXScriptConnection? = nil
local ancestryConn: RBXScriptConnection? = nil
local swayConn: RBXScriptConnection? = nil
local restCf: CFrame? = nil
local shineGui: SurfaceGui? = nil
local shineGrad: UIGradient? = nil
local shineTween: Tween? = nil
local shineToken = 0
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

local function remainParts(sec: number): ({ string }, { string })
	local n = math.max(0, math.floor(sec + 0.5))
	local d = math.floor(n / 86400)
	local h = math.floor((n % 86400) / 3600)
	local m = math.floor((n % 3600) / 60)
	local s = n % 60
	if d > 0 then
		return { tostring(d), string.format("%02d", h), string.format("%02d", m) }, { "DAYS", "HRS", "MIN" }
	end
	return { string.format("%02d", h), string.format("%02d", m), string.format("%02d", s) }, { "HRS", "MIN", "SEC" }
end

local function localWindowLabel(): string
	local locale = LocalizationService.RobloxLocaleId
	if typeof(locale) ~= "string" or locale == "" then
		locale = "en-us"
	end
	local ok, text = pcall(function()
		local startDt = DateTime.fromUnixTimestamp(EventBillboardConfig.START_UNIX)
		local endDt = DateTime.fromUnixTimestamp(EventBillboardConfig.END_UNIX)
		local day = startDt:FormatLocalTime("ddd, MMM D", locale)
		local startClock = startDt:FormatLocalTime("LT", locale)
		local endClock = endDt:FormatLocalTime("LT", locale)
		return string.format("%s · %s – %s", day, startClock, endClock)
	end)
	if ok and typeof(text) == "string" and text ~= "" then
		return text
	end
	if not ok then
		warn("[EventBillboardController] local window label:", text)
	end
	return EventBillboardConfig.WINDOW_LABEL
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
	if not title or #chipNums < 3 then
		return
	end
	local phase, remain = eventPhase()
	local showChips = phase ~= "ended"
	if chipRow then
		chipRow.Visible = showChips
	end
	if endedLabel then
		endedLabel.Visible = not showChips
	end
	if windowLabel then
		windowLabel.TextColor3 = if phase == "ended" then ENDED_GRAY else DUST
	end
	if livePip then
		livePip.Visible = phase == "live"
	end
	if phase == "upcoming" then
		title.Text = "STARTS IN"
		title.TextColor3 = DUST
	elseif phase == "live" then
		title.Text = "LIVE  ·  ENDS IN"
		title.TextColor3 = LIVE_ROSE
	else
		title.Text = "EVENT ENDED"
		title.TextColor3 = ENDED_GRAY
	end
	if showChips then
		local nums, units = remainParts(remain)
		for i = 1, 3 do
			chipNums[i].Text = nums[i]
			chipNums[i].TextColor3 = if phase == "live" then LIVE_ROSE else INK
			chipUnits[i].Text = units[i]
			chipUnits[i].TextColor3 = DUST
		end
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
	shineToken += 1
	if shineTween then
		shineTween:Cancel()
		shineTween = nil
	end
	if shineGui then
		shineGui:Destroy()
		shineGui = nil
	end
	shineGrad = nil
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
	windowLabel = nil
	endedLabel = nil
	chipRow = nil
	livePip = nil
	table.clear(chipNums)
	table.clear(chipUnits)
	restCf = nil
	boundRoot = nil
end

local function addCorner(gui: GuiObject, scale: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(scale, 0)
	corner.Parent = gui
end

local function addStud(parent: Frame, xScale: number, yScale: number)
	local stud = Instance.new("Frame")
	stud.Name = "Stud"
	stud.BackgroundColor3 = STUD
	stud.BorderSizePixel = 0
	stud.AnchorPoint = Vector2.new(0.5, 0.5)
	stud.Position = UDim2.fromScale(xScale, yScale)
	stud.Size = UDim2.fromScale(0.052, 0.15)
	stud.ZIndex = 6
	addCorner(stud, 0.32)
	stud.Parent = parent
end

local function makeChip(parent: Frame, order: number): (TextLabel, TextLabel)
	local chip = Instance.new("Frame")
	chip.Name = "Chip" .. order
	chip.BackgroundColor3 = FRAME_EDGE
	chip.BackgroundTransparency = 0.12
	chip.BorderSizePixel = 0
	chip.LayoutOrder = order
	chip.Size = UDim2.new(0.31, 0, 1, 0)
	chip.ZIndex = 3
	addCorner(chip, 0.14)
	local stroke = Instance.new("UIStroke")
	stroke.Color = STUD
	stroke.Thickness = 1.2
	stroke.Transparency = 0.28
	stroke.Parent = chip

	local num = Instance.new("TextLabel")
	num.Name = "Value"
	num.BackgroundTransparency = 1
	num.Position = UDim2.fromScale(0.04, 0.02)
	num.Size = UDim2.fromScale(0.92, 0.66)
	num.FontFace = UiFonts.DISPLAY_FACE
	num.Text = "—"
	num.TextColor3 = INK
	num.TextScaled = true
	num.TextStrokeColor3 = FRAME_EDGE
	num.TextStrokeTransparency = 0.35
	num.ZIndex = 4
	num.Parent = chip

	local unit = Instance.new("TextLabel")
	unit.Name = "Unit"
	unit.BackgroundTransparency = 1
	unit.Position = UDim2.fromScale(0.06, 0.66)
	unit.Size = UDim2.fromScale(0.88, 0.28)
	unit.FontFace = UiFonts.DISPLAY_FACE
	unit.Text = "—"
	unit.TextColor3 = DUST
	unit.TextScaled = true
	unit.ZIndex = 4
	unit.Parent = chip

	chip.Parent = parent
	return num, unit
end

local function ensureTimerGui(host: BasePart)
	local existing = host:FindFirstChild(TIMER_GUI_NAME)
	if existing then
		existing:Destroy()
	end

	-- Sit the plaque just above the banner; part-local offset lets it lean with the sway.
	if boundRoot and boundRoot:IsA("Model") then
		(boundRoot :: Model):PivotTo(restCFrame())
	end
	local guiHeight = 3.4
	local gap = 0.58
	local follow = 0.42
	local topWorldY = host.Position.Y + host.Size.Y * 0.5
	if boundRoot and boundRoot:IsA("Model") then
		local boxCf, boxSize = (boundRoot :: Model):GetBoundingBox()
		topWorldY = boxCf.Position.Y + boxSize.Y * 0.5
	end
	local offsetY = (topWorldY - host.Position.Y) + gap + guiHeight * 0.5
	local localUp = host.CFrame:VectorToObjectSpace(Vector3.yAxis)

	local bb = Instance.new("BillboardGui")
	bb.Name = TIMER_GUI_NAME
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 110
	bb.Size = UDim2.fromScale(10.4, guiHeight)
	bb.StudsOffset = localUp * (offsetY * follow)
	bb.StudsOffsetWorldSpace = Vector3.yAxis * (offsetY * (1 - follow))
	bb.Adornee = host
	bb.ResetOnSpawn = false

	local plaque = Instance.new("Frame")
	plaque.Name = "Plaque"
	plaque.BackgroundColor3 = FRAME
	plaque.BorderSizePixel = 0
	plaque.Size = UDim2.fromScale(1, 1)
	addCorner(plaque, 0.07)
	local plaqueStroke = Instance.new("UIStroke")
	plaqueStroke.Color = FRAME_EDGE
	plaqueStroke.Thickness = 2.4
	plaqueStroke.Transparency = 0.05
	plaqueStroke.Parent = plaque
	local plaqueGrad = Instance.new("UIGradient")
	plaqueGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(92, 38, 56)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(48, 16, 30)),
	})
	plaqueGrad.Rotation = 110
	plaqueGrad.Parent = plaque

	addStud(plaque, 0.07, 0.14)
	addStud(plaque, 0.93, 0.14)
	addStud(plaque, 0.07, 0.86)
	addStud(plaque, 0.93, 0.86)

	local screen = Instance.new("Frame")
	screen.Name = "Screen"
	screen.BackgroundColor3 = SCREEN
	screen.BorderSizePixel = 0
	screen.Position = UDim2.fromScale(0.055, 0.1)
	screen.Size = UDim2.fromScale(0.89, 0.8)
	screen.ZIndex = 2
	addCorner(screen, 0.08)
	local screenStroke = Instance.new("UIStroke")
	screenStroke.Color = Color3.fromRGB(186, 132, 148)
	screenStroke.Thickness = 1.15
	screenStroke.Transparency = 0.55
	screenStroke.Parent = screen
	local screenPad = Instance.new("UIPadding")
	screenPad.PaddingLeft = UDim.new(0.045, 0)
	screenPad.PaddingRight = UDim.new(0.045, 0)
	screenPad.PaddingTop = UDim.new(0.07, 0)
	screenPad.PaddingBottom = UDim.new(0.07, 0)
	screenPad.Parent = screen

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0.2, 0)
	header.ZIndex = 3
	header.Parent = screen

	local pip = Instance.new("Frame")
	pip.Name = "LivePip"
	pip.BackgroundColor3 = LIVE_ROSE
	pip.BorderSizePixel = 0
	pip.AnchorPoint = Vector2.new(0, 0.5)
	pip.Position = UDim2.new(0.02, 0, 0.5, 0)
	pip.Size = UDim2.fromScale(0.08, 0.55)
	pip.Visible = false
	pip.ZIndex = 5
	addCorner(pip, 1)
	local pipAspect = Instance.new("UIAspectRatioConstraint")
	pipAspect.AspectRatio = 1
	pipAspect.Parent = pip
	pip.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 1)
	title.FontFace = UiFonts.DISPLAY_FACE
	title.Text = "STARTS IN"
	title.TextColor3 = DUST
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 4
	title.Parent = header

	local chips = Instance.new("Frame")
	chips.Name = "Chips"
	chips.BackgroundTransparency = 1
	chips.Position = UDim2.fromScale(0, 0.22)
	chips.Size = UDim2.fromScale(1, 0.54)
	chips.ZIndex = 3
	chips.Parent = screen
	local chipList = Instance.new("UIListLayout")
	chipList.FillDirection = Enum.FillDirection.Horizontal
	chipList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	chipList.VerticalAlignment = Enum.VerticalAlignment.Center
	chipList.Padding = UDim.new(0.03, 0)
	chipList.Parent = chips

	table.clear(chipNums)
	table.clear(chipUnits)
	for i = 1, 3 do
		local num, unit = makeChip(chips, i)
		chipNums[i] = num
		chipUnits[i] = unit
	end

	local thanks = Instance.new("TextLabel")
	thanks.Name = "Ended"
	thanks.BackgroundTransparency = 1
	thanks.Position = UDim2.fromScale(0, 0.22)
	thanks.Size = UDim2.fromScale(1, 0.54)
	thanks.FontFace = UiFonts.DISPLAY_FACE
	thanks.Text = "Thanks for coming"
	thanks.TextColor3 = ENDED_GRAY
	thanks.TextScaled = true
	thanks.Visible = false
	thanks.ZIndex = 4
	thanks.Parent = screen

	local sub = Instance.new("TextLabel")
	sub.Name = "Window"
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromScale(0, 0.78)
	sub.Size = UDim2.fromScale(1, 0.2)
	sub.FontFace = UiFonts.DISPLAY_FACE
	sub.Text = localWindowLabel()
	sub.TextColor3 = DUST
	sub.TextScaled = true
	sub.ZIndex = 3
	sub.Parent = screen

	screen.Parent = plaque
	plaque.Parent = bb
	bb.Parent = host

	timerGui = bb
	titleLabel = title
	windowLabel = sub
	endedLabel = thanks
	chipRow = chips
	livePip = pip
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

local function resolvePosterFace(host: BasePart): Enum.NormalId
	local fallback: SurfaceGui? = nil
	for _, d in host:GetDescendants() do
		if d:IsA("SurfaceGui") and d.Name ~= SHINE_GUI_NAME then
			if d:FindFirstChildWhichIsA("ImageLabel", true) then
				return d.Face
			end
			fallback = d
		end
	end
	if fallback then
		return fallback.Face
	end
	for _, d in host:GetChildren() do
		if (d:IsA("Decal") or d:IsA("Texture")) and d.Transparency < 0.95 then
			return d.Face
		end
	end
	return Enum.NormalId.Front
end

local function playerNearHost(host: BasePart): boolean
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return true
	end
	return (hrp.Position - host.Position).Magnitude <= EventBillboardConfig.SHINE_MAX_DISTANCE
end

local function ensureShineOverlay(host: BasePart)
	local existing = host:FindFirstChild(SHINE_GUI_NAME)
	if existing then
		existing:Destroy()
	end

	local sheet = Instance.new("Frame")
	sheet.Name = "Sheen"
	sheet.BackgroundColor3 = Color3.fromRGB(255, 250, 240)
	sheet.BackgroundTransparency = 0
	sheet.BorderSizePixel = 0
	sheet.Size = UDim2.fromScale(1, 1)

	local grad = Instance.new("UIGradient")
	grad.Rotation = EventBillboardConfig.SHINE_ROTATION
	grad.Color = ColorSequence.new(Color3.fromRGB(255, 252, 245))
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.38, 1),
		NumberSequenceKeypoint.new(0.46, 0.88),
		NumberSequenceKeypoint.new(0.5, 0.58),
		NumberSequenceKeypoint.new(0.54, 0.88),
		NumberSequenceKeypoint.new(0.62, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Offset = Vector2.new(-1.2, 0)
	grad.Parent = sheet

	local sg = Instance.new("SurfaceGui")
	sg.Name = SHINE_GUI_NAME
	sg.Face = resolvePosterFace(host)
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0
	sg.AlwaysOnTop = false
	sg.MaxDistance = EventBillboardConfig.SHINE_MAX_DISTANCE
	sg.Active = false
	sg.ResetOnSpawn = false
	sg.ZOffset = 0.08
	sg.ClipsDescendants = true
	sheet.Parent = sg
	sg.Adornee = host
	sg.Parent = host

	shineGui = sg
	shineGrad = grad
end

local function startShineLoop(host: BasePart)
	shineToken += 1
	local token = shineToken
	local grad = shineGrad
	if not grad then
		return
	end
	local sweepInfo = TweenInfo.new(
		EventBillboardConfig.SHINE_DURATION,
		Enum.EasingStyle.Sine,
		Enum.EasingDirection.InOut
	)
	task.spawn(function()
		task.wait(1.1)
		while token == shineToken and grad.Parent do
			if not host.Parent then
				return
			end
			if playerNearHost(host) then
				grad.Offset = Vector2.new(-1.2, 0)
				local tw = TweenService:Create(grad, sweepInfo, { Offset = Vector2.new(1.2, 0) })
				shineTween = tw
				tw:Play()
				tw.Completed:Wait()
				if shineTween == tw then
					shineTween = nil
				end
			end
			if token ~= shineToken then
				return
			end
			task.wait(EventBillboardConfig.SHINE_PAUSE)
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
	hl.OutlineColor = FRAME_GLOW
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
	ensureShineOverlay(host)
	startShineLoop(host)

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
