-- [ACTIVE] BushSpiderEncounterController
--[[
	Spider ambush after accepting a floating bush brainrot: drop-in, rage, slow-mo web,
	rhythm letter QTE (shrinking ring), death on fail.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local LandAmbushUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandAmbushUtil"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local SpiderEncounterConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpiderEncounterConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local C = SpiderEncounterConfig
local player = Players.LocalPlayer

local BushSpiderEncounterController = {}

local encounterActive = false
local hiddenGui: { { inst: GuiObject, wasVisible: boolean } } = {}
local hiddenScreenGui: { { gui: ScreenGui, wasEnabled: boolean } } = {}
local bgmSpeedSaved: { [Sound]: number } = {}
local bgmSpeedTweens: { [Sound]: Tween } = {}
local cutsceneGui: ScreenGui? = nil
local letterTop: Frame? = nil
local letterBottom: Frame? = nil
local timingRoot: Frame? = nil
local timingRing: Frame? = nil
local timingRingScale: UIScale? = nil
local timingRingStroke: UIStroke? = nil
local timingPulseRing: Frame? = nil
local timingPulseScale: UIScale? = nil
local timingTargetRing: Frame? = nil
local timingLetter: TextLabel? = nil
local timingHint: TextLabel? = nil
local timingRootScale: UIScale? = nil
local timingPulseConn: RBXScriptConnection? = nil
local colorFx: ColorCorrectionEffect? = nil
local blurFx: BlurEffect? = nil
local cameraConn: RBXScriptConnection? = nil
local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov = 70
local defaultFov = 70
local dodgeResolved = false
local spiderKillRE: RemoteEvent? = nil

local GREEN_OK = Color3.fromRGB(70, 255, 130)
local RED_FAIL = Color3.fromRGB(255, 55, 55)
local RING_IDLE = Color3.fromRGB(255, 235, 120)

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function ringScaleForEased(eased: number): number
	return C.RING_START_SCALE + (C.RING_CLOSED_SCALE - C.RING_START_SCALE) * eased
end

local function getPlayerHRP(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function cfFacingTarget(fromPos: Vector3, targetPos: Vector3): CFrame
	local flatTarget = Vector3.new(targetPos.X, fromPos.Y, targetPos.Z)
	if (flatTarget - fromPos).Magnitude < 0.05 then
		return CFrame.new(fromPos)
	end
	return CFrame.lookAt(fromPos, flatTarget) * CFrame.Angles(0, C.SPIDER_YAW_OFFSET, 0)
end

local function faceCharacterToward(targetPos: Vector3)
	local hrp = getPlayerHRP()
	if not hrp then
		return
	end
	local flatTarget = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z)
	if (flatTarget - hrp.Position).Magnitude < 0.05 then
		return
	end
	hrp.CFrame = CFrame.lookAt(hrp.Position, flatTarget)
end

local function resolveSpiderSpawnPosition(fallbackAnchor: Vector3): Vector3
	local hrp = getPlayerHRP()
	local playerPos = if hrp then hrp.Position else fallbackAnchor
	local landPos = LandAmbushUtil.pickAmbushForPlayer(
		playerPos,
		C.SPIDER_MIN_PLAYER_DISTANCE,
		C.SPIDER_MAX_PLAYER_DISTANCE,
		C.LAND_EDGE_MARGIN
	)
	if landPos then
		return landPos
	end

	local away = fallbackAnchor - playerPos
	local flat = Vector3.new(away.X, 0, away.Z)
	if flat.Magnitude < C.SPIDER_MIN_PLAYER_DISTANCE then
		local dir = if flat.Magnitude > 0.05 then flat.Unit else Vector3.new(1, 0, 0)
		return playerPos + dir * C.SPIDER_MIN_PLAYER_DISTANCE + Vector3.new(0, 2, 0)
	end
	return playerPos + flat.Unit * C.SPIDER_MIN_PLAYER_DISTANCE + Vector3.new(0, 2, 0)
end

local function waitSec(sec: number)
	task.wait(sec)
end

local function findSpiderTemplate(): Model?
	local node: Instance = ReplicatedStorage
	for _, name in C.SPIDER_TEMPLATE_PATH do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	if node:IsA("Model") then
		return node :: Model
	end
	return nil
end

local function resolveAnimator(model: Model): Animator?
	local controller = model:FindFirstChildOfClass("AnimationController")
	if controller then
		local animator = controller:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = controller
		end
		return animator
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		return animator
	end
	return nil
end

local function loadTrack(animator: Animator, assetId: string): AnimationTrack?
	local anim = Instance.new("Animation")
	anim.AnimationId = if string.find(assetId, "rbxassetid://", 1, true)
		then assetId
		else "rbxassetid://" .. assetId
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if ok and track then
		return track
	end
	return nil
end

local function flatUnitXZ(fromPos: Vector3, toPos: Vector3): Vector3
	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function waitForRageSequence(
	spider: Model,
	rageTrack: AnimationTrack?,
	playerAimFn: () -> Vector3
): number
	if rageTrack then
		rageTrack.Priority = Enum.AnimationPriority.Action4
		rageTrack.Looped = false
		rageTrack:Play(0.1, 1, 1)
	end

	local duration = if rageTrack and rageTrack.Length > 0.05 then rageTrack.Length else C.RAGE_FALLBACK_SEC
	local started = os.clock()
	while os.clock() - started < duration and encounterActive do
		local aim = playerAimFn()
		spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, aim))
		RunService.RenderStepped:Wait()
	end
	return duration
end

local function waitForWebShootWindup(
	spider: Model,
	webTrack: AnimationTrack?,
	playerAimFn: () -> Vector3
): number
	local aim = playerAimFn()
	faceCharacterToward(spider:GetPivot().Position)
	spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, aim))

	if not webTrack then
		waitSec(C.WEB_ANIM_FALLBACK_SEC)
		return C.WEB_ANIM_FALLBACK_SEC
	end

	webTrack.Priority = Enum.AnimationPriority.Action4
	webTrack.Looped = false
	webTrack:Play(0.12, 1, 1)

	local length = webTrack.Length
	local windup = if length > 0.05 then length * C.WEB_SHOOT_AT else C.WEB_ANIM_FALLBACK_SEC
	local started = os.clock()
	while os.clock() - started < windup and encounterActive do
		local aim = playerAimFn()
		spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, aim))
		RunService.RenderStepped:Wait()
	end
	return windup
end

local function collectBgmSounds(): { Sound }
	local out: { Sound } = {}
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	local sg = bg and bg:FindFirstChild("SoundGroup")
	if not sg then
		return out
	end
	for _, child in sg:GetChildren() do
		if child:IsA("Sound") then
			table.insert(out, child)
		elseif child:IsA("Folder") then
			for _, snd in child:GetChildren() do
				if snd:IsA("Sound") then
					table.insert(out, snd)
				end
			end
		end
	end
	return out
end

local function forceRestoreBgm()
	for _, s in collectBgmSounds() do
		if not s.Parent then
			continue
		end
		local tw = bgmSpeedTweens[s]
		if tw then
			tw:Cancel()
			bgmSpeedTweens[s] = nil
		end
		s.PlaybackSpeed = bgmSpeedSaved[s] or 1
		bgmSpeedSaved[s] = nil
	end
end

local function setBgmSlowed(slowed: boolean)
	for _, s in collectBgmSounds() do
		if not s.Parent then
			continue
		end
		local tw = bgmSpeedTweens[s]
		if tw then
			tw:Cancel()
			bgmSpeedTweens[s] = nil
		end
		if slowed then
			if bgmSpeedSaved[s] == nil then
				bgmSpeedSaved[s] = s.PlaybackSpeed
			end
			local tween = TweenService:Create(
				s,
				TweenInfo.new(C.BGM_SLOW_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ PlaybackSpeed = C.BGM_SLOW_SPEED }
			)
			bgmSpeedTweens[s] = tween
			tween:Play()
		else
			forceRestoreBgm()
			return
		end
	end
end

local function setBgmWebSlow()
	for _, s in collectBgmSounds() do
		if not s.Parent then
			continue
		end
		local tw = bgmSpeedTweens[s]
		if tw then
			tw:Cancel()
			bgmSpeedTweens[s] = nil
		end
		if bgmSpeedSaved[s] == nil then
			bgmSpeedSaved[s] = s.PlaybackSpeed
		end
		TweenService:Create(
			s,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ PlaybackSpeed = C.BGM_SLOW_SPEED * C.WEB_SLOW_TIME_SCALE }
		):Play()
	end
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
			if ch:IsA("ScreenGui") and ch.Name ~= "BushSpiderCutscene" then
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
			entry.gui.Enabled = entry.wasEnabled
		end
	end
	table.clear(hiddenGui)
	table.clear(hiddenScreenGui)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
	end)
end

local function ensureCutsceneGui(): ScreenGui
	if cutsceneGui and cutsceneGui.Parent then
		return cutsceneGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "BushSpiderCutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 950
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.Size = UDim2.new(1, 0, 0, 0)
	top.Position = UDim2.fromScale(0, 0)
	top.ZIndex = 20
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.Size = UDim2.new(1, 0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.ZIndex = 20
	bottom.Parent = gui

	local qte = Instance.new("Frame")
	qte.Name = "TimingQTE"
	qte.AnchorPoint = Vector2.new(0.5, 0.5)
	qte.Position = UDim2.fromScale(0.5, 0.56)
	qte.Size = UDim2.fromOffset(210, 210)
	qte.BackgroundTransparency = 1
	qte.Visible = false
	qte.ZIndex = 40
	qte.Parent = gui

	local qteScale = Instance.new("UIScale")
	qteScale.Scale = 1
	qteScale.Parent = qte

	local pulse = Instance.new("Frame")
	pulse.Name = "PulseRing"
	pulse.AnchorPoint = Vector2.new(0.5, 0.5)
	pulse.Position = UDim2.fromScale(0.5, 0.5)
	pulse.Size = UDim2.fromOffset(200, 200)
	pulse.BackgroundTransparency = 1
	pulse.ZIndex = 41
	pulse.Parent = qte
	local pulseStroke = Instance.new("UIStroke")
	pulseStroke.Color = Color3.fromRGB(255, 220, 120)
	pulseStroke.Thickness = 2
	pulseStroke.Transparency = 0.55
	pulseStroke.Parent = pulse
	local pulseCorner = Instance.new("UICorner")
	pulseCorner.CornerRadius = UDim.new(1, 0)
	pulseCorner.Parent = pulse
	local pulseScale = Instance.new("UIScale")
	pulseScale.Scale = 1.55
	pulseScale.Parent = pulse

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(170, 170)
	ring.BackgroundColor3 = Color3.fromRGB(10, 10, 16)
	ring.BackgroundTransparency = 0.25
	ring.ZIndex = 42
	ring.Parent = qte
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Color = RING_IDLE
	ringStroke.Thickness = 5
	ringStroke.Transparency = 0.05
	ringStroke.Parent = ring
	local ringGrad = Instance.new("UIGradient")
	ringGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 160)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 200, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 240, 160)),
	})
	ringGrad.Rotation = 35
	ringGrad.Parent = ringStroke
	local ringScale = Instance.new("UIScale")
	ringScale.Scale = 1.42
	ringScale.Parent = ring

	local target = Instance.new("Frame")
	target.Name = "TargetRing"
	target.AnchorPoint = Vector2.new(0.5, 0.5)
	target.Position = UDim2.fromScale(0.5, 0.5)
	target.Size = UDim2.fromOffset(108, 108)
	target.BackgroundTransparency = 1
	target.ZIndex = 43
	target.Parent = qte
	local targetStroke = Instance.new("UIStroke")
	targetStroke.Color = Color3.fromRGB(255, 255, 255)
	targetStroke.Thickness = 2
	targetStroke.Transparency = 0.35
	targetStroke.Parent = target
	local targetCorner = Instance.new("UICorner")
	targetCorner.CornerRadius = UDim.new(1, 0)
	targetCorner.Parent = target

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.fromOffset(96, 96)
	inner.BackgroundColor3 = Color3.fromRGB(14, 14, 22)
	inner.BackgroundTransparency = 0.08
	inner.ZIndex = 44
	inner.Parent = qte
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(1, 0)
	innerCorner.Parent = inner
	local innerStroke = Instance.new("UIStroke")
	innerStroke.Color = Color3.fromRGB(255, 245, 200)
	innerStroke.Thickness = 2
	innerStroke.Transparency = 0.2
	innerStroke.Parent = inner

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Letter"
	keyLabel.Size = UDim2.fromScale(1, 0.62)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Text = "E"
	keyLabel.TextColor3 = Color3.fromRGB(255, 248, 220)
	UiFonts.applyDisplayLabel(keyLabel, 58, 34)
	keyLabel.ZIndex = 45
	keyLabel.Parent = inner

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Size = UDim2.new(1, 0, 0.34, 0)
	hint.Position = UDim2.fromScale(0, 0.64)
	hint.BackgroundTransparency = 1
	hint.Text = "HIT"
	hint.TextColor3 = Color3.fromRGB(200, 205, 220)
	UiFonts.applyButtonLabel(hint, 13, 10)
	hint.ZIndex = 45
	hint.Parent = inner

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	timingRoot = qte
	timingRing = ring
	timingRingScale = ringScale
	timingRingStroke = ringStroke
	timingPulseRing = pulse
	timingPulseScale = pulseScale
	timingTargetRing = target
	timingLetter = keyLabel
	timingHint = hint
	timingRootScale = qteScale
	return gui
end

local function animateLetterboxIn()
	local gui = ensureCutsceneGui()
	gui.Enabled = true
	if letterTop and letterBottom then
		TweenService:Create(letterTop, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = UDim2.new(1, 0, 0.11, 0),
		}):Play()
		TweenService:Create(letterBottom, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = UDim2.new(1, 0, 0.11, 0),
		}):Play()
	end
end

local function animateLetterboxOut()
	if letterTop and letterBottom then
		TweenService:Create(letterTop, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(1, 0, 0, 0),
		}):Play()
		TweenService:Create(letterBottom, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(1, 0, 0, 0),
		}):Play()
	end
	if cutsceneGui then
		task.delay(0.38, function()
			if cutsceneGui then
				cutsceneGui.Enabled = false
			end
		end)
	end
end

local function ensurePostFx()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if not colorFx then
		colorFx = Instance.new("ColorCorrectionEffect")
		colorFx.Name = "BushSpiderColor"
		colorFx.Parent = cam
	end
	if not blurFx then
		blurFx = Instance.new("BlurEffect")
		blurFx.Name = "BushSpiderBlur"
		blurFx.Parent = cam
	end
	colorFx.Enabled = true
	blurFx.Enabled = true
	TweenService:Create(colorFx, TweenInfo.new(0.4), {
		Brightness = -0.12,
		Contrast = 0.18,
		Saturation = -0.25,
		TintColor = Color3.fromRGB(200, 210, 230),
	}):Play()
	TweenService:Create(blurFx, TweenInfo.new(0.4), { Size = 6 }):Play()
end

local function clearPostFx()
	if colorFx then
		TweenService:Create(colorFx, TweenInfo.new(0.35), {
			Brightness = 0,
			Contrast = 0,
			Saturation = 0,
			TintColor = Color3.new(1, 1, 1),
		}):Play()
		task.delay(0.36, function()
			if colorFx then
				colorFx.Enabled = false
			end
		end)
	end
	if blurFx then
		TweenService:Create(blurFx, TweenInfo.new(0.35), { Size = 0 }):Play()
		task.delay(0.36, function()
			if blurFx then
				blurFx.Enabled = false
			end
		end)
	end
end

local function saveCameraState(cam: Camera)
	if not savedCameraType then
		savedCameraType = cam.CameraType
		savedCameraSubject = cam.CameraSubject
		savedFov = cam.FieldOfView
		defaultFov = cam.FieldOfView
	end
	cam.CameraType = Enum.CameraType.Scriptable
end

local function stopCameraRig()
	if cameraConn then
		cameraConn:Disconnect()
		cameraConn = nil
	end
end

local function wobbleCFrame(base: CFrame, phase: number, intensity: number): CFrame
	return base
		* CFrame.Angles(
			math.sin(phase * 9.5) * 0.04 * intensity,
			math.cos(phase * 7.2) * 0.032 * intensity,
			math.sin(phase * 11.3) * 0.022 * intensity
		)
end

local function beginSpiderDropCamera(getSpiderPos: () -> Vector3, intensity: number)
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	saveCameraState(cam)

	local phase = 0
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not cam then
			return
		end
		phase += dt
		local spiderPos = getSpiderPos()
		local offset = Vector3.new(
			math.sin(phase * 1.6) * 5,
			5 + math.sin(phase * 2.8) * 1.2,
			14 + math.cos(phase * 1.1) * 3
		)
		local camPos = spiderPos + offset
		local lookAt = spiderPos + Vector3.new(0, 2.5, 0)
		cam.CFrame = wobbleCFrame(CFrame.lookAt(camPos, lookAt), phase, intensity)
		cam.FieldOfView = defaultFov + 6 + math.sin(phase * 4) * 3 * intensity
	end)
end

local function beginRageCamera(
	getSpiderPos: () -> Vector3,
	getPlayerPos: () -> Vector3,
	intensity: number
)
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	saveCameraState(cam)

	local phase = 0
	local zoomFov = C.RAGE_CAMERA_ZOOM_FOV

	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not cam then
			return
		end
		phase += dt

		local spiderPos = getSpiderPos()
		local playerPos = getPlayerPos()
		local lookTarget = spiderPos + Vector3.new(0, 2.4, 0)
		local between = flatUnitXZ(spiderPos, playerPos)
		local right = between:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local mid = spiderPos:Lerp(playerPos, 0.32)
		local pullBack = 19 + intensity * 6 + math.sin(phase * 2.2) * 3
		local height = 7 + math.sin(phase * 3.4) * 2
		local side = math.sin(phase * 1.35) * 6 * intensity
		local camPos = mid - between * pullBack + right * side + Vector3.new(0, height, 0)

		cam.CFrame = wobbleCFrame(CFrame.lookAt(camPos, lookTarget), phase, intensity * 1.15)
		cam.FieldOfView = defaultFov + zoomFov + math.sin(phase * 5.2) * 3.5
	end)
end

local function beginWebWindupCamera(getSpiderPos: () -> Vector3, getPlayerPos: () -> Vector3)
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local phase = 0
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not cam then
			return
		end
		phase += dt

		local spiderPos = getSpiderPos()
		local playerPos = getPlayerPos()
		local toPlayer = flatUnitXZ(spiderPos, playerPos)
		local right = toPlayer:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local lookTarget = spiderPos + Vector3.new(0, 2.1, 0) + toPlayer * 1.2
		local camPos = spiderPos
			- toPlayer * (7.5 + math.sin(phase * 2.8) * 0.6)
			+ right * (2.8 + math.cos(phase * 2.1) * 0.5)
			+ Vector3.new(0, 1.35 + math.sin(phase * 4.5) * 0.25, 0)

		cam.CFrame = wobbleCFrame(CFrame.lookAt(camPos, lookTarget), phase, 0.5)
		cam.FieldOfView = defaultFov + 6 + math.sin(phase * 7) * 1.5
	end)
end

local function beginWebFollowCamera(getWebPos: () -> Vector3, getTargetPos: () -> Vector3, intensity: number)
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	saveCameraState(cam)

	local phase = 0
	local side = if math.random() < 0.5 then 1 else -1

	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not cam then
			return
		end
		phase += dt
		local webPos = getWebPos()
		local targetPos = getTargetPos()
		local toTarget = targetPos - webPos
		if toTarget.Magnitude < 0.05 then
			toTarget = Vector3.new(0, 0, -1)
		else
			toTarget = toTarget.Unit
		end
		local lateral = toTarget:Cross(Vector3.yAxis)
		if lateral.Magnitude < 0.05 then
			lateral = Vector3.new(side, 0, 0)
		else
			lateral = lateral.Unit * side
		end
		local camPos = webPos
			- toTarget * (8 + math.sin(phase * 3) * 1.5)
			+ lateral * (5 + math.cos(phase * 2.4) * 1.2)
			+ Vector3.new(0, 2.4 + math.sin(phase * 5) * 0.6, 0)
		cam.CFrame = wobbleCFrame(CFrame.lookAt(camPos, webPos + toTarget * 2.5), phase, intensity)
		cam.FieldOfView = defaultFov + 12 + math.sin(phase * 6) * 2.5
	end)
end

local function restoreCamera()
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	TweenService:Create(cam, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FieldOfView = savedFov,
	}):Play()
	if savedCameraType then
		cam.CameraType = savedCameraType
	else
		cam.CameraType = Enum.CameraType.Custom
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
	if savedCameraSubject then
		cam.CameraSubject = savedCameraSubject
	end
	savedCameraType = nil
	savedCameraSubject = nil
end

local function pulseCameraShake(duration: number, amp: number)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local endAt = os.clock() + duration
	local token = {}
	local activeToken = token
	task.spawn(function()
		while os.clock() < endAt and encounterActive and activeToken == token do
			local t = os.clock()
			local fade = math.clamp((endAt - t) / duration, 0, 1)
			hum.CameraOffset = Vector3.new(
				math.sin(t * 38) * amp * fade,
				math.cos(t * 31) * amp * 0.55 * fade,
				math.sin(t * 27) * amp * 0.35 * fade
			)
			RunService.RenderStepped:Wait()
		end
		if activeToken == token and hum.Parent then
			hum.CameraOffset = Vector3.zero
		end
	end)
end

local function stabilizeSpiderModel(model: Model)
	local primary = model.PrimaryPart
	if not primary then
		primary = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart", true)
		if primary and primary:IsA("BasePart") then
			model.PrimaryPart = primary
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d == primary
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function fadeSpider(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
		elseif d:IsA("Decal") or d:IsA("Texture") then
			TweenService:Create(d, TweenInfo.new(0.55), { Transparency = 1 }):Play()
		end
	end
end

local function hideTimingQTE()
	if timingPulseConn then
		timingPulseConn:Disconnect()
		timingPulseConn = nil
	end
	if timingRoot then
		timingRoot.Visible = false
	end
end

local function pickRandomQtePosition()
	if not timingRoot then
		return
	end
	local x = 0.22 + math.random() * 0.56
	local y = 0.34 + math.random() * 0.34
	timingRoot.Position = UDim2.fromScale(x, y)
end

local function startTimingPulse()
	if timingPulseConn then
		timingPulseConn:Disconnect()
	end
	if not timingPulseScale then
		return
	end
	local phase = 0
	timingPulseConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not timingRoot or not timingRoot.Visible then
			return
		end
		phase += dt
		if timingPulseScale then
			timingPulseScale.Scale = 1.35 + math.sin(phase * 7) * 0.08
		end
		if timingRingStroke then
			timingRingStroke.Transparency = 0.04 + math.sin(phase * 9) * 0.08
		end
	end)
end

local function flashTimingResult(success: boolean)
	if not timingRingStroke or not timingLetter or not timingRootScale or not timingRingScale then
		return
	end

	local color = if success then GREEN_OK else RED_FAIL
	timingRingStroke.Color = color
	timingLetter.TextColor3 = color

	if success then
		TweenService:Create(timingRingScale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = C.RING_CLOSED_SCALE,
		}):Play()
		TweenService:Create(timingRootScale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1.12,
		}):Play()
	else
		local shakeToken = {}
		local token = shakeToken
		task.spawn(function()
			for i = 1, 8 do
				if token ~= shakeToken or not timingRootScale then
					break
				end
				timingRootScale.Scale = 1 + (if i % 2 == 0 then 0.08 else -0.06)
				RunService.RenderStepped:Wait()
			end
			if timingRootScale then
				timingRootScale.Scale = 1
			end
		end)
		pulseCameraShake(0.45, 0.22)
		GameSoundEffects.playErrorNotif()
	end
end

local function playDodgeMove()
	local hrp = getPlayerHRP()
	if not hrp then
		return
	end
	local cam = Workspace.CurrentCamera
	local right = if cam then cam.CFrame.RightVector else Vector3.new(1, 0, 0)
	local flat = Vector3.new(right.X, 0, right.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(1, 0, 0)
	else
		flat = flat.Unit
	end
	if math.random() < 0.5 then
		flat = -flat
	end
	local goal = hrp.CFrame + flat * 7 + Vector3.new(0, 0.4, 0)
	TweenService:Create(hrp, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = goal,
	}):Play()
	pulseCameraShake(0.25, 0.12)
end

local function tweenSpiderDrop(spider: Model, fromPos: Vector3, toPos: Vector3, faceTarget: Vector3, duration: number)
	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local tween = TweenService:Create(nv, TweenInfo.new(duration, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {
		Value = 1,
	})
	local conn = nv.Changed:Connect(function()
		local pos = fromPos:Lerp(toPos, nv.Value)
		spider:PivotTo(cfFacingTarget(pos, faceTarget))
	end)
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	nv:Destroy()
end

local function finishEncounter(spider: Model?, web: BasePart?)
	encounterActive = false
	hideTimingQTE()
	forceRestoreBgm()
	clearPostFx()
	animateLetterboxOut()
	restoreCamera()
	restoreGameplayUi()

	if spider and spider.Parent then
		spider:Destroy()
	end
	if web and web.Parent then
		web:Destroy()
	end
end

local function killPlayerFromSpiderHit()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	hum.BreakJointsOnDeath = true
	if spiderKillRE then
		spiderKillRE:FireServer()
	end
	hum.Health = 0
	if char and char.Parent and hum.Health <= 0 then
		char:BreakJoints()
	end
end

local function getPlayerAimPos(fallback: Vector3): Vector3
	local hrp = getPlayerHRP()
	return if hrp then hrp.Position + Vector3.new(0, 1.2, 0) else fallback
end

local function runEncounter(fallbackAnchor: Vector3)
	local template = findSpiderTemplate()
	if not template then
		warn("[BushSpiderEncounterController] EssentialAssets.Spider missing")
		return
	end

	encounterActive = true
	dodgeResolved = false
	savedCameraType = nil
	savedCameraSubject = nil

	hideGameplayUi()
	animateLetterboxIn()
	ensurePostFx()
	setBgmSlowed(true)

	local landPos = resolveSpiderSpawnPosition(fallbackAnchor)
	local playerAim = getPlayerAimPos(fallbackAnchor)
	local dropStart = landPos + Vector3.new(0, C.DROP_HEIGHT, 0)
	local hrp = getPlayerHRP()
	if hrp then
		local ceiling = workspace:Raycast(dropStart, Vector3.new(0, 40, 0))
		if ceiling then
			dropStart = Vector3.new(landPos.X, ceiling.Position.Y - 3, landPos.Z)
		end
		local maxDropY = hrp.Position.Y + 28
		if dropStart.Y > maxDropY then
			dropStart = Vector3.new(dropStart.X, maxDropY, dropStart.Z)
		end
	end

	local spider = template:Clone()
	spider.Name = "BushSpiderEncounter"
	stabilizeSpiderModel(spider)
	spider:PivotTo(cfFacingTarget(dropStart, playerAim))
	spider.Parent = Workspace

	beginSpiderDropCamera(function()
		return spider:GetPivot().Position
	end, 1.1)
	pulseCameraShake(0.35, 0.08)

	local animator = resolveAnimator(spider)
	local jumpTrack = if animator then loadTrack(animator, C.ANIM.JUMP) else nil
	local rageTrack = if animator then loadTrack(animator, C.ANIM.RAGE) else nil
	local webTrack = if animator then loadTrack(animator, C.ANIM.WEB) else nil

	if jumpTrack then
		jumpTrack:Play(0.05, 1, 1)
	end
	tweenSpiderDrop(spider, dropStart, landPos, playerAim, 0.85)

	if not encounterActive then
		finishEncounter(spider, nil)
		return
	end

	waitSec(0.15)
	GameSoundEffects.playErrorNotif()
	pulseCameraShake(0.55, 0.16)
	playerAim = getPlayerAimPos(fallbackAnchor)
	faceCharacterToward(landPos)
	spider:PivotTo(cfFacingTarget(landPos, playerAim))
	beginRageCamera(function()
		return spider:GetPivot().Position
	end, function()
		return getPlayerAimPos(fallbackAnchor)
	end, 1.4)
	waitForRageSequence(spider, rageTrack, function()
		return getPlayerAimPos(fallbackAnchor)
	end)

	if not encounterActive then
		finishEncounter(spider, nil)
		return
	end

	if rageTrack then
		rageTrack:Stop(0.2)
	end

	beginWebWindupCamera(function()
		return spider:GetPivot().Position
	end, function()
		return getPlayerAimPos(fallbackAnchor)
	end)
	waitForWebShootWindup(spider, webTrack, function()
		return getPlayerAimPos(fallbackAnchor)
	end)

	if not encounterActive then
		finishEncounter(spider, nil)
		return
	end

	playerAim = getPlayerAimPos(fallbackAnchor)
	faceCharacterToward(spider:GetPivot().Position)
	spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, playerAim))

	local web = Instance.new("Part")
	web.Name = "SpiderWebShot"
	web.Size = C.WEB_PROJECTILE_SIZE
	web.Shape = Enum.PartType.Ball
	web.Material = Enum.Material.SmoothPlastic
	web.Color = Color3.fromRGB(235, 235, 245)
	web.Anchored = true
	web.CanCollide = false
	web.CanQuery = false
	web.CanTouch = false
	web.Transparency = 0.08
	web.Parent = Workspace
	local webMesh = Instance.new("SpecialMesh")
	webMesh.MeshType = Enum.MeshType.Sphere
	webMesh.Scale = Vector3.new(1.1, 1.1, 2.2)
	webMesh.Parent = web

	playerAim = getPlayerAimPos(fallbackAnchor)
	local spiderShoot = spider:GetPivot().Position + spider:GetPivot().LookVector * 2.5
	web.CFrame = CFrame.new(spiderShoot, playerAim)

	setBgmWebSlow()

	beginWebFollowCamera(function()
		return web.Position
	end, function()
		return getPlayerAimPos(fallbackAnchor)
	end, 1.65)

	ensureCutsceneGui()
	local choice = C.TIMING_LETTERS[math.random(1, #C.TIMING_LETTERS)]
	if timingLetter then
		timingLetter.Text = choice.label
		timingLetter.TextColor3 = Color3.fromRGB(255, 248, 220)
	end
	if timingHint then
		timingHint.Text = "HIT"
		timingHint.TextColor3 = Color3.fromRGB(200, 205, 220)
	end
	if timingRingStroke then
		timingRingStroke.Color = RING_IDLE
	end
	if timingRingScale then
		timingRingScale.Scale = C.RING_START_SCALE
	end
	if timingPulseScale then
		timingPulseScale.Scale = 1.22
	end
	if timingRootScale then
		timingRootScale.Scale = 0.35
	end
	pickRandomQtePosition()
	if timingRoot then
		timingRoot.Visible = true
	end
	startTimingPulse()
	if timingRootScale then
		TweenService:Create(timingRootScale, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end

	local qteResolved = false
	local qteSuccess = false
	local currentEased = 0
	local travel = C.WEB_TRAVEL_TIME
	local start = os.clock()
	local inputConn: RBXScriptConnection? = nil
	inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or qteResolved or not encounterActive then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if input.KeyCode ~= choice.key then
			qteResolved = true
			qteSuccess = false
			flashTimingResult(false)
			return
		end
		local pressAlpha = (os.clock() - start) / travel
		if pressAlpha < C.QTE_CLOSE_MIN then
			return
		end
		qteResolved = true
		qteSuccess = pressAlpha <= C.QTE_CLOSE_MAX
		flashTimingResult(qteSuccess)
	end)

	while encounterActive do
		local travelAlpha = (os.clock() - start) / travel
		if travelAlpha > C.QTE_CLOSE_MAX + 0.04 and (qteResolved or travelAlpha > 1.08) then
			break
		end
		if qteResolved and qteSuccess then
			dodgeResolved = true
			playDodgeMove()
			break
		end
		if qteResolved and not qteSuccess then
			break
		end

		playerAim = getPlayerAimPos(fallbackAnchor)
		spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, playerAim))
		currentEased = smoothstep(math.clamp(travelAlpha, 0, 1))
		local pos = spiderShoot:Lerp(playerAim, currentEased)
		web.CFrame = CFrame.new(pos, playerAim)

		if timingRingScale then
			timingRingScale.Scale = ringScaleForEased(currentEased)
		end
		if timingPulseScale then
			timingPulseScale.Scale = 1.08 + (1 - currentEased) * 0.18
		end
		if timingHint then
			if travelAlpha >= C.QTE_CLOSE_MIN then
				timingHint.Text = "NOW!"
				timingHint.TextColor3 = Color3.fromRGB(255, 230, 140)
			else
				timingHint.Text = "HIT"
				timingHint.TextColor3 = Color3.fromRGB(200, 205, 220)
			end
		end

		RunService.RenderStepped:Wait()
	end

	if inputConn then
		inputConn:Disconnect()
	end

	if not qteResolved then
		flashTimingResult(false)
		qteResolved = true
		qteSuccess = false
	end

	task.wait(if qteSuccess then 0.22 else 0.35)
	hideTimingQTE()

	if dodgeResolved then
		waitSec(0.35)
		TweenService:Create(web, TweenInfo.new(0.25), { Transparency = 1 }):Play()
		fadeSpider(spider)
		waitSec(0.55)
		finishEncounter(spider, web)
		return
	end

	pulseCameraShake(0.45, 0.2)
	TweenService:Create(web, TweenInfo.new(0.12), {
		Size = C.WEB_PROJECTILE_SIZE * 1.8,
	}):Play()
	killPlayerFromSpiderHit()
	waitSec(0.85)
	finishEncounter(spider, web)
	forceRestoreBgm()
	return
end

function BushSpiderEncounterController.tryTriggerAfterBrainrotAccept(_model: Model)
	if not C.ENABLED or encounterActive then
		return
	end
	if math.random() > C.TRIGGER_CHANCE then
		return
	end
	local hrp = getPlayerHRP()
	local anchor = if hrp then hrp.Position else Vector3.zero
	task.spawn(function()
		runEncounter(anchor)
	end)
end

function BushSpiderEncounterController.init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 60)
	if remotes then
		local re = remotes:WaitForChild("BushSpiderEncounterKill", 15)
		if re and re:IsA("RemoteEvent") then
			spiderKillRE = re
		end
	end

	BushFloatingClaimController.registerAcceptHook(function(_model: Model)
		BushSpiderEncounterController.tryTriggerAfterBrainrotAccept(_model)
	end)
end

return BushSpiderEncounterController
