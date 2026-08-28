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

-- Faint mist inside safe zone — softens distance so the base isn't crystal-clear
local SAFEZONE_FOG = {
	densityAdd = 0.18,
	densityMin = 0.22,
	densityMax = 0.34,
	hazeAdd = 0.85,
	hazeMin = 0.9,
	hazeMax = 1.55,
	offsetBias = -0.04,
	glareMax = 0.035,
	mistColor = Color3.fromRGB(198, 204, 210),
	mistDecay = Color3.fromRGB(155, 160, 166),
	mistMix = 0.28,
}

local SAFEZONE_FOG_LOW = {
	densityAdd = 0.14,
	densityMin = 0.2,
	densityMax = 0.3,
	hazeAdd = 0.65,
	hazeMin = 0.75,
	hazeMax = 1.35,
	offsetBias = -0.03,
	glareMax = 0.03,
	mistColor = Color3.fromRGB(198, 204, 210),
	mistDecay = Color3.fromRGB(155, 160, 166),
	mistMix = 0.22,
}

type AtmoSnap = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

type LightSnap = {
	ClockTime: number,
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	ExposureCompensation: number,
}

local NIGHT_LIGHT: LightSnap = {
	ClockTime = 0.35,
	Brightness = 1.2,
	Ambient = Color3.fromRGB(22, 26, 42),
	OutdoorAmbient = Color3.fromRGB(14, 18, 32),
	ExposureCompensation = -0.45,
}

local NIGHT_LIGHT_LOW: LightSnap = {
	ClockTime = 0.55,
	Brightness = 1.45,
	Ambient = Color3.fromRGB(32, 36, 52),
	OutdoorAmbient = Color3.fromRGB(22, 26, 40),
	ExposureCompensation = -0.25,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local lowGraphics = false
local _pollConn: RBXScriptConnection? = nil
local dayAtmo: AtmoSnap? = nil
local dayLight: LightSnap? = nil

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

local function readLight(): LightSnap
	return {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		ExposureCompensation = Lighting.ExposureCompensation,
	}
end

-- Capture place day lighting once. Never call after night/fog has been applied.
local function captureDayOnce()
	if dayAtmo and dayLight then
		return
	end
	if not dayAtmo then
		dayAtmo = readAtmo(ensureAtmosphere())
	end
	if not dayLight then
		dayLight = readLight()
	end
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
	local lightGoal = if night
		then (if lowGraphics then NIGHT_LIGHT_LOW else NIGHT_LIGHT)
		else (dayLight :: LightSnap)

	if instant then
		atmo.Density = goal.Density
		atmo.Offset = goal.Offset
		atmo.Color = goal.Color
		atmo.Decay = goal.Decay
		atmo.Glare = goal.Glare
		atmo.Haze = goal.Haze
		Lighting.ClockTime = lightGoal.ClockTime
		Lighting.Brightness = lightGoal.Brightness
		Lighting.Ambient = lightGoal.Ambient
		Lighting.OutdoorAmbient = lightGoal.OutdoorAmbient
		Lighting.ExposureCompensation = lightGoal.ExposureCompensation
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
	playTween(Lighting, {
		ClockTime = lightGoal.ClockTime,
		Brightness = lightGoal.Brightness,
		Ambient = lightGoal.Ambient,
		OutdoorAmbient = lightGoal.OutdoorAmbient,
		ExposureCompensation = lightGoal.ExposureCompensation,
	})
end

local function readInSafezone(): boolean
	local char = player.Character
	if not char then
		return true
	end
	return SafezoneUtil.isCharacterInSafezonePad(char)
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
