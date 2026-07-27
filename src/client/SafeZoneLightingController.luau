-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: smoky dark Atmosphere night.
	Inside: sunny day lighting + distant haze (base stays bright; far lands soften).
	Day Atmosphere + Lighting are snapped once at boot before any night apply.
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

-- Dark nighty fog outside safe zone
local NIGHT_ATMO = {
	Density = 0.62,
	Offset = 0.05,
	Color = Color3.fromRGB(46, 50, 52),
	Decay = Color3.fromRGB(58, 62, 64),
	Glare = 0.03,
	Haze = 2.85,
}

local NIGHT_ATMO_LOW = {
	Density = 0.52,
	Offset = 0.05,
	Color = Color3.fromRGB(46, 50, 52),
	Decay = Color3.fromRGB(58, 62, 64),
	Glare = 0.02,
	Haze = 2.35,
}

-- Distant haze in safe zone — near base stays clear/sunny; far lands soften
local SAFEZONE_FOG = {
	densityAdd = 0.22,
	densityMin = 0.28,
	densityMax = 0.4,
	hazeAdd = 1.35,
	hazeMin = 1.25,
	hazeMax = 2.2,
	offsetBias = 0.09,
	glareMin = 0.14,
	glareMax = 0.32,
	mistColor = Color3.fromRGB(215, 222, 228),
	mistDecay = Color3.fromRGB(168, 176, 182),
	mistMix = 0.2,
}

local SAFEZONE_FOG_LOW = {
	densityAdd = 0.18,
	densityMin = 0.24,
	densityMax = 0.34,
	hazeAdd = 1.05,
	hazeMin = 1.0,
	hazeMax = 1.85,
	offsetBias = 0.08,
	glareMin = 0.1,
	glareMax = 0.24,
	mistColor = Color3.fromRGB(215, 222, 228),
	mistDecay = Color3.fromRGB(168, 176, 182),
	mistMix = 0.16,
}

-- Extra sunny punch on top of the place day lighting (safezone only)
local SAFEZONE_LIGHT = {
	brightnessAdd = 0.45,
	ambientMix = 0.12,
	outdoorMix = 0.16,
	warmTop = Color3.fromRGB(255, 236, 205),
	warmTopMix = 0.22,
	warmBottom = Color3.fromRGB(255, 245, 230),
	warmBottomMix = 0.1,
}

local SAFEZONE_LIGHT_LOW = {
	brightnessAdd = 0.28,
	ambientMix = 0.08,
	outdoorMix = 0.1,
	warmTop = Color3.fromRGB(255, 236, 205),
	warmTopMix = 0.14,
	warmBottom = Color3.fromRGB(255, 245, 230),
	warmBottomMix = 0.06,
}

type AtmoSnap = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

type DayLightSnap = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	ColorShift_Top: Color3,
	ColorShift_Bottom: Color3,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local lowGraphics = false
local _pollConn: RBXScriptConnection? = nil
local dayAtmo: AtmoSnap? = nil
local dayLight: DayLightSnap? = nil

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

local function readDayLight(): DayLightSnap
	return {
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		ColorShift_Top = Lighting.ColorShift_Top,
		ColorShift_Bottom = Lighting.ColorShift_Bottom,
	}
end

-- Capture place day lighting once. Never call after night/fog has been applied.
local function captureDayOnce()
	if not dayAtmo then
		dayAtmo = readAtmo(ensureAtmosphere())
	end
	if not dayLight then
		dayLight = readDayLight()
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
		-- Force a sunny glare floor — place day often has Glare=0 so math.min alone never looked sunny.
		Glare = math.clamp(math.max(day.Glare, fog.glareMin), fog.glareMin, fog.glareMax),
		Haze = math.clamp(math.max(day.Haze, fog.hazeMin) + fog.hazeAdd, fog.hazeMin, fog.hazeMax),
	}
end

local function safezoneLightProps(): { [string]: any }
	local day = dayLight :: DayLightSnap
	local boost = if lowGraphics then SAFEZONE_LIGHT_LOW else SAFEZONE_LIGHT
	local white = Color3.new(1, 1, 1)
	return {
		Brightness = math.clamp(day.Brightness + boost.brightnessAdd, 0, 4),
		Ambient = day.Ambient:Lerp(white, boost.ambientMix),
		OutdoorAmbient = day.OutdoorAmbient:Lerp(white, boost.outdoorMix),
		ColorShift_Top = day.ColorShift_Top:Lerp(boost.warmTop, boost.warmTopMix),
		ColorShift_Bottom = day.ColorShift_Bottom:Lerp(boost.warmBottom, boost.warmBottomMix),
	}
end

local function restoreDayLightProps(): { [string]: any }
	local day = dayLight :: DayLightSnap
	return {
		Brightness = day.Brightness,
		Ambient = day.Ambient,
		OutdoorAmbient = day.OutdoorAmbient,
		ColorShift_Top = day.ColorShift_Top,
		ColorShift_Bottom = day.ColorShift_Bottom,
	}
end

local function applyProfile(night: boolean, instant: boolean?)
	captureDayOnce()
	local atmo = ensureAtmosphere()
	cancelTweens()

	local atmoGoal = if night then (if lowGraphics then NIGHT_ATMO_LOW else NIGHT_ATMO) else safezoneAtmo()
	local lightGoal = if night then restoreDayLightProps() else safezoneLightProps()

	if instant then
		atmo.Density = atmoGoal.Density
		atmo.Offset = atmoGoal.Offset
		atmo.Color = atmoGoal.Color
		atmo.Decay = atmoGoal.Decay
		atmo.Glare = atmoGoal.Glare
		atmo.Haze = atmoGoal.Haze
		Lighting.Brightness = lightGoal.Brightness
		Lighting.Ambient = lightGoal.Ambient
		Lighting.OutdoorAmbient = lightGoal.OutdoorAmbient
		Lighting.ColorShift_Top = lightGoal.ColorShift_Top
		Lighting.ColorShift_Bottom = lightGoal.ColorShift_Bottom
		return
	end

	playTween(atmo, {
		Density = atmoGoal.Density,
		Offset = atmoGoal.Offset,
		Color = atmoGoal.Color,
		Decay = atmoGoal.Decay,
		Glare = atmoGoal.Glare,
		Haze = atmoGoal.Haze,
	})
	playTween(Lighting, lightGoal)
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
