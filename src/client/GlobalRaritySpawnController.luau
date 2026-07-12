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
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer
local C = GlobalRaritySpawnConfig

local GlobalRaritySpawnController = {}

type MarkerState = {
	bushKey: string,
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
		if remaining <= 0 then
			label.Text = ""
			label.Visible = false
		else
			label.Visible = true
			label.Text = formatRowLabel(tier, remaining)
		end
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
	local count = 0
	for _, desc in map:GetDescendants() do
		count += 1
		if count % 4000 == 0 then
			task.wait()
		end
		if desc:GetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR) == true and desc:GetAttribute(C.BUSH_GLOBAL_KEY_ATTR) == key then
			cachedBushByKey[key] = desc
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
	if activeMarker.billboard.Parent then
		activeMarker.billboard:Destroy()
	end
	activeMarker = nil
	TopNotifController.dismissActive()
end

local function addBlackStroke(parent: Instance, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = thickness
	stroke.Parent = parent
	return stroke
end

local function buildMarkerUi(rarity: string, iconImage: string): (BillboardGui, TextLabel)
	local tier = C.tierById(rarity)
	local rarityLabel = if tier then tier.displayName else string.upper(rarity)
	local color = pulseColor(rarity)

	local bb = Instance.new("BillboardGui")
	bb.Name = "GlobalRaritySpawnMarker"
	bb.Size = UDim2.fromOffset(76, 86)
	bb.StudsOffset = Vector3.new(0, 14, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000

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
	rarityText.Size = UDim2.fromOffset(76, 17)
	rarityText.BackgroundTransparency = 1
	rarityText.Font = Enum.Font.GothamBlack
	rarityText.TextSize = 14
	rarityText.Text = rarityLabel
	rarityText.TextColor3 = Color3.fromRGB(255, 255, 255)
	rarityText.Parent = bb
	RaritySpawnStyle.applyTextGradient(rarityText, rarity)
	addBlackStroke(rarityText, 1.5)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.LayoutOrder = 2
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(46, 46)
	icon.ScaleType = Enum.ScaleType.Fit
	if iconImage ~= "" then
		icon.Image = iconImage
		icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	else
		icon.Image = "rbxassetid://6031075938"
		icon.ImageColor3 = color
	end
	icon.Parent = bb

	local timer = Instance.new("TextLabel")
	timer.Name = "Time"
	timer.LayoutOrder = 3
	timer.Size = UDim2.fromOffset(76, 16)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.GothamBold
	timer.TextSize = 13
	timer.TextColor3 = Color3.fromRGB(238, 240, 248)
	timer.Text = C.formatCountdown(C.MARKER_DURATION_SEC)
	timer.Parent = bb
	addBlackStroke(timer, 1.5)

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

	local bb, timerLabel = buildMarkerUi(rarity, if typeof(iconImage) == "string" then iconImage else "")
	bb.Adornee = adornee
	bb.Parent = player:FindFirstChild("PlayerGui") or Workspace.CurrentCamera

	local state: MarkerState = {
		bushKey = bushKey,
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
			timerLabel.Text = C.formatCountdown(remaining)
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
	local endsAt = ReplicatedStorage:GetAttribute(C.ACTIVE_ENDS_ATTR)
	local lifetimeSec = if typeof(endsAt) == "number" then math.max(0, endsAt - os.time()) else nil
	TopNotifController.showRaritySpawn(message, rarityId, lifetimeSec)

	local bushKey = ReplicatedStorage:GetAttribute(C.ACTIVE_BUSH_KEY_ATTR)
	if typeof(bushKey) == "string" and typeof(endsAt) == "number" then
		trackMarker(bushKey, rarityId, endsAt)
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
		task.spawn(function()
			trackMarker(bushKey, rarity, endsAt)
		end)
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
