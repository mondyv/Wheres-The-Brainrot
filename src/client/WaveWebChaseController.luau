-- [ACTIVE] WaveWebChaseController
--[[
	After every bush brainrot accept: brief delay → spider drop/roar intro →
	Wave Web tsunami chase toward safezone. HUD hides during chase; red heartbeat vignette.
]]

local Debris = game:GetService("Debris")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local LandAmbushUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandAmbushUtil"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local WaveWebChaseConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WaveWebChaseConfig"))

local C = WaveWebChaseConfig
local player = Players.LocalPlayer

local WaveWebChaseController = {}

local MOVE_LOCK_ACTION = "WaveWebChaseMoveLock"

local chaseActive = false
local chaseToken = 0
local renderConn: RBXScriptConnection? = nil
local moveLockConn: RBXScriptConnection? = nil
local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov = 70
local defaultFov = 70
local fxGui: ScreenGui? = nil
local heartbeatFrame: Frame? = nil
local colorFx: ColorCorrectionEffect? = nil
local blurFx: BlurEffect? = nil
local exclamationGui: BillboardGui? = nil
local activeSpider: Model? = nil
local activeWave: Model? = nil
local bgmSpeedSaved: { [Sound]: number } = {}
local bgmSpeedTweens: { [Sound]: Tween } = {}
local killRE: RemoteEvent? = nil
local killFired = false

local function getHRP(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function findAsset(path: { string }): Instance?
	local node: Instance = ReplicatedStorage
	for _, name in path do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function flatUnitXZ(fromPos: Vector3, toPos: Vector3): Vector3
	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function cfFacingTarget(fromPos: Vector3, targetPos: Vector3): CFrame
	local flatTarget = Vector3.new(targetPos.X, fromPos.Y, targetPos.Z)
	if (flatTarget - fromPos).Magnitude < 0.05 then
		return CFrame.new(fromPos)
	end
	return CFrame.lookAt(fromPos, flatTarget) * CFrame.Angles(0, C.SPIDER_YAW_OFFSET, 0)
end

local function resolveSpiderSpawn(playerPos: Vector3): Vector3
	local landPos = LandAmbushUtil.pickAmbushForPlayer(
		playerPos,
		C.SPIDER_MIN_PLAYER_DISTANCE,
		C.SPIDER_MAX_PLAYER_DISTANCE,
		C.LAND_EDGE_MARGIN
	)
	if landPos then
		return landPos
	end
	return playerPos + Vector3.new(C.SPIDER_MIN_PLAYER_DISTANCE, 2, 0)
end

local function computeChaseAxes(playerPos: Vector3): (Vector3, Vector3)
	local safeCenter = SafezoneUtil.getSafezoneCenter() or playerPos
	local toSafe = flatUnitXZ(playerPos, safeCenter)
	return toSafe, -toSafe
end

-- Upright facing along chaseDir (mesh yaw offset applied once).
local function waveFacingCf(pos: Vector3, chaseDir: Vector3): CFrame
	local flat = Vector3.new(chaseDir.X, 0, chaseDir.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local look = pos + flat
	return CFrame.lookAt(pos, look) * CFrame.Angles(0, C.WAVE_FACE_YAW_OFFSET, 0)
end

local function hideChaseHud()
	GameplayUiVisibility.hide({
		keepScreenGuiNames = { "WaveWebChaseFx" },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker", "LandActivityStripGui" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
end

local function groundYAt(x: number, z: number, refY: number): number
	local origin = Vector3.new(x, refY + 80, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if activeSpider then
		table.insert(ignore, activeSpider)
	end
	if activeWave then
		table.insert(ignore, activeWave)
	end
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(origin, Vector3.new(0, -220, 0), params)
	if hit then
		return hit.Position.Y
	end
	return refY
end

local function stabilizeSpider(model: Model)
	local primary = model.PrimaryPart
	if not primary then
		primary = model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
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

local function prepareWaveModel(model: Model)
	local primary = model.PrimaryPart
	if not primary then
		primary = model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			model.PrimaryPart = primary
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = true
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = true
		elseif d:IsA("Beam") then
			d.Enabled = true
		elseif d:IsA("Trail") then
			d.Enabled = true
		end
	end
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

local function pulseCameraShake(duration: number, amp: number, token: number)
	local hum = getHumanoid()
	if not hum then
		return
	end
	task.spawn(function()
		local endAt = os.clock() + duration
		while os.clock() < endAt and chaseActive and token == chaseToken do
			local t = os.clock()
			local fade = math.clamp((endAt - t) / duration, 0, 1)
			hum.CameraOffset = Vector3.new(
				math.sin(t * 38) * amp * fade,
				math.cos(t * 31) * amp * 0.55 * fade,
				math.sin(t * 27) * amp * 0.35 * fade
			)
			RunService.RenderStepped:Wait()
		end
		if token == chaseToken and hum.Parent then
			hum.CameraOffset = Vector3.zero
		end
	end)
end

local function setBgmChase(on: boolean)
	local function eachBgm(fn: (Sound) -> ())
		for _, inst in game:GetService("SoundService"):GetDescendants() do
			if inst:IsA("Sound") and inst.IsPlaying and inst.Looped then
				fn(inst)
			end
		end
	end
	if on then
		eachBgm(function(sound)
			if bgmSpeedSaved[sound] == nil then
				bgmSpeedSaved[sound] = sound.PlaybackSpeed
			end
			local prev = bgmSpeedTweens[sound]
			if prev then
				prev:Cancel()
			end
			local tw = TweenService:Create(sound, TweenInfo.new(0.45), { PlaybackSpeed = C.BGM_CHASE_SPEED })
			bgmSpeedTweens[sound] = tw
			tw:Play()
		end)
	else
		eachBgm(function(sound)
			local base = bgmSpeedSaved[sound]
			if base == nil then
				return
			end
			local prev = bgmSpeedTweens[sound]
			if prev then
				prev:Cancel()
			end
			local tw = TweenService:Create(sound, TweenInfo.new(C.BGM_RESTORE_FADE), { PlaybackSpeed = base })
			bgmSpeedTweens[sound] = tw
			tw:Play()
		end)
		table.clear(bgmSpeedSaved)
	end
end

local function ensureFxGui(): ScreenGui
	if fxGui and fxGui.Parent then
		return fxGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "WaveWebChaseFx"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 55
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Heartbeat"
	frame.BackgroundColor3 = Color3.fromRGB(120, 12, 18)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = gui

	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(0.32, 0.55),
		NumberSequenceKeypoint.new(0.62, 0.88),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Rotation = 90
	grad.Parent = frame

	heartbeatFrame = frame
	fxGui = gui
	return gui
end

local function ensurePostFx()
	if not colorFx or not colorFx.Parent then
		local fx = Instance.new("ColorCorrectionEffect")
		fx.Name = "WaveWebChaseColor"
		fx.Enabled = false
		fx.Parent = game:GetService("Lighting")
		colorFx = fx
	end
	if not blurFx or not blurFx.Parent then
		local fx = Instance.new("BlurEffect")
		fx.Name = "WaveWebChaseBlur"
		fx.Enabled = false
		fx.Size = 0
		fx.Parent = game:GetService("Lighting")
		blurFx = fx
	end
	colorFx.Enabled = true
	blurFx.Enabled = true
end

local function clearPostFx()
	if colorFx then
		colorFx.Enabled = false
		colorFx.TintColor = Color3.new(1, 1, 1)
		colorFx.Contrast = 0
		colorFx.Saturation = 0
	end
	if blurFx then
		blurFx.Enabled = false
		blurFx.Size = 0
	end
end

local function showHeartbeat(intensity: number)
	local gui = ensureFxGui()
	gui.Enabled = true
	if heartbeatFrame then
		heartbeatFrame.BackgroundTransparency = 1 - math.clamp(intensity * 0.42, 0, 0.38)
	end
	if colorFx then
		colorFx.TintColor = Color3.fromRGB(255, 210, 210):Lerp(Color3.new(1, 1, 1), 1 - intensity * 0.35)
		colorFx.Contrast = intensity * 0.12
		colorFx.Saturation = -intensity * 0.08
	end
	if blurFx then
		blurFx.Size = intensity * 2.2
	end
end

local function hideHeartbeat()
	if fxGui then
		fxGui.Enabled = false
	end
	if heartbeatFrame then
		heartbeatFrame.BackgroundTransparency = 1
	end
	clearPostFx()
end

local function clearExclamation()
	if exclamationGui then
		exclamationGui:Destroy()
		exclamationGui = nil
	end
end

local function attachExclamation()
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	if exclamationGui then
		exclamationGui:Destroy()
		exclamationGui = nil
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "WaveWebExclamation"
	bb.Size = UDim2.fromOffset(64, 64)
	bb.StudsOffset = Vector3.new(0, 2.8, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Parent = head

	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = bb

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = C.EXCLAMATION_IMAGE
	img.Parent = bb

	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	exclamationGui = bb

	-- Brief WOAH — auto-clear so it never sticks through the chase.
	local shown = bb
	task.delay(C.EXCLAMATION_SEC, function()
		if exclamationGui == shown then
			local s = shown:FindFirstChildOfClass("UIScale")
			if s then
				local tw = TweenService:Create(s, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.15 })
				tw:Play()
				tw.Completed:Wait()
			end
			if exclamationGui == shown then
				clearExclamation()
			end
		end
	end)
end

local function requestKill()
	if killFired then
		return
	end
	killFired = true
	if killRE then
		killRE:FireServer()
	else
		local hum = getHumanoid()
		if hum then
			hum.Health = 0
		end
	end
end

local function lockMovement()
	ContextActionService:BindActionAtPriority(
		MOVE_LOCK_ACTION,
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
	local hum = getHumanoid()
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
	end
	if moveLockConn then
		moveLockConn:Disconnect()
	end
	moveLockConn = RunService.Heartbeat:Connect(function()
		local h = getHumanoid()
		if h and chaseActive then
			h.WalkSpeed = 0
		end
	end)
end

local function unlockMovement()
	ContextActionService:UnbindAction(MOVE_LOCK_ACTION)
	if moveLockConn then
		moveLockConn:Disconnect()
		moveLockConn = nil
	end
	local hum = getHumanoid()
	if hum then
		hum.WalkSpeed = 16
		hum.JumpPower = 50
		hum.JumpHeight = 7.2
		hum.AutoRotate = true
	end
	MobileTouchGate.restorePlayerMovement()
end

local function saveCamera(cam: Camera)
	if savedCameraType == nil then
		savedCameraType = cam.CameraType
		savedCameraSubject = cam.CameraSubject
		savedFov = cam.FieldOfView
		defaultFov = cam.FieldOfView
	end
	cam.CameraType = Enum.CameraType.Scriptable
end

local function restoreCamera()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	local cam = Workspace.CurrentCamera
	if cam and savedCameraType then
		cam.CameraType = savedCameraType
		if savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
		cam.FieldOfView = savedFov
	end
	savedCameraType = nil
	savedCameraSubject = nil
	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function tweenSpiderDrop(spider: Model, fromPos: Vector3, toPos: Vector3, faceFn: () -> Vector3, duration: number)
	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local phase = 0
	local tween = TweenService:Create(nv, TweenInfo.new(duration, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {
		Value = 1,
	})
	local conn = nv.Changed:Connect(function()
		local alpha = nv.Value
		local pos = fromPos:Lerp(toPos, alpha)
		local sway = math.sin(phase * 16) * (1 - alpha) * 1.1
		pos += Vector3.new(sway, 0, math.cos(phase * 13) * (1 - alpha) * 0.65)
		spider:PivotTo(cfFacingTarget(pos, faceFn()))
	end)
	local phaseConn = RunService.RenderStepped:Connect(function(dt)
		phase += dt
	end)
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	phaseConn:Disconnect()
	nv:Destroy()
	spider:PivotTo(cfFacingTarget(toPos, faceFn()))
end

local function spawnSpiderImpact(pos: Vector3)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.SmoothPlastic
	ring.Color = Color3.fromRGB(90, 75, 45)
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.12, 10, 10)
	ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.12, 42, 42),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.65)
end

local function playSpiderBlow(pos: Vector3)
	local folder = findAsset(C.SPIDER_VFX_FOLDER_PATH)
	local template = folder and folder:FindFirstChild(C.SPIDER_BLOW_VFX_NAME)
	if not template then
		return
	end
	local clone = template:Clone()
	if clone:IsA("Model") then
		clone:PivotTo(CFrame.new(pos))
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(pos)
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d:Emit(d:GetAttribute("EmitCount") or 12)
		end
	end
	clone.Parent = Workspace
	Debris:AddItem(clone, 2)
end

local function destroyChaseInstances()
	if activeSpider then
		activeSpider:Destroy()
		activeSpider = nil
	end
	if activeWave then
		activeWave:Destroy()
		activeWave = nil
	end
end

local function finishChase(didHideHud: boolean)
	chaseActive = false
	chaseToken += 1
	destroyChaseInstances()
	clearExclamation()
	hideHeartbeat()
	restoreCamera()
	unlockMovement()
	setBgmChase(false)
	BushHoldInteraction.setBushSearchLocked(false)
	if didHideHud then
		GameplayUiVisibility.show()
	end
	MobileTouchGate.ensureTouchControlsVisible(true)
end

-- End cinematic: free camera + movement so the player can sprint to safezone.
local function releaseToGameplay(token: number)
	if token ~= chaseToken then
		return
	end
	clearExclamation()
	restoreCamera()
	unlockMovement()
	MobileTouchGate.ensureTouchControlsVisible(true)
	MobileTouchGate.restorePlayerMovement()
end

local function runIntro(token: number, playerPos: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	hideChaseHud()
	attachExclamation()
	saveCamera(cam)
	lockMovement()

	local spiderTemplate = findAsset(C.SPIDER_TEMPLATE_PATH)
	if spiderTemplate and spiderTemplate:IsA("Model") then
		local landPos = resolveSpiderSpawn(playerPos)
		local dropStart = landPos + Vector3.new(0, C.SPIDER_DROP_HEIGHT, 0)
		local spider = spiderTemplate:Clone()
		spider.Name = "WaveWebChaseSpider"
		stabilizeSpider(spider)
		spider:PivotTo(cfFacingTarget(dropStart, playerPos))
		spider.Parent = Workspace
		activeSpider = spider

		pulseCameraShake(0.5, 0.16, token)

		local phase = 0
		if renderConn then
			renderConn:Disconnect()
		end
		renderConn = RunService.RenderStepped:Connect(function(dt)
			if not chaseActive or token ~= chaseToken or not cam then
				return
			end
			phase += dt
			local spiderPos = spider:GetPivot().Position
			local hrp = getHRP()
			local lookPos = if hrp then hrp.Position + Vector3.new(0, 1.4, 0) else playerPos
			local front = flatUnitXZ(spiderPos, lookPos)
			local right = front:Cross(Vector3.yAxis)
			if right.Magnitude < 0.05 then
				right = Vector3.new(1, 0, 0)
			else
				right = right.Unit
			end
			local dist = 15 + math.sin(phase * 1.4) * 3.5
			local camPos = spiderPos + front * dist + right * 5.5 + Vector3.new(0, 5.5 + math.sin(phase * 2.1) * 1.2, 0)
			cam.CFrame = CFrame.lookAt(camPos, spiderPos + Vector3.new(0, 2, 0))
			cam.FieldOfView = defaultFov + 6 + math.sin(phase * 3.5) * 2
		end)

		tweenSpiderDrop(spider, dropStart, landPos, function()
			local hrp = getHRP()
			return if hrp then hrp.Position else playerPos
		end, 1.05)

		if token ~= chaseToken then
			return
		end

		spawnSpiderImpact(landPos)
		playSpiderBlow(landPos)
		pulseCameraShake(0.85, 0.48, token)
		GameSoundEffects.playSpiderRoar()

		local animator = resolveAnimator(spider)
		local rageTrack = if animator then loadTrack(animator, C.SPIDER_ANIM.RAGE) else nil
		if rageTrack then
			rageTrack.Priority = Enum.AnimationPriority.Action4
			rageTrack.Looped = false
			rageTrack:Play(0.08, 1, 1.05)
			task.wait(math.clamp(rageTrack.Length * 0.55, 0.65, 1.35))
		else
			task.wait(0.85)
		end

		if token ~= chaseToken then
			return
		end

		if activeSpider then
			activeSpider:Destroy()
			activeSpider = nil
		end
	else
		warn("[WaveWebChaseController] EssentialAssets.Spider missing — skipping drop intro")
		task.wait(0.35)
	end

	if token ~= chaseToken then
		return
	end

	-- Brief look-back at the wave, then hand control back.
	local revealStart = os.clock()
	local revealDur = 1.1
	local _toSafe, awayFromSafe = computeChaseAxes(playerPos)
	local waveHintPos = playerPos + awayFromSafe * (C.WAVE_SPAWN_DISTANCE * 0.55)
	if renderConn then
		renderConn:Disconnect()
	end
	renderConn = RunService.RenderStepped:Connect(function()
		if not chaseActive or token ~= chaseToken or not cam then
			return
		end
		local alpha = math.clamp((os.clock() - revealStart) / revealDur, 0, 1)
		local eased = alpha * alpha * (3 - 2 * alpha)
		local hrp = getHRP()
		local pPos = if hrp then hrp.Position else playerPos
		local chest = pPos + Vector3.new(0, 1.5, 0)
		local overShoulder = chest - awayFromSafe * 6 + Vector3.new(0, 3.2, 0)
		local lookBack = CFrame.lookAt(overShoulder, waveHintPos + Vector3.new(0, 8, 0))
		local startLook = chest + Vector3.new(0, 2.5, 0) - awayFromSafe * 4
		local startCf = CFrame.lookAt(startLook, waveHintPos + Vector3.new(0, 6, 0))
		cam.CFrame = startCf:Lerp(lookBack, eased)
		cam.FieldOfView = defaultFov + 8 * (1 - eased * 0.4)
	end)
	task.wait(revealDur)

	-- Critical: leave cinematic camera so the player can run.
	releaseToGameplay(token)
end

local function runChase(token: number)
	local waveTemplate = findAsset(C.WAVE_WEB_PATH)
	if not waveTemplate or not waveTemplate:IsA("Model") then
		warn("[WaveWebChaseController] EssentialAssets['Wave Web'] missing")
		return
	end

	-- Make sure we never re-lock camera mid-chase.
	releaseToGameplay(token)
	killFired = false

	local wave = waveTemplate:Clone()
	wave.Name = "WaveWebChase"
	prepareWaveModel(wave)
	wave.Parent = Workspace
	activeWave = wave

	local function emitWaveFx()
		if not activeWave then
			return
		end
		for _, d in activeWave:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d:Emit(math.clamp(d:GetAttribute("EmitCount") or 10, 4, 28))
			end
		end
	end

	emitWaveFx()

	local chaseStart = os.clock()
	local phase = 0
	local safezoneTimer = 0
	local didHideHud = true
	local lastWaveEmit = 0
	local escaped = false

	-- HUD already hidden at intro start.
	ensurePostFx()
	setBgmChase(true)
	BushHoldInteraction.setBushSearchLocked(true)

	local hrp = getHRP()
	local playerPos = if hrp then hrp.Position else Vector3.zero
	local _toSafe, awayFromSafe = computeChaseAxes(playerPos)
	-- Spawn a bit behind the player, then chase straight at them (upright, fixed yaw).
	local wavePos = playerPos + awayFromSafe * C.WAVE_SPAWN_DISTANCE
	wavePos = Vector3.new(wavePos.X, groundYAt(wavePos.X, wavePos.Z, playerPos.Y) + 2, wavePos.Z)
	local initialDir = flatUnitXZ(wavePos, playerPos)
	wave:PivotTo(waveFacingCf(wavePos, initialDir))

	if renderConn then
		renderConn:Disconnect()
	end
	-- Heartbeat/chase tick only — do NOT take CameraType.Scriptable.
	renderConn = RunService.Heartbeat:Connect(function(dt)
		if not chaseActive or token ~= chaseToken then
			return
		end
		local root = getHRP()
		local hum = getHumanoid()
		local character = player.Character
		if not root or not hum or not character or not activeWave then
			return
		end

		phase += dt
		local pPos = root.Position

		if phase - lastWaveEmit > 0.42 then
			lastWaveEmit = phase
			emitWaveFx()
		end

		if SafezoneUtil.isCharacterInSafezone(character) then
			safezoneTimer += dt
			if safezoneTimer >= C.SAFEZONE_CONFIRM_SEC then
				escaped = true
				chaseActive = false
				return
			end
		else
			safezoneTimer = 0
		end

		local elapsed = os.clock() - chaseStart
		local ramp = math.clamp(elapsed / C.WAVE_SPEED_RAMP_SEC, 0, 1)
		local speed = C.WAVE_BASE_SPEED + (C.WAVE_MAX_SPEED - C.WAVE_BASE_SPEED) * ramp

		-- Chase the player (no trail leash). Move toward their current position.
		local toPlayer = Vector3.new(pPos.X - wavePos.X, 0, pPos.Z - wavePos.Z)
		local distXZ = toPlayer.Magnitude
		local chaseDir = if distXZ > 0.05 then toPlayer.Unit else Vector3.new(0, 0, -1)
		wavePos += chaseDir * speed * dt
		local gy = groundYAt(wavePos.X, wavePos.Z, pPos.Y) + 2
		wavePos = Vector3.new(wavePos.X, gy, wavePos.Z)

		-- Soft float bob only — keep facing locked upright (no pitch/roll tumble).
		local bob = math.sin(phase * 1.55) * 1.6
		local visualPos = wavePos + Vector3.new(0, bob, 0)
		wave:PivotTo(waveFacingCf(visualPos, chaseDir))

		local threat = 1 - math.clamp(distXZ / 90, 0, 1)
		local beat = (math.sin(phase * (2.8 + threat * 3.4)) + 1) * 0.5
		showHeartbeat(threat * (0.35 + beat * 0.45))

		if threat > 0.35 then
			hum.CameraOffset = Vector3.new(
				math.sin(phase * 28) * threat * 0.18,
				math.cos(phase * 22) * threat * 0.1,
				0
			)
		else
			hum.CameraOffset = Vector3.zero
		end

		if distXZ <= C.WAVE_KILL_DISTANCE then
			requestKill()
			chaseActive = false
			return
		end
	end)

	while chaseActive and token == chaseToken do
		task.wait(0.05)
	end

	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end

	finishChase(didHideHud)
	if not escaped and killFired then
		-- finishChase already ran; kill remote handles death.
	end
end

local function runSequence(_model: Model)
	if chaseActive then
		return
	end
	if not C.ENABLED then
		return
	end

	local hrp = getHRP()
	if not hrp then
		return
	end
	if SafezoneUtil.isCharacterInSafezone(player.Character) then
		return
	end

	chaseActive = true
	chaseToken += 1
	local token = chaseToken
	killFired = false

	local ok, err = pcall(function()
		task.wait(C.DELAY_AFTER_ACCEPT_SEC)
		if token ~= chaseToken then
			return
		end

		local liveHrp = getHRP()
		if not liveHrp or SafezoneUtil.isCharacterInSafezone(player.Character) then
			return
		end

		local playerPos = liveHrp.Position
		runIntro(token, playerPos)
		if token ~= chaseToken then
			return
		end

		runChase(token)
	end)

	if not ok then
		warn("[WaveWebChaseController] sequence error:", err)
	end
	if chaseActive and token == chaseToken then
		finishChase(GameplayUiVisibility.isHidden())
	end
end

function WaveWebChaseController.isActive(): boolean
	return chaseActive
end

function WaveWebChaseController.init()
	MobileTouchGate.init()

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 60)
		if remotes then
			local re = remotes:WaitForChild("BushSpiderEncounterKill", 15)
			if re and re:IsA("RemoteEvent") then
				killRE = re
			end
		end
	end)

	player.CharacterAdded:Connect(function()
		if chaseActive then
			finishChase(true)
		else
			clearExclamation()
			restoreCamera()
			unlockMovement()
		end
	end)

	BushFloatingClaimController.registerAcceptHook(function(model: Model)
		FloatingClaimCutscene.releaseMoveLock()
		task.spawn(runSequence, model)
	end)
end

return WaveWebChaseController
