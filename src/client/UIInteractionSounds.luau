-- [ACTIVE] UIInteractionSounds
--[[
	UIHover / UIClick / StoreClick / UINotif from SoundService.UISounds.SoundGroup
	Respects Settings: "UI Sounds" toggle + SFX slider drives SoundGroup volumes.
]]

local SoundService = game:GetService("SoundService")

local GameSoundEffects = require(script.Parent.GameSoundEffects)

local hoverSound: Sound?
local clickSound: Sound?
local storeClickSound: Sound?
local uiNotifSound: Sound?
local uiSoundsOn = true
local lastHoverClock = 0.0
local lastClickClock = 0.0
local HOVER_DEBOUNCE = 0.055
local CLICK_DEBOUNCE = 0.08

local UIInteractionSounds = {}

function UIInteractionSounds.init()
	local folder = SoundService:WaitForChild("UISounds", 20)
	if not folder then
		warn("[UIInteractionSounds] SoundService.UISounds not found")
		return
	end
	local sg = folder:WaitForChild("SoundGroup", 15)
	if not sg then
		warn("[UIInteractionSounds] UISounds.SoundGroup not found")
		return
	end
	hoverSound = sg:FindFirstChild("UIHover") :: Sound?
	clickSound = sg:FindFirstChild("UIClick") :: Sound?
	storeClickSound = sg:FindFirstChild("StoreClick") :: Sound?
	uiNotifSound = sg:FindFirstChild("UINotif") :: Sound?
	if not hoverSound then
		warn("[UIInteractionSounds] UIHover sound missing")
	end
	if not clickSound then
		warn("[UIInteractionSounds] UIClick sound missing")
	end
	if not storeClickSound then
		warn("[UIInteractionSounds] StoreClick sound missing")
	end
	if not uiNotifSound then
		warn("[UIInteractionSounds] UINotif sound missing")
	end
end

function UIInteractionSounds.setUISoundsEnabled(on: boolean)
	uiSoundsOn = on
end

function UIInteractionSounds.playHover()
	if not uiSoundsOn or not hoverSound then
		return
	end
	local now = os.clock()
	if now - lastHoverClock < HOVER_DEBOUNCE then
		return
	end
	lastHoverClock = now
	hoverSound:Play()
end

function UIInteractionSounds.playClick()
	if not uiSoundsOn or not clickSound then
		return
	end
	local now = os.clock()
	if now - lastClickClock < CLICK_DEBOUNCE then
		return
	end
	lastClickClock = now
	clickSound:Play()
end

function UIInteractionSounds.playStoreClick()
	if not uiSoundsOn or not storeClickSound then
		return
	end
	local now = os.clock()
	if now - lastClickClock < CLICK_DEBOUNCE then
		return
	end
	lastClickClock = now
	storeClickSound:Play()
end

function UIInteractionSounds.playNotif()
	if not uiSoundsOn then
		return
	end
	if uiNotifSound then
		uiNotifSound:Play()
		return
	end
	GameSoundEffects.playNotification1()
end

return UIInteractionSounds
