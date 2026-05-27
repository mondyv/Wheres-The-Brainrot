--[[
	GameSoundEffects — gameplay SFX under SoundService.SoundEffects
	CashGrab: collecting cash from a stand pad (skips leading silence, combo pitch)
	ErrorNotif: can't afford / purchase rejected
--]]

local SoundService = game:GetService("SoundService")

local cashGrabTemplate: Sound?
local errorNotifTemplate: Sound?

-- Leading silence baked into the cash grab asset (~0.3s).
local CASH_GRAB_START_OFFSET = 0.3
-- Combo: grab again within 1.25s → pitch stacks; longer gap → reset to 1.0.
local CASH_GRAB_COMBO_WINDOW_SEC = 1.25
local CASH_GRAB_PITCH_STEP = 0.08
local CASH_GRAB_MAX_PITCH = 2.0

local lastCashGrabTime = 0.0
local comboCount = 0

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

local function cashGrabStartOffset(template: Sound): number
	local attr = template:GetAttribute("StartOffset")
	if typeof(attr) == "number" and attr >= 0 then
		return attr
	end
	return CASH_GRAB_START_OFFSET
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
	if not cashGrabTemplate then
		return
	end

	local now = os.clock()
	if lastCashGrabTime > 0 and (now - lastCashGrabTime) <= CASH_GRAB_COMBO_WINDOW_SEC then
		comboCount += 1
	else
		comboCount = 0
	end
	lastCashGrabTime = now

	local pitch = math.min(1 + comboCount * CASH_GRAB_PITCH_STEP, CASH_GRAB_MAX_PITCH)

	local clone = cashGrabTemplate:Clone()
	clone.PlaybackSpeed = pitch

	local startAt = cashGrabStartOffset(cashGrabTemplate)
	if startAt > 0 then
		clone.TimePosition = startAt
	end

	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playErrorNotif()
	playTemplate(errorNotifTemplate)
end

return GameSoundEffects
