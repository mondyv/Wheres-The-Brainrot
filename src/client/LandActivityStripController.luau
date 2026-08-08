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
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))

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

local CHEESE_OUTER = Color3.fromRGB(255, 214, 74)
local CHEESE_INNER = Color3.fromRGB(255, 244, 180)
local CHEESE_STROKE = Color3.fromRGB(40, 28, 8)
local CHEESE_DASH = Color3.fromRGB(180, 120, 30)
local CHEESE_STUD = Color3.fromRGB(120, 80, 20)
local YOU_RING = Color3.fromRGB(255, 170, 40)

-- Warm cheese → toasted gradient across lands (not neon rainbow).
local LAND_COLORS: { Color3 } = {
	Color3.fromRGB(255, 236, 140),
	Color3.fromRGB(255, 220, 100),
	Color3.fromRGB(255, 200, 70),
	Color3.fromRGB(250, 175, 55),
	Color3.fromRGB(240, 150, 45),
	Color3.fromRGB(230, 130, 40),
	Color3.fromRGB(220, 110, 40),
	Color3.fromRGB(210, 95, 45),
	Color3.fromRGB(195, 80, 40),
	Color3.fromRGB(175, 65, 35),
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

	local size = if isMobile() then 16 else 18
	local root = Instance.new("Frame")
	root.Name = "Avatar_" .. tostring(plr.UserId)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 20
	root.Active = true
	root.Parent = avatarsHost

	local icon = Instance.new("ImageLabel")
	icon.Name = "Head"
	icon.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	icon.BorderSizePixel = 0
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = headshotUrl(plr.UserId)
	icon.ScaleType = Enum.ScaleType.Crop
	icon.ZIndex = 21
	icon.Active = false
	icon.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = icon

	local ring = Instance.new("UIStroke")
	ring.Thickness = if plr == player then 2.6 else 1.8
	ring.Color = if plr == player then YOU_RING else CHEESE_STROKE
	ring.Transparency = if plr == player then 0.05 else 0.2
	ring.Parent = icon

	local tip = Instance.new("TextLabel")
	tip.Name = "NameTip"
	tip.BackgroundTransparency = 1
	tip.Size = UDim2.new(2.6, 0, 0.5, 0)
	tip.Position = UDim2.new(0.5, 0, 0, -2)
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Text = plr.DisplayName
	tip.TextColor3 = CHEESE_STROKE
	tip.TextStrokeColor3 = CHEESE_INNER
	tip.TextStrokeTransparency = 0.35
	tip.TextScaled = true
	tip.Visible = false
	tip.ZIndex = 25
	UiFonts.applyBody(tip)
	tip.Parent = root

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
			local xJitter = ((stack % 3) - 1) * 0.01
			local yLift = stack * (if isMobile() then 7 else 8)
			local goal = UDim2.new(baseX + xJitter, 0, 1, -2 - yLift)
			slot.root.ZIndex = 20 + stack + (if slot.player == player then 5 else 0)
			TweenService:Create(slot.root, MOVE_TWEEN, { Position = goal }):Play()

			local col = LAND_COLORS[math.clamp(land, 1, #LAND_COLORS)]
			if slot.player == player then
				slot.ring.Color = YOU_RING
				slot.ring.Transparency = 0.05
			else
				slot.ring.Color = CHEESE_STROKE
				slot.ring.Transparency = 0.15
			end
			-- Soft cheese tint behind head for land heat.
			slot.icon.BackgroundColor3 = col:Lerp(Color3.fromRGB(40, 28, 8), 0.55)
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

local function paintStudImage(label: ImageLabel, color: Color3, imageTransparency: number)
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0
	label.BorderSizePixel = 0
	label.Image = TimCheeseQuestConfig.STUD_TEXTURE
	label.ImageColor3 = CHEESE_STUD
	label.ImageTransparency = imageTransparency
	label.ScaleType = Enum.ScaleType.Tile
	label.TileSize = UDim2.fromOffset(22, 22)
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
	local height = if compact then 32 else 34
	local widthScale = if compact then 0.62 else 0.4

	local gui = Instance.new("ScreenGui")
	gui.Name = "LandActivityStripGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	-- Below modal panels (offline / revive ~90+) so it never covers Decline.
	gui.DisplayOrder = 18
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true
	gui.Parent = parentGui
	stripGui = gui

	local root = Instance.new("CanvasGroup")
	root.Name = "LandActivityStrip"
	root.AnchorPoint = Vector2.new(0.5, 1)
	-- Flush to the real bottom of the screen (IgnoreGuiInset).
	root.Position = UDim2.new(0.5, 0, 1, if compact then -4 else -5)
	root.Size = UDim2.new(widthScale, 0, 0, height)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.GroupTransparency = 1
	root.Visible = false
	root.ZIndex = 40
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = root

	-- Outer cheese ticket (matches Tim Cheese quest card).
	local ticket = Instance.new("ImageLabel")
	ticket.Name = "Ticket"
	ticket.Size = UDim2.fromScale(1, 1)
	ticket.ZIndex = 40
	ticket.ClipsDescendants = false
	paintStudImage(ticket, CHEESE_OUTER, 0.8)
	ticket.Parent = root

	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 6)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Color = CHEESE_STROKE
	ticketStroke.Thickness = 2
	ticketStroke.Parent = ticket

	local floatPad = Instance.new("UIPadding")
	floatPad.PaddingTop = UDim.new(0, 3)
	floatPad.PaddingBottom = UDim.new(0, 3)
	floatPad.PaddingLeft = UDim.new(0, 5)
	floatPad.PaddingRight = UDim.new(0, 5)
	floatPad.Parent = ticket

	local inner = Instance.new("ImageLabel")
	inner.Name = "Inner"
	paintStudImage(inner, CHEESE_INNER, 0.84)
	inner.Size = UDim2.fromScale(1, 1)
	inner.ZIndex = 41
	inner.ClipsDescendants = false
	inner.Parent = ticket
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 4)
	innerCorner.Parent = inner
	local dash = Instance.new("UIStroke")
	dash.Color = CHEESE_DASH
	dash.Thickness = 1
	dash.Transparency = 0.4
	dash.Parent = inner

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0)
	title.Position = UDim2.new(0, 6, 0, 1)
	title.Size = UDim2.new(0.55, 0, 0, 11)
	title.Text = "SERVER LANDS"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = CHEESE_STROKE
	title.TextStrokeColor3 = Color3.fromRGB(255, 244, 180)
	title.TextStrokeTransparency = 0.55
	title.TextSize = 10
	title.ZIndex = 45
	UiFonts.applyBody(title)
	title.Parent = inner

	local trackFrame = Instance.new("Frame")
	trackFrame.Name = "Track"
	trackFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	trackFrame.Position = UDim2.new(0.5, 0, 0.62, 0)
	trackFrame.Size = UDim2.new(0.94, 0, 0, 3)
	trackFrame.BackgroundColor3 = CHEESE_STROKE
	trackFrame.BackgroundTransparency = 0.55
	trackFrame.BorderSizePixel = 0
	trackFrame.ZIndex = 42
	trackFrame.Parent = inner

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = trackFrame

	local trackGlow = Instance.new("UIGradient")
	trackGlow.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 140)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 170, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(175, 65, 35)),
	})
	trackGlow.Parent = trackFrame

	local ticksHost = Instance.new("Frame")
	ticksHost.Name = "Ticks"
	ticksHost.BackgroundTransparency = 1
	ticksHost.Size = UDim2.fromScale(1, 1)
	ticksHost.ZIndex = 43
	ticksHost.Parent = inner

	table.clear(landTicks)
	table.clear(landLabels)
	for land = 1, MAX_LAND do
		local x = landXScale(land)
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. tostring(land)
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.new(x, 0, 0.62, 0)
		tick.Size = UDim2.fromOffset(5, 5)
		tick.BackgroundColor3 = LAND_COLORS[land]
		tick.BorderSizePixel = 0
		tick.ZIndex = 44
		tick.Parent = ticksHost
		local tickCorner = Instance.new("UICorner")
		tickCorner.CornerRadius = UDim.new(1, 0)
		tickCorner.Parent = tick
		local tickStroke = Instance.new("UIStroke")
		tickStroke.Color = CHEESE_STROKE
		tickStroke.Thickness = 1
		tickStroke.Transparency = 0.25
		tickStroke.Parent = tick
		table.insert(landTicks, tick)

		local label = Instance.new("TextLabel")
		label.Name = "L" .. tostring(land)
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(x, 0, 0.62, 5)
		label.Size = UDim2.fromOffset(28, 10)
		label.Text = formatLandLuckLabel(land)
		label.TextColor3 = CHEESE_STROKE
		label.TextTransparency = 0.05
		label.TextSize = 8
		label.ZIndex = 44
		UiFonts.applyBody(label)
		label.Parent = ticksHost
		table.insert(landLabels, label)
	end

	local avatars = Instance.new("Frame")
	avatars.Name = "Avatars"
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.fromScale(1, 1)
	avatars.ZIndex = 46
	avatars.ClipsDescendants = false
	avatars.Parent = inner

	stripRoot = root
	stripScale = scale
	avatarsHost = avatars

	-- Luck hitboxes stream in late — refresh labels a few times.
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
