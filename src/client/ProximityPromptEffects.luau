-- [ACTIVE] ProximityPromptEffects
--[[
	ProximityPromptEffects — custom proximity prompt billboard UI (client)
	Managed bush search: engine ProximityPrompt handles hold/trigger; optional displayOnly billboard is visual-only.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local _TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local CarryGate = require(script.Parent.CarryGate)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local GamepadInput = require(script.Parent.GamepadInput)
local MobileHaptics = require(script.Parent.MobileHaptics)
local OtherVfxController = require(script.Parent.OtherVfxController)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local C = require(script.Parent.ProximityPromptEffectsConfig)
local PromptTheme = require(script.Parent.ProximityPromptTheme)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────

type PromptView = {
	prompt: ProximityPrompt,
	billboard: BillboardGui,
	root: Frame,
	rootScale: UIScale,
	rootStroke: UIStroke,
	strokeGrads: { UIGradient },
	strokeGradConn: RBXScriptConnection?,
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
	pressAnimToken: number,
	holdRenderConn: RBXScriptConnection?,
	liveConns: { RBXScriptConnection },
	clickConns: { RBXScriptConnection },
	clickWired: boolean,
	hoverWired: boolean,
	displayOnly: boolean,
	inputType: Enum.ProximityPromptInputType?,
}

local viewsByPrompt: { [ProximityPrompt]: PromptView } = {}
local styledPrompts: { [ProximityPrompt]: boolean } = {}
local promptStyleConns: { [ProximityPrompt]: { RBXScriptConnection } } = {}
-- Prevents concurrent showView (PromptShown + sync + repair) from stacking billboards.
local promptBuildLocks: { [ProximityPrompt]: boolean } = {}
local serviceWired = false
local effectsBooted = false
local activeBushSearchPrompt: ProximityPrompt? = nil
local bushSharedView = nil
local bushWobbleBases: { [Instance]: CFrame } = {}
local bushWobbleStepBound = false
local cameraShakeActive = false
local bushCameraShakeStepBound = false
local bushHoldLockUntil = 0
local bushHoldCompleteHandler: ((ProximityPrompt) -> ())? = nil
local bushHoldBeganHandler: ((ProximityPrompt) -> boolean?)? = nil
local bushHoldCompleteHooks: { (ProximityPrompt, () -> ()) -> boolean } = {}
local managedBushHoldActive: ProximityPrompt? = nil
local directBushHoldPrompt: ProximityPrompt? = nil

-- Post-harvest cooldown banner (clock + seconds) on the bush adornee
type BushCooldownBannerEntry = {
	bb: BillboardGui,
	label: TextLabel,
	endClock: number,
	prompt: ProximityPrompt,
}
local bushCooldownBanners: { [Instance]: BushCooldownBannerEntry } = {}
local suppressedBushCooldownBanners: { [Instance]: boolean } = {}
local suppressedBushCooldownPrompts: { [Instance]: ProximityPrompt } = {}
local bushCooldownTickerConn: RBXScriptConnection? = nil
local rarityGradientsFolder: Folder? = nil

local activeStandPrompt: ProximityPrompt? = nil

local ProximityPromptEffects = {}

function ProximityPromptEffects.setBushHoldCompleteHandler(handler: ((ProximityPrompt) -> ())?)
	bushHoldCompleteHandler = handler
end

function ProximityPromptEffects.setBushHoldBeganHandler(handler: ((ProximityPrompt) -> boolean?)?)
	bushHoldBeganHandler = handler
end

function ProximityPromptEffects.registerBushHoldCompleteHook(hook: (ProximityPrompt, () -> ()) -> boolean)
	table.insert(bushHoldCompleteHooks, hook)
end

local startIdleSway: (view: PromptView) -> ()
local stopIdleSway: (view: PromptView) -> ()
local playPressAnim: (view: PromptView) -> ()
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
local isPromptFacingCamera: (ProximityPrompt) -> boolean
local isStandProximityPrompt: (ProximityPrompt) -> boolean
local purgeOrphanPromptBillboards: () -> ()

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

-- Empty-stand "Place" custom card: brainrot Tool equipped or placeable bush haul (not lucky blocks).
local function canShowPlaceBrainrotUi(): boolean
	return playerHasBrainrotToolEquipped() or CarryGate.isCarryingPlaceableBrainrot()
end

local function isPlaceBrainrotPrompt(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute(C.PLACE_PROMPT_ATTR) == true or prompt.ActionText == "Place Brainrot"
end

local function isManagedBushPrompt(prompt: ProximityPrompt): boolean
	return CarryGate.isBushSearchPrompt(prompt) and prompt:GetAttribute(C.BUSH_MANAGED_ATTR) == true
end

local function applyBushSearchCardStyle(view: PromptView)
	PromptTheme.applyBushSearchStyle(view)
end

local function bushBillboardMaxDistance(prompt: ProximityPrompt): number
	return math.max(prompt.MaxActivationDistance * 1.5, C.BUSH_BILLBOARD_MIN_MAX_DISTANCE)
end

-- Must be above promptBillboardMaxDistance / refreshKeyLabel (Luau local scope).
local function isStealProximityPrompt(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute(C.STEAL_PROMPT_ATTR) == true
end

local function promptBillboardMaxDistance(prompt: ProximityPrompt): number
	-- Steal used to cap at MaxActivation+1, which hid the card while still in range.
	return bushBillboardMaxDistance(prompt)
end

local getPromptFocusWorld: (ProximityPrompt) -> Vector3?

local function getCharacterRootPart(): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isBushSearchInCameraRange(prompt: ProximityPrompt): boolean
	local cam = workspace.CurrentCamera
	if not cam then
		return true
	end
	local focus = getPromptFocusWorld(prompt)
	if not focus then
		return false
	end
	return (focus - cam.CFrame.Position).Magnitude <= bushBillboardMaxDistance(prompt)
end

local function isBushSearchInPlayerRange(prompt: ProximityPrompt): boolean
	local root = getCharacterRootPart()
	local focus = getPromptFocusWorld(prompt)
	if not root or not focus then
		return false
	end
	return (root.Position - focus).Magnitude <= prompt.MaxActivationDistance + 1.25
end

function ProximityPromptEffects.isBushSearchInViewRange(prompt: ProximityPrompt): boolean
	return isBushSearchInPlayerRange(prompt) or isBushSearchInCameraRange(prompt)
end

function ProximityPromptEffects.isBushSearchNearPlayer(prompt: ProximityPrompt): boolean
	return isBushSearchInPlayerRange(prompt)
end

local function managedBushUiEligible(prompt: ProximityPrompt): boolean
	return isManagedBushPrompt(prompt)
		and prompt.Enabled
		and not CarryGate.isFull()
		and isBushSearchInPlayerRange(prompt)
end

local function shouldShowPromptUi(prompt: ProximityPrompt): boolean
	if not prompt.Enabled then
		return false
	end
	if managedBushUiEligible(prompt) then
		return true
	end
	if not isPromptFacingCamera(prompt) then
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
	return GamepadInput.isPreferred()
end

local function gamepadButtonLabel(keyCode: Enum.KeyCode): string
	return GamepadInput.faceLabel(keyCode)
end

local function showGamepadKeyIcon(view: PromptView, keyCode: Enum.KeyCode)
	local label = view.keyLabel
	local icon = view.keyIcon
	local img = GamepadInput.faceImage(keyCode)
	if img == "" then
		icon.Visible = false
		label.Visible = true
		label.Text = gamepadButtonLabel(keyCode)
		return
	end
	label.Text = ""
	label.Visible = false
	icon.Visible = true
	icon.ImageTransparency = 0
	icon.ImageColor3 = Color3.new(1, 1, 1)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromOffset(28, 28)
	icon.ZIndex = 10
	icon.Image = img
end

local function isMobilePlatform(): boolean
	-- Many phones/tablets report KeyboardEnabled=true; don't require keyboard off.
	if UserInputService.TouchEnabled then
		if prefersGamepadInput() then
			return false
		end
		if not UserInputService.KeyboardEnabled then
			return true
		end
		local ok, preferred = pcall(function()
			return (UserInputService :: any).PreferredInput
		end)
		if ok and preferred == Enum.PreferredInput.Touch then
			return true
		end
		if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
			return true
		end
		-- Touch screen present and not actively using gamepad — treat as mobile for prompt UI.
		return true
	end
	return false
end

local function isTouchDevice(): boolean
	return UserInputService.TouchEnabled
end

local function resolvePromptInputType(explicit: Enum.ProximityPromptInputType?): Enum.ProximityPromptInputType
	-- Prefer touch whenever the device has a touch screen (bush/stand share the same badge).
	if UserInputService.TouchEnabled and not prefersGamepadInput() then
		if isMobilePlatform() or UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
			return Enum.ProximityPromptInputType.Touch
		end
		local ok, preferred = pcall(function()
			return (UserInputService :: any).PreferredInput
		end)
		if ok and preferred == Enum.PreferredInput.Touch then
			return Enum.ProximityPromptInputType.Touch
		end
	end
	if isMobilePlatform() then
		return Enum.ProximityPromptInputType.Touch
	end
	if explicit ~= nil then
		return explicit
	end
	if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		return Enum.ProximityPromptInputType.Touch
	end
	if prefersGamepadInput() then
		return Enum.ProximityPromptInputType.Gamepad
	end
	return Enum.ProximityPromptInputType.Keyboard
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

local function effectiveMinCardWidth(): number
	if isMobilePlatform() then
		return C.MOBILE_MIN_CARD_W
	end
	return C.MIN_CARD_W
end

-- Phones/tablets should show Roblox touch icons even before the first touch event.
local function usesTouchPromptIcon(): boolean
	if not UserInputService.TouchEnabled then
		return false
	end
	if prefersGamepadInput() then
		return false
	end
	if isMobilePlatform() then
		return true
	end
	if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		return true
	end
	return prefersTouchInput()
end

local function isBushSearchPrompt(prompt: ProximityPrompt): boolean
	return CarryGate.isBushSearchPrompt(prompt)
end

-- Bush shared cards skip PromptShown, so they often have nil inputType.
-- Always use the stand touch badge on any touch-capable device (ignore KeyboardEnabled).
local function shouldShowBushTouchIcon(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): boolean
	if prefersGamepadInput() then
		return false
	end
	if not isBushSearchPrompt(prompt) then
		return false
	end
	if UserInputService.TouchEnabled then
		return true
	end
	if inputType == Enum.ProximityPromptInputType.Touch then
		return true
	end
	return usesTouchPromptIcon()
end

local function showTouchKeyIcon(view: PromptView, _hold: boolean)
	local label = view.keyLabel
	local icon = view.keyIcon
	label.Text = ""
	label.Visible = false
	icon.Visible = true
	icon.ImageTransparency = 0
	-- Same finger image as stand prompts. TouchHoldIcon is blank/missing on many
	-- clients; hold is already communicated by the green hold-fill ring.
	icon.ImageColor3 = Color3.new(1, 1, 1)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	local touchSize = if isTouchDevice() then 34 else 28
	icon.Size = UDim2.fromOffset(touchSize, touchSize + 6)
	icon.ZIndex = 10
	icon.Image = C.TOUCH_TAP_ICON
end

local function refreshKeyLabel(view: PromptView)
	local prompt = view.prompt
	local label = view.keyLabel
	local icon = view.keyIcon
	local inputType = resolvePromptInputType(view.inputType)

	local function showText(text: string)
		icon.Visible = false
		label.Visible = true
		label.Text = text
	end

	if inputType == Enum.ProximityPromptInputType.Gamepad then
		showGamepadKeyIcon(view, prompt.GamepadKeyCode)
		return
	end
	-- Touch devices: always finger badge (same asset as stand). Never keyboard "E".
	if UserInputService.TouchEnabled and not prefersGamepadInput() then
		showTouchKeyIcon(view, prompt.HoldDuration > 0)
		return
	end
	if
		inputType == Enum.ProximityPromptInputType.Touch
		or usesTouchPromptIcon()
		or (isBushSearchPrompt(prompt) and shouldShowBushTouchIcon(prompt, inputType))
		or (isStealProximityPrompt(prompt) and usesTouchPromptIcon())
	then
		showTouchKeyIcon(view, prompt.HoldDuration > 0)
		return
	end
	local kc = prompt.KeyboardKeyCode
	if kc == Enum.KeyCode.Unknown then
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

local function promptBillboardInputActive(): boolean
	return true
end

local function wirePromptHover(view: PromptView)
	if view.hoverWired then
		return
	end
	view.hoverWired = true

	local root = view.root
	local clickBtn = root:FindFirstChild("ClickTarget")
	if not clickBtn or not clickBtn:IsA("GuiObject") then
		return
	end

	local rootScale = view.rootScale
	local badgeScale = getOrAddUIScale(view.keyBadge)
	local hoverIn = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local hoverOut = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local isStand = isStandProximityPrompt(view.prompt)

	table.insert(view.clickConns, clickBtn.MouseEnter:Connect(function()
		if view.holding or not viewIsActive(view) then
			return
		end
		stopIdleSway(view)
		TweenService:Create(rootScale, hoverIn, { Scale = if isStand then 1.06 else 1.05 }):Play()
		TweenService:Create(badgeScale, hoverIn, { Scale = 1.08 }):Play()
		TweenService:Create(view.rootStroke, hoverIn, { Thickness = 2.2, Transparency = 0.06 }):Play()
		view.root.Rotation = if isStand then -2.5 else -2
		view.keyBadge.Rotation = if isStand then -3.5 else -3
	end))

	table.insert(view.clickConns, clickBtn.MouseLeave:Connect(function()
		if view.holding or not viewIsActive(view) then
			return
		end
		TweenService:Create(rootScale, hoverOut, { Scale = 1 }):Play()
		TweenService:Create(badgeScale, hoverOut, { Scale = 1 }):Play()
		TweenService:Create(view.rootStroke, hoverOut, {
			Thickness = 1.5,
			Transparency = C.PANEL_STROKE_TRANSPARENCY,
		}):Play()
		view.root.Rotation = 0
		view.keyBadge.Rotation = 0
		if not (view.displayOnly and isManagedBushPrompt(view.prompt)) then
			startIdleSway(view)
		end
	end))
end

local function wireClickablePrompt(view: PromptView)
	if view.clickWired then
		return
	end
	view.clickWired = true

	local root = view.root
	root.Active = true
	view.billboard.Active = promptBillboardInputActive()

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
	clickBtn.Active = true
	clickBtn.Selectable = true
	clickBtn.ZIndex = 20
	clickBtn.Parent = root

	local touchMinPx = if prefersTouchInput() then C.MIN_TOUCH_PX_MOBILE else C.MIN_TOUCH_PX
	local touchMin = Instance.new("UISizeConstraint")
	touchMin.MinSize = Vector2.new(touchMinPx, touchMinPx)
	touchMin.Parent = clickBtn

	if view.prompt.HoldDuration > 0 then
		local function beginPointerHold()
			local prompt = view.prompt
			if not shouldShowPromptUi(prompt) or view.holding then
				return
			end
			if not MobileTouchGate.canTapUi() then
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
			-- Cancel programmatic hold started by beginHoldVisual / InputHoldBegin.
			pcall(function()
				view.prompt:InputHoldEnd()
			end)
			endHoldVisual(view, false)
		end
		local function beginKeyboardHold()
			local prompt = view.prompt
			if not shouldShowPromptUi(prompt) or view.holding then
				return
			end
			view.holdViaPointer = false
			-- InputHoldBegin so hold completes even when engine HoldBegan is skipped.
			beginHoldVisual(view)
		end
		local function endKeyboardHold()
			if not view.holding or view.holdViaPointer then
				return
			end
			pcall(function()
				view.prompt:InputHoldEnd()
			end)
			endHoldVisual(view, false)
		end
		local function matchesKeyboardHold(input: InputObject): boolean
			local prompt = view.prompt
			local kc = prompt.KeyboardKeyCode
			if kc == Enum.KeyCode.Unknown then
				return input.KeyCode == Enum.KeyCode.E
			end
			return input.KeyCode == kc
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
			if not MobileTouchGate.canTapUi() then
				return
			end
			local now = os.clock()
			if now - lastTapAt < 0.12 then
				return
			end
			lastTapAt = now
			UIInteractionSounds.playClick()
			playPressAnim(view)
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

local function _isUnderBushScripts(inst: Instance?): boolean
	local node: Instance? = inst
	while node do
		if node.Name == "BushSCRIPTs" or node.Name == "BushSCRIPT" then
			return true
		end
		node = node.Parent
	end
	return false
end

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))

local function findBushRootForPrompt(prompt: ProximityPrompt): Instance?
	return BushRootUtil.resolveBushRootFromPrompt(prompt)
end

local function findBushModelForPrompt(prompt: ProximityPrompt): Model?
	local root = findBushRootForPrompt(prompt)
	if root and root:IsA("Model") then
		return root
	end
	return nil
end

local function _bushFocusWorldPosition(bush: Instance): Vector3?
	return BushRootUtil.focusWorldPosition(bush, C.BUSH_BILLBOARD_LIFT_SCALE)
end

local function _refreshBushPromptAttachment(_prompt: ProximityPrompt)
	-- IMPORTANT: never move the real ProximityPrompt Attachment.
	-- Moving the prompt Attachment also moves the real activation point, which is what
	-- caused the bush prompt card to climb upward / disappear every refresh.
end

local function getBushBillboardAdornee(prompt: ProximityPrompt): Instance?
	-- Bush UI must be anchored to a stable BasePart, not the prompt Attachment.
	-- The Attachment can be used by Roblox's ProximityPrompt engine, but the custom
	-- billboard should not ride on it.
	return getPromptAdornee(prompt)
end

local function _bushBillboardStudsOffset(_prompt: ProximityPrompt?, _bushModel: Model?, _adornee: BasePart): Vector3
	-- HARD STABILITY FIX: do not calculate this from bush bounding boxes.
	-- Some bush models wobble/pivot while searching, and recomputing focus height
	-- makes the UI step upward repeatedly. Use one fixed local offset instead.
	return C.BUSH_UI_STATIC_OFFSET
end

local function applyBushBillboardPlacement(billboard: BillboardGui, _prompt: ProximityPrompt?, adornee: Instance)
	billboard.StudsOffsetWorldSpace = Vector3.zero
	if adornee:IsA("BasePart") then
		billboard.StudsOffset = C.BUSH_UI_STATIC_OFFSET
		return
	end
	billboard.StudsOffset = Vector3.zero
end

local function floatingClaimBillboardOffset(adornee: BasePart): Vector3
	local model = adornee:FindFirstAncestorWhichIsA("Model")
	if not model then
		return Vector3.zero
	end
	local pivot = model:GetPivot().Position
	return adornee.CFrame:PointToObjectSpace(pivot)
end

local function applyFloatingClaimBillboardPlacement(billboard: BillboardGui, _prompt: ProximityPrompt?, adornee: BasePart)
	billboard.StudsOffsetWorldSpace = Vector3.zero
	billboard.StudsOffset = floatingClaimBillboardOffset(adornee)
end

local function isBushPrompt(prompt: ProximityPrompt): boolean
	return CarryGate.isBushSearchPrompt(prompt) or findBushRootForPrompt(prompt) ~= nil
end

getPromptFocusWorld = function(prompt: ProximityPrompt): Vector3?
	-- Use the stable prompt BasePart for range/camera checks.
	-- Do not use the bush focus/bounding-box position here, because that position
	-- changes during bush wobble and can make the UI hide/reappear incorrectly.
	local adornee = getPromptAdornee(prompt)
	if adornee then
		return adornee.Position
	end
	local parent = prompt.Parent
	if parent and parent:IsA("Attachment") then
		return (parent :: Attachment).WorldPosition
	end
	return nil
end

ProximityPromptEffects.getPromptFocusWorld = getPromptFocusWorld

isPromptFacingCamera = function(prompt: ProximityPrompt): boolean
	if not isMobilePlatform() then
		return true
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return true
	end
	local focus = getPromptFocusWorld(prompt)
	if not focus then
		return false
	end
	local toTarget = focus - cam.CFrame.Position
	if toTarget.Magnitude < 0.08 then
		return true
	end
	return cam.CFrame.LookVector:Dot(toTarget.Unit) >= C.MIN_MOBILE_FACE_DOT
end

function ProximityPromptEffects.isPromptFacingCamera(prompt: ProximityPrompt): boolean
	return isPromptFacingCamera(prompt)
end

function ProximityPromptEffects.isPromptHolding(prompt: ProximityPrompt): boolean
	local view = viewsByPrompt[prompt]
	return view ~= nil and view.holding == true
end

function ProximityPromptEffects.isBushSearchUiInRange(prompt: ProximityPrompt): boolean
	if not prompt.Parent or CarryGate.isFull() then
		return false
	end
	return isBushSearchInPlayerRange(prompt) or isBushSearchInCameraRange(prompt)
end

local function findStandForPrompt(prompt: ProximityPrompt): Model?
	if prompt:GetAttribute("BrainrotFloatingClaim") == true then
		return nil
	end
	local node: Instance? = prompt.Parent
	while node do
		if node:IsA("Model") then
			local m = node :: Model
			if CollectionService:HasTag(m, C.STAND_TAG) then
				return m
			end
		end
		node = node.Parent
	end
	return nil
end

local function isManagedStandProximityPrompt(prompt: ProximityPrompt): boolean
	return findStandForPrompt(prompt) ~= nil and not isStealProximityPrompt(prompt)
end

isStandProximityPrompt = function(prompt: ProximityPrompt): boolean
	return findStandForPrompt(prompt) ~= nil
end

local function cacheRarityGradientsFolder()
	if rarityGradientsFolder and rarityGradientsFolder.Parent then
		return rarityGradientsFolder
	end
	local pg = player:FindFirstChild("PlayerGui")
	local main = pg and pg:FindFirstChild("Main")
	local gameGradients = main and main:FindFirstChild("GameGradients")
	local rarities = gameGradients and gameGradients:FindFirstChild("Rarity")
	if rarities and rarities:IsA("Folder") then
		rarityGradientsFolder = rarities
	end
	return rarityGradientsFolder
end

local function rarityGradientUiName(rarityId: string?): string?
	if typeof(rarityId) ~= "string" or rarityId == "" then
		return nil
	end
	local key = RebirthConfig.normalizeRarity(rarityId)
	return C.RARITY_GRADIENT_UI_NAMES[key]
end

local function hasStandStrokeGradient(view: PromptView): boolean
	return #view.strokeGrads > 0
end

local function stopStandStrokeGradientCycle(view: PromptView)
	if view.strokeGradConn then
		view.strokeGradConn:Disconnect()
		view.strokeGradConn = nil
	end
end

local function clearStandStrokeGradient(view: PromptView)
	stopStandStrokeGradientCycle(view)
	for _, grad in view.strokeGrads do
		if grad.Parent then
			grad:Destroy()
		end
	end
	table.clear(view.strokeGrads)
	-- Also purge any leftover gradients that weren't tracked (prevents stacking / darkening).
	if view.rootStroke then
		for _, ch in view.rootStroke:GetChildren() do
			if ch:IsA("UIGradient") then
				ch:Destroy()
			end
		end
	end
	if view.keyStroke then
		for _, ch in view.keyStroke:GetChildren() do
			if ch:IsA("UIGradient") then
				ch:Destroy()
			end
		end
	end
	view.rootStroke.Color = C.PANEL_STROKE
	view.rootStroke.Transparency = C.PANEL_STROKE_TRANSPARENCY
	view.keyStroke.Color = C.KEY_CHIP_STROKE
	view.keyStroke.Transparency = C.KEY_CHIP_STROKE_TRANSPARENCY
end

local function attachStrokeGradient(stroke: UIStroke, template: UIGradient, view: PromptView)
	-- One gradient per stroke — wipe leftovers first.
	for _, ch in stroke:GetChildren() do
		if ch:IsA("UIGradient") then
			ch:Destroy()
		end
	end
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.12
	local clone = template:Clone()
	clone.Enabled = true
	clone.Parent = stroke
	table.insert(view.strokeGrads, clone)
end

local function startStandStrokeGradientCycle(view: PromptView)
	stopStandStrokeGradientCycle(view)
	if isMobilePlatform() or #view.strokeGrads == 0 then
		return
	end
	view.strokeGradConn = RunService.Heartbeat:Connect(function(dt)
		for _, grad in view.strokeGrads do
			if grad.Parent then
				grad.Rotation = (grad.Rotation + dt * C.STAND_STROKE_GRAD_ROT_SPEED) % 360
			end
		end
	end)
end

local function applyStandStrokeGradient(view: PromptView, stand: Model)
	if not isStandProximityPrompt(view.prompt) then
		return
	end

	clearStandStrokeGradient(view)

	local occupied = typeof(stand:GetAttribute(C.STAND_NAME_ATTR)) == "string"
		and stand:GetAttribute(C.STAND_NAME_ATTR) ~= ""
	if not occupied then
		return
	end

	local gradUiName = rarityGradientUiName(stand:GetAttribute(C.STAND_RARITY_ATTR) :: string?)
	if not gradUiName then
		gradUiName = "Common"
	end

	local folder = cacheRarityGradientsFolder()
	local template = folder and folder:FindFirstChild(gradUiName)
	if template and template:IsA("UIGradient") then
		attachStrokeGradient(view.rootStroke, template, view)
		attachStrokeGradient(view.keyStroke, template, view)
		startStandStrokeGradientCycle(view)
		return
	end

	local rarityRaw = stand:GetAttribute(C.STAND_RARITY_ATTR)
	local rarityKey = if typeof(rarityRaw) == "string" then RebirthConfig.normalizeRarity(rarityRaw) else "common"
	local accent = BrainrotHeaderStyle.rarityAccentColor(rarityKey)
	view.rootStroke.Color = accent
	view.rootStroke.Transparency = 0.08
	view.keyStroke.Color = accent:Lerp(Color3.new(1, 1, 1), 0.18)
	view.keyStroke.Transparency = 0.12
end

local function resolvePromptLabels(prompt: ProximityPrompt): (string, string)
	if prompt:GetAttribute("BrainrotFloatingClaim") == true then
		return prompt.ActionText, prompt.ObjectText
	end
	if isStealProximityPrompt(prompt) then
		return prompt.ActionText, prompt.ObjectText
	end

	local actionText = prompt.ActionText
	if actionText == "" then
		actionText = if isPlaceBrainrotPrompt(prompt) then "Place Brainrot" else "Pick Up"
	end

	local objectText = prompt.ObjectText
	local stand = findStandForPrompt(prompt)
	if stand and not isPlaceBrainrotPrompt(prompt) then
		local name = stand:GetAttribute(C.STAND_NAME_ATTR)
		if typeof(name) == "string" and name ~= "" then
			local level = stand:GetAttribute(C.STAND_LEVEL_ATTR)
			local lvl = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1
			objectText = string.format("Lvl %d %s", lvl, name)
		end
	end
	if objectText == "" then
		objectText = if isPlaceBrainrotPrompt(prompt) then "Stand" else ""
	end

	return actionText, objectText
end

local function measureCardWidth(actionText: string, objectText: string, _holdDuration: number): number
	local measureBounds = Vector2.new(512, 48)
	local actionSize = _TextService:GetTextSize(actionText, C.ACTION_TEXT_SIZE, UiFonts.DISPLAY_LEGACY, measureBounds)
	local objectSize = _TextService:GetTextSize(objectText, C.OBJECT_TEXT_SIZE, UiFonts.DISPLAY_LEGACY, measureBounds)
	local textW = math.max(actionSize.X, objectSize.X)
	local total = C.PAD_LEFT + C.BADGE_SIZE + C.BADGE_TEXT_GAP + math.ceil(textW) + C.PAD_RIGHT
	return math.clamp(total, effectiveMinCardWidth(), C.MAX_CARD_W)
end

local function applyLabelsToView(view: PromptView)
	local actionText, objectText = resolvePromptLabels(view.prompt)
	if actionText == "" then
		actionText = view.prompt.ActionText
	end
	if actionText == "" then
		actionText = if view.prompt.HoldDuration > 0 then "Hold" else "Interact"
	end
	if objectText == "" then
		objectText = view.prompt.ObjectText
	end
	view.actionLabel.Text = actionText
	view.objectLabel.Text = objectText
	view.billboard.Size = UDim2.fromOffset(measureCardWidth(actionText, objectText, view.prompt.HoldDuration), C.CARD_H)
	refreshKeyLabel(view)
	-- Keep panel opacity stable (stacked billboards / re-applies were darkening it).
	view.root.BackgroundTransparency = C.BG_TRANSPARENCY
	view.root.BackgroundColor3 = C.BG_COLOR
	local stand = findStandForPrompt(view.prompt)
	if stand then
		applyStandStrokeGradient(view, stand)
	end
end

stopIdleSway = function(view: PromptView)
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

local function _holdTrackHeight(_view: PromptView): number
	return math.max(8, C.BADGE_SIZE - C.BADGE_HOLD_PAD * 2)
end

local function ensureKeyIcon(view: PromptView)
	local badge = view.keyBadge
	if not badge or not badge.Parent then
		return
	end
	local icon = badge:FindFirstChild("KeyIcon")
	if icon and icon:IsA("ImageLabel") then
		view.keyIcon = icon :: ImageLabel
		return
	end
	icon = Instance.new("ImageLabel")
	icon.Name = "KeyIcon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.new(1, -10, 1, -10)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ImageColor3 = if isBushSearchPrompt(view.prompt) then C.TEXT_PRIMARY else C.KEY_TEXT
	icon.ImageTransparency = 0
	icon.Visible = false
	icon.ZIndex = 10
	icon.Parent = badge
	view.keyIcon = icon :: ImageLabel
end

local function resetKeyBadgeVisuals(view: PromptView)
	PromptTheme.resetBadgeVisuals(view, isManagedBushPrompt(view.prompt), hasStandStrokeGradient(view))
	ensureKeyIcon(view)
	view.holdTrack.Size = UDim2.new(1, -C.BADGE_HOLD_PAD * 2, 1, -C.BADGE_HOLD_PAD * 2)
	view.holdFill.Size = UDim2.new(1, 0, 0, 0)
	view.holdFill.BackgroundTransparency = 0.08
	setHoldTrackVisible(view, view.prompt.HoldDuration > 0)
	refreshKeyLabel(view)
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
			RunService:UnbindFromRenderStep(C.BUSH_WOBBLE_STEP)
		end)
		bushWobbleStepBound = false
	end
end

local function stopBushCameraShake()
	if bushCameraShakeStepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(C.BUSH_CAM_SHAKE_STEP)
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
	stopBushCameraShake()
	cameraShakeActive = true
	bushCameraShakeStepBound = true
	RunService:BindToRenderStep(C.BUSH_CAM_SHAKE_STEP, Enum.RenderPriority.Camera.Value + 50, function()
		if not cameraShakeActive then
			stopBushCameraShake()
			return
		end
		local hum = getLocalHumanoid()
		if not hum then
			return
		end
		local t = os.clock() * C.BUSH_CAM_SHAKE_SPEED
		hum.CameraOffset = Vector3.new(
			(math.noise(t, 0, 0) - 0.5) * 2 * C.BUSH_CAM_SHAKE_POS,
			(math.noise(0, t, 1) - 0.5) * 2 * C.BUSH_CAM_SHAKE_POS,
			(math.noise(t, 2, 0.5) - 0.5) * 2 * C.BUSH_CAM_SHAKE_POS * 0.35
		)
	end)
end

local function applyBushWobble(t: number, seed: number)
	if next(bushWobbleBases) == nil then
		return
	end
	local nx = math.noise(t * 9, seed, 0) * C.BUSH_WOBBLE_POS
	local ny = math.noise(seed + 1, t * 9, 0.5) * C.BUSH_WOBBLE_POS * 0.6
	local nz = math.noise(t * 9, seed + 2, 1) * C.BUSH_WOBBLE_POS
	local rx = math.noise(t * 7, seed + 3, 2) * C.BUSH_WOBBLE_ROT
	local ry = math.noise(seed + 4, t * 7, 3) * C.BUSH_WOBBLE_ROT * 1.2
	local rz = math.noise(t * 7, seed + 5, 4) * C.BUSH_WOBBLE_ROT * 0.7
	local offset = CFrame.new(nx, ny, nz) * CFrame.Angles(rx, ry, rz)
	for target, base in bushWobbleBases do
		if not target.Parent then
			continue
		end
		pcall(function()
			if target:IsA("Model") then
				target:PivotTo(base * offset)
			elseif target:IsA("BasePart") then
				target.CFrame = base * offset
			end
		end)
	end
end

local function restoreBushWobbleTransforms()
	for target, base in bushWobbleBases do
		if not target.Parent then
			continue
		end
		pcall(function()
			if target:IsA("Model") then
				target:PivotTo(base)
			elseif target:IsA("BasePart") then
				target.CFrame = base
			end
		end)
	end
	table.clear(bushWobbleBases)
end

local function captureBushWobbleBases(root: Instance): boolean
	table.clear(bushWobbleBases)
	for _, target in BushRootUtil.getShakeTargets(root) do
		if target:IsA("Model") then
			bushWobbleBases[target] = target:GetPivot()
		elseif target:IsA("BasePart") then
			bushWobbleBases[target] = target.CFrame
		end
	end
	return next(bushWobbleBases) ~= nil
end

local function stopBushWobble()
	stopBushWobbleRenderStep()
	OtherVfxController.stopBushSearchShake()
	restoreBushWobbleTransforms()
end

local function beginBushWobble(prompt: ProximityPrompt)
	local bush = findBushRootForPrompt(prompt)
	if not bush or not bush.Parent then
		stopBushWobble()
		return
	end
	stopBushWobble()

	local captured = captureBushWobbleBases(bush)
	if not captured then
		-- Some bush layouts have no Model/Part shake targets — still try a leaf part.
		local part = if bush:IsA("BasePart") then bush else bush:FindFirstChildWhichIsA("BasePart", true)
		if part and part:IsA("BasePart") then
			bushWobbleBases[part] = part.CFrame
			captured = true
		end
	end

	-- Always play leaf-shake VFX even if transform wobble has nothing to move.
	OtherVfxController.playBushSearchShake(bush)

	if not captured then
		return
	end

	local bushWobbleSeed = math.random() * 10
	bushWobbleStepBound = true

	RunService:BindToRenderStep(C.BUSH_WOBBLE_STEP, Enum.RenderPriority.Last.Value, function()
		if next(bushWobbleBases) == nil then
			stopBushWobbleRenderStep()
			return
		end
		local anyAlive = false
		for target in bushWobbleBases do
			if target.Parent then
				anyAlive = true
				break
			end
		end
		if not anyAlive then
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
	local done = if completed == nil then view.holdProgress >= C.HOLD_COMPLETE_THRESHOLD else completed
	resetHoldState(view, done)
end

applyHoldBadgeActive = function(view: PromptView)
	PromptTheme.applyHoldBadgeActive(view, isManagedBushPrompt(view.prompt))
end

-- Bush-style noisy wiggle on a GuiObject rotation
local function wiggleRotation(target: GuiObject, seed: number, t: number): number
	return math.deg(
		math.noise(t * C.WIGGLE_SPEED, seed, 0.5) * C.WIGGLE_ROT
			+ math.noise(t * C.WIGGLE_SPEED * 0.7, seed + 2, 1.2) * C.WIGGLE_ROT * 0.55
	)
end

-- ── Animations ────────────────────────────────────────────────────────────────

local function flashKeyYellow(view: PromptView, holdGreenAfter: boolean?, skipBadgeScale: boolean?)
	local badge = view.keyBadge
	local badgeScale = getOrAddUIScale(badge)

	badge.BackgroundColor3 = C.PRESS_FLASH
	badge.BackgroundTransparency = 0.05
	view.keyStroke.Color = C.PRESS_FLASH
	view.keyLabel.TextColor3 = Color3.new(0.12, 0.1, 0.05)

	TweenService:Create(view.keyLabel, C.FLASH_TWEEN, { TextColor3 = C.PRESS_FLASH }):Play()
	if not skipBadgeScale then
		TweenService:Create(badgeScale, C.TILT_POP, { Scale = 1.08 }):Play()
	end

	task.delay(0.16, function()
		if not badge.Parent then
			return
		end
		if holdGreenAfter then
			applyHoldBadgeActive(view)
		else
			resetKeyBadgeVisuals(view)
		end
		TweenService:Create(view.keyLabel, C.BADGE_TWEEN, {
			TextColor3 = if isManagedBushPrompt(view.prompt) then C.TEXT_PRIMARY else C.KEY_TEXT,
		}):Play()
		if not skipBadgeScale then
			TweenService:Create(badgeScale, C.BADGE_TWEEN, { Scale = 1 }):Play()
		end
	end)
end

playPressAnim = function(view: PromptView)
	local root = view.root
	local badge = view.keyBadge
	local badgeScale = getOrAddUIScale(badge)
	local isStand = isStandProximityPrompt(view.prompt)

	stopIdleSway(view)
	root.Rotation = 0
	badge.Rotation = 0
	view.rootScale.Scale = 1
	flashKeyYellow(view, false, false)

	view.pressAnimToken += 1
	local token = view.pressAnimToken

	local tiltLeft = if isStand then C.STAND_TILT_LEFT else C.TILT_LEFT
	local tiltRight = if isStand then C.STAND_TILT_RIGHT else C.TILT_RIGHT
	local tiltCenter = if isStand then C.STAND_TILT_CENTER else C.TILT_CENTER

	if not isStand then
		TweenService:Create(badgeScale, C.TILT_LEFT, { Scale = 0.92 }):Play()
	else
		TweenService:Create(badgeScale, C.TILT_LEFT, { Scale = 0.94 }):Play()
	end

	local function animAlive(): boolean
		return view.pressAnimToken == token and root.Parent ~= nil
	end

	local function finishTilt()
		if not animAlive() then
			return
		end
		TweenService:Create(root, tiltCenter, { Rotation = 0 }):Play()
		TweenService:Create(badge, tiltCenter, { Rotation = 0 }):Play()
		if not isStand then
			TweenService:Create(badgeScale, tiltCenter, { Scale = 1 }):Play()
		else
			TweenService:Create(badgeScale, tiltCenter, { Scale = 1 }):Play()
		end
		if not view.holding and viewIsActive(view) then
			startIdleSway(view)
		end
	end

	local function swingRight()
		if not animAlive() then
			return
		end
		local tRightRoot = TweenService:Create(root, tiltRight, { Rotation = if isStand then 5 else 6 })
		local tRightBadge = TweenService:Create(badge, tiltRight, { Rotation = if isStand then 7 else 8 })
		tRightRoot:Play()
		tRightBadge:Play()
		if not isStand then
			TweenService:Create(badgeScale, tiltRight, { Scale = 1.08 }):Play()
		else
			TweenService:Create(badgeScale, tiltRight, { Scale = 1.05 }):Play()
		end
		tRightRoot.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				finishTilt()
			end
		end)
	end

	local function swingLeft()
		if not animAlive() then
			return
		end
		local tLeftRoot = TweenService:Create(root, tiltLeft, { Rotation = if isStand then -6 else -7 })
		local tLeftBadge = TweenService:Create(badge, tiltLeft, { Rotation = if isStand then -8 else -9 })
		tLeftRoot:Play()
		tLeftBadge:Play()
		if not isStand then
			TweenService:Create(badgeScale, tiltLeft, { Scale = 0.92 }):Play()
		else
			TweenService:Create(badgeScale, tiltLeft, { Scale = 0.94 }):Play()
		end
		tLeftRoot.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				swingRight()
			end
		end)
	end

	swingLeft()
end

startIdleSway = function(view: PromptView)
	stopIdleSway(view)

	if view.displayOnly and isManagedBushPrompt(view.prompt) then
		view.root.Rotation = 0
		view.keyBadge.Rotation = 0
		return
	end

	local isStand = isStandProximityPrompt(view.prompt)
	local token = view.swayToken
	local phase = math.random() * math.pi * 2
	local freq = if isStand then C.STAND_SWAY_FREQ else C.SWAY_FREQ
	local rootAmp = if isStand then C.STAND_SWAY_AMP else C.SWAY_AMP
	local badgeAmp = if isStand then C.STAND_BADGE_SWAY_AMP else 0

	task.spawn(function()
		while viewIsActive(view) and view.swayToken == token and not view.holding do
			local t = os.clock() * freq + phase
			view.root.Rotation = math.sin(t) * rootAmp
			if badgeAmp > 0 then
				view.keyBadge.Rotation = math.sin(t * 1.18 + 0.55) * badgeAmp
			else
				view.keyBadge.Rotation = 0
			end
			RunService.Heartbeat:Wait()
		end
		if view.swayToken == token and not view.holding and viewIsActive(view) then
			view.root.Rotation = 0
			view.keyBadge.Rotation = 0
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

	view.keyBadge.BackgroundColor3 = if isManagedBushPrompt(view.prompt) then C.BUSH_HOLD_BADGE else C.HOLD_GREEN_BRIGHT
	view.keyBadge.BackgroundTransparency = 0
	view.keyStroke.Color = C.KEY_CHIP_STROKE
	view.keyStroke.Transparency = C.KEY_CHIP_STROKE_TRANSPARENCY
	view.keyLabel.TextColor3 = if isManagedBushPrompt(view.prompt) then C.TEXT_PRIMARY else C.HOLD_COMPLETE_FLASH

	TweenService:Create(badgeScale, C.POP_TWEEN, { Scale = 1.22 }):Play()
	task.delay(0.16, function()
		if not view.keyBadge.Parent then
			return
		end
		TweenService:Create(badgeScale, C.POP_TWEEN, { Scale = 1 }):Play()
	end)
	task.delay(0.28, function()
		if not viewIsActive(view) then
			return
		end
		resetKeyBadgeVisuals(view)
		setHoldFillProgress(view, 0)
		view.root.Rotation = 0
		view.keyBadge.Rotation = 0
		if not (view.displayOnly and isManagedBushPrompt(view.prompt)) then
			startIdleSway(view)
		end
	end)
end

-- Visual-only hold bar for managed bush card (engine owns the real ProximityPrompt hold).
local function stopBushSharedCardHoldVisual(view: PromptView, completed: boolean)
	if not view.displayOnly then
		return
	end
	stopHoldRender(view)
	view.holding = false
	view.holdViaPointer = false
	view.root.Rotation = 0
	view.keyBadge.Rotation = 0
	if completed then
		playHoldComplete(view)
	else
		resetKeyBadgeVisuals(view)
		setHoldFillProgress(view, 0)
		view.root.Rotation = 0
		view.keyBadge.Rotation = 0
		-- No idle sway for bush prompts. They should stay still until the next hold.
		if bushSharedView == view and view.billboard.Enabled and not isManagedBushPrompt(view.prompt) then
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
	view.holding = true
	view.holdViaPointer = false
	view.holdProgress = 0
	view.holdStartTime = t0
	view.holdRenderConn = RunService.RenderStepped:Connect(function()
		if dur > 0 then
			local p = math.clamp((os.clock() - t0) / dur, 0, 1)
			view.holdProgress = p
			setHoldFillProgress(view, p)
			local pulse = 0.04 + math.sin(os.clock() * 14) * 0.03
			view.holdFill.BackgroundTransparency = math.clamp(0.05 - pulse, 0, 0.2)
			if p >= C.HOLD_COMPLETE_THRESHOLD and managedBushHoldActive == view.prompt then
				stopHoldRender(view)
				ProximityPromptEffects.endManagedBushHold(view.prompt, true)
				return
			end
		end
		local t = os.clock()
		view.root.Rotation = wiggleRotation(view.root, seed, t)
		view.keyBadge.Rotation = wiggleRotation(view.keyBadge, seed + 4, t)
	end)
end

local function fireManagedBushHoldComplete(prompt: ProximityPrompt)
	if os.clock() < bushHoldLockUntil then
		return
	end
	bushHoldLockUntil = os.clock() + 0.45
	managedBushHoldActive = nil
	if directBushHoldPrompt == prompt then
		directBushHoldPrompt = nil
	end
	GameSoundEffects.stopBushSearchLoop()
	stopBushCameraShake()
	stopBushWobble()
	if bushSharedView and bushSharedView.prompt == prompt then
		stopBushSharedCardHoldVisual(bushSharedView, true)
	end
	UIInteractionSounds.playClick()
	MobileHaptics.confirm()
	local function runDefaultBushHoldComplete()
		local handler = bushHoldCompleteHandler
		if handler then
			task.spawn(function()
				local ok, err = pcall(handler, prompt)
				if not ok then
					warn("[ProximityPromptEffects] Bush hold complete handler failed:", err)
				end
			end)
		end
	end
	local intercepted = false
	for _, hook in bushHoldCompleteHooks do
		local ok, takeOver = pcall(hook, prompt, runDefaultBushHoldComplete)
		if ok and takeOver == true then
			intercepted = true
			break
		end
	end
	if not intercepted then
		runDefaultBushHoldComplete()
	end
end

function ProximityPromptEffects.isBushSearchActive(): boolean
	return managedBushHoldActive ~= nil and managedBushHoldActive.Parent ~= nil
end

-- Client-owned bush hold (works while a hotbar brainrot Tool is equipped; engine InputHoldBegin often does not).
function ProximityPromptEffects.beginManagedBushHold(prompt: ProximityPrompt)
	if not isManagedBushPrompt(prompt) or CarryGate.isFull() or not prompt.Enabled then
		return
	end
	if managedBushHoldActive and managedBushHoldActive.Parent == nil then
		managedBushHoldActive = nil
	end
	if managedBushHoldActive == prompt then
		return
	end
	if
		managedBushHoldActive
		and managedBushHoldActive ~= prompt
		and managedBushHoldActive.Parent ~= nil
	then
		return
	end
	local began = bushHoldBeganHandler
	if began then
		local ok, block = pcall(began, prompt)
		if ok and block == true then
			return
		elseif not ok then
			warn("[ProximityPromptEffects] bushHoldBeganHandler error:", block)
		end
	end
	managedBushHoldActive = prompt
	activeBushSearchPrompt = prompt
	if not bushSharedView or not bushSharedView.billboard.Enabled then
		ProximityPromptEffects.showBushSearchFor(prompt)
	end
	if bushSharedView then
		bushSharedView.prompt = prompt
		startBushSharedCardHoldVisual(bushSharedView)
	end
	GameSoundEffects.startBushSearchLoop()
	startBushCameraShake()
	beginBushWobble(prompt)
end

function ProximityPromptEffects.endManagedBushHold(prompt: ProximityPrompt, completed: boolean)
	if managedBushHoldActive ~= prompt then
		return
	end
	managedBushHoldActive = nil
	if directBushHoldPrompt == prompt then
		directBushHoldPrompt = nil
	end
	GameSoundEffects.stopBushSearchLoop()
	stopBushCameraShake()
	stopBushWobble()
	if bushSharedView and bushSharedView.prompt == prompt then
		stopBushSharedCardHoldVisual(bushSharedView, completed)
	elseif bushSharedView then
		stopBushSharedCardHoldVisual(bushSharedView, false)
	end
	pcall(function()
		prompt:InputHoldEnd()
	end)
	if completed then
		fireManagedBushHoldComplete(prompt)
	end
end

-- Managed bush card: engine owns hold/trigger; card must forward touch to InputHoldBegin/End.
local function wireBushSharedClickable(view: PromptView)
	if view.clickWired then
		return
	end
	view.clickWired = true

	view.billboard.Active = true
	view.root.Active = true
	view.billboard.AlwaysOnTop = not isMobilePlatform()

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
	clickBtn.Active = true
	clickBtn.Selectable = true
	clickBtn.ZIndex = 20
	clickBtn.Parent = root

	local touchMinPx = if prefersTouchInput() then C.MIN_TOUCH_PX_MOBILE else C.MIN_TOUCH_PX
	local touchMin = Instance.new("UISizeConstraint")
	touchMin.MinSize = Vector2.new(touchMinPx, touchMinPx)
	touchMin.Parent = clickBtn

	local pointerHoldActive = false
	local pointerHoldBeganAt = 0.0

	local function canInteractWithBush(): boolean
		return managedBushUiEligible(view.prompt)
	end

	local function beginPointerHold()
		local prompt = view.prompt
		if not canInteractWithBush() or pointerHoldActive then
			return
		end
		if not MobileTouchGate.canTapUi() then
			return
		end
		pointerHoldActive = true
		pointerHoldBeganAt = os.clock()
		ProximityPromptEffects.beginManagedBushHold(prompt)
	end

	local function endPointerHold()
		if not pointerHoldActive then
			return
		end
		pointerHoldActive = false
		local prompt = view.prompt
		local dur = prompt.HoldDuration
		local completed = dur > 0 and (os.clock() - pointerHoldBeganAt) >= dur * 0.92
		ProximityPromptEffects.endManagedBushHold(prompt, completed)
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
			if not MobileTouchGate.canTapUi() then
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

			if view.holdProgress >= C.HOLD_COMPLETE_THRESHOLD then
				-- Celebrate the bar only. Do NOT InputHoldEnd here — that cancels the
				-- engine hold before PromptTriggered (breaks steal / other hold prompts).
				stopHoldRender(view)
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
	local adornee = if isBushPrompt(prompt) then getBushBillboardAdornee(prompt) else getPromptAdornee(prompt)

	local isDisplayOnly = displayOnly == true

	local billboard = Instance.new("BillboardGui")
	billboard.Name = if isDisplayOnly then "BushSearchSharedPrompt" else "CustomProximityPrompt"
	-- Desktop: keep billboard non-active so cards don't steal clicks from stand SurfaceGuis.
	-- Mobile: billboard must be Active or touches never reach the card (Roblox hit-test).
	billboard.Active = promptBillboardInputActive()
	billboard.AlwaysOnTop = not isMobilePlatform()
	billboard.LightInfluence = 0
	billboard.MaxDistance = promptBillboardMaxDistance(prompt)
	billboard.Size = UDim2.fromOffset(effectiveMinCardWidth(), C.CARD_H)
	billboard.Adornee = adornee
	if isBushPrompt(prompt) and adornee then
		applyBushBillboardPlacement(billboard, prompt, adornee)
	elseif prompt:GetAttribute("BrainrotFloatingClaim") == true and adornee and adornee:IsA("BasePart") then
		applyFloatingClaimBillboardPlacement(billboard, prompt, adornee :: BasePart)
	else
		billboard.StudsOffset = Vector3.new(0, 1.8, 0)
		billboard.StudsOffsetWorldSpace = Vector3.zero
	end
	-- Parent to PlayerGui so touch/mouse hits the card reliably (world-parented billboards miss on mobile).
	local pg = player:FindFirstChild("PlayerGui")
	if pg and adornee then
		billboard.ResetOnSpawn = false
		billboard.Parent = pg
	else
		billboard.Parent = adornee or prompt
	end

	local card = PromptTheme.buildCard(billboard, prompt, {
		isMobile = isMobilePlatform(),
		isDisplayOnly = isDisplayOnly,
		isManagedBush = isDisplayOnly and isManagedBushPrompt(prompt),
		isFloatingClaim = prompt:GetAttribute("BrainrotFloatingClaim") == true,
		getOrAddUIScale = getOrAddUIScale,
	})

	local view: PromptView = {
		prompt = prompt,
		billboard = billboard,
		root = card.root,
		rootScale = card.rootScale,
		rootStroke = card.rootStroke,
		strokeGrads = {},
		strokeGradConn = nil,
		keyBadge = card.keyBadge,
		keyStroke = card.keyStroke,
		keyLabel = card.keyLabel,
		keyIcon = card.keyIcon,
		holdTrack = card.holdTrack,
		holdFill = card.holdFill,
		actionLabel = card.actionLabel,
		objectLabel = card.objectLabel,
		holding = false,
		holdViaPointer = false,
		holdProgress = 0,
		holdStartTime = 0,
		swayToken = 0,
		pressAnimToken = 0,
		holdRenderConn = nil,
		liveConns = {},
		clickConns = {},
		clickWired = false,
		hoverWired = false,
		displayOnly = isDisplayOnly,
		inputType = if isDisplayOnly then resolvePromptInputType(nil) else nil,
	}

	applyLabelsToView(view)
	if isDisplayOnly and isManagedBushPrompt(prompt) then
		applyBushSearchCardStyle(view)
	end
	refreshKeyLabel(view)
	if not isDisplayOnly then
		wireClickablePrompt(view)
		wirePromptHover(view)
	end
	return view
end

-- ── View lifecycle ────────────────────────────────────────────────────────────

hideView = function(prompt: ProximityPrompt, instant: boolean?)
	if isManagedBushPrompt(prompt) then
		GameSoundEffects.stopBushSearchLoop()
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
	stopStandStrokeGradientCycle(view)
	stopHoldRender(view)
	view.holding = false
	view.holdViaPointer = false

	if instant or isStandProximityPrompt(prompt) then
		destroyView(prompt)
		return
	end

	local scale = view.rootScale
	local t = TweenService:Create(scale, C.CLOSE_TWEEN, { Scale = 0.72 })
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
	stopStandStrokeGradientCycle(view)
	clearStandStrokeGradient(view)
	stopHoldRender(view)
	disconnectAll(view.liveConns)
	disconnectAll(view.clickConns)
	viewsByPrompt[prompt] = nil

	if view.billboard.Parent then
		view.billboard.Enabled = false
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
	local t = TweenService:Create(scale, C.CLOSE_TWEEN, { Scale = 0.72 })
	t.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and bushSharedView == view then
			view.billboard.Enabled = false
			view.billboard.Adornee = nil
		end
	end)
	t:Play()
end

showBushSharedUi = function(prompt: ProximityPrompt): boolean
	if not prompt or not prompt.Parent then
		return false
	end
	if managedBushHoldActive and managedBushHoldActive ~= prompt then
		return false
	end

	clearBushPerPromptViews()

	local adornee = getBushBillboardAdornee(prompt)
	if not adornee then
		return false
	end

	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return false
	end

	local view = bushSharedView
	if view and view.holding and view.prompt ~= prompt then
		return false
	end

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

	local wasEnabled = view.billboard.Enabled
	local previousPrompt = view.prompt
	local promptChanged = previousPrompt ~= prompt

	-- Avoid one visible frame where the reused shared card is still sitting on the old bush.
	if promptChanged then
		view.billboard.Enabled = false
	end

	view.prompt = prompt
	view.inputType = resolvePromptInputType(nil)
	view.billboard.Adornee = adornee
	applyBushBillboardPlacement(view.billboard, prompt, adornee)
	view.billboard.Enabled = true
	ensureKeyIcon(view)
	applyLabelsToView(view)
	applyBushSearchCardStyle(view)
	-- Always force the same finger badge stands use on touch devices.
	-- Do this last so live label refresh / style tint cannot leave a blank "E".
	if UserInputService.TouchEnabled and not prefersGamepadInput() then
		showTouchKeyIcon(view, prompt.HoldDuration > 0)
	else
		refreshKeyLabel(view)
	end
	setHoldTrackVisible(view, view.prompt.HoldDuration > 0)
	wirePromptLiveUpdates(prompt, view)
	wireBushSharedClickable(view)

	if not view.holding then
		if not wasEnabled then
			GameSoundEffects.playProximityPromptAppear()
		end

		-- Bush prompt: no open tween and no idle rotation.
		-- This stops the card from spawning offset/small and then drifting back to center.
		view.rootScale.Scale = 1
		view.root.Rotation = 0
		view.keyBadge.Rotation = 0

		if not (view.displayOnly and isManagedBushPrompt(view.prompt)) then
			if not wasEnabled or promptChanged then
				view.rootScale.Scale = 0.82
				TweenService:Create(view.rootScale, C.OPEN_TWEEN, { Scale = 1 }):Play()
			end
			startIdleSway(view)
		end
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

local function destroyBushCooldownBannerForBush(bush: Instance)
	local entry = bushCooldownBanners[bush]
	if not entry then
		return
	end
	entry.bb:Destroy()
	bushCooldownBanners[bush] = nil
	if next(bushCooldownBanners) == nil and bushCooldownTickerConn then
		bushCooldownTickerConn:Disconnect()
		bushCooldownTickerConn = nil
	end
end

local function destroyAllBushCooldownBanners()
	local bushes: { Instance } = {}
	for bush in bushCooldownBanners do
		table.insert(bushes, bush)
	end
	for _, bush in bushes do
		destroyBushCooldownBannerForBush(bush)
	end
	if bushCooldownTickerConn then
		bushCooldownTickerConn:Disconnect()
		bushCooldownTickerConn = nil
	end
end

local function tickBushCooldownBanner(bush: Instance, entry: BushCooldownBannerEntry, now: number)
	if not entry.bb.Parent then
		destroyBushCooldownBannerForBush(bush)
		return
	end
	if bush:GetAttribute("BushOnCooldown") ~= true then
		destroyBushCooldownBannerForBush(bush)
		return
	end
	local endsAt = bush:GetAttribute("BushCooldownEndsAt")
	if typeof(endsAt) ~= "number" or now >= endsAt then
		destroyBushCooldownBannerForBush(bush)
		return
	end
	local rem = endsAt - now
	if rem <= 0.05 then
		destroyBushCooldownBannerForBush(bush)
		return
	end
	local text = string.format("%ds", math.ceil(rem))
	if entry.label.Text ~= text then
		entry.label.Text = text
	end
end

local function ensureBushCooldownTicker()
	if bushCooldownTickerConn then
		return
	end
	local accum = 0
	bushCooldownTickerConn = RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < 0.25 then
			return
		end
		accum = 0
		local now = Workspace:GetServerTimeNow()
		local bushes: { Instance } = {}
		for bush in bushCooldownBanners do
			table.insert(bushes, bush)
		end
		for _, bush in bushes do
			local entry = bushCooldownBanners[bush]
			if entry then
				tickBushCooldownBanner(bush, entry, now)
			end
		end
		if next(bushCooldownBanners) == nil and bushCooldownTickerConn then
			bushCooldownTickerConn:Disconnect()
			bushCooldownTickerConn = nil
		end
	end)
end

local function ensureBushCooldownBanner(bush: Instance, prompt: ProximityPrompt, endClock: number)
	if suppressedBushCooldownBanners[bush] then
		return
	end
	local existing = bushCooldownBanners[bush]
	if
		existing
		and existing.prompt == prompt
		and math.abs(existing.endClock - endClock) < 0.05
		and existing.bb.Parent
	then
		existing.endClock = endClock
		tickBushCooldownBanner(bush, existing, Workspace:GetServerTimeNow())
		ensureBushCooldownTicker()
		return
	end

	if existing then
		destroyBushCooldownBannerForBush(bush)
	end

	if not prompt.Parent then
		return
	end

	local adornee = getBushBillboardAdornee(prompt)
	if not adornee then
		return
	end

	local pg = player:FindFirstChild("PlayerGui")
	local bb = Instance.new("BillboardGui")
	bb.Name = "BushCooldownBanner"
	bb.Active = false
	bb.AlwaysOnTop = not isMobilePlatform()
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false
	bb.ClipsDescendants = false
	bb.Size = UDim2.fromOffset(220, 48)
	applyBushBillboardPlacement(bb, prompt, adornee)
	bb.MaxDistance = C.COOLDOWN_BANNER_VIEW_RANGE
	bb.Adornee = adornee
	if pg then
		bb.Parent = pg
	else
		bb.Parent = adornee
	end

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
	icon.Size = UDim2.fromOffset(32, 32)
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
	UiFonts.applyDisplayLabel(timeLabel, 18, 12)
	timeLabel.Text = "0s"
	timeLabel.TextColor3 = C.TEXT_PRIMARY
	timeLabel.TextXAlignment = Enum.TextXAlignment.Left
	timeLabel.LayoutOrder = 1
	local tStroke = Instance.new("UIStroke")
	tStroke.Color = Color3.new(0, 0, 0)
	tStroke.Transparency = 0.45
	tStroke.Thickness = 2
	tStroke.Parent = timeLabel
	timeLabel.Parent = cluster

	local entry: BushCooldownBannerEntry = {
		bb = bb,
		label = timeLabel,
		endClock = endClock,
		prompt = prompt,
	}
	bushCooldownBanners[bush] = entry
	tickBushCooldownBanner(bush, entry, Workspace:GetServerTimeNow())
	ensureBushCooldownTicker()
end

function ProximityPromptEffects.hideBushCooldownBanner()
	destroyAllBushCooldownBanners()
end

function ProximityPromptEffects.suppressBushCooldownBanner(bush: Instance, prompt: ProximityPrompt?)
	suppressedBushCooldownBanners[bush] = true
	if prompt then
		suppressedBushCooldownPrompts[bush] = prompt
	end
	destroyBushCooldownBannerForBush(bush)
end

function ProximityPromptEffects.releaseBushCooldownBanner(bush: Instance)
	if not suppressedBushCooldownBanners[bush] then
		return
	end
	suppressedBushCooldownBanners[bush] = nil
	local prompt = suppressedBushCooldownPrompts[bush]
	suppressedBushCooldownPrompts[bush] = nil
	if not bush.Parent then
		return
	end
	local endsAt = bush:GetAttribute("BushCooldownEndsAt")
	if typeof(endsAt) == "number" and Workspace:GetServerTimeNow() < endsAt and prompt and prompt.Parent then
		ensureBushCooldownBanner(bush, prompt, endsAt)
	end
end

function ProximityPromptEffects.clearBushCooldownBannerSuppression(bush: Instance)
	suppressedBushCooldownBanners[bush] = nil
	suppressedBushCooldownPrompts[bush] = nil
end

function ProximityPromptEffects.isBushCooldownBannerSuppressed(bush: Instance): boolean
	return suppressedBushCooldownBanners[bush] == true
end

function ProximityPromptEffects.syncBushCooldownBanners(bushPrompts: { [Instance]: ProximityPrompt })
	local now = Workspace:GetServerTimeNow()
	local expired: { Instance } = {}
	for bush in bushCooldownBanners do
		local endsAt = bush:GetAttribute("BushCooldownEndsAt")
		if not bush.Parent or typeof(endsAt) ~= "number" or now >= endsAt then
			table.insert(expired, bush)
		end
	end
	for _, bush in expired do
		destroyBushCooldownBannerForBush(bush)
	end
	for bush, prompt in bushPrompts do
		if not bush.Parent then
			continue
		end
		if suppressedBushCooldownBanners[bush] then
			continue
		end
		local endsAt = bush:GetAttribute("BushCooldownEndsAt")
		if typeof(endsAt) == "number" and now < endsAt then
			if prompt and prompt.Parent then
				ensureBushCooldownBanner(bush, prompt, endsAt)
			end
		end
	end
end

function ProximityPromptEffects.showBushCooldownBanner(prompt: ProximityPrompt, endClock: number)
	local bush = findBushRootForPrompt(prompt)
	if bush then
		ensureBushCooldownBanner(bush, prompt, endClock)
	end
end

function ProximityPromptEffects.showBushSearchFor(prompt: ProximityPrompt?)
	if managedBushHoldActive and prompt ~= managedBushHoldActive then
		return
	end
	if not prompt or not prompt.Parent then
		if not managedBushHoldActive then
			ProximityPromptEffects.hideBushSearch()
		end
		return
	end
	prompt.Style = Enum.ProximityPromptStyle.Custom
	pcall(function()
		(prompt :: any).ClickablePrompt = true
	end)
	activeBushSearchPrompt = prompt
	local ok, shown = pcall(function()
		return showBushSharedUi(prompt)
	end)
	if not ok then
		warn("[ProximityPromptEffects] showBushSharedUi failed:", shown)
		if not managedBushHoldActive then
			activeBushSearchPrompt = nil
			ProximityPromptEffects.hideBushSearch()
		end
		return
	end
	if not shown and not managedBushHoldActive then
		activeBushSearchPrompt = nil
		ProximityPromptEffects.hideBushSearch()
	end
end

function ProximityPromptEffects.hideBushSearch()
	if managedBushHoldActive then
		return
	end
	activeBushSearchPrompt = nil
	directBushHoldPrompt = nil
	GameSoundEffects.stopBushSearchLoop()
	stopBushCameraShake()
	stopBushWobble()
	hideBushSharedUi(true)
	clearBushPerPromptViews()
	if reshowEligiblePlaceProximityPrompts then
		task.defer(reshowEligiblePlaceProximityPrompts :: () -> ())
	end
end

function ProximityPromptEffects.suppressBushSearchUi(activePrompt: ProximityPrompt?)
	if managedBushHoldActive then
		return
	end
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

local function untrackBillboard(billboard: BillboardGui)
	for p, v in viewsByPrompt do
		if v.billboard == billboard then
			viewsByPrompt[p] = nil
			disconnectAll(v.liveConns)
			disconnectAll(v.clickConns)
			stopIdleSway(v)
			stopStandStrokeGradientCycle(v)
			promptBuildLocks[p] = nil
		end
	end
end

local function destroyCustomPromptBillboardsForAdornee(adornee: Instance)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, ch in ipairs(pg:GetChildren()) do
		if ch:IsA("BillboardGui") and ch.Name == "CustomProximityPrompt" and ch.Adornee == adornee then
			untrackBillboard(ch)
			ch:Destroy()
		end
	end
end

local function showView(prompt: ProximityPrompt)
	local existing = viewsByPrompt[prompt]
	if existing then
		if existing.billboard.Parent then
			-- Reuse the live card. Do NOT restart sway / reset rotation (kills animations).
			existing.billboard.Enabled = true
			return
		end
		-- Stale entry (billboard destroyed) — clear tracking before rebuild.
		viewsByPrompt[prompt] = nil
		disconnectAll(existing.liveConns)
		disconnectAll(existing.clickConns)
		stopIdleSway(existing)
		stopStandStrokeGradientCycle(existing)
	end

	if promptBuildLocks[prompt] then
		return
	end
	promptBuildLocks[prompt] = true

	local ok, viewOrErr = pcall(function()
		-- Nuke any stacked CustomProximityPrompt for this adornee before creating another.
		local adornee = if isBushPrompt(prompt) then getBushBillboardAdornee(prompt) else getPromptAdornee(prompt)
		if adornee then
			destroyCustomPromptBillboardsForAdornee(adornee)
		end

		local built = buildPromptView(prompt)
		viewsByPrompt[prompt] = built
		applyLabelsToView(built)
		built.rootScale.Scale = 0.86
		TweenService:Create(built.rootScale, C.OPEN_TWEEN, { Scale = 1 }):Play()
		startIdleSway(built)
		if not isBushPrompt(prompt) and not isManagedBushPrompt(prompt) then
			GameSoundEffects.playProximityPromptAppear()
		end
		return built
	end)

	promptBuildLocks[prompt] = nil
	if not ok then
		warn("[ProximityPromptEffects] buildPromptView failed:", viewOrErr)
	end
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
	table.insert(view.liveConns, prompt:GetAttributeChangedSignal(C.PLACE_PROMPT_ATTR):Connect(refresh))

	local stand = findStandForPrompt(prompt)
	if stand then
		table.insert(view.liveConns, stand:GetAttributeChangedSignal(C.STAND_NAME_ATTR):Connect(refresh))
		table.insert(view.liveConns, stand:GetAttributeChangedSignal(C.STAND_LEVEL_ATTR):Connect(refresh))
		table.insert(view.liveConns, stand:GetAttributeChangedSignal(C.STAND_RARITY_ATTR):Connect(refresh))
	end
end

local function onPromptShown(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType?)
	if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
		return
	end
	if not shouldShowPromptUi(prompt) then
		hideView(prompt, true)
		return
	end
	if isManagedStandProximityPrompt(prompt) and activeStandPrompt ~= nil and prompt ~= activeStandPrompt then
		hideView(prompt, true)
		return
	end

	local view = viewsByPrompt[prompt]
	local alreadyLive = view ~= nil and view.billboard.Parent ~= nil
	if not alreadyLive then
		showView(prompt)
		view = viewsByPrompt[prompt]
	end
	if not view then
		return
	end

	view.billboard.Enabled = true
	view.inputType = inputType
	if isBushPrompt(prompt) then
		local adornee = getBushBillboardAdornee(prompt)
		if adornee then
			view.billboard.Adornee = adornee
			applyBushBillboardPlacement(view.billboard, prompt, adornee)
		end
	elseif prompt:GetAttribute("BrainrotFloatingClaim") == true then
		local adornee = getPromptAdornee(prompt)
		if adornee and adornee:IsA("BasePart") then
			view.billboard.Adornee = adornee
			applyFloatingClaimBillboardPlacement(view.billboard, prompt, adornee :: BasePart)
		end
	end
	-- First show only: wire + labels. Re-shows must not restart sway (kills idle/hover/press anims).
	if not alreadyLive then
		wirePromptLiveUpdates(prompt, view)
		applyLabelsToView(view)
		ensureKeyIcon(view)
		refreshKeyLabel(view)
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
	for _, inst in CollectionService:GetTagged(C.STAND_TAG) do
		if inst:IsA("Model") then
			local pp = findStandProximityPrompt(inst :: Model)
			if pp and pp.Enabled and pp == activeStandPrompt and shouldShowPromptUi(pp) then
				onPromptShown(pp, nil)
			end
		end
	end
end

function ProximityPromptEffects.syncStandPlaceProximityUi(prompt: ProximityPrompt?)
	if not prompt or not prompt.Parent then
		return
	end
	local existing = viewsByPrompt[prompt]
	if existing and existing.billboard.Parent then
		-- Card already up — never rebuild or restart sway from stand poll.
		existing.billboard.Enabled = true
		return
	end
	task.defer(function()
		if not prompt.Parent or not prompt.Enabled then
			return
		end
		if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
			return
		end
		if not shouldShowPromptUi(prompt) then
			return
		end
		-- Bail if another path already built the card while we deferred.
		local live = viewsByPrompt[prompt]
		if live and live.billboard.Parent then
			live.billboard.Enabled = true
			return
		end
		onPromptShown(prompt, nil)
		purgeOrphanPromptBillboards()
	end)
end

function ProximityPromptEffects.syncStandActivePromptUi(prompt: ProximityPrompt?)
	ProximityPromptEffects.syncStandPlaceProximityUi(prompt)
end

local function onPromptHidden(prompt: ProximityPrompt, _inputType: Enum.ProximityPromptInputType?)
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
			ProximityPromptEffects.beginManagedBushHold(prompt)
		end
		return
	end
	if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
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
		ProximityPromptEffects.endManagedBushHold(prompt, false)
		return
	end
	if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
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
		managedBushHoldActive = nil
		if directBushHoldPrompt == prompt then
			directBushHoldPrompt = nil
		end
		fireManagedBushHoldComplete(prompt)
		return
	end
	if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
		return
	end
	if isManagedStandProximityPrompt(prompt) and activeStandPrompt ~= nil and prompt ~= activeStandPrompt then
		return
	end

	local view = viewsByPrompt[prompt]
	if not view then
		if shouldShowPromptUi(prompt) then
			showView(prompt)
			view = viewsByPrompt[prompt]
		end
	end
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

	table.insert(
		conns,
		prompt:GetPropertyChangedSignal("Style"):Connect(function()
			if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
				prompt.Style = Enum.ProximityPromptStyle.Custom
			end
		end)
	)

	table.insert(
		conns,
		prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
			if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
				prompt.Style = Enum.ProximityPromptStyle.Custom
			end
			if isManagedBushPrompt(prompt) then
				if not prompt.Enabled then
					-- Retarget may flip Enabled off mid-hold; don't kill shake for the active hold.
					if managedBushHoldActive ~= prompt then
						stopBushCameraShake()
						stopBushWobble()
					end
				end
				return
			end
			if isManagedStandProximityPrompt(prompt) then
				if not prompt.Enabled then
					hideView(prompt, true)
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
				if prompt:GetAttribute(C.CUSTOM_ATTR) ~= true or not shouldShowPromptUi(prompt) then
					return
				end
				onPromptShown(prompt, nil)
			end)
		end)
	)

	if prompt.HoldDuration > 0 then
		if not isManagedBushPrompt(prompt) then
			table.insert(
				conns,
				prompt.PromptButtonHoldBegan:Connect(function(triggerPlayer: Player)
					onHoldBegan(prompt, triggerPlayer)
				end)
			)
			table.insert(
				conns,
				prompt.PromptButtonHoldEnded:Connect(function(triggerPlayer: Player)
					onHoldEnded(prompt, triggerPlayer)
				end)
			)
		end
	end

	table.insert(
		conns,
		prompt.Destroying:Connect(function()
			hideView(prompt, true)
			styledPrompts[prompt] = nil
			local old = promptStyleConns[prompt]
			if old then
				disconnectAll(old)
				promptStyleConns[prompt] = nil
			end
		end)
	)

	promptStyleConns[prompt] = conns
end

function ProximityPromptEffects.forceHide(prompt: ProximityPrompt)
	hideView(prompt, true)
end

purgeOrphanPromptBillboards = function()
	-- Prompt billboards are parented directly under PlayerGui — never GetDescendants()
	-- (that walks the whole HUD every purge and hitchs hard).
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	local byAdornee: { [Instance]: BillboardGui } = {}
	for _, desc in ipairs(pg:GetChildren()) do
		if not desc:IsA("BillboardGui") then
			continue
		end
		local n = desc.Name
		if n ~= "CustomProximityPrompt" and n ~= "BushSearchSharedPrompt" then
			continue
		end

		local tracked = bushSharedView ~= nil and bushSharedView.billboard == desc
		if not tracked then
			for _, view in viewsByPrompt do
				if view.billboard == desc then
					tracked = true
					break
				end
			end
		end
		if not tracked then
			desc:Destroy()
			continue
		end

		if n == "CustomProximityPrompt" then
			local adornee = desc.Adornee
			if adornee then
				local existing = byAdornee[adornee]
				if existing and existing ~= desc then
					local keepTracked = false
					for _, view in viewsByPrompt do
						if view.billboard == existing then
							keepTracked = true
							break
						end
					end
					if keepTracked then
						untrackBillboard(desc)
						desc:Destroy()
					else
						untrackBillboard(existing)
						existing:Destroy()
						byAdornee[adornee] = desc
					end
				else
					byAdornee[adornee] = desc
				end
			end
		end
	end
end

-- Stand prompts: client toggles Enabled without always firing PromptHidden — hide stale cards.
function ProximityPromptEffects.syncStandProximityUi(activePrompt: ProximityPrompt?)
	activeStandPrompt = activePrompt
	for prompt in styledPrompts do
		if not prompt.Parent or isManagedBushPrompt(prompt) then
			continue
		end
		if not isManagedStandProximityPrompt(prompt) then
			continue
		end
		if prompt ~= activePrompt then
			ProximityPromptEffects.forceHide(prompt)
			prompt.Enabled = false
		end
	end
end

local function applyCustomPromptStyle(prompt: ProximityPrompt)
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute(C.CUSTOM_ATTR, true)
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
		if prompt:GetAttribute(C.BUSH_MANAGED_ATTR) ~= true then
			-- BushHoldInteraction replaces legacy Search prompts; don't destroy during map load race.
			prompt.Enabled = false
			return
		end
		wireStylePrompt(prompt)
		return
	end

	applyCustomPromptStyle(prompt)
end

function ProximityPromptEffects.init()
	if effectsBooted then
		return
	end
	effectsBooted = true

	MobileTouchGate.init()
	local function scanForPrompts(root: Instance)
		local stack = { root }
		local count = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			if inst:IsA("ProximityPrompt") then
				ProximityPromptEffects.stylePrompt(inst)
			end
			for _, child in inst:GetChildren() do
				table.insert(stack, child)
			end
			count += 1
			if count % 200 == 0 then
				task.wait()
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
		GameSoundEffects.stopBushSearchLoop()
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

	local function refreshMobileFacingPromptVisibility()
		if not isMobilePlatform() then
			return
		end

		-- Only live views + active bush/stand — never walk every styled prompt on the map.
		for prompt, view in viewsByPrompt do
			if not prompt.Parent then
				continue
			end
			local visible = view.billboard.Parent ~= nil and view.billboard.Enabled
			local want = shouldShowPromptUi(prompt)
			if want and not visible and prompt.Enabled and prompt:GetAttribute(C.CUSTOM_ATTR) == true then
				onPromptShown(prompt, nil)
			elseif not want and visible then
				hideView(prompt, true)
			end
		end

		if activeStandPrompt and activeStandPrompt.Parent and shouldShowPromptUi(activeStandPrompt) then
			local view = viewsByPrompt[activeStandPrompt]
			if not (view and view.billboard.Parent and view.billboard.Enabled) then
				onPromptShown(activeStandPrompt, nil)
			end
		end

		if activeBushSearchPrompt and activeBushSearchPrompt.Parent then
			local bushVisible = bushSharedView ~= nil and bushSharedView.billboard.Enabled
			local wantBush = managedBushUiEligible(activeBushSearchPrompt)
			if wantBush and not bushVisible then
				ProximityPromptEffects.showBushSearchFor(activeBushSearchPrompt)
			elseif not wantBush and bushVisible then
				ProximityPromptEffects.hideBushSearch()
			end
		end
	end

	task.spawn(function()
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ C.TOUCH_TAP_ICON, C.TOUCH_HOLD_ICON })
		end)
		if not ok then
			warn("[ProximityPromptEffects] touch icon preload failed:", err)
		end
	end)

	wireProximityPromptService()
	task.defer(purgeOrphanPromptBillboards)

	local promptRepairAccum = 0
	local purgeAccum = 0
	-- Orphan purge was every 1.5s + full PlayerGui GetDescendants — major hitch source.
	local PURGE_INTERVAL = 12
	local REPAIR_INTERVAL = 0.75
	RunService.Heartbeat:Connect(function(dt)
		promptRepairAccum += dt
		purgeAccum += dt
		if purgeAccum >= PURGE_INTERVAL then
			purgeAccum = 0
			purgeOrphanPromptBillboards()
		end
		if promptRepairAccum < REPAIR_INTERVAL then
			return
		end
		promptRepairAccum = 0
		-- Only repair live views + the active stand prompt — never walk every styled prompt.
		if activeStandPrompt and activeStandPrompt.Parent and shouldShowPromptUi(activeStandPrompt) then
			local view = viewsByPrompt[activeStandPrompt]
			if view and view.billboard.Parent then
				if not view.billboard.Enabled then
					view.billboard.Enabled = true
				end
			else
				onPromptShown(activeStandPrompt, nil)
			end
		end
		for prompt, view in viewsByPrompt do
			if prompt == activeStandPrompt or isManagedBushPrompt(prompt) then
				continue
			end
			if not prompt.Parent or not prompt.Enabled or prompt:GetAttribute(C.CUSTOM_ATTR) ~= true then
				continue
			end
			if isManagedStandProximityPrompt(prompt) then
				continue
			end
			if not shouldShowPromptUi(prompt) then
				continue
			end
			if view.billboard.Parent then
				if not view.billboard.Enabled then
					view.billboard.Enabled = true
				end
			end
		end
	end)

	task.defer(function()
		local pg = player:WaitForChild("PlayerGui", 120)
		if pg then
			pg:WaitForChild("Main", 120)
			cacheRarityGradientsFolder()
		end
	end)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in
			{
				"BushSearchSharedPrompt",
				"BushSearchUI",
				"BushSearchPrompt",
				"CustomProximityPrompt",
				"BushCooldownBanner",
			}
		do
			local legacy = pg:FindFirstChild(name)
			if legacy then
				legacy:Destroy()
			end
		end
	end

	task.defer(function()
		purgeOrphanPromptBillboards()
		local map = Workspace:FindFirstChild("Map")
		if map then
			scanForPrompts(map)
		else
			scanForPrompts(Workspace)
		end
	end)

	local promptRoot = Workspace:FindFirstChild("Map") or Workspace
	promptRoot.DescendantAdded:Connect(function(desc)
		if desc:IsA("ProximityPrompt") then
			-- Lock Custom immediately so streamed/enabled prompts never flash Default UI.
			desc.Style = Enum.ProximityPromptStyle.Custom
			ProximityPromptEffects.stylePrompt(desc)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(refreshAllKeyLabels)
	pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(refreshAllKeyLabels)
	end)
	if isMobilePlatform() or UserInputService.TouchEnabled then
		task.defer(refreshAllKeyLabels)
	end

	hookCarryListeners()
	player.CharacterAdded:Connect(function(char: Model)
		stopBushCameraShake()
		stopBushWobble()
		ProximityPromptEffects.hideBushSearch()
		ProximityPromptEffects.hideBushCooldownBanner()
		purgeOrphanPromptBillboards()
		hookCharacterToolListeners(char)
	end)
	if player.Character then
		hookCharacterToolListeners(player.Character)
	end

	local function promptDistanceToCharacter(prompt: ProximityPrompt): number?
		local root = getCharacterRootPart()
		local focus = getPromptFocusWorld(prompt)
		if not root or not focus then
			return nil
		end
		return (root.Position - focus).Magnitude
	end

	-- BushHoldInteraction already picks the closest bush and calls suppressBushSearchUi.
	-- Only re-validate the current prompt — never scan all styledPrompts each tick.
	local function resolveManagedBushPrompt(): ProximityPrompt?
		-- Keep the active hold even if Enabled briefly flickered during walk-retarget.
		if managedBushHoldActive and managedBushHoldActive.Parent then
			return managedBushHoldActive
		end
		if CarryGate.isFull() then
			return nil
		end
		local prompt = activeBushSearchPrompt
		if not prompt or not prompt.Parent or not isManagedBushPrompt(prompt) or not prompt.Enabled then
			return nil
		end
		if not managedBushUiEligible(prompt) then
			return nil
		end
		local dist = promptDistanceToCharacter(prompt)
		if not dist or dist > prompt.MaxActivationDistance + 1.25 then
			return nil
		end
		return prompt
	end

	local bushRefreshAccum = 0
	local facingRefreshAccum = 0
	RunService.Heartbeat:Connect(function(dt)
		bushRefreshAccum += dt
		if bushRefreshAccum >= 0.25 then
			bushRefreshAccum = 0
			local bestBushPrompt = resolveManagedBushPrompt()
			if bestBushPrompt then
				ProximityPromptEffects.showBushSearchFor(bestBushPrompt)
			elseif activeBushSearchPrompt and not managedBushHoldActive then
				ProximityPromptEffects.hideBushSearch()
			end
		end

		if isMobilePlatform() then
			facingRefreshAccum += dt
			if facingRefreshAccum >= C.MOBILE_FACING_REFRESH_INTERVAL then
				facingRefreshAccum = 0
				refreshMobileFacingPromptVisibility()
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local prompt = activeBushSearchPrompt
		if not prompt or not prompt.Parent or not isManagedBushPrompt(prompt) then
			return
		end
		local kc = prompt.KeyboardKeyCode
		if kc == Enum.KeyCode.Unknown then
			if input.KeyCode ~= Enum.KeyCode.E then
				return
			end
		elseif input.KeyCode ~= kc then
			return
		end
		if not managedBushUiEligible(prompt) then
			return
		end
		directBushHoldPrompt = prompt
		ProximityPromptEffects.beginManagedBushHold(prompt)
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject, _processed: boolean)
		local prompt = directBushHoldPrompt
		if not prompt then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local kc = prompt.KeyboardKeyCode
		if kc == Enum.KeyCode.Unknown then
			if input.KeyCode ~= Enum.KeyCode.E then
				return
			end
		elseif input.KeyCode ~= kc then
			return
		end
		ProximityPromptEffects.endManagedBushHold(prompt, false)
	end)
end

return ProximityPromptEffects
