-- [ACTIVE] SafeZoneLightingController
--[[
	Outside safe zone: mild greenish Atmosphere night + SunRays + soft physical
	god-ray Beams. No ColorCorrection, no skybox swap, no white UI veil.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25
local ATMO_INFO = TweenInfo.new(1.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local RAY_INFO = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CC_LEGACY_NAME = "SafeZoneNightCC"
local SUNRAYS_NAME = "SafeZoneSunRays"
local BEAM_FOLDER_NAME = "SafeZoneGodRays"
local BEAM_COUNT = 5

-- Slight green night — low haze so it doesn't flash white/foggy
local NIGHT_ATMO = {
	Density = 0.34,
	Offset = 0.12,
	Color = Color3.fromRGB(52, 78, 58),
	Decay = Color3.fromRGB(70, 95, 62),
	Glare = 0.06,
	Haze = 0.85,
}

local NIGHT_SUNRAYS = {
	Intensity = 0.22,
	Spread = 0.55,
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
local beamConn: RBXScriptConnection? = nil
local dayAtmo: AtmoSnap? = nil
local daySunRays: { Intensity: number, Spread: number, Enabled: boolean }? = nil
local beamFolder: Folder? = nil
local beamShafts: {
	{
		part: BasePart,
		att0: Attachment,
		att1: Attachment,
		beam: Beam,
		angle: number,
		radius: number,
	}
} = {}

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
	local existing = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if existing and existing.Name ~= SUNRAYS_NAME then
		daySunRays = {
			Intensity = existing.Intensity,
			Spread = existing.Spread,
			Enabled = existing.Enabled,
		}
	else
		daySunRays = { Intensity = 0.05, Spread = 0.1, Enabled = false }
	end
end

local function ensureSunRays(): SunRaysEffect
	local existing = Lighting:FindFirstChild(SUNRAYS_NAME)
	if existing and existing:IsA("SunRaysEffect") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local rays = Instance.new("SunRaysEffect")
	rays.Name = SUNRAYS_NAME
	rays.Intensity = 0
	rays.Spread = 0.2
	rays.Enabled = true
	rays.Parent = Lighting
	return rays
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

local function applySunRays(night: boolean, instant: boolean?)
	local rays = ensureSunRays()
	local goalIntensity = if night then NIGHT_SUNRAYS.Intensity else 0
	local goalSpread = if night then NIGHT_SUNRAYS.Spread else (daySunRays and daySunRays.Spread or 0.1)
	rays.Enabled = true
	if instant then
		rays.Intensity = goalIntensity
		rays.Spread = goalSpread
		if not night and goalIntensity <= 0.001 then
			rays.Enabled = false
		end
		return
	end
	playTween(rays, RAY_INFO, {
		Intensity = goalIntensity,
		Spread = goalSpread,
	})
end

local function clearGodRays()
	if beamConn then
		beamConn:Disconnect()
		beamConn = nil
	end
	table.clear(beamShafts)
	if beamFolder then
		beamFolder:Destroy()
		beamFolder = nil
	end
end

local function ensureGodRays()
	if beamFolder and beamFolder.Parent then
		return
	end
	clearGodRays()

	local folder = Instance.new("Folder")
	folder.Name = BEAM_FOLDER_NAME
	folder.Parent = Workspace

	local color = Color3.fromRGB(190, 230, 140)
	for i = 1, BEAM_COUNT do
		local part = Instance.new("Part")
		part.Name = "GodRay" .. i
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Parent = folder

		local att0 = Instance.new("Attachment")
		att0.Name = "Top"
		att0.Parent = part

		local att1 = Instance.new("Attachment")
		att1.Name = "Bottom"
		att1.Parent = part

		local beam = Instance.new("Beam")
		beam.Attachment0 = att0
		beam.Attachment1 = att1
		beam.Color = ColorSequence.new(color)
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.82),
			NumberSequenceKeypoint.new(0.45, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Width0 = 7.5
		beam.Width1 = 2.2
		beam.FaceCamera = true
		beam.LightEmission = 0.85
		beam.LightInfluence = 0
		beam.Segments = 8
		beam.Enabled = false
		beam.Parent = part

		local light = Instance.new("PointLight")
		light.Name = "ShaftLight"
		light.Color = color
		light.Brightness = 0.35
		light.Range = 28
		light.Shadows = false
		light.Enabled = false
		light.Parent = part

		table.insert(beamShafts, {
			part = part,
			att0 = att0,
			att1 = att1,
			beam = beam,
			angle = (i / BEAM_COUNT) * math.pi * 2 + i * 0.37,
			radius = 18 + (i % 3) * 9,
		})
	end

	beamFolder = folder
end

local function setGodRaysVisible(on: boolean)
	for _, shaft in beamShafts do
		shaft.beam.Enabled = on
		local light = shaft.part:FindFirstChild("ShaftLight")
		if light and light:IsA("PointLight") then
			light.Enabled = on
		end
	end
end

local function updateGodRayPositions()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local origin = (hrp :: BasePart).Position
	local t = os.clock()

	for _, shaft in beamShafts do
		local ang = shaft.angle + t * 0.035
		local wobble = math.sin(t * 0.4 + shaft.angle) * 2.5
		local x = origin.X + math.cos(ang) * (shaft.radius + wobble)
		local z = origin.Z + math.sin(ang) * (shaft.radius + wobble)
		local top = Vector3.new(x, origin.Y + 55, z)
		local bottom = Vector3.new(x + math.cos(ang) * 3, origin.Y - 2, z + math.sin(ang) * 3)
		shaft.part.CFrame = CFrame.new((top + bottom) * 0.5)
		shaft.att0.WorldPosition = top
		shaft.att1.WorldPosition = bottom
	end
end

local function setGodRaysActive(on: boolean)
	if on then
		ensureGodRays()
		setGodRaysVisible(true)
		if not beamConn then
			local accum = 0.0
			beamConn = RunService.Heartbeat:Connect(function(dt)
				accum += dt
				if accum < 0.05 then
					return
				end
				accum = 0
				updateGodRayPositions()
			end)
		end
	else
		setGodRaysVisible(false)
		if beamConn then
			beamConn:Disconnect()
			beamConn = nil
		end
	end
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo then
		snapshotDay()
	end
	cancelTweens()

	local goal = if night then NIGHT_ATMO else (dayAtmo :: AtmoSnap)
	applyAtmo(goal, instant)
	applySunRays(night, instant)
	setGodRaysActive(night)
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
	local stash = Lighting:FindFirstChild("_SafeZoneLightingStash")
	if stash then
		stash:Destroy()
	end
	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") and child:GetAttribute("SafeZoneLightingApplied") == true then
			child:Destroy()
		end
	end
	local oldVeil = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("SafeZoneSkyVeil")
	if oldVeil then
		oldVeil:Destroy()
	end
	local oldBeams = Workspace:FindFirstChild(BEAM_FOLDER_NAME)
	if oldBeams then
		oldBeams:Destroy()
	end

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
