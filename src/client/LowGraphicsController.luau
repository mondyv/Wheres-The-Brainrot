-- [ACTIVE] LowGraphicsController
--[[
	Settings → Low Graphics (Button7). Default off.

	When on:
	  • Fireflies / grass sway off
	  • Brainrot VFX auto-off (can re-enable)
	  • Heavier land cull (current land only + hide grass/trees/rocks on it)
	  • GlobalShadows off, lowest saved quality (best-effort)
	  • Bloom / DoF / SunRays off
	  • Safer fog via SafeZoneLightingController

	Studio play-solo caps session QualityLevel and uses the heavier land cull.
	It does not strip shadows/bloom or rewrite atmosphere (that looked wrong).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserSettings = UserSettings

local FireflyController = require(script.Parent.FireflyController)
local VegetationSwayController = require(script.Parent.VegetationSwayController)
local SafeZoneLightingController = require(script.Parent.SafeZoneLightingController)
local GrassCullController = require(script.Parent.GrassCullController)

local ATTR = "LowGraphicsEnabled"
local ATTR_FX_PREV = "__LowGfxFxPrevEnabled"
local ATTR_SHADOWS_PREV = "__LowGfxGlobalShadowsPrev"

local player = Players.LocalPlayer
local wired = false
local savedQuality: any = nil

-- Keep ColorCorrection / Blur for UI & look. Only strip costly bloom/DoF/sun rays.
local function isHeavyFx(inst: Instance): boolean
	return inst:IsA("BloomEffect") or inst:IsA("DepthOfFieldEffect") or inst:IsA("SunRaysEffect")
end

local function setHeavyFxEnabled(enabled: boolean)
	for _, child in Lighting:GetChildren() do
		if isHeavyFx(child) then
			local fx = child :: any
			if enabled then
				local prev = child:GetAttribute(ATTR_FX_PREV)
				if typeof(prev) == "boolean" then
					fx.Enabled = prev
				end
				child:SetAttribute(ATTR_FX_PREV, nil)
			else
				if child:GetAttribute(ATTR_FX_PREV) == nil then
					child:SetAttribute(ATTR_FX_PREV, fx.Enabled == true)
				end
				fx.Enabled = false
			end
		end
	end
end

local function setGlobalShadowsEnabled(enabled: boolean)
	if enabled then
		local prev = Lighting:GetAttribute(ATTR_SHADOWS_PREV)
		if typeof(prev) == "boolean" then
			Lighting.GlobalShadows = prev
		end
		Lighting:SetAttribute(ATTR_SHADOWS_PREV, nil)
	else
		if Lighting:GetAttribute(ATTR_SHADOWS_PREV) == nil then
			Lighting:SetAttribute(ATTR_SHADOWS_PREV, Lighting.GlobalShadows == true)
		end
		Lighting.GlobalShadows = false
	end
end

local function setSavedQualityLowest(enabled: boolean)
	local ok, err = pcall(function()
		local gameSettings = UserSettings():GetService("UserGameSettings")
		if enabled then
			if savedQuality == nil then
				savedQuality = gameSettings.SavedQualityLevel
			end
			-- Enum may differ by client build — try common lowest values.
			local enumType = Enum.SavedQualitySetting
			if enumType.QualityLevel1 then
				gameSettings.SavedQualityLevel = enumType.QualityLevel1
			elseif enumType.Automatic then
				-- Fall through: leave automatic if QualityLevel1 missing.
			end
		elseif savedQuality ~= nil then
			gameSettings.SavedQualityLevel = savedQuality
			savedQuality = nil
		end
	end)
	if not ok then
		warn("[LowGraphicsController] SavedQualityLevel failed:", err)
	end
end

local function studioPlay(): boolean
	return RunService:IsStudio()
end

local function capStudioRenderQuality()
	if not studioPlay() then
		return
	end
	pcall(function()
		local q = Enum.QualityLevel
		settings().Rendering.QualityLevel = q.Level08 or q.Level8 or q.Level01
	end)
end

local function apply(userEnabled: boolean)
	local userOn = userEnabled == true
	local studio = studioPlay()
	-- Studio keeps shadows/bloom/atmosphere. Only land cull + quality cap for FPS.
	FireflyController.setEnabled(not (userOn or studio))
	VegetationSwayController.setEnabled(not (userOn or studio))
	GrassCullController.setLowGraphics(userOn or studio)
	SafeZoneLightingController.setLowGraphics(userOn)
	setHeavyFxEnabled(not userOn)
	setGlobalShadowsEnabled(not userOn)
	setSavedQualityLowest(userOn)
	if studio then
		capStudioRenderQuality()
	end
end

local LowGraphicsController = {}

function LowGraphicsController.isEnabled(): boolean
	return player:GetAttribute(ATTR) == true
end

function LowGraphicsController.init()
	if wired then
		return
	end
	wired = true

	if player:GetAttribute(ATTR) == nil then
		player:SetAttribute(ATTR, false)
	end

	capStudioRenderQuality()
	apply(LowGraphicsController.isEnabled())

	player:GetAttributeChangedSignal(ATTR):Connect(function()
		apply(LowGraphicsController.isEnabled())
	end)

	Lighting.ChildAdded:Connect(function(child)
		if not LowGraphicsController.isEnabled() then
			return
		end
		task.defer(function()
			if not child.Parent or not LowGraphicsController.isEnabled() then
				return
			end
			if isHeavyFx(child) then
				local fx = child :: any
				if child:GetAttribute(ATTR_FX_PREV) == nil then
					child:SetAttribute(ATTR_FX_PREV, fx.Enabled == true)
				end
				fx.Enabled = false
			end
		end)
	end)
end

return LowGraphicsController
