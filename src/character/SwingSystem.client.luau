-- SwingSystem.client.luau
-- Swing UI + attach share SwingDetection.canSwing (same range/rules). Server validates RequestSwingAttach.
-- Pendulum rope (max travel from hook in SwingConfig); WASD nudges along arc; release scales velocity by Power upgrade.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local player = Players.LocalPlayer
local camera: Camera = workspace.CurrentCamera

local gameSoundEffects: any = nil

local function getGameSoundEffects()
	if gameSoundEffects then
		return gameSoundEffects
	end
	local ps = player:FindFirstChild("PlayerScripts")
	if not ps then
		return nil
	end
	local client = ps:FindFirstChild("Client")
	if not client then
		return nil
	end
	local mod = client:FindFirstChild("GameSoundEffects")
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require, mod)
	if ok then
		gameSoundEffects = loaded
	end
	return gameSoundEffects
end

task.defer(function()
	local ps = player:WaitForChild("PlayerScripts", 20)
	if not ps then
		return
	end
	ps:WaitForChild("Client", 20)
	getGameSoundEffects()
end)

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local SwingProgression = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingProgression"))
local SwingConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingConfig"))
local SwingDetection = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingDetection"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 30)
local swingAttachFn = remotesFolder:WaitForChild("RequestSwingAttach", 30) :: RemoteFunction

-- Unique name per boot() so BindToRenderStep doesn’t collide across respawns.
local r6RenderBindSerial = 0

-- ───────────────────────────── TUNABLES ──────────────────────────────────────
local BASE_RANGE         = 56    -- grapple search radius in studs (starting reach)
local BASE_ROPE          = 56
local BASE_FORCE         = 68    -- camera-look tangent steering (starting power)
local FORCE_DECAY_TIME   = 6.0
local FORCE_MIN_MULT     = 0.75
local ANGULAR_DAMP       = 6.0
local SPRING_STIFFNESS   = SwingConfig.SPRING_STIFFNESS
local SPRING_DAMPING     = SwingConfig.SPRING_DAMPING
local MAX_ROPE_DISTANCE  = SwingConfig.MAX_ROPE_DISTANCE
local ZIP_TOWARD_DV          = 19
local LAUNCH_CAMERA_BLEND    = 0.28  -- how much camera look steers launch vs current arc direction
local LAUNCH_FORWARD_CAMERA_MIX = 0.24
local LAUNCH_DURATION        = 0.42  -- seconds post-release camera/FOV treats player as launched
local REATTACH_ZIP_MULT      = 0.4   -- zip impulse scale when re-hooking soon after a release
local REATTACH_ZIP_GRACE      = 0.4   -- seconds after detach where zip is reduced
local MIN_SWING_HOLD_LAUNCH   = 0.1  -- shorter swings get a softer release (anti spam-fling)
local REATTACH_AIR_GRACE     = SwingConfig.REATTACH_AIR_GRACE
local GRAPPLE_INPUT_COOLDOWN = SwingConfig.GRAPPLE_INPUT_COOLDOWN
local MAX_SWING_SPEED        = 80
local FOV_MAX              = 96
local FOV_SPEED            = 4.2   -- smooth widen while accelerating on the arc
local LANDING_BLOCK_VEL_MIN = 18  -- landing speed that spawns block burst + camera shake
local LANDING_BLOCK_VEL_MAX = 92
local LANDING_CAM_SHAKE_DURATION = 0.36
local LANDING_CAM_SHAKE_POS = 0.13
-- Hanging swing camera: lag + roll only (no positional shake / high-frequency wobble).
local CAM_LAG_STUDS_MAX      = 0.95
local CAM_LAG_SMOOTH         = 3.8
local CAM_ROLL_DEG_MAX       = 2.8
local CAM_ROLL_SMOOTH        = 6.5
local ATTACH_PUNCH_DURATION  = 0.3
local ATTACH_PUNCH_FOV       = 5.5  -- brief zoom-in on hook
local LAUNCH_FOV_BOOST       = 4.5  -- tiny release FOV punch (layered on speed FOV)
local LAUNCH_FOV_DURATION    = 0.38
local LAUNCH_CAM_SHAKE_DURATION = 0.24
local LAUNCH_CAM_SHAKE_MAX   = 0.28
local SWING_CAM_RENDER_STEP  = "SwingSystem_CameraFX"
-- Pendulum arc when rope is extended; floor guard avoids slamming into plots.
local SWING_FLOOR_CLEARANCE = 6
local SWING_MAX_DROP_BELOW_ANCHOR = 40
local SWING_EXT_ARC_START = 0.42

local COLOR_NEAR     = Color3.fromRGB(90, 210, 255)
local COLOR_BEST     = Color3.fromRGB(55, 255, 105)
local COLOR_BLOCKED  = Color3.fromRGB(255, 72, 88) -- safe zone: in range but grapple disabled
local BEAM_GREEN_A   = Color3.fromRGB(30, 255, 100)
local BEAM_GREEN_B   = Color3.fromRGB(10, 200, 70)

--[[  R6 swing hang clips (camera-right vine → RightHand clip index 1; camera-left → Left clip index 2):
	HangingRight  rbxassetid://72668212449531
	HangingLeft   rbxassetid://85555597079083
]]
local ANIM_HANGING_RIGHT = "rbxassetid://72668212449531"
local ANIM_HANGING_LEFT = "rbxassetid://85555597079083"
-- ─────────────────────────────────────────────────────────────────────────────

local function isJumpReleaseKey(key: Enum.KeyCode): boolean
	return key == Enum.KeyCode.Space or key == Enum.KeyCode.ButtonA
end

local function boot(character: Model)
	local hrp      = character:WaitForChild("HumanoidRootPart", 30) :: BasePart
	local humanoid = character:WaitForChild("Humanoid",          30) :: Humanoid
	local baseWalkSpeed = humanoid.WalkSpeed
	humanoid:SetAttribute("BrainrotBaseWalkSpeed", baseWalkSpeed)
	local function applyBrainrotWalkSpeed()
		local slow = player:GetAttribute("SlowWalkEnabled") == true
		humanoid.WalkSpeed = baseWalkSpeed * (if slow then 1 else 1.75)
	end
	applyBrainrotWalkSpeed()
	local walkSpeedAttrConn = player:GetAttributeChangedSignal("SlowWalkEnabled"):Connect(applyBrainrotWalkSpeed)

	-- ── Animations / R6 Motor6D fallback ─────────────────────────────────────
	-- Load the hang clip first. If it succeeds, use Animator-only (no Motor6D wrestling).
	-- Procedural shoulders run only when the clip fails and we have classic R6 joints.
	local animateScript: Instance? = character:FindFirstChild("Animate")
	local function setDefaultAnimateEnabled(on: boolean)
		local animSc = animateScript or character:FindFirstChild("Animate")
		if animSc then
			animateScript = animSc
		end
		if animSc and animSc:IsA("LocalScript") then
			(animSc :: LocalScript).Disabled = not on
		end
	end

	local useR6Procedural = false
	local shoulderSwingAlpha = 0
	local r6Pose = {
		rs = nil :: Motor6D?,
		ls = nil :: Motor6D?,
		baseRS = nil :: CFrame?,
		baseLS = nil :: CFrame?,
		swingIdx = 1,
	}

	local animTracks: { AnimationTrack } = {}
	local activeTrack: AnimationTrack? = nil
	--- Camera-relative side index (1 right / 2 left): matches animTracks[1]/[2] and procedural pose.
	local lastSwingAnimIdx: number? = nil

	local animator = humanoid:WaitForChild("Animator") :: Animator
	for _, assetId in { ANIM_HANGING_RIGHT, ANIM_HANGING_LEFT } do
		local anim = Instance.new("Animation")
		anim.AnimationId = assetId
		local ok, trackOrErr = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and typeof(trackOrErr) == "Instance" and trackOrErr:IsA("AnimationTrack") then
			local tr = trackOrErr :: AnimationTrack
			tr.Priority = Enum.AnimationPriority.Action4
			tr.Looped = true
			table.insert(animTracks, tr)
		else
			warn(
				"[SwingSystem] Failed to load swing animation:",
				assetId,
				trackOrErr,
				"(permissions / deleted asset / wrong rig vs character)"
			)
		end
	end

	local hasR6Shoulders = false
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local torso = character:WaitForChild("Torso", 10)
		if torso then
			local rs = torso:FindFirstChild("Right Shoulder")
			local ls = torso:FindFirstChild("Left Shoulder")
			if rs and ls and rs:IsA("Motor6D") and ls:IsA("Motor6D") then
				hasR6Shoulders = true
				r6Pose.rs = rs
				r6Pose.ls = ls
				r6Pose.baseRS = rs.C0
				r6Pose.baseLS = ls.C0
			end
		end
	end

	useR6Procedural = hasR6Shoulders and (#animTracks == 0)

	if #animTracks == 0 and not useR6Procedural then
		warn("[SwingSystem] No hang animation and no R6 shoulder fallback — swinging has no arm pose.")
	end

	local function swingSideIdx(attachWorld: Vector3): number
		local idx = 1
		local flatT = Vector3.new(attachWorld.X - hrp.Position.X, 0, attachWorld.Z - hrp.Position.Z)
		local flatR = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
		if flatT.Magnitude > 0.2 and flatR.Magnitude > 0.05 then
			idx = if flatT.Unit:Dot(flatR.Unit) >= 0 then 1 else 2
		end
		return idx
	end

	local function r6HangTargets(idx: number): (CFrame, CFrame)
		local br = r6Pose.baseRS :: CFrame
		local bl = r6Pose.baseLS :: CFrame
		if idx == 1 then
			local upRR = CFrame.Angles(math.rad(-128), math.rad(-38), math.rad(12))
			local upLR = CFrame.Angles(math.rad(-108), math.rad(22), math.rad(-6))
			return br * upRR, bl * upLR
		end
		local upRL = CFrame.Angles(math.rad(-108), math.rad(-22), math.rad(6))
		local upLL = CFrame.Angles(math.rad(-128), math.rad(38), math.rad(-12))
		return br * upRL, bl * upLL
	end

	local function playSwingAnim(attachWorld: Vector3)
		local idx = swingSideIdx(attachWorld)
		if useR6Procedural then
			r6Pose.swingIdx = idx
			lastSwingAnimIdx = idx
			return
		end
		if #animTracks == 0 then
			return
		end
		idx = math.clamp(idx, 1, #animTracks)
		lastSwingAnimIdx = idx
		local track = animTracks[idx] :: AnimationTrack
		for _, t in animTracks do
			if t ~= track then
				t:Stop(0)
			end
		end
		track:Play(0.12)
		activeTrack = track
	end

	local function stopSwingAnim()
		lastSwingAnimIdx = nil
		if useR6Procedural then
			return
		end
		for _, t in animTracks do
			t:Stop(0.2)
		end
		activeTrack = nil
	end

	-- ── Landing block burst ───────────────────────────────────────────────────
	-- Grass/dirt chunk colours — top face green, body earthy brown
	local BLOCK_COLORS = {
		Color3.fromRGB(106, 127,  63),  -- dark grass green
		Color3.fromRGB( 82, 109,  39),  -- olive grass
		Color3.fromRGB(121, 152,  57),  -- medium grass
		Color3.fromRGB( 91,  65,  43),  -- dirt brown
		Color3.fromRGB(110,  82,  50),  -- light dirt
	}

	local function spawnLandingBlocks(intensity: number)
		-- Raycast straight down to find the floor
		local origin    = hrp.Position
		local rayResult = workspace:Raycast(origin, Vector3.new(0, -8, 0),
			RaycastParams.new())
		local floorY = rayResult and rayResult.Position.Y or (origin.Y - 3)
		local spawnPos = Vector3.new(origin.X, floorY, origin.Z)

		local count = math.floor(5 + intensity * 7)  -- 5–12 blocks
		for _ = 1, count do
			local size = math.random(45, 120) / 100  -- 0.45–1.2 studs — chunky blocks
			local p = Instance.new("Part")
			p.Size             = Vector3.new(size, size * math.random(60, 140) / 100, size)
			p.Color            = BLOCK_COLORS[math.random(1, #BLOCK_COLORS)]
			p.Material         = Enum.Material.Grass
			p.CastShadow       = false
			p.CanCollide       = false
			p.Anchored         = false
			p.CFrame           = CFrame.new(spawnPos + Vector3.new(
				math.random(-20, 20) / 10, 0.2, math.random(-20, 20) / 10))
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			p.Parent           = workspace

			-- Outward + upward velocity with some tumble
			local angle  = math.random() * math.pi * 2
			local speed  = math.random(14, 28) * (0.7 + intensity * 0.3)
			local upward = math.random(12, 22) * (0.7 + intensity * 0.3)
			p.AssemblyLinearVelocity  = Vector3.new(math.cos(angle) * speed, upward, math.sin(angle) * speed)
			p.AssemblyAngularVelocity = Vector3.new(
				math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))

			-- Fade + shrink then auto-clean
			TweenService:Create(p, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1, Size = Vector3.one * 0.05 }):Play()
			Debris:AddItem(p, 0.75)
		end
	end

	-- ── Landing / swing camera state ──────────────────────────────────────────
	local landingSpeed = 0
	local landedFromSwing = false
	local swingCamRoll = 0
	local swingCamLagWorld = Vector3.zero
	local attachCamClock = -1e9
	local launchCamClock = -1e9
	local launchCamShakeIntensity = 0
	local launchFovIntensity = 0
	local landingCamClock = -1e9
	local landingCamShakeIntensity = 0
	local landingCamSeed = 0

	local function landingImpactAlpha(speed: number): number
		return math.clamp(
			(speed - LANDING_BLOCK_VEL_MIN) / (LANDING_BLOCK_VEL_MAX - LANDING_BLOCK_VEL_MIN),
			0,
			1
		)
	end

	-- ── Upgrade stats (unified curve via SwingProgression) ───────────────────
	local swingRange = BASE_RANGE
	local swingForce = BASE_FORCE
	local ropeLength = BASE_ROPE

	local dynMaxSwingSpeed = MAX_SWING_SPEED
	local dynSwingArcForce = 34
	local dynSwingSpeedPump = 0.9
	local dynZipToward = ZIP_TOWARD_DV
	local dynLaunchImpulseBase = 20
	local dynLaunchMomentumRatio = 0.24
	local dynLaunchVelocityCarry = 0.20
	local dynMaxLaunchSpeed = 100
	local dynLaunchChargeBonus = 14
	local dynLaunchUpImpulse = 4.5
	local dynLaunchDeadhangImpulse = 22
	local dynLaunchMultiplier = SwingConfig.LAUNCH_BASE_MULTIPLIER

	local function refreshStats()
		local ropePts = player:GetAttribute("RopeLength")
		local ropeAttrPts = if typeof(ropePts) == "number" then ropePts else 0

		local powerLevel = player:GetAttribute(SwingUpgrades.POWER_LEVEL_ATTR)
		local ropeLevel = player:GetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR)
		if typeof(powerLevel) ~= "number" then
			powerLevel = 0
		end
		if typeof(ropeLevel) ~= "number" then
			ropeLevel = 0
		end

		local ps = SwingProgression.powerStats(powerLevel)
		local rs = SwingProgression.ropeStats(ropeLevel)

		swingForce = ps.steeringForce
		dynMaxSwingSpeed = ps.maxSwingSpeed
		dynSwingArcForce = ps.swingArcForce
		dynSwingSpeedPump = ps.swingSpeedPump
		dynZipToward = ps.zipToward
		dynLaunchImpulseBase = ps.launchImpulseBase
		dynLaunchMomentumRatio = ps.launchMomentumRatio
		dynLaunchVelocityCarry = ps.launchVelocityCarry
		dynMaxLaunchSpeed = ps.maxLaunchSpeed
		dynLaunchChargeBonus = ps.launchChargeBonus
		dynLaunchUpImpulse = ps.launchUpImpulse
		dynLaunchDeadhangImpulse = ps.launchDeadhangImpulse
		dynLaunchMultiplier = ps.launchMultiplier

		swingRange = rs.reachStuds
		ropeLength = math.max(rs.reachStuds + ropeAttrPts * 2, 8)
	end
	refreshStats()

	local swingRayParams = RaycastParams.new()
	swingRayParams.FilterType = Enum.RaycastFilterType.Exclude
	swingRayParams.FilterDescendantsInstances = { character }

	local function pendulumArcDir(radial: Vector3): Vector3?
		local grav = Vector3.new(0, -workspace.Gravity, 0)
		local tangFall = grav - radial * grav:Dot(radial)
		if tangFall.Magnitude < 0.06 then
			return nil
		end
		return tangFall.Unit
	end

	local function swingFloorScale(anchorWorld: Vector3): number
		local ray = workspace:Raycast(hrp.Position, Vector3.new(0, -160, 0), swingRayParams)
		local floorY = if ray then ray.Position.Y else hrp.Position.Y - 80
		local minSafeY = math.max(floorY + SWING_FLOOR_CLEARANCE, anchorWorld.Y - SWING_MAX_DROP_BELOW_ANCHOR)
		local dropMargin = hrp.Position.Y - minSafeY
		if dropMargin <= 0 then
			return 0.1
		end
		if dropMargin < 10 then
			return math.clamp(dropMargin / 10, 0.15, 1)
		end
		return 1
	end

	local function computeSwingArcForce(anchorWorld: Vector3, radial: Vector3, extT: number, mult: number, mass: number): Vector3
		local arcDir = pendulumArcDir(radial)
		if not arcDir then
			return Vector3.zero
		end
		local extBoost = math.clamp((extT - SWING_EXT_ARC_START) / (1 - SWING_EXT_ARC_START), 0, 1)
		extBoost = 0.38 + extBoost * 0.92
		local floorScale = swingFloorScale(anchorWorld)
		local strength = dynSwingArcForce * mult * extBoost * floorScale
		return arcDir * strength * mass
	end

	-- Grapple only works to targets within rope reach (swingRange can be larger from upgrades)
	local function attachRadius(): number
		return math.min(swingRange, ropeLength)
	end

	local statConns = {
		player:GetAttributeChangedSignal(SwingUpgrades.POWER_LEVEL_ATTR):Connect(refreshStats),
		player:GetAttributeChangedSignal(SwingUpgrades.ROPE_LEVEL_ATTR):Connect(refreshStats),
		player:GetAttributeChangedSignal("RopeLength"):Connect(refreshStats),
		player:GetAttributeChangedSignal("SwingForce"):Connect(refreshStats),
		player:GetAttributeChangedSignal("SwingRange"):Connect(refreshStats),
	}

	-- ── State ─────────────────────────────────────────────────────────────────
	local isSwinging  = false
	local isLaunched  = false
	local isAirborne  = false
	local swingTimer  = 0
	local prevInRng: { [BasePart]: boolean } = {}

	local swingCamBindSerial = 0
	swingCamBindSerial += 1
	local swingCamBindName = SWING_CAM_RENDER_STEP .. "_" .. tostring(swingCamBindSerial)

	local function expSmoothScalar(current: number, target: number, dt: number, rate: number): number
		return current + (target - current) * (1 - math.exp(-dt * rate))
	end

	local function resetSwingCameraState()
		swingCamRoll = 0
		swingCamLagWorld = Vector3.zero
		humanoid.CameraOffset = Vector3.zero
	end

	local function isLandingShakeActive(now: number): boolean
		local landingAge = now - landingCamClock
		return landingAge >= 0
			and landingAge < LANDING_CAM_SHAKE_DURATION
			and landingCamShakeIntensity > 0.02
	end

	-- View-relative shake via CameraOffset (never touches CFrame — avoids drag / camera fight).
	local function computeLandingCameraOffset(now: number): Vector3
		local age = now - landingCamClock
		if age < 0 or age >= LANDING_CAM_SHAKE_DURATION or landingCamShakeIntensity <= 0.02 then
			return Vector3.zero
		end
		local u = age / LANDING_CAM_SHAKE_DURATION
		local decay = (1 - u) * (1 - u)
		local intensity = landingCamShakeIntensity * decay
		local amp = LANDING_CAM_SHAKE_POS * intensity
		local seed = landingCamSeed
		return Vector3.new(
			math.sin(age * 26 + seed) * amp + math.sin(age * 39 + seed * 1.6) * amp * 0.32,
			math.sin(age * 22 + seed * 2.1) * amp * 0.88 + math.sin(age * 34 + seed * 0.8) * amp * 0.22,
			math.sin(age * 31 + seed * 1.3) * amp * 0.18
		)
	end

	local function applySwingCameraFx(dt: number)
		if not hrp.Parent then
			return
		end

		local now = os.clock()
		local attachAge = now - attachCamClock
		local launchAge = now - launchCamClock
		local attachActive = attachAge >= 0 and attachAge < ATTACH_PUNCH_DURATION
		local launchActive = isLaunched or (launchAge >= 0 and launchAge < LAUNCH_FOV_DURATION)
		local landingShakeActive = isLandingShakeActive(now)

		if landingShakeActive and not isSwinging and not attachActive and not launchActive then
			swingCamRoll = expSmoothScalar(swingCamRoll, 0, dt, 20)
			swingCamLagWorld = swingCamLagWorld:Lerp(Vector3.zero, math.min(1, dt * 20))
			humanoid.CameraOffset = computeLandingCameraOffset(now)
			return
		end

		if not isSwinging and not attachActive and not launchActive and not landingShakeActive then
			swingCamRoll = expSmoothScalar(swingCamRoll, 0, dt, 14)
			swingCamLagWorld = swingCamLagWorld:Lerp(Vector3.zero, math.min(1, dt * 11))
			if math.abs(swingCamRoll) < 0.0004 and swingCamLagWorld.Magnitude < 0.002 then
				resetSwingCameraState()
			end
			return
		end

		if not landingShakeActive then
			humanoid.CameraOffset = Vector3.zero
		end

		local vel = hrp.AssemblyLinearVelocity
		local speedRef = math.max(dynMaxLaunchSpeed, dynMaxSwingSpeed, 1)
		local speedT = math.clamp(vel.Magnitude / speedRef, 0, 1)

		local targetRoll = 0
		if (isSwinging or isLaunched) and vel.Magnitude > 4 then
			local camRight = camera.CFrame.RightVector
			local flatVel = Vector3.new(vel.X, 0, vel.Z)
			if flatVel.Magnitude > 0.6 then
				local lateral = camRight:Dot(flatVel.Unit)
				local rollMax = math.rad(CAM_ROLL_DEG_MAX)
				targetRoll = math.clamp(lateral * speedT * rollMax, -rollMax, rollMax)
			end
		end
		swingCamRoll = expSmoothScalar(swingCamRoll, targetRoll, dt, CAM_ROLL_SMOOTH)

		local lagTarget = Vector3.zero
		if (isSwinging or isLaunched) and vel.Magnitude > 5 then
			lagTarget = -vel.Unit * (CAM_LAG_STUDS_MAX * (0.2 + 0.8 * speedT))
		end
		swingCamLagWorld = swingCamLagWorld:Lerp(lagTarget, math.min(1, dt * CAM_LAG_SMOOTH))

		local cf = camera.CFrame
		if swingCamLagWorld.Magnitude > 0.001 then
			cf = cf + swingCamLagWorld
		end
		if math.abs(swingCamRoll) > 0.0001 then
			cf = cf * CFrame.Angles(0, 0, swingCamRoll)
		end

		if launchAge >= 0 and launchAge < LAUNCH_CAM_SHAKE_DURATION and launchCamShakeIntensity > 0.04 then
			local u = launchAge / LAUNCH_CAM_SHAKE_DURATION
			local decay = (1 - u) * (1 - u)
			local shake = launchCamShakeIntensity * decay
			local t = now * 21
			cf += Vector3.new(
				(math.noise(t, 0, 0) - 0.5) * 2 * LAUNCH_CAM_SHAKE_MAX * shake,
				(math.noise(0, t, 1) - 0.5) * 2 * LAUNCH_CAM_SHAKE_MAX * shake * 0.35,
				(math.noise(t, 2, 0.5) - 0.5) * 2 * LAUNCH_CAM_SHAKE_MAX * shake * 0.22
			)
		end

		camera.CFrame = cf
		if landingShakeActive then
			humanoid.CameraOffset = computeLandingCameraOffset(now)
		end
	end

	RunService:BindToRenderStep(swingCamBindName, Enum.RenderPriority.Camera.Value + 1, applySwingCameraFx)

	-- Remove legacy launch streak ScreenGui (horizontal speed lines) if left from older builds.
	local function destroyLaunchSpeedFx()
		local pg = player:FindFirstChild("PlayerGui")
		if pg then
			local gui = pg:FindFirstChild("SwingLaunchSpeedLines")
			if gui then
				gui:Destroy()
			end
		end
		local blur = camera:FindFirstChild("SwingLaunchBlur")
		if blur and blur:IsA("BlurEffect") then
			blur:Destroy()
		end
	end
	destroyLaunchSpeedFx()

	-- Swing constraints / force
	local ropeInst:      SpringConstraint? = nil
	local ropeBodyAtt:   Attachment?       = nil
	local ropeAnchorAtt: Attachment?       = nil
	local forceInst:     VectorForce?      = nil
	local forceAtt:      Attachment?       = nil

	local swingTargetPart: BasePart? = nil
	local beamInst: Beam?       = nil
	local beamA0:   Attachment? = nil
	local beamA1:   Attachment? = nil
	local lastSwingEndClock = -1e9
	local lastGrappleInputClock = -1e9
	local lastSwingAttachClock = -1e9
	local SWING_ATTACH_JUMP_DEBOUNCE = 0.14 -- ignore duplicate JumpRequest right after hooking (same tap)
	-- Touch jump button does not set IsKeyDown(Space); Heartbeat uses this for swing-charge ring fill.
	local mobileJumpHeld = false

	-- R6: Animator applies Motor6D.Transform after Heartbeat — must override last frame via RenderStep + clear Transform.
	local r6RenderBindName: string? = nil
	if useR6Procedural then
		r6RenderBindSerial += 1
		r6RenderBindName = "SwingSystem_R6Hang_" .. tostring(r6RenderBindSerial)
		RunService:BindToRenderStep(
			r6RenderBindName,
			Enum.RenderPriority.Last.Value + 10,
			function(dt: number)
				if not r6Pose.rs or not r6Pose.ls or not r6Pose.baseRS or not r6Pose.baseLS then
					return
				end
				local targetAlpha = if isSwinging then 1 else 0
				shoulderSwingAlpha += (targetAlpha - shoulderSwingAlpha) * math.min(1, dt * 14)
				if shoulderSwingAlpha < 0.001 then
					return
				end
				local trs, tls = r6HangTargets(r6Pose.swingIdx)
				r6Pose.rs.Transform = CFrame.new()
				r6Pose.ls.Transform = CFrame.new()
				r6Pose.rs.C0 = r6Pose.baseRS:Lerp(trs, shoulderSwingAlpha)
				r6Pose.ls.C0 = r6Pose.baseLS:Lerp(tls, shoulderSwingAlpha)
			end
		)
	end

	local function closestAttachWorldOnPart(p: BasePart): Vector3
		return SwingDetection.closestAttachWorldOnPart(p, hrp.Position)
	end
	type VisEntry = { bb: BillboardGui, ring: Frame, dot: Frame, lbl: TextLabel }
	local visMap: { [BasePart]: VisEntry } = {}

	-- During swing: Space hold fills inner dot toward outer ring (visual only)
	type SwingChargeHud = { bb: BillboardGui, ring: Frame, dot: Frame }
	local swingChargeHud: SwingChargeHud? = nil
	local swingChargeFill = 0
	local SWING_CHARGE_HOLD_SEC = 1.15
	local CHARGE_DOT_MIN = 8
	-- Ring outer ~56px; stroke eats ~5px — fill nearly flush with inner edge
	local CHARGE_DOT_MAX = 52

	local function makeVisual(part: BasePart, color: Color3): VisEntry
		-- BillboardGui tall enough to hold ring (56px) + gap + label (20px)
		local bb = Instance.new("BillboardGui")
		bb.Adornee         = part
		bb.Size            = UDim2.fromOffset(110, 88)
		bb.StudsOffset     = Vector3.new(0, part.Size.Y * 0.5 + 0.5, 0)
		bb.AlwaysOnTop     = true
		bb.LightInfluence  = 0
		bb.Parent          = workspace

		-- Ring (top 56×56, horizontally centered)
		local ring = Instance.new("Frame")
		ring.Size                   = UDim2.fromOffset(56, 56)
		ring.Position               = UDim2.new(0.5, -28, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel        = 0
		ring.Parent                 = bb

		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(1, 0)
		ringCorner.Parent       = ring

		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color        = color
		ringStroke.Thickness    = 2.5
		ringStroke.Transparency = 0.08
		ringStroke.Parent       = ring

		-- Center dot
		local dot = Instance.new("Frame")
		dot.Size                   = UDim2.fromOffset(8, 8)
		dot.Position               = UDim2.new(0.5, -4, 0.5, -4)
		dot.BackgroundColor3       = color
		dot.BackgroundTransparency = 0
		dot.BorderSizePixel        = 0
		dot.Parent                 = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent       = dot

		-- Label below ring (fits inside billboard)
		local lbl = Instance.new("TextLabel")
		lbl.Size                = UDim2.new(1, 0, 0, 22)
		lbl.Position            = UDim2.new(0, 0, 0, 62)
		lbl.BackgroundTransparency = 1
		lbl.Text                = "JUMP  ·  swing"
		lbl.TextColor3          = color
		lbl.TextTransparency    = 0.08
		lbl.TextSize            = 12
		lbl.Font                = Enum.Font.GothamBold
		lbl.TextXAlignment      = Enum.TextXAlignment.Center
		lbl.Parent              = bb

		return { bb = bb, ring = ring, dot = dot, lbl = lbl }
	end

	local function setVisualColor(v: VisEntry, color: Color3)
		local stroke = v.ring:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Color = color end
		v.dot.BackgroundColor3 = color
		v.lbl.TextColor3       = color
	end

	local function addVisual(part: BasePart)
		if visMap[part] then return end
		visMap[part] = makeVisual(part, COLOR_NEAR)
	end

	local function removeVisual(part: BasePart)
		local v = visMap[part]
		if not v then return end
		v.bb:Destroy()
		visMap[part] = nil
	end

	local function clearVisuals()
		for part in visMap do
			removeVisual(part)
		end
	end

	local function destroySwingChargeHud()
		if swingChargeHud then
			swingChargeHud.bb:Destroy()
			swingChargeHud = nil
		end
		swingChargeFill = 0
	end

	local function layoutSwingChargeDot()
		if not swingChargeHud then
			return
		end
		local t = swingChargeFill
		local px = CHARGE_DOT_MIN + (CHARGE_DOT_MAX - CHARGE_DOT_MIN) * t
		px = math.floor(px + 0.5)
		local dot = swingChargeHud.dot
		dot.Size = UDim2.fromOffset(px, px)
		dot.Position = UDim2.new(0.5, -px * 0.5, 0.5, -px * 0.5)
	end

	local function ensureSwingChargeHud(vinePart: BasePart)
		if swingChargeHud then
			return
		end
		local bb = Instance.new("BillboardGui")
		bb.Name = "SwingChargeHud"
		bb.Adornee = vinePart
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.Size = UDim2.fromOffset(110, 88)
		bb.StudsOffset = Vector3.new(0, vinePart.Size.Y * 0.5 + 0.5, 0)
		bb.Parent = workspace

		local ring = Instance.new("Frame")
		ring.Size = UDim2.fromOffset(56, 56)
		ring.Position = UDim2.new(0.5, -28, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Parent = bb

		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(1, 0)
		ringCorner.Parent = ring

		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color = BEAM_GREEN_A
		ringStroke.Thickness = 2.5
		ringStroke.Transparency = 0.06
		ringStroke.Parent = ring

		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(CHARGE_DOT_MIN, CHARGE_DOT_MIN)
		dot.Position = UDim2.new(0.5, -4, 0.5, -4)
		dot.BackgroundColor3 = BEAM_GREEN_A
		dot.BorderSizePixel = 0
		dot.Parent = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, 0, 0, 22)
		lbl.Position = UDim2.new(0, 0, 0, 62)
		lbl.BackgroundTransparency = 1
		lbl.Text = "JUMP  ·  swing"
		lbl.TextColor3 = BEAM_GREEN_A
		lbl.TextTransparency = 0.08
		lbl.TextSize = 12
		lbl.Font = Enum.Font.GothamBold
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.Parent = bb

		swingChargeHud = { bb = bb, ring = ring, dot = dot }
		layoutSwingChargeDot()
	end

	-- ── Rope beam (visual: wire from R6 hand to vine; physics stay on HRP) ─────
	local BEAM_GRIP_R6 = Vector3.new(0, -1.15, 0)

	local function handPartForSwingSide(sideIdx: number): BasePart?
		local n = if sideIdx == 1 then "Right Arm" else "Left Arm"
		local p = character:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			return p
		end
		return nil
	end

	local function placeBeamGripAttachment(att: Attachment, sideIdx: number)
		local hand = handPartForSwingSide(sideIdx)
		if hand then
			att.Parent = hand
			att.Position = BEAM_GRIP_R6
		else
			att.Parent = hrp
			att.Position = Vector3.new(0, 1.25, 0)
		end
	end

	local function spawnBeam(attachWorld: Vector3)
		local a0 = Instance.new("Attachment")
		placeBeamGripAttachment(a0, swingSideIdx(attachWorld))
		beamA0 = a0

		beamA1 = nil -- vine end uses rope anchor attachment (same point as rope)

		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = ropeAnchorAtt
		b.Width0        = 0.14
		b.Width1        = 0.1
		b.Color         = ColorSequence.new(BEAM_GREEN_A, BEAM_GREEN_B)
		b.Transparency  = NumberSequence.new(0.08)
		b.LightEmission = 0.55
		b.FaceCamera    = true
		b.Segments      = 16
		b.CurveSize0    = 0
		b.CurveSize1    = 0
		b.Parent        = character
		beamInst        = b
	end

	local function destroyBeam()
		if beamA0 then beamA0:Destroy(); beamA0 = nil end
		if beamInst then beamInst:Destroy(); beamInst = nil end
	end

	-- Preview tracer: transparent line to the grapple point whenever the swing UI shows (hidden while swinging).
	local previewBeam: Beam? = nil
	local previewAttFrom: Attachment? = nil
	local previewAttTo: Attachment? = nil
	local previewTarget: BasePart? = nil

	local PREVIEW_WHITE = Color3.new(1, 1, 1)
	local PREVIEW_TRANSPARENCY_OK = 0.12
	local PREVIEW_TRANSPARENCY_BLOCKED = 0.4
	local PREVIEW_WIDTH = 0.1
	local PREVIEW_DASH_COUNT = 18

	local function previewDashedTransparency(alpha: number): NumberSequence
		local keypoints: { NumberSequenceKeypoint } = {}
		for i = 0, PREVIEW_DASH_COUNT do
			local t = i / PREVIEW_DASH_COUNT
			local solid = i % 2 == 0
			table.insert(keypoints, NumberSequenceKeypoint.new(t, if solid then alpha else 1))
		end
		return NumberSequence.new(keypoints)
	end

	local function destroyPreviewTracer()
		if previewAttFrom then
			previewAttFrom:Destroy()
			previewAttFrom = nil
		end
		if previewAttTo then
			previewAttTo:Destroy()
			previewAttTo = nil
		end
		if previewBeam then
			previewBeam:Destroy()
			previewBeam = nil
		end
		previewTarget = nil
	end

	local function updatePreviewTracer(target: BasePart?, grappleOk: boolean)
		if isSwinging or not target or not target.Parent then
			destroyPreviewTracer()
			return
		end

		local attachWorld = closestAttachWorldOnPart(target)

		if previewTarget ~= target or not previewBeam or not previewAttFrom or not previewAttTo then
			destroyPreviewTracer()
			previewTarget = target

			previewAttFrom = Instance.new("Attachment")
			previewAttFrom.Name = "SwingPreviewFrom"
			previewAttFrom.Parent = hrp
			previewAttFrom.Position = Vector3.new(0, 0.6, 0)

			previewAttTo = Instance.new("Attachment")
			previewAttTo.Name = "SwingPreviewTo"
			previewAttTo.Parent = target

			previewBeam = Instance.new("Beam")
			previewBeam.Name = "SwingPreviewTracer"
			previewBeam.Attachment0 = previewAttFrom
			previewBeam.Attachment1 = previewAttTo
			previewBeam.Width0 = PREVIEW_WIDTH
			previewBeam.Width1 = PREVIEW_WIDTH * 0.75
			previewBeam.Color = ColorSequence.new(PREVIEW_WHITE)
			previewBeam.Texture = ""
			previewBeam.LightEmission = 0.12
			previewBeam.FaceCamera = true
			previewBeam.Segments = 1
			previewBeam.CurveSize0 = 0
			previewBeam.CurveSize1 = 0
			previewBeam.Parent = character
		end

		previewAttTo.Position = target.CFrame:PointToObjectSpace(attachWorld)
		local lineAlpha = if grappleOk then PREVIEW_TRANSPARENCY_OK else PREVIEW_TRANSPARENCY_BLOCKED
		previewBeam.Transparency = previewDashedTransparency(lineAlpha)
		previewBeam.Color = ColorSequence.new(PREVIEW_WHITE)
	end

	-- ── Target scan ───────────────────────────────────────────────────────────
	local partCache:  { BasePart } = {}
	local cacheStamp = 0
	local CACHE_TTL  = 1.0

	local function rebuildCache()
		table.clear(partCache)
		local seen: { [BasePart]: boolean } = {}

		for _, obj in CollectionService:GetTagged("SwingTarget") do
			if obj:IsA("BasePart") and obj.Parent then
				seen[obj]             = true
				table.insert(partCache, obj)
			end
		end

		local map  = workspace:FindFirstChild("Map")
		local vine = map and map:FindFirstChild("Vine")
		if vine then
			for _, d in vine:GetDescendants() do
				if d:IsA("BasePart") and d.Name == "SwingTarget" and not seen[d] then
					table.insert(partCache, d)
				end
			end
		end
		cacheStamp = os.clock()
	end

	-- Spawn safe zone (legacy hitboxes + Reddie) — grapple disabled; toolbar UI uses Reddie only.
	local function isHrpInSafezone(): boolean
		return SafezoneUtil.isCharacterInSafezone(character)
	end

	local function isAirborneForSwing(): boolean
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Freefall
			or st == Enum.HumanoidStateType.Jumping
			or st == Enum.HumanoidStateType.FallingDown then
			return true
		end
		return isAirborne
	end

	local function buildSwingQuery(): SwingDetection.SwingQuery
		if os.clock() - cacheStamp > CACHE_TTL then
			rebuildCache()
		end
		return {
			hrpPosition = hrp.Position,
			humanoid = humanoid,
			isAirborne = isAirborneForSwing(),
			isSwinging = isSwinging,
			isDead = humanoid.Health <= 0,
			inSafezone = isHrpInSafezone(),
			lastSwingEndClock = lastSwingEndClock,
			attachRangeStuds = attachRadius(),
			cameraLook = camera.CFrame.LookVector,
			partCache = partCache,
			now = os.clock(),
		}
	end

	local function queryCanSwing(): SwingDetection.CanSwingResult
		return SwingDetection.canSwing(buildSwingQuery())
	end

	local function applyGrappleMomentumBoost(attachWorld: Vector3)
		hrp.AssemblyAngularVelocity = Vector3.zero

		local v = hrp.AssemblyLinearVelocity
		local fromAnchor = hrp.Position - attachWorld
		local radial = if fromAnchor.Magnitude > 0.25 then fromAnchor.Unit else Vector3.yAxis
		local recentDetach = os.clock() - lastSwingEndClock < REATTACH_ZIP_GRACE

		local existingTang = v - radial * v:Dot(radial)
		if existingTang.Magnitude > 2 then
			hrp.AssemblyLinearVelocity = existingTang + radial * v:Dot(radial) * 0.85
		end

		local arcDir = pendulumArcDir(radial)
		if arcDir then
			local zip = dynZipToward * SwingConfig.ATTACH_ZIP_MULT
			if recentDetach then
				zip *= REATTACH_ZIP_MULT
			end
			hrp:ApplyImpulse(arcDir * zip * hrp.AssemblyMass)
		end

		local post = hrp.AssemblyLinearVelocity
		if post.Magnitude > dynMaxSwingSpeed then
			hrp.AssemblyLinearVelocity = post.Unit * dynMaxSwingSpeed
		end
	end

	local function startSwing(target: BasePart, precheck: SwingDetection.CanSwingResult?)
		local swingCheck = precheck or queryCanSwing()
		if not swingCheck.canAttach or swingCheck.target ~= target then
			return
		end

		local attachWorld = swingCheck.attachWorld or closestAttachWorldOnPart(target)
		local dist = swingCheck.distance
		local limit = SwingDetection.attachRangeLimit(attachRadius())
		if dist > limit or dist < SwingConfig.MIN_ATTACH_DIST then
			return
		end

		isSwinging = true
		lastSwingAttachClock = os.clock()
		attachCamClock = os.clock()
		isLaunched = false
		swingTimer = 0

		local anchorAtt = Instance.new("Attachment")
		anchorAtt.Parent = target
		anchorAtt.Position = target.CFrame:PointToObjectSpace(attachWorld)
		ropeAnchorAtt = anchorAtt

		local bodyAtt = Instance.new("Attachment")
		bodyAtt.Position = Vector3.zero
		bodyAtt.Parent = hrp
		ropeBodyAtt = bodyAtt

		-- Spring rest length = max rope travel; gravity + arc forces handle the pendulum.
		local spring = Instance.new("SpringConstraint")
		spring.Attachment0 = anchorAtt
		spring.Attachment1 = bodyAtt
		spring.FreeLength   = MAX_ROPE_DISTANCE
		spring.Stiffness    = SPRING_STIFFNESS
		spring.Damping      = SPRING_DAMPING
		spring.MaxForce     = math.huge
		spring.LimitsEnabled = false
		spring.Parent = hrp
		ropeInst = spring

		swingTargetPart = target

		humanoid.PlatformStand = true

		humanoid.AutoRotate = false

		local fa = Instance.new("Attachment")
		fa.Parent = hrp
		forceAtt = fa

		local vf = Instance.new("VectorForce")
		vf.Attachment0 = fa
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.Force = Vector3.zero
		vf.Parent = hrp
		forceInst = vf

		hrp.AssemblyAngularVelocity = Vector3.zero
		applyGrappleMomentumBoost(anchorAtt.WorldPosition)
		setDefaultAnimateEnabled(false)
		playSwingAnim(attachWorld)

		spawnBeam(attachWorld)
		destroyPreviewTracer()
		clearVisuals()
		swingChargeFill = 0
		ensureSwingChargeHud(target)
	end

	local function stopSwing(doLaunch: boolean)
		if not isSwinging then return end

		local heldTime = swingTimer
		local detachAnchorWorld: Vector3? = nil
		if ropeAnchorAtt and ropeAnchorAtt.Parent then
			detachAnchorWorld = ropeAnchorAtt.WorldPosition
		end

		destroySwingChargeHud()
		isSwinging = false
		if doLaunch then
			launchCamClock = os.clock()
		end

		if forceInst     then forceInst:Destroy();     forceInst     = nil end
		if forceAtt      then forceAtt:Destroy();      forceAtt      = nil end
		if ropeAnchorAtt then ropeAnchorAtt:Destroy(); ropeAnchorAtt = nil end
		if ropeBodyAtt   then ropeBodyAtt:Destroy();   ropeBodyAtt   = nil end
		if ropeInst      then ropeInst:Destroy();      ropeInst      = nil end
		destroyBeam()
		stopSwingAnim()
		setDefaultAnimateEnabled(true)

		swingTargetPart = nil

		lastSwingEndClock = os.clock()
		player:SetAttribute("LastSwingEndClock", lastSwingEndClock)
		if doLaunch then landedFromSwing = true end

		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		hrp.AssemblyAngularVelocity = Vector3.zero

		-- Momentum release: keep arc velocity, add forward impulse scaled by power + swing speed.
		if doLaunch then
			local snapVel = hrp.AssemblyLinearVelocity
			local snapPos = hrp.Position
			local snapHeld = heldTime
			local snapCharge = swingChargeFill
			local snapAnchor = detachAnchorWorld
			local camLook0 = camera.CFrame.LookVector

			task.defer(function()
				if not hrp.Parent then
					return
				end

				-- Humanoid can zero velocity when PlatformStand turns off — restore swing momentum first.
				hrp.AssemblyLinearVelocity = snapVel
				hrp.AssemblyAngularVelocity = Vector3.zero

				local vel = snapVel
				local speed = vel.Magnitude
				local camLook = camLook0
				local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
				local camFlatUnit = if camFlat.Magnitude > 0.08 then camFlat.Unit else Vector3.new(0, 0, -1)
				local holdMult = math.clamp(snapHeld / MIN_SWING_HOLD_LAUNCH, 0.72, 1)
				local mass = hrp.AssemblyMass

				local function blendLaunchDir(baseDir: Vector3): Vector3
					local d = baseDir
					if camFlat.Magnitude > 0.08 then
						d = (d * (1 - LAUNCH_FORWARD_CAMERA_MIX) + camFlat.Unit * LAUNCH_FORWARD_CAMERA_MIX)
					end
					if d.Magnitude > 1e-4 then
						return d.Unit
					end
					return camFlatUnit
				end

				local function applyMomentumLaunch(
					launchDir: Vector3,
					tangSpeed: number,
					releaseSpeed: number,
					chargeFill: number,
					extraForwardDv: number?
				)
					local dir = blendLaunchDir(launchDir)
					local forwardDv = dynLaunchImpulseBase * holdMult + (extraForwardDv or 0)
					local momentumDv = tangSpeed * dynLaunchMomentumRatio * holdMult
					local chargeDv = chargeFill * dynLaunchChargeBonus * holdMult
					local totalDv = forwardDv + momentumDv + chargeDv

					humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					hrp.AssemblyLinearVelocity = vel * dynLaunchMultiplier
					vel = hrp.AssemblyLinearVelocity
					hrp:ApplyImpulse(dir * totalDv * mass)
					if releaseSpeed > 2.5 then
						local carryDv = releaseSpeed * dynLaunchVelocityCarry * holdMult
						hrp:ApplyImpulse(vel.Unit * carryDv * mass)
					end
					if dynLaunchUpImpulse > 0 then
						hrp:ApplyImpulse(Vector3.new(0, dynLaunchUpImpulse * holdMult * mass, 0))
					end

					local post = hrp.AssemblyLinearVelocity
					if post.Magnitude > dynMaxLaunchSpeed then
						hrp.AssemblyLinearVelocity = post.Unit * dynMaxLaunchSpeed
						post = hrp.AssemblyLinearVelocity
					end

					local speedRef = math.max(dynMaxLaunchSpeed, 1)
					launchCamShakeIntensity = math.clamp(
						(post.Magnitude / speedRef) * 0.55 + (tangSpeed / math.max(dynMaxSwingSpeed, 1)) * 0.45,
						0,
						1
					)
					launchFovIntensity = math.clamp(post.Magnitude / speedRef, 0, 1)
					isLaunched = true
					task.delay(LAUNCH_DURATION, function()
						isLaunched = false
					end)
				end

				if speed <= 1 then
					local hangDir = camFlatUnit + Vector3.new(0, 0.18, 0)
					if hangDir.Magnitude > 1e-4 then
						applyMomentumLaunch(
							hangDir.Unit,
							0,
							speed,
							snapCharge,
							dynLaunchDeadhangImpulse * holdMult
						)
					end
				else
					local radial = Vector3.yAxis
					if snapAnchor then
						local fromAnchor = snapPos - snapAnchor
						if fromAnchor.Magnitude > 0.2 then
							radial = fromAnchor.Unit
						end
					end

					local tangVel = vel - radial * vel:Dot(radial)
					local tangSpeed = tangVel.Magnitude
					local camTang = camFlat - radial * camFlat:Dot(radial)

					local launchDir: Vector3
					if tangSpeed > 2 then
						local tDir = tangVel.Unit
						if camTang.Magnitude > 0.05 then
							launchDir = (tDir * (1 - LAUNCH_CAMERA_BLEND) + camTang.Unit * LAUNCH_CAMERA_BLEND).Unit
						else
							launchDir = tDir
						end
					elseif camTang.Magnitude > 0.05 then
						launchDir = camTang.Unit
					else
						launchDir = if speed > 0.1 then vel.Unit else camFlatUnit
					end

					local tangRef = if tangSpeed > 1 then tangSpeed else dynLaunchDeadhangImpulse * 0.35
					applyMomentumLaunch(launchDir, tangRef, speed, snapCharge)
				end
			end)
		end
	end

	-- ── Input ─────────────────────────────────────────────────────────────────
	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Freefall
		or new == Enum.HumanoidStateType.Jumping
		or new == Enum.HumanoidStateType.FallingDown then
			isAirborne = true
		elseif new == Enum.HumanoidStateType.Landed then
			isAirborne = false
			clearVisuals()
			destroyPreviewTracer()
			prevInRng = {}
			isAirborne = false
			if landedFromSwing then
				landedFromSwing = false
				local alpha = landingImpactAlpha(landingSpeed)
				local sfxAlpha = if alpha > 0 then alpha else math.clamp(landingSpeed / LANDING_BLOCK_VEL_MIN, 0.25, 0.6)
				local gse = getGameSoundEffects()
				if gse and gse.playGroundSmash then
					gse.playGroundSmash(sfxAlpha)
				end
				landingCamSeed = math.random() * 100
				swingCamLagWorld = Vector3.zero
				swingCamRoll = 0
				launchCamClock = -1e9
				if alpha > 0 then
					spawnLandingBlocks(alpha)
					landingCamShakeIntensity = math.clamp(0.45 + alpha * 0.55, 0, 1)
					landingCamClock = os.clock()
				elseif sfxAlpha > 0 then
					landingCamShakeIntensity = sfxAlpha * 0.55
					landingCamClock = os.clock()
				end
			end
			isLaunched = false
			launchCamShakeIntensity = 0
			launchFovIntensity = 0
			if landingCamShakeIntensity <= 0.02 then
				resetSwingCameraState()
			end
		elseif new == Enum.HumanoidStateType.Running
		or new == Enum.HumanoidStateType.RunningNoPhysics then
			isAirborne = false
		end
	end)

	local function tryGrappleAttach()
		if isSwinging then
			return
		end
		local now = os.clock()
		if now - lastGrappleInputClock < GRAPPLE_INPUT_COOLDOWN then
			return
		end

		local swingCheck = queryCanSwing()
		if not swingCheck.canAttach or not swingCheck.target then
			return
		end

		local ok = false
		pcall(function()
			ok = swingAttachFn:InvokeServer(swingCheck.target) == true
		end)
		if not ok then
			return
		end

		startSwing(swingCheck.target, swingCheck)
		if isSwinging then
			lastGrappleInputClock = now
		end
	end

	-- Mobile: bind the Roblox touch JumpButton so press = attach, release = detach (same feel as PC Space).
	-- Tap-detach via JumpRequest is kept as a fallback only when the button can't be located.
	local mobileJumpBound = false
	local mobileBoundConns: { RBXScriptConnection } = {}

	local function disconnectMobileBound()
		for _, c in mobileBoundConns do c:Disconnect() end
		table.clear(mobileBoundConns)
		mobileJumpBound = false
		mobileJumpHeld = false
	end

	local function tryBindMobileJumpButton(): boolean
		if mobileJumpBound then return true end
		if not UserInputService.TouchEnabled then return false end
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if not pg then return false end
		local touchGui = pg:FindFirstChild("TouchGui")
		if not touchGui then return false end
		local frame = touchGui:FindFirstChild("TouchControlFrame")
		if not frame then return false end
		local btn = frame:FindFirstChild("JumpButton")
		if not (btn and btn:IsA("GuiButton")) then return false end

		mobileJumpBound = true
		local pressDown = false

		table.insert(mobileBoundConns, btn.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then return end
			if pressDown then return end
			pressDown = true
			mobileJumpHeld = true
			if not isSwinging then
				tryGrappleAttach()
			end
		end))

		table.insert(mobileBoundConns, btn.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then return end
			if not pressDown then return end
			pressDown = false
			mobileJumpHeld = false
			if isSwinging then
				stopSwing(true)
			end
		end))

		table.insert(mobileBoundConns, btn.AncestryChanged:Connect(function(_, parent)
			if not parent then
				disconnectMobileBound()
				task.defer(function()
					-- Roblox rebuilds TouchGui on respawn / device changes; reattach to the new button.
					tryBindMobileJumpButton()
				end)
			end
		end))

		return true
	end

	local pgWatchConns: { RBXScriptConnection } = {}
	if UserInputService.TouchEnabled then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if pg and not tryBindMobileJumpButton() then
			table.insert(pgWatchConns, pg.DescendantAdded:Connect(function(d)
				if d.Name == "JumpButton" and d:IsA("GuiButton") then
					task.defer(tryBindMobileJumpButton)
				end
			end))
		end
	end

	local function onJumpRequest()
		if isSwinging then
			-- Fallback only: pure-touch device where we couldn't bind to the JumpButton.
			-- Without this, the player would be stuck swinging since they have no key to release.
			if not mobileJumpBound
				and UserInputService.TouchEnabled
				and not UserInputService.KeyboardEnabled
				and os.clock() - lastSwingAttachClock >= SWING_ATTACH_JUMP_DEBOUNCE
			then
				stopSwing(true)
			end
			return
		end
		tryGrappleAttach()
	end

	local jumpConn = UserInputService.JumpRequest:Connect(onJumpRequest)

	local beginConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or isSwinging then return end
		if input.UserInputType == Enum.UserInputType.Gamepad1 and isJumpReleaseKey(input.KeyCode) then
			tryGrappleAttach()
		end
	end)

	local releaseConn = UserInputService.InputEnded:Connect(function(input: InputObject, processed: boolean)
		if processed or not isSwinging then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and isJumpReleaseKey(input.KeyCode) then
			stopSwing(true)
			return
		end
		if input.UserInputType == Enum.UserInputType.Gamepad1 and isJumpReleaseKey(input.KeyCode) then
			stopSwing(true)
		end
	end)

	local diedConn = humanoid.Died:Connect(function()
		if isSwinging then
			stopSwing(false)
		end
	end)

	-- ── Heartbeat (physics + visuals) ─────────────────────────────────────────
	local fovBase   = camera.FieldOfView

	local heartbeat = RunService.Heartbeat:Connect(function(dt)
		local vel = hrp.AssemblyLinearVelocity

		-- FOV: widen with swing speed; attach punch + launch burst layered on top.
		local fovTarget = fovBase
		if isSwinging or isLaunched then
			local t = math.clamp(vel.Magnitude / math.max(dynMaxSwingSpeed, 1), 0, 1)
			fovTarget = fovBase + (FOV_MAX - fovBase) * t
		end

		local now = os.clock()
		local attachAge = now - attachCamClock
		if attachAge >= 0 and attachAge < ATTACH_PUNCH_DURATION then
			local u = attachAge / ATTACH_PUNCH_DURATION
			fovTarget -= ATTACH_PUNCH_FOV * math.sin(u * math.pi)
		end

		local launchAge = now - launchCamClock
		if launchAge >= 0 and launchAge < LAUNCH_FOV_DURATION then
			local u = launchAge / LAUNCH_FOV_DURATION
			local ease = (1 - u) * (1 - u)
			fovTarget += LAUNCH_FOV_BOOST * ease * (0.55 + launchFovIntensity * 0.65)
		end

		camera.FieldOfView += (fovTarget - camera.FieldOfView) * math.min(dt * FOV_SPEED, 1)

		-- Swing physics: camera-steered pendulum on a SpringConstraint.
		if isSwinging and forceInst and swingTargetPart and swingTargetPart.Parent and ropeAnchorAtt and ropeAnchorAtt.Parent then
			swingTimer += dt
			humanoid.PlatformStand = true
			humanoid.Jump = false

			local decay = math.clamp(swingTimer / FORCE_DECAY_TIME, 0, 1)
			local mult = 1 - decay * (1 - FORCE_MIN_MULT)

			local fromAnchor = hrp.Position - ropeAnchorAtt.WorldPosition
			local dist = fromAnchor.Magnitude
			local radial = if dist > 0.2 then fromAnchor.Unit else Vector3.yAxis
			local extT = math.clamp(dist / MAX_ROPE_DISTANCE, 0, 1.35)
			local anchorWorld = ropeAnchorAtt.WorldPosition
			local mass = hrp.AssemblyMass

			local md = humanoid.MoveDirection
			local inputSteer = Vector3.zero
			if md.Magnitude > 0.05 then
				local mdFlat = Vector3.new(md.X, 0, md.Z)
				local inputTang = mdFlat - radial * mdFlat:Dot(radial)
				if inputTang.Magnitude > 0.05 then
					inputSteer = inputTang.Unit * swingForce * SwingConfig.INPUT_STEER_FORCE_MULT * mult * mass
				end
			end

			local arcDir = pendulumArcDir(radial) or Vector3.new(0, -1, 0)
			local arcForce = computeSwingArcForce(anchorWorld, radial, extT, mult, mass)

			local ropeTension = Vector3.zero
			local softLimit = MAX_ROPE_DISTANCE * SwingConfig.ROPE_SOFT_START
			if dist > softLimit then
				local over = dist - softLimit
				local span = MAX_ROPE_DISTANCE * (1 - SwingConfig.ROPE_SOFT_START)
				local tensionT = math.clamp(over / math.max(span, 0.01), 0, 2.5)
				ropeTension = -radial * SwingConfig.ROPE_OVERSTRETCH_TENSION * tensionT * mass
			end

			forceInst.Force = inputSteer + arcForce + ropeTension

			local floorScale = swingFloorScale(anchorWorld)
			if floorScale < 0.3 and vel.Y < -10 then
				hrp.AssemblyLinearVelocity = Vector3.new(vel.X, vel.Y * 0.82, vel.Z)
			end

			-- Steering uses VectorForce only. Avoid aiming HRP at the camera here — that rotation
			-- fights the hang animation and twists arms into the torso.

			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-ANGULAR_DAMP * dt)

			if vel.Magnitude > dynMaxSwingSpeed then
				hrp.AssemblyLinearVelocity = vel.Unit * dynMaxSwingSpeed
			end

			local spaceHeld = UserInputService:IsKeyDown(Enum.KeyCode.Space)
				or UserInputService:IsKeyDown(Enum.KeyCode.ButtonA)
				or mobileJumpHeld
			swingChargeFill = if spaceHeld
				then math.min(1, swingChargeFill + dt / SWING_CHARGE_HOLD_SEC)
				else math.max(0, swingChargeFill - dt * 3.5)
			layoutSwingChargeDot()
			humanoid.CameraOffset = Vector3.zero

			return
		end

		-- Track speed in air so we know how hard the landing will be
		if isAirborne then
			landingSpeed = vel.Magnitude
		end

		if not isSwinging and not isLaunched and not isLandingShakeActive(os.clock()) then
			humanoid.CameraOffset = humanoid.CameraOffset:Lerp(Vector3.zero, math.min(dt * 14, 1))
		end

		if not isSwinging then
			local swingCheck = queryCanSwing()
			local aimVisual = if swingCheck.canShowUi then swingCheck.target else nil
			local grappleOk = swingCheck.canAttach

			local inRngNow: { BasePart } = {}
			if aimVisual then
				table.insert(inRngNow, aimVisual)
			end
			local inRngSet: { [BasePart]: boolean } = {}
			for _, p in ipairs(inRngNow) do
				inRngSet[p] = true
			end

			for _, p in inRngNow do
				if not prevInRng[p] then
					addVisual(p)
				end
			end
			for p in prevInRng do
				if not inRngSet[p] then
					removeVisual(p)
				end
			end
			prevInRng = inRngSet

			if aimVisual then
				local v = visMap[aimVisual]
				if v then
					local aimColor = if grappleOk then COLOR_BEST else COLOR_BLOCKED
					setVisualColor(v, aimColor)
					v.lbl.Text = if grappleOk then "JUMP  ·  swing" else "SAFE ZONE"
					if grappleOk then
						local w = math.sin(os.clock() * 3.4) * 0.5 + 0.5
						v.dot.BackgroundTransparency = 0.06 + 0.38 * w
					else
						v.dot.BackgroundTransparency = 0
					end
				end
			end

			if aimVisual then
				updatePreviewTracer(aimVisual, grappleOk)
			else
				destroyPreviewTracer()
			end
		end
	end)

	local renderUiConn = RunService.RenderStepped:Connect(function()
		if isSwinging then
			return
		end
		queryCanSwing()
	end)

	-- ── Cleanup (called on character removal / respawn) ───────────────────────
	return function()
		walkSpeedAttrConn:Disconnect()
		jumpConn:Disconnect()
		beginConn:Disconnect()
		releaseConn:Disconnect()
		diedConn:Disconnect()
		disconnectMobileBound()
		for _, c in pgWatchConns do c:Disconnect() end
		table.clear(pgWatchConns)
		if r6RenderBindName then
			pcall(function()
				RunService:UnbindFromRenderStep(r6RenderBindName :: string)
			end)
		end
		pcall(function()
			RunService:UnbindFromRenderStep(swingCamBindName)
		end)
		resetSwingCameraState()
		destroyLaunchSpeedFx()
		heartbeat:Disconnect()
		renderUiConn:Disconnect()
		for _, c in statConns do c:Disconnect() end
		if isSwinging then stopSwing(false) end
		destroyPreviewTracer()
		stopSwingAnim()
		clearVisuals()
		pcall(function() camera.FieldOfView = fovBase end)
		pcall(function()
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
		end)
		pcall(function()
			local animSc = animateScript
			if animSc and animSc:IsA("LocalScript") then
				animSc.Disabled = false
			end
		end)
		if useR6Procedural and r6Pose.rs and r6Pose.baseRS then
			r6Pose.rs.C0 = r6Pose.baseRS
		end
		if useR6Procedural and r6Pose.ls and r6Pose.baseLS then
			r6Pose.ls.C0 = r6Pose.baseLS
		end
	end
end

-- ── Entry point ───────────────────────────────────────────────────────────────
local dispose: (() -> ())?

local function onCharacter(char: Model)
	if dispose then dispose(); dispose = nil end
	dispose = boot(char)
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end
