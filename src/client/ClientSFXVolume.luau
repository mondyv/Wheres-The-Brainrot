-- [ACTIVE] ClientSFXVolume
--[[
	Client SFX volume (0–1) — mirrors Settings Slider2 / SoundService.SoundEffects.SoundGroup.
	Brainrot SFX and other cloned sounds use this when not routed through the group alone.
]]

local SoundService = game:GetService("SoundService")

local ClientSFXVolume = {}

local currentSFXVolume = 1

local function resolveSFXSoundGroup(): SoundGroup?
	local folder = SoundService:FindFirstChild("SoundEffects")
	if not folder then
		return nil
	end
	return folder:FindFirstChildWhichIsA("SoundGroup", true)
end

function ClientSFXVolume.setVolume(volume01: number)
	currentSFXVolume = math.clamp(volume01, 0, 1)
end

function ClientSFXVolume.getVolume(): number
	return currentSFXVolume
end

function ClientSFXVolume.syncFromSoundService(): number
	local group = resolveSFXSoundGroup()
	if group then
		currentSFXVolume = math.clamp(group.Volume, 0, 1)
	end
	return currentSFXVolume
end

function ClientSFXVolume.getSoundGroup(): SoundGroup?
	return resolveSFXSoundGroup()
end

return ClientSFXVolume
