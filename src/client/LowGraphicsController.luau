-- [ACTIVE] LowGraphicsController
--[[
	Settings → Low Graphics (Button7). Default off.
	When on: lighter lighting, no fireflies, no grass sway, auto-disables Brainrot VFX
	(user can turn VFX back on while staying in low graphics).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local FireflyController = require(script.Parent.FireflyController)
local VegetationSwayController = require(script.Parent.VegetationSwayController)
local SafeZoneLightingController = require(script.Parent.SafeZoneLightingController)

local ATTR = "LowGraphicsEnabled"
local ATTR_FX_PREV = "__LowGfxFxPrevEnabled"

local player = Players.LocalPlayer
local wired = false

local function isHeavyFx(inst: Instance): boolean
	if inst.Name == "UIModalBlur" or inst.Name == "PanelBlur" or inst.Name == "ReviveBlur" then
		return false
	end
	return inst:IsA("BloomEffect")
		or inst:IsA("DepthOfFieldEffect")
		or inst:IsA("SunRaysEffect")
		or inst:IsA("BlurEffect")
		or inst:IsA("ColorCorrectionEffect")
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
		elseif child:IsA("Clouds") then
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

local function apply(enabled: boolean)
	FireflyController.setEnabled(not enabled)
	VegetationSwayController.setEnabled(not enabled)
	SafeZoneLightingController.setLowGraphics(enabled)
	setHeavyFxEnabled(not enabled)

	-- Soften global lighting load without rewriting Technology (not always client-writable).
	pcall(function()
		if enabled then
			if Lighting:GetAttribute("__LowGfxBrightnessPrev") == nil then
				Lighting:SetAttribute("__LowGfxBrightnessPrev", Lighting.Brightness)
				Lighting:SetAttribute("__LowGfxExposurePrev", Lighting.ExposureCompensation)
				Lighting:SetAttribute("__LowGfxShadowSoftPrev", Lighting.EnvironmentDiffuseScale)
				Lighting:SetAttribute("__LowGfxSpecPrev", Lighting.EnvironmentSpecularScale)
			end
			Lighting.Brightness = math.min(Lighting.Brightness, 1.5)
			Lighting.ExposureCompensation = math.clamp(Lighting.ExposureCompensation, -0.4, 0.2)
			Lighting.EnvironmentDiffuseScale = math.min(Lighting.EnvironmentDiffuseScale, 0.35)
			Lighting.EnvironmentSpecularScale = math.min(Lighting.EnvironmentSpecularScale, 0.15)
			Lighting.GlobalShadows = false
		else
			local b = Lighting:GetAttribute("__LowGfxBrightnessPrev")
			local e = Lighting:GetAttribute("__LowGfxExposurePrev")
			local d = Lighting:GetAttribute("__LowGfxShadowSoftPrev")
			local s = Lighting:GetAttribute("__LowGfxSpecPrev")
			if typeof(b) == "number" then
				Lighting.Brightness = b
			end
			if typeof(e) == "number" then
				Lighting.ExposureCompensation = e
			end
			if typeof(d) == "number" then
				Lighting.EnvironmentDiffuseScale = d
			end
			if typeof(s) == "number" then
				Lighting.EnvironmentSpecularScale = s
			end
			Lighting.GlobalShadows = true
			Lighting:SetAttribute("__LowGfxBrightnessPrev", nil)
			Lighting:SetAttribute("__LowGfxExposurePrev", nil)
			Lighting:SetAttribute("__LowGfxShadowSoftPrev", nil)
			Lighting:SetAttribute("__LowGfxSpecPrev", nil)
		end
	end)
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
			if isHeavyFx(child) or child:IsA("Clouds") then
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
