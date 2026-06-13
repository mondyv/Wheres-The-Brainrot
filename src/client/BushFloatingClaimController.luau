-- [ACTIVE] BushFloatingClaimController
--[[
	Client polish for floating bush brainrot offers: pulse highlight, countdown ring,
	and vanish poof when the player misses the catch window.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer

local FLOAT_ENDS_AT_ATTR = "BrainrotFloatEndsAt"
local FLOATING_PHASE = "Floating"
local OWNER_ATTR = "OwnerUserId"

local BushFloatingClaimController = {}

type TrackedOffer = {
	model: Model,
	highlight: Highlight,
	billboard: BillboardGui,
	timeLabel: TextLabel,
	ring: Frame,
	conns: { RBXScriptConnection },
}

local tracked: { [Model]: TrackedOffer } = {}
local tickerConn: RBXScriptConnection? = nil

local RARITY_PULSE: { [string]: Color3 } = {
	common = Color3.fromRGB(180, 220, 180),
	uncommon = Color3.fromRGB(120, 255, 150),
	rare = Color3.fromRGB(90, 170, 255),
	epic = Color3.fromRGB(200, 120, 255),
	mythic = Color3.fromRGB(255, 120, 220),
	legendary = Color3.fromRGB(255, 210, 80),
	["brainrot god"] = Color3.fromRGB(255, 90, 90),
	secret = Color3.fromRGB(255, 70, 70),
}

local function pulseColorForRarity(rarity: string?): Color3
	if typeof(rarity) == "string" then
		local key = string.lower(rarity)
		if RARITY_PULSE[key] then
			return RARITY_PULSE[key]
		end
		return BrainrotHeaderStyle.rarityAccentColor(key)
	end
	return Color3.fromRGB(120, 255, 160)
end

local function adorneeFor(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function disconnectTracked(entry: TrackedOffer)
	for _, conn in entry.conns do
		conn:Disconnect()
	end
	table.clear(entry.conns)
	if entry.highlight.Parent then
		entry.highlight:Destroy()
	end
	if entry.billboard.Parent then
		entry.billboard:Destroy()
	end
end

local function untrack(model: Model)
	local entry = tracked[model]
	if not entry then
		return
	end
	disconnectTracked(entry)
	tracked[model] = nil
end

local function ensureTicker()
	if tickerConn then
		return
	end
	tickerConn = RunService.Heartbeat:Connect(function()
		if next(tracked) == nil then
			if tickerConn then
				tickerConn:Disconnect()
				tickerConn = nil
			end
			return
		end

		local now = Workspace:GetServerTimeNow()
		for model, entry in tracked do
			if not model.Parent then
				untrack(model)
				continue
			end
			local endsAt = model:GetAttribute(FLOAT_ENDS_AT_ATTR)
			if typeof(endsAt) ~= "number" then
				continue
			end
			local remaining = math.max(0, endsAt - now)
			entry.timeLabel.Text = string.format("%.1fs", remaining)
			local frac = math.clamp(remaining / 15, 0, 1)
			entry.ring.Size = UDim2.fromScale(frac, 1)
			local urgency = 1 - frac
			entry.highlight.OutlineTransparency = 0.05 + urgency * 0.25
			if urgency > 0.65 then
				local flash = 0.5 + math.sin(now * 14) * 0.5
				entry.timeLabel.TextColor3 = Color3.fromRGB(255, math.floor(120 + flash * 135), 90)
			else
				entry.timeLabel.TextColor3 = Color3.fromRGB(235, 255, 240)
			end
		end
	end)
end

local function buildTimerUi(model: Model): (BillboardGui, TextLabel, Frame)
	local bb = Instance.new("BillboardGui")
	bb.Name = "FloatingClaimTimer"
	bb.Size = UDim2.fromOffset(92, 28)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 80

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = Color3.fromRGB(10, 14, 12)
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Color3.fromRGB(120, 255, 170)
	stroke.Parent = panel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 6, 1, -5)
	track.Size = UDim2.new(1, -12, 0, 5)
	track.BackgroundColor3 = Color3.fromRGB(24, 32, 28)
	track.BorderSizePixel = 0
	track.Parent = panel

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local ring = Instance.new("Frame")
	ring.Name = "Fill"
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundColor3 = Color3.fromRGB(90, 255, 150)
	ring.BorderSizePixel = 0
	ring.Parent = track

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring

	local label = Instance.new("TextLabel")
	label.Name = "Time"
	label.Size = UDim2.new(1, -8, 0, 16)
	label.Position = UDim2.fromOffset(4, 3)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(235, 255, 240)
	label.Text = "15.0s"
	label.Parent = panel

	return bb, label, ring
end

local function trackModel(model: Model)
	if tracked[model] then
		return
	end
	if model:GetAttribute(OWNER_ATTR) ~= player.UserId then
		return
	end
	if model:GetAttribute("BrainrotCarryPhase") ~= FLOATING_PHASE then
		return
	end

	local adornee = adorneeFor(model)
	if not adornee then
		return
	end

	local rarity = model:GetAttribute("BrainrotRarity")
	local color = pulseColorForRarity(if typeof(rarity) == "string" then rarity else nil)

	local hl = Instance.new("Highlight")
	hl.Name = "FloatingClaimHighlight"
	hl.Adornee = model
	hl.FillTransparency = 0.82
	hl.OutlineTransparency = 0.05
	hl.OutlineColor = color
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = workspace.CurrentCamera

	local bb, label, ring = buildTimerUi(model)
	bb.Adornee = adornee
	bb.Parent = player:FindFirstChild("PlayerGui") or workspace.CurrentCamera

	local entry: TrackedOffer = {
		model = model,
		highlight = hl,
		billboard = bb,
		timeLabel = label,
		ring = ring,
		conns = {},
	}
	tracked[model] = entry

	table.insert(
		entry.conns,
		model:GetAttributeChangedSignal("BrainrotCarryPhase"):Connect(function()
			local phase = model:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" then
				GameSoundEffects.playProximityPromptAppear()
				untrack(model)
			elseif phase ~= FLOATING_PHASE then
				untrack(model)
			end
		end)
	)

	table.insert(
		entry.conns,
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				untrack(model)
			end
		end)
	)

	ensureTicker()
end

local function scanRoot(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("Model") and desc:GetAttribute("BrainrotCarryPhase") == FLOATING_PHASE then
			trackModel(desc)
		end
	end
end

local function spawnVanishBurst(worldPos: Vector3, rarity: string)
	local anchor = Instance.new("Part")
	anchor.Name = "FloatingClaimVanishFX"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(worldPos)
	anchor.Parent = Workspace

	local color = pulseColorForRarity(rarity)

	for i = 1, 10 do
		local p = Instance.new("Part")
		p.Name = "Spark"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Size = Vector3.new(0.25, 0.25, 0.25)
		p.Color = color
		p.Material = Enum.Material.Neon
		p.CFrame = anchor.CFrame
		p.Parent = anchor

		local offset = Vector3.new(math.random() - 0.5, math.random() * 0.5, math.random() - 0.5).Unit
			* (1.5 + math.random() * 2)
		TweenService:Create(p, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(worldPos + offset),
			Transparency = 1,
			Size = Vector3.new(0.05, 0.05, 0.05),
		}):Play()
	end

	task.delay(0.5, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

function BushFloatingClaimController.init()
	scanRoot(Workspace)

	Workspace.DescendantAdded:Connect(function(desc)
		if desc:IsA("Model") then
			task.defer(function()
				trackModel(desc)
			end)
		end
	end)

	local folder = ReplicatedStorage:WaitForChild("BushRemotes", 60)
	if folder then
		local vanish = folder:WaitForChild("FloatingClaimVanish", 60)
		if vanish and vanish:IsA("RemoteEvent") then
			vanish.OnClientEvent:Connect(function(worldPos: any, rarity: any)
				if typeof(worldPos) ~= "Vector3" then
					return
				end
				spawnVanishBurst(worldPos, if typeof(rarity) == "string" then rarity else "common")
				GameSoundEffects.playErrorNotif()
			end)
		end
	end
end

return BushFloatingClaimController
