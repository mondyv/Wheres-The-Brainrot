-- [ACTIVE] ReturnController
--[[
	SideUI.Return:
	• "Return Button" — free teleport home when NOT carrying (pos 0.5, 0.5)
	• "Return Button With Brainrot" — Robux product Return N for carry count N (1–11)
	Visible outside the safe zone. Decor gradients animate on hover.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CarryGate = require(script.Parent.CarryGate)
local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local ReturnConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReturnConfig"))
local TopNotifController = require(script.Parent.TopNotifController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local ReturnController = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FREE_BTN_POS = UDim2.new(0.5, 0, 0.5, 0)
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
local freeBtn: GuiButton? = nil
local paidBtn: GuiButton? = nil
local frameScale: UIScale? = nil

local fadeGui: ScreenGui? = nil
local fadeFrame: Frame? = nil

local returnRF: RemoteFunction? = nil
local returnPaidRE: RemoteEvent? = nil
local visibleTarget = false
local visibilityTween: Tween? = nil
local teleportBusy = false
local idleBobTween: Tween? = nil
local pollAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local wasInSafezone = true
local deferredShowPending = false
local pendingPaidProductId: number? = nil
local paidFinishLock = false

type BtnDecor = {
	btn: GuiButton,
	scale: UIScale,
	stud: GuiObject?,
	shadow: GuiObject?,
	studRest: UDim2?,
	shadowRest: UDim2?,
	highlightOn: GuiObject?,
	gradients: { UIGradient },
	gradRest: { [UIGradient]: { rotation: number, offset: Vector2 } },
	gradTweens: { [UIGradient]: Tween },
	wired: boolean,
}

local freeDecor: BtnDecor? = nil
local paidDecor: BtnDecor? = nil

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

local function collectGradients(btn: GuiButton): ({ UIGradient }, { [UIGradient]: { rotation: number, offset: Vector2 } })
	local list: { UIGradient } = {}
	local rest: { [UIGradient]: { rotation: number, offset: Vector2 } } = {}
	if btn:IsA("UIGradient") then
		table.insert(list, btn :: any)
	end
	for _, d in btn:GetDescendants() do
		if d:IsA("UIGradient") then
			table.insert(list, d)
		end
	end
	for _, grad in list do
		grad.Enabled = true
		rest[grad] = { rotation = grad.Rotation, offset = grad.Offset }
	end
	return list, rest
end

local function buildDecor(btn: GuiButton): BtnDecor
	local decor = btn:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local highlightOn = highlight and highlight:FindFirstChild("On")
	local stud = decor and decor:FindFirstChild("Stud")
	local shadow = decor and decor:FindFirstChild("Shadow")
	local grads, rest = collectGradients(btn)
	return {
		btn = btn,
		scale = getOrAddUIScale(btn),
		stud = if stud and stud:IsA("GuiObject") then stud :: GuiObject else nil,
		shadow = if shadow and shadow:IsA("GuiObject") then shadow :: GuiObject else nil,
		studRest = if stud and stud:IsA("GuiObject") then (stud :: GuiObject).Position else nil,
		shadowRest = if shadow and shadow:IsA("GuiObject") then (shadow :: GuiObject).Position else nil,
		highlightOn = if highlightOn and highlightOn:IsA("GuiObject") then highlightOn :: GuiObject else nil,
		gradients = grads,
		gradRest = rest,
		gradTweens = {},
		wired = false,
	}
end

local function setGradientHover(state: BtnDecor, hovering: boolean)
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
			then { Rotation = rest.rotation + 24, Offset = rest.offset + Vector2.new(0.12, 0.04) }
			else { Rotation = rest.rotation, Offset = rest.offset }
		local tween = TweenService:Create(grad, info, goal)
		state.gradTweens[grad] = tween
		tween:Play()
	end
end

local function setHighlightOn(state: BtnDecor, on: boolean)
	if state.highlightOn then
		state.highlightOn.Visible = on
	end
end

local function pressDecor(state: BtnDecor)
	if state.stud and state.studRest then
		TweenService:Create(state.stud, CLICK_TWEEN, {
			Position = state.studRest + UDim2.fromOffset(0, 3),
		}):Play()
	end
	if state.shadow and state.shadowRest then
		TweenService:Create(state.shadow, CLICK_TWEEN, {
			Position = state.shadowRest + UDim2.fromOffset(0, 1),
			BackgroundTransparency = 0.35,
		}):Play()
	end
	setHighlightOn(state, false)
end

local function releaseDecor(state: BtnDecor, hovering: boolean)
	if state.stud and state.studRest then
		TweenService:Create(state.stud, RELEASE_TWEEN, { Position = state.studRest }):Play()
	end
	if state.shadow and state.shadowRest then
		TweenService:Create(state.shadow, RELEASE_TWEEN, {
			Position = state.shadowRest,
			BackgroundTransparency = 0.55,
		}):Play()
	end
	setHighlightOn(state, hovering)
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

local function carryCount(): number
	return CarryGate.usedSlots()
end

local function shouldShowReturnChrome(): boolean
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
	if ProximityPromptEffects.isBushSearchActive() then
		return false
	end
	return true
end

local function syncModeButtons()
	local carrying = carryCount() > 0
	if freeBtn then
		freeBtn.Visible = not carrying
		if not carrying then
			freeBtn.Position = FREE_BTN_POS
		end
		freeBtn.Active = not carrying and visibleTarget and not teleportBusy
	end
	if paidBtn then
		paidBtn.Visible = carrying
		paidBtn.Active = carrying and visibleTarget and not teleportBusy
	end
end

local function setButtonsActive(active: boolean)
	if freeBtn then
		freeBtn.Active = active and freeBtn.Visible
		freeBtn.AutoButtonColor = false
	end
	if paidBtn then
		paidBtn.Active = active and paidBtn.Visible
		paidBtn.AutoButtonColor = false
	end
end

local function applyVisibility(show: boolean, instant: boolean?)
	if not returnFrame or not frameScale then
		return
	end
	if visibleTarget == show and not instant then
		syncModeButtons()
		return
	end
	visibleTarget = show

	if visibilityTween then
		visibilityTween:Cancel()
		visibilityTween = nil
	end

	if show then
		syncModeButtons()
		returnFrame.Visible = true
		setButtonsActive(true)
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
		setButtonsActive(false)
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
	applyVisibility(shouldShowReturnChrome(), instant)
	syncModeButtons()
end

local function onFreeReturnActivated()
	if teleportBusy or not shouldShowReturnChrome() or carryCount() > 0 then
		return
	end
	if not returnRF then
		return
	end

	teleportBusy = true
	setButtonsActive(false)
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

	waitForTween(playFadeOut())
	teleportBusy = false
	refreshVisibility(true)
end

local function onPaidReturnActivated()
	if teleportBusy or not shouldShowReturnChrome() then
		return
	end
	local n = carryCount()
	if n <= 0 then
		return
	end

	teleportBusy = true
	paidFinishLock = false
	setButtonsActive(false)
	stopIdleMotion()
	UIInteractionSounds.playClick()

	local productId = ReturnConfig.productIdForCount(n)
	pendingPaidProductId = productId

	local fadeIn = playFadeIn()
	waitForTween(fadeIn)

	local ok, err = pcall(function()
		PurchasePrompt.promptProduct(productId)
	end)
	if not ok then
		warn("[ReturnController] prompt failed:", err)
		pendingPaidProductId = nil
		waitForTween(playFadeOut())
		teleportBusy = false
		refreshVisibility(true)
		TopNotifController.showError("Cannot open purchase")
	end
	-- Fade out finishes in PromptProductPurchaseFinished / paid complete remote
end

local function finishPaidPrompt(purchased: boolean)
	if paidFinishLock then
		return
	end
	if not teleportBusy and not pendingPaidProductId then
		return
	end
	paidFinishLock = true
	pendingPaidProductId = nil
	if purchased then
		UIInteractionSounds.playNotif()
		task.wait(0.35)
	else
		TopNotifController.showError("Return cancelled")
	end
	waitForTween(playFadeOut())
	teleportBusy = false
	paidFinishLock = false
	refreshVisibility(true)
end

local function wireButton(state: BtnDecor, onActivated: () -> ())
	if state.wired then
		return
	end
	state.wired = true
	local hovering = false
	local btn = state.btn

	btn.MouseEnter:Connect(function()
		if not visibleTarget or teleportBusy or not btn.Visible then
			return
		end
		hovering = true
		UIInteractionSounds.playHover()
		setHighlightOn(state, true)
		setGradientHover(state, true)
		TweenService:Create(state.scale, HOVER_TWEEN, { Scale = 1.08 }):Play()
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		setHighlightOn(state, false)
		setGradientHover(state, false)
		TweenService:Create(state.scale, HOVER_TWEEN, { Scale = 1 }):Play()
		releaseDecor(state, false)
	end)
	btn.MouseButton1Down:Connect(function()
		if not visibleTarget or teleportBusy or not btn.Visible then
			return
		end
		TweenService:Create(state.scale, CLICK_TWEEN, { Scale = 0.93 }):Play()
		pressDecor(state)
	end)
	btn.MouseButton1Up:Connect(function()
		if not visibleTarget or teleportBusy then
			return
		end
		TweenService:Create(state.scale, RELEASE_TWEEN, { Scale = if hovering then 1.08 else 1 }):Play()
		releaseDecor(state, hovering)
	end)
	btn.Activated:Connect(onActivated)
end

local function findReturnContainer(root: Instance): GuiObject?
	local inst = root:FindFirstChild("Return", true)
	if inst and inst:IsA("GuiObject") then
		return inst :: GuiObject
	end
	return nil
end

local function findNamedButton(container: Instance, name: string): GuiButton?
	local inst = container:FindFirstChild(name)
	if inst and inst:IsA("GuiButton") then
		return inst :: GuiButton
	end
	inst = container:FindFirstChild(name, true)
	if inst and inst:IsA("GuiButton") then
		return inst :: GuiButton
	end
	return nil
end

local function resolveUi(): boolean
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main:WaitForChild("SideUI", 30)
	if not sideUI then
		warn("[ReturnController] SideUI missing")
		return false
	end

	local frame = findReturnContainer(sideUI)
	if not frame then
		warn("[ReturnController] Return container missing under SideUI")
		return false
	end

	local free = findNamedButton(frame, "Return Button")
	local paid = findNamedButton(frame, "Return Button With Brainrot")
	if not free then
		-- Legacy fallback
		free = frame:FindFirstChildOfClass("ImageButton") :: GuiButton?
			or frame:FindFirstChildOfClass("TextButton") :: GuiButton?
	end
	if not free then
		warn("[ReturnController] Return Button missing")
		return false
	end

	returnFrame = frame
	freeBtn = free
	paidBtn = paid
	frameScale = getOrAddUIScale(frame)
	frame.Visible = false
	frameScale.Scale = 0.72
	free.Position = FREE_BTN_POS
	free.Visible = true
	if paid then
		paid.Visible = false
	end
	return true
end

function ReturnController.init()
	local rf = ReplicatedStorage:WaitForChild("ReturnToPlot", 60)
	if rf and rf:IsA("RemoteFunction") then
		returnRF = rf
	else
		warn("[ReturnController] ReturnToPlot RemoteFunction missing")
	end

	local paidRe = ReplicatedStorage:FindFirstChild("ReturnPaidComplete")
	if not paidRe then
		paidRe = ReplicatedStorage:WaitForChild("ReturnPaidComplete", 10)
	end
	if paidRe and paidRe:IsA("RemoteEvent") then
		returnPaidRE = paidRe
		returnPaidRE.OnClientEvent:Connect(function()
			if pendingPaidProductId or teleportBusy then
				finishPaidPrompt(true)
			end
		end)
	end

	if not resolveUi() then
		return
	end

	freeDecor = buildDecor(freeBtn :: GuiButton)
	wireButton(freeDecor, onFreeReturnActivated)
	if paidBtn then
		paidDecor = buildDecor(paidBtn)
		wireButton(paidDecor, onPaidReturnActivated)
	else
		warn("[ReturnController] Return Button With Brainrot missing — paid return disabled")
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		if userId ~= player.UserId then
			return
		end
		if not ReturnConfig.isReturnProduct(productId) then
			return
		end
		if pendingPaidProductId ~= productId and not teleportBusy then
			return
		end
		-- If server already fired ReturnPaidComplete, finishPaidPrompt may have run
		if not teleportBusy then
			return
		end
		if wasPurchased then
			-- Wait briefly for server teleport + remote; if remote already finished, skip
			task.delay(0.8, function()
				if teleportBusy and pendingPaidProductId == productId then
					finishPaidPrompt(true)
				end
			end)
		else
			finishPaidPrompt(false)
		end
	end)

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

		if crossingOut and shouldShowReturnChrome() then
			if not deferredShowPending then
				deferredShowPending = true
				task.defer(function()
					task.wait(0.03)
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
