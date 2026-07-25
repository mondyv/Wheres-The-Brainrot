-- [ACTIVE] SafeZoneLightingController
--[[
	Outside the safe zone: mild Atmosphere night look only (no skybox swap,
	no ColorCorrection). Smooth dark UI veil during the switch.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25
local ATMO_INFO = TweenInfo.new(1.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local VEIL_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local VEIL_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CC_LEGACY_NAME = "SafeZoneNightCC"

-- Mild night via Atmosphere only (same as before NightSky)
local NIGHT_ATMO = {
	Density = 0.48,
	Offset = 0.08,
	Color = Color3.fromRGB(48, 62, 98),
	Decay = Color3.fromRGB(72, 88, 130),
	Glare = 0.08,
	Haze = 2.2,
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
local playerGui = player:WaitForChild("PlayerGui")

local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil
local transitionToken = 0
local dayAtmo: AtmoSnap? = nil

local veilGui: ScreenGui? = nil
local veilFrame: Frame? = nil

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

local function playVeil(targetTransparency: number, info: TweenInfo): Tween
	local frame = ensureVeil()
	frame.Visible = true
	local tw = TweenService:Create(frame, info, { BackgroundTransparency = targetTransparency })
	tw:Play()
	return tw
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
		return nil
	end
	return playTween(atmo, ATMO_INFO, {
		Density = snap.Density,
		Offset = snap.Offset,
		Color = snap.Color,
		Decay = snap.Decay,
		Glare = snap.Glare,
		Haze = snap.Haze,
	})
end

local function applyProfile(night: boolean, instant: boolean?)
	if not dayAtmo then
		snapshotDay()
	end
	cancelTweens()

	local goal = if night then NIGHT_ATMO else (dayAtmo :: AtmoSnap)

	if instant then
		applyAtmo(goal, true)
		local frame = ensureVeil()
		frame.BackgroundTransparency = 1
		return
	end

	transitionToken += 1
	local token = transitionToken

	task.spawn(function()
		local inn = playVeil(0.2, VEIL_IN)
		waitTween(inn)
		if token ~= transitionToken then
			return
		end

		cancelTweens()
		local atmoTw = applyAtmo(goal, false)

		task.wait(0.08)
		if token ~= transitionToken then
			return
		end

		local out = playVeil(1, VEIL_OUT)
		waitTween(out)
		if atmoTw and token == transitionToken then
			waitTween(atmoTw)
		end
	end)
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
	-- Clean leftover NightSky clones / stash from older builds
	local stash = Lighting:FindFirstChild("_SafeZoneLightingStash")
	if stash then
		stash:Destroy()
	end
	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") and child:GetAttribute("SafeZoneLightingApplied") == true then
			child:Destroy()
		end
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
