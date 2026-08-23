-- [ACTIVE] WaveWebChaseController
--[[
	After every bush brainrot accept: ! + spider (already on the ground) →
	fast growl → dash into the cobweb → Wave Web rolls toward safezone.
	HUD hides during chase; red heartbeat vignette.
]]

local ContentProvider = game:GetService("ContentProvider")
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
local SpiderSenseFx = require(script.Parent.SpiderSenseFx)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local C = WaveWebChaseConfig
local player = Players.LocalPlayer

local WaveWebChaseController = {}

local MOVE_LOCK_ACTION = "WaveWebChaseMoveLock"

local chaseActive = false
-- True only while intro camera/move lock is on (NOT during free-run chase).
local cinematicLocked = false
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
local waveTravelPos: Vector3? = nil
local waveForward: Vector3? = nil
local bgmSpeedSaved: { [Sound]: number } = {}
local bgmSpeedTweens: { [Sound]: Tween } = {}
local killRE: RemoteEvent? = nil
local waveStartRE: RemoteEvent? = nil
local waveEscapeRE: RemoteEvent? = nil

local function reportWaveStarted()
	if waveStartRE then
		waveStartRE:FireServer()
	end
end

local function reportWaveEscaped()
	if waveEscapeRE then
		waveEscapeRE:FireServer()
	end
end
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

local function findSpiderTemplate(): Instance?
	local direct = findAsset(C.SPIDER_TEMPLATE_PATH)
	if direct then
		return direct
	end
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	if not assets then
		return nil
	end
	return assets:FindFirstChild("Spider")
		or assets:FindFirstChild("spider")
		or assets:FindFirstChild("Giant Spider")
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
		local flat = Vector3.new(landPos.X - playerPos.X, 0, landPos.Z - playerPos.Z).Magnitude
		if flat >= 10 and flat <= 42 then
			return landPos
		end
	end
	local hrp = getHRP()
	local look = if hrp then Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z) else Vector3.new(0, 0, -1)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local candidate = playerPos + look * 18 + Vector3.new(0, 2, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local hit = Workspace:Raycast(candidate + Vector3.new(0, 40, 0), Vector3.new(0, -90, 0), params)
	if hit then
		return hit.Position + Vector3.new(0, 2, 0)
	end
	return candidate
end

-- Chase along Z toward the player, spawning close behind them (not the far authored rest pose).
local function computeTsunamiCorridor(playerPos: Vector3): (Vector3, Vector3)
	local rest = C.WAVE_SPAWN_POS
	local dz = playerPos.Z - rest.Z
	local toPlayer = if math.abs(dz) >= 4 then Vector3.new(0, 0, math.sign(dz)) else Vector3.new(0, 0, -1)
	local behind = math.max(22, C.WAVE_BEHIND_STUDS)
	local spawnPos = Vector3.new(playerPos.X, rest.Y, playerPos.Z) - toPlayer * behind
	return spawnPos, toPlayer
end

local function waveFacingCf(pos: Vector3, chaseDir: Vector3): CFrame
	local dir = Vector3.new(chaseDir.X, 0, chaseDir.Z)
	if dir.Magnitude < 0.05 then
		dir = Vector3.new(0, 0, -1)
	else
		dir = dir.Unit
	end
	local yawOffset = math.rad(C.WAVE_MESH_YAW_OFFSET_DEG or C.WAVE_SPAWN_YAW_DEG or 90)
	return CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, yawOffset, 0)
end

local function hideChaseHud()
	GameplayUiVisibility.hide({
		keepScreenGuiNames = { "WaveWebChaseFx" },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker", "LandActivityStripGui" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
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
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function enableWaveFx(root: Instance, emitBurst: boolean, playAudio: boolean)
	-- Keep light: never mass-Emit or mass-Play — that freezes when Wave Web is dense.
	local emitted = 0
	local playedSound = false
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = true
			if emitBurst and emitted < 6 then
				emitted += 1
				pcall(function()
					d:Emit(math.clamp(d:GetAttribute("EmitCount") or 6, 2, 10))
				end)
			end
		elseif d:IsA("Beam") or d:IsA("Trail") then
			(d :: any).Enabled = true
		elseif playAudio and d:IsA("Sound") and not playedSound then
			playedSound = true
			pcall(function()
				d:Play()
			end)
		end
	end
end

local function findWaveTemplate(): Instance?
	local direct = findAsset(C.WAVE_WEB_PATH)
	if direct then
		return direct
	end
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	if not assets then
		return nil
	end
	return assets:FindFirstChild("Wave Web") or assets:FindFirstChild("WaveWeb")
end

local function cloneAsModel(src: Instance, name: string): Model?
	local clone = src:Clone()
	if clone:IsA("Model") then
		clone.Name = name
		return clone
	end
	local model = Instance.new("Model")
	model.Name = name
	clone.Parent = model
	local part = model:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		local anchor = Instance.new("Part")
		anchor.Name = "Root"
		anchor.Size = Vector3.new(4, 8, 24)
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Parent = model
		part = anchor
	end
	model.PrimaryPart = part
	return model
end

local function spiderHostPart(spider: Model): BasePart?
	local head = spider:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head
	end
	return spider.PrimaryPart or spider:FindFirstChildWhichIsA("BasePart", true)
end

local function playScreechVfx(spider: Model, landPos: Vector3)
	-- startOnPlayer clears prior sense FX, so attach spider senses after.
	SpiderSenseFx.startOnPlayer({ C.SPIDER_SPIDEY_SENSES_HUMAN_NAME })
	local host = spiderHostPart(spider)
	if host then
		SpiderSenseFx.attachNamed(C.SPIDER_SPIDEY_SENSES_NAME, host, "WaveSpiderSenses")
	end
	SpiderSenseFx.playNamedAt(C.SPIDER_BLOW_VFX_NAME, CFrame.new(landPos + Vector3.new(0, 1.2, 0)), 1.6)
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
			d.CastShadow = false
		elseif d:IsA("ParticleEmitter") then
			d.Rate = math.min(d.Rate, 12)
			d.Enabled = true
		elseif d:IsA("Beam") or d:IsA("Trail") then
			(d :: any).Enabled = true
		elseif d:IsA("Sound") then
			d.Playing = false
		end
	end
end

local function spawnTsunami(playerPos: Vector3): (Vector3?, Vector3?)
	if activeWave and activeWave.Parent and waveTravelPos and waveForward then
		return waveTravelPos, waveForward
	end
	local src = findWaveTemplate()
	if not src then
		warn("[WaveWebChaseController] EssentialAssets['Wave Web'] missing")
		return nil
	end
	local ok, waveOrErr = pcall(function()
		return cloneAsModel(src, "WaveWebChase")
	end)
	if not ok or not waveOrErr then
		warn("[WaveWebChaseController] Wave Web clone failed:", waveOrErr)
		return nil
	end
	local wave = waveOrErr :: Model
	prepareWaveModel(wave)
	local spawnPos, forward = computeTsunamiCorridor(playerPos)
	local cruiseY = C.WAVE_CRUISE_Y
	local startY = cruiseY - C.WAVE_RISE_STUDS
	local startPos = Vector3.new(spawnPos.X, startY, spawnPos.Z)
	wave:PivotTo(waveFacingCf(startPos, forward))
	wave.Parent = Workspace
	activeWave = wave
	waveTravelPos = Vector3.new(spawnPos.X, cruiseY, spawnPos.Z)
	waveForward = forward
	enableWaveFx(wave, false, true)

	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local riseConn = nv:GetPropertyChangedSignal("Value"):Connect(function()
		if not wave.Parent then
			return
		end
		local y = startY + (cruiseY - startY) * nv.Value
		local overshoot = math.sin(nv.Value * math.pi) * 2.4
		wave:PivotTo(waveFacingCf(Vector3.new(spawnPos.X, y + overshoot, spawnPos.Z), forward))
	end)
	local tw = TweenService:Create(nv, TweenInfo.new(C.WAVE_RISE_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Value = 1,
	})
	tw:Play()
	tw.Completed:Wait()
	riseConn:Disconnect()
	nv:Destroy()
	if wave.Parent then
		wave:PivotTo(waveFacingCf(waveTravelPos, forward))
	end
	return waveTravelPos, forward
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
		for sound, base in bgmSpeedSaved do
			if sound.Parent then
				local prev = bgmSpeedTweens[sound]
				if prev then
					prev:Cancel()
				end
				local tw = TweenService:Create(sound, TweenInfo.new(C.BGM_RESTORE_FADE), { PlaybackSpeed = base })
				bgmSpeedTweens[sound] = tw
				tw:Play()
			end
		end
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
	gui.DisplayOrder = 80
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "Heartbeat"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	local function edge(name: string, size: UDim2, pos: UDim2, rot: number)
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundColor3 = Color3.fromRGB(160, 18, 28)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = size
		f.Position = pos
		f.Parent = root
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.55, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Rotation = rot
		g.Parent = f
		return f
	end

	-- Soft red heartbeat edges (not a full-screen wash).
	edge("Top", UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 0), 90)
	edge("Bottom", UDim2.new(1, 0, 0.22, 0), UDim2.new(0, 0, 0.78, 0), -90)
	edge("Left", UDim2.new(0.18, 0, 1, 0), UDim2.fromScale(0, 0), 0)
	edge("Right", UDim2.new(0.18, 0, 1, 0), UDim2.new(0.82, 0, 0, 0), 180)

	heartbeatFrame = root
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
	local i = math.clamp(intensity, 0, 1)
	local edgeAlpha = 1 - math.clamp(0.2 + i * 0.55, 0.2, 0.72)
	if heartbeatFrame then
		for _, ch in heartbeatFrame:GetChildren() do
			if ch:IsA("Frame") then
				ch.BackgroundTransparency = edgeAlpha
			end
		end
	end
	if colorFx then
		colorFx.TintColor = Color3.fromRGB(255, 190, 190):Lerp(Color3.new(1, 1, 1), 1 - i * 0.4)
		colorFx.Contrast = i * 0.14
		colorFx.Saturation = -i * 0.1
	end
	if blurFx then
		blurFx.Size = i * 1.6
	end
end

local function hideHeartbeat()
	if fxGui then
		fxGui.Enabled = false
	end
	if heartbeatFrame then
		for _, ch in heartbeatFrame:GetChildren() do
			if ch:IsA("Frame") then
				ch.BackgroundTransparency = 1
			end
		end
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
	bb.Size = UDim2.fromOffset(72, 72)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 120
	bb.Parent = head

	local img = Instance.new("ImageLabel")
	img.Name = "Bang"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromScale(1, 1)
	img.Image = C.EXCLAMATION_IMAGE
	img.ImageTransparency = 1
	img.Rotation = -18
	img.Parent = bb

	local scale = Instance.new("UIScale")
	scale.Scale = 0.05
	scale.Parent = img

	-- Pop in: fade + overshoot scale + settle rotation.
	TweenService:Create(img, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		ImageTransparency = 0,
	}):Play()
	TweenService:Create(scale, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.15,
	}):Play()
	TweenService:Create(img, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Rotation = 0,
	}):Play()

	exclamationGui = bb
	UIInteractionSounds.playNotif()

	local shown = bb
	local pulseToken = chaseToken
	task.spawn(function()
		task.wait(0.38)
		if exclamationGui ~= shown or pulseToken ~= chaseToken then
			return
		end
		-- Soft heartbeat pulse while visible.
		while exclamationGui == shown and pulseToken == chaseToken do
			local up = TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				Scale = 1.28,
			})
			up:Play()
			up.Completed:Wait()
			if exclamationGui ~= shown then
				return
			end
			local down = TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
				Scale = 1.05,
			})
			down:Play()
			down.Completed:Wait()
		end
	end)

	task.delay(C.EXCLAMATION_SEC, function()
		if exclamationGui ~= shown then
			return
		end
		local s = img:FindFirstChildOfClass("UIScale")
		if s then
			TweenService:Create(s, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Scale = 0.2,
			}):Play()
		end
		local fade = TweenService:Create(img, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			ImageTransparency = 1,
			Rotation = 12,
		})
		fade:Play()
		fade.Completed:Wait()
		if exclamationGui == shown then
			clearExclamation()
		end
	end)
end

local function fadeOutSpider(model: Model, duration: number)
	if not model.Parent then
		return
	end
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		elseif d:IsA("Decal") or d:IsA("Texture") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			(d :: any).Enabled = false
		end
	end
	task.wait(duration)
	if model.Parent then
		model:Destroy()
	end
end

local function fadeWaveOntoLand(model: Model, duration: number)
	if not model.Parent then
		return
	end
	local hrp = getHRP()
	local startCf = model:GetPivot()
	local landPos = if hrp
		then Vector3.new(hrp.Position.X, hrp.Position.Y + 2.2, hrp.Position.Z)
		else startCf.Position + Vector3.new(0, -18, 0)
	local endCf = CFrame.new(landPos) * (startCf - startCf.Position)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		elseif d:IsA("Decal") or d:IsA("Texture") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			(d :: any).Enabled = false
		end
	end
	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local conn = nv.Changed:Connect(function()
		if model.Parent then
			model:PivotTo(startCf:Lerp(endCf, nv.Value))
		end
	end)
	local tw = TweenService:Create(nv, info, { Value = 1 })
	tw:Play()
	tw.Completed:Wait()
	conn:Disconnect()
	nv:Destroy()
	if model.Parent then
		model:Destroy()
	end
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
	waveTravelPos = nil
	waveForward = nil
end

local function requestKill()
	if killFired then
		return
	end
	killFired = true
	chaseActive = false
	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
	if activeSpider then
		activeSpider:Destroy()
		activeSpider = nil
	end
	local wave = activeWave
	activeWave = nil
	waveTravelPos = nil
	waveForward = nil
	setBgmChase(false)

	task.spawn(function()
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if not pg then
			pg = player:WaitForChild("PlayerGui", 5) :: PlayerGui?
		end
		if not pg then
			if killRE then
				killRE:FireServer()
			end
			return
		end

		local existing = pg:FindFirstChild("WaveWebDeathFade")
		if existing then
			existing:Destroy()
		end
		local sg = Instance.new("ScreenGui")
		sg.Name = "WaveWebDeathFade"
		sg.IgnoreGuiInset = true
		sg.ResetOnSpawn = false
		sg.DisplayOrder = 2500
		sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local cover = Instance.new("Frame")
		cover.Name = "Cover"
		cover.BackgroundColor3 = Color3.new(0, 0, 0)
		cover.BackgroundTransparency = 1
		cover.BorderSizePixel = 0
		cover.Size = UDim2.fromScale(1, 1)
		cover.Active = false
		cover.Parent = sg
		sg.Parent = pg

		if wave and wave.Parent then
			task.spawn(function()
				fadeWaveOntoLand(wave, 0.32)
			end)
		end

		if killRE then
			killRE:FireServer()
		end

		local fadeIn = TweenService:Create(
			cover,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0 }
		)
		fadeIn:Play()
		fadeIn.Completed:Wait()
		task.wait(0.18)
		local fadeOut = TweenService:Create(
			cover,
			TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		fadeOut:Play()
		fadeOut.Completed:Wait()
		if sg.Parent then
			sg:Destroy()
		end
	end)
end

local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

local function lockMovement()
	cinematicLocked = true
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
		if savedWalkSpeed == nil then
			local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
			if typeof(base) == "number" and base > 0 then
				savedWalkSpeed = base
			elseif hum.WalkSpeed > 0.05 then
				savedWalkSpeed = hum.WalkSpeed
			else
				savedWalkSpeed = 16
			end
			savedJumpPower = hum.JumpPower
			savedJumpHeight = hum.JumpHeight
			savedUseJumpPower = hum.UseJumpPower
			savedAutoRotate = hum.AutoRotate
		end
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
		-- Only while cinematic intro is locked — never during free chase.
		if h and cinematicLocked then
			h.WalkSpeed = 0
			h.JumpPower = 0
			h.JumpHeight = 0
		end
	end)
end

local function unlockMovement()
	cinematicLocked = false
	ContextActionService:UnbindAction(MOVE_LOCK_ACTION)
	if moveLockConn then
		moveLockConn:Disconnect()
		moveLockConn = nil
	end
	local hum = getHumanoid()
	if hum then
		local walk = savedWalkSpeed
		local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
		if typeof(walk) ~= "number" or walk <= 0.05 then
			if typeof(base) == "number" and base > 0 then
				walk = base
			else
				walk = 16
			end
		end
		hum.WalkSpeed = walk
		if savedUseJumpPower == false then
			hum.UseJumpPower = false
			hum.JumpHeight = if typeof(savedJumpHeight) == "number" and savedJumpHeight > 0 then savedJumpHeight else 7.2
		else
			hum.UseJumpPower = true
			hum.JumpPower = if typeof(savedJumpPower) == "number" and savedJumpPower > 0 then savedJumpPower else 50
			if hum.JumpHeight <= 0 then
				hum.JumpHeight = 7.2
			end
		end
		hum.AutoRotate = if savedAutoRotate == nil then true else savedAutoRotate
		hum.PlatformStand = false
		hum.Jump = false
	end
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil
	MobileTouchGate.ensureTouchControlsVisible(true)
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

local function tweenSpiderCharge(spider: Model, fromPos: Vector3, toPos: Vector3, duration: number)
	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local tween = TweenService:Create(nv, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Value = 1,
	})
	local conn = nv.Changed:Connect(function()
		local alpha = nv.Value
		local pos = fromPos:Lerp(toPos, alpha)
		pos += Vector3.new(0, math.sin(alpha * math.pi) * 2.4, 0)
		spider:PivotTo(cfFacingTarget(pos, toPos))
	end)
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	nv:Destroy()
	if spider.Parent then
		spider:PivotTo(cfFacingTarget(toPos, toPos + (toPos - fromPos)))
	end
end

local function finishChase(didHideHud: boolean)
	chaseActive = false
	cinematicLocked = false
	chaseToken += 1
	destroyChaseInstances()
	SpiderSenseFx.stopAll()
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

local function preloadModel(model: Model)
	local assets: { Instance } = { model }
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") or d:IsA("SpecialMesh") or d:IsA("Decal") or d:IsA("Texture") then
			table.insert(assets, d)
		end
	end
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(assets)
	end)
	if not ok then
		warn("[WaveWebChaseController] preload failed:", err)
	end
	if C.SPIDER_PRELOAD_SEC > 0 then
		task.wait(C.SPIDER_PRELOAD_SEC)
	end
end

local function currentLand(): number
	local raw = player:GetAttribute("CurrentLand")
	if typeof(raw) == "number" then
		return math.clamp(math.floor(raw), 1, 10)
	end
	return 1
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

	ensureFxGui()
	hideChaseHud()
	saveCamera(cam)
	lockMovement()

	local landPos = resolveSpiderSpawn(playerPos)
	local cobSpawn = computeTsunamiCorridor(playerPos)
	local spiderTemplate = findSpiderTemplate()
	local spider: Model? = nil
	if spiderTemplate then
		local ok, cloneOrErr = pcall(function()
			return cloneAsModel(spiderTemplate, "WaveWebChaseSpider")
		end)
		if ok and cloneOrErr then
			local clone = cloneOrErr :: Model
			stabilizeSpider(clone)
			clone:PivotTo(cfFacingTarget(landPos, playerPos))
			clone.Parent = Workspace
			activeSpider = clone
			spider = clone
			task.spawn(function()
				preloadModel(clone)
			end)
		else
			warn("[WaveWebChaseController] Spider clone failed:", cloneOrErr)
		end
	else
		warn("[WaveWebChaseController] EssentialAssets.Spider missing — skipping intro spider")
	end

	-- ! + spider on the ground at the same beat; camera sits behind the player.
	attachExclamation()
	GameSoundEffects.playSpiderRoar()
	pulseCameraShake(1.15, 0.28, token)

	local introPhase = 0
	if renderConn then
		renderConn:Disconnect()
	end
	renderConn = RunService.RenderStepped:Connect(function(dt)
		if not chaseActive or token ~= chaseToken or not cam then
			return
		end
		introPhase += dt
		local hrp = getHRP()
		local pPos = if hrp then hrp.Position else playerPos
		local look = if hrp then hrp.CFrame.LookVector else Vector3.new(0, 0, -1)
		local chest = pPos + Vector3.new(0, 1.55, 0)
		local spiderLook = chest
		if spider and spider.Parent then
			spiderLook = chest:Lerp(spider:GetPivot().Position + Vector3.new(0, 2.1, 0), 0.4)
		end
		local wobble = Vector3.new(
			math.sin(introPhase * 13.5) * 0.26,
			math.cos(introPhase * 10.2) * 0.18,
			math.sin(introPhase * 8.4) * 0.14
		)
		local camPos = pPos - look * 9.2 + Vector3.new(0, 3.6, 0) + wobble
		cam.CFrame = CFrame.lookAt(camPos, spiderLook)
		cam.FieldOfView = defaultFov + 6 + math.sin(introPhase * 7.5) * 3.2
	end)

	if spider and spider.Parent then
		playScreechVfx(spider, landPos)
		local animator = resolveAnimator(spider)
		local rageTrack = if animator then loadTrack(animator, C.SPIDER_ANIM.RAGE) else nil
		if rageTrack then
			rageTrack.Priority = Enum.AnimationPriority.Action4
			rageTrack.Looped = false
			rageTrack:Play(0.04, 1, C.SPIDER_RAGE_PLAY_SPEED)
			task.wait(math.clamp(C.SPIDER_RAGE_WAIT_SEC, 0.28, 0.55))
		else
			task.wait(C.SPIDER_RAGE_WAIT_SEC)
		end

		if token ~= chaseToken then
			return
		end

		-- Face the cobweb, then dash into it and vanish.
		local webFlat = Vector3.new(cobSpawn.X, landPos.Y, cobSpawn.Z)
		local toward = flatUnitXZ(landPos, webFlat)
		local chargeDist = math.min(C.SPIDER_CHARGE_STUDS, math.max(14, (webFlat - landPos).Magnitude * 0.35))
		local chargeTo = landPos + toward * chargeDist
		spider:PivotTo(cfFacingTarget(landPos, chargeTo))
		pulseCameraShake(0.45, 0.38, token)

		local leaving = spider
		activeSpider = nil
		task.spawn(function()
			task.wait(C.SPIDER_CHARGE_SEC * 0.45)
			fadeOutSpider(leaving, C.SPIDER_CHARGE_SEC * 0.55)
		end)
		tweenSpiderCharge(leaving, landPos, chargeTo, C.SPIDER_CHARGE_SEC)
	else
		task.wait(0.28)
	end

	if token ~= chaseToken then
		return
	end

	-- Brief look at the cobweb (Orientation 0, 90, 0), then hand control back.
	local revealStart = os.clock()
	local revealDur = C.INTRO_REVEAL_SEC
	local lookHrp = getHRP()
	local lookPos = if lookHrp then lookHrp.Position else playerPos
	local waveSpawn, toSafe = spawnTsunami(lookPos)
	if not waveSpawn or not toSafe then
		waveSpawn, toSafe = computeTsunamiCorridor(lookPos)
	end
	local waveHintPos = waveSpawn
	local awayFromSafe = -toSafe
	if renderConn then
		renderConn:Disconnect()
	end
	renderConn = RunService.RenderStepped:Connect(function()
		if not chaseActive or token ~= chaseToken or not cam then
			return
		end
		local t = os.clock()
		local alpha = math.clamp((t - revealStart) / revealDur, 0, 1)
		local eased = alpha * alpha * (3 - 2 * alpha)
		local hrp = getHRP()
		local pPos = if hrp then hrp.Position else playerPos
		local chest = pPos + Vector3.new(0, 1.5, 0)
		local wobble = Vector3.new(math.sin(t * 12) * 0.14, math.cos(t * 9) * 0.1, 0)
		local overShoulder = chest - awayFromSafe * 6 + Vector3.new(0, 3.2, 0) + wobble
		local lookBack = CFrame.lookAt(overShoulder, waveHintPos + Vector3.new(0, 8, 0))
		local startLook = chest + Vector3.new(0, 2.5, 0) - awayFromSafe * 4
		local startCf = CFrame.lookAt(startLook, waveHintPos + Vector3.new(0, 6, 0))
		cam.CFrame = startCf:Lerp(lookBack, eased)
		cam.FieldOfView = defaultFov + 8 * (1 - eased * 0.4)
	end)
	task.wait(revealDur)

	releaseToGameplay(token)
end


local function runChase(token: number)
	-- Make sure we never re-lock camera mid-chase; unlock swing/move for the run.
	releaseToGameplay(token)
	FloatingClaimCutscene.releaseMoveLock()
	MobileTouchGate.restorePlayerMovement()
	killFired = false

	local hrp0 = getHRP()
	local playerPos = if hrp0 then hrp0.Position else Vector3.zero
	-- Wave already spawned mid-map during intro; reuse it.
	local spawnPos, forward = spawnTsunami(playerPos)
	if not spawnPos or not forward or not activeWave then
		warn("[WaveWebChaseController] EssentialAssets['Wave Web'] missing")
		return
	end
	local wave = activeWave

	local chaseStart = os.clock()
	local phase = 0
	local safezoneTimer = 0
	local didHideHud = true
	local escaped = false

	reportWaveStarted()

	ensurePostFx()
	ensureFxGui()
	showHeartbeat(0.35)
	setBgmChase(true)
	BushHoldInteraction.setBushSearchLocked(true)

	local wavePos = waveTravelPos or spawnPos
	local smoothPos = wavePos
	wave:PivotTo(waveFacingCf(wavePos, forward))

	pulseCameraShake(0.7, 0.16, token)

	if renderConn then
		renderConn:Disconnect()
	end
	-- Simple chase: mid-map wave rolls toward safezone. Run home or die.
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

		if SafezoneUtil.isCharacterInSafezone(character) then
			safezoneTimer += dt
			if safezoneTimer >= C.SAFEZONE_CONFIRM_SEC then
				escaped = true
				chaseActive = false
				reportWaveEscaped()
				return
			end
		else
			safezoneTimer = 0
		end

		local elapsed = os.clock() - chaseStart
		local speed = C.speedForLand(currentLand())
		speed *= 0.9 + 0.1 * math.clamp(elapsed / 8, 0, 1)

		wavePos += forward * speed * dt
		waveTravelPos = wavePos
		wavePos = Vector3.new(wavePos.X, C.WAVE_CRUISE_Y, wavePos.Z)

		local bob = math.sin(phase * 1.2) * 0.6
		local targetVisual = wavePos + Vector3.new(0, bob, 0)
		local blend = 1 - math.exp(-dt * 10)
		smoothPos = smoothPos:Lerp(targetVisual, blend)
		wave:PivotTo(waveFacingCf(smoothPos, forward))

		local rel = Vector3.new(pPos.X - wavePos.X, 0, pPos.Z - wavePos.Z)
		local along = rel:Dot(forward)
		local distAhead = math.max(along, 0)
		local threat = 1 - math.clamp(distAhead / 90, 0, 1)
		local beat = (math.sin(phase * (2.6 + threat * 3.6)) + 1) * 0.5
		-- Always a bit heartbeaty; ramps hard as the cobweb closes in.
		local pulse = 0.2 + threat * (0.32 + beat * 0.48)
		showHeartbeat(pulse)

		local shake = 0.05 + pulse * 0.4
		hum.CameraOffset = Vector3.new(
			math.sin(phase * 41) * shake,
			math.cos(phase * 33) * shake * 0.65,
			math.sin(phase * 27) * shake * 0.35
		)

		if os.clock() - chaseStart >= C.WAVE_KILL_GRACE_SEC and along <= C.WAVE_KILL_DISTANCE then
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
	-- Swing / input gates: only block during cinematic intro lock.
	return cinematicLocked
end

function WaveWebChaseController.isChaseActive(): boolean
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
		local analytics = ReplicatedStorage:WaitForChild("AnalyticsRemotes", 30)
		if analytics then
			local startRE = analytics:FindFirstChild("ReportWaveChaseStarted")
			local escapeRE = analytics:FindFirstChild("ReportWaveChaseEscaped")
			if startRE and startRE:IsA("RemoteEvent") then
				waveStartRE = startRE
			end
			if escapeRE and escapeRE:IsA("RemoteEvent") then
				waveEscapeRE = escapeRE
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
