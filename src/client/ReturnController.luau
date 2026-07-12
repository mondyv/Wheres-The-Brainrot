-- [ACTIVE] ReturnController
--[[
	Return button — lives under Main.SideUI; visible outside the safe zone, teleports home with a fade transition.
	Decor gradients stay visible; they only animate on hover.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CarryGate = require(script.Parent.CarryGate)
local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local TopNotifController = require(script.Parent.TopNotifController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local ReturnController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local VISIBILITY_POLL_SEC = 0.12
local SHOW_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_IN_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_OUT_TWEEN = TweenInfo.new(0.48, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local IDLE_BOB_TWEEN = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local GRADIENT_HOVER_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GRADIENT_IDLE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local returnFrame: GuiObject? = nil
local returnBtn: GuiButton? = nil
local decor: Instance? = nil
local decorHighlight: GuiObject? = nil
local decorHighlightOn: GuiObject? = nil
local decorStud: GuiObject? = nil
local decorShadow: GuiObject? = nil
local frameScale: UIScale? = nil
local btnScale: UIScale? = nil

local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil

local returnRF: RemoteFunction? = nil
local wired = false
local visibleTarget = false
local visibilityTween: Tween? = nil
local teleportBusy = false
local idleBobTween: Tween? = nil
local pollAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local wasInSafezone = true
local deferredShowPending = false

local decorStudRestPos: UDim2? = nil
local decorShadowRestPos: UDim2? = nil
local returnGradients: { UIGradient } = {}
local gradientRestByGrad: { [UIGradient]: { rotation: number, offset: Vector2 } } = {}
local gradientHoverTweens: { [UIGradient]: Tween } = {}

local function collectReturnGradients()
	table.clear(returnGradients)
	table.clear(gradientRestByGrad)
	local roots: { Instance } = {}
	if returnBtn then
		table.insert(roots, returnBtn)
	end
	if returnFrame and returnFrame ~= returnBtn then
		table.insert(roots, returnFrame)
	end
	for _, root in roots do
		if root:IsA("UIGradient") then
			table.insert(returnGradients, root :: UIGradient)
		end
		for _, d in root:GetDescendants() do
			if d:IsA("UIGradient") then
				table.insert(returnGradients, d)
			end
		end
	end
	for _, grad in returnGradients do
		grad.Enabled = true
		gradientRestByGrad[grad] = {
			rotation = grad.Rotation,
			offset = grad.Offset,
		}
	end
end

local function setReturnGradientHover(hovering: boolean)
	for _, grad in returnGradients do
		if not grad.Parent then
			continue
		end
		local rest = gradientRestByGrad[grad]
		if not rest then
			continue
		end
		local prev = gradientHoverTweens[grad]
		if prev then
			prev:Cancel()
			gradientHoverTweens[grad] = nil
		end
		local tweenInfo = if hovering then GRADIENT_HOVER_TWEEN else GRADIENT_IDLE_TWEEN
		local goal = if hovering then {
			Rotation = rest.rotation + 24,
			Offset = rest.offset + Vector2.new(0.12, 0.04),
		} else {
			Rotation = rest.rotation,
			Offset = rest.offset,
		}
		local tween = TweenService:Create(grad, tweenInfo, goal)
		gradientHoverTweens[grad] = tween
		tween:Play()
	end
end

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

local function ensureFadeGui(): Frame
	if fadeFrame and fadeGui and fadeGui.Parent then
		return fadeFrame
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "ReturnTeleportFade"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 200
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Active = true
	frame.ZIndex = 1
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
		task.wait()
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

local function stopIdleMotion()
	if idleBobTween then
		idleBobTween:Cancel()
		idleBobTween = nil
	end
	if returnFrame then
		returnFrame.Rotation = 0
	end
end

local function startIdleMotion()
	stopIdleMotion()
	if not visibleTarget or not returnFrame then
		return
	end
	idleBobTween = TweenService:Create(returnFrame, IDLE_BOB_TWEEN, { Rotation = 1.6 })
	idleBobTween:Play()
end

local function shouldShowReturn(): boolean
	if teleportBusy then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	if SafezoneUtil.isCharacterInSafezone(character) then
		return false
	end
	if BushFloatingClaimController.hasActiveOffer() then
		return false
	end
	if CarryGate.isCarryingOnHead() or CarryGate.isCarrying() then
		return false
	end
	if ProximityPromptEffects.isBushSearchActive() then
		return false
	end
	return true
end

local function setButtonActive(active: boolean)
	if returnBtn then
		returnBtn.Active = active
		returnBtn.AutoButtonColor = false
	end
end

local function applyVisibility(show: boolean, instant: boolean?)
	if not returnFrame or not frameScale then
		return
	end
	if visibleTarget == show and not instant then
		return
	end
	visibleTarget = show

	if visibilityTween then
		visibilityTween:Cancel()
		visibilityTween = nil
	end

	if show then
		returnFrame.Visible = true
		setButtonActive(true)
		if instant then
			frameScale.Scale = 1
			startIdleMotion()
			return
		end
		frameScale.Scale = 0.72
		visibilityTween = TweenService:Create(frameScale, SHOW_TWEEN, { Scale = 1 })
		visibilityTween:Play()
		visibilityTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and visibleTarget then
				startIdleMotion()
			end
		end)
	else
		stopIdleMotion()
		setButtonActive(false)
		if instant then
			returnFrame.Visible = false
			frameScale.Scale = 0.72
			return
		end
		visibilityTween = TweenService:Create(frameScale, HIDE_TWEEN, { Scale = 0.72 })
		visibilityTween:Play()
		visibilityTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and not visibleTarget and returnFrame then
				returnFrame.Visible = false
			end
		end)
	end
end

local function refreshVisibility(instant: boolean?)
	applyVisibility(shouldShowReturn(), instant)
end

local function setHighlightOn(on: boolean)
	if decorHighlightOn and decorHighlightOn:IsA("GuiObject") then
		(decorHighlightOn :: GuiObject).Visible = on
	end
end

local function pressDecor()
	if decorStud and decorStudRestPos then
		TweenService:Create(decorStud, CLICK_TWEEN, {
			Position = decorStudRestPos + UDim2.fromOffset(0, 3),
		}):Play()
	end
	if decorShadow and decorShadowRestPos then
		TweenService:Create(decorShadow, CLICK_TWEEN, {
			Position = decorShadowRestPos + UDim2.fromOffset(0, 1),
			BackgroundTransparency = 0.35,
		}):Play()
	end
	setHighlightOn(false)
end

local function releaseDecor(hovering: boolean)
	if decorStud and decorStudRestPos then
		TweenService:Create(decorStud, RELEASE_TWEEN, { Position = decorStudRestPos }):Play()
	end
	if decorShadow and decorShadowRestPos then
		TweenService:Create(decorShadow, RELEASE_TWEEN, {
			Position = decorShadowRestPos,
			BackgroundTransparency = 0.55,
		}):Play()
	end
	setHighlightOn(hovering)
end

local function onReturnActivated()
	if teleportBusy or not shouldShowReturn() then
		return
	end
	if not returnRF then
		return
	end

	teleportBusy = true
	setButtonActive(false)
	stopIdleMotion()
	UIInteractionSounds.playClick()

	local fadeIn = playFadeIn()
	waitForTween(fadeIn)

	local ok, errMsg = returnRF:InvokeServer()
	if not ok then
		if typeof(errMsg) == "string" and errMsg ~= "" then
			TopNotifController.showError(errMsg)
		else
			TopNotifController.showError("Cannot return right now")
		end
	else
		UIInteractionSounds.playNotif()
	end

	local fadeOut = playFadeOut()
	waitForTween(fadeOut)

	teleportBusy = false
	refreshVisibility(true)
end

local function wireReturnButton(btn: GuiButton)
	if wired then
		return
	end
	wired = true

	decor = btn:FindFirstChild("Decor")
	if decor then
		decorHighlight = decor:FindFirstChild("Highlight")
		if decorHighlight then
			decorHighlightOn = decorHighlight:FindFirstChild("On")
		end
		decorStud = decor:FindFirstChild("Stud")
		decorShadow = decor:FindFirstChild("Shadow")
	end

	if decorStud and decorStud:IsA("GuiObject") then
		decorStudRestPos = (decorStud :: GuiObject).Position
	end
	if decorShadow and decorShadow:IsA("GuiObject") then
		decorShadowRestPos = (decorShadow :: GuiObject).Position
	end

	btnScale = getOrAddUIScale(btn)
	collectReturnGradients()
	local hovering = false

	btn.MouseEnter:Connect(function()
		if not visibleTarget or teleportBusy then
			return
		end
		hovering = true
		UIInteractionSounds.playHover()
		setHighlightOn(true)
		setReturnGradientHover(true)
		TweenService:Create(btnScale :: UIScale, HOVER_TWEEN, { Scale = 1.08 }):Play()
	end)

	btn.MouseLeave:Connect(function()
		hovering = false
		setHighlightOn(false)
		setReturnGradientHover(false)
		TweenService:Create(btnScale :: UIScale, HOVER_TWEEN, { Scale = 1 }):Play()
		releaseDecor(false)
	end)

	btn.MouseButton1Down:Connect(function()
		if not visibleTarget or teleportBusy then
			return
		end
		TweenService:Create(btnScale :: UIScale, CLICK_TWEEN, { Scale = 0.93 }):Play()
		pressDecor()
	end)

	btn.MouseButton1Up:Connect(function()
		if not visibleTarget or teleportBusy then
			return
		end
		TweenService:Create(btnScale :: UIScale, RELEASE_TWEEN, { Scale = if hovering then 1.08 else 1 }):Play()
		releaseDecor(hovering)
	end)

	btn.Activated:Connect(onReturnActivated)
end

local RETURN_CONTAINER_NAMES = { "Return" }
local RETURN_BUTTON_NAMES = { "Return Button", "Button" }

local function findReturnContainer(root: Instance): GuiObject?
	for _, name in RETURN_CONTAINER_NAMES do
		local inst = root:FindFirstChild(name, true)
		if inst and inst:IsA("GuiObject") then
			return inst :: GuiObject
		end
	end
	return nil
end

local function findReturnButton(container: Instance): GuiButton?
	if container:IsA("GuiButton") then
		return container :: GuiButton
	end
	for _, name in RETURN_BUTTON_NAMES do
		local inst = container:FindFirstChild(name, true)
		if inst and inst:IsA("GuiButton") then
			return inst :: GuiButton
		end
	end
	return container:FindFirstChildOfClass("ImageButton") :: GuiButton?
		or container:FindFirstChildOfClass("TextButton") :: GuiButton?
end

local function resolveUi()
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main:WaitForChild("SideUI", 30)
	if not sideUI then
		warn("[ReturnController] SideUI missing")
		return false
	end

	local frame = findReturnContainer(sideUI)
	if not frame then
		local frames = main:FindFirstChild("Frames")
		if frames then
			frame = findReturnContainer(frames)
		end
	end
	if not frame then
		warn("[ReturnController] Return container missing under SideUI")
		return false
	end

	local btn = findReturnButton(frame)
	if not btn then
		warn("[ReturnController] Return Button missing under SideUI.Return")
		return false
	end

	returnFrame = frame
	returnBtn = btn
	frameScale = getOrAddUIScale(frame)
	frame.Visible = false
	frameScale.Scale = 0.72
	collectReturnGradients()
	return true
end

function ReturnController.init()
	local rf = ReplicatedStorage:WaitForChild("ReturnToPlot", 60)
	if rf and rf:IsA("RemoteFunction") then
		returnRF = rf
	else
		warn("[ReturnController] ReplicatedStorage.ReturnToPlot RemoteFunction missing")
	end

	if not resolveUi() then
		return
	end

	if returnBtn then
		wireReturnButton(returnBtn)
	end

	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(function()
		refreshVisibility(false)
	end)

	player.CharacterAdded:Connect(function()
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

		local character = player.Character
		local inSafezone = if character then SafezoneUtil.isCharacterInSafezone(character) else true
		local crossingOut = wasInSafezone and not inSafezone
		wasInSafezone = inSafezone

		if crossingOut and shouldShowReturn() then
			if not deferredShowPending then
				deferredShowPending = true
				task.defer(function()
					task.wait()
					deferredShowPending = false
					refreshVisibility(false)
				end)
			end
			return
		end

		refreshVisibility(false)
	end)

	wasInSafezone = if player.Character then SafezoneUtil.isCharacterInSafezone(player.Character) else true

	refreshVisibility(true)
end

return ReturnController
