-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: smoky dark Atmosphere night.
	Inside: faint mist fog (based on the place day snapshot) so the base
	isn't crystal-clear at long range. Day is snapped once at boot before
	any fog/night is applied.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25
local FADE_INFO = TweenInfo.new(1.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CC_LEGACY_NAME = "SafeZoneNightCC"

-- Dark nighty fog outside safe zone (readable, not pitch black).
local NIGHT_ATMO = {
	Density = 0.36,
	Offset = 0.14,
	Color = Color3.fromRGB(62, 68, 78),
	Decay = Color3.fromRGB(72, 78, 88),
	Glare = 0.06,
	Haze = 1.55,
}

-- Low-graphics night: slightly thinner fog only (keep the same look).
local NIGHT_ATMO_LOW = {
	Density = 0.3,
	Offset = 0.16,
	Color = Color3.fromRGB(62, 68, 78),
	Decay = Color3.fromRGB(72, 78, 88),
	Glare = 0.05,
	Haze = 1.25,
}

-- Warm, clearer safezone — light haze, not a gray soup.
local SAFEZONE_FOG = {
	densityAdd = 0.07,
	densityMin = 0.1,
	densityMax = 0.22,
	hazeAdd = 0.32,
	hazeMin = 0.28,
	hazeMax = 0.85,
	offsetBias = 0.02,
	glareMax = 0.08,
	mistColor = Color3.fromRGB(255, 236, 208),
	mistDecay = Color3.fromRGB(214, 176, 128),
	mistMix = 0.16,
}

local SAFEZONE_FOG_LOW = {
	densityAdd = 0.06,
	densityMin = 0.1,
	densityMax = 0.2,
	hazeAdd = 0.24,
	hazeMin = 0.22,
	hazeMax = 0.7,
	offsetBias = 0.01,
	glareMax = 0.06,
	mistColor = Color3.fromRGB(255, 236, 208),
	mistDecay = Color3.fromRGB(214, 176, 128),
	mistMix = 0.12,
}

local LOOK_CC_NAME = "SafeZoneLookCC"
local LOOK_BLOOM_NAME = "SafeZoneLookBloom"

local SAFEZONE_CC = {
	Brightness = 0.06,
	Contrast = 0.1,
	Saturation = 0.16,
	TintColor = Color3.fromRGB(255, 244, 224),
}

local NIGHT_CC = {
	Brightness = -0.03,
	Contrast = 0.05,
	Saturation = -0.06,
	TintColor = Color3.fromRGB(214, 222, 236),
}

local SAFEZONE_BLOOM = {
	Intensity = 0.22,
	Size = 16,
	Threshold = 0.9,
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
local lowGraphics = false
local _pollConn: RBXScriptConnection? = nil
local dayAtmo: AtmoSnap? = nil

local function cancelTweens()
	for _, tw in activeTweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeTweens)
end

local function playTween(inst: Instance, props: { [string]: any })
	local tw = TweenService:Create(inst, FADE_INFO, props)
	table.insert(activeTweens, tw)
	tw:Play()
	return tw
end

local function cleanupLegacy()
	local existing = Lighting:FindFirstChild(CC_LEGACY_NAME)
	if existing then
		existing:Destroy()
	end
	local rays = Lighting:FindFirstChild("SafeZoneSunRays")
	if rays then
		rays:Destroy()
	end
	for _, name in { "SafeZoneGodRays", "MapGodRays" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			folder:Destroy()
		end
	end
	local pg = player:FindFirstChild("PlayerGui")
	local veil = pg and pg:FindFirstChild("SafeZoneSkyVeil")
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

local function ensureLookCC(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(LOOK_CC_NAME)
	if existing and existing:IsA("ColorCorrectionEffect") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = LOOK_CC_NAME
	cc.Brightness = 0
	cc.Contrast = 0
	cc.Saturation = 0
	cc.TintColor = Color3.new(1, 1, 1)
	cc.Enabled = true
	cc.Parent = Lighting
	return cc
end

local function ensureLookBloom(): BloomEffect?
	if lowGraphics then
		local old = Lighting:FindFirstChild(LOOK_BLOOM_NAME)
		if old then
			old:Destroy()
		end
		return nil
	end
	local existing = Lighting:FindFirstChild(LOOK_BLOOM_NAME)
	if existing and existing:IsA("BloomEffect") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local bloom = Instance.new("BloomEffect")
	bloom.Name = LOOK_BLOOM_NAME
	bloom.Intensity = 0
	bloom.Size = SAFEZONE_BLOOM.Size
	bloom.Threshold = SAFEZONE_BLOOM.Threshold
	bloom.Enabled = true
	bloom.Parent = Lighting
	return bloom
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

-- Capture place day lighting once. Never call after night/fog has been applied.
local function captureDayOnce()
	if dayAtmo then
		return
	end
	dayAtmo = readAtmo(ensureAtmosphere())
end

local function safezoneAtmo(): AtmoSnap
	local day = dayAtmo :: AtmoSnap
	local fog = if lowGraphics then SAFEZONE_FOG_LOW else SAFEZONE_FOG
	local mix = fog.mistMix
	return {
		Density = math.clamp(math.max(day.Density, fog.densityMin) + fog.densityAdd, fog.densityMin, fog.densityMax),
		Offset = day.Offset + fog.offsetBias,
		Color = day.Color:Lerp(fog.mistColor, mix),
		Decay = day.Decay:Lerp(fog.mistDecay, mix * 0.85),
		Glare = math.min(day.Glare, fog.glareMax),
		Haze = math.clamp(math.max(day.Haze, fog.hazeMin) + fog.hazeAdd, fog.hazeMin, fog.hazeMax),
	}
end

local function applyProfile(night: boolean, instant: boolean?)
	captureDayOnce()
	local atmo = ensureAtmosphere()
	cancelTweens()

	local goal = if night then (if lowGraphics then NIGHT_ATMO_LOW else NIGHT_ATMO) else safezoneAtmo()

	local cc = ensureLookCC()
	local bloom = ensureLookBloom()
	local ccGoal = if night then NIGHT_CC else SAFEZONE_CC
	local bloomIntensity = if night or lowGraphics then 0 else SAFEZONE_BLOOM.Intensity

	if instant then
		atmo.Density = goal.Density
		atmo.Offset = goal.Offset
		atmo.Color = goal.Color
		atmo.Decay = goal.Decay
		atmo.Glare = goal.Glare
		atmo.Haze = goal.Haze
		cc.Brightness = ccGoal.Brightness
		cc.Contrast = ccGoal.Contrast
		cc.Saturation = ccGoal.Saturation
		cc.TintColor = ccGoal.TintColor
		if bloom then
			bloom.Intensity = bloomIntensity
			bloom.Size = SAFEZONE_BLOOM.Size
			bloom.Threshold = SAFEZONE_BLOOM.Threshold
		end
		return
	end

	playTween(atmo, {
		Density = goal.Density,
		Offset = goal.Offset,
		Color = goal.Color,
		Decay = goal.Decay,
		Glare = goal.Glare,
		Haze = goal.Haze,
	})
	playTween(cc, {
		Brightness = ccGoal.Brightness,
		Contrast = ccGoal.Contrast,
		Saturation = ccGoal.Saturation,
		TintColor = ccGoal.TintColor,
	})
	if bloom then
		playTween(bloom, {
			Intensity = bloomIntensity,
			Size = SAFEZONE_BLOOM.Size,
			Threshold = SAFEZONE_BLOOM.Threshold,
		})
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
	inSafezone = nextIn
	applyProfile(not nextIn, force == true)
end

function SafeZoneLightingController.setLowGraphics(on: boolean)
	local nextOn = on == true
	if lowGraphics == nextOn then
		return
	end
	lowGraphics = nextOn
	if wired then
		applyProfile(not inSafezone, true)
	end
end

function SafeZoneLightingController.init()
	if wired then
		return
	end
	wired = true

	cleanupLegacy()
	-- CRITICAL: snap day BEFORE any fog/night apply, so restore always works
	captureDayOnce()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(12)
		setInSafezone(readInSafezone(), true)
	end)

	inSafezone = readInSafezone()
	applyProfile(not inSafezone, true)

	player.CharacterAdded:Connect(function()
		task.defer(function()
			setInSafezone(readInSafezone(), true)
		end)
	end)

	local accum = 0.0
	_pollConn = RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < POLL_INTERVAL then
			return
		end
		accum = 0
		setInSafezone(readInSafezone())
	end)
end

return SafeZoneLightingController
