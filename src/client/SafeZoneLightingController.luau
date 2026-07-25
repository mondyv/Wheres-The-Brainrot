-- [ACTIVE] SafeZoneLightingController
--[[
	Safe zone = day lighting snapshot.
	Outside = ReplicatedStorage.LightingPresets.NightLighting (NightSky + any
	Atmosphere / Lighting attrs on the folder).

	Transition: atmosphere veil → swap Sky → settle props (no ColorCorrection
	unless the preset itself includes one — we only clone Sky / Atmosphere /
	Clouds / Bloom / SunRays / DepthOfField from the preset).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.2
local VEIL_INFO = TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local SETTLE_INFO = TweenInfo.new(1.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local CC_LEGACY_NAME = "SafeZoneNightCC"
local STASH_NAME = "_SafeZoneLightingStash"
local APPLIED_TAG = "SafeZoneLightingApplied"

local LIGHTING_ATTRS = {
	"ClockTime",
	"Brightness",
	"Ambient",
	"OutdoorAmbient",
	"FogColor",
	"FogStart",
	"FogEnd",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"ExposureCompensation",
	"GeographicLatitude",
	"ShadowSoftness",
}

local ATMO_PROPS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }

local CLONE_CLASSES = {
	Sky = true,
	Atmosphere = true,
	Clouds = true,
	BloomEffect = true,
	SunRaysEffect = true,
	DepthOfFieldEffect = true,
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil
local transitionToken = 0
local presetsReady = false

local nightFolder: Folder? = nil
local nightSkyTemplate: Sky? = nil
local nightAtmoTemplate: Atmosphere? = nil

type LightingSnap = { [string]: any }
type AtmoSnap = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

local dayLighting: LightingSnap = {}
local dayAtmo: AtmoSnap? = nil
local daySkyBackup: Sky? = nil
local nightLightingGoals: LightingSnap = {}
local nightAtmoGoals: AtmoSnap? = nil

local function cancelTweens()
	for _, tw in activeTweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeTweens)
end

local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local tw = TweenService:Create(inst, info, props)
	table.insert(activeTweens, tw)
	tw:Play()
	return tw
end

local function waitTween(tw: Tween)
	if tw.PlaybackState == Enum.PlaybackState.Completed then
		return
	end
	local done = false
	local conn = tw.Completed:Connect(function()
		done = true
	end)
	while not done do
		task.wait(0.03)
		if tw.PlaybackState == Enum.PlaybackState.Cancelled then
			break
		end
	end
	conn:Disconnect()
end

local function destroyLegacyColorCorrection()
	local existing = Lighting:FindFirstChild(CC_LEGACY_NAME)
	if existing then
		existing:Destroy()
	end
end

local function getStash(): Folder
	local stash = Lighting:FindFirstChild(STASH_NAME)
	if stash and stash:IsA("Folder") then
		return stash
	end
	if stash then
		stash:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = STASH_NAME
	folder.Parent = Lighting
	return folder
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

local function applyAtmoSnap(atmo: Atmosphere, snap: AtmoSnap, instant: boolean?, info: TweenInfo?)
	if instant then
		atmo.Density = snap.Density
		atmo.Offset = snap.Offset
		atmo.Color = snap.Color
		atmo.Decay = snap.Decay
		atmo.Glare = snap.Glare
		atmo.Haze = snap.Haze
		return nil
	end
	return playTween(atmo, info or SETTLE_INFO, {
		Density = snap.Density,
		Offset = snap.Offset,
		Color = snap.Color,
		Decay = snap.Decay,
		Glare = snap.Glare,
		Haze = snap.Haze,
	})
end

local function readLightingAttrs(): LightingSnap
	local snap: LightingSnap = {}
	for _, key in LIGHTING_ATTRS do
		local ok, value = pcall(function()
			return (Lighting :: any)[key]
		end)
		if ok then
			snap[key] = value
		end
	end
	return snap
end

local function applyLightingSnap(snap: LightingSnap, instant: boolean?, info: TweenInfo?)
	if next(snap) == nil then
		return nil
	end
	if instant then
		for key, value in snap do
			pcall(function()
				(Lighting :: any)[key] = value
			end)
		end
		return nil
	end
	return playTween(Lighting, info or SETTLE_INFO, snap)
end

local function clearAppliedPresetChildren()
	for _, child in Lighting:GetChildren() do
		if child:GetAttribute(APPLIED_TAG) == true then
			child:Destroy()
		end
	end
end

local function stashCurrentSky()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		return
	end
	if sky:GetAttribute(APPLIED_TAG) == true then
		sky:Destroy()
		return
	end
	local stash = getStash()
	for _, old in stash:GetChildren() do
		if old:IsA("Sky") then
			old:Destroy()
		end
	end
	sky.Parent = stash
	daySkyBackup = sky
end

local function restoreDaySky(instant: boolean?)
	clearAppliedPresetChildren()
	local stash = getStash()
	local sky = daySkyBackup
	if not sky or not sky.Parent then
		sky = stash:FindFirstChildOfClass("Sky")
	end
	if sky and sky:IsA("Sky") then
		sky.Parent = Lighting
		daySkyBackup = sky
	end
end

local function applyNightSky()
	clearAppliedPresetChildren()
	-- Stash day sky if still under Lighting
	local live = Lighting:FindFirstChildOfClass("Sky")
	if live and live:GetAttribute(APPLIED_TAG) ~= true then
		stashCurrentSky()
	elseif live then
		live:Destroy()
	end

	if nightSkyTemplate then
		local clone = nightSkyTemplate:Clone()
		clone.Name = "NightSky"
		clone:SetAttribute(APPLIED_TAG, true)
		clone.Parent = Lighting
	end

	-- Optional night Atmosphere from preset (replace live values via goals; keep one Atmosphere)
	if nightAtmoTemplate then
		local atmo = ensureAtmosphere()
		nightAtmoGoals = readAtmo(nightAtmoTemplate)
		-- Copy non-tweenable mid-state already handled by settle
		atmo.Name = atmo.Name
	end

	-- Clone other allowed effects from preset
	if nightFolder then
		for _, child in nightFolder:GetChildren() do
			if child:IsA("Sky") or child:IsA("Atmosphere") then
				continue
			end
			if CLONE_CLASSES[child.ClassName] then
				local existing = Lighting:FindFirstChild(child.Name)
				if existing and existing.ClassName == child.ClassName then
					if existing:GetAttribute(APPLIED_TAG) == true then
						existing:Destroy()
					else
						existing.Parent = getStash()
					end
				end
				local clone = child:Clone()
				clone:SetAttribute(APPLIED_TAG, true)
				clone.Parent = Lighting
			end
		end
	end
end

local function restoreDayEffects()
	clearAppliedPresetChildren()
	local stash = getStash()
	for _, child in stash:GetChildren() do
		if not child:IsA("Sky") and CLONE_CLASSES[child.ClassName] then
			-- Put day effects back
			local liveDup = Lighting:FindFirstChild(child.Name)
			if liveDup and liveDup:GetAttribute(APPLIED_TAG) == true then
				liveDup:Destroy()
			end
			child.Parent = Lighting
		end
	end
	restoreDaySky(true)
end

local function buildNightLightingGoals(folder: Instance): LightingSnap
	local goals: LightingSnap = {}
	for _, key in LIGHTING_ATTRS do
		local attr = folder:GetAttribute(key)
		if attr ~= nil then
			goals[key] = attr
		end
	end
	-- ValueBase children (NumberValue / Color3Value / etc.)
	for _, child in folder:GetChildren() do
		if child:IsA("NumberValue") or child:IsA("IntValue") then
			if table.find(LIGHTING_ATTRS, child.Name) then
				goals[child.Name] = child.Value
			end
		elseif child:IsA("Color3Value") then
			if table.find(LIGHTING_ATTRS, child.Name) then
				goals[child.Name] = child.Value
			end
		end
	end
	-- Soft defaults if folder has no lighting attrs but we have a night sky
	if next(goals) == nil then
		goals.Brightness = math.max(1.2, (dayLighting.Brightness or 3) * 0.55)
		goals.ClockTime = 0.35
		if typeof(dayLighting.Ambient) == "Color3" then
			local a = dayLighting.Ambient :: Color3
			goals.Ambient = Color3.new(a.R * 0.55, a.G * 0.58, a.B * 0.75)
		end
		if typeof(dayLighting.OutdoorAmbient) == "Color3" then
			local a = dayLighting.OutdoorAmbient :: Color3
			goals.OutdoorAmbient = Color3.new(a.R * 0.5, a.G * 0.55, a.B * 0.8)
		end
	end
	return goals
end

local function defaultNightAtmo(): AtmoSnap
	return {
		Density = 0.4,
		Offset = 0.1,
		Color = Color3.fromRGB(50, 64, 100),
		Decay = Color3.fromRGB(70, 85, 125),
		Glare = 0.1,
		Haze = 1.6,
	}
end

local function veilAtmo(atmo: Atmosphere, heavier: boolean): Tween
	local base = readAtmo(atmo)
	local density = if heavier then math.clamp(base.Density + 0.35, 0.35, 0.95) else base.Density
	local haze = if heavier then math.clamp(base.Haze + 2.4, 1.5, 6) else base.Haze
	return playTween(atmo, VEIL_INFO, {
		Density = density,
		Haze = haze,
	})
end

local function runTransition(toNight: boolean, instant: boolean?)
	transitionToken += 1
	local token = transitionToken
	cancelTweens()

	if not presetsReady then
		return
	end

	local atmo = ensureAtmosphere()

	if instant then
		if toNight then
			applyNightSky()
			if nightAtmoGoals then
				applyAtmoSnap(atmo, nightAtmoGoals, true)
			end
			applyLightingSnap(nightLightingGoals, true)
		else
			restoreDayEffects()
			if dayAtmo then
				applyAtmoSnap(atmo, dayAtmo, true)
			end
			applyLightingSnap(dayLighting, true)
		end
		return
	end

	task.spawn(function()
		-- 1) Soft veil so the sky swap isn't a hard pop
		local veil = veilAtmo(atmo, true)
		waitTween(veil)
		if token ~= transitionToken then
			return
		end

		-- 2) Swap sky / effects at peak veil
		if toNight then
			applyNightSky()
		else
			restoreDayEffects()
		end

		if token ~= transitionToken then
			return
		end

		-- 3) Settle atmosphere + lighting props
		cancelTweens()
		local atmoGoal = if toNight then (nightAtmoGoals or defaultNightAtmo()) else (dayAtmo or readAtmo(atmo))
		local lightGoal = if toNight then nightLightingGoals else dayLighting

		local twA = applyAtmoSnap(atmo, atmoGoal, false, SETTLE_INFO)
		local twL = applyLightingSnap(lightGoal, false, SETTLE_INFO)
		if twA then
			waitTween(twA)
		end
		if twL and token == transitionToken then
			waitTween(twL)
		end
	end)
end

local function snapshotDay()
	dayLighting = readLightingAttrs()
	dayAtmo = readAtmo(ensureAtmosphere())
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky and sky:GetAttribute(APPLIED_TAG) ~= true then
		daySkyBackup = sky
	end
end

local function resolvePresets(): boolean
	local presets = ReplicatedStorage:FindFirstChild("LightingPresets")
		or ReplicatedStorage:WaitForChild("LightingPresets", 30)
	if not presets then
		warn("[SafeZoneLighting] LightingPresets missing")
		return false
	end
	local folder = presets:FindFirstChild("NightLighting")
		or presets:WaitForChild("NightLighting", 10)
	if not folder then
		warn("[SafeZoneLighting] NightLighting missing")
		return false
	end
	nightFolder = folder :: Folder

	local sky = folder:FindFirstChild("NightSky") or folder:FindFirstChildOfClass("Sky")
	if sky and sky:IsA("Sky") then
		nightSkyTemplate = sky
	else
		warn("[SafeZoneLighting] NightSky missing under NightLighting")
	end

	local atmo = folder:FindFirstChildOfClass("Atmosphere")
	if atmo and atmo:IsA("Atmosphere") then
		nightAtmoTemplate = atmo
		nightAtmoGoals = readAtmo(atmo)
	else
		nightAtmoGoals = defaultNightAtmo()
	end

	nightLightingGoals = buildNightLightingGoals(folder)
	presetsReady = true
	return true
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
	-- Outside safe zone → night
	runTransition(not nextIn, force == true)
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

	task.spawn(function()
		if not resolvePresets() then
			-- Fallback: atmosphere-only night if preset missing
			presetsReady = true
			nightAtmoGoals = defaultNightAtmo()
			nightLightingGoals = {
				Brightness = math.max(1.2, (dayLighting.Brightness or 3) * 0.55),
				ClockTime = 0.35,
			}
		end

		-- Re-snapshot day after a short settle (map lighting may stream in)
		task.wait(0.5)
		if inSafezone then
			snapshotDay()
		end

		inSafezone = readInSafezone()
		runTransition(not inSafezone, true)
	end)

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
		if not presetsReady then
			return
		end
		setInSafezone(readInSafezone())
	end)
end

return SafeZoneLightingController
