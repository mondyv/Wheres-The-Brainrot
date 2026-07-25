-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: swap in LightingPresets.NightLighting.NightSky only.
	Keeps all Lighting / Atmosphere / brightness exactly as day — no darkening.
	Crossfade uses a brief dark UI veil (not Atmosphere haze) so no white flash.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.2
local VEIL_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local VEIL_OUT = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CC_LEGACY_NAME = "SafeZoneNightCC"
local STASH_NAME = "_SafeZoneLightingStash"
local APPLIED_TAG = "SafeZoneLightingApplied"

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil
local transitionToken = 0
local presetsReady = false
local nightSkyTemplate: Sky? = nil
local daySkyBackup: Sky? = nil
local showingNight = false

local veilGui: ScreenGui? = nil
local veilFrame: Frame? = nil

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

local function ensureVeil(): Frame
	if veilFrame and veilGui and veilGui.Parent then
		return veilFrame
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SafeZoneSkyVeil"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Veil"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(8, 10, 18)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = gui

	veilGui = gui
	veilFrame = frame
	return frame
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

local function playVeil(targetTransparency: number, info: TweenInfo): Tween
	local frame = ensureVeil()
	frame.Visible = true
	local tw = TweenService:Create(frame, info, { BackgroundTransparency = targetTransparency })
	tw:Play()
	return tw
end

local function clearAppliedNightSky()
	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") and child:GetAttribute(APPLIED_TAG) == true then
			child:Destroy()
		end
	end
end

local function stashDaySkyIfNeeded()
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

local function restoreDaySky()
	clearAppliedNightSky()
	local stash = getStash()
	local sky = daySkyBackup
	if not sky or not sky.Parent then
		sky = stash:FindFirstChildOfClass("Sky")
	end
	if sky and sky:IsA("Sky") then
		sky.Parent = Lighting
		daySkyBackup = sky
	end
	showingNight = false
end

local function applyNightSky()
	local live = Lighting:FindFirstChildOfClass("Sky")
	if live and live:GetAttribute(APPLIED_TAG) ~= true then
		stashDaySkyIfNeeded()
	else
		clearAppliedNightSky()
	end

	if nightSkyTemplate then
		local clone = nightSkyTemplate:Clone()
		clone.Name = "NightSky"
		clone:SetAttribute(APPLIED_TAG, true)
		clone.Parent = Lighting
	end
	showingNight = true
end

local function setSky(toNight: boolean, instant: boolean?)
	if toNight == showingNight and not instant then
		-- Already correct (allow force via instant path on boot)
		if toNight then
			local live = Lighting:FindFirstChildOfClass("Sky")
			if live and live:GetAttribute(APPLIED_TAG) == true then
				return
			end
		else
			local live = Lighting:FindFirstChildOfClass("Sky")
			if live and live:GetAttribute(APPLIED_TAG) ~= true then
				return
			end
		end
	end

	transitionToken += 1
	local token = transitionToken

	if instant or not nightSkyTemplate then
		if toNight then
			applyNightSky()
		else
			restoreDaySky()
		end
		local frame = ensureVeil()
		frame.BackgroundTransparency = 1
		return
	end

	task.spawn(function()
		-- Dark veil (not white atmosphere haze) → swap sky → reveal
		local inn = playVeil(0.22, VEIL_IN)
		waitTween(inn)
		if token ~= transitionToken then
			return
		end

		if toNight then
			applyNightSky()
		else
			restoreDaySky()
		end

		task.wait(0.04)
		if token ~= transitionToken then
			return
		end

		local out = playVeil(1, VEIL_OUT)
		waitTween(out)
	end)
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

	local sky = folder:FindFirstChild("NightSky") or folder:FindFirstChildOfClass("Sky")
	if sky and sky:IsA("Sky") then
		nightSkyTemplate = sky
		presetsReady = true
		return true
	end

	warn("[SafeZoneLighting] NightSky missing under NightLighting")
	return false
end

local function snapshotDaySky()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky and sky:GetAttribute(APPLIED_TAG) ~= true then
		daySkyBackup = sky
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
	-- Outside safe zone → NightSky only (lighting untouched)
	setSky(not nextIn, force == true)
end

function SafeZoneLightingController.init()
	if wired then
		return
	end
	wired = true

	destroyLegacyColorCorrection()
	snapshotDaySky()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
	end)

	task.spawn(function()
		resolvePresets()
		task.wait(0.5)
		if inSafezone then
			snapshotDaySky()
		end
		inSafezone = readInSafezone()
		setSky(not inSafezone, true)
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
