-- [ACTIVE] BushSpiderEncounterController
--[[
	Spider ambush after accepting a floating bush brainrot: drop-in, rage, slow-mo web,
	rhythm letter QTE (shrinking ring), death on fail.
]]

local Debris = game:GetService("Debris")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local LandAmbushUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandAmbushUtil"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local PromptFxConfig = require(script.Parent.ProximityPromptEffectsConfig)
local SpiderEncounterConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpiderEncounterConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local C = SpiderEncounterConfig
local player = Players.LocalPlayer

local BushSpiderEncounterController = {}

local MOVE_LOCK_ACTION = "BushSpiderEncounterMoveLock"

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
local timingLetter: TextLabel? = nil
local timingHint: TextLabel? = nil
local timingRootScale: UIScale? = nil
local timingTapBtn: TextButton? = nil
local timingKeyIcon: ImageLabel? = nil
local clearSpiderEncounterCharacterFx: () -> ()
local timingProgressFill: Frame? = nil
local colorFx: ColorCorrectionEffect? = nil
local blurFx: BlurEffect? = nil
local cameraConn: RBXScriptConnection? = nil
local moveLockConn: RBXScriptConnection? = nil
local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov = 70
local defaultFov = 70
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil
local dodgeResolved = false
local spiderKillRE: RemoteEvent? = nil
local activeSpideySensesRoot: Instance? = nil

local GREEN_OK = Color3.fromRGB(70, 255, 130)
local RED_FAIL = Color3.fromRGB(255, 55, 55)
local RING_IDLE = Color3.fromRGB(255, 235, 120)
local FLASH_HIT = Color3.fromRGB(255, 72, 68)
local FLASH_DODGE = Color3.fromRGB(55, 255, 130)

local function isMobileSpiderInput(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function flatUnitXZ(fromPos: Vector3, toPos: Vector3): Vector3
	local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
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

local function findReplicatedAsset(path: { string }): Instance?
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

local function findSpiderTemplate(): Model?
	local node = findReplicatedAsset(C.SPIDER_TEMPLATE_PATH)
	if node and node:IsA("Model") then
		return node :: Model
	end
	return nil
end

local function findSpiderVfxTemplate(vfxName: string): Instance?
	local folder = findReplicatedAsset(C.SPIDER_VFX_FOLDER_PATH)
	if folder then
		local template = folder:FindFirstChild(vfxName)
		if template then
			return template
		end
	end

	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local templates = assets and assets:FindFirstChild("Templates")
	local fallback = templates and templates:FindFirstChild(vfxName)
	if fallback then
		return fallback
	end
	return nil
end

local function findSpiderBlowVfxTemplate(): Instance?
	return findSpiderVfxTemplate(C.SPIDER_BLOW_VFX_NAME)
end

local function emitVfxParticles(root: Instance, defaultCount: number)
	local function emitOne(emitter: ParticleEmitter)
		local count = emitter:GetAttribute("EmitCount")
		emitter:Emit(if typeof(count) == "number" then count else defaultCount)
	end

	if root:IsA("ParticleEmitter") then
		emitOne(root)
	end
	for _, child in root:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			emitOne(child)
		end
	end
end

local function playVfxSounds(root: Instance)
	for _, child in root:GetDescendants() do
		if child:IsA("Sound") then
			child:Play()
		end
	end
end

local function setEffectInstancesEnabled(root: Instance, enabled: boolean)
	if root:IsA("ParticleEmitter") or root:IsA("Trail") or root:IsA("Beam") then
		root.Enabled = enabled
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam") then
			desc.Enabled = enabled
		end
	end
end

local function resolveSpiderHeadHost(spider: Model): BasePart?
	local head = spider:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	if head and head:IsA("Model") then
		local part = head:FindFirstChildWhichIsA("BasePart", true)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	for _, desc in spider:GetDescendants() do
		if desc.Name == "Head" and desc:IsA("BasePart") then
			return desc
		end
	end
	return nil
end

local function createVfxAnchorPart(host: BasePart, name: string): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = name
	anchor.Size = Vector3.new(0.12, 0.12, 0.12)
	anchor.Transparency = 1
	anchor.Anchored = false
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Massless = true
	anchor.CFrame = host.CFrame
	anchor.Parent = host

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = host
	weld.Part1 = anchor
	weld.Parent = anchor

	return anchor
end

local function attachEncounterVfxToPart(template: Instance, host: BasePart, cloneName: string): Instance?
	local clone = template:Clone()
	clone.Name = cloneName

	if clone:IsA("Attachment") then
		clone.Parent = host
		setEffectInstancesEnabled(clone, true)
		return clone
	end

	if clone:IsA("BasePart") then
		clone.Anchored = false
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
		clone.CFrame = host.CFrame
		clone.Parent = host

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = host
		weld.Part1 = clone
		weld.Parent = clone

		setEffectInstancesEnabled(clone, true)
		return clone
	end

	local anchorPart = clone:FindFirstChildWhichIsA("BasePart", true)
	if anchorPart and anchorPart:IsA("BasePart") then
		for _, desc in clone:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanQuery = false
				desc.CanTouch = false
				desc.Massless = true
			end
		end
		clone.Parent = host
		anchorPart.CFrame = host.CFrame

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = host
		weld.Part1 = anchorPart
		weld.Parent = anchorPart

		setEffectInstancesEnabled(clone, true)
		return clone
	end

	local moved: { Instance } = {}
	local anchor = createVfxAnchorPart(host, cloneName)
	for _, desc in clone:GetDescendants() do
		if desc:IsA("Attachment") then
			desc.Parent = anchor
			table.insert(moved, desc)
		end
	end
	for _, desc in clone:GetDescendants() do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam") or desc:IsA("Sound") then
			if desc.Parent == clone or desc:IsDescendantOf(clone) then
				desc.Parent = anchor
				table.insert(moved, desc)
			end
		end
	end
	clone:Destroy()

	if #moved == 0 then
		anchor:Destroy()
		return nil
	end
	setEffectInstancesEnabled(anchor, true)
	return anchor
end

local function stopSpideySenses()
	if activeSpideySensesRoot and activeSpideySensesRoot.Parent then
		setEffectInstancesEnabled(activeSpideySensesRoot, false)
		activeSpideySensesRoot:Destroy()
	end
	activeSpideySensesRoot = nil
end

local function startSpideySensesOnSpider(spider: Model)
	stopSpideySenses()

	local template = findSpiderVfxTemplate(C.SPIDER_SPIDEY_SENSES_NAME)
	if not template then
		warn("[BushSpiderEncounterController] EssentialAssets.SpiderVFX['Spidey senses'] missing")
		return
	end

	local head = resolveSpiderHeadHost(spider)
	if not head then
		warn("[BushSpiderEncounterController] Spider Head part missing for Spidey senses VFX")
		return
	end

	local attached = attachEncounterVfxToPart(template, head, "SpiderSpideySenses")
	if attached then
		activeSpideySensesRoot = attached
		emitVfxParticles(attached, 24)
		playVfxSounds(attached)
	end
end

local function webProjectileCFrame(pos: Vector3, flightDir: Vector3): CFrame
	local dir = flightDir
	if dir.Magnitude < 0.05 then
		return CFrame.new(pos)
	end
	dir = dir.Unit
	local upHint = Vector3.yAxis
	if math.abs(dir:Dot(upHint)) > 0.92 then
		upHint = Vector3.xAxis
	end
	return CFrame.lookAt(pos, pos + dir, upHint)
		* CFrame.Angles(C.WEB_SHOT_PITCH_OFFSET, C.WEB_SHOT_YAW_OFFSET, 0)
end

local function getWebProjectilePosition(web: Model): Vector3
	return web:GetPivot().Position
end

local function setWebProjectileCFrame(web: Model, pos: Vector3, flightDir: Vector3)
	web:PivotTo(webProjectileCFrame(pos, flightDir))
end

local function stabilizeWebProjectile(model: Model)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if primary and primary:IsA("BasePart") then
		model.PrimaryPart = primary
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
end

local function createFallbackWebProjectile(): Model
	local model = Instance.new("Model")
	model.Name = "SpiderWebShot"
	local web = Instance.new("Part")
	web.Name = "Root"
	web.Size = Vector3.new(1.2, 1.2, 2.4)
	web.Shape = Enum.PartType.Ball
	web.Material = Enum.Material.SmoothPlastic
	web.Color = Color3.fromRGB(235, 235, 245)
	web.Anchored = true
	web.CanCollide = false
	web.CanQuery = false
	web.CanTouch = false
	web.Transparency = 0.08
	web.Parent = model
	model.PrimaryPart = web
	model.Parent = Workspace
	return model
end

local function createShootingWebProjectile(): Model
	local template = findSpiderVfxTemplate(C.SPIDER_SHOOTING_WEB_NAME)
	if not template then
		warn("[BushSpiderEncounterController] EssentialAssets.SpiderVFX['Shooting Web'] missing")
		return createFallbackWebProjectile()
	end

	local clone = template:Clone()
	clone.Name = "SpiderWebShot"

	local model: Model
	if clone:IsA("Model") then
		model = clone
	else
		model = Instance.new("Model")
		model.Name = "SpiderWebShot"
		clone.Parent = model
	end

	stabilizeWebProjectile(model)
	model.Parent = Workspace
	setEffectInstancesEnabled(model, true)
	emitVfxParticles(model, 10)
	playVfxSounds(model)
	return model
end

local function fadeWebProjectile(web: Model, duration: number)
	setEffectInstancesEnabled(web, false)
	local fadeInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, d in web:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, fadeInfo, { Transparency = 1 }):Play()
		elseif d:IsA("Decal") or d:IsA("Texture") then
			TweenService:Create(d, fadeInfo, { Transparency = 1 }):Play()
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			TweenService:Create(d, fadeInfo, { Brightness = 0 }):Play()
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
			d.Rate = 0
		elseif d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = false
		end
	end
	-- Soft shrink dissolve while trails finish fading.
	pcall(function()
		local startScale = (web :: any):GetScale()
		if typeof(startScale) ~= "number" then
			return
		end
		local nv = Instance.new("NumberValue")
		nv.Value = startScale
		local conn = nv.Changed:Connect(function()
			if web.Parent then
				pcall(function()
					(web :: any):ScaleTo(nv.Value)
				end)
			end
		end)
		local tween = TweenService:Create(nv, fadeInfo, { Value = startScale * 0.28 })
		tween:Play()
		tween.Completed:Once(function()
			conn:Disconnect()
			nv:Destroy()
		end)
	end)
end

local function snapWebToImpact(web: Model, fromPos: Vector3, hitPos: Vector3, flightDir: Vector3, duration: number)
	local started = os.clock()
	while os.clock() - started < duration and encounterActive do
		local alpha = smoothstep((os.clock() - started) / duration)
		local pos = fromPos:Lerp(hitPos, alpha)
		setWebProjectileCFrame(web, pos, flightDir)
		RunService.RenderStepped:Wait()
	end
	setWebProjectileCFrame(web, hitPos, flightDir)
end

local function holdHitImpactCamera(hitPos: Vector3, spiderPos: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local viewDir = flatUnitXZ(spiderPos, hitPos)
	local right = viewDir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.05 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end
	local camPos = hitPos + viewDir * 8.2 + right * 4.5 + Vector3.new(0, 2.0, 0)
	cam.CFrame = CFrame.lookAt(camPos, hitPos + Vector3.new(0, 0.35, 0))
	cam.FieldOfView = defaultFov + 4
end

local function placeVfxAtWorldPos(vfx: Instance, worldPos: Vector3)
	if vfx:IsA("Model") then
		vfx:PivotTo(CFrame.new(worldPos))
		return
	end
	if vfx:IsA("BasePart") then
		vfx.CFrame = CFrame.new(worldPos)
		return
	end
	if vfx:IsA("Attachment") then
		local anchor = Instance.new("Part")
		anchor.Name = "SpiderBlowVfxAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.CFrame = CFrame.new(worldPos)
		anchor.Parent = Workspace
		vfx.Parent = anchor
		return
	end

	local anchor = vfx:FindFirstChildWhichIsA("BasePart", true)
	if anchor then
		local offset = worldPos - anchor.Position
		for _, desc in vfx:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.CFrame = desc.CFrame + offset
			end
		end
	end
end

local function playSpiderHitBlowVfx(impactPos: Vector3?)
	local template = findSpiderBlowVfxTemplate()
	if not template then
		warn("[BushSpiderEncounterController] EssentialAssets.SpiderVFX.Blow missing")
		return
	end

	local hrp = getPlayerHRP()
	local pos = impactPos or (if hrp then hrp.Position + Vector3.new(0, 1.1, 0) else nil)
	if not pos then
		return
	end

	local vfx = template:Clone()
	vfx.Name = "SpiderHitBlowVfx"
	placeVfxAtWorldPos(vfx, pos)

	local effectRoot: Instance = vfx
	if vfx:IsA("Attachment") and vfx.Parent then
		effectRoot = vfx.Parent
	elseif not vfx.Parent then
		vfx.Parent = Workspace
	end

	emitVfxParticles(effectRoot, 40)
	playVfxSounds(effectRoot)
	Debris:AddItem(effectRoot, C.SPIDER_BLOW_VFX_LIFETIME)
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

local function spiderVisualFrontFlat(spiderPivot: CFrame, playerPos: Vector3): Vector3
	-- Rig is yaw-flipped (SPIDER_YAW_OFFSET); LookVector points at the mesh back, not the face.
	local toPlayer = flatUnitXZ(spiderPivot.Position, playerPos)
	local flatLook = Vector3.new(spiderPivot.LookVector.X, 0, spiderPivot.LookVector.Z)
	if flatLook.Magnitude > 0.05 then
		local visualFront = (-flatLook).Unit
		if visualFront:Dot(toPlayer) > 0.25 then
			return visualFront
		end
	end
	return toPlayer
end

local function spiderHeadTarget(spiderPos: Vector3, visualFront: Vector3): Vector3
	return spiderPos + visualFront * 1.6 + Vector3.new(0, 3.1, 0)
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
	GameSoundEffects.playSpiderRoar()

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
	for s, tw in bgmSpeedTweens do
		if tw then
			tw:Cancel()
		end
		bgmSpeedTweens[s] = nil
	end
	for s, saved in bgmSpeedSaved do
		if s.Parent then
			s.PlaybackSpeed = if typeof(saved) == "number" then saved else 1
		end
		bgmSpeedSaved[s] = nil
	end
	-- Snap any lingering combat slowdown even if we lost the saved map entry.
	for _, s in collectBgmSounds() do
		if s.Parent and s.PlaybackSpeed < 0.95 then
			s.PlaybackSpeed = 1
		end
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
		local tween = TweenService:Create(
			s,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ PlaybackSpeed = C.BGM_WEB_SPEED }
		)
		bgmSpeedTweens[s] = tween
		tween:Play()
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

local function ensureCutsceneGui(): ScreenGui
	if cutsceneGui and cutsceneGui.Parent and cutsceneGui:GetAttribute("QteStyle") == "clean_v2" then
		return cutsceneGui
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
		cutsceneGui = nil
		letterTop = nil
		letterBottom = nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "BushSpiderCutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 950
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui:SetAttribute("QteStyle", "clean_v2")
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
	pcall(function()
		(gui :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.Size = UDim2.new(1.4, 0, 0, 0)
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, -0.04, 0)
	top.ZIndex = 20
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.Size = UDim2.new(1.4, 0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.new(0.5, 0, 1.04, 0)
	bottom.ZIndex = 20
	bottom.Parent = gui

	local leftSeal = Instance.new("Frame")
	leftSeal.Name = "LetterLeftSeal"
	leftSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	leftSeal.BorderSizePixel = 0
	leftSeal.Size = UDim2.new(0, 0, 1.2, 0)
	leftSeal.AnchorPoint = Vector2.new(0, 0.5)
	leftSeal.Position = UDim2.new(0, 0, 0.5, 0)
	leftSeal.ZIndex = 18
	leftSeal.Visible = false
	leftSeal.Parent = gui

	local rightSeal = Instance.new("Frame")
	rightSeal.Name = "LetterRightSeal"
	rightSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	rightSeal.BorderSizePixel = 0
	rightSeal.Size = UDim2.new(0, 0, 1.2, 0)
	rightSeal.AnchorPoint = Vector2.new(1, 0.5)
	rightSeal.Position = UDim2.new(1, 0, 0.5, 0)
	rightSeal.ZIndex = 18
	rightSeal.Visible = false
	rightSeal.Parent = gui

	-- Clean QTE: key badge + one closing ring + thin progress (stays above letterbox).
	local ringPx = C.RING_OUTER_PX
	local qte = Instance.new("Frame")
	qte.Name = "TimingQTE"
	qte.AnchorPoint = Vector2.new(0.5, 0.5)
	qte.Position = UDim2.fromScale(0.5, 0.70)
	qte.Size = UDim2.fromOffset(132, 148)
	qte.BackgroundTransparency = 1
	qte.Visible = false
	qte.ZIndex = 40
	qte.Parent = gui

	local qteScale = Instance.new("UIScale")
	qteScale.Scale = 1
	qteScale.Parent = qte

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.42)
	ring.Size = UDim2.fromOffset(ringPx, ringPx)
	ring.BackgroundTransparency = 1
	-- Behind badge + hint so the closing stroke never covers the letter/text.
	ring.ZIndex = 41
	ring.Parent = qte
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Color = RING_IDLE
	ringStroke.Thickness = 3
	ringStroke.Transparency = 0.12
	ringStroke.Parent = ring
	local ringScale = Instance.new("UIScale")
	ringScale.Scale = C.RING_START_SCALE
	ringScale.Parent = ring

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.fromScale(0.5, 0.42)
	badge.Size = UDim2.fromOffset(ringPx, ringPx)
	badge.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
	badge.BackgroundTransparency = 0
	badge.ZIndex = 44
	badge.Parent = qte
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge
	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = Color3.fromRGB(255, 245, 210)
	badgeStroke.Thickness = 1.5
	badgeStroke.Transparency = 0.35
	badgeStroke.Parent = badge

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Letter"
	keyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	keyLabel.Position = UDim2.fromScale(0.5, 0.48)
	keyLabel.Size = UDim2.fromScale(0.9, 0.7)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Text = "E"
	keyLabel.TextColor3 = Color3.fromRGB(255, 248, 220)
	UiFonts.applyDisplayLabel(keyLabel, 42, 28)
	keyLabel.ZIndex = 45
	keyLabel.Parent = badge

	local keyIcon = Instance.new("ImageLabel")
	keyIcon.Name = "KeyIcon"
	keyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	keyIcon.Position = UDim2.fromScale(0.5, 0.5)
	keyIcon.Size = UDim2.fromOffset(40, 40)
	keyIcon.BackgroundTransparency = 1
	keyIcon.Image = PromptFxConfig.TOUCH_TAP_ICON
	keyIcon.ImageColor3 = Color3.fromRGB(255, 248, 220)
	keyIcon.ScaleType = Enum.ScaleType.Fit
	keyIcon.Visible = false
	keyIcon.ZIndex = 46
	keyIcon.Parent = badge

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 0)
	hint.Position = UDim2.fromScale(0.5, 0.72)
	hint.Size = UDim2.new(1, 0, 0, 22)
	hint.BackgroundTransparency = 1
	hint.Text = "GET READY"
	hint.TextColor3 = Color3.fromRGB(200, 205, 220)
	UiFonts.applyButtonLabel(hint, 12, 9)
	hint.ZIndex = 48
	hint.Parent = qte

	local tapBtn = Instance.new("TextButton")
	tapBtn.Name = "TapButton"
	tapBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	tapBtn.Position = UDim2.fromScale(0.5, 0.42)
	tapBtn.Size = UDim2.fromOffset(120, 120)
	tapBtn.BackgroundTransparency = 1
	tapBtn.BorderSizePixel = 0
	tapBtn.Text = ""
	tapBtn.AutoButtonColor = false
	tapBtn.ZIndex = 50
	tapBtn.Visible = false
	tapBtn.Parent = qte

	local progressTrack = Instance.new("Frame")
	progressTrack.Name = "ProgressTrack"
	progressTrack.AnchorPoint = Vector2.new(0.5, 1)
	progressTrack.Position = UDim2.new(0.5, 0, 1, 0)
	progressTrack.Size = UDim2.fromOffset(88, 5)
	progressTrack.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	progressTrack.BackgroundTransparency = 0.2
	progressTrack.BorderSizePixel = 0
	progressTrack.ZIndex = 46
	progressTrack.Parent = qte
	local progressCorner = Instance.new("UICorner")
	progressCorner.CornerRadius = UDim.new(1, 0)
	progressCorner.Parent = progressTrack
	local progressFill = Instance.new("Frame")
	progressFill.Name = "Fill"
	progressFill.Size = UDim2.fromScale(0, 1)
	progressFill.BackgroundColor3 = Color3.fromRGB(255, 220, 110)
	progressFill.BorderSizePixel = 0
	progressFill.ZIndex = 47
	progressFill.Parent = progressTrack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = progressFill

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	timingRoot = qte
	timingRing = ring
	timingRingScale = ringScale
	timingRingStroke = ringStroke
	timingLetter = keyLabel
	timingKeyIcon = keyIcon
	timingHint = hint
	timingRootScale = qteScale
	timingTapBtn = tapBtn
	timingProgressFill = progressFill
	return gui
end

local function animateLetterboxIn()
	local gui = ensureCutsceneGui()
	gui.Enabled = true
	local barIn = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	if letterTop and letterBottom then
		TweenService:Create(letterTop, barIn, {
			Size = UDim2.new(1.4, 0, 0.12, 0),
		}):Play()
		TweenService:Create(letterBottom, barIn, {
			Size = UDim2.new(1.4, 0, 0.12, 0),
		}):Play()
	end
	local leftSeal = gui:FindFirstChild("LetterLeftSeal")
	local rightSeal = gui:FindFirstChild("LetterRightSeal")
	local useSideSeals = UserInputService.TouchEnabled
	if leftSeal and leftSeal:IsA("Frame") then
		leftSeal.Visible = useSideSeals
		if useSideSeals then
			TweenService:Create(leftSeal, barIn, {
				Size = UDim2.new(0.04, 16, 1.2, 0),
			}):Play()
		else
			leftSeal.Size = UDim2.new(0, 0, 1.2, 0)
		end
	end
	if rightSeal and rightSeal:IsA("Frame") then
		rightSeal.Visible = useSideSeals
		if useSideSeals then
			TweenService:Create(rightSeal, barIn, {
				Size = UDim2.new(0.04, 16, 1.2, 0),
			}):Play()
		else
			rightSeal.Size = UDim2.new(0, 0, 1.2, 0)
		end
	end
end

local function animateLetterboxOut()
	local barOut = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if letterTop and letterBottom then
		TweenService:Create(letterTop, barOut, {
			Size = UDim2.new(1.4, 0, 0, 0),
		}):Play()
		TweenService:Create(letterBottom, barOut, {
			Size = UDim2.new(1.4, 0, 0, 0),
		}):Play()
	end
	if cutsceneGui then
		local leftSeal = cutsceneGui:FindFirstChild("LetterLeftSeal")
		local rightSeal = cutsceneGui:FindFirstChild("LetterRightSeal")
		if leftSeal and leftSeal:IsA("Frame") then
			TweenService:Create(leftSeal, barOut, {
				Size = UDim2.new(0, 0, 1.2, 0),
			}):Play()
		end
		if rightSeal and rightSeal:IsA("Frame") then
			TweenService:Create(rightSeal, barOut, {
				Size = UDim2.new(0, 0, 1.2, 0),
			}):Play()
		end
		task.delay(0.38, function()
			if cutsceneGui then
				cutsceneGui.Enabled = false
			end
		end)
	end
end

local function clearPostFx()
	if colorFx then
		colorFx.Enabled = false
		colorFx.Brightness = 0
		colorFx.Contrast = 0
		colorFx.Saturation = 0
		colorFx.TintColor = Color3.new(1, 1, 1)
		colorFx:Destroy()
		colorFx = nil
	end
	if blurFx then
		blurFx.Enabled = false
		blurFx.Size = 0
		blurFx:Destroy()
		blurFx = nil
	end
	local cam = Workspace.CurrentCamera
	if cam then
		local leftoverColor = cam:FindFirstChild("BushSpiderColor")
		if leftoverColor then
			leftoverColor:Destroy()
		end
		local leftoverBlur = cam:FindFirstChild("BushSpiderBlur")
		if leftoverBlur then
			leftoverBlur:Destroy()
		end
	end
end

local function ensurePostFx()
	-- Keep world lighting/coloring normal during the spider cutscene (no tint/blur).
	clearPostFx()
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

local function shakeCFrame(base: CFrame, phase: number, amp: number): CFrame
	local wobble = amp * (0.78 + 0.22 * math.sin(phase * 0.55))
	return base
		* CFrame.new(
			math.sin(phase * 17.3) * wobble * 0.14 + math.sin(phase * 4.1) * wobble * 0.07,
			math.sin(phase * 13.7) * wobble * 0.11 + math.cos(phase * 3.3) * wobble * 0.055,
			math.sin(phase * 10.9) * wobble * 0.085 + math.sin(phase * 2.4) * wobble * 0.04
		)
		* CFrame.Angles(
			math.sin(phase * 19.1) * wobble * 0.024 + math.sin(phase * 5.2) * wobble * 0.011,
			math.cos(phase * 15.4) * wobble * 0.02 + math.sin(phase * 2.8) * wobble * 0.009,
			math.sin(phase * 21.3) * wobble * 0.016 + math.cos(phase * 6.7) * wobble * 0.007
		)
end

local function beginSpiderDropCamera(getSpiderPivot: () -> CFrame, getPlayerPos: () -> Vector3, intensity: number)
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
		local spiderPivot = getSpiderPivot()
		local spiderPos = spiderPivot.Position
		local playerPos = getPlayerPos()
		local front = spiderVisualFrontFlat(spiderPivot, playerPos)
		local right = front:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local dist = 16.5 + math.sin(phase * 1.55) * 3.6
		local sidePull = 6.8 + math.sin(phase * 1.05) * 2.2
		local height = 4.8 + math.sin(phase * 2.35) * 1.85
		local camPos = spiderPos + front * dist + right * sidePull + Vector3.new(0, height, 0)
		local lookAt = spiderPos + Vector3.new(0, 1.85, 0) + front * 0.35
		cam.CFrame = shakeCFrame(CFrame.lookAt(camPos, lookAt), phase, intensity * 1.15)
		cam.FieldOfView = defaultFov + 5 + math.sin(phase * 4.2) * 3.2 * intensity
	end)
end

local function beginRageCamera(
	getSpiderPivot: () -> CFrame,
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

		local spiderPivot = getSpiderPivot()
		local spiderPos = spiderPivot.Position
		local playerPos = getPlayerPos()
		local front = spiderVisualFrontFlat(spiderPivot, playerPos)
		local right = front:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local pullBack = 20 + intensity * 3.5
		local sidePull = 8.5 + math.sin(phase * 1.45) * 2.4
		local camPos = spiderPos + front * pullBack + right * sidePull + Vector3.new(0, 5.8 + math.sin(phase * 2.1) * 0.85, 0)
		local lookTarget = spiderPos + Vector3.new(0, 2.15, 0) + front * 0.65

		cam.CFrame = shakeCFrame(CFrame.lookAt(camPos, lookTarget), phase, 1.05)
		cam.FieldOfView = defaultFov + zoomFov + math.sin(phase * 3.1) * 2.2
	end)
end

local function beginWebWindupCamera(getSpiderPivot: () -> CFrame, getPlayerPos: () -> Vector3)
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

		local spiderPivot = getSpiderPivot()
		local spiderPos = spiderPivot.Position
		local playerPos = getPlayerPos()
		local front = spiderVisualFrontFlat(spiderPivot, playerPos)
		local right = front:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local lookTarget = spiderPos + Vector3.new(0, 2.0, 0) + front * 0.45
		local camPos = spiderPos
			+ front * (7.5 + math.sin(phase * 2.6) * 0.95)
			+ right * (5.4 + math.cos(phase * 2.05) * 1.05)
			+ Vector3.new(0, 1.65 + math.sin(phase * 4.1) * 0.42, 0)

		cam.CFrame = shakeCFrame(CFrame.lookAt(camPos, lookTarget), phase, 0.92)
		cam.FieldOfView = defaultFov + 5 + math.sin(phase * 5.8) * 2.8
	end)
end

local function beginWebFollowCamera(
	getWebPos: () -> Vector3,
	getTargetPos: () -> Vector3,
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

	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not encounterActive or not cam then
			return
		end
		phase += dt

		local playerPos = getPlayerPos()
		local webPos = getWebPos()
		local targetPos = getTargetPos()
		local toWeb = webPos - playerPos
		local flatToWeb = Vector3.new(toWeb.X, 0, toWeb.Z)
		if flatToWeb.Magnitude < 0.05 then
			flatToWeb = Vector3.new(0, 0, -1)
		else
			flatToWeb = flatToWeb.Unit
		end
		local right = flatToWeb:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local camPos = playerPos
			- flatToWeb * (10.5 + math.sin(phase * 2.2) * 0.8)
			+ right * (6.2 + math.cos(phase * 1.8) * 0.55)
			+ Vector3.new(0, 3.1 + math.sin(phase * 3.5) * 0.25, 0)
		local lookTarget = webPos:Lerp(targetPos, 0.42) + Vector3.new(0, 1.1, 0)

		cam.CFrame = shakeCFrame(CFrame.lookAt(camPos, lookTarget), phase, intensity * 0.72)
		cam.FieldOfView = defaultFov + 8 + math.sin(phase * 4.2) * 2.8
	end)
end

local function easeCameraBackToPlayer(duration: number, _spider: Model?)
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	local hrp = getPlayerHRP()
	if not cam or not hrp then
		return
	end

	local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end

	local function gameplayHandoffCf(root: BasePart): CFrame
		local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if look.Magnitude < 0.05 then
			look = Vector3.new(0, 0, -1)
		else
			look = look.Unit
		end
		local camPos = root.Position - look * 12.5 + Vector3.new(0, 5.5, 0)
		return CFrame.lookAt(camPos, root.Position + Vector3.new(0, 1.6, 0))
	end

	local startCf = cam.CFrame
	local goalCf = gameplayHandoffCf(hrp)
	local startFov = cam.FieldOfView
	local goalFov = if savedFov > 0 then savedFov else defaultFov

	local nv = Instance.new("NumberValue")
	nv.Value = 0
	local conn = nv.Changed:Connect(function()
		local live = getPlayerHRP()
		if live then
			goalCf = gameplayHandoffCf(live)
		end
		local t = 1 - (1 - nv.Value) ^ 3
		cam.CFrame = startCf:Lerp(goalCf, t)
		cam.FieldOfView = startFov + (goalFov - startFov) * t
	end)
	local tween = TweenService:Create(nv, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	nv:Destroy()
end

local function lockPlayerMovement()
	local handoff = FloatingClaimCutscene.takeMoveLockState()
	if handoff then
		if typeof(handoff.walkSpeed) == "number" then
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

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		if savedWalkSpeed == nil then
			-- Don't capture a zeroed speed from a prior cutscene freeze.
			savedWalkSpeed = if hum.WalkSpeed > 0.05 then hum.WalkSpeed else 16
			savedJumpPower = hum.JumpPower
			savedJumpHeight = if hum.JumpHeight > 0 then hum.JumpHeight else 7.2
			savedUseJumpPower = hum.UseJumpPower
			savedAutoRotate = hum.AutoRotate
		end
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
		hum:Move(Vector3.zero, false)
	end
	pcall(function()
		ContextActionService:UnbindAction(MOVE_LOCK_ACTION)
	end)
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
	if moveLockConn then
		moveLockConn:Disconnect()
	end
	moveLockConn = RunService.RenderStepped:Connect(function()
		if not encounterActive then
			return
		end
		local liveHum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if liveHum then
			if liveHum.WalkSpeed ~= 0 then
				liveHum.WalkSpeed = 0
			end
			liveHum:Move(Vector3.zero, false)
		end
	end)
end

local function unlockPlayerMovement()
	if moveLockConn then
		moveLockConn:Disconnect()
		moveLockConn = nil
	end
	pcall(function()
		ContextActionService:UnbindAction(MOVE_LOCK_ACTION)
	end)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
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

local function restoreCamera()
	stopCameraRig()
	local cam = Workspace.CurrentCamera
	if not cam then
		unlockPlayerMovement()
		return
	end
	local goalFov = if savedFov > 0 then savedFov else defaultFov
	cam.FieldOfView = goalFov
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
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end
	savedCameraType = nil
	savedCameraSubject = nil
	unlockPlayerMovement()
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
	if timingRoot then
		timingRoot.Visible = false
	end
end

local function pickRandomQtePosition()
	if not timingRoot then
		return
	end
	-- Centered above bottom letterbox (~12% bars).
	timingRoot.Position = UDim2.fromScale(0.5, 0.70)
end

local function refreshTimingUiPresentation(mobileInput: boolean, choiceLabel: string)
	if timingLetter then
		timingLetter.Visible = not mobileInput
		if not mobileInput then
			timingLetter.Text = choiceLabel
		end
	end
	if timingKeyIcon then
		timingKeyIcon.Visible = mobileInput
	end
	if timingHint then
		timingHint.Text = if mobileInput then "TAP!" else "NOW!"
	end
	if timingRing then
		timingRing.Visible = true
	end
end

local function flashCharacterTint(color: Color3, duration: number, intense: boolean?)
	local strong = intense == true
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		local existingGui = pg:FindFirstChild("SpiderEncounterFlash")
		if existingGui then
			existingGui:Destroy()
		end

		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "SpiderEncounterFlash"
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 10000
		screenGui.ResetOnSpawn = true

		local overlay = Instance.new("Frame")
		overlay.BackgroundColor3 = color
		overlay.BackgroundTransparency = if strong then 0.22 else 0.55
		overlay.BorderSizePixel = 0
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.Parent = screenGui

		screenGui.Parent = pg

		TweenService:Create(overlay, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
		task.delay(duration + 0.06, function()
			if screenGui.Parent then
				screenGui:Destroy()
			end
		end)
	end

	local char = player.Character
	local cam = Workspace.CurrentCamera
	if char and cam then
		local existingHl = cam:FindFirstChild("SpiderEncounterFlashHl")
		if existingHl then
			existingHl:Destroy()
		end

		local hl = Instance.new("Highlight")
		hl.Name = "SpiderEncounterFlashHl"
		hl.Adornee = char
		hl.FillColor = color
		hl.OutlineColor = color
		hl.FillTransparency = if strong then 0.02 else 0.28
		hl.OutlineTransparency = if strong then 0.08 else 0.35
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = cam

		TweenService:Create(hl, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
		task.delay(duration + 0.06, function()
			if hl.Parent then
				hl:Destroy()
			end
		end)
	end
end

local function flashCharacterHit()
	flashCharacterTint(FLASH_HIT, 0.72, true)
end

local function flashCharacterDodge()
	flashCharacterTint(FLASH_DODGE, 0.65, true)
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
	end
end

local function playDodgeMove()
	local hrp = getPlayerHRP()
	if not hrp then
		return
	end
	GameSoundEffects.playSpiderDodge()
	flashCharacterDodge()
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

local function computeSpiderDropPositions(landPos: Vector3): (Vector3, Vector3)
	local landing = landPos
	local dropHeight = C.DROP_HEIGHT
	local dropStart = landing + Vector3.new(0, dropHeight, 0)

	local ceiling = workspace:Raycast(dropStart, Vector3.new(0, 55, 0))
	if ceiling then
		local cappedY = ceiling.Position.Y - 2.5
		if cappedY - landing.Y >= 8 then
			dropStart = Vector3.new(landing.X, cappedY, landing.Z)
		end
	end

	if dropStart.Y - landing.Y < dropHeight * 0.65 then
		dropStart = Vector3.new(landing.X, landing.Y + dropHeight, landing.Z)
	end

	return dropStart, landing
end

local function tweenSpiderDrop(
	spider: Model,
	fromPos: Vector3,
	toPos: Vector3,
	faceTargetFn: () -> Vector3,
	duration: number
)
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
		local faceTarget = faceTargetFn()
		spider:PivotTo(cfFacingTarget(pos, faceTarget))
	end)
	local phaseConn = RunService.RenderStepped:Connect(function(dt)
		phase += dt
	end)
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	phaseConn:Disconnect()
	nv:Destroy()
	spider:PivotTo(cfFacingTarget(toPos, faceTargetFn()))
end

local function finishEncounter(spider: Model?, web: Model?)
	encounterActive = false
	hideTimingQTE()
	stopSpideySenses()
	clearSpiderEncounterCharacterFx()
	forceRestoreBgm()
	clearPostFx()
	animateLetterboxOut()
	restoreCamera()
	restoreGameplayUi()
	BushHoldInteraction.setBushSearchLocked(false)

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
	if not hum then
		return
	end
	if hum.Health <= 0 then
		return
	end
	hum.BreakJointsOnDeath = true
	if spiderKillRE then
		spiderKillRE:FireServer()
	end
	pcall(function()
		hum:TakeDamage(hum.MaxHealth * 2)
	end)
	hum.Health = 0
	task.defer(function()
		if not hum.Parent then
			return
		end
		if hum.Health > 0 then
			if spiderKillRE then
				spiderKillRE:FireServer()
			end
			hum.Health = 0
		end
		local liveChar = player.Character
		if liveChar and liveChar.Parent and hum.Health <= 0 then
			pcall(function()
				liveChar:BreakJoints()
			end)
		end
	end)
end

local function getPlayerChestPos(fallback: Vector3): Vector3
	local hrp = getPlayerHRP()
	return if hrp then hrp.Position + Vector3.new(0, 0.75, 0) else fallback
end

local function getPlayerAimPos(fallback: Vector3): Vector3
	return getPlayerChestPos(fallback)
end

local function getWebImpactPos(flightDir: Vector3, fallback: Vector3, spider: Model?, web: Model?): Vector3
	local hrp = getPlayerHRP()
	if not hrp then
		return fallback
	end
	local char = hrp.Parent
	local flatDir = Vector3.new(flightDir.X, 0, flightDir.Z)
	if flatDir.Magnitude > 0.05 then
		flatDir = flatDir.Unit
	else
		flatDir = Vector3.new(0, 0, -1)
	end

	local origin = hrp.Position + Vector3.new(0, 0.85, 0) - flatDir * 9
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if spider then
		table.insert(ignore, spider)
	end
	if web then
		table.insert(ignore, web)
	end
	params.FilterDescendantsInstances = ignore

	local hit = workspace:Raycast(origin, flatDir * 16, params)
	if hit and char and hit.Instance:IsDescendantOf(char) then
		return hit.Position + hit.Normal * 1.35
	end

	return hrp.Position + Vector3.new(0, 0.55, 0) - flatDir * 3.8
end

clearSpiderEncounterCharacterFx = function()
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		local flashGui = pg:FindFirstChild("SpiderEncounterFlash")
		if flashGui then
			flashGui:Destroy()
		end
	end
	local cam = Workspace.CurrentCamera
	if cam then
		local hl = cam:FindFirstChild("SpiderEncounterFlashHl")
		if hl then
			hl:Destroy()
		end
	end
	for _, inst in Workspace:GetChildren() do
		if inst.Name == "SpiderHitBlowVfx" or inst.Name == "SpiderBlowVfxAnchor" then
			inst:Destroy()
		end
	end
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
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil

	BushHoldInteraction.setBushSearchLocked(true)
	lockPlayerMovement()
	local skipCutscene = player:GetAttribute("SkipSpiderCutscene") ~= false
	if not skipCutscene then
		hideGameplayUi()
		animateLetterboxIn()
		ensurePostFx()
	end
	setBgmSlowed(true)

	local landPos = resolveSpiderSpawnPosition(fallbackAnchor)
	local playerAim = getPlayerAimPos(fallbackAnchor)
	local dropStart, landingPos = computeSpiderDropPositions(landPos)

	local spider = template:Clone()
	spider.Name = "BushSpiderEncounter"
	stabilizeSpiderModel(spider)
	-- Skip mode: spawn already on the ground and go straight into the attack beat.
	if skipCutscene then
		spider:PivotTo(cfFacingTarget(landingPos, playerAim))
	else
		spider:PivotTo(cfFacingTarget(dropStart, playerAim))
	end
	spider.Parent = Workspace

	local animator = resolveAnimator(spider)
	local rageTrack = if animator then loadTrack(animator, C.ANIM.RAGE) else nil
	local webTrack = if animator then loadTrack(animator, C.ANIM.WEB) else nil

	if skipCutscene then
		faceCharacterToward(landingPos)
		spider:PivotTo(cfFacingTarget(landingPos, playerAim))
		startSpideySensesOnSpider(spider)
		-- Short rage sting, then straight into web attack (no cinematic cameras).
		if rageTrack then
			rageTrack.Priority = Enum.AnimationPriority.Action4
			rageTrack.Looped = false
			rageTrack:Play(0.08, 1, 1.15)
			waitSec(math.clamp((if rageTrack.Length > 0.05 then rageTrack.Length else C.RAGE_FALLBACK_SEC) * 0.35, 0.35, 0.85))
			rageTrack:Stop(0.12)
		else
			waitSec(0.35)
		end
		stopSpideySenses()
	else
		beginSpiderDropCamera(function()
			return spider:GetPivot()
		end, function()
			return getPlayerChestPos(fallbackAnchor)
		end, 1.35)
		pulseCameraShake(0.45, 0.14)

		tweenSpiderDrop(spider, dropStart, landingPos, function()
			return getPlayerAimPos(fallbackAnchor)
		end, 1.05)

		if not encounterActive then
			finishEncounter(spider, nil)
			return
		end

		pulseCameraShake(0.65, 0.18)
		playerAim = getPlayerAimPos(fallbackAnchor)
		faceCharacterToward(landingPos)
		spider:PivotTo(cfFacingTarget(landingPos, playerAim))
		beginRageCamera(function()
			return spider:GetPivot()
		end, function()
			return getPlayerAimPos(fallbackAnchor)
		end, 1.4)
		startSpideySensesOnSpider(spider)
		waitForRageSequence(spider, rageTrack, function()
			return getPlayerAimPos(fallbackAnchor)
		end)
		stopSpideySenses()

		if not encounterActive then
			finishEncounter(spider, nil)
			return
		end

		if rageTrack then
			rageTrack:Stop(0.2)
		end

		beginWebWindupCamera(function()
			return spider:GetPivot()
		end, function()
			return getPlayerAimPos(fallbackAnchor)
		end)
		waitForWebShootWindup(spider, webTrack, function()
			return getPlayerAimPos(fallbackAnchor)
		end)
	end

	if not encounterActive then
		finishEncounter(spider, nil)
		return
	end

	if not skipCutscene then
		-- already waited windup above
	else
		waitForWebShootWindup(spider, webTrack, function()
			return getPlayerAimPos(fallbackAnchor)
		end)
	end

	if not encounterActive then
		finishEncounter(spider, nil)
		return
	end

	playerAim = getPlayerAimPos(fallbackAnchor)
	faceCharacterToward(spider:GetPivot().Position)
	spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, playerAim))

	local web = createShootingWebProjectile()

	playerAim = getPlayerAimPos(fallbackAnchor)
	local spiderPivot = spider:GetPivot()
	local visualFront = spiderVisualFrontFlat(spiderPivot, playerAim)
	local spiderShoot = spiderPivot.Position + visualFront * 2.5
	local shotTarget = getPlayerChestPos(fallbackAnchor)
	local flightDir = shotTarget - spiderShoot
	if flightDir.Magnitude < 0.05 then
		flightDir = Vector3.new(0, 0, -1)
	else
		flightDir = flightDir.Unit
	end
	setWebProjectileCFrame(web, spiderShoot, flightDir)

	GameSoundEffects.playSpiderWebShot()
	setBgmWebSlow()

	if not skipCutscene then
		beginWebFollowCamera(function()
			return getWebProjectilePosition(web)
		end, function()
			return getPlayerAimPos(fallbackAnchor)
		end, function()
			local hrp = getPlayerHRP()
			return if hrp then hrp.Position else getPlayerAimPos(fallbackAnchor)
		end, 1.65)
	end

	ensureCutsceneGui()
	-- Skip mode: QTE only — no letterbox bars.
	if skipCutscene and cutsceneGui then
		local top = cutsceneGui:FindFirstChild("LetterTop")
		local bottom = cutsceneGui:FindFirstChild("LetterBottom")
		if top and top:IsA("GuiObject") then
			top.Visible = false
		end
		if bottom and bottom:IsA("GuiObject") then
			bottom.Visible = false
		end
	end
	local choice = C.TIMING_LETTERS[math.random(1, #C.TIMING_LETTERS)]
	local mobileInput = isMobileSpiderInput()
	refreshTimingUiPresentation(mobileInput, choice.label)
	if timingLetter and not mobileInput then
		timingLetter.TextColor3 = Color3.fromRGB(255, 248, 220)
	end
	if timingHint then
		timingHint.TextColor3 = Color3.fromRGB(220, 225, 240)
	end
	if timingRingStroke then
		timingRingStroke.Color = RING_IDLE
	end
	if timingRingScale then
		timingRingScale.Scale = C.RING_START_SCALE
	end
	if timingProgressFill then
		timingProgressFill.Size = UDim2.fromScale(0, 1)
		timingProgressFill.BackgroundColor3 = Color3.fromRGB(255, 220, 110)
	end
	if timingRootScale then
		timingRootScale.Scale = 0.82
	end
	pickRandomQtePosition()
	if timingRoot then
		timingRoot.Visible = true
	end
	if timingRootScale then
		TweenService:Create(timingRootScale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end

	local qteResolved = false
	local qteSuccess = false
	local currentEased = 0
	local travel = C.WEB_TRAVEL_TIME
	local start = os.clock()
	local inputConn: RBXScriptConnection? = nil
	local tapConn: RBXScriptConnection? = nil

	local function tryResolveQtePress(): boolean
		if qteResolved or not encounterActive then
			return false
		end
		if not MobileTouchGate.canTapUi() then
			return false
		end
		local pressAlpha = (os.clock() - start) / travel
		if pressAlpha < C.QTE_CLOSE_MIN then
			return false
		end
		qteResolved = true
		qteSuccess = pressAlpha <= C.QTE_CLOSE_MAX
		flashTimingResult(qteSuccess)
		return true
	end

	if timingTapBtn then
		timingTapBtn.Visible = mobileInput
		timingTapBtn.Active = mobileInput
	end
	if mobileInput and timingTapBtn then
		tapConn = timingTapBtn.Activated:Connect(function()
			if not MobileTouchGate.canTapUi() then
				return
			end
			if timingRootScale then
				TweenService:Create(timingRootScale, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Scale = 0.92,
				}):Play()
				task.delay(0.08, function()
					if timingRootScale then
						TweenService:Create(timingRootScale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
							Scale = 1,
						}):Play()
					end
				end)
			end
			tryResolveQtePress()
		end)
	end

	inputConn = UserInputService.InputBegan:Connect(function(input, _processed)
		-- Ignore `processed` so bush/UI can't swallow the dodge letter (often E).
		if qteResolved or not encounterActive or mobileInput then
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
		tryResolveQtePress()
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

		playerAim = getPlayerChestPos(fallbackAnchor)
		spider:PivotTo(cfFacingTarget(spider:GetPivot().Position, playerAim))
		shotTarget = getWebImpactPos(flightDir, getPlayerChestPos(fallbackAnchor), spider, web)
		currentEased = smoothstep(math.clamp(travelAlpha, 0, 1))
		local pos = spiderShoot:Lerp(shotTarget, currentEased)
		setWebProjectileCFrame(web, pos, flightDir)

		if timingProgressFill then
			timingProgressFill.Size = UDim2.fromScale(math.clamp(travelAlpha, 0, 1), 1)
			if travelAlpha >= C.QTE_CLOSE_MIN and travelAlpha <= C.QTE_CLOSE_MAX then
				timingProgressFill.BackgroundColor3 = Color3.fromRGB(80, 255, 140)
			elseif travelAlpha > C.QTE_CLOSE_MAX then
				timingProgressFill.BackgroundColor3 = Color3.fromRGB(255, 90, 90)
			else
				timingProgressFill.BackgroundColor3 = Color3.fromRGB(255, 220, 110)
			end
		end
		if timingRingScale then
			timingRingScale.Scale = ringScaleForEased(currentEased)
		end
		if timingRingStroke then
			if travelAlpha >= C.QTE_CLOSE_MIN and travelAlpha <= C.QTE_CLOSE_MAX then
				timingRingStroke.Color = GREEN_OK
				timingRingStroke.Transparency = 0.05
			else
				timingRingStroke.Color = RING_IDLE
				timingRingStroke.Transparency = 0.12
			end
		end
		if timingHint then
			if travelAlpha >= C.QTE_CLOSE_MIN and travelAlpha <= C.QTE_CLOSE_MAX then
				timingHint.Text = if mobileInput then "TAP!" else "NOW!"
				timingHint.TextColor3 = Color3.fromRGB(120, 255, 170)
			else
				timingHint.Text = if mobileInput then "WAIT..." else "GET READY"
				timingHint.TextColor3 = Color3.fromRGB(200, 205, 220)
			end
		end

		RunService.RenderStepped:Wait()
	end

	if inputConn then
		inputConn:Disconnect()
	end
	if tapConn then
		tapConn:Disconnect()
	end
	if timingTapBtn then
		timingTapBtn.Visible = false
		timingTapBtn.Active = false
	end

	if not qteResolved then
		flashTimingResult(false)
		qteResolved = true
		qteSuccess = false
	end

	hideTimingQTE()

	if dodgeResolved then
		task.wait(0.22)
		if not skipCutscene then
			easeCameraBackToPlayer(0.55, spider)
			waitSec(0.2)
		end
		fadeWebProjectile(web, C.WEB_FADE_OUT)
		fadeSpider(spider)
		waitSec(0.4)
		finishEncounter(spider, web)
		return
	end

	task.wait(0.1)
	stopCameraRig()

	local hitTarget = getWebImpactPos(flightDir, getPlayerChestPos(fallbackAnchor), spider, web)
	snapWebToImpact(web, getWebProjectilePosition(web), hitTarget, flightDir, 0.14)
	holdHitImpactCamera(hitTarget, spider:GetPivot().Position)

	fadeWebProjectile(web, math.min(C.WEB_FADE_OUT, 0.22))
	GameSoundEffects.playSpiderGettingHit()
	flashCharacterHit()
	playSpiderHitBlowVfx(hitTarget)
	-- Restore BGM before death so ReviveController doesn't snapshot the combat slowdown.
	forceRestoreBgm()
	killPlayerFromSpiderHit()
	task.delay(0.15, killPlayerFromSpiderHit)
	waitSec(0.95)
	finishEncounter(spider, web)
	return
end

function BushSpiderEncounterController.isActive(): boolean
	return encounterActive
end

function BushSpiderEncounterController.tryTriggerAfterBrainrotAccept(_model: Model)
	if not C.ENABLED or encounterActive then
		FloatingClaimCutscene.releaseMoveLock()
		return
	end
	local hrp = getPlayerHRP()
	local anchor = if hrp then hrp.Position else Vector3.zero
	task.spawn(function()
		runEncounter(anchor)
	end)
end

function BushSpiderEncounterController.init()
	MobileTouchGate.init()

	player.CharacterAdded:Connect(function()
		clearSpiderEncounterCharacterFx()
		forceRestoreBgm()
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 60)
	if remotes then
		local re = remotes:WaitForChild("BushSpiderEncounterKill", 15)
		if re and re:IsA("RemoteEvent") then
			spiderKillRE = re
		end
	end

	BushFloatingClaimController.registerAcceptHook(function(model: Model)
		if BushFloatingClaimController.consumeAmbushOnAccept(model) then
			BushSpiderEncounterController.tryTriggerAfterBrainrotAccept(model)
		else
			FloatingClaimCutscene.releaseMoveLock()
		end
	end)
end

return BushSpiderEncounterController
