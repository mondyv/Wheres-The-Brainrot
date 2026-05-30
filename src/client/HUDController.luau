--[[
	HUDController
	Manages HUD sidebar buttons → frame toggling with slick animations.
	Also exposes openFrameByName / closeCurrentFrame for other modules.
--]]

local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")
local SocialService = game:GetService("SocialService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)

local player    = Players.LocalPlayer

-- StarterGui is only copied to PlayerGui after the character loads.
-- Yielding here guarantees Main and its children exist before we reference them.
if not player.Character then
	player.CharacterAdded:Wait()
end

local playerGui    = player.PlayerGui
local mainGui      = playerGui:WaitForChild("Main")
local sideUI       = mainGui:WaitForChild("SideUI")
local framesFolder = mainGui:WaitForChild("Frames")

-- Tween configs
local OPEN_TWEEN  = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Button name (searched recursively across all of mainGui) → Frame name in Frames
local BUTTON_FRAME_MAP = {
	Store   = "Store",
	Index   = "Index",
	Gifts   = "Daily",
	Rebirth = "Rebirth2",
	Config  = "Config/Settings",
}

local currentFrame: Frame? = nil
local closeTweenByFrame: { [Frame]: Tween } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then return s end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function resolveFrame(name: string): Frame?
	return framesFolder:FindFirstChild(name) :: Frame?
end

-- Searches sideUI first, then all of mainGui.
-- If the found instance is a container, grabs the first GuiButton inside it.
local function findButton(name: string): GuiButton?
	local inst = sideUI:FindFirstChild(name, true)
		or mainGui:FindFirstChild(name, true)
	if not inst then return nil end
	if inst:IsA("GuiButton") then return inst :: GuiButton end
	return inst:FindFirstChildOfClass("ImageButton")
		or inst:FindFirstChildOfClass("TextButton") :: GuiButton?
end

-- ── Animation helpers ─────────────────────────────────────────────────────────

local function animateOpen(frame: Frame)
	frame.Visible = true
	local scale = getOrAddUIScale(frame)
	scale.Scale = 0.82
	TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
end

local function animateClose(frame: Frame)
	local prevTween = closeTweenByFrame[frame]
	if prevTween then
		prevTween:Cancel()
		closeTweenByFrame[frame] = nil
	end
	local scale = getOrAddUIScale(frame)
	local t = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
	closeTweenByFrame[frame] = t
	t.Completed:Once(function()
		closeTweenByFrame[frame] = nil
		frame.Visible = false
		scale.Scale = 0.82 -- reset for next open
	end)
	t:Play()
end

-- ── Core open / close ─────────────────────────────────────────────────────────

local function closeFrame(frame: Frame)
	if not frame.Visible then
		return
	end
	if currentFrame == frame then
		currentFrame = nil
	end
	animateClose(frame)
end

local function openFrame(frame: Frame)
	if currentFrame == frame then
		closeFrame(frame)
		return
	end
	-- Fire close on the old frame immediately — don't wait for it
	if currentFrame then
		animateClose(currentFrame)
	end
	-- Start opening the new frame at the same time, no sequential delay
	currentFrame = frame
	animateOpen(frame)
end

-- Closing via Studio Close under Header, scripts toggling Visible, etc.
local function wireFrameVisibleBackdropCleanup(frame: Frame)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			return
		end
		if currentFrame ~= nil and currentFrame ~= frame then
			return
		end
		if currentFrame == frame then
			currentFrame = nil
		end
	end)
end

-- ── Button helpers ────────────────────────────────────────────────────────────

local TILT_HOVER = TweenInfo.new(0.18, Enum.EasingStyle.Back,    Enum.EasingDirection.Out)
local TILT_LEAVE = TweenInfo.new(0.22, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local TILT_CLICK = TweenInfo.new(0.08, Enum.EasingStyle.Quad,    Enum.EasingDirection.Out)

-- Full sidebar-button animation: scale on the button + tilt on its Icon child.
-- Used by every HUD button (frame-openers AND invite).
local function applyHoverAndClick(button: GuiButton, onClicked: () -> ())
	local scale = getOrAddUIScale(button)
	local icon  = button:FindFirstChild("Icon", true)

	button.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.10 }):Play()
		if icon then TweenService:Create(icon, TILT_HOVER, { Rotation = -10 }):Play() end
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
		if icon then TweenService:Create(icon, TILT_LEAVE, { Rotation = 0 }):Play() end
	end)
	button.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		if icon then TweenService:Create(icon, TILT_CLICK, { Rotation = 6 }):Play() end
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.10 }):Play()
		if icon then TweenService:Create(icon, TILT_HOVER, { Rotation = -10 }):Play() end
	end)
	button.MouseButton1Click:Connect(onClicked)
end

local function setupFrameButton(button: GuiButton, frame: Frame)
	frame.Visible = false
	local header = frame:FindFirstChild("Header")
	local buttons = header and header:FindFirstChild("Buttons")
	local closeBtn = buttons and buttons:FindFirstChild("Close")
	if closeBtn and closeBtn:IsA("GuiButton") then
		UIButtonEffects.wireGlistenCloseButton(closeBtn :: GuiButton, function()
			closeFrame(frame)
		end)
	else
		for _, name in ipairs({ "Close", "CloseButton", "Exit", "X" }) do
			local btn = frame:FindFirstChild(name, true)
			if btn and btn:IsA("GuiButton") then
				UIButtonEffects.wireGlistenCloseButton(btn, function()
					closeFrame(frame)
				end)
				break
			end
		end
	end
	UIButtonEffects.wireSidebarButton(button, function()
		openFrame(frame)
	end)
	wireFrameVisibleBackdropCleanup(frame)
end

-- ── SlowButton toggle ─────────────────────────────────────────────────────────
-- Must be defined BEFORE HUDController.init so the local is in scope.

local function setupSlowButton()
	local slowBtn = sideUI:FindFirstChild("SlowButton", true)
	if not slowBtn then
		warn("[HUDController] SlowButton not found")
		return
	end

	local offImg = slowBtn:FindFirstChild("Off")
	local onImg = slowBtn:FindFirstChild("On")

	local decor = slowBtn:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	local studOff = stud and stud:FindFirstChild("Off")
	local studOn = stud and stud:FindFirstChild("On")

	local nameLabel = slowBtn:FindFirstChild("Name")

	local function setToggleGraphic(inst: Instance?, visible: boolean)
		if not inst then
			return
		end
		if inst:IsA("UIGradient") then
			(inst :: UIGradient).Enabled = visible
		elseif inst:IsA("GuiObject") then
			(inst :: GuiObject).Visible = visible
		end
	end

	local function applyStateFromAttribute()
		local isOn = player:GetAttribute("SlowWalkEnabled") == true
		setToggleGraphic(offImg, not isOn)
		setToggleGraphic(onImg, isOn)
		setToggleGraphic(studOff, not isOn)
		setToggleGraphic(studOn, isOn)
		if nameLabel and nameLabel:IsA("TextLabel") then
			(nameLabel :: TextLabel).Text = if isOn then "Slow: On" else "Slow: Off"
		elseif nameLabel and nameLabel:IsA("TextButton") then
			(nameLabel :: TextButton).Text = if isOn then "Slow: On" else "Slow: Off"
		end
	end

	if player:GetAttribute("SlowWalkEnabled") == nil then
		player:SetAttribute("SlowWalkEnabled", false)
	end
	applyStateFromAttribute()

	player:GetAttributeChangedSignal("SlowWalkEnabled"):Connect(applyStateFromAttribute)

	local btn: GuiButton? = if slowBtn:IsA("GuiButton") then slowBtn :: GuiButton
		else (slowBtn:FindFirstChildOfClass("ImageButton") or slowBtn:FindFirstChildOfClass("TextButton") :: GuiButton?)

	if not btn then
		warn("[HUDController] SlowButton has no clickable GuiButton child")
		return
	end

	local scale = getOrAddUIScale(slowBtn :: Instance)

	btn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.03 }):Play()
		UIButtonEffects.playBorderGlisten(slowBtn :: GuiObject)
	end)
	btn.MouseLeave:Connect(function()
		UIButtonEffects.hideHoverEffects(slowBtn :: GuiObject)
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
	end)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.97 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.03 }):Play()
	end)

	btn.MouseButton1Click:Connect(function()
		player:SetAttribute("SlowWalkEnabled", not (player:GetAttribute("SlowWalkEnabled") == true))

		local pulse = TweenService:Create(scale,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1.08 })
		pulse.Completed:Once(function()
			TweenService:Create(scale,
				TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1.0 }):Play()
		end)
		pulse:Play()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local HUDController = {}

function HUDController.init()
	-- Frame-opening HUD buttons
	for buttonName, frameName in pairs(BUTTON_FRAME_MAP) do
		local button = findButton(buttonName)
		local frame  = resolveFrame(frameName)
		if not button then
			warn("[HUDController] Button not found: " .. buttonName)
			continue
		end
		if not frame then
			warn("[HUDController] Frame not found: " .. frameName)
			continue
		end
		setupFrameButton(button, frame)
	end

	-- Invite button → Roblox social invite prompt
	local inviteBtn = findButton("Invite")
	if inviteBtn then
		UIButtonEffects.wireSidebarButton(inviteBtn, function()
			pcall(function()
				SocialService:PromptGameInvite(player)
			end)
		end)
	else
		warn("[HUDController] Invite button not found")
	end

	-- SlowButton toggle
	setupSlowButton()

	-- Cash counter Buy button → opens Store frame
	local counters = sideUI:FindFirstChild("Counters")
	if counters then
		local cashBuy = counters:FindFirstChild("Buy", true) :: GuiButton?
		if cashBuy and cashBuy:IsA("GuiButton") then
			local storeFrame = resolveFrame("Store")
			if storeFrame then
				UIButtonEffects.wireAccentButton(cashBuy, function()
					openFrame(storeFrame)
				end)
			end
		else
			warn("[HUDController] Cash Buy button not found under Counters")
		end
	end
end

function HUDController.openFrameByName(frameName: string)
	local frame = resolveFrame(frameName)
	if frame then
		openFrame(frame)
	else
		warn("[HUDController] openFrameByName: frame not found: " .. frameName)
	end
end

function HUDController.closeCurrentFrame()
	if currentFrame then
		closeFrame(currentFrame)
	end
end

function HUDController.getCurrentFrame(): Frame?
	return currentFrame
end

HUDController.applyHoverAndClick = applyHoverAndClick

return HUDController
