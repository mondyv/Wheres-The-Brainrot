--[[
	GameSoundEffects — gameplay SFX under SoundService.SoundEffects
	CashGrab: collecting cash from a stand pad
	ErrorNotif: can't afford / purchase rejected
--]]

local SoundService = game:GetService("SoundService")

local cashGrabSound: Sound?
local errorNotifSound: Sound?

local GameSoundEffects = {}

local function playOneShot(sound: Sound?)
	if not sound then
		return
	end
	if sound.IsPlaying then
		sound:Stop()
	end
	sound.TimePosition = 0
	sound:Play()
end

function GameSoundEffects.init()
	local root = SoundService:WaitForChild("SoundEffects", 30)
	if not root then
		warn("[GameSoundEffects] SoundService.SoundEffects missing")
		return
	end
	local cashFolder = root:FindFirstChild("CashGrab")
	if cashFolder then
		cashGrabSound = (cashFolder:FindFirstChild("Cash grab sfx") or cashFolder:FindFirstChildWhichIsA("Sound")) :: Sound?
	end
	local errFolder = root:FindFirstChild("ErrorNotif")
	if errFolder then
		errorNotifSound = (errFolder:FindFirstChild("Xbox Menu Error") or errFolder:FindFirstChildWhichIsA("Sound")) :: Sound?
	end
end

function GameSoundEffects.playCashGrab()
	playOneShot(cashGrabSound)
end

function GameSoundEffects.playErrorNotif()
	playOneShot(errorNotifSound)
end

return GameSoundEffects
