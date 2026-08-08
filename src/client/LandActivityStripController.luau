-- [ACTIVE] LandActivityStripController
--[[
	Outside the safe zone:
	• Hides SideUI.Right.RandomBrainrot
	• Shows a land activity strip (L1→L10) with every player's headshot on their land
	Inside safe zone: strip hides, RandomBrainrot returns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local LandActivityStripController = {}

local player = Players.LocalPlayer
local LAND_ATTR = "CurrentLand"
local MAX_LAND = 10
local POLL_SEC = 0.18
local SHOW_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local MOVE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local INSIDE_STREAK = 2
local OUTSIDE_STREAK = 2

local GLASS = Color3.fromRGB(28, 72, 48)
local GLASS_INNER = Color3.fromRGB(36, 96, 58)
local GLASS_STROKE = Color3.fromRGB(120, 220, 150)
local INK = Color3.fromRGB(220, 255, 230)
local INK_DARK = Color3.fromRGB(12, 32, 20)
local YOU_RING = Color3.fromRGB(255, 210, 90)
local YOU_GLOW = Color3.fromRGB(180, 255, 140)
local TRACK = Color3.fromRGB(16, 40, 26)

-- Soft green → lime heat across lands.
local LAND_COLORS: { Color3 } = {
	Color3.fromRGB(160, 230, 150),
	Color3.fromRGB(150, 220, 130),
	Color3.fromRGB(140, 210, 115),
	Color3.fromRGB(130, 200, 100),
	Color3.fromRGB(120, 190, 90),
	Color3.fromRGB(110, 180, 85),
	Color3.fromRGB(100, 170, 80),
	Color3.fromRGB(95, 160, 75),
	Color3.fromRGB(90, 150, 70),
	Color3.fromRGB(80, 140, 65),
}

type AvatarSlot = {
	player: Player,
	root: Frame,
	icon: ImageLabel,
	ring: UIStroke,
	nameTip: TextLabel?,
	land: number,
	stackIndex: number,
}

local randomBrainrotFrame: GuiObject? = nil
local stripGui: ScreenGui? = nil
local stripRoot: CanvasGroup? = nil
local stripScale: UIScale? = nil
local avatarsHost: Frame? = nil
local landTicks: { Frame } = {}
local landLabels: { TextLabel } = {}

local slotsByUserId: { [number]: AvatarSlot } = {}
local attrConns: { [Player]: RBXScriptConnection } = {}
local visibleTarget = false
local visibilityTween: Tween? = nil
local pollAccum = 0
local outsideStreak = 0
local insideStreak = 0
local heartbeatConn: RBXScriptConnection? = nil
local pulseToken = 0

local function headshotUrl(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

local function isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function getOrAddUIScale(parent: GuiObject): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = parent
	return s
end

local function landXScale(land: number): number
	-- Evenly space lands 1..10 across the track (pad edges).
	local t = (math.clamp(land, 1, MAX_LAND) - 1) / (MAX_LAND - 1)
	return 0.04 + t * 0.92
end

local function shouldShowStrip(): boolean
	if GameplayUiVisibility.isHidden() then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	if not SafezoneUtil.isCacheReady() then
		return false
	end
	return not SafezoneUtil.isCharacterInSafezone(character)
end

local function setRandomBrainrotVisible(show: boolean)
	if not randomBrainrotFrame then
		return
	end
	if randomBrainrotFrame.Visible ~= show then
		randomBrainrotFrame.Visible = show
	end
	-- Keep purchase button inactive while hidden so it can't steal taps.
	local activation = randomBrainrotFrame:FindFirstChild("Activation", true)
	if activation and activation:IsA("GuiButton") then
		activation.Active = show
		pcall(function()
			(activation :: any).Interactable = show
		end)
	end
end

local function cancelVisibilityTween()
	if visibilityTween then
		visibilityTween:Cancel()
		visibilityTween = nil
	end
end

local function applyVisibility(show: boolean, instant: boolean?)
	if not stripRoot or not stripScale then
		return
	end
	if visibleTarget == show and not instant then
		return
	end
	visibleTarget = show
	cancelVisibilityTween()

	if show then
		setRandomBrainrotVisible(false)
		stripRoot.Visible = true
		if instant then
			stripScale.Scale = 1
			stripRoot.GroupTransparency = 0
			return
		end
		stripScale.Scale = 0.82
		stripRoot.GroupTransparency = 1
		visibilityTween = TweenService:Create(stripScale, SHOW_TWEEN, { Scale = 1 })
		visibilityTween:Play()
		TweenService:Create(stripRoot, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
		}):Play()
	else
		setRandomBrainrotVisible(true)
		if instant then
			stripRoot.Visible = false
			stripScale.Scale = 0.82
			stripRoot.GroupTransparency = 1
			return
		end
		visibilityTween = TweenService:Create(stripScale, HIDE_TWEEN, { Scale = 0.82 })
		visibilityTween:Play()
		TweenService:Create(stripRoot, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			GroupTransparency = 1,
		}):Play()
		visibilityTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and not visibleTarget and stripRoot then
				stripRoot.Visible = false
			end
		end)
	end
end

local function refreshVisibility(instant: boolean?)
	local want = shouldShowStrip()
	if want then
		insideStreak = 0
		outsideStreak += 1
		if visibleTarget or outsideStreak >= OUTSIDE_STREAK or instant then
			applyVisibility(true, instant)
		end
	else
		outsideStreak = 0
		insideStreak += 1
		if (not visibleTarget) or insideStreak >= INSIDE_STREAK or instant or GameplayUiVisibility.isHidden() then
			applyVisibility(false, instant)
		end
	end
end

local function destroySlot(userId: number)
	local slot = slotsByUserId[userId]
	if not slot then
		return
	end
	slotsByUserId[userId] = nil
	if slot.root.Parent then
		slot.root:Destroy()
	end
end

local function ensureSlot(plr: Player): AvatarSlot?
	local existing = slotsByUserId[plr.UserId]
	if existing and existing.root.Parent then
		return existing
	end
	if not avatarsHost then
		return nil
	end

	local size = if isMobile() then 20 else 24
	local root = Instance.new("Frame")
	root.Name = "Avatar_" .. tostring(plr.UserId)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 50
	root.Active = true
	root.Parent = avatarsHost

	-- Opaque disc so heads read on glass.
	local pedestal = Instance.new("Frame")
	pedestal.Name = "Pedestal"
	pedestal.Size = UDim2.fromScale(1, 1)
	pedestal.BackgroundColor3 = Color3.fromRGB(18, 48, 30)
	pedestal.BackgroundTransparency = 0.1
	pedestal.BorderSizePixel = 0
	pedestal.ZIndex = 50
	pedestal.Parent = root
	local pedCorner = Instance.new("UICorner")
	pedCorner.CornerRadius = UDim.new(1, 0)
	pedCorner.Parent = pedestal
	local pedStroke = Instance.new("UIStroke")
	pedStroke.Color = GLASS_STROKE
	pedStroke.Thickness = 1.4
	pedStroke.Transparency = 0.25
	pedStroke.Parent = pedestal

	local icon = Instance.new("ImageLabel")
	icon.Name = "Head"
	icon.BackgroundColor3 = Color3.fromRGB(20, 40, 28)
	icon.BackgroundTransparency = 0
	icon.BorderSizePixel = 0
	icon.Size = UDim2.new(1, -3, 1, -3)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Image = headshotUrl(plr.UserId)
	icon.ScaleType = Enum.ScaleType.Crop
	icon.ZIndex = 51
	icon.Active = false
	icon.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = icon

	local ring = Instance.new("UIStroke")
	ring.Thickness = if plr == player then 2.4 else 1.5
	ring.Color = if plr == player then YOU_RING else GLASS_STROKE
	ring.Transparency = 0
	ring.Parent = icon

	if plr == player then
		local glow = Instance.new("UIStroke")
		glow.Name = "YouGlow"
		glow.Thickness = 4
		glow.Color = YOU_GLOW
		glow.Transparency = 0.5
		glow.Parent = pedestal
	end

	local tip = Instance.new("TextLabel")
	tip.Name = "NameTip"
	tip.BackgroundColor3 = INK_DARK
	tip.BackgroundTransparency = 0.15
	tip.Size = UDim2.new(0, 72, 0, 14)
	tip.Position = UDim2.new(0.5, 0, 0, -4)
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Text = plr.DisplayName
	tip.TextColor3 = INK
	tip.TextStrokeTransparency = 1
	tip.TextSize = 10
	tip.TextTruncate = Enum.TextTruncate.AtEnd
	tip.Visible = false
	tip.ZIndex = 60
	UiFonts.applyBody(tip)
	tip.Parent = root
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 4)
	tipCorner.Parent = tip
	local tipPad = Instance.new("UIPadding")
	tipPad.PaddingLeft = UDim.new(0, 4)
	tipPad.PaddingRight = UDim.new(0, 4)
	tipPad.Parent = tip

	root.MouseEnter:Connect(function()
		tip.Visible = true
	end)
	root.MouseLeave:Connect(function()
		tip.Visible = false
	end)

	local slot: AvatarSlot = {
		player = plr,
		root = root,
		icon = icon,
		ring = ring,
		nameTip = tip,
		land = 0,
		stackIndex = 0,
	}
	slotsByUserId[plr.UserId] = slot
	return slot
end

local function layoutStacks()
	-- Group by land, stack icons so they don't fully overlap.
	local byLand: { [number]: { AvatarSlot } } = {}
	for _, slot in slotsByUserId do
		if slot.land < 1 then
			continue
		end
		local list = byLand[slot.land]
		if not list then
			list = {}
			byLand[slot.land] = list
		end
		-- Local player first in stack.
		if slot.player == player then
			table.insert(list, 1, slot)
		else
			table.insert(list, slot)
		end
	end

	for land, list in byLand do
		local baseX = landXScale(land)
		for i, slot in ipairs(list) do
			slot.stackIndex = i
			local stack = i - 1
			local xJitter = ((stack % 3) - 1) * 0.012
			local yLift = stack * (if isMobile() then 8 else 10)
			-- Heads live in the TOP band; luck pills stay on the bottom track.
			local goal = UDim2.new(baseX + xJitter, 0, 0.32, -yLift)
			slot.root.AnchorPoint = Vector2.new(0.5, 0.5)
			slot.root.ZIndex = 50 + stack + (if slot.player == player then 8 else 0)
			TweenService:Create(slot.root, MOVE_TWEEN, { Position = goal }):Play()

			if slot.player == player then
				slot.ring.Color = YOU_RING
				slot.ring.Transparency = 0
				slot.ring.Thickness = 2.4
			else
				slot.ring.Color = GLASS_STROKE
				slot.ring.Transparency = 0.1
				slot.ring.Thickness = 1.5
			end
			slot.icon.BackgroundColor3 = Color3.fromRGB(20, 40, 28)
		end
	end
end

local function syncPlayerSlot(plr: Player)
	local landRaw = plr:GetAttribute(LAND_ATTR)
	local land = if typeof(landRaw) == "number" then math.floor(landRaw) else 0
	if land < 1 or land > MAX_LAND then
		destroySlot(plr.UserId)
		layoutStacks()
		return
	end
	local slot = ensureSlot(plr)
	if not slot then
		return
	end
	if slot.land ~= land then
		slot.land = land
		-- Soft pop when land changes.
		local scale = getOrAddUIScale(slot.root)
		scale.Scale = 0.7
		TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 }):Play()
	end
	layoutStacks()
end

local function syncAllSlots()
	local seen: { [number]: boolean } = {}
	for _, plr in Players:GetPlayers() do
		seen[plr.UserId] = true
		syncPlayerSlot(plr)
	end
	for userId in slotsByUserId do
		if not seen[userId] then
			destroySlot(userId)
		end
	end
	layoutStacks()
end

local function hookPlayer(plr: Player)
	if attrConns[plr] then
		attrConns[plr]:Disconnect()
	end
	attrConns[plr] = plr:GetAttributeChangedSignal(LAND_ATTR):Connect(function()
		syncPlayerSlot(plr)
	end)
	syncPlayerSlot(plr)
end

local function startLocalPulse()
	pulseToken += 1
	local token = pulseToken
	task.spawn(function()
		while token == pulseToken do
			local slot = slotsByUserId[player.UserId]
			if slot and slot.root.Parent and visibleTarget then
				local scale = getOrAddUIScale(slot.root)
				TweenService:Create(scale, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1.12,
				}):Play()
				task.wait(0.7)
				if token ~= pulseToken then
					break
				end
				TweenService:Create(scale, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1,
				}):Play()
				task.wait(0.7)
			else
				task.wait(0.4)
			end
		end
	end)
end

local function formatLandLuckLabel(land: number): string
	-- Entry luck per land so L1→L10 stay ascending (max-of-folder scrambled the strip).
	local luck = LandResolver.getEntryDisplayLuckForLand(land)
	if luck <= 1 then
		return "1x"
	end
	local n = math.floor(luck + 0.5)
	if n >= 1000 then
		return string.format("%dkx", math.floor(n / 1000 + 0.5))
	end
	return tostring(n) .. "x"
end

local function refreshLandLabels()
	for land = 1, MAX_LAND do
		local label = landLabels[land]
		if label and label.Parent then
			label.Text = formatLandLuckLabel(land)
		end
	end
end

local function buildStrip(parentGui: PlayerGui)
	local compact = isMobile()
	-- Tall enough for head row + luck row (no overlap).
	local height = if compact then 62 else 68
	local widthScale = if compact then 0.8 else 0.58

	local gui = Instance.new("ScreenGui")
	gui.Name = "LandActivityStripGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 18
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true
	gui.Parent = parentGui
	stripGui = gui

	local root = Instance.new("CanvasGroup")
	root.Name = "LandActivityStrip"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, if compact then -6 else -8)
	root.Size = UDim2.new(widthScale, 0, 0, height)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.GroupTransparency = 1
	root.Visible = false
	root.ZIndex = 40
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.82
	scale.Parent = root

	-- Soft green glass plate (readable, not opaque cheese).
	local ticket = Instance.new("Frame")
	ticket.Name = "Ticket"
	ticket.Size = UDim2.fromScale(1, 1)
	ticket.BackgroundColor3 = GLASS
	ticket.BackgroundTransparency = 0.28
	ticket.BorderSizePixel = 0
	ticket.ZIndex = 40
	ticket.ClipsDescendants = false
	ticket.Parent = root

	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 10)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Color = GLASS_STROKE
	ticketStroke.Thickness = 1.6
	ticketStroke.Transparency = 0.35
	ticketStroke.Parent = ticket

	local glassGrad = Instance.new("UIGradient")
	glassGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 110, 70)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(24, 68, 44)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(18, 50, 34)),
	})
	glassGrad.Rotation = 90
	glassGrad.Parent = ticket

	local floatPad = Instance.new("UIPadding")
	floatPad.PaddingTop = UDim.new(0, 4)
	floatPad.PaddingBottom = UDim.new(0, 5)
	floatPad.PaddingLeft = UDim.new(0, 8)
	floatPad.PaddingRight = UDim.new(0, 8)
	floatPad.Parent = ticket

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.Size = UDim2.fromScale(1, 1)
	inner.BackgroundColor3 = GLASS_INNER
	inner.BackgroundTransparency = 0.42
	inner.BorderSizePixel = 0
	inner.ZIndex = 41
	inner.ClipsDescendants = false
	inner.Parent = ticket
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 7)
	innerCorner.Parent = inner
	local innerStroke = Instance.new("UIStroke")
	innerStroke.Color = GLASS_STROKE
	innerStroke.Thickness = 1
	innerStroke.Transparency = 0.55
	innerStroke.Parent = inner

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0)
	title.Position = UDim2.new(0, 4, 0, 1)
	title.Size = UDim2.new(0.4, 0, 0, 11)
	title.Text = "LANDS"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = INK
	title.TextTransparency = 0.15
	title.TextSize = 9
	title.ZIndex = 46
	UiFonts.applyBody(title)
	title.Parent = inner

	-- Luck track sits in the BOTTOM band only.
	local trackFrame = Instance.new("Frame")
	trackFrame.Name = "Track"
	trackFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	trackFrame.Position = UDim2.new(0.5, 0, 0.82, 0)
	trackFrame.Size = UDim2.new(0.94, 0, 0, 4)
	trackFrame.BackgroundColor3 = TRACK
	trackFrame.BackgroundTransparency = 0.25
	trackFrame.BorderSizePixel = 0
	trackFrame.ZIndex = 43
	trackFrame.Parent = inner

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = trackFrame

	local trackGlow = Instance.new("UIGradient")
	trackGlow.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 230, 160)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 200, 120)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 150, 90)),
	})
	trackGlow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.15),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	trackGlow.Parent = trackFrame

	local ticksHost = Instance.new("Frame")
	ticksHost.Name = "Ticks"
	ticksHost.BackgroundTransparency = 1
	ticksHost.Size = UDim2.fromScale(1, 1)
	ticksHost.ZIndex = 44
	ticksHost.Parent = inner

	table.clear(landTicks)
	table.clear(landLabels)
	for land = 1, MAX_LAND do
		local x = landXScale(land)
		local landCol = LAND_COLORS[land]

		local pill = Instance.new("Frame")
		pill.Name = "Tick" .. tostring(land)
		pill.AnchorPoint = Vector2.new(0.5, 0.5)
		pill.Position = UDim2.new(x, 0, 0.82, 0)
		pill.Size = UDim2.fromOffset(if compact then 26 else 30, if compact then 13 else 14)
		pill.BackgroundColor3 = landCol
		pill.BackgroundTransparency = 0.12
		pill.BorderSizePixel = 0
		pill.ZIndex = 45
		pill.Parent = ticksHost
		local pillCorner = Instance.new("UICorner")
		pillCorner.CornerRadius = UDim.new(0, 4)
		pillCorner.Parent = pill
		local pillStroke = Instance.new("UIStroke")
		pillStroke.Color = INK_DARK
		pillStroke.Thickness = 1
		pillStroke.Transparency = 0.35
		pillStroke.Parent = pill
		table.insert(landTicks, pill)

		local label = Instance.new("TextLabel")
		label.Name = "L" .. tostring(land)
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Text = formatLandLuckLabel(land)
		label.TextColor3 = INK_DARK
		label.TextTransparency = 0
		label.TextSize = if compact then 8 else 9
		label.ZIndex = 46
		UiFonts.applyBody(label)
		label.Parent = pill
		table.insert(landLabels, label)
	end

	-- Avatar row is its own host in the TOP band (never covers luck pills).
	local avatars = Instance.new("Frame")
	avatars.Name = "Avatars"
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.fromScale(1, 1)
	avatars.ZIndex = 50
	avatars.ClipsDescendants = false
	avatars.Parent = inner

	stripRoot = root
	stripScale = scale
	avatarsHost = avatars

	task.spawn(function()
		for _ = 1, 12 do
			task.wait(1.25)
			refreshLandLabels()
		end
	end)
end

function LandActivityStripController.init()
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main:WaitForChild("SideUI", 30)
	if not sideUI then
		warn("[LandActivityStripController] SideUI missing")
		return
	end

	local right = sideUI:FindFirstChild("Right")
	local rb = right and right:FindFirstChild("RandomBrainrot")
	if rb and rb:IsA("GuiObject") then
		randomBrainrotFrame = rb :: GuiObject
	else
		warn("[LandActivityStripController] SideUI.Right.RandomBrainrot missing")
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 15)
	if not playerGui or not playerGui:IsA("PlayerGui") then
		warn("[LandActivityStripController] PlayerGui missing")
		return
	end
	local existing = playerGui:FindFirstChild("LandActivityStripGui")
	if existing then
		existing:Destroy()
	end
	buildStrip(playerGui)

	for _, plr in Players:GetPlayers() do
		hookPlayer(plr)
	end
	Players.PlayerAdded:Connect(function(plr)
		hookPlayer(plr)
		syncAllSlots()
	end)
	Players.PlayerRemoving:Connect(function(plr)
		if attrConns[plr] then
			attrConns[plr]:Disconnect()
			attrConns[plr] = nil
		end
		destroySlot(plr.UserId)
		layoutStacks()
	end)

	GameplayUiVisibility.onRestored(function()
		outsideStreak = 0
		insideStreak = 0
		refreshVisibility(true)
	end)

	player.CharacterAdded:Connect(function()
		outsideStreak = 0
		insideStreak = 0
		applyVisibility(false, true)
		task.defer(function()
			refreshVisibility(true)
		end)
	end)

	startLocalPulse()
	syncAllSlots()
	applyVisibility(false, true)

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		pollAccum += dt
		if pollAccum < POLL_SEC then
			return
		end
		pollAccum = 0
		refreshVisibility(false)
		-- Keep slots honest even if an attribute edge was missed.
		if visibleTarget then
			syncAllSlots()
		end
	end)
end

return LandActivityStripController
