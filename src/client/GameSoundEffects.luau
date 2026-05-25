--[[
	GameSoundEffects — gameplay SFX under SoundService.SoundEffects
	CashGrab: collecting cash from a stand pad
	ErrorNotif: can't afford / purchase rejected
--]]

local SoundService = game:GetService("SoundService")

local cashGrabTemplate: Sound?
local errorNotifTemplate: Sound?

local GameSoundEffects = {}

local function playTemplate(template: Sound?)
	if not template then
		return
	end
	local clone = template:Clone()
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.init()
	local root = SoundService:WaitForChild("SoundEffects", 30)
	if not root then
		warn("[GameSoundEffects] SoundService.SoundEffects missing")
		return
	end
	local cashFolder = root:FindFirstChild("CashGrab")
	if cashFolder then
		cashGrabTemplate = (cashFolder:FindFirstChild("Cash grab sfx") or cashFolder:FindFirstChildWhichIsA("Sound")) :: Sound?
	end
	local errFolder = root:FindFirstChild("ErrorNotif")
	if errFolder then
		errorNotifTemplate = (errFolder:FindFirstChild("Xbox Menu Error") or errFolder:FindFirstChildWhichIsA("Sound")) :: Sound?
	end
end

function GameSoundEffects.playCashGrab()
	playTemplate(cashGrabTemplate)
end

function GameSoundEffects.playErrorNotif()
	playTemplate(errorNotifTemplate)
end

return GameSoundEffects
