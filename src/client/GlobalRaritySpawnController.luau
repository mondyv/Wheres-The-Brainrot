-- [ACTIVE] GlobalRaritySpawnController
--[[
	Map spawn timer SurfaceGui sync, global bush markers, and spawn notifications.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GlobalRaritySpawnConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GlobalRaritySpawnConfig"))
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer
local C = GlobalRaritySpawnConfig

local GlobalRaritySpawnController = {}

type MarkerState = {
	bushKey: string,
	highlight: Highlight,
	billboard: BillboardGui,
	timerLabel: TextLabel,
	conns: { RBXScriptConnection },
}

local timerLabels: { [string]: TextLabel } = {}
local activeMarker: MarkerState? = nil
local tickerConn: RBXScriptConnection? = nil

local RaritySpawnStyle = require(script.Parent:WaitForChild("RaritySpawnStyle"))

local function pulseColor(rarity: string): Color3
	return RaritySpawnStyle.accentColor(rarity)
end

local function formatRowLabel(tier: GlobalRaritySpawnConfig.TierDef, remaining: number): string
	return string.format("%s Spawning in %s", tier.displayName, C.formatCountdown(remaining))
end

local function findTimerLabels()
	local map = Workspace:FindFirstChild("Map")
	local timersRoot = map and map:FindFirstChild("SpawnTimers")
	local guiPart = timersRoot and timersRoot:FindFirstChild("GUIPart")
	local surface = guiPart and guiPart:FindFirstChild("SurfaceGui")
	local timers = surface and surface:FindFirstChild("Timers")
	if not timers then
		return
	end

	for _, tier in C.TIERS do
		local row = timers:FindFirstChild(tier.timerRowName)
		if not row then
			continue
		end
		local timeLabel = row:FindFirstChild("Time", true)
		if timeLabel and timeLabel:IsA("TextLabel") then
			timerLabels[tier.id] = timeLabel
			RaritySpawnStyle.applyTextGradient(timeLabel, tier.id)
		end
	end
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
		label.Text = formatRowLabel(tier, remaining)
	end
end

local function findBushByKey(key: string): Instance?
	local map = Workspace:FindFirstChild("Map")
	if not map or key == "" then
		return nil
	end
	for _, desc in map:GetDescendants() do
		if desc:GetAttribute(C.BUSH_GLOBAL_KEY_ATTR) == key then
			return desc
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
	if activeMarker.highlight.Parent then
		activeMarker.highlight:Destroy()
	end
	if activeMarker.billboard.Parent then
		activeMarker.billboard:Destroy()
	end
	activeMarker = nil
end

local function buildMarkerUi(bush: Instance, rarity: string, iconImage: string, brainrotName: string): (BillboardGui, TextLabel)
	local color = pulseColor(rarity)

	local bb = Instance.new("BillboardGui")
	bb.Name = "GlobalRaritySpawnMarker"
	bb.Size = UDim2.fromOffset(150, 168)
	bb.StudsOffset = Vector3.new(0, 7, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000

	-- Card panel; outline tinted to the rarity.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.fromScale(0.5, 0)
	panel.Size = UDim2.fromOffset(132, 132)
	panel.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = bb

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 14)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = color
	panelStroke.Thickness = 3
	panelStroke.Parent = panel

	local panelGrad = Instance.new("UIGradient")
	panelGrad.Color = RaritySpawnStyle.colorSequence(rarity)
	panelGrad.Rotation = 90
	panelGrad.Parent = panelStroke

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0.06)
	icon.Size = UDim2.fromScale(0.74, 0.74)
	icon.ScaleType = Enum.ScaleType.Fit
	if iconImage ~= "" then
		icon.Image = iconImage
		icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	else
		icon.Image = "rbxassetid://6031075938"
		icon.ImageColor3 = color
	end
	icon.Parent = panel

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "BrainrotName"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.fromScale(0.5, 0.99)
	nameLabel.Size = UDim2.new(1, -10, 0, 22)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.Text = if brainrotName ~= "" then brainrotName else "???"
	nameLabel.Parent = panel
	RaritySpawnStyle.applyTextGradient(nameLabel, rarity)

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 1.5
	nameStroke.Transparency = 0.25
	nameStroke.Parent = nameLabel

	-- Countdown pill below the card.
	local ring = Instance.new("Frame")
	ring.Name = "TimerRing"
	ring.AnchorPoint = Vector2.new(0.5, 0)
	ring.Position = UDim2.new(0.5, 0, 0, 134)
	ring.Size = UDim2.fromOffset(72, 24)
	ring.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	ring.BackgroundTransparency = 0.1
	ring.BorderSizePixel = 0
	ring.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = ring

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 1.5
	stroke.Parent = ring

	local timer = Instance.new("TextLabel")
	timer.Name = "Time"
	timer.Size = UDim2.fromScale(1, 1)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.GothamBold
	timer.TextSize = 15
	timer.TextColor3 = Color3.fromRGB(255, 255, 255)
	timer.Text = "60s"
	timer.Parent = ring

	return bb, timer
end

local function trackMarker(bushKey: string, rarity: string, endsAt: number)
	destroyMarker()
	local bush = findBushByKey(bushKey)
	if not bush then
		return
	end
	local adornee = adorneeForBush(bush)
	if not adornee then
		return
	end

	local iconImage = ReplicatedStorage:GetAttribute(C.ACTIVE_ICON_ATTR)
	local brainrotName = ReplicatedStorage:GetAttribute(C.ACTIVE_NAME_ATTR)

	local color = pulseColor(rarity)
	local hl = Instance.new("Highlight")
	hl.Name = "GlobalSpawnOutline"
	hl.Adornee = bush
	hl.FillColor = color
	hl.FillTransparency = 0.8
	hl.OutlineTransparency = 0
	hl.OutlineColor = color
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = Workspace.CurrentCamera

	local bb, timerLabel = buildMarkerUi(
		bush,
		rarity,
		if typeof(iconImage) == "string" then iconImage else "",
		if typeof(brainrotName) == "string" then brainrotName else ""
	)
	bb.Adornee = adornee
	bb.Parent = player:FindFirstChild("PlayerGui") or Workspace.CurrentCamera

	local state: MarkerState = {
		bushKey = bushKey,
		highlight = hl,
		billboard = bb,
		timerLabel = timerLabel,
		conns = {},
	}
	activeMarker = state

	table.insert(
		state.conns,
		RunService.Heartbeat:Connect(function()
			if not bush.Parent then
				destroyMarker()
				return
			end
			local remaining = math.max(0, endsAt - os.time())
			timerLabel.Text = string.format("%ds", math.ceil(remaining))
			local urgency = 1 - math.clamp(remaining / C.MARKER_DURATION_SEC, 0, 1)
			hl.OutlineTransparency = urgency * 0.35
			if remaining <= 0 then
				destroyMarker()
			end
		end)
	)
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
	TopNotifController.showRaritySpawn(message, rarityId)

	local bushKey = ReplicatedStorage:GetAttribute(C.ACTIVE_BUSH_KEY_ATTR)
	local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
	if typeof(bushKey) == "string" and typeof(endsAt) == "number" then
		trackMarker(bushKey, rarityId, endsAt)
	end
end

local function syncFromAttributes()
	local bushKey = ReplicatedStorage:GetAttribute(C.ACTIVE_BUSH_KEY_ATTR)
	local rarity = ReplicatedStorage:GetAttribute(C.ACTIVE_RARITY_ATTR)
	local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
	if typeof(bushKey) == "string" and typeof(rarity) == "string" and typeof(endsAt) == "number" and os.time() < endsAt then
		trackMarker(bushKey, rarity, endsAt)
	else
		destroyMarker()
	end
end

local function ensureTicker()
	if tickerConn then
		return
	end
	tickerConn = RunService.Heartbeat:Connect(function()
		refreshTimerLabels()
	end)
end

function GlobalRaritySpawnController.init()
	TopNotifController.init()
	findTimerLabels()
	refreshTimerLabels()
	ensureTicker()
	syncFromAttributes()

	for _, tier in C.TIERS do
		ReplicatedStorage:GetAttributeChangedSignal(C.timerAttrForTier(tier.id)):Connect(refreshTimerLabels)
	end
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_BUSH_KEY_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_ENDS_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_RARITY_ATTR):Connect(syncFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(C.ACTIVE_ICON_ATTR):Connect(syncFromAttributes)

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
