-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: dark greenish Atmosphere + slightly dimmer ambient.
	No ColorCorrection, no skybox swap, no light beams / SunRays.
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

-- Dark green night — low haze so it doesn't wash white
local NIGHT_ATMO = {
	Density = 0.52,
	Offset = 0.06,
	Color = Color3.fromRGB(36, 55, 40),
	Decay = Color3.fromRGB(48, 68, 46),
	Glare = 0.03,
	Haze = 0.55,
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
	Ambient: Color3,
	OutdoorAmbient: Color3,
	Brightness: number,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil
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
	local cc = Lighting:FindFirstChild(CC_LEGACY_NAME)
	if cc then
		cc:Destroy()
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

local function snapshotDay()
	local atmo = ensureAtmosphere()
	dayAtmo = {
		Density = atmo.Density,
		Offset = atmo.Offset,
		Color = atmo.Color,
		Decay = atmo.Decay,
		Glare = atmo.Glare,
		Haze = atmo.Haze,
	}
	dayLight = {
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Brightness = Lighting.Brightness,
	}
end

local function nightLightGoals(): LightSnap
	local day = dayLight :: LightSnap
	local function dim(c: Color3): Color3
		return Color3.new(c.R * 0.45, math.min(1, c.G * 0.55), c.B * 0.42)
	end
	return {
		Ambient = dim(day.Ambient),
		OutdoorAmbient = dim(day.OutdoorAmbient),
		Brightness = math.max(1.1, day.Brightness * 0.55),
	}
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo or not dayLight then
		snapshotDay()
	end
	cancelTweens()

	local atmo = ensureAtmosphere()
	local atmoGoal = if night then NIGHT_ATMO else (dayAtmo :: AtmoSnap)
	local lightGoal = if night then nightLightGoals() else (dayLight :: LightSnap)

	if instant then
		atmo.Density = atmoGoal.Density
		atmo.Offset = atmoGoal.Offset
		atmo.Color = atmoGoal.Color
		atmo.Decay = atmoGoal.Decay
		atmo.Glare = atmoGoal.Glare
		atmo.Haze = atmoGoal.Haze
		Lighting.Ambient = lightGoal.Ambient
		Lighting.OutdoorAmbient = lightGoal.OutdoorAmbient
		Lighting.Brightness = lightGoal.Brightness
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
	playTween(Lighting, {
		Ambient = lightGoal.Ambient,
		OutdoorAmbient = lightGoal.OutdoorAmbient,
		Brightness = lightGoal.Brightness,
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
	if nextIn then
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

	cleanupLegacy()
	snapshotDay()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(12)
		if readInSafezone() then
			snapshotDay()
		end
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
