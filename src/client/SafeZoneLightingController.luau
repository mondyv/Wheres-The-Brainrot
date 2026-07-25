-- [ACTIVE] SafeZoneLightingController
--[[
	Outside safe zone → visible greenish Atmosphere night (smooth tween).
	Fixed physical light shafts sit permanently on the map (lands) — not
	player-follow, no SunRaysEffect.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local POLL_INTERVAL = 0.2
local ATMO_INFO = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local CC_LEGACY_NAME = "SafeZoneNightCC"
local BEAM_FOLDER_NAME = "MapGodRays"
local SUNRAYS_NAME = "SafeZoneSunRays"

-- Visible greenish night (stronger than last pass so the transition reads)
local NIGHT_ATMO = {
	Density = 0.45,
	Offset = 0.1,
	Color = Color3.fromRGB(58, 92, 64),
	Decay = Color3.fromRGB(78, 110, 70),
	Glare = 0.05,
	Haze = 1.35,
}

type AtmoSnap = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil
local dayAtmo: AtmoSnap? = nil
local beamsBuilt = false

local function cancelTweens()
	for _, tw in activeTweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeTweens)
end

local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any })
	local tw = TweenService:Create(inst, info, props)
	table.insert(activeTweens, tw)
	tw:Play()
	return tw
end

local function destroyLegacyJunk()
	local cc = Lighting:FindFirstChild(CC_LEGACY_NAME)
	if cc then
		cc:Destroy()
	end
	local rays = Lighting:FindFirstChild(SUNRAYS_NAME)
	if rays then
		rays:Destroy()
	end
	local oldFollow = Workspace:FindFirstChild("SafeZoneGodRays")
	if oldFollow then
		oldFollow:Destroy()
	end
	local veilPg = player:FindFirstChild("PlayerGui")
	local veil = veilPg and veilPg:FindFirstChild("SafeZoneSkyVeil")
	if veil then
		veil:Destroy()
	end
end

local function ensureAtmosphere(): Atmosphere
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmo then
		return atmo
	end
	atmo = Instance.new("Atmosphere")
	atmo.Density = 0.3
	atmo.Offset = 0.25
	atmo.Color = Color3.fromRGB(199, 199, 199)
	atmo.Decay = Color3.fromRGB(92, 60, 13)
	atmo.Glare = 0
	atmo.Haze = 0
	atmo.Parent = Lighting
	return atmo
end

local function readAtmo(atmo: Atmosphere): AtmoSnap
	return {
		Density = atmo.Density,
		Offset = atmo.Offset,
		Color = atmo.Color,
		Decay = atmo.Decay,
		Glare = atmo.Glare,
		Haze = atmo.Haze,
	}
end

local function snapshotDay()
	dayAtmo = readAtmo(ensureAtmosphere())
end

local function applyAtmo(snap: AtmoSnap, instant: boolean?)
	local atmo = ensureAtmosphere()
	if instant then
		atmo.Density = snap.Density
		atmo.Offset = snap.Offset
		atmo.Color = snap.Color
		atmo.Decay = snap.Decay
		atmo.Glare = snap.Glare
		atmo.Haze = snap.Haze
		return
	end
	playTween(atmo, ATMO_INFO, {
		Density = snap.Density,
		Offset = snap.Offset,
		Color = snap.Color,
		Decay = snap.Decay,
		Glare = snap.Glare,
		Haze = snap.Haze,
	})
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo then
		snapshotDay()
	end
	cancelTweens()
	local goal = if night then NIGHT_ATMO else (dayAtmo :: AtmoSnap)
	applyAtmo(goal, instant)
end

-- Fixed shafts at land positions (permanent map props)
local function createShaft(folder: Folder, name: string, top: Vector3, bottom: Vector3, width: number)
	local mid = (top + bottom) * 0.5
	local len = (top - bottom).Magnitude
	if len < 1 then
		return
	end

	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 236, 175)
	part.Transparency = 0.88
	part.Size = Vector3.new(width * 0.55, len, width * 0.55)
	part.CFrame = CFrame.lookAt(mid, bottom) * CFrame.Angles(math.rad(90), 0, 0)
	part.Parent = folder

	local att0 = Instance.new("Attachment")
	att0.Position = Vector3.new(0, len * 0.5, 0)
	att0.Parent = part

	local att1 = Instance.new("Attachment")
	att1.Position = Vector3.new(0, -len * 0.5, 0)
	att1.Parent = part

	local beam = Instance.new("Beam")
	beam.Attachment0 = att0
	beam.Attachment1 = att1
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 245, 200)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 255, 170)),
	})
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.72),
		NumberSequenceKeypoint.new(0.35, 0.55),
		NumberSequenceKeypoint.new(1, 0.95),
	})
	beam.Width0 = width
	beam.Width1 = width * 0.35
	beam.FaceCamera = true
	beam.LightEmission = 0.7
	beam.LightInfluence = 0.15
	beam.Segments = 10
	beam.Texture = "rbxasset://textures/particles/smoke_main.dds"
	beam.TextureSpeed = 0.04
	beam.TextureLength = 18
	beam.Enabled = true
	beam.Parent = part

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 235, 170)
	light.Brightness = 0.45
	light.Range = 22
	light.Shadows = false
	light.Parent = part
end

local function buildFixedGodRays()
	if beamsBuilt then
		return
	end
	beamsBuilt = true

	local existing = Workspace:FindFirstChild(BEAM_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = BEAM_FOLDER_NAME
	folder.Parent = Workspace

	local placed = 0
	for land = 1, 10 do
		local cf = LandResolver.getSpawnCFrameForLand(land)
		if not cf then
			continue
		end
		local base = cf.Position
		-- Two offset shafts per land, angled slightly, fixed forever
		for j = 1, 2 do
			local ang = (land * 0.9 + j * 1.7)
			local ox = math.cos(ang) * (10 + j * 7)
			local oz = math.sin(ang) * (10 + j * 7)
			local lean = 6 + j * 3
			local top = Vector3.new(base.X + ox, base.Y + 72, base.Z + oz)
			local bottom = Vector3.new(base.X + ox + lean * 0.35, base.Y + 1.5, base.Z + oz + lean * 0.2)
			createShaft(folder, ("Land%d_Ray%d"):format(land, j), top, bottom, 5.5 + j)
			placed += 1
		end
	end

	-- Fallback if lands aren't ready yet — retry once
	if placed == 0 then
		beamsBuilt = false
		task.delay(3, function()
			if not beamsBuilt then
				buildFixedGodRays()
			end
		end)
	end
end

local function readInSafezone(): boolean
	local char = player.Character
	if not char then
		return true
	end
	return SafezoneUtil.isCharacterInSafezone(char)
end

local function setInSafezone(nextIn: boolean, force: boolean?)
	if not force and nextIn == inSafezone then
		return
	end
	-- Refresh day snapshot while inside so return looks correct
	if nextIn and (force or inSafezone) then
		snapshotDay()
	end
	inSafezone = nextIn
	applyProfile(not nextIn, force == true)
end

function SafeZoneLightingController.init()
	if wired then
		return
	end
	wired = true

	destroyLegacyJunk()
	snapshotDay()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(12)
		-- Re-snapshot day lighting once map/lighting is settled
		if readInSafezone() then
			snapshotDay()
		end
		inSafezone = readInSafezone()
		applyProfile(not inSafezone, true)
		buildFixedGodRays()
	end)

	-- Immediate baseline so first leave still works before cache finishes
	inSafezone = readInSafezone()
	applyProfile(not inSafezone, true)

	player.CharacterAdded:Connect(function()
		task.defer(function()
			setInSafezone(readInSafezone(), true)
		end)
	end)

	local accum = 0.0
	pollConn = RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < POLL_INTERVAL then
			return
		end
		accum = 0
		setInSafezone(readInSafezone())
	end)
end

return SafeZoneLightingController
