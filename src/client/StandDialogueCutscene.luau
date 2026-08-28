-- [ACTIVE] StandDialogueCutscene
--[[
	Undertale-style stand greeting: camera pan, typewriter + Voice Gaster,
	brainrot talk-jump, Enter/Sell/Upgrade + Exit choices.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local MobileHaptics = require(script.Parent.MobileHaptics)
local UiFonts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiFonts"))
local MobileTouchGate = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

local GUI_NAME = "StandDialogueCutscene"
local LOCK_ACTION = "StandDialogueMoveLock"
local SELECT_ACTION = "StandDialogueSelect"
local WORLD_SPEECH_NAME = "StandBrainrotSpeech"
local ARROW_IMAGE = "rbxassetid://92898814478474"

local LETTER_DELAY = 0.026
local LINE_PAUSE = 0.12
local WORLD_LETTER_DELAY = 0.022
local WORLD_MAX_DISTANCE = 160

local IDLE_ANIM_IDS: { [string]: number } = {
	TatatataSahur = 126404281186060,
	TricTracBarabum = 93169378235673,
	OrangutiniAnanassini = 101569991072351,
	TimCheese = 123573016645821,
}

export type DialogueLine = {
	text: string,
	shake: boolean?,
}

export type StandDialogueConfig = {
	standName: string,
	frameName: string,
	brainrotName: string,
	enterLabel: string,
	exitLabel: string?,
	lines: { DialogueLine },
	voicePitchMin: number,
	voicePitchMax: number,
}

export type WorldSpeechOpts = {
	durationSec: number?,
	letterDelay: number?,
	minDurationSec: number?,
	voicePitchMin: number?,
	voicePitchMax: number?,
	textSize: number?,
	billboardWidth: number?,
	billboardHeight: number?,
	studsOffset: Vector3?,
}

local StandDialogueCutscene = {}

local active = false
local finishing = false
local cameraConn: RBXScriptConnection? = nil
local shakeConn: RBXScriptConnection? = nil
local choiceHoverConn: RBXScriptConnection? = nil
local stickSelectConn: RBXScriptConnection? = nil
local touchSelectConn: RBXScriptConnection? = nil
local touchPanConn: RBXScriptConnection? = nil
local jumpRequestConn: RBXScriptConnection? = nil
local jumpStateConn: RBXScriptConnection? = nil
local jumpSuppressConn: RBXScriptConnection? = nil
local typeToken = 0
local jumpToken = 0
local skipRequested = false
local conversationSkip = false
local typingActive = false
local letterboxSkipBtn: TextButton? = nil
local letterboxSkipConn: RBXScriptConnection? = nil
local letterboxSkipCallback: (() -> ())? = nil

local _savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov: number? = nil
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

local cutsceneGui: ScreenGui? = nil
local letterTop: Frame? = nil
local letterBottom: Frame? = nil
local dialogueBox: Frame? = nil
local dialogueLabel: TextLabel? = nil
local skipHint: TextLabel? = nil
local choiceEnter: TextButton? = nil
local choiceExit: TextButton? = nil
local soulMarker: ImageLabel? = nil
local soulSpinConn: RBXScriptConnection? = nil
local soulMoveConn: RBXScriptConnection? = nil
local soulWiping = false
local soulAnimX = 0
local soulAnimY = 0
local soulHasPos = false
local soulSpinT0 = 0
local soulSpinDur = 0
local _soulSpinFrom = 0
local _soulSpinDelta = 0
local soulSpinning = false

local focusModel: Model? = nil
local basePivot: CFrame? = nil
local blendFromCf: CFrame? = nil
local blendStart = 0
local BLEND_DURATION = 0.75
local selectedIndex = 1
local lastHapticSelectedIndex = 0
local choicesReady = false
local resolveChoice: ((choseEnter: boolean) -> ())? = nil
local activeVoicePitchMin = 0.88
local activeVoicePitchMax = 1.2
local mouseLookX = 0
local mouseLookY = 0
local touchPanX = 0
local touchPanY = 0
local boxShakeBasePos: UDim2? = nil
local choiceFrame: Frame? = nil
local dialogueLayoutConn: RBXScriptConnection? = nil
local dialogueViewportConn: RBXScriptConnection? = nil
local DIALOGUE_LAYOUT_HZ = 12

local CUTSCENE_HIDE_OPTS = {
	keepScreenGuiNames = { "StandDialogueCutscene" },
	hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker" },
	hideMainChildNames = { "TimCheeseQuestHost" },
}

type ChoiceHoverState = {
	btn: TextButton,
	basePos: UDim2,
	baseRot: number,
	hovering: boolean,
	pos: UDim2,
	rot: number,
}

local choiceHoverStates: { ChoiceHoverState } = {}

local voiceGasterTemplate: Sound? = nil
local idleTracks: { [Model]: AnimationTrack } = {}
local worldSpeechToken = 0

local function getHRP(): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

local function flatUnit(from: Vector3, to: Vector3): Vector3
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function modelFocusPoint(model: Model): (Vector3, number)
	local ok, boxCFrame, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3" then
		local radius = math.max(boxSize.X, boxSize.Y, boxSize.Z) * 0.55
		return boxCFrame.Position + Vector3.new(0, boxSize.Y * 0.08, 0), math.max(radius, 2.5)
	end
	local pivot = model:GetPivot().Position
	return pivot + Vector3.new(0, 1.5, 0), 3.5
end

local function resolveSpeechAdornee(model: Model): BasePart?
	local head = model:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head
	end
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function faceCharacterToward(target: Vector3)
	local hrp = getHRP()
	if not hrp then
		return
	end
	local flat = flatUnit(hrp.Position, target)
	hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + flat)
end

local function resolveAnimator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			return animator
		end
		local created = Instance.new("Animator")
		created.Parent = humanoid
		return created
	end
	local controller = model:FindFirstChildOfClass("AnimationController")
	if not controller then
		controller = Instance.new("AnimationController")
		controller.Name = "AnimationController"
		controller.Parent = model
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local created = Instance.new("Animator")
	created.Parent = controller
	return created
end

function StandDialogueCutscene.ensureIdleAnimation(model: Model, brainrotName: string)
	if idleTracks[model] and idleTracks[model].IsPlaying then
		return
	end
	local animId = IDLE_ANIM_IDS[brainrotName]
	if not animId then
		return
	end
	local animator = resolveAnimator(model)
	if not animator then
		return
	end
	local anim = Instance.new("Animation")
	anim.Name = "StandIdle"
	anim.AnimationId = "rbxassetid://" .. tostring(animId)
	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	anim:Destroy()
	if not ok or typeof(trackOrErr) ~= "Instance" then
		warn("[StandDialogueCutscene] idle load failed:", trackOrErr)
		return
	end
	local track = trackOrErr :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped = true
	track:Play(0.15)
	idleTracks[model] = track
end

local function ensureVoiceTemplate()
	if voiceGasterTemplate and voiceGasterTemplate.Parent then
		return
	end
	local root = SoundService:FindFirstChild("SoundEffects")
	local dialogueFolder = root and root:FindFirstChild("Dialogue")
	if not dialogueFolder then
		return
	end
	local sound = dialogueFolder:FindFirstChild("Voice Gaster")
	if sound and sound:IsA("Sound") then
		voiceGasterTemplate = sound
	else
		voiceGasterTemplate = dialogueFolder:FindFirstChildWhichIsA("Sound")
	end
end

local function playVoiceLetter()
	ensureVoiceTemplate()
	if not voiceGasterTemplate then
		return
	end
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local clone = voiceGasterTemplate:Clone()
	local sfxGroup = ClientSFXVolume.getSoundGroup()
	if sfxGroup then
		clone.SoundGroup = sfxGroup
	else
		clone.Volume = voiceGasterTemplate.Volume * ClientSFXVolume.getVolume()
	end
	local span = math.max(activeVoicePitchMax - activeVoicePitchMin, 0.01)
	clone.PlaybackSpeed = activeVoicePitchMin + math.random() * span
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
	task.delay(0.12, function()
		if clone.Parent and clone.IsPlaying then
			clone:Stop()
			clone:Destroy()
		end
	end)
end

StandDialogueCutscene.playVoiceLetter = playVoiceLetter

function StandDialogueCutscene.setVoicePitch(minPitch: number?, maxPitch: number?)
	if typeof(minPitch) == "number" then
		activeVoicePitchMin = minPitch
	end
	if typeof(maxPitch) == "number" then
		activeVoicePitchMax = maxPitch
	end
end

local function bindMoveLock()
	ContextActionService:BindActionAtPriority(
		LOCK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		100000,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump
	)
end

local function unbindMoveLock()
	pcall(function()
		ContextActionService:UnbindAction(LOCK_ACTION)
	end)
end

local function clearJumpSuppress()
	if jumpRequestConn then
		jumpRequestConn:Disconnect()
		jumpRequestConn = nil
	end
	if jumpStateConn then
		jumpStateConn:Disconnect()
		jumpStateConn = nil
	end
	if jumpSuppressConn then
		jumpSuppressConn:Disconnect()
		jumpSuppressConn = nil
	end
end

local function bindJumpSuppress()
	clearJumpSuppress()
	jumpRequestConn = UserInputService.JumpRequest:Connect(function()
		local hum = getHumanoid()
		if hum then
			hum.Jump = false
		end
	end)
	local hum = getHumanoid()
	if hum then
		jumpStateConn = hum.StateChanged:Connect(function(_old, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				hum.Jump = false
				hum:ChangeState(Enum.HumanoidStateType.Running)
			end
		end)
	end
	jumpSuppressConn = RunService.Heartbeat:Connect(function()
		if not active then
			return
		end
		local h = getHumanoid()
		if not h then
			return
		end
		h.Jump = false
		h.JumpPower = 0
		h.JumpHeight = 0
		if h:GetState() == Enum.HumanoidStateType.Jumping then
			h:ChangeState(Enum.HumanoidStateType.Running)
		end
	end)
end

local function lockMovement()
	local hum = getHumanoid()
	if hum then
		-- Don't snapshot zero speed from an outer cutscene lock (would restore as slowed).
		if hum.WalkSpeed > 0.05 then
			savedWalkSpeed = hum.WalkSpeed
		elseif savedWalkSpeed == nil then
			local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
			if typeof(base) == "number" and base > 0 then
				local slowOn = Players.LocalPlayer:GetAttribute("SlowWalkEnabled") == true
				savedWalkSpeed = base * (if slowOn then 0.8 else 1.15)
			else
				savedWalkSpeed = 16 * 1.15
			end
		end
		if hum.JumpPower > 0 then
			savedJumpPower = hum.JumpPower
		elseif savedJumpPower == nil then
			savedJumpPower = 50
		end
		if hum.JumpHeight > 0 then
			savedJumpHeight = hum.JumpHeight
		elseif savedJumpHeight == nil then
			savedJumpHeight = 7.2
		end
		savedUseJumpPower = hum.UseJumpPower
		savedAutoRotate = hum.AutoRotate
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.Jump = false
		hum.AutoRotate = false
	end
	BushHoldInteraction.setBushSearchLocked(true)
	bindMoveLock()
	bindJumpSuppress()
end

local function unlockMovement()
	clearJumpSuppress()
	unbindMoveLock()
	BushHoldInteraction.setBushSearchLocked(false)
	local hum = getHumanoid()
	if hum then
		if typeof(savedWalkSpeed) == "number" then
			hum.WalkSpeed = savedWalkSpeed
		end
		if typeof(savedUseJumpPower) == "boolean" then
			hum.UseJumpPower = savedUseJumpPower
		end
		if typeof(savedJumpPower) == "number" then
			hum.JumpPower = savedJumpPower
		end
		if typeof(savedJumpHeight) == "number" then
			hum.JumpHeight = savedJumpHeight
		elseif hum.JumpHeight <= 0 then
			hum.JumpHeight = 7.2
		end
		if typeof(savedAutoRotate) == "boolean" then
			hum.AutoRotate = savedAutoRotate
		end
	end
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil
end

local function stopCamera()
	if cameraConn then
		cameraConn:Disconnect()
		cameraConn = nil
	end
end

local function stopShake()
	if shakeConn then
		shakeConn:Disconnect()
		shakeConn = nil
	end
	if dialogueBox and boxShakeBasePos then
		dialogueBox.Position = boxShakeBasePos
	end
end

local function viewportSize(): Vector2
	local cam = Workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

local function syncDialogueLayout()
	if not dialogueBox or not dialogueLabel then
		return
	end
	local vp = viewportSize()
	local vw, vh = vp.X, vp.Y
	local touch = UserInputService.TouchEnabled
	local compact = touch or vw < 1100 or vh < 620
	local tiny = vw < 520 or vh < 400

	local dialogueTextSize = if tiny then 14 elseif compact then 17 elseif vh < 720 then 22 else 26
	local buttonTextSize = if tiny then 11 elseif compact then 14 else 18
	local dialogueH = math.clamp(math.floor(vh * (if compact then 0.24 else 0.20)), 80, 156)
	local choiceH = math.clamp(math.floor(vh * 0.24), 96, 176)

	-- Centered dialogue box; Undertale-style choices on the right.
	dialogueBox.AnchorPoint = Vector2.new(0.5, 1)
	dialogueBox.Position = UDim2.new(0.5, 0, 0.90, 0)
	dialogueBox.Size = UDim2.new(if compact then 0.72 else 0.62, 0, 0, dialogueH)

	if choiceFrame then
		choiceFrame.AnchorPoint = Vector2.new(1, 0.5)
		choiceFrame.Position = UDim2.new(0.96, 0, 0.48, 0)
		choiceFrame.Size = UDim2.new(if compact then 0.32 else 0.24, 0, 0, choiceH)
	end

	dialogueLabel.TextSize = dialogueTextSize
	UiFonts.applyBodyLabel(dialogueLabel, dialogueTextSize, math.max(10, dialogueTextSize - 8))

	if choiceEnter then
		choiceEnter.TextSize = buttonTextSize
		choiceEnter.TextWrapped = true
		-- Same pixel font as dialogue text (Montserrat often fails to resolve here).
		UiFonts.applyBody(choiceEnter)
		UiFonts.ensureTextSizeConstraint(choiceEnter :: any, buttonTextSize, math.max(9, buttonTextSize - 4))
	end
	if choiceExit then
		choiceExit.TextSize = buttonTextSize
		choiceExit.TextWrapped = true
		UiFonts.applyBody(choiceExit)
		UiFonts.ensureTextSizeConstraint(choiceExit :: any, buttonTextSize, math.max(9, buttonTextSize - 4))
	end

	boxShakeBasePos = dialogueBox.Position
end

local function stopDialogueLayoutSync()
	if dialogueLayoutConn then
		dialogueLayoutConn:Disconnect()
		dialogueLayoutConn = nil
	end
	if dialogueViewportConn then
		dialogueViewportConn:Disconnect()
		dialogueViewportConn = nil
	end
end

local function startDialogueLayoutSync()
	stopDialogueLayoutSync()
	local accum = 0.0
	dialogueLayoutConn = RunService.Heartbeat:Connect(function(dt)
		if not active then
			return
		end
		accum += dt
		if accum < (1 / DIALOGUE_LAYOUT_HZ) then
			return
		end
		accum = 0
		syncDialogueLayout()
	end)
	local cam = Workspace.CurrentCamera
	if cam then
		dialogueViewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if active then
				syncDialogueLayout()
			end
		end)
	end
	syncDialogueLayout()
end

local function stopSoulSpin()
	soulSpinning = false
	soulSpinDur = 0
	if soulSpinConn then
		soulSpinConn:Disconnect()
		soulSpinConn = nil
	end
end

local function stopSoulMove()
	if soulMoveConn then
		soulMoveConn:Disconnect()
		soulMoveConn = nil
	end
end

local function soulPosForButton(target: GuiObject)
	if not soulMarker or not soulMarker.Parent then
		return nil, nil
	end
	local parent = soulMarker.Parent
	if not parent:IsA("GuiObject") then
		return nil, nil
	end
	local btnAbs = target.AbsolutePosition
	local btnSize = target.AbsoluteSize
	local parentAbs = (parent :: GuiObject).AbsolutePosition
	local x = btnAbs.X - parentAbs.X - 4
	local y = btnAbs.Y + btnSize.Y * 0.5 - parentAbs.Y
	return x, y
end

local function beginSoulSelectPulse()
	if not soulMarker or soulWiping then
		return
	end
	-- Scale pulse only — never rotate (180 flips the arrow the wrong way)
	_soulSpinFrom = 0
	_soulSpinDelta = 0
	soulSpinT0 = os.clock()
	soulSpinDur = 0.26
	soulSpinning = true
end

local function ensureSoulTrackLoop()
	if soulMoveConn or not choicesReady then
		return
	end
	soulMoveConn = RunService.RenderStepped:Connect(function(dt)
		if not choicesReady or soulWiping or not soulMarker or not soulMarker.Parent then
			stopSoulMove()
			return
		end
		local target = if selectedIndex == 1 then choiceEnter else choiceExit
		if not target then
			return
		end
		local gx, gy = soulPosForButton(target)
		if not gx or not gy then
			return
		end
		if not soulHasPos then
			soulAnimX = gx
			soulAnimY = gy
			soulHasPos = true
		else
			-- Pokemon-style cursor: glide toward the selected option
			local smooth = math.min(dt * 16, 1)
			soulAnimX += (gx - soulAnimX) * smooth
			soulAnimY += (gy - soulAnimY) * smooth
		end
		soulMarker.Position = UDim2.fromOffset(soulAnimX, soulAnimY)

		if soulSpinning and soulMarker then
			local scale = soulMarker:FindFirstChildOfClass("UIScale")
			if not scale then
				scale = Instance.new("UIScale")
				scale.Scale = 1
				scale.Parent = soulMarker
			end
			local a = math.clamp((os.clock() - soulSpinT0) / math.max(soulSpinDur, 0.01), 0, 1)
			local eased = a * a * (3 - 2 * a)
			-- Keep facing; just shrink then grow
			soulMarker.Rotation = 0
			scale.Scale = 1 - 0.22 * math.sin(eased * math.pi)
			if a >= 1 then
				scale.Scale = 1
				soulSpinning = false
			end
		end

		-- Soft button follow / tilt
		local mouse = UserInputService:GetMouseLocation()
		for _, state in choiceHoverStates do
			local btn = state.btn
			if not btn.Parent then
				continue
			end
			local goalX = 0
			local goalY = 0
			local goalRot = state.baseRot
			if state.hovering then
				local absPos = btn.AbsolutePosition
				local absSize = btn.AbsoluteSize
				local centerX = absPos.X + absSize.X * 0.5 - (state.pos.X.Offset - state.basePos.X.Offset)
				local centerY = absPos.Y + absSize.Y * 0.5 - (state.pos.Y.Offset - state.basePos.Y.Offset)
				local dx = mouse.X - centerX
				local dy = mouse.Y - centerY
				goalX = math.clamp(dx * 0.1, -7, 7)
				goalY = math.clamp(dy * 0.1, -5, 5)
				goalRot = state.baseRot + math.clamp(dx * 0.012, -1.1, 1.1)
			end
			local smooth = math.min(dt * 14, 1)
			local curX = state.pos.X.Offset - state.basePos.X.Offset
			local curY = state.pos.Y.Offset - state.basePos.Y.Offset
			local nextX = curX + (goalX - curX) * smooth
			local nextY = curY + (goalY - curY) * smooth
			state.rot += (goalRot - state.rot) * smooth
			state.pos = UDim2.new(
				state.basePos.X.Scale,
				state.basePos.X.Offset + nextX,
				state.basePos.Y.Scale,
				state.basePos.Y.Offset + nextY
			)
			btn.Position = state.pos
			btn.Rotation = state.rot
		end
	end)
end

local function wipeSoulMarker(onDone: (() -> ())?)
	if not soulMarker or soulWiping then
		if onDone then
			onDone()
		end
		return
	end
	soulWiping = true
	stopSoulSpin()
	stopSoulMove()
	local marker = soulMarker
	local scale = marker:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = marker
	end
	local info = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(marker, info, {
		ImageTransparency = 1,
	}):Play()
	TweenService:Create(scale, info, { Scale = 0.15 }):Play()
	task.delay(0.3, function()
		if marker.Parent then
			marker.Visible = false
			marker.ImageTransparency = 0
			marker.Rotation = 0
			scale.Scale = 1
		end
		soulHasPos = false
		soulWiping = false
		if onDone then
			onDone()
		end
	end)
end

local function stopChoiceHover()
	if choiceHoverConn then
		choiceHoverConn:Disconnect()
		choiceHoverConn = nil
	end
	for _, state in choiceHoverStates do
		state.btn.Position = state.basePos
		state.btn.Rotation = state.baseRot
		state.pos = state.basePos
		state.rot = state.baseRot
		state.hovering = false
	end
end

local function stopTouchInput()
	if touchSelectConn then
		touchSelectConn:Disconnect()
		touchSelectConn = nil
	end
	if touchPanConn then
		touchPanConn:Disconnect()
		touchPanConn = nil
	end
end

local function isPointerOverChoiceButtons(): boolean
	local mouse = UserInputService:GetMouseLocation()
	local guiObjects = GuiService:GetGuiObjectsAtPosition(mouse.X, mouse.Y)
	for _, obj in guiObjects do
		if obj == choiceEnter or obj == choiceExit then
			return true
		end
		if choiceEnter and obj:IsDescendantOf(choiceEnter) then
			return true
		end
		if choiceExit and obj:IsDescendantOf(choiceExit) then
			return true
		end
	end
	return false
end

local function startChoiceHoverLoop()
	ensureSoulTrackLoop()
end

local updateChoiceVisuals: () -> ()

local function wireChoiceHover(btn: TextButton)
	local state: ChoiceHoverState = {
		btn = btn,
		basePos = btn.Position,
		baseRot = btn.Rotation,
		hovering = false,
		pos = btn.Position,
		rot = btn.Rotation,
	}
	table.insert(choiceHoverStates, state)

	btn.MouseEnter:Connect(function()
		if choicesReady then
			selectedIndex = if btn == choiceEnter then 1 else 2
			updateChoiceVisuals()
		end
		state.hovering = true
		startChoiceHoverLoop()
	end)
	btn.MouseLeave:Connect(function()
		state.hovering = false
		startChoiceHoverLoop()
	end)
end

local function startShake()
	stopShake()
	if not dialogueBox then
		return
	end
	boxShakeBasePos = dialogueBox.Position
	local base = boxShakeBasePos
	local vp = viewportSize()
	local compact = vp.X < 900 or vp.Y < 620
	local ampX = if compact then 3 else 6
	local ampY = if compact then 2.5 else 5
	shakeConn = RunService.RenderStepped:Connect(function()
		if not dialogueBox or not base then
			return
		end
		local ox = (math.random() - 0.5) * ampX
		local oy = (math.random() - 0.5) * ampY
		dialogueBox.Position = UDim2.new(base.X.Scale, base.X.Offset + ox, base.Y.Scale, base.Y.Offset + oy)
	end)
end

local function stopInput()
	pcall(function()
		ContextActionService:UnbindAction(SELECT_ACTION)
	end)
	if stickSelectConn then
		stickSelectConn:Disconnect()
		stickSelectConn = nil
	end
	stopTouchInput()
end

local function restoreBrainrotPivot()
	jumpToken += 1
	if focusModel and focusModel.Parent and basePivot then
		pcall(function()
			focusModel:PivotTo(basePivot)
		end)
	end
end

local function defaultGameplayCameraCFrame(hrp: BasePart): CFrame
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local camPos = hrp.Position - look * 12.5 + Vector3.new(0, 5.5, 0)
	local lookAt = hrp.Position + Vector3.new(0, 1.6, 0)
	return CFrame.lookAt(camPos, lookAt)
end

local function styleChoiceButton(btn: TextButton)
	btn.BackgroundColor3 = Color3.new(0, 0, 0)
	btn.BackgroundTransparency = 0.15
	btn.BorderSizePixel = 0
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextStrokeColor3 = Color3.new(0, 0, 0)
	btn.TextStrokeTransparency = 0
	btn.TextXAlignment = Enum.TextXAlignment.Left
	btn.AutoButtonColor = false
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = btn
	end
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local pad = btn:FindFirstChildOfClass("UIPadding")
	if not pad then
		pad = Instance.new("UIPadding")
		pad.Parent = btn
	end
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
end

updateChoiceVisuals = function()
	if not choiceEnter or not choiceExit or not soulMarker then
		return
	end
	if selectedIndex ~= lastHapticSelectedIndex and choicesReady then
		lastHapticSelectedIndex = selectedIndex
		beginSoulSelectPulse()
	end
	choiceEnter.TextColor3 = if selectedIndex == 1 then Color3.fromRGB(255, 255, 0) else Color3.fromRGB(255, 255, 255)
	choiceExit.TextColor3 = if selectedIndex == 2 then Color3.fromRGB(255, 255, 0) else Color3.fromRGB(255, 255, 255)
	local enterStroke = choiceEnter:FindFirstChildOfClass("UIStroke")
	local exitStroke = choiceExit:FindFirstChildOfClass("UIStroke")
	if enterStroke and exitStroke then
		if selectedIndex == 1 then
			enterStroke.Color = Color3.fromRGB(255, 255, 0)
			exitStroke.Color = Color3.new(1, 1, 1)
		else
			enterStroke.Color = Color3.new(1, 1, 1)
			exitStroke.Color = Color3.fromRGB(255, 255, 0)
		end
	end
	if choicesReady and not soulWiping then
		soulMarker.Visible = true
		soulMarker.ImageTransparency = 0
	end
	ensureSoulTrackLoop()
end

local linePauseSkip = false

local function requestSkip()
	if choicesReady then
		return
	end
	if typingActive then
		skipRequested = true
	else
		linePauseSkip = true
	end
end

local function confirmChoice(enter: boolean)
	if not choicesReady or not resolveChoice then
		return
	end
	selectedIndex = if enter then 1 else 2
	updateChoiceVisuals()
	MobileHaptics.confirm()
	local resolve = resolveChoice
	choicesReady = false
	wipeSoulMarker(function()
		if resolve then
			resolve(enter)
		end
	end)
end

local function ensureGui(): ScreenGui
	local STYLE = "center_arcade_v4"
	if
		cutsceneGui
		and cutsceneGui.Parent
		and cutsceneGui:GetAttribute("Style") == STYLE
		and dialogueLabel
		and choiceEnter
		and choiceExit
		and soulMarker
		and dialogueBox
		and letterboxSkipBtn
	then
		return cutsceneGui
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
		cutsceneGui = nil
	end

	table.clear(choiceHoverStates)

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 950
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui:SetAttribute("Style", STYLE)
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.Size = UDim2.new(1.2, 0, 0, 0)
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, 0, 0)
	top.ZIndex = 10
	top.Active = false
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.Size = UDim2.new(1.2, 0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.new(0.5, 0, 1, 0)
	bottom.ZIndex = 10
	bottom.Active = false
	bottom.Parent = gui

	local letterSkip = Instance.new("TextButton")
	letterSkip.Name = "LetterboxSkip"
	letterSkip.BackgroundTransparency = 1
	letterSkip.AutoButtonColor = false
	letterSkip.Text = if UserInputService.TouchEnabled then "TAP TO SKIP" else "CLICK TO SKIP"
	letterSkip.TextColor3 = Color3.fromRGB(210, 210, 210)
	letterSkip.TextStrokeColor3 = Color3.new(0, 0, 0)
	letterSkip.TextStrokeTransparency = 0.35
	letterSkip.TextSize = 16
	letterSkip.Font = Enum.Font.GothamBold
	letterSkip.AnchorPoint = Vector2.new(0.5, 0.5)
	letterSkip.Position = UDim2.fromScale(0.5, 0.5)
	letterSkip.Size = UDim2.new(0.5, 0, 0.55, 0)
	letterSkip.ZIndex = 15
	letterSkip.Visible = false
	letterSkip.Parent = bottom
	UiFonts.applyBody(letterSkip)
	local letterSkipBoldOk, letterSkipBold = pcall(function()
		return Font.new(letterSkip.FontFace.Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	end)
	if letterSkipBoldOk and typeof(letterSkipBold) == "Font" then
		letterSkip.FontFace = letterSkipBold
	end

	local box = Instance.new("TextButton")
	box.Name = "DialogueBox"
	box.BackgroundColor3 = Color3.new(0, 0, 0)
	box.BorderSizePixel = 0
	box.AutoButtonColor = false
	box.Text = ""
	box.AnchorPoint = Vector2.new(0.5, 1)
	box.Position = UDim2.new(0.5, 0, 0.92, 0)
	box.Size = UDim2.new(0.72, 0, 0.18, 0)
	box.ZIndex = 30
	box.Parent = gui

	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = Color3.new(1, 1, 1)
	boxStroke.Thickness = 4
	boxStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	boxStroke.Parent = box

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = box

	local label = Instance.new("TextLabel")
	label.Name = "DialogueText"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, -14)
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.TextSize = 26
	label.ZIndex = 31
	UiFonts.applyBodyLabel(label, 26, 14)
	label.Parent = box

	local hint = Instance.new("TextLabel")
	hint.Name = "SkipHint"
	hint.BackgroundTransparency = 1
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -4, 1, -2)
	hint.Size = UDim2.new(0.45, 0, 0, 14)
	hint.Text = if UserInputService.TouchEnabled then "TAP TO SKIP" else "CLICK TO SKIP"
	hint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hint.TextStrokeTransparency = 0.4
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextSize = 12
	hint.ZIndex = 32
	hint.Visible = false
	UiFonts.applyBody(hint)
	hint.Parent = box

	box.Activated:Connect(function()
		requestSkip()
	end)

	local choices = Instance.new("Frame")
	choices.Name = "Choices"
	choices.BackgroundTransparency = 1
	choices.AnchorPoint = Vector2.new(1, 0.5)
	choices.Position = UDim2.new(0.96, 0, 0.48, 0)
	choices.Size = UDim2.new(0.24, 0, 0.26, 0)
	choices.ZIndex = 40
	choices.Parent = gui

	local enterBtn = Instance.new("TextButton")
	enterBtn.Name = "Enter"
	enterBtn.Size = UDim2.new(1, 0, 0.42, 0)
	enterBtn.Position = UDim2.new(0, 0, 0.02, 0)
	enterBtn.Text = "* ENTER"
	enterBtn.TextSize = 18
	enterBtn.TextWrapped = true
	enterBtn.ZIndex = 41
	styleChoiceButton(enterBtn)
	UiFonts.applyBody(enterBtn)
	UiFonts.ensureTextSizeConstraint(enterBtn :: any, 18, 11)
	enterBtn.Parent = choices

	local exitBtn = Instance.new("TextButton")
	exitBtn.Name = "Exit"
	exitBtn.Size = UDim2.new(1, 0, 0.42, 0)
	exitBtn.Position = UDim2.new(0, 0, 0.54, 0)
	exitBtn.Text = "* EXIT"
	exitBtn.TextSize = 18
	exitBtn.TextWrapped = true
	exitBtn.ZIndex = 41
	styleChoiceButton(exitBtn)
	UiFonts.applyBody(exitBtn)
	UiFonts.ensureTextSizeConstraint(exitBtn :: any, 18, 11)
	exitBtn.Parent = choices

	local soul = Instance.new("ImageLabel")
	soul.Name = "Soul"
	soul.BackgroundTransparency = 1
	soul.Size = UDim2.fromOffset(44, 44)
	soul.AnchorPoint = Vector2.new(1, 0.5)
	soul.Image = ARROW_IMAGE
	soul.ScaleType = Enum.ScaleType.Fit
	soul.Visible = false
	soul.ZIndex = 42
	soul.Rotation = 0
	soul.Parent = choices
	local soulScale = Instance.new("UIScale")
	soulScale.Scale = 1
	soulScale.Parent = soul

	wireChoiceHover(enterBtn)
	wireChoiceHover(exitBtn)

	enterBtn.Activated:Connect(function()
		if choicesReady then
			confirmChoice(true)
		end
	end)
	exitBtn.Activated:Connect(function()
		if choicesReady then
			confirmChoice(false)
		end
	end)

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	letterboxSkipBtn = letterSkip
	dialogueBox = box
	dialogueLabel = label
	skipHint = hint
	choiceEnter = enterBtn
	choiceExit = exitBtn
	choiceFrame = choices
	soulMarker = soul
	boxShakeBasePos = box.Position
	syncDialogueLayout()
	return gui
end

local function setDialoguePanelVisible(visible: boolean)
	if dialogueBox then
		dialogueBox.Visible = visible
	end
	if choiceFrame then
		choiceFrame.Visible = visible
	end
	if soulMarker and not visible then
		soulMarker.Visible = false
	end
	if skipHint and not visible then
		skipHint.Visible = false
	end
end

local function animateLetterboxIn(letterboxOnly: boolean?)
	local gui = ensureGui()
	setDialoguePanelVisible(letterboxOnly ~= true)
	gui.Enabled = true
	local info = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	if letterTop then
		TweenService:Create(letterTop, info, { Size = UDim2.new(1.2, 0, 0.1, 0) }):Play()
	end
	if letterBottom then
		TweenService:Create(letterBottom, info, { Size = UDim2.new(1.2, 0, 0.1, 0) }):Play()
	end
end

local function animateLetterboxOut()
	local info = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if letterTop then
		TweenService:Create(letterTop, info, { Size = UDim2.new(1.2, 0, 0, 0) }):Play()
	end
	if letterBottom then
		TweenService:Create(letterBottom, info, { Size = UDim2.new(1.2, 0, 0, 0) }):Play()
	end
	if cutsceneGui then
		task.delay(0.3, function()
			if cutsceneGui and not active then
				cutsceneGui.Enabled = false
			end
		end)
	end
end

local function startTalkJump(model: Model)
	jumpToken += 1
	local token = jumpToken
	basePivot = model:GetPivot()
	task.spawn(function()
		while token == jumpToken and active and model.Parent do
			local up = basePivot :: CFrame + Vector3.new(0, 0.55, 0)
			local t0 = os.clock()
			while os.clock() - t0 < 0.12 and token == jumpToken do
				local a = (os.clock() - t0) / 0.12
				model:PivotTo((basePivot :: CFrame):Lerp(up, a))
				RunService.Heartbeat:Wait()
			end
			local t1 = os.clock()
			while os.clock() - t1 < 0.12 and token == jumpToken do
				local a = (os.clock() - t1) / 0.12
				model:PivotTo(up:Lerp(basePivot :: CFrame, a))
				RunService.Heartbeat:Wait()
			end
			if token == jumpToken and basePivot then
				model:PivotTo(basePivot)
			end
			task.wait(0.08)
		end
	end)
end

local function stopTalkJump()
	restoreBrainrotPivot()
end

local function refreshSkipHintText()
	if skipHint then
		skipHint.Text = if UserInputService.TouchEnabled then "TAP TO SKIP" else "CLICK TO SKIP"
	end
end

local function typeLine(line: DialogueLine)
	local label = dialogueLabel
	if not label then
		return
	end
	local fullText = line.text
	typeToken += 1
	local token = typeToken
	typingActive = true
	-- Keep conversationSkip so one click can dump the rest of the cutscene.
	skipRequested = conversationSkip
	label.Text = ""
	refreshSkipHintText()
	if skipHint then
		skipHint.Visible = true
	end
	if conversationSkip then
		label.Text = fullText
		stopShake()
		typingActive = false
		return
	end
	if line.shake then
		startShake()
	else
		stopShake()
	end

	for i = 1, #fullText do
		if token ~= typeToken or not active or skipRequested or conversationSkip then
			break
		end
		local ch = string.sub(fullText, i, i)
		label.Text = string.sub(fullText, 1, i)
		if ch ~= " " and ch ~= "\n" then
			playVoiceLetter()
		end
		task.wait(LETTER_DELAY)
	end

	if active then
		label.Text = fullText
	end
	stopShake()
	typingActive = false
end

local function bindTouchChoiceInput()
	stopTouchInput()
	if not UserInputService.TouchEnabled then
		return
	end

	local dragAccumY = 0
	local DRAG_THRESHOLD = 28

	touchSelectConn = UserInputService.TouchMoved:Connect(function(input, _processed)
		if not active or not choicesReady or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not isPointerOverChoiceButtons() then
			return
		end
		dragAccumY += input.Delta.Y
		if math.abs(dragAccumY) >= DRAG_THRESHOLD then
			local newIndex = if dragAccumY < 0 then 1 else 2
			dragAccumY = 0
			if newIndex ~= selectedIndex then
				selectedIndex = newIndex
				updateChoiceVisuals()
			end
		end
	end)

	touchPanConn = UserInputService.TouchMoved:Connect(function(input, _processed)
		if not active or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if choicesReady and isPointerOverChoiceButtons() then
			return
		end
		touchPanX = math.clamp(touchPanX + input.Delta.X * 0.004, -1, 1)
		touchPanY = math.clamp(touchPanY + input.Delta.Y * 0.004, -1, 1)
	end)
end

local function startCamera(brainrot: Model)
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if not cam or not hrp then
		return
	end

	stopCamera()
	blendFromCf = cam.CFrame
	blendStart = os.clock()
	mouseLookX = 0
	mouseLookY = 0
	touchPanX = 0
	touchPanY = 0
	_savedCameraType = cam.CameraType
	savedCameraSubject = cam.CameraSubject
	savedFov = cam.FieldOfView
	cam.CameraType = Enum.CameraType.Scriptable

	local focusPos = modelFocusPoint(brainrot)
	faceCharacterToward(focusPos)

	local phase = 0
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not active or not cam then
			return
		end
		local liveHrp = getHRP()
		local hum = getHumanoid()
		if not liveHrp then
			return
		end
		if hum then
			hum:Move(Vector3.zero, false)
		end

		phase += dt

		local viewport = cam.ViewportSize
		local mouse = UserInputService:GetMouseLocation()
		local nx = ((mouse.X / math.max(viewport.X, 1)) - 0.5) * 2
		local ny = ((mouse.Y / math.max(viewport.Y, 1)) - 0.5) * 2
		nx = math.clamp(nx + touchPanX, -1, 1)
		ny = math.clamp(ny + touchPanY, -1, 1)
		local lookSmooth = math.min(dt * 7.5, 1)
		mouseLookX += (nx - mouseLookX) * lookSmooth
		mouseLookY += (ny - mouseLookY) * lookSmooth

		local npcPos, npcRadius = modelFocusPoint(brainrot)
		local playerPos = liveHrp.Position + Vector3.new(0, 1.4, 0)
		local mid = playerPos:Lerp(npcPos, 0.55)

		local toNpc = flatUnit(playerPos, npcPos)
		local right = toNpc:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local sidePull = 3.4 + mouseLookX * 2.8
		local height = 2.35 - mouseLookY * 1.2
		local pullBack = 7.2 + npcRadius * 0.15 - math.abs(mouseLookX) * 0.35

		local camPos = mid - toNpc * pullBack + right * sidePull + Vector3.new(0, height, 0)
		camPos += Vector3.new(math.sin(phase * 1.1) * 0.05, math.sin(phase * 0.9) * 0.04, 0)
		local lookAt = mid + Vector3.new(0, 0.2, 0) + right * (0.4 + mouseLookX * 1.1) + Vector3.new(0, -mouseLookY * 0.7, 0)
		local goalCf = CFrame.lookAt(camPos, lookAt)
		local goalFov = (savedFov or 70) - 4 + math.abs(mouseLookX) * 1.5 + math.abs(mouseLookY) * 0.8

		local blend = 1
		if blendFromCf then
			local elapsed = os.clock() - blendStart
			local raw = math.clamp(elapsed / BLEND_DURATION, 0, 1)
			blend = 1 - (1 - raw) ^ 2.6
			if raw >= 1 then
				blendFromCf = nil
			end
		end
		if blendFromCf and blend < 1 then
			cam.CFrame = blendFromCf:Lerp(goalCf, blend)
			cam.FieldOfView = (savedFov or 70) + (goalFov - (savedFov or 70)) * blend
		else
			cam.CFrame = goalCf
			cam.FieldOfView = goalFov
		end
	end)
end

local function endCamera(fadeSec: number?)
	stopCamera()
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	local hum = getHumanoid()
	if cam and hrp and (fadeSec or 0) > 0 then
		local startCf = cam.CFrame
		local endCf = defaultGameplayCameraCFrame(hrp)
		local startFov = cam.FieldOfView
		local goalFov = savedFov or startFov
		local t0 = os.clock()
		local dur = fadeSec :: number
		while os.clock() - t0 < dur do
			local liveHrp = getHRP()
			if liveHrp then
				endCf = defaultGameplayCameraCFrame(liveHrp)
			end
			local alpha = (os.clock() - t0) / dur
			local eased = 1 - (1 - alpha) ^ 3
			cam.CFrame = startCf:Lerp(endCf, eased)
			cam.FieldOfView = startFov + (goalFov - startFov) * eased
			RunService.RenderStepped:Wait()
		end
	end
	-- Always hard-restore gameplay camera (never leave Scriptable / weird FOV on mobile)
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		if hum then
			cam.CameraSubject = hum
		elseif savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
		if savedFov then
			cam.FieldOfView = savedFov
		elseif cam.FieldOfView < 55 or cam.FieldOfView > 90 then
			cam.FieldOfView = 70
		end
	end
	_savedCameraType = nil
	savedCameraSubject = nil
	savedFov = nil
end

local function finishSession(choseEnter: boolean): boolean
	if finishing then
		return choseEnter
	end
	finishing = true
	choicesReady = false
	resolveChoice = nil
	skipRequested = false
	typingActive = false
	stopInput()
	stopChoiceHover()
	stopTouchInput()
	stopSoulSpin()
	stopSoulMove()
	soulHasPos = false
	soulWiping = false
	typeToken += 1
	stopShake()
	stopTalkJump()
	stopDialogueLayoutSync()
	animateLetterboxOut()
	active = false
	if cutsceneGui then
		cutsceneGui.Enabled = false
	end
	endCamera(0.35)
	unlockMovement()
	-- Instant restore so shop panel open right after doesn't re-snapshot mid-slide
	GameplayUiVisibility.show({ instant = true })
	MobileTouchGate.ensureTouchControlsVisible(true)
	MobileTouchGate.restorePlayerMovement()
	if dialogueLabel then
		dialogueLabel.Text = ""
	end
	if skipHint then
		skipHint.Visible = false
	end
	if soulMarker then
		soulMarker.Visible = false
		soulMarker.ImageTransparency = 0
		soulMarker.Rotation = 0
		local sc = soulMarker:FindFirstChildOfClass("UIScale")
		if sc then
			sc.Scale = 1
		end
	end
	if choiceEnter then
		choiceEnter.Visible = false
	end
	if choiceExit then
		choiceExit.Visible = false
	end
	focusModel = nil
	basePivot = nil
	finishing = false
	return choseEnter
end

--[[
	Floating goodbye / speech near a stand brainrot (no cutscene).
]]
function StandDialogueCutscene.showWorldSpeech(model: Model, message: string, opts: WorldSpeechOpts?)
	local adornee = resolveSpeechAdornee(model)
	if not adornee then
		return
	end
	worldSpeechToken += 1
	local token = worldSpeechToken

	local existing = model:FindFirstChild(WORLD_SPEECH_NAME)
	if existing then
		existing:Destroy()
	end

	local savedPitchMin = activeVoicePitchMin
	local savedPitchMax = activeVoicePitchMax
	if opts then
		if typeof(opts.voicePitchMin) == "number" then
			activeVoicePitchMin = opts.voicePitchMin
		end
		if typeof(opts.voicePitchMax) == "number" then
			activeVoicePitchMax = opts.voicePitchMax
		end
	end

	local bbW = if opts and typeof(opts.billboardWidth) == "number" then opts.billboardWidth else 320
	local bbH = if opts and typeof(opts.billboardHeight) == "number" then opts.billboardHeight else 72
	local textSize = if opts and typeof(opts.textSize) == "number" then opts.textSize else 18
	-- Stud scale (not Offset pixels): Offset stays fixed on-screen and looks huge when you walk away.
	local studsW = math.clamp(bbW / 40, 6, 11)
	local studsH = math.clamp(bbH / 40, 1.4, 2.6)

	local bb = Instance.new("BillboardGui")
	bb.Name = WORLD_SPEECH_NAME
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = WORLD_MAX_DISTANCE
	bb.Size = UDim2.fromScale(studsW, studsH)
	-- Cap close-up blowup only; keep shrinking with distance so walking away doesn't balloon text.
	bb.DistanceLowerLimit = 8
	local offset = if opts and typeof(opts.studsOffset) == "Vector3" then opts.studsOffset else Vector3.new(0, 2.8, 0)
	bb.StudsOffset = offset
	bb.Adornee = adornee
	bb.Parent = model

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.15
	label.TextWrapped = true
	label.TextScaled = true
	label.TextSize = textSize
	label.TextTransparency = 0
	UiFonts.applyBody(label)
	UiFonts.ensureTextSizeConstraint(label, textSize, math.max(12, textSize - 4))
	label.Parent = bb

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 2)
	pad.Parent = label

	local letterDelay = if opts and typeof(opts.letterDelay) == "number" then opts.letterDelay else WORLD_LETTER_DELAY
	local typeDuration = #message * letterDelay + 0.1
	task.spawn(function()
		for i = 1, #message do
			if token ~= worldSpeechToken or not bb.Parent then
				break
			end
			local ch = string.sub(message, i, i)
			label.Text = string.sub(message, 1, i)
			if ch ~= " " then
				playVoiceLetter()
			end
			task.wait(letterDelay)
		end
		if token == worldSpeechToken and bb.Parent then
			label.Text = message
		end
	end)

	local holdAfter = if opts and typeof(opts.durationSec) == "number" then opts.durationSec else 0.75
	local minDur = if opts and typeof(opts.minDurationSec) == "number" then opts.minDurationSec else 0
	local dur = math.max(typeDuration + holdAfter, minDur)
	task.delay(dur, function()
		activeVoicePitchMin = savedPitchMin
		activeVoicePitchMax = savedPitchMax
		if token ~= worldSpeechToken or not bb.Parent then
			return
		end
		TweenService:Create(label, TweenInfo.new(0.18), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		task.delay(0.2, function()
			if bb.Parent then
				bb:Destroy()
			end
		end)
	end)
end

function StandDialogueCutscene.cancelWorldSpeech()
	worldSpeechToken += 1
	-- Clear any lingering overhead speech billboards on stand brainrots.
	local map = workspace:FindFirstChild("Map")
	local uiStands = map and map:FindFirstChild("UIStands")
	if not uiStands then
		return
	end
	for _, standFolder in uiStands:GetChildren() do
		for _, d in standFolder:GetDescendants() do
			if d.Name == WORLD_SPEECH_NAME then
				d:Destroy()
			end
		end
	end
end

function StandDialogueCutscene.setLetterboxSkipVisible(visible: boolean, onSkip: (() -> ())?)
	ensureGui()
	letterboxSkipCallback = onSkip
	if letterboxSkipConn then
		letterboxSkipConn:Disconnect()
		letterboxSkipConn = nil
	end
	if letterboxSkipBtn then
		letterboxSkipBtn.Text = if UserInputService.TouchEnabled then "TAP TO SKIP" else "CLICK TO SKIP"
		letterboxSkipBtn.Visible = visible == true
		if visible == true then
			letterboxSkipConn = letterboxSkipBtn.Activated:Connect(function()
				local cb = letterboxSkipCallback
				if cb then
					cb()
				end
			end)
		end
	end
	if letterBottom then
		letterBottom.Active = visible == true
	end
end

function StandDialogueCutscene.isActive(): boolean
	return active
end

function StandDialogueCutscene.showLetterbox()
	animateLetterboxIn(true)
end

function StandDialogueCutscene.hideLetterbox()
	StandDialogueCutscene.setLetterboxSkipVisible(false, nil)
	animateLetterboxOut()
end

function StandDialogueCutscene.getEnterChoiceButton(): TextButton?
	if not active or not choiceEnter or not choiceEnter.Parent or not choiceEnter.Visible then
		return nil
	end
	return choiceEnter
end

function StandDialogueCutscene.cancel()
	if not active then
		return
	end
	finishSession(false)
end

function StandDialogueCutscene.play(config: StandDialogueConfig, brainrot: Model): boolean
	if active then
		return false
	end
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if not cam or not hrp or not brainrot.Parent then
		return false
	end

	active = true
	finishing = false
	choicesReady = false
	skipRequested = false
	conversationSkip = false
	typingActive = false
	linePauseSkip = false
	selectedIndex = 1
	lastHapticSelectedIndex = 0
	focusModel = brainrot
	basePivot = brainrot:GetPivot()
	activeVoicePitchMin = config.voicePitchMin
	activeVoicePitchMax = config.voicePitchMax

	StandDialogueCutscene.ensureIdleAnimation(brainrot, config.brainrotName)
	ensureGui()
	syncDialogueLayout()
	GameplayUiVisibility.hide(CUTSCENE_HIDE_OPTS)
	startDialogueLayoutSync()
	animateLetterboxIn(false)
	setDialoguePanelVisible(true)
	lockMovement()
	startCamera(brainrot)
	bindTouchChoiceInput()

	if choiceEnter then
		choiceEnter.Text = "* " .. string.upper(config.enterLabel)
		choiceEnter.Visible = false
	end
	if choiceExit then
		choiceExit.Text = "* " .. string.upper(config.exitLabel or "EXIT")
		choiceExit.Visible = false
	end
	if soulMarker then
		soulMarker.Visible = false
	end
	if skipHint then
		skipHint.Visible = false
	end

	local choseEnter = false
	local done = false

	resolveChoice = function(enter: boolean)
		if done then
			return
		end
		done = true
		choseEnter = enter
	end

	ContextActionService:BindActionAtPriority(
		SELECT_ACTION,
		function(_name, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if not choicesReady then
				if
					input.KeyCode == Enum.KeyCode.Return
					or input.KeyCode == Enum.KeyCode.Space
					or input.KeyCode == Enum.KeyCode.ButtonA
					or input.KeyCode == Enum.KeyCode.DPadDown
					or input.KeyCode == Enum.KeyCode.DPadUp
				then
					requestSkip()
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end
			if input.KeyCode == Enum.KeyCode.Up or input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.DPadUp then
				selectedIndex = 1
				updateChoiceVisuals()
				return Enum.ContextActionResult.Sink
			elseif input.KeyCode == Enum.KeyCode.Down or input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.DPadDown then
				selectedIndex = 2
				updateChoiceVisuals()
				return Enum.ContextActionResult.Sink
			elseif
				input.KeyCode == Enum.KeyCode.Return
				or input.KeyCode == Enum.KeyCode.Space
				or input.KeyCode == Enum.KeyCode.ButtonA
			then
				confirmChoice(selectedIndex == 1)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.W,
		Enum.KeyCode.S,
		Enum.KeyCode.Return,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown
	)

	local stickLatch = 0
	stickSelectConn = UserInputService.InputChanged:Connect(function(input)
		if not active then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= Enum.KeyCode.Thumbstick1 then
			return
		end
		local y = input.Position.Y
		if not choicesReady then
			if math.abs(y) > 0.65 and stickLatch ~= 3 then
				stickLatch = 3
				requestSkip()
			elseif math.abs(y) < 0.25 then
				stickLatch = 0
			end
			return
		end
		if y > 0.55 and stickLatch ~= 1 then
			stickLatch = 1
			selectedIndex = 1
			updateChoiceVisuals()
		elseif y < -0.55 and stickLatch ~= 2 then
			stickLatch = 2
			selectedIndex = 2
			updateChoiceVisuals()
		elseif math.abs(y) < 0.25 then
			stickLatch = 0
		end
	end)

	startTalkJump(brainrot)
	for _, line in ipairs(config.lines) do
		if not active or conversationSkip then
			break
		end
		typeLine(line)
		if not active or conversationSkip then
			break
		end
		local pauseStart = os.clock()
		linePauseSkip = false
		while os.clock() - pauseStart < LINE_PAUSE and active and not conversationSkip and not linePauseSkip do
			task.wait()
		end
	end
	stopTalkJump()
	stopShake()
	typingActive = false
	if skipHint then
		skipHint.Visible = false
	end

	if not active then
		return false
	end

	if choiceEnter and choiceExit then
		choiceEnter.Visible = true
		choiceExit.Visible = true
	end
	choicesReady = true
	selectedIndex = 1
	lastHapticSelectedIndex = 1
	soulHasPos = false
	soulSpinning = false
	updateChoiceVisuals()

	while active and not done do
		task.wait(0.05)
	end

	if not active then
		return false
	end

	return finishSession(choseEnter)
end

return StandDialogueCutscene
