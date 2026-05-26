--[[
	ProximityPromptEffects — custom proximity prompt billboard UI (client)
	Managed bush search: engine ProximityPrompt handles hold/trigger; optional displayOnly billboard is visual-only.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local CarryGate = require(script.Parent.CarryGate)

local player = Players.LocalPlayer

-- ── Visual constants ───────────────────────────────────────────────────────────

local ACCENT = Color3.fromRGB(72, 255, 140)
local ACCENT_BRIGHT = Color3.fromRGB(130, 255, 175)
local ACCENT_STROKE = Color3.fromRGB(48, 220, 110)
local BG_COLOR = Color3.fromRGB(10, 12, 16)
local BG_TRANSPARENCY = 0.4
local BADGE_BG = Color3.fromRGB(24, 28, 34)
local BADGE_BG_TRANSPARENCY = 0.12
local HOLD_GREEN = Color3.fromRGB(36, 165, 88)
local HOLD_GREEN_BRIGHT = Color3.fromRGB(95, 255, 145)
local PRESS_FLASH = Color3.fromRGB(255, 228, 88)
local HOLD_COMPLETE_FLASH = Color3.fromRGB(210, 255, 230)
local TEXT_PRIMARY = Color3.fromRGB(248, 250, 252)
local TEXT_SECONDARY = Color3.fromRGB(168, 178, 192)

local CARD_H = 58
local BADGE_SIZE = 44
local BADGE_HOLD_PAD = 3
local PAD_LEFT = 8
local BADGE_TEXT_GAP = 6
local PAD_RIGHT = 10
local MIN_CARD_W = 118
local MAX_CARD_W = 232

local OPEN_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local BADGE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_LEFT = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_RIGHT = TweenInfo.new(0.11, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TILT_CENTER = TweenInfo.new(0.14, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local FLASH_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local SWAY_FREQ = 1.35
local SWAY_AMP = 2.2
local WIGGLE_ROT = math.rad(4.5)
local WIGGLE_SPEED = 13
local HOLD_COMPLETE_THRESHOLD = 0.98

local BUSH_CAM_SHAKE_STEP = "BushSearchCameraShake"
local BUSH_WOBBLE_STEP = "BushSearchModelWobble"
local BUSH_CAM_SHAKE_POS = 0.14
local BUSH_CAM_SHAKE_SPEED = 9
local BUSH_WOBBLE_POS = 0.11
local BUSH_WOBBLE_ROT = math.rad(3.4)

local CUSTOM_ATTR = "CustomPromptFX"
local PLACE_PROMPT_ATTR = "BrainrotPlacePrompt"
local STAND_NAME_ATTR = "BrainrotName"
local STAND_LEVEL_ATTR = "BrainrotLevel"
local MIN_TOUCH_PX = 44
local MIN_TOUCH_PX_MOBILE = 52
local TOUCH_TAP_ICON = "rbxasset://textures/ui/Controls/TouchTapIcon.png"
local TOUCH_HOLD_ICON = "rbxasset://textures/ui/Controls/TouchHoldIcon.png"

-- ── State ─────────────────────────────────────────────────────────────────────

type PromptView = {
	prompt: ProximityPrompt,
	billboard: BillboardGui,
	root: Frame,
	rootScale: UIScale,
	keyBadge: Frame,
	keyStroke: UIStroke,
	keyLabel: TextLabel,
	keyIcon: ImageLabel,
	holdTrack: Frame,
	holdFill: Frame,
	actionLabel: TextLabel,
	objectLabel: TextLabel,
	holding: boolean,
	holdViaPointer: boolean,
	holdProgress: number,
	holdStartTime: number,
	swayToken: number,
	holdRenderConn: RBXScriptConnection?,
	liveConns: { RBXScriptConnection },
	clickConns: { RBXScriptConnection },
	clickWired: boolean,
	displayOnly: boolean,
}

local viewsByPrompt: { [ProximityPrompt]: PromptView } = {}
local styledPrompts: { [ProximityPrompt]: boolean } = {}
local promptStyleConns: { [ProximityPrompt]: { RBXScriptConnection } } = {}
local serviceWired = false
local activeBushSearchPrompt: ProximityPrompt? = nil
local bushSharedView: PromptView? = nil
local bushWobbleModel: Model? = nil
local bushWobbleBasePivot: CFrame? = nil
local bushWobbleSeed = 0.0
local bushWobbleStepBound = false
local cameraShakeActive = false
local bushCameraShakeStepBound = false
local bushHoldLockUntil = 0
local bushHoldCompleteHandler: ((ProximityPrompt) -> ())? = nil

-- Post-harvest cooldown banner (clock + seconds) on the bush adornee
local bushCooldownBillboard: BillboardGui? = nil
local bushCooldownConn: RBXScriptConnection? = nil
local bushCooldownPromptRef: ProximityPrompt? = nil
local bushCooldownEndClock = 0.0

local BUSH_MANAGED_ATTR = "BushManagedPrompt"
-- Must match BrainrotStandController — cheap reshow path (never scan all of Workspace).
local STAND_TAG = "BrainrotStand"
-- Cooldown billboard can stay visible farther than bush search range.
local COOLDOWN_BANNER_VIEW_RANGE = 56

local ProximityPromptEffects = {}

function ProximityPromptEffects.setBushHoldCompleteHandler(handler: ((ProximityPrompt) -> ())?)
	bushHoldCompleteHandler = handler
end

local startIdleSway: (view: PromptView) -> ()
local destroyView: (prompt: ProximityPrompt) -> ()
local hideView: (prompt: ProximityPrompt, instant: boolean?) -> ()
local clearBushPerPromptViews: () -> ()
local hideBushSharedUi: (instant: boolean?) -> ()
local showBushSharedUi: (prompt: ProximityPrompt) -> boolean
local wirePromptLiveUpdates: (prompt: ProximityPrompt, view: PromptView) -> ()
local applyHoldBadgeActive: (view: PromptView) -> ()
local startHoldRender: (view: PromptView) -> ()
local resetHoldState: (view: PromptView, celebrate: boolean) -> ()
local beginHoldVisual: (view: PromptView, skipPromptHoldBegin: boolean?) -> ()
local endHoldVisual: (view: PromptView, completed: boolean?) -> ()
-- After carry/bush UI clears, PromptShown may not refire for prompts already enabled — refresh place cards.
local reshowEligiblePlaceProximityPrompts: (() -> ())?

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function disconnectAll(conns: { RBXScriptConnection })
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = parent
	return s
end

local function playerHasBrainrotToolEquipped(): boolean
	local char = player.Character
	if not char then
		return false
	end
	for _, ch in char:GetChildren() do
		if ch:IsA("Tool") and ch:GetAttribute("BrainrotTool") == true then
			return true
		end
	end
	return false
end

-- Empty-stand "Place" custom card: Tool equipped or bush-style carry (no tool yet).
local function canShowPlaceBrainrotUi(): boolean
	return playerHasBrainrotToolEquipped() or CarryGate.isCarrying()
end

local function isPlaceBrainrotPrompt(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute(PLACE_PROMPT_ATTR) == true
		or prompt.ActionText == "Place Brainrot"
end

local function isManagedBushPrompt(prompt: ProximityPrompt): boolean
	return CarryGate.isBushSearchPrompt(prompt) and prompt:GetAttribute(BUSH_MANAGED_ATTR) == true
end

local function managedBushUiEligible(prompt: ProximityPrompt): boolean
	return isManagedBushPrompt(prompt) and prompt == activeBushSearchPrompt and not CarryGate.isFull()
end

local function shouldShowPromptUi(prompt: ProximityPrompt): boolean
	if managedBushUiEligible(prompt) then
		return true
	end
	if not prompt.Enabled then
		return false
	end
	if CarryGate.isBushSearchPrompt(prompt) then
		return false
	end
	if isPlaceBrainrotPrompt(prompt) and not canShowPlaceBrainrotUi() then
		return false
	end
	return true
end

local function viewIsActive(view: PromptView): boolean
	if bushSharedView == view then
		return view.billboard.Parent ~= nil and view.billboard.Enabled == true
	end
	return viewsByPrompt[view.prompt] == view
end

local function prefersGamepadInput(): boolean
	return UserInputService.GamepadEnabled
		and UserInputService:GetLastInputType() == Enum.UserInputType.Gamepad1
end

local function prefersTouchInput(): boolean
	if not UserInputService.TouchEnabled then
		return false
	end
	if prefersGamepadInput() then
		return false
	end
	return true
end

local function gamepadButtonLabel(keyCode: Enum.KeyCode): string
	if keyCode == Enum.KeyCode.ButtonX then
		return "X"
	elseif keyCode == Enum.KeyCode.ButtonY then
		return "Y"
	elseif keyCode == Enum.KeyCode.ButtonA then
		return "A"
	elseif keyCode == Enum.KeyCode.ButtonB then
		return "B"
	end
	local name = keyCode.Name
	if string.sub(name, 1, 6) == "Button" and #name == 7 then
		return string.sub(name, 7, 7)
	end
	return "•"
end

local function refreshKeyLabel(view: PromptView)
	local prompt = view.prompt
	local label = view.keyLabel
	local icon = view.keyIcon

	local function showText(text: string)
		icon.Visible = false
		label.Visible = true
		label.Text = text
	end

	local function showIcon(image: string)
		label.Visible = false
		icon.Visible = true
		icon.Image = image
		icon.ImageColor3 = TEXT_PRIMARY
	end

	if prefersGamepadInput() then
		showText(gamepadButtonLabel(prompt.GamepadKeyCode))
		return
	end
	if prefersTouchInput() then
		if prompt.HoldDuration > 0 then
			showIcon(TOUCH_HOLD_ICON)
		else
			showIcon(TOUCH_TAP_ICON)
		end
		return
	end
	local kc = prompt.KeyboardKeyCode
	if kc == Enum.KeyCode.Unknown or kc == Enum.KeyCode.E then
		showText("E")
		return
	end
	local name = kc.Name
	if #name == 1 then
		showText(name)
	elseif #name <= 3 then
		showText(string.upper(name))
	else
		showText(string.sub(name, 1, 1))
	end
end

local function refreshAllKeyLabels()
	for _, view in viewsByPrompt do
		if view.billboard.Parent then
			refreshKeyLabel(view)
		end
	end
	local bush = bushSharedView
	if bush and bush.billboard.Parent then
		refreshKeyLabel(bush)
	end
end

local function triggerPromptTap(prompt: ProximityPrompt)
	if not prompt.Enabled then
		return
	end
	local began = prompt:InputHoldBegin()
	if prompt.HoldDuration <= 0 and began then
		prompt:InputHoldEnd()
	end
end

local function hidePlacePromptViewsIfNeeded()
	if canShowPlaceBrainrotUi() then
		return
	end
	for prompt, view in viewsByPrompt do
		if isPlaceBrainrotPrompt(prompt) then
			hideView(prompt, true)
		end
	end
end

local function wireClickablePrompt(view: PromptView)
	if view.clickWired then
		return
	end
	view.clickWired = true

	local root = view.root
	root.Active = true

	local existing = root:FindFirstChild("ClickTarget")
	if existing then
		existing:Destroy()
	end

	-- ImageButton: use MouseLeave (not MouseButton1Leave — that event does not exist on ImageButton).
	local clickBtn = Instance.new("ImageButton")
	clickBtn.Name = "ClickTarget"
	clickBtn.Size = UDim2.fromScale(1, 1)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Image = ""
	clickBtn.ImageTransparency = 1
	clickBtn.AutoButtonColor = false
	clickBtn.ZIndex = 20
	clickBtn.Parent = root

	local touchMinPx = if prefersTouchInput() then MIN_TOUCH_PX_MOBILE else MIN_TOUCH_PX
	local touchMin = Instance.new("UISizeConstraint")
	touchMin.MinSize = Vector2.new(touchMinPx, touchMinPx)
	touchMin.Parent = clickBtn

	if view.prompt.HoldDuration > 0 then
		local function beginPointerHold()
			local prompt = view.prompt
			if not shouldShowPromptUi(prompt) or view.holding then
				return
			end
			view.holdViaPointer = true
			beginHoldVisual(view)
		end
		local function endPointerHold()
			if not view.holding then
				return
			end
			view.holdViaPointer = false
			endHoldVisual(view, false)
		end
		local function beginKeyboardHold()
			local prompt = view.prompt
			if not shouldShowPromptUi(prompt) or view.holding then
				return
			end
			view.holdViaPointer = false
			beginHoldVisual(view)
		end
		local function endKeyboardHold()
			if not view.holding or view.holdViaPointer then
				return
			end
			endHoldVisual(view, false)
		end
		local function matchesKeyboardHold(input: InputObject): boolean
			local prompt = view.prompt
			return input.KeyCode == prompt.KeyboardKeyCode or input.KeyCode == Enum.KeyCode.E
		end
		local function matchesGamepadHold(input: InputObject): boolean
			local prompt = view.prompt
			local gc = prompt.GamepadKeyCode
			return gc ~= Enum.KeyCode.Unknown and input.KeyCode == gc
		end

		table.insert(view.clickConns, clickBtn.MouseButton1Down:Connect(beginPointerHold))
		table.insert(view.clickConns, clickBtn.MouseButton1Up:Connect(endPointerHold))
		table.insert(view.clickConns, clickBtn.MouseLeave:Connect(endPointerHold))
		table.insert(
			view.clickConns,
			clickBtn.InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					beginPointerHold()
				end
			end)
		)
		table.insert(
			view.clickConns,
			clickBtn.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					endPointerHold()
				end
			end)
		)

		table.insert(
			view.clickConns,
			UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
				local prompt = view.prompt
				if not prompt.Enabled then
					return
				end
				if isManagedBushPrompt(prompt) and processed then
					return
				end
				if processed and input.UserInputType == Enum.UserInputType.Keyboard then
					return
				end
				if input.UserInputType == Enum.UserInputType.Keyboard and matchesKeyboardHold(input) then
					beginKeyboardHold()
				elseif input.UserInputType == Enum.UserInputType.Gamepad1 and matchesGamepadHold(input) then
					beginKeyboardHold()
				end
			end)
		)
		table.insert(
			view.clickConns,
			UserInputService.InputEnded:Connect(function(input: InputObject, _processed: boolean)
				if input.UserInputType == Enum.UserInputType.Keyboard and matchesKeyboardHold(input) then
					endKeyboardHold()
				elseif input.UserInputType == Enum.UserInputType.Gamepad1 and matchesGamepadHold(input) then
					endKeyboardHold()
				end
			end)
		)
	else
		local lastTapAt = 0
		local function tryTapPrompt()
			local prompt = view.prompt
			if not shouldShowPromptUi(prompt) then
				return
			end
			local now = os.clock()
			if now - lastTapAt < 0.12 then
				return
			end
			lastTapAt = now
			UIInteractionSounds.playClick()
			triggerPromptTap(prompt)
		end
		table.insert(view.clickConns, clickBtn.Activated:Connect(tryTapPrompt))
		table.insert(
			view.clickConns,
			clickBtn.InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					tryTapPrompt()
				end
			end)
		)
	end
end

local function getPromptAdornee(prompt: ProximityPrompt): BasePart?
	local parent = prompt.Parent
	if not parent then
		return nil
	end
	if parent:IsA("Attachment") then
		local part = parent.Parent
		if part and part:IsA("BasePart") then
			return part
		end
	end
	if parent:IsA("BasePart") then
		return parent
	end
	if parent:IsA("Model") then
		if parent.PrimaryPart then
			return parent.PrimaryPart
		end
		return parent:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function isUnderBushScripts(inst: Instance?): boolean
	local node: Instance? = inst
	while node do
		if node.Name == "BushSCRIPTs" or node.Name == "BushSCRIPT" then
			return true
		end
		node = node.Parent
	end
	return false
end

local function findBushModelForPrompt(prompt: ProximityPrompt): Model?
	local node: Instance? = prompt.Parent
	local best: Model? = nil
	while node do
		if node:IsA("Model") and isUnderBushScripts(node) then
			best = node :: Model
		end
		node = node.Parent
	end
	return best
end

local function findStandForPrompt(prompt: ProximityPrompt): Model?
	local node: Instance? = prompt.Parent
	while node do
		if node:IsA("Model") then
			local m = node :: Model
			if m:GetAttribute(STAND_NAME_ATTR) ~= nil or m:FindFirstChild("Spawn", true) then
				return m
			end
		end
		node = node.Parent
	end
	return nil
end

local function resolvePromptLabels(prompt: ProximityPrompt): (string, string)
	local stand = findStandForPrompt(prompt)
	if stand then
		local name = stand:GetAttribute(STAND_NAME_ATTR)
		if typeof(name) == "string" and name ~= "" then
			local level = stand:GetAttribute(STAND_LEVEL_ATTR)
			local lvl = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1
			return "Pick Up", string.format("Lvl %d %s", lvl, name)
		end
	end
	return prompt.ActionText, prompt.ObjectText
end

local function measureCardWidth(actionText: string, objectText: string, _holdDuration: number): number
	local measureBounds = Vector2.new(512, 48)
	local actionSize = TextService:GetTextSize(actionText, 17, Enum.Font.GothamBold, measureBounds)
	local objectSize = TextService:GetTextSize(objectText, 14, Enum.Font.Gotham, measureBounds)
	local textW = math.max(actionSize.X, objectSize.X)
	local total = PAD_LEFT + BADGE_SIZE + BADGE_TEXT_GAP + math.ceil(textW) + PAD_RIGHT
	return math.clamp(total, MIN_CARD_W, MAX_CARD_W)
end

local function applyLabelsToView(view: PromptView)
	local actionText, objectText = resolvePromptLabels(view.prompt)
	view.actionLabel.Text = actionText
	view.objectLabel.Text = objectText
	view.billboard.Size = UDim2.fromOffset(measureCardWidth(actionText, objectText, view.prompt.HoldDuration), CARD_H)
	refreshKeyLabel(view)
end

local function stopIdleSway(view: PromptView)
	view.swayToken += 1
end

local function stopHoldRender(view: PromptView)
	if view.holdRenderConn then
		view.holdRenderConn:Disconnect()
		view.holdRenderConn = nil
	end
end

local function setHoldTrackVisible(view: PromptView, visible: boolean)
	view.holdTrack.Visible = visible
	view.holdFill.Visible = visible
end

local function holdTrackHeight(_view: PromptView): number
	return math.max(8, BADGE_SIZE - BADGE_HOLD_PAD * 2)
end

local function resetKeyBadgeVisuals(view: PromptView)
	view.keyBadge.BackgroundColor3 = BADGE_BG
	view.keyBadge.BackgroundTransparency = BADGE_BG_TRANSPARENCY
	view.keyStroke.Color = ACCENT_STROKE
	view.keyStroke.Transparency = 0.35
	view.keyLabel.TextColor3 = TEXT_PRIMARY
	view.keyIcon.ImageColor3 = TEXT_PRIMARY
	local trackH = holdTrackHeight(view)
	view.holdTrack.Size = UDim2.new(1, -BADGE_HOLD_PAD * 2, 1, -BADGE_HOLD_PAD * 2)
	view.holdFill.Size = UDim2.new(1, 0, 0, 0)
	view.holdFill.BackgroundTransparency = 0.05
	setHoldTrackVisible(view, view.prompt.HoldDuration > 0)
end

local function setHoldFillProgress(view: PromptView, progress: number)
	local t = math.clamp(progress, 0, 1)
	view.holdFill.Size = UDim2.new(1, 0, t, 0)
end

local function getLocalHumanoid(): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

local function stopBushWobbleRenderStep()
	if bushWobbleStepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(BUSH_WOBBLE_STEP)
		end)
		bushWobbleStepBound = false
	end
end

local function stopBushCameraShake()
	if bushCameraShakeStepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(BUSH_CAM_SHAKE_STEP)
		end)
		bushCameraShakeStepBound = false
	end
	cameraShakeActive = false
	local hum = getLocalHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function startBushCameraShake()
	if cameraShakeActive and bushCameraShakeStepBound then
		return
	end
	cameraShakeActive = true
	if bushCameraShakeStepBound then
		return
	end
	bushCameraShakeStepBound = true
	RunService:BindToRenderStep(BUSH_CAM_SHAKE_STEP, Enum.RenderPriority.Camera.Value + 50, function()
		if not cameraShakeActive then
			stopBushCameraShake()
			return
		end
		local hum = getLocalHumanoid()
		if not hum then
			return
		end
		local t = os.clock() * BUSH_CAM_SHAKE_SPEED
		hum.CameraOffset = Vector3.new(
			(math.noise(t, 0, 0) - 0.5) * 2 * BUSH_CAM_SHAKE_POS,
			(math.noise(0, t, 1) - 0.5) * 2 * BUSH_CAM_SHAKE_POS,
			(math.noise(t, 2, 0.5) - 0.5) * 2 * BUSH_CAM_SHAKE_POS * 0.35
		)
	end)
end

local function applyBushWobble(t: number, seed: number)
	local bush = bushWobbleModel
	local base = bushWobbleBasePivot
	if not bush or not base or not bush.Parent then
		return
	end
	local nx = math.noise(t * 9, seed, 0) * BUSH_WOBBLE_POS
	local ny = math.noise(seed + 1, t * 9, 0.5) * BUSH_WOBBLE_POS * 0.6
	local nz = math.noise(t * 9, seed + 2, 1) * BUSH_WOBBLE_POS
	local rx = math.noise(t * 7, seed + 3, 2) * BUSH_WOBBLE_ROT
	local ry = math.noise(seed + 4, t * 7, 3) * BUSH_WOBBLE_ROT * 1.2
	local rz = math.noise(t * 7, seed + 5, 4) * BUSH_WOBBLE_ROT * 0.7
	pcall(function()
		bush:PivotTo(base * CFrame.new(nx, ny, nz) * CFrame.Angles(rx, ry, rz))
	end)
end

local function stopBushWobble()
	stopBushWobbleRenderStep()
	if bushWobbleModel and bushWobbleBasePivot and bushWobbleModel.Parent then
		pcall(function()
			bushWobbleModel:PivotTo(bushWobbleBasePivot :: CFrame)
		end)
	end
	bushWobbleModel = nil
	bushWobbleBasePivot = nil
end

local function beginBushWobble(prompt: ProximityPrompt)
	local bush = findBushModelForPrompt(prompt)
	if not bush or not bush.Parent then
		stopBushWobble()
		return
	end
	stopBushWobble()
	bushWobbleModel = bush
	bushWobbleBasePivot = bush:GetPivot()
	bushWobbleSeed = math.random() * 10
	bushWobbleStepBound = true
	RunService:BindToRenderStep(BUSH_WOBBLE_STEP, Enum.RenderPriority.Last.Value, function()
		if not bushWobbleModel or not bushWobbleBasePivot then
			stopBushWobbleRenderStep()
			return
		end
		if not bushWobbleModel.Parent then
			stopBushWobble()
			return
		end
		applyBushWobble(os.clock(), bushWobbleSeed)
	end)
end

beginHoldVisual = function(view: PromptView, skipPromptHoldBegin: boolean?)
	if view.holding or view.prompt.HoldDuration <= 0 then
		return
	end
	if not skipPromptHoldBegin then
		pcall(function()
			view.prompt:InputHoldBegin()
		end)
	end
	stopIdleSway(view)
	setHoldTrackVisible(view, true)
	view.holding = true
	view.holdProgress = 0
	view.holdStartTime = os.clock()
	applyHoldBadgeActive(view)
	setHoldFillProgress(view, 0)
	startHoldRender(view)
end

endHoldVisual = function(view: PromptView, completed: boolean?)
	if not view.holding then
		return
	end
	local done = if completed == nil then view.holdProgress >= HOLD_COMPLETE_THRESHOLD else completed
	resetHoldState(view, done)
end

applyHoldBadgeActive = function(view: PromptView)
	view.keyBadge.BackgroundColor3 = BADGE_BG
	view.keyBadge.BackgroundTransparency = 0.2
	view.keyStroke.Color = HOLD_GREEN_BRIGHT
	view.keyStroke.Transparency = 0.1
	view.holdTrack.BackgroundTransparency = 0.15
end

-- Bush-style noisy wiggle on a GuiObject rotation
local function wiggleRotation(target: GuiObject, seed: number, t: number): number
	return math.deg(
		math.noise(t * WIGGLE_SPEED, seed, 0.5) * WIGGLE_ROT
			+ math.noise(t * WIGGLE_SPEED * 0.7, seed + 2, 1.2) * WIGGLE_ROT * 0.55
	)
end

-- ── Animations ────────────────────────────────────────────────────────────────

local function flashKeyYellow(view: PromptView, holdGreenAfter: boolean?)
	local badge = view.keyBadge
	local badgeScale = getOrAddUIScale(badge)

	badge.BackgroundColor3 = PRESS_FLASH
	badge.BackgroundTransparency = 0.05
	view.keyStroke.Color = PRESS_FLASH
	view.keyLabel.TextColor3 = Color3.new(0.12, 0.1, 0.05)

	TweenService:Create(view.keyLabel, FLASH_TWEEN, { TextColor3 = PRESS_FLASH }):Play()
	TweenService:Create(badgeScale, TILT_RIGHT, { Scale = 1.1 }):Play()

	task.delay(0.14, function()
		if not badge.Parent then
			return
		end
		if holdGreenAfter then
			applyHoldBadgeActive(view)
		else
			resetKeyBadgeVisuals(view)
		end
		TweenService:Create(view.keyLabel, BADGE_TWEEN, { TextColor3 = TEXT_PRIMARY }):Play()
		TweenService:Create(badgeScale, BADGE_TWEEN, { Scale = 1 }):Play()
	end)
end

local function playPressAnim(view: PromptView)
	local root = view.root
	local badge = view.keyBadge
	local badgeScale = getOrAddUIScale(badge)

	stopIdleSway(view)
	root.Rotation = 0
	flashKeyYellow(view, false)

	TweenService:Create(badgeScale, TILT_LEFT, { Scale = 0.92 }):Play()
	task.delay(0.09, function()
		if not badge.Parent then
			return
		end
		TweenService:Create(root, TILT_LEFT, { Rotation = -7 }):Play()
		TweenService:Create(badge, TILT_LEFT, { Rotation = -9 }):Play()
		TweenService:Create(badgeScale, TILT_RIGHT, { Scale = 1.08 }):Play()
	end)
	task.delay(0.2, function()
		if not badge.Parent then
			return
		end
		TweenService:Create(root, TILT_RIGHT, { Rotation = 6 }):Play()
		TweenService:Create(badge, TILT_RIGHT, { Rotation = 8 }):Play()
	end)
	task.delay(0.34, function()
		if not root.Parent then
			return
		end
		TweenService:Create(root, TILT_CENTER, { Rotation = 0 }):Play()
		TweenService:Create(badge, TILT_CENTER, { Rotation = 0 }):Play()
		TweenService:Create(badgeScale, TILT_CENTER, { Scale = 1 }):Play()
		if not view.holding and viewIsActive(view) then
			startIdleSway(view)
		end
	end)
end

startIdleSway = function(view: PromptView)
	stopIdleSway(view)
	local token = view.swayToken
	local phase = math.random() * math.pi * 2

	task.spawn(function()
		while viewIsActive(view) and view.swayToken == token and not view.holding do
			local t = os.clock() * SWAY_FREQ + phase
			view.root.Rotation = math.sin(t) * SWAY_AMP
			RunService.Heartbeat:Wait()
		end
		if view.swayToken == token and not view.holding and viewIsActive(view) then
			view.root.Rotation = 0
		end
	end)
end

local function playHoldComplete(view: PromptView)
	stopHoldRender(view)
	view.holding = false
	stopIdleSway(view)

	local badgeScale = getOrAddUIScale(view.keyBadge)
	view.root.Rotation = 0
	view.keyBadge.Rotation = 0

	view.keyBadge.BackgroundColor3 = HOLD_GREEN_BRIGHT
	view.keyBadge.BackgroundTransparency = 0
	view.keyStroke.Color = ACCENT_BRIGHT
	view.keyStroke.Transparency = 0
	view.keyLabel.TextColor3 = HOLD_COMPLETE_FLASH

	TweenService:Create(badgeScale, POP_TWEEN, { Scale = 1.22 }):Play()
	task.delay(0.16, function()
		if not view.keyBadge.Parent then
			return
		end
		TweenService:Create(badgeScale, POP_TWEEN, { Scale = 1 }):Play()
	end)
	task.delay(0.28, function()
		if not viewIsActive(view) then
			return
		end
		resetKeyBadgeVisuals(view)
		setHoldFillProgress(view, 0)
		startIdleSway(view)
	end)
end

-- Visual-only hold bar for managed bush card (engine owns the real ProximityPrompt hold).
local function stopBushSharedCardHoldVisual(view: PromptView, completed: boolean)
	if not view.displayOnly then
		return
	end
	stopHoldRender(view)
	view.root.Rotation = 0
	view.keyBadge.Rotation = 0
	if completed then
		playHoldComplete(view)
	else
		resetKeyBadgeVisuals(view)
		setHoldFillProgress(view, 0)
		if bushSharedView == view and view.billboard.Enabled then
			startIdleSway(view)
		end
	end
end

local function startBushSharedCardHoldVisual(view: PromptView)
	if not view.displayOnly then
		return
	end
	stopHoldRender(view)
	stopIdleSway(view)
	applyHoldBadgeActive(view)
	setHoldFillProgress(view, 0)
	local dur = view.prompt.HoldDuration
	local seed = math.random() * 10
	local t0 = os.clock()
	view.holdRenderConn = RunService.RenderStepped:Connect(function()
		if dur > 0 then
			local p = math.clamp((os.clock() - t0) / dur, 0, 1)
			setHoldFillProgress(view, p)
			local pulse = 0.04 + math.sin(os.clock() * 14) * 0.03
			view.holdFill.BackgroundTransparency = math.clamp(0.05 - pulse, 0, 0.2)
		end
		local t = os.clock()
		view.root.Rotation = wiggleRotation(view.root, seed, t)
		view.keyBadge.Rotation = wiggleRotation(view.keyBadge, seed + 4, t)
	end)
end

-- Managed bush card: engine owns hold/trigger; card must forward touch to InputHoldBegin/End.
local function wireBushSharedClickable(view: PromptView)
	if view.clickWired then
		return
	end
	view.clickWired = true

	view.billboard.Active = true
	view.root.Active = true

	local root = view.root
	local existing = root:FindFirstChild("ClickTarget")
	if existing then
		existing:Destroy()
	end

	local clickBtn = Instance.new("ImageButton")
	clickBtn.Name = "ClickTarget"
	clickBtn.Size = UDim2.fromScale(1, 1)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Image = ""
	clickBtn.ImageTransparency = 1
	clickBtn.AutoButtonColor = false
	clickBtn.ZIndex = 20
	clickBtn.Parent = root

	local touchMinPx = if prefersTouchInput() then MIN_TOUCH_PX_MOBILE else MIN_TOUCH_PX
	local touchMin = Instance.new("UISizeConstraint")
	touchMin.MinSize = Vector2.new(touchMinPx, touchMinPx)
	touchMin.Parent = clickBtn

	local pointerHoldActive = false

	local function canInteractWithBush(): boolean
		return managedBushUiEligible(view.prompt)
	end

	local function beginPointerHold()
		local prompt = view.prompt
		if not canInteractWithBush() or pointerHoldActive then
			return
		end
		pointerHoldActive = true
		startBushSharedCardHoldVisual(view)
		pcall(function()
			prompt:InputHoldBegin()
		end)
	end

	local function endPointerHold()
		if not pointerHoldActive then
			return
		end
		pointerHoldActive = false
		stopBushSharedCardHoldVisual(view, false)
		pcall(function()
			view.prompt:InputHoldEnd()
		end)
	end

	if view.prompt.HoldDuration > 0 then
		table.insert(view.clickConns, clickBtn.MouseButton1Down:Connect(beginPointerHold))
		table.insert(view.clickConns, clickBtn.MouseButton1Up:Connect(endPointerHold))
		table.insert(view.clickConns, clickBtn.MouseLeave:Connect(endPointerHold))
		table.insert(
			view.clickConns,
			clickBtn.InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					beginPointerHold()
				end
			end)
		)
		table.insert(
			view.clickConns,
			clickBtn.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					endPointerHold()
				end
			end)
		)
	else
		local lastTapAt = 0
		local function tryTapPrompt()
			if not canInteractWithBush() then
				return
			end
			local now = os.clock()
			if now - lastTapAt < 0.12 then
				return
			end
			lastTapAt = now
			UIInteractionSounds.playClick()
			triggerPromptTap(view.prompt)
		end
		table.insert(view.clickConns, clickBtn.Activated:Connect(tryTapPrompt))
		table.insert(
			view.clickConns,
			clickBtn.InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.Touch then
					tryTapPrompt()
				end
			end)
		)
	end
end

resetHoldState = function(view: PromptView, celebrate: boolean)
	stopHoldRender(view)
	view.holding = false
	view.holdViaPointer = false
	view.holdProgress = 0
	view.root.Rotation = 0
	view.keyBadge.Rotation = 0

	if celebrate then
		playHoldComplete(view)
	else
		resetKeyBadgeVisuals(view)
		setHoldFillProgress(view, 0)
		if viewIsActive(view) then
			startIdleSway(view)
		end
	end
end

startHoldRender = function(view: PromptView)
	stopHoldRender(view)
	local seed = math.random() * 10

	view.holdRenderConn = RunService.RenderStepped:Connect(function()
		if not view.holding then
			return
		end

		local dur = view.prompt.HoldDuration
		if dur > 0 then
			view.holdProgress = math.clamp((os.clock() - view.holdStartTime) / dur, 0, 1)
			setHoldFillProgress(view, view.holdProgress)
			local pulse = 0.04 + math.sin(os.clock() * 14) * 0.03
			view.holdFill.BackgroundTransparency = math.clamp(0.05 - pulse, 0, 0.2)

			if view.holdProgress >= HOLD_COMPLETE_THRESHOLD then
				stopHoldRender(view)
				pcall(function()
					view.prompt:InputHoldEnd()
				end)
				resetHoldState(view, true)
				return
			end
		end

		local t = os.clock()
		view.root.Rotation = wiggleRotation(view.root, seed, t)
		view.keyBadge.Rotation = wiggleRotation(view.keyBadge, seed + 4, t)
	end)
end

-- ── UI build ──────────────────────────────────────────────────────────────────

local function buildPromptView(prompt: ProximityPrompt, displayOnly: boolean?): PromptView
	local adornee = getPromptAdornee(prompt)

	local isDisplayOnly = displayOnly == true

	local billboard = Instance.new("BillboardGui")
	billboard.Name = if isDisplayOnly then "BushSearchSharedPrompt" else "CustomProximityPrompt"
	billboard.Active = not isDisplayOnly
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.max(prompt.MaxActivationDistance * 1.5, 40)
	billboard.Size = UDim2.fromOffset(MIN_CARD_W, CARD_H)
	billboard.StudsOffset = Vector3.new(0, 1.8, 0)
	billboard.Adornee = adornee
	-- Parent to PlayerGui so touch/mouse hits the card reliably (world-parented billboards miss on mobile).
	local pg = player:FindFirstChild("PlayerGui")
	if pg and adornee then
		billboard.ResetOnSpawn = false
		billboard.Parent = pg
	else
		billboard.Parent = adornee or prompt
	end

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Active = not isDisplayOnly
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = BG_COLOR
	root.BackgroundTransparency = BG_TRANSPARENCY
	root.BorderSizePixel = 0
	root.Parent = billboard

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 10)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Color = ACCENT
	rootStroke.Thickness = 1.5
	rootStroke.Transparency = 0.25
	rootStroke.Parent = root

	local rootGrad = Instance.new("UIGradient")
	rootGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 22, 28)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 10, 14)),
	})
	rootGrad.Rotation = 90
	rootGrad.Parent = root

	local rootScale = getOrAddUIScale(root)
	rootScale.Scale = 0.82

	local keyBadge = Instance.new("Frame")
	keyBadge.Name = "KeyBadge"
	keyBadge.AnchorPoint = Vector2.new(0, 0.5)
	keyBadge.Position = UDim2.new(0, PAD_LEFT, 0.5, 0)
	keyBadge.Size = UDim2.fromOffset(BADGE_SIZE, BADGE_SIZE)
	keyBadge.BackgroundColor3 = BADGE_BG
	keyBadge.BackgroundTransparency = BADGE_BG_TRANSPARENCY
	keyBadge.BorderSizePixel = 0
	keyBadge.Parent = root

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 8)
	badgeCorner.Parent = keyBadge

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = ACCENT_STROKE
	keyStroke.Thickness = 1.5
	keyStroke.Transparency = 0.35
	keyStroke.Parent = keyBadge

	local holdTrack = Instance.new("Frame")
	holdTrack.Name = "HoldTrack"
	holdTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	holdTrack.Position = UDim2.fromScale(0.5, 0.5)
	holdTrack.Size = UDim2.new(1, -BADGE_HOLD_PAD * 2, 1, -BADGE_HOLD_PAD * 2)
	holdTrack.BackgroundColor3 = Color3.fromRGB(8, 20, 12)
	holdTrack.BackgroundTransparency = 0.15
	holdTrack.BorderSizePixel = 0
	holdTrack.ClipsDescendants = true
	holdTrack.ZIndex = 1
	holdTrack.Visible = prompt.HoldDuration > 0
	holdTrack.Parent = keyBadge

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 6)
	trackCorner.Parent = holdTrack

	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = ACCENT_STROKE
	trackStroke.Thickness = 1.25
	trackStroke.Transparency = 0.35
	trackStroke.Parent = holdTrack

	local holdFill = Instance.new("Frame")
	holdFill.Name = "HoldFill"
	holdFill.AnchorPoint = Vector2.new(0.5, 1)
	holdFill.Position = UDim2.new(0.5, 0, 1, 0)
	holdFill.Size = UDim2.new(1, 0, 0, 0)
	holdFill.BackgroundColor3 = HOLD_GREEN_BRIGHT
	holdFill.BackgroundTransparency = 0.08
	holdFill.BorderSizePixel = 0
	holdFill.ZIndex = 2
	holdFill.Visible = prompt.HoldDuration > 0
	holdFill.Parent = holdTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = holdFill

	local fillGrad = Instance.new("UIGradient")
	fillGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, HOLD_GREEN),
		ColorSequenceKeypoint.new(0.5, HOLD_GREEN_BRIGHT),
		ColorSequenceKeypoint.new(1, ACCENT_BRIGHT),
	})
	fillGrad.Rotation = 90
	fillGrad.Parent = holdFill

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Key"
	keyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	keyLabel.Position = UDim2.fromScale(0.5, 0.5)
	keyLabel.Size = UDim2.new(1, -6, 1, -6)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextSize = 22
	keyLabel.TextColor3 = TEXT_PRIMARY
	keyLabel.ZIndex = 5
	keyLabel.Parent = keyBadge

	local keyIcon = Instance.new("ImageLabel")
	keyIcon.Name = "KeyIcon"
	keyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	keyIcon.Position = UDim2.fromScale(0.5, 0.5)
	keyIcon.Size = UDim2.new(1, -10, 1, -10)
	keyIcon.BackgroundTransparency = 1
	keyIcon.ScaleType = Enum.ScaleType.Fit
	keyIcon.ImageColor3 = TEXT_PRIMARY
	keyIcon.Visible = false
	keyIcon.ZIndex = 6
	keyIcon.Parent = keyBadge

	local textCol = Instance.new("Frame")
	textCol.Name = "TextColumn"
	textCol.AnchorPoint = Vector2.new(0, 0.5)
	textCol.Position = UDim2.new(0, PAD_LEFT + BADGE_SIZE + BADGE_TEXT_GAP, 0.5, 0)
	textCol.Size = UDim2.new(1, -(PAD_LEFT + BADGE_SIZE + BADGE_TEXT_GAP + PAD_RIGHT), 1, -8)
	textCol.BackgroundTransparency = 1
	textCol.Parent = root

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "Action"
	actionLabel.Size = UDim2.new(1, 0, 0.52, 0)
	actionLabel.BackgroundTransparency = 1
	actionLabel.Font = Enum.Font.GothamBold
	actionLabel.TextSize = 17
	actionLabel.TextXAlignment = Enum.TextXAlignment.Left
	actionLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	actionLabel.TextColor3 = TEXT_PRIMARY
	actionLabel.TextWrapped = false
	actionLabel.TextTruncate = Enum.TextTruncate.AtEnd
	actionLabel.Parent = textCol

	local objectLabel = Instance.new("TextLabel")
	objectLabel.Name = "Object"
	objectLabel.Position = UDim2.fromScale(0, 0.48)
	objectLabel.Size = UDim2.new(1, 0, 0.52, 0)
	objectLabel.BackgroundTransparency = 1
	objectLabel.Font = Enum.Font.Gotham
	objectLabel.TextSize = 14
	objectLabel.TextXAlignment = Enum.TextXAlignment.Left
	objectLabel.TextYAlignment = Enum.TextYAlignment.Top
	objectLabel.TextColor3 = TEXT_SECONDARY
	objectLabel.TextWrapped = false
	objectLabel.TextTruncate = Enum.TextTruncate.AtEnd
	objectLabel.Parent = textCol

	local view: PromptView = {
		prompt = prompt,
		billboard = billboard,
		root = root,
		rootScale = rootScale,
		keyBadge = keyBadge,
		keyStroke = keyStroke,
		keyLabel = keyLabel,
		keyIcon = keyIcon,
		holdTrack = holdTrack,
		holdFill = holdFill,
		actionLabel = actionLabel,
		objectLabel = objectLabel,
		holding = false,
		holdViaPointer = false,
		holdProgress = 0,
		holdStartTime = 0,
		swayToken = 0,
		holdRenderConn = nil,
		liveConns = {},
		clickConns = {},
		clickWired = false,
		displayOnly = isDisplayOnly,
	}

	applyLabelsToView(view)
	refreshKeyLabel(view)
	if not isDisplayOnly then
		wireClickablePrompt(view)
	end
	return view
end

-- ── View lifecycle ────────────────────────────────────────────────────────────

hideView = function(prompt: ProximityPrompt, instant: boolean?)
	if isManagedBushPrompt(prompt) then
		stopBushCameraShake()
		stopBushWobble()
		if bushSharedView and bushSharedView.prompt == prompt then
			stopHoldRender(bushSharedView)
			resetKeyBadgeVisuals(bushSharedView)
			setHoldFillProgress(bushSharedView, 0)
			activeBushSearchPrompt = nil
			hideBushSharedUi(true)
		end
		if viewsByPrompt[prompt] then
			destroyView(prompt)
		end
		return
	end

	local view = viewsByPrompt[prompt]
	if not view then
		return
	end

	stopIdleSway(view)
	stopHoldRender(view)
	view.holding = false
	view.holdViaPointer = false

	if instant then
		destroyView(prompt)
		return
	end

	local scale = view.rootScale
	local t = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
	t.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and viewsByPrompt[prompt] == view then
			destroyView(prompt)
		end
	end)
	t:Play()
end

destroyView = function(prompt: ProximityPrompt)
	local view = viewsByPrompt[prompt]
	if not view then
		return
	end

	stopIdleSway(view)
	stopHoldRender(view)
	disconnectAll(view.liveConns)
	disconnectAll(view.clickConns)
	viewsByPrompt[prompt] = nil

	if view.billboard.Parent then
		view.billboard:Destroy()
	end
end

clearBushPerPromptViews = function()
	local removeList: { ProximityPrompt } = {}
	for prompt in viewsByPrompt do
		if CarryGate.isBushSearchPrompt(prompt) then
			table.insert(removeList, prompt)
		end
	end
	for _, prompt in removeList do
		destroyView(prompt)
	end
end

hideBushSharedUi = function(instant: boolean?)
	local view = bushSharedView
	if not view then
		return
	end

	stopIdleSway(view)
	stopHoldRender(view)
	view.holding = false
	view.holdViaPointer = false
	resetKeyBadgeVisuals(view)
	setHoldFillProgress(view, 0)
	view.root.Rotation = 0
	view.keyBadge.Rotation = 0

	if instant then
		view.billboard.Enabled = false
		view.billboard.Adornee = nil
		return
	end

	local scale = view.rootScale
	local t = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
	t.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and bushSharedView == view then
			view.billboard.Enabled = false
			view.billboard.Adornee = nil
		end
	end)
	t:Play()
end

showBushSharedUi = function(prompt: ProximityPrompt): boolean
	clearBushPerPromptViews()
	local map = Workspace:FindFirstChild("Map")
	if map then
		for _, desc in map:GetDescendants() do
			if desc:IsA("BillboardGui") then
				if desc.Name == "BushSearchSharedPrompt" or desc.Name == "CustomProximityPrompt" then
					local adornee = desc.Adornee
					if adornee and isUnderBushScripts(adornee) then
						desc:Destroy()
					end
				end
			end
		end
	end

	local adornee = getPromptAdornee(prompt)
	if not adornee then
		return false
	end

	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return false
	end

	local view = bushSharedView
	if not view or not view.billboard.Parent then
		local ok, built = pcall(buildPromptView, prompt, true)
		if not ok or not built then
			return false
		end
		view = built
		view.billboard.Name = "BushSearchSharedPrompt"
		view.billboard.Parent = pg
		bushSharedView = view
	end

	view.prompt = prompt
	view.billboard.Adornee = adornee
	view.billboard.StudsOffset = Vector3.new(0, 1.8, 0)
	local bushModel = findBushModelForPrompt(prompt)
	if bushModel then
		local ok, _cf, size = pcall(function()
			return bushModel:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			view.billboard.StudsOffset = Vector3.new(0, math.max(2.2, size.Y * 0.42 + 0.8), 0)
		end
	end
	view.billboard.Enabled = true
	applyLabelsToView(view)
	refreshKeyLabel(view)
	setHoldTrackVisible(view, view.prompt.HoldDuration > 0)
	wirePromptLiveUpdates(prompt, view)
	wireBushSharedClickable(view)

	if not view.holding then
		view.rootScale.Scale = 0.82
		TweenService:Create(view.rootScale, OPEN_TWEEN, { Scale = 1 }):Play()
		startIdleSway(view)
	end

	return true
end

local function tryGetClockImageAsset(): string
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return ""
	end
	-- Studio: ClockImage is often a direct child of StarterGui → PlayerGui (sibling of Main).
	local direct = pg:FindFirstChild("ClockImage")
	if direct and direct:IsA("ImageLabel") then
		return (direct :: ImageLabel).Image
	end
	if direct and direct:IsA("ImageButton") then
		return (direct :: ImageButton).Image
	end
	local main = pg:FindFirstChild("Main")
	if main then
		local clk = main:FindFirstChild("ClockImage", true)
		if clk and clk:IsA("ImageLabel") then
			return (clk :: ImageLabel).Image
		end
		if clk and clk:IsA("ImageButton") then
			return (clk :: ImageButton).Image
		end
	end
	return ""
end

local function destroyBushCooldownBannerInner()
	if bushCooldownConn then
		bushCooldownConn:Disconnect()
		bushCooldownConn = nil
	end
	if bushCooldownBillboard then
		bushCooldownBillboard:Destroy()
		bushCooldownBillboard = nil
	end
	bushCooldownPromptRef = nil
	bushCooldownEndClock = 0
end

function ProximityPromptEffects.hideBushCooldownBanner()
	destroyBushCooldownBannerInner()
end

function ProximityPromptEffects.showBushCooldownBanner(prompt: ProximityPrompt, endClock: number)
	if not prompt.Parent then
		return
	end
	if
		bushCooldownPromptRef == prompt
		and math.abs(bushCooldownEndClock - endClock) < 0.05
		and bushCooldownBillboard
		and bushCooldownBillboard.Parent
	then
		bushCooldownEndClock = endClock
		return
	end

	destroyBushCooldownBannerInner()
	bushCooldownPromptRef = prompt
	bushCooldownEndClock = endClock

	local adornee = getPromptAdornee(prompt)
	if not adornee then
		return
	end

	local pg = player:FindFirstChild("PlayerGui")
	local bb = Instance.new("BillboardGui")
	bb.Name = "BushCooldownBanner"
	bb.Active = false
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false
	bb.ClipsDescendants = false
	-- BillboardGui has no AutomaticSize; inner Frame uses AutomaticSize. Fixed canvas in pixels.
	bb.Size = UDim2.fromOffset(300, 56)
	-- World-space lift so it sits above the bush center, not embedded in the mesh.
	bb.StudsOffset = Vector3.zero
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	bb.MaxDistance = COOLDOWN_BANNER_VIEW_RANGE
	bb.Adornee = adornee
	if pg then
		bb.Parent = pg
	else
		bb.Parent = adornee
	end

	-- No panel / border — only clock + countdown (bush Highlight is the red outline).
	local cluster = Instance.new("Frame")
	cluster.Name = "CooldownCluster"
	cluster.BackgroundTransparency = 1
	cluster.BorderSizePixel = 0
	cluster.AutomaticSize = Enum.AutomaticSize.XY
	cluster.AnchorPoint = Vector2.new(0.5, 0.5)
	cluster.Position = UDim2.fromScale(0.5, 0.5)
	cluster.Size = UDim2.fromOffset(0, 0)
	cluster.Parent = bb

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = cluster

	local icon = Instance.new("ImageLabel")
	icon.Name = "Clock"
	icon.ZIndex = 2
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(40, 40)
	icon.ScaleType = Enum.ScaleType.Fit
	local img = tryGetClockImageAsset()
	icon.Image = if img ~= "" then img else "rbxasset://textures/ui/GuiImagePlaceholder.png"
	icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	icon.LayoutOrder = 0
	icon.Parent = cluster

	local timeLabel = Instance.new("TextLabel")
	timeLabel.Name = "TimeLeft"
	timeLabel.ZIndex = 2
	timeLabel.BackgroundTransparency = 1
	timeLabel.AutomaticSize = Enum.AutomaticSize.XY
	timeLabel.Size = UDim2.fromOffset(0, 0)
	timeLabel.Font = Enum.Font.GothamBold
	timeLabel.TextSize = 28
	timeLabel.TextColor3 = TEXT_PRIMARY
	timeLabel.TextXAlignment = Enum.TextXAlignment.Left
	timeLabel.Text = "0s"
	timeLabel.LayoutOrder = 1
	local tStroke = Instance.new("UIStroke")
	tStroke.Color = Color3.new(0, 0, 0)
	tStroke.Transparency = 0.45
	tStroke.Thickness = 2
	tStroke.Parent = timeLabel
	timeLabel.Parent = cluster

	bushCooldownBillboard = bb

	local function tickCooldownBanner()
		if not bushCooldownBillboard or not bushCooldownBillboard.Parent then
			destroyBushCooldownBannerInner()
			return
		end
		local rem = bushCooldownEndClock - os.clock()
		if rem <= 0 then
			timeLabel.Text = "0s"
			destroyBushCooldownBannerInner()
			return
		end
		timeLabel.Text = string.format("%ds", math.ceil(rem))
	end

	tickCooldownBanner()
	bushCooldownConn = RunService.Heartbeat:Connect(tickCooldownBanner)
end

function ProximityPromptEffects.showBushSearchFor(prompt: ProximityPrompt?)
	if not prompt or not prompt.Parent then
		ProximityPromptEffects.hideBushCooldownBanner()
		ProximityPromptEffects.hideBushSearch()
		return
	end
	ProximityPromptEffects.hideBushCooldownBanner()
	activeBushSearchPrompt = prompt
	local ok, shown = pcall(function()
		return showBushSharedUi(prompt)
	end)
	if not ok then
		warn("[ProximityPromptEffects] showBushSharedUi failed:", shown)
		activeBushSearchPrompt = nil
		ProximityPromptEffects.hideBushSearch()
		return
	end
	if not shown then
		activeBushSearchPrompt = nil
		ProximityPromptEffects.hideBushSearch()
	end
end

function ProximityPromptEffects.hideBushSearch()
	activeBushSearchPrompt = nil
	stopBushCameraShake()
	stopBushWobble()
	hideBushSharedUi(true)
	clearBushPerPromptViews()
	if reshowEligiblePlaceProximityPrompts then
		task.defer(reshowEligiblePlaceProximityPrompts :: () -> ())
	end
end

function ProximityPromptEffects.suppressBushSearchUi(activePrompt: ProximityPrompt?)
	local effective = if CarryGate.isFull() then nil else activePrompt
	if effective and effective.Parent then
		effective.Style = Enum.ProximityPromptStyle.Custom
		pcall(function()
			(effective :: any).ClickablePrompt = true
		end)
		ProximityPromptEffects.showBushSearchFor(effective)
	else
		ProximityPromptEffects.hideBushSearch()
	end
end

local function showView(prompt: ProximityPrompt)
	local existing = viewsByPrompt[prompt]
	if existing and existing.billboard.Parent then
		applyLabelsToView(existing)
		return
	end

	local ok, view = pcall(buildPromptView, prompt)
	if not ok or not view then
		return
	end
	viewsByPrompt[prompt] = view

	applyLabelsToView(view)
	TweenService:Create(view.rootScale, OPEN_TWEEN, { Scale = 1 }):Play()
	startIdleSway(view)
end

wirePromptLiveUpdates = function(prompt: ProximityPrompt, view: PromptView)
	disconnectAll(view.liveConns)

	local function refresh()
		if viewsByPrompt[prompt] == view or (bushSharedView == view and bushSharedView.prompt == prompt) then
			applyLabelsToView(view)
		end
	end

	table.insert(view.liveConns, prompt:GetPropertyChangedSignal("ActionText"):Connect(refresh))
	table.insert(view.liveConns, prompt:GetPropertyChangedSignal("ObjectText"):Connect(refresh))

	local stand = findStandForPrompt(prompt)
	if stand then
		table.insert(view.liveConns, stand:GetAttributeChangedSignal(STAND_NAME_ATTR):Connect(refresh))
		table.insert(view.liveConns, stand:GetAttributeChangedSignal(STAND_LEVEL_ATTR):Connect(refresh))
	end
end

local function onPromptShown(prompt: ProximityPrompt, _inputType: Enum.ProximityPromptInputType)
	if prompt:GetAttribute(CUSTOM_ATTR) ~= true then
		return
	end
	if not shouldShowPromptUi(prompt) then
		hideView(prompt, true)
		return
	end

	local view = viewsByPrompt[prompt]
	if not view then
		showView(prompt)
		view = viewsByPrompt[prompt]
	end
	if view then
		wirePromptLiveUpdates(prompt, view)
		applyLabelsToView(view)
		setHoldTrackVisible(view, prompt.HoldDuration > 0)
	end
end

local function findStandProximityPrompt(stand: Model): ProximityPrompt?
	local decor = stand:FindFirstChild("Decor")
	if decor then
		for _, d in ipairs(decor:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				return d
			end
		end
	end
	local spawnPart = stand:FindFirstChild("Spawn", true)
	if spawnPart and spawnPart:IsA("BasePart") then
		local pp = (spawnPart :: BasePart):FindFirstChildWhichIsA("ProximityPrompt")
		if pp then
			return pp
		end
	end
	return stand:FindFirstChildWhichIsA("ProximityPrompt", true)
end

reshowEligiblePlaceProximityPrompts = function()
	for _, inst in CollectionService:GetTagged(STAND_TAG) do
		if inst:IsA("Model") then
			local pp = findStandProximityPrompt(inst :: Model)
			if pp and pp.Enabled and isPlaceBrainrotPrompt(pp) then
				onPromptShown(pp, Enum.ProximityPromptInputType.Keyboard)
			end
		end
	end
end

function ProximityPromptEffects.syncStandPlaceProximityUi(prompt: ProximityPrompt?)
	if not prompt or not prompt.Parent then
		return
	end
	task.defer(function()
		if not prompt.Parent or not prompt.Enabled then
			return
		end
		if not isPlaceBrainrotPrompt(prompt) then
			return
		end
		if prompt:GetAttribute(CUSTOM_ATTR) ~= true or not shouldShowPromptUi(prompt) then
			return
		end
		onPromptShown(prompt, Enum.ProximityPromptInputType.Keyboard)
	end)
end

local function onPromptHidden(prompt: ProximityPrompt, _inputType: Enum.ProximityPromptInputType)
	if isManagedBushPrompt(prompt) then
		return
	end
	hideView(prompt, false)
end

local function onHoldBegan(prompt: ProximityPrompt, triggerPlayer: Player)
	if triggerPlayer ~= player then
		return
	end
	if isManagedBushPrompt(prompt) then
		if prompt.HoldDuration > 0 then
			startBushCameraShake()
			beginBushWobble(prompt)
			if bushSharedView and bushSharedView.prompt == prompt then
				startBushSharedCardHoldVisual(bushSharedView)
			end
		end
		return
	end
	if prompt:GetAttribute(CUSTOM_ATTR) ~= true then
		return
	end
	if prompt.HoldDuration <= 0 then
		return
	end

	local view = viewsByPrompt[prompt]
	if not view then
		if not shouldShowPromptUi(prompt) then
			return
		end
		showView(prompt)
		view = viewsByPrompt[prompt]
	end
	if view then
		view.holdViaPointer = false
		beginHoldVisual(view, true)
	end
end

local function onHoldEnded(prompt: ProximityPrompt, triggerPlayer: Player)
	if triggerPlayer ~= player then
		return
	end
	if isManagedBushPrompt(prompt) then
		stopBushCameraShake()
		stopBushWobble()
		if bushSharedView and bushSharedView.prompt == prompt then
			stopBushSharedCardHoldVisual(bushSharedView, false)
		end
		return
	end
	if prompt:GetAttribute(CUSTOM_ATTR) ~= true then
		return
	end
	if prompt.HoldDuration <= 0 then
		return
	end

	local view = viewsByPrompt[prompt]
	if view then
		endHoldVisual(view)
	end
end

local function onPromptTriggered(prompt: ProximityPrompt, triggerPlayer: Player)
	if triggerPlayer ~= player then
		return
	end
	if isManagedBushPrompt(prompt) then
		if bushSharedView and bushSharedView.prompt == prompt then
			stopBushSharedCardHoldVisual(bushSharedView, true)
		end
		bushHoldLockUntil = os.clock() + 0.45
		UIInteractionSounds.playClick()
		if bushHoldCompleteHandler then
			task.defer(bushHoldCompleteHandler, prompt)
		end
		return
	end
	if prompt:GetAttribute(CUSTOM_ATTR) ~= true then
		return
	end

	local view = viewsByPrompt[prompt]
	if not view then
		return
	end

	UIInteractionSounds.playClick()
	if prompt.HoldDuration <= 0 then
		playPressAnim(view)
	else
		flashKeyYellow(view, false)
	end
end

-- ── stylePrompt / init ───────────────────────────────────────────────────────

local function wireStylePrompt(prompt: ProximityPrompt)
	if styledPrompts[prompt] then
		return
	end
	styledPrompts[prompt] = true

	local conns: { RBXScriptConnection } = {}

	table.insert(conns, prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
		if isManagedBushPrompt(prompt) then
			if not prompt.Enabled then
				stopBushCameraShake()
				stopBushWobble()
			end
			return
		end
		if not prompt.Enabled then
			hideView(prompt, true)
			return
		end
		-- Stand place prompts (and other client-gated prompts) toggle Enabled without a fresh
		-- PromptShown; Custom style would otherwise stay invisible while E still works.
		task.defer(function()
			if not prompt.Parent or not prompt.Enabled then
				return
			end
			if prompt:GetAttribute(CUSTOM_ATTR) ~= true or not shouldShowPromptUi(prompt) then
				return
			end
			onPromptShown(prompt, Enum.ProximityPromptInputType.Keyboard)
		end)
	end))

	if prompt.HoldDuration > 0 then
		if not isManagedBushPrompt(prompt) then
			table.insert(conns, prompt.PromptButtonHoldBegan:Connect(function(triggerPlayer: Player)
				onHoldBegan(prompt, triggerPlayer)
			end))
			table.insert(conns, prompt.PromptButtonHoldEnded:Connect(function(triggerPlayer: Player)
				onHoldEnded(prompt, triggerPlayer)
			end))
		end
	end

	table.insert(conns, prompt.Destroying:Connect(function()
		hideView(prompt, true)
		styledPrompts[prompt] = nil
		local old = promptStyleConns[prompt]
		if old then
			disconnectAll(old)
			promptStyleConns[prompt] = nil
		end
	end))

	promptStyleConns[prompt] = conns
end

function ProximityPromptEffects.forceHide(prompt: ProximityPrompt)
	hideView(prompt, true)
end

local function applyCustomPromptStyle(prompt: ProximityPrompt)
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute(CUSTOM_ATTR, true)
	pcall(function()
		(prompt :: any).ClickablePrompt = true
	end)
	if prompt.KeyboardKeyCode == Enum.KeyCode.Unknown then
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	end
	if prompt.GamepadKeyCode == Enum.KeyCode.Unknown then
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	end
	wireStylePrompt(prompt)

	local view = viewsByPrompt[prompt]
	if view then
		wirePromptLiveUpdates(prompt, view)
	end
end

function ProximityPromptEffects.stylePrompt(prompt: ProximityPrompt)
	if CarryGate.isBushSearchPrompt(prompt) then
		if prompt:GetAttribute(BUSH_MANAGED_ATTR) ~= true then
			-- BushHoldInteraction replaces legacy Search prompts; don't destroy during map load race.
			prompt.Enabled = false
			return
		end
		wireStylePrompt(prompt)
		return
	end

	applyCustomPromptStyle(prompt)
end

local function scanForPrompts(root: Instance)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("ProximityPrompt") then
			ProximityPromptEffects.stylePrompt(desc)
		end
	end
end

local function wireProximityPromptService()
	if serviceWired then
		return
	end
	serviceWired = true

	ProximityPromptService.PromptShown:Connect(onPromptShown)
	ProximityPromptService.PromptHidden:Connect(onPromptHidden)
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	ProximityPromptService.PromptButtonHoldBegan:Connect(onHoldBegan)
	ProximityPromptService.PromptButtonHoldEnded:Connect(onHoldEnded)
end

local function hookCharacterToolListeners(char: Model)
	char.ChildRemoved:Connect(function(ch)
		if ch:IsA("Tool") and ch:GetAttribute("BrainrotTool") == true then
			hidePlacePromptViewsIfNeeded()
		end
	end)
end

local function refreshCarryHiddenPrompts()
	if not CarryGate.isFull() then
		return
	end
	activeBushSearchPrompt = nil
	stopBushCameraShake()
	stopBushWobble()
	hideBushSharedUi(true)
	clearBushPerPromptViews()
end

local function hookCarryListeners()
	local function onCarryChanged()
		refreshCarryHiddenPrompts()
		hidePlacePromptViewsIfNeeded()
		if canShowPlaceBrainrotUi() and reshowEligiblePlaceProximityPrompts then
			task.defer(reshowEligiblePlaceProximityPrompts :: () -> ())
		end
	end

	local carryBumpPending = false
	local function scheduleCarryBump()
		if carryBumpPending then
			return
		end
		carryBumpPending = true
		task.defer(function()
			carryBumpPending = false
			onCarryChanged()
		end)
	end

	local function wireCharCarryBumps(char: Model)
		char.ChildAdded:Connect(function(ch)
			if ch:IsA("Tool") or ch:IsA("Model") then
				scheduleCarryBump()
			end
		end)
		char.ChildRemoved:Connect(function(ch)
			if ch:IsA("Tool") or ch:IsA("Model") then
				scheduleCarryBump()
			end
		end)
	end

	player:GetAttributeChangedSignal("Carry"):Connect(scheduleCarryBump)
	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(scheduleCarryBump)

	player.CharacterAdded:Connect(function(char: Model)
		wireCharCarryBumps(char)
		scheduleCarryBump()
	end)
	if player.Character then
		wireCharCarryBumps(player.Character)
	end

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		backpack.ChildAdded:Connect(scheduleCarryBump)
		backpack.ChildRemoved:Connect(scheduleCarryBump)
	end

	scheduleCarryBump()
end

function ProximityPromptEffects.init()
	wireProximityPromptService()
	task.defer(function()
		local map = Workspace:FindFirstChild("Map")
		if map then
			scanForPrompts(map)
		else
			scanForPrompts(Workspace)
		end
	end)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in { "BushSearchSharedPrompt", "BushSearchUI", "BushSearchPrompt", "BushCooldownBanner" } do
			local legacy = pg:FindFirstChild(name)
			if legacy then
				legacy:Destroy()
			end
		end
	end

	local promptRoot = Workspace:FindFirstChild("Map") or Workspace
	promptRoot.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") then
			ProximityPromptEffects.stylePrompt(desc)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(refreshAllKeyLabels)

	hookCarryListeners()
	player.CharacterAdded:Connect(function(char: Model)
		stopBushCameraShake()
		stopBushWobble()
		ProximityPromptEffects.hideBushSearch()
		ProximityPromptEffects.hideBushCooldownBanner()
		hookCharacterToolListeners(char)
	end)
	if player.Character then
		hookCharacterToolListeners(player.Character)
	end
end

return ProximityPromptEffects
