-- [ACTIVE] GlobalRaritySpawnController
--[[
	Map spawn timer SurfaceGui sync, global bush markers, and spawn notifications.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GlobalRaritySpawnConfig =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GlobalRaritySpawnConfig"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local TopNotifController = require(script.Parent.TopNotifController)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer
local C = GlobalRaritySpawnConfig

local GlobalRaritySpawnController = {}

type MarkerState = {
	bushKey: string,
	billboard: BillboardGui,
	timerLabel: TextLabel,
	conns: { RBXScriptConnection },
	bush: Instance?,
	highlight: Highlight?,
	anchor: BasePart?,
}

local timerLabels: { [string]: TextLabel } = {}
local activeMarker: MarkerState? = nil
local tickerConn: RBXScriptConnection? = nil

local RaritySpawnStyle = require(script.Parent:WaitForChild("RaritySpawnStyle"))

local PLACEHOLDER_ICON = "rbxasset://textures/ui/GuiImagePlaceholder.png"
local OUTLINE_RANGE = 42
local OUTLINE_RANGE_SQ = OUTLINE_RANGE * OUTLINE_RANGE
local PROXIMITY_TICK = 0.12
local proximityAccum = 0

local function pulseColor(rarity: string): Color3
	return RaritySpawnStyle.accentColor(rarity)
end

local function resolveSpawnIcon(iconAttr: any, brainrotName: any): string
	if typeof(iconAttr) == "string" and iconAttr ~= "" then
		return iconAttr
	end
	if typeof(brainrotName) == "string" and brainrotName ~= "" then
		return BrainrotsConfig:GetIcon(brainrotName, "normal")
	end
	return PLACEHOLDER_ICON
end

local function updateMarkerIcon(icon: ImageLabel, _iconImage: string, rarity: string)
	if _iconImage ~= "" then
		icon.Image = _iconImage
		icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	else
		icon.Image = PLACEHOLDER_ICON
		icon.ImageColor3 = pulseColor(rarity)
	end
end

-- Studio hierarchy (Secret differs): Timers.<Row>/Time is sometimes a Frame
-- with a nested TextLabel (e.g. Secret.Time.Secret2), not a TextLabel itself.
local TITLE_CANDIDATES: { [string]: { string } } = {
	mythic = { "Mythical" },
	legendary = { "Legendary" },
	["brainrot god"] = { "Godly", "BrainrotGod" },
	secret = { "Secret1", "Secret" },
}

local function resolveTimeLabel(row: Instance): TextLabel?
	local timeNode = row:FindFirstChild("Time") or row:FindFirstChild("Time", true)
	if not timeNode then
		return nil
	end
	if timeNode:IsA("TextLabel") then
		return timeNode
	end
	for _, name in { "Secret2", "Time", "Label", "Text", "Countdown" } do
		local child = timeNode:FindFirstChild(name)
		if child and child:IsA("TextLabel") then
			return child
		end
	end
	local nested = timeNode:FindFirstChildWhichIsA("TextLabel", true)
	if nested then
		return nested
	end
	-- Secret board also nests text under UIStroke in Studio.
	local stroke = row:FindFirstChild("UIStroke")
	if stroke then
		local underStroke = stroke:FindFirstChildWhichIsA("TextLabel", true)
		if underStroke then
			return underStroke
		end
	end
	return nil
end

-- Hide Studio title labels — the Time row carries the full "Mythical Spawning in …" string.
local function hideTitleLabels(row: Instance, tier: GlobalRaritySpawnConfig.TierDef)
	local names = TITLE_CANDIDATES[tier.id]
	if not names then
		return
	end
	for _, name in names do
		local title = row:FindFirstChild(name)
		if title and title:IsA("TextLabel") then
			title.Text = ""
			title.Visible = false
		end
	end
end

local function formatRowLabel(tier: GlobalRaritySpawnConfig.TierDef, remaining: number): string
	return string.format("%s Spawning in %s", tier.displayName, C.formatCountdown(remaining))
end

local function findTimerLabels(): number
	local map = Workspace:FindFirstChild("Map")
	local timersRoot = map and map:FindFirstChild("SpawnTimers")
	local guiPart = timersRoot and timersRoot:FindFirstChild("GUIPart")
	local surface = guiPart and guiPart:FindFirstChild("SurfaceGui")
	local timers = surface and surface:FindFirstChild("Timers")
	if not timers then
		return 0
	end

	local bound = 0
	for _, tier in C.TIERS do
		local row: Instance? = nil
		local aliases = tier.timerRowAliases or { tier.timerRowName }
		for _, name in aliases do
			row = timers:FindFirstChild(name)
			if row then
				break
			end
		end
		if not row then
			continue
		end
		hideTitleLabels(row, tier)
		local timeLabel = resolveTimeLabel(row)
		if timeLabel then
			timerLabels[tier.id] = timeLabel
			bound += 1
		end
	end
	return bound
end

local function refreshTimerLabels()
	local now = os.time()
	for _, tier in C.TIERS do
		local label = timerLabels[tier.id]
		if not label then
			continue
		end
		local endsAt = ReplicatedStorage:GetAttribute(C.timerAttrForTier(tier.id))
		local remaining = if typeof(endsAt) == "number" then math.max(0, endsAt - now) else tier.intervalSec
		label.Visible = true
		label.Text = formatRowLabel(tier, remaining)
	end
end

local cachedBushByKey: { [string]: Instance } = {}

local function findBushByKey(key: string): Instance?
	if key == "" then
		return nil
	end
	local hit = cachedBushByKey[key]
	if hit and hit.Parent then
		return hit
	end
	cachedBushByKey[key] = nil

	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local stack = { map }
	local count = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst:GetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR) == true and inst:GetAttribute(C.BUSH_GLOBAL_KEY_ATTR) == key then
			cachedBushByKey[key] = inst
			return inst
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		count += 1
		if count % 500 == 0 then
			task.wait(0.1)
		end
	end
	return nil
end

local function adorneeForBush(bush: Instance): BasePart?
	if bush:IsA("BasePart") then
		return bush
	end
	if bush:IsA("Model") then
		if bush.PrimaryPart then
			return bush.PrimaryPart
		end
		return bush:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function destroyMarker()
	if not activeMarker then
		return
	end
	for _, conn in activeMarker.conns do
		conn:Disconnect()
	end
	if activeMarker.highlight then
		activeMarker.highlight:Destroy()
	end
	if activeMarker.billboard.Parent then
		activeMarker.billboard:Destroy()
	end
	if activeMarker.anchor and activeMarker.anchor.Parent then
		activeMarker.anchor:Destroy()
	end
	activeMarker = nil
end

local function readActivePos(): Vector3?
	local attr = ReplicatedStorage:GetAttribute(C.ACTIVE_POS_ATTR)
	if typeof(attr) == "Vector3" then
		return attr
	end
	return nil
end

local function ensureAnchor(pos: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "GlobalRaritySpawnAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.Position = pos
	part.Parent = Workspace
	return part
end

local function bushWorldPos(bush: Instance): Vector3?
	if bush:IsA("BasePart") then
		return bush.Position
	end
	if bush:IsA("Model") then
		local ok, pivot = pcall(function()
			return (bush :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return (pivot :: CFrame).Position
		end
	end
	local part = bush:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function ensureOutlineHighlight(state: MarkerState, rarity: string): Highlight?
	local bush = state.bush
	if not bush or not bush.Parent then
		return nil
	end
	local hl = state.highlight
	if not hl or not hl.Parent then
		hl = Instance.new("Highlight")
		hl.Name = "GlobalRaritySpawnOutline"
		hl.FillTransparency = 1
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Enabled = false
		hl.Parent = Workspace.CurrentCamera or bush
		state.highlight = hl
	end
	hl.Adornee = bush
	hl.OutlineColor = pulseColor(rarity)
	return hl
end

local function updateProximityOutline(dt: number)
	proximityAccum += dt
	if proximityAccum < PROXIMITY_TICK then
		return
	end
	proximityAccum = 0

	local state = activeMarker
	if not state then
		return
	end
	local bush = state.bush
	local rarity = ReplicatedStorage:GetAttribute(C.ACTIVE_RARITY_ATTR)
	if not bush or not bush.Parent or typeof(rarity) ~= "string" then
		if state.highlight then
			state.highlight.Enabled = false
		end
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hl = ensureOutlineHighlight(state, rarity)
	if not hl or not hrp or not hrp:IsA("BasePart") then
		if hl then
			hl.Enabled = false
		end
		return
	end

	local pos = bushWorldPos(bush)
	if not pos then
		hl.Enabled = false
		return
	end
	local delta = pos - hrp.Position
	local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
	hl.Enabled = distSq <= OUTLINE_RANGE_SQ
end

local function addBlackStroke(parent: Instance, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = thickness
	stroke.Parent = parent
	return stroke
end

local function buildMarkerUi(rarity: string, _iconImage: string, brainrotName: string): (BillboardGui, TextLabel)
	local tier = C.tierById(rarity)
	local rarityLabel = if tier then tier.displayName else string.upper(rarity)

	local bb = Instance.new("BillboardGui")
	bb.Name = "GlobalRaritySpawnMarker"
	bb.Size = UDim2.fromOffset(132, 168)
	bb.StudsOffset = Vector3.new(0, 16, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 100000

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = bb

	local rarityText = Instance.new("TextLabel")
	rarityText.Name = "Rarity"
	rarityText.LayoutOrder = 1
	rarityText.Size = UDim2.fromOffset(128, 22)
	rarityText.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(rarityText, 16, 11)
	rarityText.Text = rarityLabel
	rarityText.TextColor3 = Color3.fromRGB(255, 255, 255)
	rarityText.Parent = bb
	RaritySpawnStyle.applyTextGradient(rarityText, rarity)
	addBlackStroke(rarityText, 1.5)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.LayoutOrder = 2
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(72, 72)
	icon.ScaleType = Enum.ScaleType.Fit
	updateMarkerIcon(icon, _iconImage, rarity)
	icon.Parent = bb

	local nameText = Instance.new("TextLabel")
	nameText.Name = "BrainrotName"
	nameText.LayoutOrder = 3
	nameText.Size = UDim2.fromOffset(128, 20)
	nameText.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(nameText, 13, 10)
	nameText.Text = if brainrotName ~= "" then brainrotName else "Brainrot"
	nameText.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameText.TextTruncate = Enum.TextTruncate.AtEnd
	nameText.Parent = bb
	addBlackStroke(nameText, 1.5)

	local timer = Instance.new("TextLabel")
	timer.Name = "Time"
	timer.LayoutOrder = 4
	timer.Size = UDim2.fromOffset(128, 18)
	timer.BackgroundTransparency = 1
	UiFonts.applyDisplayLabel(timer, 13, 10)
	timer.TextColor3 = Color3.fromRGB(238, 240, 248)
	timer.Text = C.formatCountdown(C.MARKER_DURATION_SEC)
	timer.Parent = bb
	addBlackStroke(timer, 1.5)

	return bb, timer
end

local function trackMarker(bushKey: string, rarity: string, endsAt: number)
	destroyMarker()
	local pos = readActivePos()
	local bush = findBushByKey(bushKey)
	if not pos and bush then
		pos = bushWorldPos(bush)
	end

	local anchor: BasePart? = nil
	local adornee: BasePart? = nil
	if pos then
		anchor = ensureAnchor(pos)
		adornee = anchor
	elseif bush then
		adornee = adorneeForBush(bush)
	end
	if not adornee then
		return
	end

	local brainrotName = ReplicatedStorage:GetAttribute(C.ACTIVE_NAME_ATTR)
	local nameStr = if typeof(brainrotName) == "string" then brainrotName else ""
	local _iconImage = resolveSpawnIcon(ReplicatedStorage:GetAttribute(C.ACTIVE_ICON_ATTR), nameStr)

	local bb, timerLabel = buildMarkerUi(rarity, _iconImage, nameStr)
	bb.Adornee = adornee
	bb.Parent = player:FindFirstChild("PlayerGui") or Workspace.CurrentCamera

	local state: MarkerState = {
		bushKey = bushKey,
		billboard = bb,
		timerLabel = timerLabel,
		conns = {},
		bush = bush,
		highlight = nil,
		anchor = anchor,
	}
	activeMarker = state
	if bush then
		ensureOutlineHighlight(state, rarity)
	end

	table.insert(
		state.conns,
		RunService.Heartbeat:Connect(function()
			local remaining = math.max(0, endsAt - os.time())
			if remaining <= 0 then
				timerLabel.Text = ""
				destroyMarker()
				return
			end
			timerLabel.Text = C.formatCountdown(remaining)
			if not state.bush or not state.bush.Parent then
				local found = findBushByKey(bushKey)
				if found then
					state.bush = found
					local bushPos = bushWorldPos(found)
					if bushPos and state.anchor and state.anchor.Parent then
						state.anchor.Position = bushPos
					end
				end
			end
		end)
	)
end

local function trackMarkerWithRetry(bushKey: string, rarity: string, endsAt: number)
	task.spawn(function()
		local deadline = os.clock() + 45
		while os.clock() < deadline and os.time() < endsAt do
			if activeMarker and activeMarker.bushKey == bushKey then
				return
			end
			if readActivePos() or findBushByKey(bushKey) then
				trackMarker(bushKey, rarity, endsAt)
				return
			end
			task.wait(0.5)
		end
	end)
end

local function onSpawnEvent(rarityId: string?, brainrotName: string?)
	if typeof(rarityId) ~= "string" then
		return
	end
	local tier = C.tierById(rarityId)
	local message = if tier then tier.spawnMessage else string.format("A %s brainrot has spawned!", rarityId)
	if typeof(brainrotName) == "string" and brainrotName ~= "" then
		message = string.format("%s (%s)", message, brainrotName)
	end
	local _iconImage = resolveSpawnIcon(
		ReplicatedStorage:GetAttribute(C.ACTIVE_ICON_ATTR),
		ReplicatedStorage:GetAttribute(C.ACTIVE_NAME_ATTR)
	)
	local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
	TopNotifController.showRaritySpawn(message, rarityId)

	local bushKey = ReplicatedStorage:GetAttribute(C.ACTIVE_BUSH_KEY_ATTR)
	if typeof(bushKey) == "string" and typeof(endsAt) == "number" then
		trackMarkerWithRetry(bushKey, rarityId, endsAt)
	end
end

local function syncFromAttributes()
	local bushKey = ReplicatedStorage:GetAttribute(C.ACTIVE_BUSH_KEY_ATTR)
	local rarity = ReplicatedStorage:GetAttribute(C.ACTIVE_RARITY_ATTR)
	local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
	if
		typeof(bushKey) == "string"
		and typeof(rarity) == "string"
		and typeof(endsAt) == "number"
		and os.time() < endsAt
	then
		trackMarkerWithRetry(bushKey, rarity, endsAt)
	else
		destroyMarker()
	end
end

local function ensureTicker()
	if tickerConn then
		return
	end
	tickerConn = RunService.Heartbeat:Connect(function(dt)
		refreshTimerLabels()
		updateProximityOutline(dt)
		local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
		if typeof(endsAt) ~= "number" or os.time() >= endsAt then
			if activeMarker then
				destroyMarker()
			end
		end
	end)
end

function GlobalRaritySpawnController.init()
	TopNotifController.init()
	findTimerLabels()
	refreshTimerLabels()
	ensureTicker()
	syncFromAttributes()

	-- Map/SpawnTimers can stream in late — keep trying until all rows bind.
	task.spawn(function()
		for _ = 1, 45 do
			local bound = 0
			for _ in pairs(timerLabels) do
				bound += 1
			end
			if bound >= #C.TIERS then
				break
			end
			task.wait(1)
			findTimerLabels()
			refreshTimerLabels()
		end
	end)

	for _, tier in C.TIERS do
		ReplicatedStorage:GetAttributeChangedSignal(C.timerAttrForTier(tier.id)):Connect(refreshTimerLabels)
	end
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_BUSH_KEY_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_ENDS_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_RARITY_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_POS_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_ICON_ATTR):Connect(function()
		syncFromAttributes()
		if activeMarker and activeMarker.billboard.Parent then
			local iconNode = activeMarker.billboard:FindFirstChild("Icon")
			if iconNode and iconNode:IsA("ImageLabel") then
				local rarity = ReplicatedStorage:GetAttribute(C.ACTIVE_RARITY_ATTR)
				local _iconImage = resolveSpawnIcon(
					ReplicatedStorage:GetAttribute(C.ACTIVE_ICON_ATTR),
					ReplicatedStorage:GetAttribute(C.ACTIVE_NAME_ATTR)
				)
				updateMarkerIcon(iconNode, _iconImage, if typeof(rarity) == "string" then rarity else "common")
			end
		end
	end)

	local folder = ReplicatedStorage:WaitForChild(C.REMOTE_FOLDER, 60)
	if folder then
		local updated = folder:WaitForChild(C.UPDATED_REMOTE, 60)
		if updated and updated:IsA("RemoteEvent") then
			updated.OnClientEvent:Connect(function(eventKind: any, _tierId: any, rarityId: any, brainrotName: any)
				if eventKind == "spawn" then
					onSpawnEvent(rarityId, brainrotName)
				elseif eventKind == "claimed" or eventKind == "sync" then
					syncFromAttributes()
				end
			end)
		end
	end
end

return GlobalRaritySpawnController
