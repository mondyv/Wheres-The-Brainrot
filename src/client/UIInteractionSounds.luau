--[[
	UIInteractionSounds — UIClick / UIHover from SoundService.UISounds.SoundGroup
	Respects Settings: "UI Sounds" toggle + SFX slider drives SoundGroup volumes.
--]]

local SoundService = game:GetService("SoundService")

local hoverSound: Sound?
local clickSound: Sound?
local notifSound: Sound?
local uiSoundsOn = true
local lastHoverClock = 0.0
local HOVER_DEBOUNCE = 0.055

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
	notifSound = sg:FindFirstChild("UINotif") :: Sound?
	if not hoverSound then warn("[UIInteractionSounds] UIHover sound missing") end
	if not clickSound then warn("[UIInteractionSounds] UIClick sound missing") end
end

function UIInteractionSounds.setUISoundsEnabled(on: boolean)
	uiSoundsOn = on
end

function UIInteractionSounds.playHover()
	if not uiSoundsOn or not hoverSound then return end
	local now = os.clock()
	if now - lastHoverClock < HOVER_DEBOUNCE then return end
	lastHoverClock = now
	hoverSound:Play()
end

function UIInteractionSounds.playClick()
	if not uiSoundsOn or not clickSound then return end
	clickSound:Play()
end

function UIInteractionSounds.playNotif()
	if not uiSoundsOn or not notifSound then return end
	notifSound:Play()
end

return UIInteractionSounds
