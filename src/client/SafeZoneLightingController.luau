-- [ACTIVE] SafeZoneLightingController
--[[
	Smoothly fades Lighting toward a slight night look when the local player
	leaves the safe zone, and restores the original look when they return.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25
local FADE_INFO = TweenInfo.new(1.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CC_NAME = "SafeZoneNightCC"

-- Mild night — not pitch black
local NIGHT = {
	Brightness = -0.14,
	Contrast = 0.06,
	Saturation = -0.12,
	TintColor = Color3.fromRGB(168, 186, 230),
}

local DAY = {
	Brightness = 0,
	Contrast = 0,
	Saturation = 0,
	TintColor = Color3.new(1, 1, 1),
}

local SafeZoneLightingController = {}

local player = Players.LocalPlayer
local colorFx: ColorCorrectionEffect? = nil
local activeTweens: { Tween } = {}
local inSafezone = true
local wired = false
local pollConn: RBXScriptConnection? = nil

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

local function ensureColorFx(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(CC_NAME)
	if existing and existing:IsA("ColorCorrectionEffect") then
		colorFx = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local fx = Instance.new("ColorCorrectionEffect")
	fx.Name = CC_NAME
	fx.Brightness = DAY.Brightness
	fx.Contrast = DAY.Contrast
	fx.Saturation = DAY.Saturation
	fx.TintColor = DAY.TintColor
	fx.Enabled = true
	fx.Parent = Lighting
	colorFx = fx
	return fx
end

local function applyProfile(night: boolean)
	local fx = ensureColorFx()
	cancelTweens()
	local profile = if night then NIGHT else DAY
	playTween(fx, {
		Brightness = profile.Brightness,
		Contrast = profile.Contrast,
		Saturation = profile.Saturation,
		TintColor = profile.TintColor,
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
	applyProfile(not nextIn)
end

function SafeZoneLightingController.init()
	if wired then
		return
	end
	wired = true

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
	end)

	ensureColorFx()
	inSafezone = readInSafezone()
	-- Snap to correct state on join (no long fade from wrong look)
	local fx = ensureColorFx()
	local profile = if inSafezone then DAY else NIGHT
	fx.Brightness = profile.Brightness
	fx.Contrast = profile.Contrast
	fx.Saturation = profile.Saturation
	fx.TintColor = profile.TintColor

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
