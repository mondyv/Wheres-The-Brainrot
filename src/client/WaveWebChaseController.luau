-- [ACTIVE] WaveWebChaseController
--[[
	After every bush brainrot accept: ! above the player, then Wave Web
	rises behind them and charges in one direction toward safezone.
	HUD hides during chase; red heartbeat vignette.
]]

local ContentProvider = game:GetService("ContentProvider")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local ReviveController = require(script.Parent.ReviveController)
local LandAmbushUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandAmbushUtil"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local WaveWebChaseConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WaveWebChaseConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local BrainrotGradientAnimator = require(script.Parent.BrainrotGradientAnimator)
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
local chaseTitleLabel: TextLabel? = nil
local ensureFxGui: (() -> ScreenGui)? = nil
local colorFx: ColorCorrectionEffect? = nil
local blurFx: BlurEffect? = nil
local exclamationGui: BillboardGui? = nil
local activeSpider: Model? = nil
local activeWave: Model? = nil
local waveTitleGui: BillboardGui? = nil
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
local deathLocked = false

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

local function chargeAlongZ(fromPos: Vector3): Vector3
	local safe = SafezoneUtil.getSafezoneCenter()
	local dz = 1.0
	if safe then
		dz = safe.Z - fromPos.Z
	end
	return Vector3.new(0, 0, if dz >= 0 then 1 else -1)
end

local function waveStudioCf(pos: Vector3): CFrame
	local o = C.WAVE_SPAWN_ORIENTATION_DEG
	return CFrame.new(pos) * CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

-- Studio Position/Orientation on the primary part (not Model WorldPivot).
local function applyWaveStudioPose(model: Model, pos: Vector3)
	local target = waveStudioCf(pos)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		model:PivotTo(target)
		return
	end
	model.PrimaryPart = primary
	local delta = target * primary.CFrame:Inverse()
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
	pcall(function()
		model.WorldPivot = target
	end)
end

local function currentLandNumber(): number
	local raw = player:GetAttribute("CurrentLand")
	if typeof(raw) == "number" then
		return math.clamp(math.floor(raw), 1, 10)
	end
	return 1
end

local function instanceWorldPos(root: Instance): Vector3?
	if root:IsA("BasePart") then
		return root.Position
	end
	if root:IsA("Model") then
		local primary = (root :: Model).PrimaryPart
		if primary then
			return primary.Position
		end
		local part = root:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part.Position
		end
		return (root :: Model):GetPivot().Position
	end
	local part = root:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

-- Land N harvest uses "Land (N+1) Lock" (Land 1 → Land 2 Lock). Land 10 uses Land 10 Lock.
local function findLandLock(land: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	local folder = map and map:FindFirstChild("Land Locks")
	if not folder then
		return nil
	end
	local lockLand = math.clamp(land + 1, 2, 10)
	local name = "Land " .. tostring(lockLand) .. " Lock"
	return folder:FindFirstChild(name)
end

-- Exact lock Position (or authored 1451, 92.3, 699.7). Orientation is applied separately as 0,90,0.
local function computeTsunamiCorridor(_playerPos: Vector3): (Vector3, Vector3)
	local lock = findLandLock(currentLandNumber())
	local pos = C.WAVE_SPAWN_POS
	local lockPos = if lock then instanceWorldPos(lock) else nil
	if lockPos then
		pos = Vector3.new(lockPos.X, lockPos.Y, lockPos.Z)
	end
	return pos, chargeAlongZ(pos)
end

local function findStarterGradient(name: string): UIGradient?
	local folder = StarterGui:FindFirstChild("Gradients")
	if not folder then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		folder = pg and pg:FindFirstChild("Gradients")
	end
	if not folder then
		return nil
	end
	local node = folder:FindFirstChild(name)
	if not node then
		return nil
	end
	if node:IsA("UIGradient") then
		return node
	end
	local nested = node:FindFirstChildOfClass("UIGradient")
	if nested then
		return nested
	end
	return nil
end

local function destroyWaveTitle()
	if waveTitleGui then
		BrainrotGradientAnimator.unregister(waveTitleGui)
		waveTitleGui:Destroy()
		waveTitleGui = nil
	end
	for _, child in Workspace:GetChildren() do
		if child:IsA("BillboardGui") and child.Name == "WaveWebTitle" then
			BrainrotGradientAnimator.unregister(child)
			child:Destroy()
		end
	end
end

local function pickTitleAdornee(wave: Model): BasePart?
	local best: BasePart? = wave.PrimaryPart
	local bestVol = 0
	for _, d in wave:GetDescendants() do
		if d:IsA("BasePart") then
			local vol = d.Size.X * d.Size.Y * d.Size.Z
			if vol > bestVol then
				bestVol = vol
				best = d
			end
		end
	end
	return best or wave:FindFirstChildWhichIsA("BasePart", true)
end

local function setChaseRankTitle(text: string)
	local makeGui = ensureFxGui
	if not makeGui then
		return
	end
	local gui = makeGui()
	gui.Enabled = true
	if chaseTitleLabel then
		for _, child in chaseTitleLabel:GetChildren() do
			if child:IsA("UIGradient") then
				child:Destroy()
			end
		end
		chaseTitleLabel.Text = text
		chaseTitleLabel.Visible = true
	end
end

local function attachWaveTitle(wave: Model)
	local part = pickTitleAdornee(wave)
	if not part then
		return
	end
	destroyWaveTitle()
	local nested = wave:FindFirstChild("WaveWebTitle", true)
	if nested then
		BrainrotGradientAnimator.unregister(nested)
		nested:Destroy()
	end
	local land = currentLandNumber()
	local title = C.titleForLand(land)
	setChaseRankTitle(title.name)

	local pg = player:FindFirstChildOfClass("PlayerGui")
	local bb = Instance.new("BillboardGui")
	bb.Name = "WaveWebTitle"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.ResetOnSpawn = false
	bb.Active = false
	bb.Size = UDim2.fromScale(22, 5)
	bb.StudsOffset = Vector3.new(0, 22, 0)
	bb.MaxDistance = 2000
	bb.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	bb.Adornee = part

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = title.name
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.ZIndex = 5
	label.Parent = bb
	UiFonts.applyDisplay(label)
	UiFonts.ensureTextSizeConstraint(label, 72, 32)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3.2
	stroke.Color = Color3.fromRGB(18, 10, 6)
	stroke.Parent = label

	local template = findStarterGradient(title.gradient)
	if template then
		local clone = template:Clone()
		clone.Enabled = true
		clone.Parent = label
		if chaseTitleLabel then
			local hudGrad = template:Clone()
			hudGrad.Enabled = true
			hudGrad.Parent = chaseTitleLabel
		end
	else
		warn("[WaveWebChaseController] StarterGui.Gradients missing:", title.gradient)
	end

	bb.Parent = pg or Workspace
	waveTitleGui = bb
	BrainrotGradientAnimator.register(bb)
end

local function hideChaseHud()
	GameplayUiVisibility.hide({
		keepScreenGuiNames = { "WaveWebChaseFx" },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker", "LandActivityStripGui" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
end

local function stabilizeSpider(model: Model)
	local primary = model:FindFirstChild("HumanoidRootPart")
	if not (primary and primary:IsA("BasePart")) then
		primary = model.PrimaryPart
	end
	if not primary then
		primary = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if primary and primary:IsA("BasePart") then
		model.PrimaryPart = primary
	end
	-- Only the root stays anchored so Motor6Ds can play the rage clip.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d == primary
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.AutoRotate = false
		hum.PlatformStand = false
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

local function playScreechVfx(spider: Model, _landPos: Vector3)
	-- Rage + spider-sense FX only (no Blow template).
	SpiderSenseFx.startOnPlayer({ C.SPIDER_SPIDEY_SENSES_HUMAN_NAME })
	local host = spiderHostPart(spider)
	if host then
		SpiderSenseFx.attachNamed(C.SPIDER_SPIDEY_SENSES_NAME, host, "WaveSpiderSenses")
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
	local cruiseY = spawnPos.Y
	local startY = cruiseY - C.WAVE_RISE_STUDS
	local startPos = Vector3.new(spawnPos.X, startY, spawnPos.Z)
	applyWaveStudioPose(wave, startPos)
	wave.Parent = Workspace
	activeWave = wave
	waveTravelPos = Vector3.new(spawnPos.X, cruiseY, spawnPos.Z)
	waveForward = forward
	enableWaveFx(wave, false, true)
	attachWaveTitle(wave)

	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local riseConn = nv:GetPropertyChangedSignal("Value"):Connect(function()
		if not wave.Parent then
			return
		end
		local y = startY + (cruiseY - startY) * nv.Value
		local overshoot = math.sin(nv.Value * math.pi) * 2.4
		applyWaveStudioPose(wave, Vector3.new(spawnPos.X, y + overshoot, spawnPos.Z))
	end)
	local tw = TweenService:Create(nv, TweenInfo.new(C.WAVE_RISE_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Value = 1,
	})
	tw:Play()
	tw.Completed:Wait()
	riseConn:Disconnect()
	nv:Destroy()
	if wave.Parent then
		applyWaveStudioPose(wave, waveTravelPos)
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
	pcall(function()
		ContentProvider:PreloadAsync({ anim })
	end)
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
		local bg = SoundService:FindFirstChild("BackgroundMusic")
		if not bg then
			return
		end
		for _, inst in bg:GetDescendants() do
			if inst:IsA("Sound") and inst.IsPlaying then
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

local function applyFxGuiFullBleed(gui: ScreenGui)
	gui.IgnoreGuiInset = true
	gui.ClipToDeviceSafeArea = false
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.DisplayOrder = 80
	gui.ResetOnSpawn = false
end

ensureFxGui = function(): ScreenGui
	if fxGui and fxGui.Parent then
		applyFxGuiFullBleed(fxGui)
		if heartbeatFrame and heartbeatFrame:FindFirstChild("Wash") then
			local existingTitle = fxGui:FindFirstChild("WebRankTitle")
			if existingTitle and existingTitle:IsA("TextLabel") then
				chaseTitleLabel = existingTitle
			end
			return fxGui
		end
		fxGui:Destroy()
		fxGui = nil
		heartbeatFrame = nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "WaveWebChaseFx"
	gui.Enabled = false
	applyFxGuiFullBleed(gui)
	gui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "Heartbeat"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Position = UDim2.fromScale(0, 0)
	root.Active = false
	root.Parent = gui

	local wash = Instance.new("Frame")
	wash.Name = "Wash"
	wash.BackgroundColor3 = Color3.fromRGB(160, 18, 28)
	wash.BackgroundTransparency = 1
	wash.BorderSizePixel = 0
	wash.Size = UDim2.fromScale(1, 1)
	wash.Active = false
	wash.Parent = root

	local function edge(name: string, size: UDim2, pos: UDim2, rot: number)
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundColor3 = Color3.fromRGB(160, 18, 28)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = size
		f.Position = pos
		f.Active = false
		f.Parent = root
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.5, 0.42),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Rotation = rot
		g.Parent = f
		return f
	end

	-- Full-bleed vignette (covers phone safe-area / notch insets).
	edge("Top", UDim2.new(1, 0, 0.36, 0), UDim2.fromScale(0, 0), 90)
	edge("Bottom", UDim2.new(1, 0, 0.36, 0), UDim2.new(0, 0, 0.64, 0), -90)
	edge("Left", UDim2.new(0.28, 0, 1, 0), UDim2.fromScale(0, 0), 0)
	edge("Right", UDim2.new(0.28, 0, 1, 0), UDim2.new(0.72, 0, 0, 0), 180)

	heartbeatFrame = root
	local title = Instance.new("TextLabel")
	title.Name = "WebRankTitle"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.05, 0)
	title.Size = UDim2.new(0.94, 0, 0.09, 0)
	title.ZIndex = 50
	title.Active = false
	title.Text = ""
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.Visible = false
	title.Parent = gui
	UiFonts.applyDisplay(title)
	UiFonts.ensureTextSizeConstraint(title, 56, 28)
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 2.8
	titleStroke.Color = Color3.fromRGB(18, 10, 6)
	titleStroke.Parent = title
	chaseTitleLabel = title
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
	local makeGui = ensureFxGui
	if not makeGui then
		return
	end
	local gui = makeGui()
	gui.Enabled = true
	local i = math.clamp(intensity, 0, 1)
	local edgeAlpha = 1 - math.clamp(0.28 + i * 0.58, 0.28, 0.82)
	local washAlpha = 1 - math.clamp(0.08 + i * 0.22, 0.08, 0.3)
	if heartbeatFrame then
		for _, ch in heartbeatFrame:GetChildren() do
			if ch:IsA("Frame") then
				if ch.Name == "Wash" then
					ch.BackgroundTransparency = washAlpha
				else
					ch.BackgroundTransparency = edgeAlpha
				end
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
	if chaseTitleLabel then
		chaseTitleLabel.Visible = false
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
		destroyWaveTitle()
		activeWave:Destroy()
		activeWave = nil
	end
	waveTravelPos = nil
	waveForward = nil
end

local lockMovement: (any) -> ()
local restoreCamera: () -> ()

local function resolveKillRemote(): RemoteEvent?
	if killRE and killRE.Parent then
		return killRE
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local re = remotes and remotes:FindFirstChild("BushSpiderEncounterKill")
	if re and re:IsA("RemoteEvent") then
		killRE = re
		return re
	end
	return nil
end

local function requestKill()
	if killFired then
		return
	end
	killFired = true
	deathLocked = true
	chaseActive = false
	lockMovement()
	player:SetAttribute("WaveWebDeathLock", true)

	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
		hum.PlatformStand = false
	end
	local hrp = getHRP()
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	restoreCamera()

	ensurePostFx()
	if colorFx then
		colorFx.Enabled = true
		colorFx.TintColor = Color3.fromRGB(210, 30, 36)
		colorFx.Contrast = 0.28
		colorFx.Saturation = -0.15
	end
	if blurFx then
		blurFx.Enabled = true
		blurFx.Size = 10
	end

	if typeof(ReviveController.playWorldDeathFx) == "function" then
		ReviveController.playWorldDeathFx()
	end

	if activeSpider then
		activeSpider:Destroy()
		activeSpider = nil
	end
	local wave = activeWave
	destroyWaveTitle()
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
			local reEarly = resolveKillRemote()
			if reEarly then
				reEarly:FireServer()
			else
				warn("[WaveWebChaseController] BushSpiderEncounterKill missing — cannot teleport home")
			end
			deathLocked = false
			player:SetAttribute("WaveWebDeathLock", nil)
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
		sg.DisplayOrder = 4000
		sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local red = Instance.new("Frame")
		red.Name = "Red"
		red.BackgroundColor3 = Color3.fromRGB(150, 6, 12)
		red.BackgroundTransparency = 1
		red.BorderSizePixel = 0
		red.Size = UDim2.fromScale(1, 1)
		red.Active = true
		red.ZIndex = 1
		red.Parent = sg
		local cover = Instance.new("Frame")
		cover.Name = "Cover"
		cover.BackgroundColor3 = Color3.new(0, 0, 0)
		cover.BackgroundTransparency = 1
		cover.BorderSizePixel = 0
		cover.Size = UDim2.fromScale(1, 1)
		cover.Active = true
		cover.ZIndex = 2
		cover.Parent = sg
		sg.Parent = pg

		if wave and wave.Parent then
			task.spawn(function()
				fadeWaveOntoLand(wave, 0.45)
			end)
		end

		local redIn = TweenService:Create(
			red,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0.28 }
		)
		redIn:Play()
		redIn.Completed:Wait()
		local fadeIn = TweenService:Create(
			cover,
			TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0 }
		)
		fadeIn:Play()
		fadeIn.Completed:Wait()
		local re = resolveKillRemote()
		if re then
			re:FireServer()
		else
			warn("[WaveWebChaseController] BushSpiderEncounterKill missing — cannot teleport home")
		end
		task.wait(1.05)
		if typeof(ReviveController.stopWorldDeathFx) == "function" then
			ReviveController.stopWorldDeathFx()
		end
		local fadeOut = TweenService:Create(
			cover,
			TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		local redOut = TweenService:Create(
			red,
			TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		fadeOut:Play()
		redOut:Play()
		fadeOut.Completed:Wait()
		if sg.Parent then
			sg:Destroy()
		end
		player:SetAttribute("WaveWebDeathLock", nil)
		deathLocked = false
	end)
end

local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

lockMovement = function(handoff: {
	walkSpeed: number?,
	jumpPower: number?,
	jumpHeight: number?,
	useJumpPower: boolean?,
	autoRotate: boolean?,
}?)
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
		if handoff then
			if typeof(handoff.walkSpeed) == "number" and (handoff.walkSpeed :: number) > 0.05 then
				savedWalkSpeed = handoff.walkSpeed
			end
			if typeof(handoff.jumpPower) == "number" then
				savedJumpPower = handoff.jumpPower
			end
			if typeof(handoff.jumpHeight) == "number" then
				savedJumpHeight = handoff.jumpHeight
			end
			if typeof(handoff.useJumpPower) == "boolean" then
				savedUseJumpPower = handoff.useJumpPower
			end
			if typeof(handoff.autoRotate) == "boolean" then
				savedAutoRotate = handoff.autoRotate
			end
		end
		if savedWalkSpeed == nil then
			local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
			if typeof(base) == "number" and base > 0 then
				savedWalkSpeed = base
			elseif hum.WalkSpeed > 0.05 then
				savedWalkSpeed = hum.WalkSpeed
			else
				savedWalkSpeed = 16
			end
			if savedJumpPower == nil then
				savedJumpPower = hum.JumpPower
			end
			if savedJumpHeight == nil then
				savedJumpHeight = hum.JumpHeight
			end
			if savedUseJumpPower == nil then
				savedUseJumpPower = hum.UseJumpPower
			end
			if savedAutoRotate == nil then
				savedAutoRotate = hum.AutoRotate
			end
		end
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.Jump = false
		hum.AutoRotate = false
		hum:Move(Vector3.zero, false)
	end
	if moveLockConn then
		moveLockConn:Disconnect()
	end
	moveLockConn = RunService.Heartbeat:Connect(function()
		local h = getHumanoid()
		-- Only while cinematic intro is locked — never during free chase.
		if h and (cinematicLocked or deathLocked) then
			h.WalkSpeed = 0
			h.JumpPower = 0
			h.JumpHeight = 0
			h.Jump = false
			h:Move(Vector3.zero, false)
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

restoreCamera = function()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	local cam = Workspace.CurrentCamera
	local hum = getHumanoid()
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		if savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		elseif hum then
			cam.CameraSubject = hum
		end
		cam.FieldOfView = savedFov
	end
	savedCameraType = nil
	savedCameraSubject = nil
	if hum then
		hum.CameraOffset = Vector3.zero
		hum.PlatformStand = false
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
	deathLocked = false
	player:SetAttribute("WaveWebDeathLock", nil)
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
	return currentLandNumber()
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

-- ! above the player, then cobweb rises. No spider / screech.
local function runIntro(token: number, _playerPos: Vector3)
	local makeGui = ensureFxGui
	if makeGui then
		makeGui()
	end
	hideChaseHud()
	attachExclamation()
	pulseCameraShake(0.55, 0.16, token)
	task.wait(C.EXCLAMATION_SEC)
	if token ~= chaseToken then
		return
	end
	clearExclamation()
end

local function runChase(token: number)
	-- Wave already rose during intro lock; now it charges and the player can run.
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
	local makeGui = ensureFxGui
	if makeGui then
		makeGui()
	end
	showHeartbeat(0.35)
	setBgmChase(true)
	BushHoldInteraction.setBushSearchLocked(true)

	local wavePos = waveTravelPos or spawnPos
	local cruiseY = wavePos.Y
	applyWaveStudioPose(wave, wavePos)

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

		local speed = C.speedForLand(currentLand())

		wavePos += forward * speed * dt
		wavePos = Vector3.new(wavePos.X, cruiseY, wavePos.Z)
		waveTravelPos = wavePos
		applyWaveStudioPose(wave, wavePos)

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
	while deathLocked and token == chaseToken do
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

local function runSequence(_model: Model, handoff: {
	walkSpeed: number?,
	jumpPower: number?,
	jumpHeight: number?,
	useJumpPower: boolean?,
	autoRotate: boolean?,
}?)
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
	lockMovement(handoff)

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

		spawnTsunami(playerPos)
		if token ~= chaseToken then
			return
		end
		releaseToGameplay(token)
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
	-- Block swing/input during intro lock and cobweb-death lock.
	return cinematicLocked or deathLocked
end

function WaveWebChaseController.isChaseActive(): boolean
	return chaseActive or deathLocked
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
		local handoff = FloatingClaimCutscene.takeMoveLockState()
		task.spawn(runSequence, model, handoff)
	end)
end

return WaveWebChaseController
