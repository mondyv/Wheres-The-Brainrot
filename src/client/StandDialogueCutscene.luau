-- [ACTIVE] StandDialogueCutscene
--[[
	Undertale-style stand greeting: camera pan, typewriter + Voice Gaster,
	brainrot talk-jump, Enter/Sell/Upgrade + Exit choices.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UiFonts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local GUI_NAME = "StandDialogueCutscene"
local LOCK_ACTION = "StandDialogueMoveLock"
local SELECT_ACTION = "StandDialogueSelect"

local IDLE_ANIM_IDS: { [string]: number } = {
	TatatataSahur = 126404281186060,
	TricTracBarabum = 93169378235673,
	OrangutiniAnanassini = 101569991072351,
}

export type StandDialogueConfig = {
	standName: string,
	frameName: string,
	brainrotName: string,
	enterLabel: string,
	lines: { string },
}

local StandDialogueCutscene = {}

local active = false
local finishing = false
local cameraConn: RBXScriptConnection? = nil
local typeToken = 0
local jumpToken = 0

local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov: number? = nil
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

local hiddenGui: { { inst: GuiObject, wasVisible: boolean } } = {}
local hiddenScreenGui: { { gui: ScreenGui, wasEnabled: boolean } } = {}

local cutsceneGui: ScreenGui? = nil
local letterTop: Frame? = nil
local letterBottom: Frame? = nil
local dialogueLabel: TextLabel? = nil
local choiceEnter: TextButton? = nil
local choiceExit: TextButton? = nil
local soulMarker: TextLabel? = nil

local focusModel: Model? = nil
local basePivot: CFrame? = nil
local blendFromCf: CFrame? = nil
local blendStart = 0
local BLEND_DURATION = 0.75
local selectedIndex = 1 -- 1 = enter, 2 = exit
local choicesReady = false
local resolveChoice: ((choseEnter: boolean) -> ())? = nil

local voiceGasterTemplate: Sound? = nil
local idleTracks: { [Model]: AnimationTrack } = {}

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
	-- Undertale-style: each letter slightly different pitch
	clone.PlaybackSpeed = 0.88 + math.random() * 0.32
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

local function hideGameplayUi()
	table.clear(hiddenGui)
	table.clear(hiddenScreenGui)
	local main = PlayerGuiMain.ensure(player)
	for _, child in main:GetChildren() do
		if child:IsA("GuiObject") then
			local gui = child :: GuiObject
			table.insert(hiddenGui, { inst = gui, wasVisible = gui.Visible })
			gui.Visible = false
		end
	end
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, ch in pg:GetChildren() do
			if ch:IsA("ScreenGui") and ch.Name ~= GUI_NAME and ch.Name ~= "FloatingClaimCutscene" and ch.Name ~= "BushSpiderCutscene" then
				table.insert(hiddenScreenGui, { gui = ch, wasEnabled = ch.Enabled })
				ch.Enabled = false
			end
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
	end)
end

local function restoreGameplayUi()
	for _, entry in hiddenGui do
		if entry.inst.Parent then
			entry.inst.Visible = entry.wasVisible
		end
	end
	for _, entry in hiddenScreenGui do
		if entry.gui.Parent then
			if entry.gui.Name == "Main" then
				entry.gui.Enabled = true
			else
				entry.gui.Enabled = entry.wasEnabled
			end
		end
	end
	table.clear(hiddenGui)
	table.clear(hiddenScreenGui)
	local pg = player:FindFirstChild("PlayerGui")
	local main = pg and pg:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
	end)
end

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

local function stopInput()
	pcall(function()
		ContextActionService:UnbindAction(SELECT_ACTION)
	end)
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

local function updateChoiceVisuals()
	if not choiceEnter or not choiceExit or not soulMarker then
		return
	end
	choiceEnter.TextColor3 = if selectedIndex == 1 then Color3.fromRGB(255, 255, 0) else Color3.fromRGB(255, 255, 255)
	choiceExit.TextColor3 = if selectedIndex == 2 then Color3.fromRGB(255, 255, 0) else Color3.fromRGB(255, 255, 255)
	local target = if selectedIndex == 1 then choiceEnter else choiceExit
	soulMarker.Position = UDim2.new(
		target.Position.X.Scale,
		target.Position.X.Offset - 28,
		target.Position.Y.Scale,
		target.Position.Y.Offset
	)
	soulMarker.Visible = choicesReady
end

local function ensureGui(): ScreenGui
	if cutsceneGui and cutsceneGui.Parent and dialogueLabel and choiceEnter and choiceExit and soulMarker then
		return cutsceneGui
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
		cutsceneGui = nil
	end

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

	local box = Instance.new("Frame")
	box.Name = "DialogueBox"
	box.BackgroundColor3 = Color3.new(0, 0, 0)
	box.BorderColor3 = Color3.new(1, 1, 1)
	box.BorderSizePixel = 4
	box.AnchorPoint = Vector2.new(0.5, 1)
	box.Position = UDim2.new(0.5, 0, 0.92, 0)
	box.Size = UDim2.new(0.72, 0, 0.18, 0)
	box.ZIndex = 30
	box.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = box

	local label = Instance.new("TextLabel")
	label.Name = "DialogueText"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.TextSize = 22
	label.ZIndex = 31
	UiFonts.applyBody(label)
	label.Parent = box

	local choices = Instance.new("Frame")
	choices.Name = "Choices"
	choices.BackgroundTransparency = 1
	choices.AnchorPoint = Vector2.new(1, 0.5)
	choices.Position = UDim2.new(0.96, 0, 0.48, 0)
	choices.Size = UDim2.new(0.22, 0, 0.22, 0)
	choices.ZIndex = 40
	choices.Parent = gui

	local enterBtn = Instance.new("TextButton")
	enterBtn.Name = "Enter"
	enterBtn.BackgroundTransparency = 1
	enterBtn.Size = UDim2.new(1, 0, 0.4, 0)
	enterBtn.Position = UDim2.new(0, 0, 0.05, 0)
	enterBtn.Text = "* ENTER"
	enterBtn.TextColor3 = Color3.new(1, 1, 1)
	enterBtn.TextXAlignment = Enum.TextXAlignment.Left
	enterBtn.TextSize = 24
	enterBtn.AutoButtonColor = false
	enterBtn.ZIndex = 41
	UiFonts.applyBody(enterBtn)
	enterBtn.Parent = choices

	local exitBtn = Instance.new("TextButton")
	exitBtn.Name = "Exit"
	exitBtn.BackgroundTransparency = 1
	exitBtn.Size = UDim2.new(1, 0, 0.4, 0)
	exitBtn.Position = UDim2.new(0, 0, 0.55, 0)
	exitBtn.Text = "* EXIT"
	exitBtn.TextColor3 = Color3.new(1, 1, 1)
	exitBtn.TextXAlignment = Enum.TextXAlignment.Left
	exitBtn.TextSize = 24
	exitBtn.AutoButtonColor = false
	exitBtn.ZIndex = 41
	UiFonts.applyBody(exitBtn)
	exitBtn.Parent = choices

	local soul = Instance.new("TextLabel")
	soul.Name = "Soul"
	soul.BackgroundTransparency = 1
	soul.Size = UDim2.fromOffset(22, 22)
	soul.AnchorPoint = Vector2.new(0.5, 0.5)
	soul.Text = "♥"
	soul.TextColor3 = Color3.fromRGB(255, 60, 60)
	soul.TextSize = 20
	soul.Visible = false
	soul.ZIndex = 42
	soul.Parent = choices

	enterBtn.MouseEnter:Connect(function()
		if choicesReady then
			selectedIndex = 1
			updateChoiceVisuals()
		end
	end)
	exitBtn.MouseEnter:Connect(function()
		if choicesReady then
			selectedIndex = 2
			updateChoiceVisuals()
		end
	end)
	enterBtn.Activated:Connect(function()
		if choicesReady and resolveChoice then
			selectedIndex = 1
			resolveChoice(true)
		end
	end)
	exitBtn.Activated:Connect(function()
		if choicesReady and resolveChoice then
			selectedIndex = 2
			resolveChoice(false)
		end
	end)

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	dialogueLabel = label
	choiceEnter = enterBtn
	choiceExit = exitBtn
	soulMarker = soul
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

local function typeLine(fullText: string)
	local label = dialogueLabel
	if not label then
		return
	end
	typeToken += 1
	local token = typeToken
	label.Text = ""
	local chars = {}
	for i = 1, #fullText do
		table.insert(chars, string.sub(fullText, i, i))
	end
	for i, ch in ipairs(chars) do
		if token ~= typeToken or not active then
			return
		end
		label.Text = string.sub(fullText, 1, i)
		if ch ~= " " and ch ~= "\n" then
			playVoiceLetter()
		end
		task.wait(0.035)
	end
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

		-- Over-shoulder from the player's right so character stays left-ish, choices read on the right
		local camPos = mid - toNpc * (7.2 + npcRadius * 0.15) + right * 3.4 + Vector3.new(0, 2.35, 0)
		camPos += Vector3.new(math.sin(phase * 1.1) * 0.05, math.sin(phase * 0.9) * 0.04, 0)
		local lookAt = mid + Vector3.new(0, 0.2, 0) + right * 0.4
		local goalCf = CFrame.lookAt(camPos, lookAt)
		local goalFov = (savedFov or 70) - 4

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
	stopInput()
	typeToken += 1
	stopTalkJump()
	animateLetterboxOut()
	active = false
	endCamera(0.35)
	unlockMovement()
	restoreGameplayUi()
	if dialogueLabel then
		dialogueLabel.Text = ""
	end
	if soulMarker then
		soulMarker.Visible = false
	end
	focusModel = nil
	basePivot = nil
	finishing = false
	return choseEnter
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

--[[
	Runs the stand dialogue. Returns true if player chose Enter/Sell/Upgrade.
]]
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
	selectedIndex = 1
	focusModel = brainrot
	basePivot = brainrot:GetPivot()

	StandDialogueCutscene.ensureIdleAnimation(brainrot, config.brainrotName)
	ensureGui()
	hideGameplayUi()
	animateLetterboxIn()
	lockMovement()
	startCamera(brainrot)

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
			if not choicesReady or state ~= Enum.UserInputState.Begin then
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
				if resolveChoice then
					resolveChoice(selectedIndex == 1)
				end
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
		if not active then
			break
		end
		typeLine(line)
		if not active then
			break
		end
		task.wait(0.15)
	end
	stopTalkJump()

	if not active then
		return false
	end

	if choiceEnter and choiceExit then
		choiceEnter.Visible = true
		choiceExit.Visible = true
	end
	choicesReady = true
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
