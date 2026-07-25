-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone, darkens Atmosphere (sky look) only.
	Does NOT use ColorCorrection — that tints the whole screen.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25
local FADE_INFO = TweenInfo.new(1.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CC_LEGACY_NAME = "SafeZoneNightCC"

-- Mild night sky via Atmosphere only
local NIGHT_ATMO = {
	Density = 0.48,
	Offset = 0.08,
	Color = Color3.fromRGB(48, 62, 98),
	Decay = Color3.fromRGB(72, 88, 130),
	Glare = 0.08,
	Haze = 2.2,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil

local dayAtmo: {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}? = nil

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

local function destroyLegacyColorCorrection()
	local existing = Lighting:FindFirstChild(CC_LEGACY_NAME)
	if existing then
		existing:Destroy()
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
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo then
		snapshotDay()
	end
	local atmo = ensureAtmosphere()
	cancelTweens()

	local goal = if night then NIGHT_ATMO else (dayAtmo :: typeof(NIGHT_ATMO))

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

	destroyLegacyColorCorrection()
	snapshotDay()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
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
