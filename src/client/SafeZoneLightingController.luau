-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: smoky dark Atmosphere night.
	Inside: heavier mist fog so distant unloaded lands don't read as empty holes.
	Day is snapped once at boot before any fog/night is applied.
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

-- Low-graphics night: slightly thinner fog only (keep the same look).
local NIGHT_ATMO_LOW = {
	Density = 0.52,
	Offset = 0.05,
	Color = Color3.fromRGB(46, 50, 52),
	Decay = Color3.fromRGB(58, 62, 64),
	Glare = 0.02,
	Haze = 2.35,
}

-- Faint mist inside safe zone — denser so distant unloaded lands don't show as empty gaps
local SAFEZONE_FOG = {
	densityAdd = 0.34,
	densityMin = 0.4,
	densityMax = 0.55,
	hazeAdd = 1.65,
	hazeMin = 1.7,
	hazeMax = 2.7,
	offsetBias = -0.06,
	glareMax = 0.025,
	mistColor = Color3.fromRGB(185, 192, 200),
	mistDecay = Color3.fromRGB(138, 144, 150),
	mistMix = 0.45,
}

local SAFEZONE_FOG_LOW = {
	densityAdd = 0.28,
	densityMin = 0.34,
	densityMax = 0.48,
	hazeAdd = 1.35,
	hazeMin = 1.4,
	hazeMax = 2.3,
	offsetBias = -0.05,
	glareMax = 0.022,
	mistColor = Color3.fromRGB(185, 192, 200),
	mistDecay = Color3.fromRGB(138, 144, 150),
	mistMix = 0.38,
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

	if instant then
		atmo.Density = goal.Density
		atmo.Offset = goal.Offset
		atmo.Color = goal.Color
		atmo.Decay = goal.Decay
		atmo.Glare = goal.Glare
		atmo.Haze = goal.Haze
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
