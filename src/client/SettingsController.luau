--[[
	SettingsController — Config/Settings frame
	• Slider1 → Background music volume (SoundService.BackgroundMusic.SoundGroup mixer, or Music1 fallback).
	• Slider2 → SoundEffects SoundGroup + UISounds SoundGroup (same slider value).
	• Button rows → toggles; row whose label contains "ui sound" drives UI hover/click sounds.
	• Row whose label contains "slow" → SlowWalkEnabled (1× vs 1.75× base walk); default off; softer hover on that row.
	• Row whose label contains "other" (or Button3) → ShowOtherBrainrots; default on.
	• Row whose label contains "vfx" (or Button4/5) → BrainrotVFXEnabled; default on.
--]]

local Players          = game:GetService("Players")
local SoundService     = game:GetService("SoundService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local HUDController = require(script.Parent.HUDController)
local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local mainGui      = PlayerGuiMain.ensure(player)
local playerGui    = player.PlayerGui
local framesFolder = mainGui:WaitForChild("Frames")
local SETTINGS_NAME = "Config/Settings"

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then return s end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function bindButtonMicroAnim(gui: GuiButton, hoverPeak: number?, downPeak: number?)
	local hoverTo = hoverPeak or 1.06
	local downTo = downPeak or 0.94
	local scale = getOrAddUIScale(gui)
	gui.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = hoverTo }):Play()
	end)
	gui.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
	end)
	gui.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = downTo }):Play()
	end)
	gui.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = hoverTo }):Play()
	end)
end

local function bindRowHoverAnim(row: GuiObject, peakScale: number?)
	local peak = peakScale or 1.02
	local scale = getOrAddUIScale(row)
	row.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = peak }):Play()
	end)
	row.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
	end)
end

local function getOnOffFolder(buttonRow: Instance): Instance?
	local btn = buttonRow:FindFirstChild("Button")
	if not btn then return nil end
	return btn:FindFirstChild("On/Off")
end

local function findClickable(buttonRow: Instance): GuiButton?
	local btn = buttonRow:FindFirstChild("Button")
	if btn then
		local onOff = btn:FindFirstChild("On/Off")
		if onOff then
			local inner = onOff:FindFirstChild("On/Off")
			if inner and inner:IsA("GuiButton") then
				return inner :: GuiButton
			end
		end
		local deep = btn:FindFirstChildWhichIsA("GuiButton", true)
		if deep then return deep end
	end
	return buttonRow:FindFirstChildWhichIsA("GuiButton", true)
end

local function applyToggleVisuals(onOffFolder: Instance, isOn: boolean)
	local function setPair(offInst: Instance?, onInst: Instance?)
		if offInst and offInst:IsA("UIGradient") then
			offInst.Enabled = not isOn
		end
		if onInst and onInst:IsA("UIGradient") then
			onInst.Enabled = isOn
		end
	end

	setPair(onOffFolder:FindFirstChild("Off"), onOffFolder:FindFirstChild("On"))

	local decor = onOffFolder:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	if stud then
		setPair(stud:FindFirstChild("Off"), stud:FindFirstChild("On"))
	end
end

local function setToggleFaceText(onOffFolder: Instance, isOn: boolean)
	local inner = onOffFolder:FindFirstChild("On/Off")
	if inner and (inner:IsA("TextButton") or inner:IsA("TextLabel")) then
		inner.Text = isOn and "On" or "Off"
	end
end

local function readInitialOn(onOffFolder: Instance): boolean
	local on = onOffFolder:FindFirstChild("On")
	if on and on:IsA("UIGradient") then
		return on.Enabled
	end
	local off = onOffFolder:FindFirstChild("Off")
	if off and off:IsA("UIGradient") then
		return not off.Enabled
	end
	return true
end

local function getBackgroundMusicMixer(): SoundGroup?
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

local function getBackgroundMusicSound(): Sound?
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	if not bg then return nil end
	local sg = bg:FindFirstChild("SoundGroup")
	if not sg then return nil end
	local s = sg:FindFirstChild("Music1")
	if s and s:IsA("Sound") then
		return s
	end
	return nil
end

local function getSFXSoundGroup(): SoundGroup?
	local folder = SoundService:FindFirstChild("SoundEffects")
	if not folder then return nil end
	return folder:FindFirstChildWhichIsA("SoundGroup", true)
end

local function getUISoundsMixerGroup(): SoundGroup?
	local folder = SoundService:FindFirstChild("UISounds")
	if not folder then return nil end
	return folder:FindFirstChild("SoundGroup") :: SoundGroup?
end

local function syncMusicVolume(sound: Sound, volume01: number)
	sound.Volume = math.clamp(volume01, 0, 1)
	-- Never Stop() here — stopping resets TimePosition when you turn volume back up.
	if volume01 > 0 and not sound.IsPlaying then
		sound:Play()
	end
	-- At volume 0 the track keeps playing silently so the timeline stays continuous.
end

local function syncGroupVolume(group: SoundGroup, volume01: number)
	group.Volume = math.clamp(volume01, 0, 1)
end

local function getSliderRowTitle(sliderRow: Instance): string
	local n = sliderRow:FindFirstChild("Name")
	if n and n:IsA("TextLabel") then
		return n.Text:lower()
	end
	return ""
end

local function getButtonRowTitle(buttonRow: Instance): string
	local chunks: { string } = {}
	local function addText(text: string)
		local t = string.lower(string.gsub(text, "^%s*(.-)%s*$", "%1"))
		if t ~= "" then
			table.insert(chunks, t)
		end
	end
	local nameNode = buttonRow:FindFirstChild("Name", true)
	if nameNode and (nameNode:IsA("TextLabel") or nameNode:IsA("TextButton")) then
		addText((nameNode :: TextLabel).Text)
	end
	for _, desc in buttonRow:GetDescendants() do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			if string.find(desc.Name, "On", 1, true) and desc.Parent and desc.Parent.Name == "On/Off" then
				continue
			end
			if desc.Name == "On" or desc.Name == "Off" then
				continue
			end
			addText((desc :: TextLabel).Text)
		end
	end
	return table.concat(chunks, " ")
end

local function classifySettingsRow(buttonRow: Instance): string?
	local title = getButtonRowTitle(buttonRow)
	if title:find("ui sound", 1, true) then
		return "ui_sounds"
	end
	if title:find("slow", 1, true) then
		return "slow"
	end
	if title:find("other", 1, true) and title:find("brainrot", 1, true) then
		return "show_others"
	end
	if title:find("show", 1, true) and title:find("other", 1, true) then
		return "show_others"
	end
	if title:find("vfx", 1, true) or title:find("visual", 1, true) then
		return "brainrot_vfx"
	end
	local n = buttonRow.Name
	if n == "Button3" then
		return "show_others"
	end
	if n == "Button4" or n == "Button5" then
		return "brainrot_vfx"
	end
	return nil
end

local function setSlowRowNameLabel(buttonRow: Instance, slowModeOn: boolean)
	local n = buttonRow:FindFirstChild("Name")
	if n and n:IsA("TextLabel") then
		local tl = n :: TextLabel
		if tl.Text:lower():find("slow", 1, true) then
			tl.Text = if slowModeOn then "Slow: On" else "Slow: Off"
		end
	elseif n and n:IsA("TextButton") then
		local tb = n :: TextButton
		if tb.Text:lower():find("slow", 1, true) then
			tb.Text = if slowModeOn then "Slow: On" else "Slow: Off"
		end
	end
end

local function wireVolumeSlider(
	sliderRow: Instance,
	setVolume: (number) -> (),
	getInitialVolume: () -> number
)
	local slider = sliderRow:FindFirstChild("Slider")
	if not slider then return end
	local bg = slider:FindFirstChild("BG") :: GuiObject?
	local thumb = slider:FindFirstChild("Button") :: GuiObject?
	if not bg or not thumb then return end

	bg.Active = true
	thumb.Active = true

	local thumbScale = getOrAddUIScale(thumb)

	local function ratioFromScreenX(screenX: number): number
		local pos = bg.AbsolutePosition
		local size = bg.AbsoluteSize
		if size.X <= 1 then return 0 end
		return math.clamp((screenX - pos.X) / size.X, 0, 1)
	end

	local function applyRatio(r: number, tweenThumb: boolean)
		setVolume(r)
		local yScale = thumb.Position.Y.Scale
		local yOff = thumb.Position.Y.Offset
		local target = UDim2.new(r, 0, yScale, yOff)
		if tweenThumb then
			TweenService:Create(thumb, SLIDE_TWEEN, { Position = target }):Play()
			TweenService:Create(thumbScale, TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 }):Play()
			task.delay(0.1, function()
				TweenService:Create(thumbScale, TweenInfo.new(0.18, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end)
		else
			thumb.Position = target
		end
	end

	applyRatio(math.clamp(getInitialVolume(), 0, 1), false)

	local dragging = false
	local moveConn: RBXScriptConnection? = nil
	local endConn: RBXScriptConnection? = nil

	local function stopDrag()
		if not dragging then return end
		dragging = false
		if moveConn then moveConn:Disconnect() moveConn = nil end
		if endConn then endConn:Disconnect() endConn = nil end
		TweenService:Create(thumbScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end

	local function beginDrag(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		stopDrag() -- clean stale
		dragging = true
		UIInteractionSounds.playClick()
		applyRatio(ratioFromScreenX(input.Position.X), true)

		moveConn = UserInputService.InputChanged:Connect(function(inp: InputObject)
			if not dragging then return end
			if inp.UserInputType == Enum.UserInputType.MouseMovement
				or inp.UserInputType == Enum.UserInputType.Touch then
				applyRatio(ratioFromScreenX(inp.Position.X), false)
			end
		end)

		endConn = UserInputService.InputEnded:Connect(function(inp: InputObject)
			if inp.UserInputType == Enum.UserInputType.MouseButton1
				or inp.UserInputType == Enum.UserInputType.Touch then
				stopDrag()
			end
		end)
	end

	bg.InputBegan:Connect(beginDrag)
	thumb.InputBegan:Connect(beginDrag)

	if sliderRow:IsA("GuiObject") then
		bindRowHoverAnim(sliderRow :: GuiObject)
	end
end

local SettingsController = {}

function SettingsController.init()
	local settingsFrame = framesFolder:WaitForChild(SETTINGS_NAME, 15) :: Frame?
	if not settingsFrame then
		warn("[SettingsController] Frame not found: " .. SETTINGS_NAME)
		return
	end

	local container = settingsFrame:WaitForChild("Container", 10)
	if not container then
		warn("[SettingsController] Config/Settings.Container missing")
		return
	end

	-- Header Close (X): same hover / press scale as other settings buttons
	local header = settingsFrame:FindFirstChild("Header")
	if header then
		local buttons = header:FindFirstChild("Buttons")
		if buttons then
			local close = buttons:FindFirstChild("Close")
			local closeBtn: GuiButton? = if close and close:IsA("GuiButton") then close :: GuiButton
				else close and close:FindFirstChildWhichIsA("GuiButton", true) :: GuiButton?
			if closeBtn then
				UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
					HUDController.closeCurrentFrame()
				end)
			end
		end
	end

	local musicMixer = getBackgroundMusicMixer()
	local musicSound = if not musicMixer then getBackgroundMusicSound() else nil
	if not musicMixer and not musicSound then
		warn("[SettingsController] No BackgroundMusic mixer (SoundGroup) or Music1 under SoundService.BackgroundMusic.SoundGroup")
	end

	local sfxGroup = getSFXSoundGroup()
	local uiMixerGroup = getUISoundsMixerGroup()
	if not sfxGroup and not uiMixerGroup then
		warn("[SettingsController] No SoundGroup for SoundEffects or UISounds — Slider2 skipped")
	end

	ClientSFXVolume.syncFromSoundService()

	local function applySFXSliderVolume(r: number)
		ClientSFXVolume.setVolume(r)
		if sfxGroup then
			syncGroupVolume(sfxGroup, r)
		end
		if uiMixerGroup then
			syncGroupVolume(uiMixerGroup, r)
		end
	end

	local uiSoundsToggleRow: Instance? = nil
	local slowToggleRow: Instance? = nil
	local showOthersToggleRow: Instance? = nil
	local brainrotVfxToggleRow: Instance? = nil
	for _, child in ipairs(container:GetChildren()) do
		if child.Name:match("^Button%d+$") then
			local kind = classifySettingsRow(child)
			if kind == "ui_sounds" then
				uiSoundsToggleRow = child
				local oo = getOnOffFolder(child)
				if oo then
					UIInteractionSounds.setUISoundsEnabled(readInitialOn(oo))
				end
			elseif kind == "slow" then
				slowToggleRow = child
			elseif kind == "show_others" then
				showOthersToggleRow = child
			elseif kind == "brainrot_vfx" and not brainrotVfxToggleRow then
				brainrotVfxToggleRow = child
			end
		end
	end
	if player:GetAttribute("SlowWalkEnabled") == nil then
		player:SetAttribute("SlowWalkEnabled", false)
	end
	if player:GetAttribute("ShowOtherBrainrots") == nil then
		player:SetAttribute("ShowOtherBrainrots", true)
	end
	if player:GetAttribute("BrainrotVFXEnabled") == nil then
		player:SetAttribute("BrainrotVFXEnabled", true)
	end

	local function configureSettingsContainer()
		for _, ch in container:GetChildren() do
			if ch.Name == "ScrollBarAdjuster" and ch:IsA("GuiObject") then
				ch.Active = false
				ch.ZIndex = 1
			end
		end
	end
	configureSettingsContainer()

	local function wireSliderIfMatch(sliderRow: Instance)
		if not sliderRow.Name:match("^Slider%d+$") then
			return
		end
		local title = getSliderRowTitle(sliderRow)
		local isMusic = title:find("music", 1, true) ~= nil or sliderRow.Name == "Slider1"
		local isSfx = title:find("sound", 1, true) ~= nil
			or title:find("effect", 1, true) ~= nil
			or sliderRow.Name == "Slider2"

		if isMusic and musicMixer then
			wireVolumeSlider(sliderRow, function(r)
				syncGroupVolume(musicMixer, r)
			end, function()
				return musicMixer.Volume
			end)
			return
		elseif isMusic and musicSound then
			wireVolumeSlider(sliderRow, function(r)
				syncMusicVolume(musicSound, r)
			end, function()
				return musicSound.Volume
			end)
			return
		end

		if isSfx and (sfxGroup or uiMixerGroup) then
			wireVolumeSlider(sliderRow, applySFXSliderVolume, function()
				return ClientSFXVolume.getVolume()
			end)
			return
		end

		if sliderRow.Name == "Slider1" and musicMixer then
			wireVolumeSlider(sliderRow, function(r)
				syncGroupVolume(musicMixer, r)
			end, function()
				return musicMixer.Volume
			end)
		elseif sliderRow.Name == "Slider1" and musicSound then
			wireVolumeSlider(sliderRow, function(r)
				syncMusicVolume(musicSound, r)
			end, function()
				return musicSound.Volume
			end)
		elseif sliderRow.Name == "Slider2" and (sfxGroup or uiMixerGroup) then
			wireVolumeSlider(sliderRow, applySFXSliderVolume, function()
				return ClientSFXVolume.getVolume()
			end)
		end
	end

	for _, child in ipairs(container:GetChildren()) do
		wireSliderIfMatch(child)
	end

	for _, child in ipairs(container:GetChildren()) do
		if not child.Name:match("^Button%d+$") then
			continue
		end

		local onOff = getOnOffFolder(child)
		if not onOff then
			warn("[SettingsController] No On/Off under " .. child.Name)
			continue
		end

		local toggleOn = if child == slowToggleRow then false
			elseif child == showOthersToggleRow then true
			elseif child == brainrotVfxToggleRow then true
			else readInitialOn(onOff)
		if child == showOthersToggleRow then
			toggleOn = player:GetAttribute("ShowOtherBrainrots") ~= false
		elseif child == brainrotVfxToggleRow then
			toggleOn = player:GetAttribute("BrainrotVFXEnabled") ~= false
		end
		applyToggleVisuals(onOff, toggleOn)
		setToggleFaceText(onOff, toggleOn)
		if child == slowToggleRow then
			setSlowRowNameLabel(child, false)
		end

		local clickable = findClickable(child)
		if not clickable then
			warn("[SettingsController] No GuiButton under " .. child.Name)
			continue
		end

		if child == slowToggleRow then
			bindButtonMicroAnim(clickable, 1.03, 0.97)
			if child:IsA("GuiObject") then
				bindRowHoverAnim(child :: GuiObject, 1.008)
			end
		else
			bindButtonMicroAnim(clickable)
			if child:IsA("GuiObject") then
				bindRowHoverAnim(child :: GuiObject)
			end
		end

		clickable.Activated:Connect(function()
			toggleOn = not toggleOn
			applyToggleVisuals(onOff, toggleOn)
			setToggleFaceText(onOff, toggleOn)
			if child == uiSoundsToggleRow then
				UIInteractionSounds.setUISoundsEnabled(toggleOn)
			end
			if child == slowToggleRow then
				player:SetAttribute("SlowWalkEnabled", toggleOn)
				setSlowRowNameLabel(child, toggleOn)
			end
			if child == showOthersToggleRow then
				player:SetAttribute("ShowOtherBrainrots", toggleOn)
			end
			if child == brainrotVfxToggleRow then
				player:SetAttribute("BrainrotVFXEnabled", toggleOn)
			end
		end)
	end
end

return SettingsController
