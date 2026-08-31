-- [ACTIVE] HUDController
--[[
	HUDController
	Manages HUD sidebar buttons → frame toggling with slick animations.
	Also exposes openFrameByName / closeCurrentFrame for other modules.
--]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")

local UIButtonEffects = require(script.Parent.UIButtonEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local PanelSlideIn = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PanelSlideIn"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BoostIconsController = require(script.Parent.BoostIconsController)

local player = Players.LocalPlayer

local mainGui: ScreenGui? = nil
local sideUI: Instance? = nil
local framesFolder: Instance? = nil

local PANEL_BLUR_NAME = "PanelModalBlur"
local PANEL_DIM_GUI_NAME = "PanelModalDim"
local PANEL_BACKDROP_NAME = "PanelClickOutside"
local BLUR_SIZE = 18
local BLUR_SIZE_MOBILE = 28
local BLUR_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MOBILE_PANEL_SCALE = 1.5 / 1.3 -- all HUD panels ~1.15× on mobile
local PANEL_MODAL_MAIN_ORDER = 50

local panelChromeHidden = false
local panelBlur: BlurEffect? = nil
local panelBackdrop: TextButton? = nil
local panelDimGui: ScreenGui? = nil
local panelClosing = false
local savedMainDisplayOrder: number? = nil

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

local function isMobileUi(): boolean
	return UserInputService.TouchEnabled
end

local function panelRestScale(_frame: Frame?): number
	return if isMobileUi() then MOBILE_PANEL_SCALE else 1
end

local function blurTargetSize(): number
	return if isMobileUi() then BLUR_SIZE_MOBILE else BLUR_SIZE
end

-- Tween configs
local OPEN_TWEEN = TweenInfo.new(0.44, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.In)

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

local function clearPanelBlur()
	local blur = panelBlur or Lighting:FindFirstChild(PANEL_BLUR_NAME)
	if blur and blur:IsA("BlurEffect") then
		-- Destroy immediately so close never leaves a stuck blur (tween races).
		blur:Destroy()
		if panelBlur == blur then
			panelBlur = nil
		end
	else
		panelBlur = nil
	end
	local leftover = Lighting:FindFirstChild(PANEL_BLUR_NAME)
	if leftover then
		leftover:Destroy()
	end
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
	TweenService:Create(panelBlur :: BlurEffect, BLUR_TWEEN, { Size = blurTargetSize() }):Play()
end

local function restoreMainDisplayOrder()
	if mainGui and savedMainDisplayOrder ~= nil then
		mainGui.DisplayOrder = savedMainDisplayOrder
		savedMainDisplayOrder = nil
	end
end

local function raiseMainForModalDim(): number
	ensureHudRoots()
	if not mainGui then
		return 10
	end
	if savedMainDisplayOrder == nil then
		savedMainDisplayOrder = mainGui.DisplayOrder
	end
	if mainGui.DisplayOrder < PANEL_MODAL_MAIN_ORDER then
		mainGui.DisplayOrder = PANEL_MODAL_MAIN_ORDER
	end
	return mainGui.DisplayOrder
end

local function destroyPanelBackdrop()
	if panelBackdrop then
		panelBackdrop:Destroy()
		panelBackdrop = nil
	end
	if panelDimGui then
		panelDimGui:Destroy()
		panelDimGui = nil
	end
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		local existing = pg:FindFirstChild(PANEL_DIM_GUI_NAME)
		if existing then
			existing:Destroy()
		end
	end
	restoreMainDisplayOrder()
	ensureHudRoots()
	local frames = framesFolder
	if frames then
		local legacy = frames:FindFirstChild(PANEL_BACKDROP_NAME)
		if legacy then
			legacy:Destroy()
		end
	end
end

local function findPanelCloseButton(frame: Frame): GuiButton?
	local header = frame:FindFirstChild("Header")
	local headerButtons = header and header:FindFirstChild("Buttons")
	local close = headerButtons and headerButtons:FindFirstChild("Close")
	if close and close:IsA("GuiButton") then
		return close :: GuiButton
	end
	if close then
		local nested = close:FindFirstChildOfClass("ImageButton") or close:FindFirstChildOfClass("TextButton")
		if nested then
			return nested
		end
	end
	return nil
end

local function ensurePanelCloseOnTop(frame: Frame)
	local closeBtn = findPanelCloseButton(frame)
	if not closeBtn then
		return
	end
	closeBtn.Active = true
	pcall(function()
		(closeBtn :: any).Interactable = true
	end)
	if closeBtn.ZIndex < 50 then
		closeBtn.ZIndex = 50
	end
	local header = frame:FindFirstChild("Header")
	if header and header:IsA("GuiObject") and header.ZIndex < 40 then
		(header :: GuiObject).ZIndex = 40
	end
	local buttons = header and header:FindFirstChild("Buttons")
	if buttons and buttons:IsA("GuiObject") and (buttons :: GuiObject).ZIndex < 45 then
		(buttons :: GuiObject).ZIndex = 45
	end
	for _, d in closeBtn:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			(d :: GuiObject).Active = false
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

	if frames:IsA("GuiObject") then
		(frames :: GuiObject).ClipsDescendants = false
	end

	local mobile = isMobileUi()

	-- Click-outside sink inside Frames. On mobile the visible dim is a separate
	-- ScreenGui behind a raised Main (safe-area / blur parity with PC).
	local backdrop = Instance.new("TextButton")
	backdrop.Name = PANEL_BACKDROP_NAME
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = if mobile then 1 else 0.55
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 12
	backdrop.Active = true

	local inset = GuiService:GetGuiInset()
	local padX = math.max(inset.X, if mobile then 24 else 8)
	local padTop = math.max(inset.Y, if mobile then 24 else 8)
	local bottomExtra = if mobile then 96 else 28
	backdrop.AnchorPoint = Vector2.new(0, 0)
	backdrop.Position = UDim2.fromOffset(-padX, -padTop)
	backdrop.Size = UDim2.new(1, padX * 2, 1, padTop + bottomExtra)
	backdrop.Parent = frames

	if mobile then
		local pg = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 5)
		if pg then
			-- Raise Main first so dim at (order-1) stays behind the panel (not on top).
			local mainOrder = raiseMainForModalDim()
			local gui = Instance.new("ScreenGui")
			gui.Name = PANEL_DIM_GUI_NAME
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = math.max(0, mainOrder - 1)
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			pcall(function()
				(gui :: any).ClipToDeviceSafeArea = false
			end)
			pcall(function()
				(gui :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
			end)
			pcall(function()
				(gui :: any).ScreenInsets = Enum.ScreenInsets.None
			end)

			local fullDim = Instance.new("Frame")
			fullDim.Name = "FullScreenDim"
			fullDim.BackgroundColor3 = Color3.new(0, 0, 0)
			fullDim.BackgroundTransparency = 0.55
			fullDim.BorderSizePixel = 0
			fullDim.Size = UDim2.fromScale(1, 1)
			fullDim.Position = UDim2.fromScale(0, 0)
			fullDim.Active = false
			fullDim.Parent = gui

			gui.Parent = pg
			panelDimGui = gui
		end
	end

	backdrop.Activated:Connect(function()
		if not MobileTouchGate.canTapUi() then
			return
		end
		local frame = currentFrame
		if not frame then
			return
		end
		local mouse = UserInputService:GetMouseLocation()
		local guiInset = GuiService:GetGuiInset()
		local px = mouse.X - guiInset.X
		local py = mouse.Y - guiInset.Y
		local atPos = player.PlayerGui:GetGuiObjectsAtPosition(px, py)
		local closeBtn = findPanelCloseButton(frame)
		for _, obj in atPos do
			if closeBtn and (obj == closeBtn or obj:IsDescendantOf(closeBtn)) then
				HUDController.closeCurrentFrame()
				return
			end
		end
		for _, obj in atPos do
			if obj ~= backdrop and (obj == frame or obj:IsDescendantOf(frame)) then
				return
			end
		end
		local pos = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		if px >= pos.X and px <= pos.X + size.X and py >= pos.Y and py <= pos.Y + size.Y then
			return
		end
		HUDController.closeCurrentFrame()
	end)

	panelBackdrop = backdrop
end

local function ensurePanelClickSink(frame: Frame)
	local sink = frame:FindFirstChild("_PanelClickSink")
	if sink and sink:IsA("GuiButton") then
		-- Must stay behind Header / Close / content or the X never receives clicks.
		sink.Active = true
		sink.ZIndex = 0
		sink.Selectable = false
		return
	end
	if sink then
		sink:Destroy()
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_PanelClickSink"
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0, 0)
	btn.ZIndex = 0
	btn.Active = true
	btn.Selectable = false
	btn.Parent = frame
end

local function restoreMobileControlsAfterPanel()
	task.defer(function()
		MobileTouchGate.ensureTouchControlsVisible(true)
		MobileTouchGate.restorePlayerMovement()
	end)
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
	panelChromeHidden = false
	GameplayUiVisibility.show()
	clearPanelBlur()
	destroyPanelBackdrop()
	restoreMobileControlsAfterPanel()
end

local KEEP_SIDE_IN_JUNGLE = {
	Return = true,
	Toolbar = true,
	Top = true,
	Right = true,
}

local KEEP_COUNTERS_IN_JUNGLE = {
	SPACE = true,
}

local explorerHudActive = false
local explorerSaved: { [GuiObject]: boolean } = {}

local function hideForExplorer(obj: GuiObject)
	if explorerSaved[obj] == nil then
		explorerSaved[obj] = obj.Visible
	end
	if obj.Visible then
		obj.Visible = false
	end
end

local function restoreExplorerSaved()
	for obj, wasVisible in explorerSaved do
		if obj.Parent then
			obj.Visible = wasVisible
		end
	end
	table.clear(explorerSaved)
end

local function applyExplorerHud(outside: boolean)
	ensureHudRoots()
	local side = sideUI
	if not side then
		return
	end
	if outside then
		for _, child in side:GetChildren() do
			if child:IsA("GuiObject") and not KEEP_SIDE_IN_JUNGLE[child.Name] then
				hideForExplorer(child)
			end
		end
		local counters = side:FindFirstChild("Counters")
		if counters then
			for _, child in counters:GetChildren() do
				if child:IsA("GuiObject") and not KEEP_COUNTERS_IN_JUNGLE[child.Name] then
					hideForExplorer(child)
				end
			end
		end
	else
		restoreExplorerSaved()
	end
	if BoostIconsController.setExplorerHud then
		BoostIconsController.setExplorerHud(outside)
	end
end

local function syncExplorerHud()
	if GameplayUiVisibility.isHidden() then
		return
	end
	local character = player.Character
	local outside = false
	if character and SafezoneUtil.isCacheReady() then
		outside = not SafezoneUtil.isCharacterInSafezone(character)
	end
	if outside == explorerHudActive then
		if outside then
			applyExplorerHud(true)
		end
		return
	end
	explorerHudActive = outside
	applyExplorerHud(outside)
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
	-- CanvasGroup-wrap scrolls + pre-squash scales before Visible (keeps clip + no flash).
	PanelSlideIn.prepareForPanel(frame)
	frame.Visible = true
	local rest = panelRestScale(frame)
	local scale = getOrAddUIScale(frame)
	scale.Scale = rest * 0.78
	frame.Rotation = -1.2
	TweenService:Create(scale, OPEN_TWEEN, { Scale = rest }):Play()
	TweenService:Create(frame, TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Rotation = 0,
	}):Play()
	PanelSlideIn.playForPanel(frame)
end

local function animateClose(frame: Frame)
	PanelSlideIn.playCloseForPanel(frame)
	local prevTween = closeTweenByFrame[frame]
	if prevTween then
		prevTween:Cancel()
		closeTweenByFrame[frame] = nil
	end
	local rest = panelRestScale(frame)
	local scale = getOrAddUIScale(frame)
	TweenService:Create(frame, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Rotation = 1.4,
	}):Play()
	local t = TweenService:Create(scale, CLOSE_TWEEN, { Scale = rest * 0.78 })
	closeTweenByFrame[frame] = t
	t.Completed:Once(function()
		closeTweenByFrame[frame] = nil
		frame.Visible = false
		frame.Active = false
		frame.Rotation = 0
		scale.Scale = rest * 0.78
		panelClosing = false
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
	if not frame.Visible and currentFrame ~= frame then
		showPanelChrome()
		return
	end
	panelClosing = true
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
		local f = frames :: GuiObject
		f.Visible = true
		f.Active = false
		-- Never leave Frames parked off-screen from a prior HUD slide
		if math.abs(f.Position.X.Offset) > 2 or math.abs(f.Position.Y.Offset) > 2 then
			if f.Position.X.Scale == 0 and f.Position.Y.Scale == 0 then
				f.Position = UDim2.fromScale(0, 0)
			end
		end
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
	ensurePanelClickSink(frame)
	ensurePanelCloseOnTop(frame)
	-- Panel content must receive clicks (ScrollingFrames / buy buttons).
	-- Index catalog clones can be hundreds of instances — don't walk those trees every open.
	local function activateInteractive(node: Instance)
		if node.Name == "_PanelClickSink" then
			return
		end
		if node:IsA("GuiButton") or node:IsA("ScrollingFrame") or node:IsA("TextBox") then
			(node :: GuiObject).Active = true
			if node:IsA("GuiButton") and (node :: GuiObject).ZIndex < 2 then
				(node :: GuiObject).ZIndex = 2
			end
		elseif node:IsA("GuiObject") and not node:IsA("GuiButton") then
			if node.Name == "__SweepClip" or node.Name == "__GlistenTrack" or node.Name == "__DiagSweep" then
				(node :: GuiObject).Active = false
			end
		end
	end
	if frame.Name == "Index" then
		local function activateIndexScrollHost(node: Instance, depth: number)
			if depth > 5 then
				return
			end
			if node:IsA("ScrollingFrame") or node:IsA("GuiButton") or node:IsA("TextBox") then
				activateInteractive(node)
			end
			-- Catalog rows live under the ScrollingFrame — don't walk those trees.
			if node:IsA("ScrollingFrame") then
				return
			end
			for _, ch in node:GetChildren() do
				local n = ch.Name
				if string.sub(n, 1, 6) ~= "Entry_" then
					activateIndexScrollHost(ch, depth + 1)
				end
			end
		end
		for _, child in frame:GetChildren() do
			if child.Name == "Container" or child.Name == "_ClippedScroll" then
				activateIndexScrollHost(child, 0)
			else
				activateInteractive(child)
				for _, d in child:GetDescendants() do
					activateInteractive(d)
				end
			end
		end
	else
		for _, d in frame:GetDescendants() do
			activateInteractive(d)
		end
	end
	ensurePanelCloseOnTop(frame)
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
		-- Intentional animated close owns chrome restore.
		if panelClosing then
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

-- Used by StoreController (Chances) and any other HUD micro-buttons.
local function applyHoverAndClick(button: GuiButton, onClicked: () -> ())
	local icon = button:FindFirstChild("Icon", true)
	local tiltTarget: GuiObject = if icon and icon:IsA("GuiObject") then icon else button
	UIButtonEffects.wireTiltHoverButton(button, onClicked, button, tiltTarget, false)
end

local function setupFrameButton(button: GuiButton, frame: Frame)
	frame.Visible = false

	-- ONLY Header.Buttons.Close — recursive "Close"/"X" search wired huge hitboxes and ate panel clicks.
	local closeBtn = findPanelCloseButton(frame)
	if closeBtn then
		UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
			closeFrame(frame)
		end)
	end

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

	-- Open on a clean tap; press-and-drag (camera pan) must not open the panel.
	UIButtonEffects.wireSidebarButton(button, requestOpen)

	wireFrameVisibleBackdropCleanup(frame)
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

	task.spawn(function()
		while true do
			task.wait(0.18)
			syncExplorerHud()
		end
	end)
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
		return
	end
	-- Orphan modal chrome (e.g. panel Visible flipped outside HUD) — always clear blur/dim.
	showPanelChrome()
end

function HUDController.forceClearPanelModal()
	currentFrame = nil
	panelClosing = false
	panelChromeHidden = false
	-- forceShow (not show): interrupted slide-ins can leave hideCount at 0 while
	-- SideUI children stay parked invisible — show() then no-ops forever.
	GameplayUiVisibility.forceShow()
	clearPanelBlur()
	destroyPanelBackdrop()
	restoreMobileControlsAfterPanel()
	ensureHudRoots()
	if sideUI and sideUI:IsA("GuiObject") then
		(sideUI :: GuiObject).Visible = true
	end
	local main = mainGui
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
	end
	syncFramesInputPassthrough()
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

-- Swap the open HUD panel without clearing blur/chrome (e.g. Sell → SellInfo confirm).
function HUDController.replaceOpenFrame(frame: Frame)
	ensureHudRoots()
	makeChromeClickThrough(sideUI)
	local prev = currentFrame
	currentFrame = frame
	if prev and prev ~= frame and prev.Parent then
		local prevTween = closeTweenByFrame[prev]
		if prevTween then
			prevTween:Cancel()
			closeTweenByFrame[prev] = nil
		end
		prev.Visible = false
		prev.Active = false
		local prevScale = getOrAddUIScale(prev)
		prevScale.Scale = panelRestScale(prev) * 0.82
	end
	frame.Active = true
	if frame.ZIndex < 20 then
		frame.ZIndex = 20
	end
	ensurePanelClickSink(frame)
	ensurePanelCloseOnTop(frame)
	for _, d in frame:GetDescendants() do
		if d.Name == "_PanelClickSink" then
			continue
		end
		if d:IsA("GuiButton") or d:IsA("ScrollingFrame") or d:IsA("TextBox") then
			(d :: GuiObject).Active = true
			if d:IsA("GuiButton") and (d :: GuiObject).ZIndex < 2 then
				(d :: GuiObject).ZIndex = 2
			end
		end
	end
	hidePanelChrome()
	animateOpen(frame)
	syncFramesInputPassthrough()
end

HUDController.applyHoverAndClick = applyHoverAndClick

return HUDController
