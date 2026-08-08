-- [ACTIVE] LandActivityStripController
--[[
	Outside the safe zone:
	• Hides SideUI.Right.RandomBrainrot (only restores it inside the safe zone)
	• Shows a minimal land radar (L1→L10) with player headshots
	Inside safe zone / HUD hidden: strip hides.
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
local SHOW_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local MOVE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local INSIDE_STREAK = 2
local OUTSIDE_STREAK = 2

-- Cartoony grass radar — chunky outline, sunny accents, big readable heads.
local BAR = Color3.fromRGB(88, 178, 72)
local BAR_DARK = Color3.fromRGB(42, 58, 36)
local RAIL = Color3.fromRGB(255, 244, 168)
local ACCENT = Color3.fromRGB(255, 220, 72)
local LABEL = Color3.fromRGB(255, 255, 255)
local LABEL_SHADOW = Color3.fromRGB(42, 58, 36)
local YOU_RING = Color3.fromRGB(255, 92, 92)
local OTHER_RING = Color3.fromRGB(255, 255, 255)

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
	local t = (math.clamp(land, 1, MAX_LAND) - 1) / (MAX_LAND - 1)
	return 0.035 + t * 0.93
end

local function isOutsideSafezone(): boolean
	local character = player.Character
	if not character then
		return false
	end
	if not SafezoneUtil.isCacheReady() then
		return false
	end
	return not SafezoneUtil.isCharacterInSafezone(character)
end

local function shouldShowStrip(): boolean
	if GameplayUiVisibility.isHidden() then
		return false
	end
	return isOutsideSafezone()
end

-- RandomBrainrot is a safezone-only HUD piece — never flash it outside / under panels.
local function shouldShowRandomBrainrot(): boolean
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
	return SafezoneUtil.isCharacterInSafezone(character)
end

local function setRandomBrainrotVisible(show: boolean)
	if not randomBrainrotFrame then
		return
	end
	if randomBrainrotFrame.Visible ~= show then
		randomBrainrotFrame.Visible = show
	end
	local activation = randomBrainrotFrame:FindFirstChild("Activation", true)
	if activation and activation:IsA("GuiButton") then
		activation.Active = show
		pcall(function()
			(activation :: any).Interactable = show
		end)
	end
end

local function syncRandomBrainrot()
	setRandomBrainrotVisible(shouldShowRandomBrainrot())
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
		syncRandomBrainrot()
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
		stripScale.Scale = 0.92
		stripRoot.GroupTransparency = 1
		visibilityTween = TweenService:Create(stripScale, SHOW_TWEEN, { Scale = 1 })
		visibilityTween:Play()
		TweenService:Create(stripRoot, TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
		}):Play()
	else
		-- Only restore RandomBrainrot when actually in safezone (never mid-panel / jungle).
		syncRandomBrainrot()
		if instant then
			stripRoot.Visible = false
			stripScale.Scale = 0.92
			stripRoot.GroupTransparency = 1
			return
		end
		visibilityTween = TweenService:Create(stripScale, HIDE_TWEEN, { Scale = 0.92 })
		visibilityTween:Play()
		TweenService:Create(stripRoot, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
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
	syncRandomBrainrot()
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

	local size = if isMobile() then 36 else 42
	local root = Instance.new("Frame")
	root.Name = "Avatar_" .. tostring(plr.UserId)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 50
	root.Active = true
	root.Parent = avatarsHost

	-- Soft drop shadow under the head so it pops off the bar.
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 2)
	shadow.Size = UDim2.new(1, 4, 1, 4)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 49
	shadow.Parent = root
	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(1, 0)
	shadowCorner.Parent = shadow

	local icon = Instance.new("ImageLabel")
	icon.Name = "Head"
	icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	icon.BackgroundTransparency = 0
	icon.BorderSizePixel = 0
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = headshotUrl(plr.UserId)
	icon.ScaleType = Enum.ScaleType.Crop
	icon.ZIndex = 52
	icon.Active = false
	icon.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = icon

	local ring = Instance.new("UIStroke")
	ring.Thickness = if plr == player then 3.5 else 3
	ring.Color = if plr == player then YOU_RING else OTHER_RING
	ring.Transparency = 0
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = icon

	local outerRing = Instance.new("UIStroke")
	outerRing.Thickness = 1.5
	outerRing.Color = BAR_DARK
	outerRing.Transparency = 0
	outerRing.Parent = icon

	local tip = Instance.new("TextLabel")
	tip.Name = "NameTip"
	tip.BackgroundColor3 = Color3.fromRGB(8, 10, 9)
	tip.BackgroundTransparency = 0.2
	tip.Size = UDim2.new(0, 76, 0, 15)
	tip.Position = UDim2.new(0.5, 0, 0, -6)
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Text = plr.DisplayName
	tip.TextColor3 = Color3.fromRGB(245, 255, 248)
	tip.TextStrokeTransparency = 1
	tip.TextSize = 10
	tip.TextTruncate = Enum.TextTruncate.AtEnd
	tip.Visible = false
	tip.ZIndex = 60
	UiFonts.applyBody(tip)
	tip.Parent = root
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 5)
	tipCorner.Parent = tip
	local tipPad = Instance.new("UIPadding")
	tipPad.PaddingLeft = UDim.new(0, 5)
	tipPad.PaddingRight = UDim.new(0, 5)
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
			local yLift = stack * (if isMobile() then 12 else 14)
			-- Heads sit clearly above the chunky bar.
			local goal = UDim2.new(baseX + xJitter, 0, 0, if isMobile() then 38 else 42)
			goal = UDim2.new(goal.X.Scale, goal.X.Offset, goal.Y.Scale, goal.Y.Offset - yLift)
			slot.root.AnchorPoint = Vector2.new(0.5, 1)
			slot.root.ZIndex = 50 + stack + (if slot.player == player then 10 else 0)
			TweenService:Create(slot.root, MOVE_TWEEN, { Position = goal }):Play()

			if slot.player == player then
				slot.ring.Color = YOU_RING
				slot.ring.Thickness = 3.5
			else
				slot.ring.Color = OTHER_RING
				slot.ring.Thickness = 3
			end
			slot.ring.Transparency = 0
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
		local scale = getOrAddUIScale(slot.root)
		scale.Scale = 0.75
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
				TweenService:Create(scale, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1.1,
				}):Play()
				task.wait(0.65)
				if token ~= pulseToken then
					break
				end
				TweenService:Create(scale, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1,
				}):Play()
				task.wait(0.65)
			else
				task.wait(0.4)
			end
		end
	end)
end

local function formatLandLuckLabel(land: number): string
	local luck = LandResolver.getEntryDisplayLuckForLand(land)
	if luck <= 1 then
		return "1x"
	end
	local n = math.floor(luck + 0.5)
	if n >= 1000 then
		return string.format("%dk", math.floor(n / 1000 + 0.5)) .. "x"
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
	local barHeight = if compact then 26 else 28
	local height = if compact then 68 else 76
	local widthScale = if compact then 0.78 else 0.56

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
	root.ClipsDescendants = false
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.92
	scale.Parent = root

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, barHeight)
	bar.BackgroundColor3 = BAR
	bar.BackgroundTransparency = 0
	bar.BorderSizePixel = 0
	bar.ZIndex = 40
	bar.Parent = root

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 14)
	barCorner.Parent = bar

	local barStroke = Instance.new("UIStroke")
	barStroke.Color = BAR_DARK
	barStroke.Thickness = 3
	barStroke.Transparency = 0
	barStroke.Parent = bar

	local barShine = Instance.new("UIGradient")
	barShine.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 210, 96)),
		ColorSequenceKeypoint.new(0.5, BAR),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(66, 148, 58)),
	})
	barShine.Rotation = 90
	barShine.Parent = bar

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 2)
	pad.Parent = bar

	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.AnchorPoint = Vector2.new(0.5, 0)
	rail.Position = UDim2.new(0.5, 0, 0, 6)
	rail.Size = UDim2.new(1, -8, 0, 3)
	rail.BackgroundColor3 = RAIL
	rail.BackgroundTransparency = 0.08
	rail.BorderSizePixel = 0
	rail.ZIndex = 41
	rail.Parent = bar
	local railCorner = Instance.new("UICorner")
	railCorner.CornerRadius = UDim.new(1, 0)
	railCorner.Parent = rail

	local ticksHost = Instance.new("Frame")
	ticksHost.Name = "Ticks"
	ticksHost.BackgroundTransparency = 1
	ticksHost.Size = UDim2.fromScale(1, 1)
	ticksHost.ZIndex = 42
	ticksHost.Parent = bar

	table.clear(landTicks)
	table.clear(landLabels)
	for land = 1, MAX_LAND do
		local x = landXScale(land)

		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. tostring(land)
		tick.AnchorPoint = Vector2.new(0.5, 0)
		tick.Position = UDim2.new(x, 0, 0, 5)
		tick.Size = UDim2.fromOffset(4, 4)
		tick.BackgroundColor3 = ACCENT
		tick.BackgroundTransparency = 0
		tick.BorderSizePixel = 0
		tick.ZIndex = 43
		tick.Parent = ticksHost
		local tickCorner = Instance.new("UICorner")
		tickCorner.CornerRadius = UDim.new(1, 0)
		tickCorner.Parent = tick
		local tickStroke = Instance.new("UIStroke")
		tickStroke.Color = BAR_DARK
		tickStroke.Thickness = 1
		tickStroke.Parent = tick
		table.insert(landTicks, tick)

		local pill = Instance.new("Frame")
		pill.Name = "Pill" .. tostring(land)
		pill.AnchorPoint = Vector2.new(0.5, 0)
		pill.Position = UDim2.new(x, 0, 0, 11)
		pill.Size = UDim2.fromOffset(if compact then 30 else 34, if compact then 14 else 15)
		pill.BackgroundColor3 = BAR_DARK
		pill.BackgroundTransparency = 0.12
		pill.BorderSizePixel = 0
		pill.ZIndex = 43
		pill.Parent = ticksHost
		local pillCorner = Instance.new("UICorner")
		pillCorner.CornerRadius = UDim.new(1, 0)
		pillCorner.Parent = pill

		local label = Instance.new("TextLabel")
		label.Name = "L" .. tostring(land)
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(1, 1)
		label.Text = formatLandLuckLabel(land)
		label.TextColor3 = LABEL
		label.TextStrokeColor3 = LABEL_SHADOW
		label.TextStrokeTransparency = 0.35
		label.TextSize = if compact then 9 else 10
		label.ZIndex = 44
		UiFonts.applyBody(label)
		label.Parent = pill
		table.insert(landLabels, label)
	end

	local avatars = Instance.new("Frame")
	avatars.Name = "Avatars"
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.fromScale(1, 1)
	avatars.ZIndex = 50
	avatars.ClipsDescendants = false
	avatars.Parent = root

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
		syncRandomBrainrot()
	end)

	player.CharacterAdded:Connect(function()
		outsideStreak = 0
		insideStreak = 0
		applyVisibility(false, true)
		syncRandomBrainrot()
		task.defer(function()
			refreshVisibility(true)
		end)
	end)

	startLocalPulse()
	syncAllSlots()
	applyVisibility(false, true)
	syncRandomBrainrot()

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
		if visibleTarget then
			syncAllSlots()
		end
	end)
end

return LandActivityStripController
