-- [ACTIVE] HUDController
--[[
	HUDController
	Manages HUD sidebar buttons → frame toggling with slick animations.
	Also exposes openFrameByName / closeCurrentFrame for other modules.
--]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SocialService = game:GetService("SocialService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local MobileHaptics = require(script.Parent.MobileHaptics)
local PanelSlideIn = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PanelSlideIn"))

local player = Players.LocalPlayer

local mainGui: ScreenGui? = nil
local sideUI: Instance? = nil
local framesFolder: Instance? = nil

local PANEL_BLUR_NAME = "PanelModalBlur"
local PANEL_BACKDROP_NAME = "PanelClickOutside"
local BLUR_SIZE = 14
local BLUR_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local panelChromeHidden = false
local panelBlur: BlurEffect? = nil
local panelBackdrop: TextButton? = nil

-- Module table declared early so backdrop callbacks never see a nil HUDController.
local HUDController = {}

local function ensureHudRoots()
	if mainGui then
		return
	end
	mainGui = PlayerGuiMain.ensure(player)
	sideUI = mainGui:WaitForChild("SideUI")
	framesFolder = mainGui:WaitForChild("Frames")
end

-- Tween configs
local OPEN_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Button name (searched recursively across all of mainGui) → Frame name in Frames
local BUTTON_FRAME_MAP = {
	Store = "Store",
	Index = "Index",
	Gifts = "Daily",
	Rebirth = "Rebirth2",
	Config = "Config/Settings",
}

local currentFrame: Frame? = nil
local closeTweenByFrame: { [Frame]: Tween } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function resolveFrame(name: string): Frame?
	ensureHudRoots()
	return (framesFolder :: Instance):FindFirstChild(name) :: Frame?
end

local function ensurePanelBlur()
	local existing = Lighting:FindFirstChild(PANEL_BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		panelBlur = existing
	else
		if existing then
			existing:Destroy()
		end
		local blur = Instance.new("BlurEffect")
		blur.Name = PANEL_BLUR_NAME
		blur.Size = 0
		blur.Parent = Lighting
		panelBlur = blur
	end
	TweenService:Create(panelBlur :: BlurEffect, BLUR_TWEEN, { Size = BLUR_SIZE }):Play()
end

local function clearPanelBlur()
	local blur = panelBlur or Lighting:FindFirstChild(PANEL_BLUR_NAME)
	if blur and blur:IsA("BlurEffect") then
		local tw = TweenService:Create(blur, BLUR_TWEEN, { Size = 0 })
		tw.Completed:Once(function()
			if blur.Parent then
				blur:Destroy()
			end
			if panelBlur == blur then
				panelBlur = nil
			end
		end)
		tw:Play()
	else
		panelBlur = nil
	end
end

local function destroyPanelBackdrop()
	if panelBackdrop then
		panelBackdrop:Destroy()
		panelBackdrop = nil
	end
	ensureHudRoots()
	local frames = framesFolder
	if frames then
		local existing = frames:FindFirstChild(PANEL_BACKDROP_NAME)
		if existing then
			existing:Destroy()
		end
	end
end

local function ensurePanelBackdrop()
	ensureHudRoots()
	local frames = framesFolder
	if not frames or not frames:IsA("GuiObject") then
		return
	end
	destroyPanelBackdrop()

	local backdrop = Instance.new("TextButton")
	backdrop.Name = PANEL_BACKDROP_NAME
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.55
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Position = UDim2.fromScale(0, 0)
	backdrop.AnchorPoint = Vector2.new(0, 0)
	backdrop.ZIndex = 12
	backdrop.Active = true
	backdrop.Parent = frames

	backdrop.Activated:Connect(function()
		local frame = currentFrame
		if frame then
			MobileHaptics.tap()
			HUDController.closeCurrentFrame()
		end
	end)

	panelBackdrop = backdrop
end

local function hidePanelChrome()
	if panelChromeHidden then
		ensurePanelBlur()
		ensurePanelBackdrop()
		return
	end
	panelChromeHidden = true
	GameplayUiVisibility.hide({ keepMainChildNames = { "Frames" } })
	ensurePanelBlur()
	ensurePanelBackdrop()
end

local function showPanelChrome()
	if not panelChromeHidden then
		clearPanelBlur()
		destroyPanelBackdrop()
		return
	end
	panelChromeHidden = false
	GameplayUiVisibility.show()
	clearPanelBlur()
	destroyPanelBackdrop()
end

-- Searches SideUI only (never Main.Frames — that wrongly wired panel-internal buttons).
-- Prefers a child named Button; makes non-button visuals non-Active so they don't steal clicks.
local function findButton(name: string): GuiButton?
	ensureHudRoots()
	local side = sideUI :: Instance
	local inst = side:FindFirstChild(name, true)
	if not inst then
		return nil
	end
	-- Reject anything that somehow sits under Frames.
	if inst:IsDescendantOf((framesFolder :: Instance)) then
		return nil
	end

	local btn: GuiButton? = nil
	if inst:IsA("GuiButton") then
		btn = inst :: GuiButton
	else
		local named = inst:FindFirstChild("Button")
		if named and named:IsA("GuiButton") then
			btn = named :: GuiButton
		else
			btn = inst:FindFirstChildOfClass("ImageButton") or inst:FindFirstChildOfClass("TextButton")
		end
	end
	if not btn then
		return nil
	end

	btn.Active = true
	btn.Selectable = true
	for _, d in btn:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			(d :: GuiObject).Active = false
		end
	end
	return btn
end

-- ── Animation helpers ─────────────────────────────────────────────────────────

-- Forward-declared: animateClose's Completed callback must not see a nil upvalue.
local syncFramesInputPassthrough: () -> ()

local function animateOpen(frame: Frame)
	frame.Visible = true
	local scale = getOrAddUIScale(frame)
	scale.Scale = 0.82
	TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
	PanelSlideIn.playForPanel(frame)
end

local function animateClose(frame: Frame)
	PanelSlideIn.cancel()
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
		frame.Active = false
		scale.Scale = 0.82
		if syncFramesInputPassthrough then
			syncFramesInputPassthrough()
		end
		if currentFrame == nil then
			showPanelChrome()
		end
	end)
	t:Play()
end

-- ── Core open / close ─────────────────────────────────────────────────────────

local function makeChromeClickThrough(root: Instance?)
	if not root or not root:IsA("GuiObject") then
		return
	end
	-- Fullscreen / large chrome must not steal clicks from Frames panels.
	(root :: GuiObject).Active = false
	for _, d in root:GetDescendants() do
		if d:IsA("GuiButton") then
			(d :: GuiButton).Active = true
			pcall(function()
				(d :: any).Interactable = true
			end)
		elseif d:IsA("TextBox") then
			(d :: TextBox).Active = true
		elseif d:IsA("ScrollingFrame") then
			(d :: ScrollingFrame).Active = true
		elseif d:IsA("GuiObject") then
			-- Decorative hosts (icons, panels used as layout) pass clicks through.
			local name = d.Name
			if name == "__SweepClip" or name == "__GlistenTrack" or name == "__DiagSweep" or name == "Glint" then
				(d :: GuiObject).Active = false
			elseif not d:IsA("GuiButton") then
				-- Keep known interactive hosts active only if they are scrolling/input.
				-- Everything else under SideUI chrome should pass through.
				if d:FindFirstAncestorWhichIsA("GuiButton") then
					-- inside a button: already handled; leave false so button gets the click
					(d :: GuiObject).Active = false
				else
					(d :: GuiObject).Active = false
				end
			end
		end
	end
end

syncFramesInputPassthrough = function()
	ensureHudRoots()
	local side = sideUI
	local frames = framesFolder
	if not side or not frames then
		return
	end
	local sideZ = if side:IsA("GuiObject") then (side :: GuiObject).ZIndex else 1
	if frames:IsA("GuiObject") then
		local f = frames :: GuiObject
		f.Visible = true
		-- CRITICAL: Frames is fullscreen. Active=true steals camera orbit/zoom (mouse icon stays).
		-- Only the open panel should capture input; empty Frames must click through.
		f.Active = false
		if f.ZIndex <= sideZ then
			f.ZIndex = sideZ + 10
		end
	end
	if currentFrame and currentFrame.Parent and currentFrame.Visible then
		currentFrame.Active = true
		if currentFrame.ZIndex < 20 then
			currentFrame.ZIndex = 20
		end
	end
end

local function closeFrame(frame: Frame)
	if not frame.Visible then
		return
	end
	if currentFrame == frame then
		currentFrame = nil
	end
	animateClose(frame)
	task.defer(syncFramesInputPassthrough)
end

local function openFrame(frame: Frame)
	ensureHudRoots()
	makeChromeClickThrough(sideUI)
	syncFramesInputPassthrough()

	local frames = framesFolder
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
		(frames :: GuiObject).Active = false
	end
	-- Ensure parent chain isn't hiding the panel (don't force `frame` yet — toggle needs prior Visible).
	local p: Instance? = frame.Parent
	while p and p ~= mainGui do
		if p:IsA("GuiObject") and p ~= framesFolder then
			(p :: GuiObject).Visible = true
		end
		p = p.Parent
	end

	if currentFrame == frame and frame.Visible then
		closeFrame(frame)
		return
	end
	if currentFrame and currentFrame ~= frame then
		animateClose(currentFrame)
	end
	currentFrame = frame
	frame.Active = true
	if frame.ZIndex < 20 then
		frame.ZIndex = 20
	end
	-- Panel content must receive clicks (ScrollingFrames / buy buttons).
	for _, d in frame:GetDescendants() do
		if d:IsA("GuiButton") or d:IsA("ScrollingFrame") or d:IsA("TextBox") then
			(d :: GuiObject).Active = true
		elseif d:IsA("GuiObject") and not d:IsA("GuiButton") then
			-- Keep decorative layers from eating camera when they overflow the panel.
			if d.Name == "__SweepClip" or d.Name == "__GlistenTrack" or d.Name == "__DiagSweep" then
				(d :: GuiObject).Active = false
			end
		end
	end
	hidePanelChrome()
	animateOpen(frame)
	syncFramesInputPassthrough()
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
		if currentFrame == nil then
			showPanelChrome()
		end
	end)
end

-- ── Button helpers ────────────────────────────────────────────────────────────

local TILT_HOVER = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TILT_LEAVE = TweenInfo.new(0.22, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local TILT_CLICK = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Used by StoreController (Chances) and any other HUD micro-buttons.
local function applyHoverAndClick(button: GuiButton, onClicked: () -> ())
	local scale = getOrAddUIScale(button)
	local icon = button:FindFirstChild("Icon", true)
	local lastFire = 0
	local function fire()
		local now = os.clock()
		if now - lastFire < 0.12 then
			return
		end
		lastFire = now
		onClicked()
	end

	button.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.10 }):Play()
		if icon and icon:IsA("GuiObject") then
			TweenService:Create(icon, TILT_HOVER, { Rotation = -10 }):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
		if icon and icon:IsA("GuiObject") then
			TweenService:Create(icon, TILT_LEAVE, { Rotation = 0 }):Play()
		end
	end)
	button.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		if icon and icon:IsA("GuiObject") then
			TweenService:Create(icon, TILT_CLICK, { Rotation = 6 }):Play()
		end
		fire()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.10 }):Play()
		if icon and icon:IsA("GuiObject") then
			TweenService:Create(icon, TILT_HOVER, { Rotation = -10 }):Play()
		end
	end)
end

local function setupFrameButton(button: GuiButton, frame: Frame)
	frame.Visible = false

	-- ONLY Header.Buttons.Close — recursive "Close"/"X" search wired huge hitboxes and ate panel clicks.
	local header = frame:FindFirstChild("Header")
	local headerButtons = header and header:FindFirstChild("Buttons")
	local closeBtn = headerButtons and headerButtons:FindFirstChild("Close")
	if closeBtn and closeBtn:IsA("GuiButton") then
		UIButtonEffects.wireGlistenCloseButton(closeBtn :: GuiButton, function()
			closeFrame(frame)
		end)
	end

	-- Visual polish only (open is bound separately).
	UIButtonEffects.wireSidebarButton(button, function() end)

	button.Active = true
	pcall(function()
		(button :: any).Interactable = true
	end)
	for _, d in button:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			(d :: GuiObject).Active = false
		end
	end

	local lastFire = 0
	local function requestOpen()
		local now = os.clock()
		if now - lastFire < 0.2 then
			return
		end
		lastFire = now
		openFrame(frame)
	end

	button.MouseButton1Down:Connect(requestOpen)

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

	local btn: GuiButton? = if slowBtn:IsA("GuiButton")
		then slowBtn :: GuiButton
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

		local pulse = TweenService:Create(
			scale,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1.08 }
		)
		pulse.Completed:Once(function()
			TweenService
				:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.0 })
				:Play()
		end)
		pulse:Play()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function HUDController.init()
	if (HUDController :: any)._initialized then
		return
	end
	(HUDController :: any)._initialized = true

	ensureHudRoots()
	makeChromeClickThrough(sideUI)
	-- Other Main chrome that is often fullscreen and steals panel clicks.
	if mainGui then
		for _, name in { "Purchased", "GameGradients", "Boosts" } do
			makeChromeClickThrough(mainGui:FindFirstChild(name))
		end
		-- Main itself must not modal-lock the mouse.
		pcall(function()
			(mainGui :: any).Modal = false
		end)
	end
	syncFramesInputPassthrough()

	-- Frame-opening HUD buttons
	for buttonName, frameName in pairs(BUTTON_FRAME_MAP) do
		local button = findButton(buttonName)
		local frame = resolveFrame(frameName)
		if not button then
			continue
		end
		if not frame then
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

	-- Cash counter + button → opens Store scrolled to cash bundles at the bottom
	local counters = sideUI:FindFirstChild("Counters")
	if counters then
		local cashFrame = counters:FindFirstChild("Cash")
		local cashBuy: GuiButton? = nil
		if cashFrame then
			for _, name in { "Buy", "+", "Plus" } do
				local candidate = cashFrame:FindFirstChild(name, true)
				if candidate and candidate:IsA("GuiButton") then
					cashBuy = candidate :: GuiButton
					break
				end
			end
			if not cashBuy then
				for _, desc in cashFrame:GetDescendants() do
					if desc:IsA("ImageButton") and (desc.Name == "Buy" or desc.Name == "+" or desc.Name == "Plus") then
						cashBuy = desc :: GuiButton
						break
					end
				end
			end
		end
		if not cashBuy then
			local fallback = counters:FindFirstChild("Buy", true)
			if fallback and fallback:IsA("GuiButton") then
				cashBuy = fallback :: GuiButton
			end
		end
		if cashBuy then
			UIButtonEffects.wireAccentButton(cashBuy, function()
				HUDController.openStoreAtBottom()
			end)
		else
			warn("[HUDController] Cash + / Buy button not found under Counters")
		end
	end
end

function HUDController.openFrameByName(frameName: string)
	-- Legacy stand pad name for the Robux store — Shop now opens the dealer
	-- panel directly (Frames.Shop); Store is still reachable via SideUI/HUD.
	if frameName == "Shop2" then
		frameName = "Store"
	end
	local frame = resolveFrame(frameName)
	if frame then
		openFrame(frame)
	end
end

function HUDController.closeCurrentFrame()
	if currentFrame then
		closeFrame(currentFrame)
	end
end

function HUDController.syncInputPassthrough()
	syncFramesInputPassthrough()
end

function HUDController.closeFrameByName(frameName: string)
	local frame = resolveFrame(frameName)
	if frame then
		closeFrame(frame)
	end
end

local function scrollStoreToBottom(storeFrame: Frame)
	local bestScroll: ScrollingFrame? = nil
	local bestCanvas = 0
	for _, desc in storeFrame:GetDescendants() do
		if desc:IsA("ScrollingFrame") then
			local scroll = desc :: ScrollingFrame
			local canvasH = scroll.CanvasSize.Y.Offset
			if canvasH > bestCanvas then
				bestCanvas = canvasH
				bestScroll = scroll
			end
		end
	end
	if not bestScroll then
		return
	end
	local scroll = bestScroll
	local function apply()
		local maxY = math.max(0, scroll.CanvasSize.Y.Offset - scroll.AbsoluteWindowSize.Y)
		scroll.CanvasPosition = Vector2.new(0, maxY)
	end
	apply()
	local conn: RBXScriptConnection? = nil
	conn = scroll:GetPropertyChangedSignal("CanvasSize"):Connect(function()
		apply()
	end)
	task.delay(0.2, function()
		apply()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end)
end

function HUDController.openStoreAtBottom()
	local storeFrame = resolveFrame("Store")
	if not storeFrame then
		warn("[HUDController] Store frame not found")
		return
	end
	local alreadyOpen = currentFrame == storeFrame and storeFrame.Visible
	if not alreadyOpen then
		openFrame(storeFrame)
	end
	task.spawn(function()
		task.wait()
		scrollStoreToBottom(storeFrame)
		task.wait(0.1)
		scrollStoreToBottom(storeFrame)
	end)
end

function HUDController.getCurrentFrame(): Frame?
	return currentFrame
end

HUDController.applyHoverAndClick = applyHoverAndClick

return HUDController
