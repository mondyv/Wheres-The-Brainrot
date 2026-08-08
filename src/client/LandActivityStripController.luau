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
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck

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

local LAND_COLORS: { Color3 } = {
	Color3.fromRGB(120, 220, 140),
	Color3.fromRGB(100, 210, 180),
	Color3.fromRGB(90, 190, 230),
	Color3.fromRGB(120, 150, 255),
	Color3.fromRGB(170, 120, 255),
	Color3.fromRGB(230, 110, 210),
	Color3.fromRGB(255, 130, 110),
	Color3.fromRGB(255, 170, 70),
	Color3.fromRGB(255, 210, 70),
	Color3.fromRGB(255, 240, 120),
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

	local size = if isMobile() then 28 else 34
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
	ring.Thickness = if plr == player then 2.4 else 1.6
	ring.Color = if plr == player then Color3.fromRGB(255, 230, 90) else Color3.fromRGB(255, 255, 255)
	ring.Transparency = if plr == player then 0.05 else 0.35
	ring.Parent = icon

	local tip = Instance.new("TextLabel")
	tip.Name = "NameTip"
	tip.BackgroundTransparency = 1
	tip.Size = UDim2.new(2.4, 0, 0.45, 0)
	tip.Position = UDim2.new(0.5, 0, 0, -2)
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Text = plr.DisplayName
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.TextStrokeTransparency = 0.4
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
			local xJitter = ((stack % 3) - 1) * 0.012
			local yLift = stack * (if isMobile() then 10 else 12)
			local goal = UDim2.new(baseX + xJitter, 0, 1, -4 - yLift)
			slot.root.ZIndex = 20 + stack + (if slot.player == player then 5 else 0)
			TweenService:Create(slot.root, MOVE_TWEEN, { Position = goal }):Play()

			local col = LAND_COLORS[math.clamp(land, 1, #LAND_COLORS)]
			if slot.player == player then
				slot.ring.Color = Color3.fromRGB(255, 230, 90)
				slot.ring.Transparency = 0.05
			else
				slot.ring.Color = col
				slot.ring.Transparency = 0.2
			end
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

local function buildStrip(parent: Instance)
	local compact = isMobile()
	local height = if compact then 54 else 64
	local widthScale = if compact then 0.92 else 0.72

	local root = Instance.new("CanvasGroup")
	root.Name = "LandActivityStrip"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, if compact then -72 else -88)
	root.Size = UDim2.new(widthScale, 0, 0, height)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.GroupTransparency = 1
	root.Visible = false
	root.ZIndex = 40
	root.Parent = parent

	local scale = Instance.new("UIScale")
	scale.Scale = 0.82
	scale.Parent = root

	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	bg.BackgroundTransparency = 0.28
	bg.BorderSizePixel = 0
	bg.ZIndex = 40
	bg.Parent = root

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 14)
	bgCorner.Parent = bg

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(255, 255, 255)
	bgStroke.Thickness = 1.2
	bgStroke.Transparency = 0.78
	bgStroke.Parent = bg

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0)
	title.Position = UDim2.new(0, 12, 0, 4)
	title.Size = UDim2.new(0.4, 0, 0, 14)
	title.Text = "SERVER LANDS"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(220, 230, 255)
	title.TextTransparency = 0.25
	title.TextSize = 11
	title.ZIndex = 42
	UiFonts.applyBody(title)
	title.Parent = root

	local trackFrame = Instance.new("Frame")
	trackFrame.Name = "Track"
	trackFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	trackFrame.Position = UDim2.new(0.5, 0, 0.58, 0)
	trackFrame.Size = UDim2.new(0.92, 0, 0, 4)
	trackFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	trackFrame.BackgroundTransparency = 0.82
	trackFrame.BorderSizePixel = 0
	trackFrame.ZIndex = 41
	trackFrame.Parent = root

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = trackFrame

	local trackGlow = Instance.new("UIGradient")
	trackGlow.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 200, 140)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 210, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 90)),
	})
	trackGlow.Parent = trackFrame

	local ticksHost = Instance.new("Frame")
	ticksHost.Name = "Ticks"
	ticksHost.BackgroundTransparency = 1
	ticksHost.Size = UDim2.fromScale(1, 1)
	ticksHost.ZIndex = 42
	ticksHost.Parent = root

	table.clear(landTicks)
	table.clear(landLabels)
	for land = 1, MAX_LAND do
		local x = landXScale(land)
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. tostring(land)
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.new(x, 0, 0.58, 0)
		tick.Size = UDim2.fromOffset(6, 6)
		tick.BackgroundColor3 = LAND_COLORS[land]
		tick.BorderSizePixel = 0
		tick.ZIndex = 43
		tick.Parent = ticksHost
		local tickCorner = Instance.new("UICorner")
		tickCorner.CornerRadius = UDim.new(1, 0)
		tickCorner.Parent = tick
		table.insert(landTicks, tick)

		local label = Instance.new("TextLabel")
		label.Name = "L" .. tostring(land)
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(x, 0, 0.58, 8)
		label.Size = UDim2.fromOffset(28, 12)
		local luck = PlotLuck.DISPLAY_TIERS[land] or land
		label.Text = if land == 1 then "1x" else (tostring(math.floor(luck)) .. "x")
		label.TextColor3 = LAND_COLORS[land]
		label.TextTransparency = 0.15
		label.TextSize = 10
		label.ZIndex = 43
		UiFonts.applyBody(label)
		label.Parent = ticksHost
		table.insert(landLabels, label)
	end

	local avatars = Instance.new("Frame")
	avatars.Name = "Avatars"
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.fromScale(1, 1)
	avatars.ZIndex = 44
	avatars.ClipsDescendants = false
	avatars.Parent = root

	stripRoot = root
	stripScale = scale
	avatarsHost = avatars
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

	-- Parent under Main so GameplayUiVisibility can slide SideUI without losing the strip;
	-- we manually hide with HUD.
	buildStrip(main)

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
