-- [ACTIVE] LandActivityStripController
--[[
	Outside the safe zone:
	• Hides SideUI.Right.RandomBrainrot (only restores it inside the safe zone)
	• Shows a cartoony land radar (Safezone → luck lands → Other World) with player headshots
	Inside safe zone / HUD hidden: strip hides.
]]

local CollectionService = game:GetService("CollectionService")
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
local LandAmbushUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandAmbushUtil"))
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))

local LandActivityStripController = {}

local player = Players.LocalPlayer
local LAND_ATTR = "CurrentLand"
local MAX_LAND = 10
local SAFEZONE_SLOT = 0
local OTHER_WORLD_SLOT = 11
local OTHER_WORLD_LABEL = "Other World"
local SAFEZONE_LABEL = "Safezone"
local COMING_SOON_TAG = "ComingSoonZone"
local POLL_SEC = if UserInputService.TouchEnabled then 0.45 else 0.18
local SHOW_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local MOVE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLUSTER_METER = 0.12
local PEEK_PX = 13
local HEAD_Y = -4
local INSIDE_STREAK = 2
local OUTSIDE_STREAK = 2

-- Soft glass plate + rainbow track + readable luck chips (no loud yellow borders).
local PLATE = Color3.fromRGB(12, 18, 16)
local TRACK = Color3.fromRGB(255, 255, 255)
local TOKEN = Color3.fromRGB(18, 22, 20)
local TOKEN_FACE = Color3.fromRGB(255, 250, 235)
local TOKEN_EDGE = Color3.fromRGB(255, 255, 255)
local TOKEN_EDGE_YOU = Color3.fromRGB(255, 255, 255)
local YOU_RING = Color3.fromRGB(255, 64, 64)
local OTHER_RING = Color3.fromRGB(255, 255, 255)
local STEM = Color3.fromRGB(255, 255, 255)
local STUD_TEX = TimCheeseQuestConfig.STUD_TEXTURE
local highlightedLand = 0

type AvatarSlot = {
	player: Player,
	root: Frame,
	icon: ImageLabel,
	ring: UIStroke,
	stem: Frame?,
	land: number,
	meterIndex: number,
	stackIndex: number,
	moveTween: Tween?,
}

local randomBrainrotFrame: GuiObject? = nil
local stripGui: ScreenGui? = nil
local stripRoot: Frame? = nil
local stripScale: UIScale? = nil
local plateFrame: Frame? = nil
local avatarsHost: Frame? = nil
local landTicks: { [number]: Frame } = {}
local landLabels: { [number]: TextLabel } = {}
local landTokens: { [number]: Frame } = {}
local trackRainbow: UIGradient? = nil
local trackFrame: Frame? = nil

local slotsByUserId: { [number]: AvatarSlot } = {}
local attrConns: { [Player]: RBXScriptConnection } = {}
local visibleTarget = false
local visibilityTween: Tween? = nil
local pollAccum = 0
local outsideStreak = 0
local insideStreak = 0
local heartbeatConn: RBXScriptConnection? = nil
local pulseToken = 0
local bobConn: RBXScriptConnection? = nil
local bobPhase = 0

local function headshotUrl(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

local function applyHeadshot(icon: ImageLabel, userId: number)
	icon.Image = headshotUrl(userId)
	icon.ImageTransparency = 0
	task.spawn(function()
		local ok, content, _ready = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and typeof(content) == "string" and content ~= "" and icon.Parent then
			icon.Image = content
		end
	end)
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

local function rainbowColorAt(phase: number): ColorSequence
	local keys = table.create(7)
	for i = 0, 6 do
		local t = i / 6
		local hue = (t + phase) % 1
		keys[i + 1] = ColorSequenceKeypoint.new(t, Color3.fromHSV(hue, 0.92, 1))
	end
	return ColorSequence.new(keys)
end

local function applyRainbowToTrack(track: Frame): UIGradient?
	for _, ch in track:GetChildren() do
		if ch:IsA("UIGradient") then
			ch:Destroy()
		end
	end
	-- HSV rainbow so scroll never snaps to a red fill / hard Offset wrap.
	local grad = Instance.new("UIGradient")
	grad.Name = "Rainbow"
	grad.Enabled = true
	grad.Rotation = 0
	grad.Offset = Vector2.zero
	grad.Color = rainbowColorAt(0)
	grad.Parent = track
	return grad
end

local function landXDim(index: number): UDim
	-- Track is Size (1, -14) on the plate. Base (0) … lands … Other World (11).
	local pad = 7
	local t = math.clamp(index, SAFEZONE_SLOT, OTHER_WORLD_SLOT) / OTHER_WORLD_SLOT
	return UDim.new(t, pad * (1 - 2 * t))
end

local function flattenXZ(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function landCenterOf(folder: Instance): Vector3?
	local minB, maxB = LandAmbushUtil.getLandBounds(folder)
	if not minB or not maxB then
		return nil
	end
	return flattenXZ((minB + maxB) * 0.5)
end

local function comingSoonCenter(): Vector3?
	local sum = Vector3.zero
	local n = 0
	for _, inst in CollectionService:GetTagged(COMING_SOON_TAG) do
		if inst:IsA("BasePart") and inst.Parent then
			sum += inst.Position
			n += 1
		end
	end
	if n == 0 then
		return nil
	end
	return flattenXZ(sum / n)
end

local function isInComingSoon(worldPos: Vector3): boolean
	for _, inst in CollectionService:GetTagged(COMING_SOON_TAG) do
		if inst:IsA("BasePart") and inst.Parent then
			local localPt = inst.CFrame:PointToObjectSpace(worldPos)
			local half = inst.Size * 0.5 + Vector3.new(6, 80, 6)
			if math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z then
				return true
			end
		end
	end
	return false
end

local function landCenter(land: number): Vector3?
	local folder = LandAmbushUtil.findLandFolder(land)
	if not folder then
		return nil
	end
	return landCenterOf(folder)
end

local cachedPath: { Vector3 }? = nil
local cachedPathAt = 0.0

local function pathWaypoints(): { Vector3 }
	if cachedPath and (os.clock() - cachedPathAt) < 1.25 then
		return cachedPath
	end
	local pts: { Vector3 } = table.create(OTHER_WORLD_SLOT + 1)
	local safe = SafezoneUtil.getSafezoneCenter()
	pts[1] = flattenXZ(if safe then safe else Vector3.zero)
	local prev = pts[1]
	for land = 1, MAX_LAND do
		local c = landCenter(land)
		pts[land + 1] = c or prev
		prev = pts[land + 1]
	end
	pts[OTHER_WORLD_SLOT + 1] = comingSoonCenter() or prev
	cachedPath = pts
	cachedPathAt = os.clock()
	return pts
end

-- Continuous 0 (Base) → 11 (Other World) along the land path, not AABB sides.
local function meterAlongPath(worldPos: Vector3): number
	local pts = pathWaypoints()
	local flat = flattenXZ(worldPos)
	local bestMeter = 0
	local bestDist = math.huge
	for i = 1, OTHER_WORLD_SLOT do
		local a = pts[i]
		local b = pts[i + 1]
		if not a or not b then
			continue
		end
		local ab = b - a
		local mag = ab.Magnitude
		local t = 0
		if mag >= 2 then
			t = math.clamp((flat - a):Dot(ab.Unit) / mag, 0, 1)
		end
		local closest = if mag >= 2 then a + ab * t else a
		local dist = (flat - closest).Magnitude
		if dist < bestDist then
			bestDist = dist
			bestMeter = (i - 1) + t
		end
	end
	return math.clamp(bestMeter, SAFEZONE_SLOT, OTHER_WORLD_SLOT)
end

local function resolveMeterForPlayer(plr: Player): (number, number)
	local character = plr.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		local cacheReady = true
		local isReady = (SafezoneUtil :: any).isCacheReady
		if typeof(isReady) == "function" then
			cacheReady = isReady() == true
		end
		if cacheReady and SafezoneUtil.isCharacterInSafezone(character) then
			local m = meterAlongPath(hrp.Position)
			return math.clamp(m, SAFEZONE_SLOT, 0.4), SAFEZONE_SLOT
		end
		if isInComingSoon(hrp.Position) then
			return OTHER_WORLD_SLOT, OTHER_WORLD_SLOT
		end
		local meter = meterAlongPath(hrp.Position)
		local discrete = math.clamp(math.floor(meter + 0.001), SAFEZONE_SLOT, OTHER_WORLD_SLOT)
		if discrete >= 1 and discrete <= MAX_LAND then
			return meter, discrete
		end
		return meter, discrete
	end
	local raw = plr:GetAttribute(LAND_ATTR)
	if typeof(raw) == "number" then
		local n = math.floor(raw)
		if n < 1 then
			return SAFEZONE_SLOT, SAFEZONE_SLOT
		end
		n = math.clamp(n, 1, MAX_LAND)
		return n, n
	end
	return SAFEZONE_SLOT, SAFEZONE_SLOT
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

local function setStripAlpha(alpha: number)
	if plateFrame then
		-- Soft fade plate — no stroke, edges fall off via UIGradient.
		plateFrame.BackgroundTransparency = 0.55 + (1 - alpha) * 0.45
	end
	local track = trackFrame or (plateFrame and plateFrame:FindFirstChild("Track"))
	if track and track:IsA("GuiObject") then
		track.BackgroundTransparency = 0.05 + (1 - alpha) * 0.95
		local stroke = track:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 0.35 + (1 - alpha) * 0.65
		end
	end
	for _, token in landTokens do
		token.BackgroundTransparency = 0.18 + (1 - alpha) * 0.82
		local stroke = token:FindFirstChildOfClass("UIStroke")
		if stroke then
			-- Keep your-land highlight brighter; others stay soft.
			local isYouLand = stroke:GetAttribute("YouLand") == true
			local baseT = if isYouLand then 0.28 else 0.78
			stroke.Transparency = baseT + (1 - alpha) * (1 - baseT)
		end
	end
	for _, peg in landTicks do
		peg.BackgroundTransparency = 0.2 + (1 - alpha) * 0.8
		local stroke = peg:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 0.75 + (1 - alpha) * 0.25
		end
	end
	for _, label in landLabels do
		label.TextTransparency = 1 - alpha
		label.TextStrokeTransparency = 0.15 + (1 - alpha) * 0.85
	end
	for _, slot in slotsByUserId do
		slot.root.Visible = alpha > 0.05
		slot.icon.ImageTransparency = 1 - alpha
		slot.ring.Transparency = 1 - alpha
		if slot.stem then
			slot.stem.BackgroundTransparency = 0.35 + (1 - alpha) * 0.65
		end
		local badge = slot.root:FindFirstChild("Badge")
		if badge and badge:IsA("GuiObject") then
			badge.BackgroundTransparency = (1 - alpha) * 0.9
		end
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
			setStripAlpha(1)
			return
		end
		stripScale.Scale = 0.78
		setStripAlpha(0)
		visibilityTween = TweenService:Create(stripScale, SHOW_TWEEN, { Scale = 1 })
		visibilityTween:Play()
		local nv = Instance.new("NumberValue")
		nv.Value = 0
		local tw = TweenService:Create(nv, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1 })
		local conn = nv.Changed:Connect(function()
			setStripAlpha(nv.Value)
		end)
		tw.Completed:Once(function()
			conn:Disconnect()
			nv:Destroy()
			setStripAlpha(1)
		end)
		tw:Play()
	else
		syncRandomBrainrot()
		if instant then
			stripRoot.Visible = false
			stripScale.Scale = 0.78
			setStripAlpha(0)
			return
		end
		visibilityTween = TweenService:Create(stripScale, HIDE_TWEEN, { Scale = 0.86 })
		visibilityTween:Play()
		local nv = Instance.new("NumberValue")
		nv.Value = 1
		local tw = TweenService:Create(nv, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 0 })
		local conn = nv.Changed:Connect(function()
			setStripAlpha(nv.Value)
		end)
		tw.Completed:Once(function()
			conn:Disconnect()
			nv:Destroy()
			setStripAlpha(0)
			if not visibleTarget and stripRoot then
				stripRoot.Visible = false
			end
		end)
		tw:Play()
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
	if slot.moveTween then
		slot.moveTween:Cancel()
		slot.moveTween = nil
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

	local size = if isMobile() then 44 else 52
	local root = Instance.new("Frame")
	root.Name = "Avatar_" .. tostring(plr.UserId)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Size = UDim2.fromOffset(size, size)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 80
	root.Active = false
	root.Parent = avatarsHost

	-- Stick/stem down to the land token.
	local stem = Instance.new("Frame")
	stem.Name = "Stem"
	stem.AnchorPoint = Vector2.new(0.5, 0)
	stem.Position = UDim2.new(0.5, 0, 1, -1)
	stem.Size = UDim2.fromOffset(3, if isMobile() then 16 else 18)
	stem.BackgroundColor3 = STEM
	stem.BackgroundTransparency = 0.35
	stem.BorderSizePixel = 0
	stem.ZIndex = 78
	stem.Parent = root
	local stemCorner = Instance.new("UICorner")
	stemCorner.CornerRadius = UDim.new(1, 0)
	stemCorner.Parent = stem

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 1, 0.5, 3)
	shadow.Size = UDim2.new(1, 6, 1, 6)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 79
	shadow.Parent = root
	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(1, 0)
	shadowCorner.Parent = shadow

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromScale(1, 1)
	badge.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	badge.BorderSizePixel = 0
	badge.ZIndex = 81
	badge.Parent = root
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge

	local ink = Instance.new("UIStroke")
	ink.Thickness = 3
	ink.Color = Color3.fromRGB(20, 24, 22)
	ink.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ink.Parent = badge

	local icon = Instance.new("ImageLabel")
	icon.Name = "Head"
	icon.BackgroundColor3 = Color3.fromRGB(40, 44, 42)
	icon.BackgroundTransparency = 0
	icon.BorderSizePixel = 0
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.88, 0.88)
	icon.Image = headshotUrl(plr.UserId)
	icon.ScaleType = Enum.ScaleType.Crop
	icon.ZIndex = 82
	icon.Active = false
	icon.Parent = badge
	applyHeadshot(icon, plr.UserId)
	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	local ring = Instance.new("UIStroke")
	ring.Thickness = if plr == player then 3.5 else 2.5
	ring.Color = if plr == player then YOU_RING else OTHER_RING
	ring.Transparency = 0
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = icon

	if plr == player then
		local pin = Instance.new("TextLabel")
		pin.Name = "YouPin"
		pin.AnchorPoint = Vector2.new(0.5, 1)
		pin.Position = UDim2.new(0.5, 0, 0, 2)
		pin.Size = UDim2.fromOffset(28, 14)
		pin.BackgroundColor3 = YOU_RING
		pin.BackgroundTransparency = 0
		pin.BorderSizePixel = 0
		pin.Text = "YOU"
		pin.TextColor3 = Color3.fromRGB(255, 255, 255)
		pin.TextSize = 9
		pin.ZIndex = 90
		UiFonts.applyBody(pin)
		pin.Parent = root
		local pinCorner = Instance.new("UICorner")
		pinCorner.CornerRadius = UDim.new(0, 6)
		pinCorner.Parent = pin
		local pinStroke = Instance.new("UIStroke")
		pinStroke.Thickness = 2
		pinStroke.Color = Color3.fromRGB(20, 24, 22)
		pinStroke.Parent = pin
	end

	local slot: AvatarSlot = {
		player = plr,
		root = root,
		icon = icon,
		ring = ring,
		stem = stem,
		land = SAFEZONE_SLOT,
		meterIndex = SAFEZONE_SLOT,
		stackIndex = 0,
		moveTween = nil,
	}
	slotsByUserId[plr.UserId] = slot
	return slot
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
	for land = SAFEZONE_SLOT, OTHER_WORLD_SLOT do
		local label = landLabels[land]
		if label and label.Parent then
			if land == SAFEZONE_SLOT then
				label.Text = SAFEZONE_LABEL
			elseif land == OTHER_WORLD_SLOT then
				label.Text = OTHER_WORLD_LABEL
			else
				label.Text = formatLandLuckLabel(land)
			end
		end
	end
end

-- Only your current land: slightly whiter / brighter token stroke (not other players).
local function refreshYouLandHighlight()
	local _, discrete = resolveMeterForPlayer(player)
	highlightedLand = discrete
	for i, token in landTokens do
		local stroke = token:FindFirstChildOfClass("UIStroke")
		if not stroke then
			continue
		end
		local isYou = i == discrete
		stroke:SetAttribute("YouLand", isYou)
		if isYou then
			stroke.Color = TOKEN_EDGE_YOU
			stroke.Thickness = 1.75
			stroke.Transparency = 0.28
		else
			stroke.Color = TOKEN_EDGE
			stroke.Thickness = 1
			stroke.Transparency = 0.78
		end
	end
end

local function cancelMove(slot: AvatarSlot)
	local tw = slot.moveTween
	if tw then
		tw:Cancel()
		slot.moveTween = nil
	end
end

local function moveSlot(slot: AvatarSlot, goal: UDim2)
	cancelMove(slot)
	if slot.player == player then
		slot.root.Position = goal
		return
	end
	local cur = slot.root.Position
	local dx = math.abs((cur.X.Scale - goal.X.Scale) * 480 + (cur.X.Offset - goal.X.Offset))
	if dx < 3 then
		slot.root.Position = goal
		return
	end
	local tw = TweenService:Create(slot.root, MOVE_TWEEN, { Position = goal })
	slot.moveTween = tw
	tw:Play()
end

-- Overlap on the track (peek behind), never stack upward.
local function layoutStacks()
	local list: { AvatarSlot } = {}
	for _, slot in slotsByUserId do
		table.insert(list, slot)
	end
	table.sort(list, function(a, b)
		if math.abs(a.meterIndex - b.meterIndex) > 1e-4 then
			return a.meterIndex < b.meterIndex
		end
		if a.player == player then
			return false
		end
		if b.player == player then
			return true
		end
		return a.player.UserId < b.player.UserId
	end)

	local i = 1
	while i <= #list do
		local j = i
		while j + 1 <= #list and math.abs(list[j + 1].meterIndex - list[j].meterIndex) <= CLUSTER_METER do
			j += 1
		end
		local clusterCount = j - i + 1
		for k = i, j do
			local slot = list[k]
			local behind = j - k
			slot.stackIndex = behind
			local xd = landXDim(slot.meterIndex)
			local peek = (if isMobile() then 11 else PEEK_PX) * behind
			local goal = UDim2.new(xd.Scale, xd.Offset - peek, 0, HEAD_Y)
			slot.root.AnchorPoint = Vector2.new(0.5, 1)
			slot.root.ZIndex = 80 + (clusterCount - behind) + (if slot.player == player then 24 else 0)
			moveSlot(slot, goal)

			if slot.player == player then
				slot.ring.Color = YOU_RING
				slot.ring.Thickness = 3.5
			else
				slot.ring.Color = OTHER_RING
				slot.ring.Thickness = 2.5
			end
			slot.ring.Transparency = 0
		end
		i = j + 1
	end
end

local function syncPlayerSlot(plr: Player)
	local meter, discrete = resolveMeterForPlayer(plr)
	local slot = ensureSlot(plr)
	if not slot then
		return
	end
	slot.meterIndex = meter
	if slot.land ~= discrete then
		slot.land = discrete
		local scale = getOrAddUIScale(slot.root)
		scale.Scale = 0.7
		TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 }):Play()
	end
	layoutStacks()
	if plr == player then
		refreshYouLandHighlight()
	end
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
	if UserInputService.TouchEnabled then
		return
	end
	pulseToken += 1
	local token = pulseToken
	task.spawn(function()
		while token == pulseToken do
			local slot = slotsByUserId[player.UserId]
			if slot and slot.root.Parent and visibleTarget then
				local scale = getOrAddUIScale(slot.root)
				TweenService:Create(scale, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1.12,
				}):Play()
				task.wait(0.55)
				if token ~= pulseToken then
					break
				end
				TweenService:Create(scale, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Scale = 1,
				}):Play()
				task.wait(0.55)
			else
				task.wait(0.4)
			end
		end
	end)
end

local function buildStrip(parentGui: PlayerGui)
	local compact = isMobile()
	local plateH = if compact then 36 else 40
	local height = if compact then 94 else 104
	local widthScale = if compact then 0.9 else 0.68

	local gui = Instance.new("ScreenGui")
	gui.Name = "LandActivityStripGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 18
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true
	gui.Parent = parentGui
	stripGui = gui

	local root = Instance.new("Frame")
	root.Name = "LandActivityStrip"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, if compact then -4 else -6)
	root.Size = UDim2.new(widthScale, 0, 0, height)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.ZIndex = 40
	root.ClipsDescendants = false
	root.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 0.78
	scale.Parent = root

	-- Soft transparent plate — no stroke; horizontal fade so edges dissolve.
	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 1)
	plate.Position = UDim2.new(0.5, 0, 1, 0)
	plate.Size = UDim2.new(1, 0, 0, plateH)
	plate.BackgroundColor3 = PLATE
	plate.BackgroundTransparency = 0.55
	plate.BorderSizePixel = 0
	plate.ZIndex = 40
	plate.ClipsDescendants = false
	plate.Parent = root
	plateFrame = plate

	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(1, 0)
	plateCorner.Parent = plate

	local plateFade = Instance.new("UIGradient")
	plateFade.Name = "EdgeFade"
	plateFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.92),
		NumberSequenceKeypoint.new(0.12, 0.35),
		NumberSequenceKeypoint.new(0.5, 0.15),
		NumberSequenceKeypoint.new(0.88, 0.35),
		NumberSequenceKeypoint.new(1, 0.92),
	})
	plateFade.Parent = plate

	-- Rainbow track with a real visible border.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.34)
	track.Size = UDim2.new(1, -14, 0, if compact then 12 else 14)
	track.BackgroundColor3 = TRACK
	track.BackgroundTransparency = 0.05
	track.BorderSizePixel = 0
	track.ZIndex = 43
	track.Parent = plate
	trackFrame = track
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = Color3.fromRGB(255, 255, 255)
	trackStroke.Thickness = 1.75
	trackStroke.Transparency = 0.35
	trackStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	trackStroke.Parent = track
	trackRainbow = applyRainbowToTrack(track)

	-- Dotted stud wash over the rainbow (same stud tile as Tim Cheese UI).
	local studs = Instance.new("ImageLabel")
	studs.Name = "StudOverlay"
	studs.BackgroundTransparency = 1
	studs.BorderSizePixel = 0
	studs.Size = UDim2.fromScale(1, 1)
	studs.Position = UDim2.fromScale(0, 0)
	studs.Image = STUD_TEX
	studs.ImageColor3 = Color3.fromRGB(255, 255, 255)
	studs.ImageTransparency = 0.55
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(12, 12)
	studs.ZIndex = 44
	studs.Parent = track
	local studCorner = Instance.new("UICorner")
	studCorner.CornerRadius = UDim.new(1, 0)
	studCorner.Parent = studs

	local tokensHost = Instance.new("Frame")
	tokensHost.Name = "Tokens"
	tokensHost.BackgroundTransparency = 1
	tokensHost.Size = UDim2.fromScale(1, 1)
	tokensHost.ZIndex = 50
	tokensHost.Parent = plate

	table.clear(landTicks)
	table.clear(landLabels)
	table.clear(landTokens)
	for land = SAFEZONE_SLOT, OTHER_WORLD_SLOT do
		local xd = landXDim(land)
		local isNamedChip = land == SAFEZONE_SLOT or land == OTHER_WORLD_SLOT

		local peg = Instance.new("Frame")
		peg.Name = "Peg" .. tostring(land)
		peg.AnchorPoint = Vector2.new(0.5, 0.5)
		peg.Position = UDim2.new(xd.Scale, xd.Offset, 0.34, 0)
		peg.Size = UDim2.fromOffset(7, 7)
		peg.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		peg.BackgroundTransparency = 0.15
		peg.BorderSizePixel = 0
		peg.ZIndex = 51
		peg.Parent = tokensHost
		local pegCorner = Instance.new("UICorner")
		pegCorner.CornerRadius = UDim.new(1, 0)
		pegCorner.Parent = peg
		local pegStroke = Instance.new("UIStroke")
		pegStroke.Color = Color3.fromRGB(255, 255, 255)
		pegStroke.Thickness = 1
		pegStroke.Transparency = 0.75
		pegStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		pegStroke.Parent = peg
		landTicks[land] = peg

		local token = Instance.new("Frame")
		token.Name = "Token" .. tostring(land)
		token.AnchorPoint = Vector2.new(0.5, 0)
		token.Position = UDim2.new(xd.Scale, xd.Offset, 0.54, 0)
		local chipW = if compact then 40 else 44
		if land == OTHER_WORLD_SLOT then
			chipW = if compact then 62 else 74
		elseif land == SAFEZONE_SLOT then
			chipW = if compact then 52 else 58
		end
		token.Size = UDim2.fromOffset(chipW, if compact then 17 else 18)
		token.BackgroundColor3 = TOKEN
		token.BackgroundTransparency = 0.18
		token.BorderSizePixel = 0
		token.ZIndex = 52
		token.Parent = tokensHost
		local tokenCorner = Instance.new("UICorner")
		tokenCorner.CornerRadius = UDim.new(0, 7)
		tokenCorner.Parent = token
		local tokenStroke = Instance.new("UIStroke")
		tokenStroke.Color = TOKEN_EDGE
		tokenStroke.Thickness = 1
		tokenStroke.Transparency = 0.78
		tokenStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		tokenStroke.Parent = token
		landTokens[land] = token

		local label = Instance.new("TextLabel")
		label.Name = "L" .. tostring(land)
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(1, 1)
		if land == SAFEZONE_SLOT then
			label.Text = SAFEZONE_LABEL
		elseif land == OTHER_WORLD_SLOT then
			label.Text = OTHER_WORLD_LABEL
		else
			label.Text = formatLandLuckLabel(land)
		end
		label.TextColor3 = TOKEN_FACE
		label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		label.TextStrokeTransparency = 0.15
		label.TextSize = if isNamedChip then (if compact then 8 else 9) else (if compact then 11 else 12)
		label.TextScaled = true
		label.TextTruncate = Enum.TextTruncate.None
		label.ZIndex = 53
		UiFonts.applyBody(label)
		UiFonts.ensureTextSizeConstraint(
			label,
			if isNamedChip then 9 else 12,
			if compact then 7 else 8
		)
		label.Parent = token
		landLabels[land] = label
	end
	refreshYouLandHighlight()

	local avatars = Instance.new("Frame")
	avatars.Name = "Avatars"
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.fromScale(1, 1)
	avatars.ZIndex = 80
	avatars.ClipsDescendants = false
	avatars.Parent = plate

	stripRoot = root
	stripScale = scale
	avatarsHost = avatars

	if bobConn then
		bobConn:Disconnect()
	end
	-- Phones: skip per-frame ColorSequence rebuilds (layout + GPU). Desktop: 8 Hz.
	if UserInputService.TouchEnabled then
		return
	end
	local bobAccum = 0.0
	bobConn = RunService.Heartbeat:Connect(function(dt)
		if not visibleTarget or not stripRoot then
			return
		end
		bobAccum += dt
		if bobAccum < 0.12 then
			return
		end
		bobAccum = 0
		bobPhase += 0.12
		stripRoot.Rotation = math.sin(bobPhase * 0.55) * 0.35
		local grad = trackRainbow
		if grad and grad.Parent then
			grad.Offset = Vector2.new(math.sin(bobPhase * 0.18) * 0.4, 0)
		end
	end)

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
			refreshYouLandHighlight()
		end
	end)
end

return LandActivityStripController
