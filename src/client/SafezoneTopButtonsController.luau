-- [ACTIVE] SafezoneTopButtonsController
--[[
	SideUI.Top.Buttons (Sell / Base / Upgrade):
	• Visible only inside the safe zone (fade + staggered scale-in)
	• Hover / press polish matching Return chrome
	• Smooth black fade teleport via SafezoneQuickNav
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local WebTrapConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WebTrapConfig"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local TopNotifController = require(script.Parent.TopNotifController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)

local SafezoneTopButtonsController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BUTTON_ORDER = { "Sell", "Base", "Upgrade" }
local VISIBILITY_POLL_SEC = 0.12
local INSIDE_STREAK_TO_SHOW = 2
local OUTSIDE_STREAK_TO_HIDE = 2

local SHOW_BAR_TWEEN = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_BAR_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BTN_SHOW_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BTN_HIDE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_IN_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_OUT_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRADIENT_HOVER_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRADIENT_IDLE_TWEEN = TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STAGGER_SEC = 0.055

type BtnState = {
	name: string,
	host: GuiObject,
	btn: GuiButton,
	scale: UIScale,
	restRotation: number,
	gradients: { UIGradient },
	gradRest: { [UIGradient]: { rotation: number, offset: Vector2 } },
	gradTweens: { [UIGradient]: Tween },
	hovering: boolean,
	wired: boolean,
}

local buttonsRoot: GuiObject? = nil
local barScale: UIScale? = nil
local btnStates: { BtnState } = {}
local navRF: RemoteFunction? = nil

local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil

local visibleTarget = false
local visibilityGen = 0
local barTween: Tween? = nil
local teleportBusy = false
local pollAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local insideStreak = 0
local outsideStreak = 0
local lastFireAt = 0

local function getOrAddUIScale(parent: GuiObject): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = parent
	return s
end

local function collectGradients(root: Instance): ({ UIGradient }, { [UIGradient]: { rotation: number, offset: Vector2 } })
	local list: { UIGradient } = {}
	local rest: { [UIGradient]: { rotation: number, offset: Vector2 } } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("UIGradient") then
			table.insert(list, d)
			rest[d] = { rotation = d.Rotation, offset = d.Offset }
		end
	end
	return list, rest
end

local function resolveClickable(host: Instance): GuiButton?
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local named = host:FindFirstChild("Button")
	if named and named:IsA("GuiButton") then
		return named :: GuiButton
	end
	local nested = host:FindFirstChildWhichIsA("GuiButton", true)
	if nested then
		return nested
	end
	return nil
end

local function ensureFadeGui(): Frame
	if fadeFrame and fadeGui and fadeGui.Parent then
		return fadeFrame
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SafezoneTopNavFade"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 200
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Active = true
	frame.Parent = sg

	fadeGui = sg
	fadeFrame = frame
	return frame
end

local function waitForTween(tween: Tween)
	local finished = false
	local conn = tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			finished = true
		end
	end)
	tween:Play()
	while not finished do
		task.wait(0.03)
	end
	conn:Disconnect()
end

local function playFadeIn(): Tween
	local frame = ensureFadeGui()
	frame.Visible = true
	frame.BackgroundTransparency = 1
	return TweenService:Create(frame, FADE_IN_TWEEN, { BackgroundTransparency = 0 })
end

local function playFadeOut(): Tween
	local frame = ensureFadeGui()
	frame.BackgroundTransparency = 0
	local tween = TweenService:Create(frame, FADE_OUT_TWEEN, { BackgroundTransparency = 1 })
	tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			frame.Visible = false
		end
	end)
	return tween
end

local function isCharacterAlive(character: Model): boolean
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false
	end
	local ok, state = pcall(function()
		return hum:GetState()
	end)
	if ok and state == Enum.HumanoidStateType.Dead then
		return false
	end
	return true
end

local function isReviveSessionActive(): boolean
	local ok, revive = pcall(function()
		return require(script.Parent.ReviveController)
	end)
	if not ok or typeof(revive) ~= "table" then
		return false
	end
	local fn = (revive :: any).isSessionActive
	if typeof(fn) ~= "function" then
		return false
	end
	local okCall, active = pcall(fn)
	return okCall and active == true
end

local function shouldShowButtons(): boolean
	if teleportBusy then
		return false
	end
	if GameplayUiVisibility.isHidden() then
		return false
	end
	if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true then
		return false
	end
	if isReviveSessionActive() then
		return false
	end
	local character = player.Character
	if not character or not isCharacterAlive(character) then
		return false
	end
	if not SafezoneUtil.isCacheReady() then
		return false
	end
	return SafezoneUtil.isCharacterInSafezone(character)
end

local function setButtonsActive(active: boolean)
	for _, state in btnStates do
		if state.btn.Parent then
			state.btn.Active = active and visibleTarget and not teleportBusy
			state.btn.AutoButtonColor = false
			pcall(function()
				(state.btn :: any).Interactable = state.btn.Active
			end)
		end
	end
end

local function setGradientHover(state: BtnState, hovering: boolean)
	for _, grad in state.gradients do
		if not grad.Parent then
			continue
		end
		local rest = state.gradRest[grad]
		if not rest then
			continue
		end
		local prev = state.gradTweens[grad]
		if prev then
			prev:Cancel()
			state.gradTweens[grad] = nil
		end
		local info = if hovering then GRADIENT_HOVER_TWEEN else GRADIENT_IDLE_TWEEN
		local goal = if hovering
			then { Rotation = rest.rotation + 18, Offset = rest.offset + Vector2.new(0.1, 0.03) }
			else { Rotation = rest.rotation, Offset = rest.offset }
		local tween = TweenService:Create(grad, info, goal)
		state.gradTweens[grad] = tween
		tween:Play()
	end
end

local function cancelBarTween()
	if barTween then
		barTween:Cancel()
		barTween = nil
	end
end

local function snapHidden()
	visibilityGen += 1
	cancelBarTween()
	visibleTarget = false
	if buttonsRoot then
		buttonsRoot.Visible = false
	end
	if barScale then
		barScale.Scale = 0.78
	end
	for _, state in btnStates do
		state.scale.Scale = 0.72
		state.host.Rotation = state.restRotation
		setGradientHover(state, false)
		state.hovering = false
	end
	setButtonsActive(false)
end

local function snapShown()
	visibilityGen += 1
	cancelBarTween()
	visibleTarget = true
	if buttonsRoot then
		buttonsRoot.Visible = true
	end
	if barScale then
		barScale.Scale = 1
	end
	for _, state in btnStates do
		state.scale.Scale = 1
		state.host.Rotation = state.restRotation
	end
	setButtonsActive(true)
end

local function playShowAnimated()
	if not buttonsRoot or not barScale then
		return
	end
	visibilityGen += 1
	local gen = visibilityGen
	cancelBarTween()
	visibleTarget = true
	buttonsRoot.Visible = true
	barScale.Scale = 0.78
	for _, state in btnStates do
		state.scale.Scale = 0.55
		state.host.Rotation = state.restRotation
	end
	barTween = TweenService:Create(barScale, SHOW_BAR_TWEEN, { Scale = 1 })
	barTween:Play()
	setButtonsActive(true)

	for i, state in ipairs(btnStates) do
		task.delay((i - 1) * STAGGER_SEC, function()
			if gen ~= visibilityGen or not visibleTarget or not state.host.Parent then
				return
			end
			TweenService:Create(state.scale, BTN_SHOW_TWEEN, { Scale = 1 }):Play()
		end)
	end
end

local function playHideAnimated()
	if not buttonsRoot or not barScale then
		return
	end
	visibilityGen += 1
	local gen = visibilityGen
	cancelBarTween()
	visibleTarget = false
	setButtonsActive(false)
	for _, state in btnStates do
		state.hovering = false
		setGradientHover(state, false)
		TweenService:Create(state.scale, BTN_HIDE_TWEEN, { Scale = 0.72 }):Play()
		TweenService:Create(state.host, BTN_HIDE_TWEEN, { Rotation = state.restRotation }):Play()
	end
	barTween = TweenService:Create(barScale, HIDE_BAR_TWEEN, { Scale = 0.78 })
	barTween:Play()
	barTween.Completed:Connect(function(playback)
		if playback ~= Enum.PlaybackState.Completed or gen ~= visibilityGen then
			return
		end
		if not visibleTarget and buttonsRoot then
			buttonsRoot.Visible = false
		end
	end)
end

local function applyVisibility(show: boolean, instant: boolean?)
	if show == visibleTarget then
		if show then
			setButtonsActive(true)
		end
		return
	end
	if show then
		if instant then
			snapShown()
		else
			playShowAnimated()
		end
	else
		if instant then
			snapHidden()
		else
			playHideAnimated()
		end
	end
end

local function refreshVisibility(instant: boolean?)
	local want = shouldShowButtons()
	if want then
		outsideStreak = 0
		insideStreak += 1
		if visibleTarget or insideStreak >= INSIDE_STREAK_TO_SHOW or instant then
			applyVisibility(true, instant)
		end
	else
		insideStreak = 0
		outsideStreak += 1
		if (not visibleTarget) or outsideStreak >= OUTSIDE_STREAK_TO_HIDE or instant or teleportBusy or GameplayUiVisibility.isHidden() then
			applyVisibility(false, instant)
		end
	end
end

local function onNavActivated(dest: string)
	if teleportBusy or not visibleTarget then
		return
	end
	if not MobileTouchGate.canTapUi() then
		return
	end
	local now = os.clock()
	if now - lastFireAt < 0.35 then
		return
	end
	lastFireAt = now
	if not shouldShowButtons() then
		refreshVisibility(true)
		return
	end
	if not navRF then
		TopNotifController.showError("Teleport not ready")
		return
	end

	teleportBusy = true
	setButtonsActive(false)
	UIInteractionSounds.playClick()

	local fadeIn = playFadeIn()
	waitForTween(fadeIn)

	local ok, errMsg = navRF:InvokeServer(dest)
	if not ok then
		-- Cooldown is intentional spam guard — don't toast "please wait" (feels broken).
		local silent = typeof(errMsg) == "string"
			and (string.find(string.lower(errMsg), "please wait", 1, true) ~= nil
				or string.find(string.lower(errMsg), "wait a moment", 1, true) ~= nil)
		if not silent then
			if typeof(errMsg) == "string" and errMsg ~= "" then
				TopNotifController.showError(errMsg)
			else
				TopNotifController.showError("Cannot teleport right now")
			end
		end
	else
		UIInteractionSounds.playNotif()
	end

	waitForTween(playFadeOut())
	teleportBusy = false
	insideStreak = INSIDE_STREAK_TO_SHOW
	outsideStreak = 0
	-- Animate back in (hide used playHideAnimated; don't snap).
	if shouldShowButtons() then
		playShowAnimated()
	else
		refreshVisibility(false)
	end
end

local function wireButton(state: BtnState)
	if state.wired then
		return
	end
	state.wired = true
	local btn = state.btn
	btn.AutoButtonColor = false
	btn.Active = false

	-- Nested labels/icons must not steal clicks.
	for _, d in state.host:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			(d :: GuiObject).Active = false
		end
	end

	btn.MouseEnter:Connect(function()
		if not visibleTarget or teleportBusy then
			return
		end
		state.hovering = true
		UIInteractionSounds.playHover()
		TweenService:Create(state.scale, HOVER_TWEEN, { Scale = 1.1 }):Play()
		TweenService:Create(state.host, HOVER_TWEEN, { Rotation = state.restRotation - 4 }):Play()
		setGradientHover(state, true)
		UIButtonEffects.playBorderGlisten(btn)
		UIButtonEffects.playDiagonalSweep(btn)
	end)
	btn.MouseLeave:Connect(function()
		state.hovering = false
		-- Let glisten / diagonal shine finish — cutting them on leave looks abrupt.
		local targetScale = if visibleTarget then 1 else state.scale.Scale
		TweenService:Create(state.scale, RELEASE_TWEEN, { Scale = targetScale }):Play()
		TweenService:Create(state.host, RELEASE_TWEEN, { Rotation = state.restRotation }):Play()
		setGradientHover(state, false)
	end)
	btn.MouseButton1Down:Connect(function()
		if not visibleTarget or teleportBusy or not MobileTouchGate.canTapUi() then
			return
		end
		TweenService:Create(state.scale, CLICK_TWEEN, { Scale = 0.92 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		local target = if state.hovering then 1.1 else 1
		TweenService:Create(state.scale, RELEASE_TWEEN, { Scale = target }):Play()
	end)
	btn.Activated:Connect(function()
		onNavActivated(state.name)
	end)
end

local function resolveUi(): boolean
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main:WaitForChild("SideUI", 30)
	if not sideUI then
		warn("[SafezoneTopButtonsController] SideUI missing")
		return false
	end
	local top = sideUI:WaitForChild("Top", 15)
	if not top then
		warn("[SafezoneTopButtonsController] SideUI.Top missing")
		return false
	end
	local buttons = top:FindFirstChild("Buttons")
	if not buttons or not buttons:IsA("GuiObject") then
		warn("[SafezoneTopButtonsController] SideUI.Top.Buttons missing")
		return false
	end

	buttonsRoot = buttons :: GuiObject
	barScale = getOrAddUIScale(buttonsRoot)
	table.clear(btnStates)

	for _, name in BUTTON_ORDER do
		local host = buttons:FindFirstChild(name)
		if not host or not host:IsA("GuiObject") then
			warn("[SafezoneTopButtonsController] missing button host:", name)
			continue
		end
		local clickable = resolveClickable(host)
		if not clickable then
			warn("[SafezoneTopButtonsController] no GuiButton under", name)
			continue
		end
		local grads, rest = collectGradients(host)
		local state: BtnState = {
			name = name,
			host = host :: GuiObject,
			btn = clickable,
			scale = getOrAddUIScale(host :: GuiObject),
			restRotation = (host :: GuiObject).Rotation,
			gradients = grads,
			gradRest = rest,
			gradTweens = {},
			hovering = false,
			wired = false,
		}
		table.insert(btnStates, state)
		wireButton(state)
	end

	if #btnStates == 0 then
		warn("[SafezoneTopButtonsController] no nav buttons wired")
		return false
	end

	snapHidden()
	return true
end

function SafezoneTopButtonsController.forceHide()
	insideStreak = 0
	outsideStreak = OUTSIDE_STREAK_TO_HIDE
	snapHidden()
end

function SafezoneTopButtonsController.init()
	local rf = ReplicatedStorage:WaitForChild("SafezoneQuickNav", 60)
	if rf and rf:IsA("RemoteFunction") then
		navRF = rf
	else
		warn("[SafezoneTopButtonsController] SafezoneQuickNav RemoteFunction missing")
	end

	if not resolveUi() then
		return
	end

	GameplayUiVisibility.onRestored(function()
		insideStreak = 0
		outsideStreak = 0
		refreshVisibility(true)
	end)

	player:GetAttributeChangedSignal(WebTrapConfig.TRAPPED_ATTR):Connect(function()
		refreshVisibility(false)
	end)

	player.CharacterAdded:Connect(function()
		teleportBusy = false
		insideStreak = 0
		outsideStreak = 0
		snapHidden()
		task.defer(function()
			refreshVisibility(true)
		end)
	end)

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		pollAccum += dt
		if pollAccum < VISIBILITY_POLL_SEC then
			return
		end
		pollAccum = 0
		refreshVisibility(false)
	end)

	-- First paint after cache warms (avoid flash at spawn).
	task.spawn(function()
		local deadline = os.clock() + 8
		while os.clock() < deadline and not SafezoneUtil.isCacheReady() do
			task.wait(0.15)
		end
		refreshVisibility(true)
	end)
end

return SafezoneTopButtonsController
