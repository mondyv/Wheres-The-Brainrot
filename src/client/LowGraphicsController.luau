-- [ACTIVE] LowGraphicsController
--[[
	Settings → Low Graphics (Button7). Default off.
	When on: no fireflies, no grass sway, auto-disables Brainrot VFX
	(user can turn VFX back on while staying in low graphics).
	Lighting stays mostly intact — only trims the heaviest post FX slightly.
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

local function apply(enabled: boolean)
	FireflyController.setEnabled(not enabled)
	VegetationSwayController.setEnabled(not enabled)
	SafeZoneLightingController.setLowGraphics(enabled)
	setHeavyFxEnabled(not enabled)
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
