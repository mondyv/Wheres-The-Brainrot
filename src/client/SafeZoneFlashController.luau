--[[
	Full-screen white flash when the local player successfully delivers a carried brainrot
	to the safe zone. Server fires ReplicatedStorage.SafeZoneFlash for that player only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local FLASH_DURATION = 0.7
local FLASH_PEAK_TRANSPARENCY = 0.5
local FLASH_DISPLAY_ORDER = -50

local SafeZoneFlashController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local flashGui: ScreenGui? = nil
local flashFrame: Frame? = nil
local activeTween: Tween? = nil
local flashToken = 0

local function ensureFlashGui(): (ScreenGui, Frame)
	if flashGui and flashFrame and flashGui.Parent then
		return flashGui, flashFrame
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "SafeZoneFlash"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = FLASH_DISPLAY_ORDER
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Flash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Visible = false
	frame.Parent = sg

	flashGui = sg
	flashFrame = frame
	return sg, frame
end

local function playFlash()
	local _, frame = ensureFlashGui()
	flashToken += 1
	local token = flashToken

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	frame.Visible = true
	frame.BackgroundTransparency = FLASH_PEAK_TRANSPARENCY

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(FLASH_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	activeTween = tween
	tween:Play()
	tween.Completed:Connect(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end
		if token ~= flashToken then
			return
		end
		activeTween = nil
		frame.Visible = false
	end)
end

function SafeZoneFlashController.init()
	local ev = ReplicatedStorage:WaitForChild("SafeZoneFlash", 60)
	if not ev or not ev:IsA("RemoteEvent") then
		warn("[SafeZoneFlash] ReplicatedStorage.SafeZoneFlash RemoteEvent missing")
		return
	end

	(ev :: RemoteEvent).OnClientEvent:Connect(function()
		playFlash()
	end)
end

return SafeZoneFlashController
