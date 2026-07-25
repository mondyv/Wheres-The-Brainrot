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

-- Dark nighty fog outside safe zone
local NIGHT_ATMO = {
	Density = 0.62,
	Offset = 0.05,
	Color = Color3.fromRGB(46, 50, 52),
	Decay = Color3.fromRGB(58, 62, 64),
	Glare = 0.03,
	Haze = 2.85,
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
	local mix = SAFEZONE_FOG.mistMix
	return {
		Density = math.clamp(math.max(day.Density, SAFEZONE_FOG.densityMin) + SAFEZONE_FOG.densityAdd, SAFEZONE_FOG.densityMin, SAFEZONE_FOG.densityMax),
		Offset = day.Offset + SAFEZONE_FOG.offsetBias,
		Color = day.Color:Lerp(SAFEZONE_FOG.mistColor, mix),
		Decay = day.Decay:Lerp(SAFEZONE_FOG.mistDecay, mix * 0.85),
		Glare = math.min(day.Glare, SAFEZONE_FOG.glareMax),
		Haze = math.clamp(math.max(day.Haze, SAFEZONE_FOG.hazeMin) + SAFEZONE_FOG.hazeAdd, SAFEZONE_FOG.hazeMin, SAFEZONE_FOG.hazeMax),
	}
end

local function applyProfile(night: boolean, instant: boolean?)
	captureDayOnce()
	local atmo = ensureAtmosphere()
	cancelTweens()

	local goal = if night then NIGHT_ATMO else safezoneAtmo()

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
