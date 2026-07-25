-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone, darkens Atmosphere only (smoky jungle night).
	Does NOT touch Ambient / OutdoorAmbient / Brightness / ColorCorrection —
	those tint the whole screen.
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

-- Misty see-through fog night — not black crush
local NIGHT_ATMO = {
	Density = 0.38,
	Offset = 0.2,
	Color = Color3.fromRGB(110, 118, 122),
	Decay = Color3.fromRGB(95, 102, 108),
	Glare = 0.02,
	Haze = 3.4,
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
local daySnapReady = false

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

local function snapshotDay(force: boolean?)
	-- Never overwrite the day snapshot with night atmosphere values
	if daySnapReady and not force then
		return
	end
	local atmo = ensureAtmosphere()
	dayAtmo = {
		Density = atmo.Density,
		Offset = atmo.Offset,
		Color = atmo.Color,
		Decay = atmo.Decay,
		Glare = atmo.Glare,
		Haze = atmo.Haze,
	}
	daySnapReady = true
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo then
		snapshotDay(true)
	end
	local atmo = ensureAtmosphere()
	cancelTweens()

	local goal = if night then NIGHT_ATMO else (dayAtmo :: AtmoSnap)

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
	-- Restore day snap when returning; never re-snapshot while night is active
	applyProfile(not nextIn, force == true)
end

function SafeZoneLightingController.init()
	if wired then
		return
	end
	wired = true

	cleanupLegacy()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(12)
		-- Capture true day look only while (or if) inside safezone before night apply
		if readInSafezone() then
			snapshotDay(true)
		elseif not daySnapReady then
			-- Outside on join: still store whatever is current as fallback, then night
			snapshotDay(true)
		end
		setInSafezone(readInSafezone(), true)
	end)

	-- Prefer snapping day ASAP if we spawn in safezone
	if readInSafezone() then
		snapshotDay(true)
	end
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
