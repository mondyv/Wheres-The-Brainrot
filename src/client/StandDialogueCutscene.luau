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
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local MobileHaptics = require(script.Parent.MobileHaptics)
local UiFonts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local GUI_NAME = "StandDialogueCutscene"
local LOCK_ACTION = "StandDialogueMoveLock"
local SELECT_ACTION = "StandDialogueSelect"
local WORLD_SPEECH_NAME = "StandBrainrotSpeech"

local LETTER_DELAY = 0.07
local LINE_PAUSE = 0.4
local WORLD_LETTER_DELAY = 0.055

local IDLE_ANIM_IDS: { [string]: number } = {
	TatatataSahur = 126404281186060,
	TricTracBarabum = 93169378235673,
	OrangutiniAnanassini = 101569991072351,
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
	lines: { DialogueLine },
	voicePitchMin: number,
	voicePitchMax: number,
}

export type WorldSpeechOpts = {
	durationSec: number?,
	voicePitchMin: number?,
	voicePitchMax: number?,
}

local StandDialogueCutscene = {}

local active = false
local finishing = false
local cameraConn: RBXScriptConnection? = nil
local shakeConn: RBXScriptConnection? = nil
local choiceHoverConn: RBXScriptConnection? = nil
local touchSelectConn: RBXScriptConnection? = nil
local touchPanConn: RBXScriptConnection? = nil
local typeToken = 0
local jumpToken = 0
local skipRequested = false
local typingActive = false

local savedCameraType: Enum.CameraType? = nil
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
local soulMarker: TextLabel? = nil

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
		return nil
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

local function bindMoveLock()
	ContextActionService:BindActionAtPriority(
		LOCK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
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

local function lockMovement()
	local hum = getHumanoid()
	if hum then
		savedWalkSpeed = hum.WalkSpeed
		savedJumpPower = hum.JumpPower
		savedJumpHeight = hum.JumpHeight
		savedUseJumpPower = hum.UseJumpPower
		savedAutoRotate = hum.AutoRotate
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
	end
	bindMoveLock()
end

local function unlockMovement()
	unbindMoveLock()
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
	if choiceHoverConn then
		return
	end
	choiceHoverConn = RunService.RenderStepped:Connect(function(dt)
		local anyActive = false
		for _, state in choiceHoverStates do
			local btn = state.btn
			if not btn.Parent then
				continue
			end
			local smooth = math.min(dt * 10, 1)
			if state.hovering then
				anyActive = true
				local absPos = btn.AbsolutePosition
				local absSize = btn.AbsoluteSize
				local centerX = absPos.X + absSize.X * 0.5
				local centerY = absPos.Y + absSize.Y * 0.5
				local mouse = UserInputService:GetMouseLocation()
				local dx = mouse.X - centerX
				local dy = mouse.Y - centerY
				local followX = math.clamp(dx * 0.12, -6, 6)
				local followY = math.clamp(dy * 0.12, -6, 6)
				local tilt = math.clamp(dx * 0.025, -4, 4)
				local goalPos = UDim2.new(
					state.basePos.X.Scale,
					state.basePos.X.Offset + followX,
					state.basePos.Y.Scale,
					state.basePos.Y.Offset + followY
				)
				state.pos = UDim2.new(
					state.pos.X.Scale,
					state.pos.X.Offset + (goalPos.X.Offset - state.pos.X.Offset) * smooth,
					state.pos.Y.Scale,
					state.pos.Y.Offset + (goalPos.Y.Offset - state.pos.Y.Offset) * smooth
				)
				state.rot += (tilt - state.rot) * smooth
				btn.Position = state.pos
				btn.Rotation = state.rot
			else
				local distX = math.abs(state.pos.X.Offset - state.basePos.X.Offset)
				local distY = math.abs(state.pos.Y.Offset - state.basePos.Y.Offset)
				local rotDist = math.abs(state.rot - state.baseRot)
				if distX > 0.05 or distY > 0.05 or rotDist > 0.05 then
					anyActive = true
					state.pos = UDim2.new(
						state.pos.X.Scale,
						state.pos.X.Offset + (state.basePos.X.Offset - state.pos.X.Offset) * smooth,
						state.pos.Y.Scale,
						state.pos.Y.Offset + (state.basePos.Y.Offset - state.pos.Y.Offset) * smooth
					)
					state.rot += (state.baseRot - state.rot) * smooth
					btn.Position = state.pos
					btn.Rotation = state.rot
				else
					btn.Position = state.basePos
					btn.Rotation = state.baseRot
					state.pos = state.basePos
					state.rot = state.baseRot
				end
			end
		end
		if not anyActive and choiceHoverConn then
			local stillHovering = false
			for _, state in choiceHoverStates do
				if state.hovering then
					stillHovering = true
					break
				end
			end
			if not stillHovering then
				local needsSpring = false
				for _, state in choiceHoverStates do
					if
						math.abs(state.pos.X.Offset - state.basePos.X.Offset) > 0.05
						or math.abs(state.pos.Y.Offset - state.basePos.Y.Offset) > 0.05
						or math.abs(state.rot - state.baseRot) > 0.05
					then
						needsSpring = true
						break
					end
				end
				if not needsSpring then
					stopChoiceHover()
				end
			end
		end
	end)
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
	shakeConn = RunService.RenderStepped:Connect(function()
		if not dialogueBox or not base then
			return
		end
		local ox = (math.random() - 0.5) * 10
		local oy = (math.random() - 0.5) * 8
		dialogueBox.Position = UDim2.new(base.X.Scale, base.X.Offset + ox, base.Y.Scale, base.Y.Offset + oy)
	end)
end

local function stopInput()
	pcall(function()
		ContextActionService:UnbindAction(SELECT_ACTION)
	end)
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
end

updateChoiceVisuals = function()
	if not choiceEnter or not choiceExit or not soulMarker then
		return
	end
	if selectedIndex ~= lastHapticSelectedIndex and choicesReady then
		lastHapticSelectedIndex = selectedIndex
		MobileHaptics.select()
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
	local target = if selectedIndex == 1 then choiceEnter else choiceExit
	soulMarker.Position = UDim2.new(
		0,
		-18,
		target.Position.Y.Scale + target.Size.Y.Scale * 0.5,
		target.Position.Y.Offset
	)
	soulMarker.Visible = choicesReady
end

local function requestSkip()
	if typingActive and not choicesReady then
		skipRequested = true
	end
end

local function confirmChoice(enter: boolean)
	if not choicesReady or not resolveChoice then
		return
	end
	selectedIndex = if enter then 1 else 2
	updateChoiceVisuals()
	MobileHaptics.confirm()
	resolveChoice(enter)
end

local function ensureGui(): ScreenGui
	if cutsceneGui and cutsceneGui.Parent and dialogueLabel and choiceEnter and choiceExit and soulMarker and dialogueBox then
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
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.Size = UDim2.new(1.2, 0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.new(0.5, 0, 1, 0)
	bottom.ZIndex = 10
	bottom.Parent = gui

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
	label.TextSize = 22
	label.ZIndex = 31
	UiFonts.applyBody(label)
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
	hint.TextSize = 11
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
	enterBtn.TextSize = 22
	enterBtn.ZIndex = 41
	UiFonts.applyBody(enterBtn)
	styleChoiceButton(enterBtn)
	enterBtn.Parent = choices

	local exitBtn = Instance.new("TextButton")
	exitBtn.Name = "Exit"
	exitBtn.Size = UDim2.new(1, 0, 0.42, 0)
	exitBtn.Position = UDim2.new(0, 0, 0.54, 0)
	exitBtn.Text = "* EXIT"
	exitBtn.TextSize = 22
	exitBtn.ZIndex = 41
	UiFonts.applyBody(exitBtn)
	styleChoiceButton(exitBtn)
	exitBtn.Parent = choices

	local soul = Instance.new("TextLabel")
	soul.Name = "Soul"
	soul.BackgroundTransparency = 1
	soul.Size = UDim2.fromOffset(22, 22)
	soul.AnchorPoint = Vector2.new(1, 0.5)
	soul.Text = "♥"
	soul.TextColor3 = Color3.fromRGB(255, 60, 60)
	soul.TextStrokeTransparency = 0
	soul.TextStrokeColor3 = Color3.new(0, 0, 0)
	soul.TextSize = 20
	soul.Visible = false
	soul.ZIndex = 42
	soul.Parent = choices

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
	dialogueBox = box
	dialogueLabel = label
	skipHint = hint
	choiceEnter = enterBtn
	choiceExit = exitBtn
	soulMarker = soul
	boxShakeBasePos = box.Position
	return gui
end

local function animateLetterboxIn()
	local gui = ensureGui()
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
	skipRequested = false
	label.Text = ""
	refreshSkipHintText()
	if skipHint then
		skipHint.Visible = true
	end
	if line.shake then
		startShake()
	else
		stopShake()
	end

	for i = 1, #fullText do
		if token ~= typeToken or not active or skipRequested then
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
	if skipHint then
		skipHint.Visible = false
	end
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
	savedCameraType = cam.CameraType
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
	if cam and savedCameraType then
		cam.CameraType = savedCameraType
		if savedFov then
			cam.FieldOfView = savedFov
		end
		if savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
	end
	savedCameraType = nil
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
	typeToken += 1
	stopShake()
	stopTalkJump()
	animateLetterboxOut()
	active = false
	endCamera(0.35)
	unlockMovement()
	GameplayUiVisibility.show()
	if dialogueLabel then
		dialogueLabel.Text = ""
	end
	if skipHint then
		skipHint.Visible = false
	end
	if soulMarker then
		soulMarker.Visible = false
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

	local bb = Instance.new("BillboardGui")
	bb.Name = WORLD_SPEECH_NAME
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 80
	bb.Size = UDim2.fromOffset(220, 48)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.Adornee = adornee
	bb.Parent = model

	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextWrapped = true
	label.TextScaled = false
	label.TextSize = 12
	label.TextTransparency = 0
	UiFonts.applyBody(label)
	UiFonts.ensureTextSizeConstraint(label, 12, 10)
	label.Parent = bb

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.Parent = label

	local typeDuration = #message * WORLD_LETTER_DELAY + 0.15
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
			task.wait(WORLD_LETTER_DELAY)
		end
		if token == worldSpeechToken and bb.Parent then
			label.Text = message
		end
	end)

	local holdAfter = if opts and typeof(opts.durationSec) == "number" then opts.durationSec else 1.4
	local dur = math.max(typeDuration + holdAfter, 2.2)
	task.delay(dur, function()
		activeVoicePitchMin = savedPitchMin
		activeVoicePitchMax = savedPitchMax
		if token ~= worldSpeechToken or not bb.Parent then
			return
		end
		TweenService:Create(label, TweenInfo.new(0.25), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 1,
		}):Play()
		task.delay(0.28, function()
			if bb.Parent then
				bb:Destroy()
			end
		end)
	end)
end

function StandDialogueCutscene.isActive(): boolean
	return active
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
	typingActive = false
	selectedIndex = 1
	lastHapticSelectedIndex = 0
	focusModel = brainrot
	basePivot = brainrot:GetPivot()
	activeVoicePitchMin = config.voicePitchMin
	activeVoicePitchMax = config.voicePitchMax

	StandDialogueCutscene.ensureIdleAnimation(brainrot, config.brainrotName)
	ensureGui()
	GameplayUiVisibility.hide({ keepScreenGuiNames = { "StandDialogueCutscene" } })
	animateLetterboxIn()
	lockMovement()
	startCamera(brainrot)
	bindTouchChoiceInput()

	if choiceEnter then
		choiceEnter.Text = "* " .. string.upper(config.enterLabel)
		choiceEnter.Visible = false
	end
	if choiceExit then
		choiceExit.Text = "* EXIT"
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
		if done or not choicesReady then
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
			if typingActive and not choicesReady then
				if
					input.KeyCode == Enum.KeyCode.Return
					or input.KeyCode == Enum.KeyCode.Space
					or input.KeyCode == Enum.KeyCode.ButtonA
				then
					requestSkip()
					return Enum.ContextActionResult.Sink
				end
			end
			if not choicesReady then
				return Enum.ContextActionResult.Pass
			end
			if input.KeyCode == Enum.KeyCode.Up or input.KeyCode == Enum.KeyCode.W then
				selectedIndex = 1
				updateChoiceVisuals()
				return Enum.ContextActionResult.Sink
			elseif input.KeyCode == Enum.KeyCode.Down or input.KeyCode == Enum.KeyCode.S then
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
		Enum.KeyCode.ButtonA
	)

	startTalkJump(brainrot)
	for _, line in ipairs(config.lines) do
		if not active or skipRequested then
			break
		end
		typeLine(line)
		if not active or skipRequested then
			break
		end
		local pauseStart = os.clock()
		while os.clock() - pauseStart < LINE_PAUSE and active and not skipRequested do
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
	lastHapticSelectedIndex = 0
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
