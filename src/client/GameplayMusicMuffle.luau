-- [ACTIVE] GameplayMusicMuffle
--[[
	Underwater / blurry BGM while panels or cutscenes hide the HUD.
	Equalizer + light reverb on SoundService.BackgroundMusic.SoundGroup.
	Ref-counted to match nested GameplayUiVisibility hides.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local M = {}

local EQ_NAME = "GameplayUiMuffleEQ"
local REVERB_NAME = "GameplayUiMuffleReverb"
local FADE_IN = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Underwater-ish profile (dB)
local MUFFLE_HIGH = -24
local MUFFLE_MID = -9
local MUFFLE_LOW = 3
local REVERB_WET = -4
local REVERB_DRY = -2

local depth = 0
local activeTweens: { Tween } = {}

local function cancelTweens()
	for _, tw in activeTweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeTweens)
end

local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any })
	local tw = TweenService:Create(inst, info, props)
	table.insert(activeTweens, tw)
	tw:Play()
	return tw
end

local function getMusicGroup(): SoundGroup?
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	if not bg then
		return nil
	end
	local sg = bg:FindFirstChild("SoundGroup")
	if sg and sg:IsA("SoundGroup") then
		return sg :: SoundGroup
	end
	return nil
end

local function ensureEffects(group: SoundGroup): (EqualizerSoundEffect, ReverbSoundEffect)
	local eq = group:FindFirstChild(EQ_NAME)
	if not eq or not eq:IsA("EqualizerSoundEffect") then
		if eq then
			eq:Destroy()
		end
		local created = Instance.new("EqualizerSoundEffect")
		created.Name = EQ_NAME
		created.HighGain = 0
		created.MidGain = 0
		created.LowGain = 0
		created.Enabled = true
		created.Parent = group
		eq = created
	end

	local reverb = group:FindFirstChild(REVERB_NAME)
	if not reverb or not reverb:IsA("ReverbSoundEffect") then
		if reverb then
			reverb:Destroy()
		end
		local created = Instance.new("ReverbSoundEffect")
		created.Name = REVERB_NAME
		created.DecayTime = 1.6
		created.Density = 0.35
		created.Diffusion = 0.75
		created.DryLevel = 0
		created.WetLevel = -40
		created.Enabled = true
		created.Parent = group
		reverb = created
	end

	return eq :: EqualizerSoundEffect, reverb :: ReverbSoundEffect
end

local function applyMuffle(on: boolean)
	local group = getMusicGroup()
	if not group then
		return
	end
	local eq, reverb = ensureEffects(group)
	cancelTweens()
	local info = if on then FADE_IN else FADE_OUT
	if on then
		eq.Enabled = true
		reverb.Enabled = true
		playTween(eq, info, {
			HighGain = MUFFLE_HIGH,
			MidGain = MUFFLE_MID,
			LowGain = MUFFLE_LOW,
		})
		playTween(reverb, info, {
			WetLevel = REVERB_WET,
			DryLevel = REVERB_DRY,
		})
	else
		playTween(eq, info, {
			HighGain = 0,
			MidGain = 0,
			LowGain = 0,
		})
		playTween(reverb, info, {
			WetLevel = -40,
			DryLevel = 0,
		})
	end
end

function M.push()
	depth += 1
	if depth == 1 then
		applyMuffle(true)
	end
end

function M.pop()
	if depth <= 0 then
		return
	end
	depth -= 1
	if depth == 0 then
		applyMuffle(false)
	end
end

function M.forceClear()
	depth = 0
	applyMuffle(false)
end

return M
