-- MergedFriendSwingSystem.client.lua
-- Drop this LocalScript into StarterPlayerScripts.
-- Swing targets come from your friend's setup.
-- Performance mode uses CollectionService tag "SwingTarget" only.
-- The old workspace.Map.Vine name fallback exists below, but is off by default
-- because huge Vine folders can hard-freeze the client while scanning.
--
-- Controls:
-- PC: hold Space near a close visible target, or jump/hold Space for longer reach.
-- Gamepad: hold R2 near a close visible target, or jump/hold R2 for longer reach.
-- Mobile: hold the Jump button near a close visible target, or jump/hold it for longer reach.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

-- Cache this outside boot() so the huge boot function does not spend extra local registers.
-- Luau functions can only have 200 local registers; adding locals near the bottom of boot() can break compilation.
-- Constants/config table. Keeps Luau from exceeding the 200 local-register limit.
local C = {}
C.PRE_SIMULATION_SIGNAL = nil
pcall(function()
	C.PRE_SIMULATION_SIGNAL = RunService.PreSimulation
end)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local sharedFolder = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 10)

local function tryRequireModule(parent, name)
	local module = parent and parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end

	local ok, result = pcall(require, module)
	if ok then
		return result
	end

	warn("[MergedFriendSwingSystem] Failed to load module:", name, result)
	return nil
end

local SafezoneUtil = tryRequireModule(sharedFolder, "SafezoneUtil")
local SwingUpgrades = tryRequireModule(sharedFolder, "SwingUpgrades")
local SwingProgression = tryRequireModule(sharedFolder, "SwingProgression")

-- Target setup from the original friend script.
C.SWING_TARGET_TAG = "SwingTarget"
C.SWING_TARGET_NAME = "SwingTarget"
C.MAP_FOLDER_NAME = "Map"
C.VINE_FOLDER_NAME = "Vine"

-- Tuning.
C.SWING_RANGE = 102
C.ROPE_MAX_LENGTH = 44
C.ROPE_MIN_LENGTH = 13
C.ROPE_REST_LENGTH_MULT = 0.48
C.ROPE_STRETCH_MAX_EXTRA = 26
C.ROPE_MOMENTUM_LENGTH_MULT = 0.68
C.ROPE_DISTANCE_STRETCH_MULT = 0.22
C.ROPE_LENGTH_RESPONSE = 24
C.ROPE_ATTACH_START_MULT = 0.58
-- Elastic catch controls the brief "stretch then recover" feel when chaining to a new swing.
-- It does NOT increase target reach; it only starts the rope closer to the player's current distance,
-- then gently retracts it instead of snapping the player upward instantly.
C.ROPE_CATCH_ELASTIC_TIME = 0.42
C.ROPE_CATCH_START_MULT = 0.88
C.ROPE_CATCH_FORCE_MULT = 0.62
C.ROPE_CATCH_REEL_MULT = 0.48
C.ROPE_HANG_PULL_TARGET_MULT = 0.46
C.ROPE_HANG_PULL_START_MULT = 0.3
C.ROPE_HANG_PULL_MIN_GAP = 3.25
C.ROPE_HANG_PULL_FORCE = 145
C.ROPE_HANG_PULL_WINCH_SPEED = 58
C.ROPE_HANG_PULL_MAX_UP_SPEED = 88
C.ROPE_SAFE_MAX_MIN_LENGTH = 24
C.ROPE_REEL_ALWAYS_ALPHA = 0.76
C.MIN_LOOK_DOT = 0.3
C.AIRBORNE_TARGET_LOOK_DOT = 0.02
C.GROUNDED_TARGET_LOOK_DOT = 0.02
C.TARGET_SCREEN_RADIUS_LIMIT = 0.98
C.GROUNDED_TARGET_SCREEN_RADIUS_LIMIT = 0.98
C.MIN_TARGET_HEIGHT_OFFSET = -8
C.TARGET_SCAN_INTERVAL = 0.12
C.TARGET_CANDIDATE_EXTRA_RADIUS = 4
C.TARGET_GRID_CELL_SIZE = 64
C.TARGET_MAX_CANDIDATES_PER_SCAN = 45
C.TARGET_FULL_SCAN_FALLBACK_LIMIT = 180
C.TARGET_ENABLE_VINE_NAME_FALLBACK = false
C.TARGET_BACKGROUND_SEED_ENABLED = false
C.TARGET_SKIP_VINE_SEED_WHEN_TAGGED = true
C.TARGET_SEED_BATCH_SIZE = 12
C.TARGET_SEED_MAX_SLICE_TIME = 0.004
C.TARGET_SEED_STEP_WAIT = 0.05
C.ENABLE_TARGET_HIGHLIGHT = true
C.TARGET_HIGHLIGHT_FILL_TRANSPARENCY = 0.5
C.TARGET_HIGHLIGHT_PROXY_TRANSPARENCY = 0.99
C.TARGET_HIGHLIGHT_VISIBLE_TRANSPARENCY = 0.92
C.TARGET_VISUAL_STEP_INTERVAL = 1 / 30
C.TARGET_VISUAL_HIDDEN_POSITION = Vector3.new(0, -100000, 0)
C.ATTACH_RETRY_TIME = 0.12
C.ATTACH_COOLDOWN = 0.18
C.MIN_SWING_LOCK_TIME = 0.28
-- Grounded range should match actual swing reach, otherwise the UI can show red even when attach is allowed.
-- These are fallback floors only; the live grounded ready distance uses getSwingRange().
C.GROUNDED_READY_RANGE = 75
C.GROUNDED_BLOCKED_UI_RANGE = 75
C.SAFEZONE_BLOCKED_UI_RANGE = 48
C.AIRBORNE_TARGET_UI_EXTRA = 45

C.STEER_FORCE = 70
C.ARC_FORCE = 44
C.SPEED_PUMP = 1.1
C.MAX_SWING_SPEED = 94
C.FORCE_DECAY_TIME = 6
C.FORCE_MIN_MULT = 0.76
C.ANGULAR_DAMP = 7.5
C.FLOOR_CLEARANCE = 5
C.SWING_GROUND_CLEARANCE = 5.8
C.SWING_GROUND_HARD_CLEARANCE = 2.6
C.SWING_GROUND_LIFT_FORCE = 150
C.SWING_GROUND_MIN_UP_SPEED = 16
C.SWING_GROUND_DRAG_MIN_SPEED = 8
C.SWING_GROUND_DRAG_DEBRIS_INTERVAL = 0.075
C.SWING_GROUND_DRAG_DEBRIS_LIFETIME = 0.75

C.ZIP_SPRING_STIFFNESS = 22
C.ZIP_SPRING_DAMPING = 16
C.ZIP_SPRING_MAX_ACCEL = 700
C.ATTACH_ZIP_DV = 13
C.ZIP_PULL_TIME = 0.5

C.LAUNCH_FORWARD_DV = 124
C.LAUNCH_MOMENTUM_RATIO = 0.12
C.LAUNCH_UP_DV = 38
C.LAUNCH_CHARGE_DV = 16
C.LAUNCH_FORWARD_INPUT_DV = 62
C.LAUNCH_SPEED_CAP = 140
C.LAUNCH_STYLE_TIME = 1.15
C.LAUNCH_STYLE_TILT_TIME = 0.2
C.LAUNCH_STYLE_ORIENT_RESPONSIVENESS = 48
C.LAUNCH_STYLE_ORIENT_TORQUE = 19000
C.LAUNCH_STYLE_UP_AIM = 1.18
C.LAUNCH_STYLE_DOWN_AIM = 1.08
C.LAUNCH_DROP_DELAY = 0.34
C.LAUNCH_DROP_ACCEL = 38
C.LAUNCH_DROP_MAX_SPEED = -92
C.MIN_HOLD_FOR_FULL_LAUNCH = 0.14
C.CHARGE_TIME = 0.95
C.FORWARD_CHARGE_TIME = 1.05
C.SWING_MOMENTUM_BUILD_RATE = 0.68
C.SWING_MOMENTUM_FORWARD_BUILD_RATE = 0.34
C.SWING_MOMENTUM_IDLE_DECAY_RATE = 0.82
C.SWING_MOMENTUM_BAD_INPUT_DECAY_RATE = 0.7
C.SWING_DEAD_HANG_MOMENTUM_BUILD_RATE = 0.54
C.SWING_RHYTHM_BUILD_RATE = 0.58
C.SWING_RHYTHM_DECAY_RATE = 1.25
C.SWING_REVERSAL_BUILD_RATE = 0.46
C.SWING_RHYTHM_FORCE = 54
C.SWING_REVERSAL_FORCE = 62
C.SWING_INPUT_ORBIT_FORCE = 42
C.SWING_MOMENTUM_SPEED_BONUS = 0.36
C.SWING_MOMENTUM_LAUNCH_BONUS = 0.3

C.FOV_SPEED = 4.5
C.FOV_MAX = 96
C.ATTACH_FOV_PUNCH = 5
C.ATTACH_FOV_TIME = 0.28
C.LAUNCH_FOV_BOOST = 7
C.LAUNCH_FOV_TIME = 0.34
C.LANDING_FOV_KICK = 8
C.LANDING_FOV_TIME = 0.42

-- Set this false if you decide the grounded camera assist feels annoying.
C.ENABLE_GROUNDED_CAMERA_ASSIST = false
C.CAMERA_ASSIST_RANGE = 50
C.CAMERA_ASSIST_STRENGTH = 0.72
C.CAMERA_ASSIST_MIN_LOOK_DOT = 0.52

C.DEAD_HANG_MOVE_FORCE = 68
C.AVATAR_TURN_RESPONSIVENESS = 44
C.AVATAR_FAST_TURN_DOT = -0.12
C.AVATAR_NATURAL_FACE_TURN_RATE = 18
C.AVATAR_NATURAL_FACE_FAST_TURN_RATE = 32

C.ENABLE_PROCEDURAL_SWING_POSE = true
C.SWING_POSE_BLEND_IN_SPEED = 14
C.SWING_POSE_BLEND_OUT_SPEED = 11
C.SWING_POSE_VELOCITY_LAG_SPEED = 7
C.SWING_POSE_STATE_RESPONSE = 15
C.SWING_POSE_TORSO_LEAN = math.rad(32)
C.SWING_POSE_TORSO_ROLL = math.rad(20)
C.SWING_POSE_TORSO_YAW = math.rad(16)
C.SWING_POSE_LEG_BACK = math.rad(46)
C.SWING_POSE_LEG_FRONT_IDLE = math.rad(13)
C.SWING_POSE_LEG_BACK_DIRECTION = -1
C.SWING_POSE_R6_LEG_BACK_DIRECTION = 1
C.SWING_POSE_KNEE_BEND = math.rad(19)
C.SWING_POSE_ANKLE_FLEX = math.rad(6)
C.SWING_POSE_FREE_ARM_BACK = math.rad(38)
C.SWING_POSE_FREE_ARM_OUT = math.rad(28)
C.SWING_POSE_FREE_ARM_SWAY = math.rad(12)
C.SWING_POSE_FREE_ELBOW = math.rad(22)

C.SWING_CAMERA_ROLL_MAX = math.rad(5)
C.SWING_CAMERA_LAG_MAX = 0.72
C.SWING_CAMERA_EFFECT_SPEED = 7
C.LAUNCH_CAMERA_SHAKE_TIME = 0.3
C.LAUNCH_CAMERA_SHAKE_STRENGTH = 0.22
C.LANDING_CAMERA_SHAKE_TIME = 0.62
C.LANDING_CAMERA_SHAKE_STRENGTH = 0.92

C.PREVIEW_COLOR = Color3.fromRGB(90, 220, 255)
C.READY_COLOR = Color3.fromRGB(70, 255, 115)
C.NOT_READY_COLOR = Color3.fromRGB(255, 70, 70)
C.TARGET_VISUAL_SMOOTH_SPEED = 10
C.PREVIEW_FADE_SPEED = 12
C.READY_TEXT_BOB_SPEED = 8
C.READY_TEXT_BOB_PIXELS = 5
C.ROPE_COLOR_A = Color3.fromRGB(255, 255, 255)
C.ROPE_COLOR_B = Color3.fromRGB(90, 220, 255)

-- Swing animations live in ReplicatedStorage/Animations/Player.
-- Expected Animation names: Hang_Left, Hang_Right, Falling, Landed.
C.ENABLE_SWING_ANIMATIONS = true
C.ANIMATIONS_FOLDER_NAME = "Animations"
C.PLAYER_ANIMATIONS_FOLDER_NAME = "Player"
C.HANG_ANIM_RIGHT_NAME = "Hang_Right"
C.HANG_ANIM_LEFT_NAME = "Hang_Left"
C.FALLING_ANIM_NAME = "Falling"
C.LANDED_ANIM_NAME = "Landed"

local function flatUnit(v)
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude > 0.05 then
		return f.Unit
	end
	return nil
end

local function safeIsKeyDown(keyCode)
	local ok, down = pcall(function()
		return UserInputService:IsKeyDown(keyCode)
	end)
	return ok and down == true
end

local cachedPlayerControls = nil
local controlsLoadFailed = false

local function getPlayerControls()
	if cachedPlayerControls then
		return cachedPlayerControls
	end
	if controlsLoadFailed then
		return nil
	end

	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule or not playerModule:IsA("ModuleScript") then
		return nil
	end

	local ok, module = pcall(require, playerModule)
	if not ok or typeof(module) ~= "table" or typeof(module.GetControls) ~= "function" then
		controlsLoadFailed = true
		return nil
	end

	local controlsOk, controls = pcall(function()
		return module:GetControls()
	end)
	if not controlsOk then
		controlsLoadFailed = true
		return nil
	end

	cachedPlayerControls = controls
	return cachedPlayerControls
end

local function getControlWorldMove(currentCamera)
	local controls = getPlayerControls()
	if not controls or typeof(controls.GetMoveVector) ~= "function" then
		return nil, 0
	end

	local ok, moveVector = pcall(function()
		return controls:GetMoveVector()
	end)
	if not ok or typeof(moveVector) ~= "Vector3" or moveVector.Magnitude < 0.05 then
		return nil, 0
	end

	local cf = currentCamera and currentCamera.CFrame
	local forward = cf and flatUnit(cf.LookVector) or nil
	local right = cf and flatUnit(cf.RightVector) or nil
	if not forward or not right then
		return nil, math.clamp(moveVector.Magnitude, 0, 1)
	end

	local worldMove = right * moveVector.X - forward * moveVector.Z
	if worldMove.Magnitude > 0.05 then
		return worldMove.Unit, math.clamp(moveVector.Magnitude, 0, 1)
	end
	return nil, 0
end

local function getFirstNumberAttribute(names)
	for _, name in ipairs(names) do
		local value = player:GetAttribute(name)
		if typeof(value) == "number" then
			return value
		end
	end
	return nil
end

local function getPowerStats()
	if not (SwingProgression and SwingUpgrades) then
		return nil
	end
	if typeof(SwingProgression.powerStats) ~= "function" then
		return nil
	end

	local attrName = SwingUpgrades.POWER_LEVEL_ATTR
	local level = nil
	if typeof(attrName) == "string" then
		level = player:GetAttribute(attrName)
	end
	if typeof(level) ~= "number" then
		level = getFirstNumberAttribute({ "SwingPowerLevel", "PowerLevel" }) or 0
	end

	local ok, stats = pcall(function()
		return SwingProgression.powerStats(level)
	end)
	if ok and typeof(stats) == "table" then
		return stats
	end
	return nil
end

local function getRopeStats()
	if not (SwingProgression and SwingUpgrades) then
		return nil
	end
	if typeof(SwingProgression.ropeStats) ~= "function" then
		return nil
	end

	local attrName = SwingUpgrades.ROPE_LEVEL_ATTR
	local level = nil
	if typeof(attrName) == "string" then
		level = player:GetAttribute(attrName)
	end
	if typeof(level) ~= "number" then
		level = getFirstNumberAttribute({ "RopeLevel", "SwingRopeLevel" }) or 0
	end

	local ok, stats = pcall(function()
		return SwingProgression.ropeStats(level)
	end)
	if ok and typeof(stats) == "table" then
		return stats
	end
	return nil
end

local function getPowerScale()
	local stats = getPowerStats()
	if stats then
		if typeof(stats.maxSwingSpeed) == "number" and stats.maxSwingSpeed > 0 then
			return math.clamp(stats.maxSwingSpeed / C.MAX_SWING_SPEED, 0.75, 3.25)
		end
		if typeof(stats.steeringForce) == "number" and stats.steeringForce > 0 then
			return math.clamp(stats.steeringForce / C.STEER_FORCE, 0.75, 3.25)
		end
	end

	local rawPower = getFirstNumberAttribute({ "SwingPower", "Power" })
	if not rawPower then
		local force = getFirstNumberAttribute({ "SwingForce" })
		if force and force > 0 then
			return math.clamp(force / C.STEER_FORCE, 0.75, 3.25)
		end
		return 1
	end

	if rawPower > 10 then
		rawPower = rawPower / 100
	end

	return math.clamp(rawPower, 0.65, 3.25)
end

local function getSwingRange()
	local ropeStats = getRopeStats()
	if ropeStats and typeof(ropeStats.reachStuds) == "number" and ropeStats.reachStuds > 0 then
		return math.clamp(ropeStats.reachStuds, 40, 190)
	end

	local rangeAttr = getFirstNumberAttribute({ "SwingRange", "ReachDistance", "Reach_Distance" })
	if rangeAttr and rangeAttr > 0 then
		return math.clamp(rangeAttr, 40, 190)
	end

	local powerScale = getPowerScale()
	return math.clamp(C.SWING_RANGE * (0.9 + (powerScale - 1) * 0.25), 65, 165)
end

local function getRopeMaxLength()
	return math.clamp(
		C.ROPE_MAX_LENGTH + math.max(getSwingRange() - C.SWING_RANGE, 0) * 0.55,
		C.ROPE_MIN_LENGTH + C.ROPE_HANG_PULL_MIN_GAP + 4,
		118
	)
end

local function getRopeRestLength()
	return math.clamp(C.ROPE_MAX_LENGTH * C.ROPE_REST_LENGTH_MULT, C.ROPE_MIN_LENGTH, C.ROPE_MAX_LENGTH)
end

local function getLaunchScale()
	local stats = getPowerStats()
	if stats and typeof(stats.maxLaunchSpeed) == "number" and stats.maxLaunchSpeed > 0 then
		return math.clamp(stats.maxLaunchSpeed / C.LAUNCH_SPEED_CAP, 0.86, 3.05)
	end
	return math.clamp(0.9 + (getPowerScale() - 1) * 0.82, 0.86, 2.75)
end

local function getSteerForce()
	local stats = getPowerStats()
	if stats and typeof(stats.steeringForce) == "number" and stats.steeringForce > 0 then
		return stats.steeringForce
	end
	local attr = getFirstNumberAttribute({ "SwingForce" })
	if attr and attr > 0 then
		return attr
	end
	return C.STEER_FORCE * getPowerScale()
end

local function getMaxSwingSpeed()
	local stats = getPowerStats()
	if stats and typeof(stats.maxSwingSpeed) == "number" and stats.maxSwingSpeed > 0 then
		return stats.maxSwingSpeed
	end
	return C.MAX_SWING_SPEED * getLaunchScale()
end

local function getArcForce()
	local stats = getPowerStats()
	if stats and typeof(stats.swingArcForce) == "number" and stats.swingArcForce > 0 then
		return stats.swingArcForce
	end
	return C.ARC_FORCE * getPowerScale()
end

local function getSpeedPump()
	local stats = getPowerStats()
	if stats and typeof(stats.swingSpeedPump) == "number" and stats.swingSpeedPump > 0 then
		return stats.swingSpeedPump
	end
	return C.SPEED_PUMP * getPowerScale()
end

local function getZipDv()
	local stats = getPowerStats()
	if stats and typeof(stats.zipToward) == "number" and stats.zipToward > 0 then
		return stats.zipToward
	end
	return C.ATTACH_ZIP_DV * getPowerScale()
end

local function playOptionalSound(name)
	local s = script:FindFirstChild(name)

	if not s then
		local soundEffects = SoundService:FindFirstChild("SoundEffects")
		s = soundEffects and soundEffects:FindFirstChild(name)
	end

	if s and s:IsA("Sound") then
		pcall(function()
			s.TimePosition = 0
			s:Play()
		end)
	end
end

local function stopOptionalSound(name)
	local s = script:FindFirstChild(name)
	if s and s:IsA("Sound") then
		pcall(function()
			s:Stop()
		end)
	end
end

local function createSwingPose(character, hrp)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local state = {
		alpha = 0,
		clock = 0,
		velocityLag = Vector3.new(0, 0, 0),
		joints = {},
		cleared = true,
		isR6 = humanoid and humanoid.RigType == Enum.HumanoidRigType.R6,
		torsoPitch = 0,
		torsoRoll = 0,
		torsoYaw = 0,
		legBack = 0,
		kneeBend = 0,
		ankleFlex = 0,
		freeArmBack = 0,
		freeArmOut = 0,
		freeArmSway = 0,
		freeElbow = 0,
	}

	local function findMotor(names)
		for _, name in ipairs(names) do
			local inst = character:FindFirstChild(name, true)
			if inst and inst:IsA("Motor6D") then
				return inst
			end
		end
		return nil
	end

	state.joints.root = findMotor({ "Root", "RootJoint" })
	state.joints.waist = findMotor({ "Waist" })
	state.joints.neck = findMotor({ "Neck" })
	state.joints.leftHip = findMotor({ "LeftHip", "Left Hip" })
	state.joints.rightHip = findMotor({ "RightHip", "Right Hip" })
	state.joints.leftKnee = findMotor({ "LeftKnee" })
	state.joints.rightKnee = findMotor({ "RightKnee" })
	state.joints.leftAnkle = findMotor({ "LeftAnkle" })
	state.joints.rightAnkle = findMotor({ "RightAnkle" })
	state.joints.leftShoulder = findMotor({ "LeftShoulder", "Left Shoulder" })
	state.joints.rightShoulder = findMotor({ "RightShoulder", "Right Shoulder" })
	state.joints.leftElbow = findMotor({ "LeftElbow" })
	state.joints.rightElbow = findMotor({ "RightElbow" })

	local function applyJointOffset(joint, transform)
		if joint and joint.Parent then
			joint.Transform = transform
		end
	end

	local function clearJointTransform(joint)
		if joint and joint.Parent then
			joint.Transform = CFrame.new()
		end
	end

	local function clear()
		if state.cleared then
			return
		end
		state.alpha = 0
		state.clock = 0
		state.velocityLag = hrp.AssemblyLinearVelocity
		state.torsoPitch = 0
		state.torsoRoll = 0
		state.torsoYaw = 0
		state.legBack = 0
		state.kneeBend = 0
		state.ankleFlex = 0
		state.freeArmBack = 0
		state.freeArmOut = 0
		state.freeArmSway = 0
		state.freeElbow = 0
		for _, joint in pairs(state.joints) do
			clearJointTransform(joint)
		end
		state.cleared = true
	end

	local function step(
		dt,
		velocity,
		radial,
		moveFlatUnit,
		forwardInput,
		extT,
		momentum,
		hangSide,
		activeSwinging,
		activeLaunched,
		activeLandingCarry
	)
		if not C.ENABLE_PROCEDURAL_SWING_POSE then
			return
		end

		local targetAlpha = 0
		if activeSwinging then
			targetAlpha = 1
		end
		if targetAlpha <= 0 and state.cleared then
			return
		end

		local blendSpeed = targetAlpha > state.alpha and C.SWING_POSE_BLEND_IN_SPEED or C.SWING_POSE_BLEND_OUT_SPEED
		state.alpha += (targetAlpha - state.alpha) * math.clamp(dt * blendSpeed, 0, 1)

		if state.alpha <= 0.003 then
			if targetAlpha <= 0 then
				clear()
			end
			return
		end
		state.cleared = false

		local speedRef = math.max(getMaxSwingSpeed(), 1)
		local speedAlpha = math.clamp(velocity.Magnitude / speedRef, 0, 1.35)
		state.clock += dt * (0.8 + speedAlpha * 1.45)
		state.velocityLag = state.velocityLag:Lerp(velocity, math.clamp(dt * C.SWING_POSE_VELOCITY_LAG_SPEED, 0, 1))

		local lagVelocity = velocity - state.velocityLag
		local localVelocity = hrp.CFrame:VectorToObjectSpace(velocity)
		local localLag = hrp.CFrame:VectorToObjectSpace(lagVelocity)
		local localRadial = radial and hrp.CFrame:VectorToObjectSpace(radial) or Vector3.new(0, -1, 0)
		local forwardMotion = math.clamp(-localVelocity.Z / speedRef, -1, 1)
		local sideMotion = math.clamp(localVelocity.X / speedRef, -1, 1)
		local lagForward = math.clamp(-localLag.Z / 48, -1, 1)
		local lagSide = math.clamp(localLag.X / 48, -1, 1)
		local verticalMotion = math.clamp(velocity.Y / 72, -1, 1)
		local stretch = math.clamp(extT or 0, 0, 1)
		local poseMomentum = math.clamp(momentum or 0, 0, 1)
		local physicsAlpha = math.clamp(speedAlpha * 0.42 + poseMomentum * 0.5 + stretch * 0.22, 0, 1.25)
		local response = math.clamp(dt * C.SWING_POSE_STATE_RESPONSE * (0.65 + physicsAlpha * 0.45), 0, 1)

		local targetTorsoPitch = math.clamp(
			-forwardMotion * 0.38 - lagForward * 0.62 - localRadial.Z * 0.42 + verticalMotion * 0.14,
			-1,
			1
		) * C.SWING_POSE_TORSO_LEAN * (0.55 + physicsAlpha * 0.62)
		local targetTorsoRoll = math.clamp(-sideMotion * 0.32 - lagSide * 0.55 - localRadial.X * 0.4, -1, 1)
			* C.SWING_POSE_TORSO_ROLL
			* (0.55 + physicsAlpha * 0.62)
		local targetTorsoYaw = math.clamp(sideMotion * 0.24 + lagSide * 0.34 + localRadial.X * 0.12, -1, 1)
			* C.SWING_POSE_TORSO_YAW
			* (0.45 + physicsAlpha * 0.7)

		local inputAlpha = 0
		if moveFlatUnit or (forwardInput or 0) > 0.08 then
			inputAlpha = math.clamp((forwardInput or 0) + 0.35, 0, 1)
		end
		local legMotionAlpha = math.clamp(
			speedAlpha * 0.72 + poseMomentum * 0.32 + stretch * 0.16 + inputAlpha * 0.28 + math.abs(lagForward) * 0.18,
			0,
			1
		)
		local movingLegBack = C.SWING_POSE_LEG_BACK
			* C.SWING_POSE_LEG_BACK_DIRECTION
			* math.clamp(0.35 + legMotionAlpha * 0.82 - math.max(verticalMotion, 0) * 0.08, 0.22, 1.12)
		local idleLegFront = C.SWING_POSE_LEG_FRONT_IDLE
			* -C.SWING_POSE_LEG_BACK_DIRECTION
			* math.clamp(1 - legMotionAlpha * 1.35, 0, 1)
		local targetLegBack = movingLegBack * legMotionAlpha + idleLegFront * (1 - legMotionAlpha)
		local targetKneeBend = C.SWING_POSE_KNEE_BEND
			* math.clamp(0.16 + legMotionAlpha * 0.34 + stretch * 0.16 + poseMomentum * 0.12, 0.1, 0.82)
		local targetAnkleFlex = C.SWING_POSE_ANKLE_FLEX
			* math.clamp(-verticalMotion * 0.18 + legMotionAlpha * 0.18, -0.24, 0.58)
		local targetFreeArmBack = -C.SWING_POSE_FREE_ARM_BACK
			* math.clamp(0.35 + physicsAlpha * 0.44 + stretch * 0.18 + inputAlpha * 0.12, 0.28, 1.08)
		local targetFreeArmOut = C.SWING_POSE_FREE_ARM_OUT
			* math.clamp(0.25 + math.abs(sideMotion) * 0.35 + physicsAlpha * 0.22, 0.18, 0.86)
		local targetFreeArmSway = (
			math.sin(state.clock * 4.1) * (0.28 + physicsAlpha * 0.72)
			+ sideMotion * 0.55
			+ lagSide * 0.35
		) * C.SWING_POSE_FREE_ARM_SWAY
		local targetFreeElbow = C.SWING_POSE_FREE_ELBOW
			* math.clamp(0.25 + legMotionAlpha * 0.2 + poseMomentum * 0.2, 0.18, 0.88)

		state.torsoPitch += (targetTorsoPitch - state.torsoPitch) * response
		state.torsoRoll += (targetTorsoRoll - state.torsoRoll) * response
		state.torsoYaw += (targetTorsoYaw - state.torsoYaw) * response
		state.legBack += (targetLegBack - state.legBack) * response
		state.kneeBend += (targetKneeBend - state.kneeBend) * response
		state.ankleFlex += (targetAnkleFlex - state.ankleFlex) * response
		state.freeArmBack += (targetFreeArmBack - state.freeArmBack) * response
		state.freeArmOut += (targetFreeArmOut - state.freeArmOut) * response
		state.freeArmSway += (targetFreeArmSway - state.freeArmSway) * response
		state.freeElbow += (targetFreeElbow - state.freeElbow) * response

		local alpha = state.alpha
		local joints = state.joints

		applyJointOffset(
			joints.root,
			CFrame.Angles(
				state.torsoPitch * 0.48 * alpha,
				state.torsoYaw * 0.28 * alpha,
				state.torsoRoll * 0.42 * alpha
			)
		)
		applyJointOffset(
			joints.waist,
			CFrame.Angles(state.torsoPitch * 0.95 * alpha, state.torsoYaw * 0.72 * alpha, state.torsoRoll * 0.9 * alpha)
		)
		applyJointOffset(
			joints.neck,
			CFrame.Angles(
				-state.torsoPitch * 0.25 * alpha,
				-state.torsoYaw * 0.24 * alpha,
				-state.torsoRoll * 0.18 * alpha
			)
		)
		if state.isR6 then
			local r6LegBack = math.clamp(state.legBack, -math.rad(40), math.rad(22))
				* C.SWING_POSE_R6_LEG_BACK_DIRECTION
				* alpha
			applyJointOffset(joints.leftHip, CFrame.Angles(0, 0, -r6LegBack))
			applyJointOffset(joints.rightHip, CFrame.Angles(0, 0, r6LegBack))
		else
			applyJointOffset(joints.leftHip, CFrame.Angles(state.legBack * alpha, 0, 0))
			applyJointOffset(joints.rightHip, CFrame.Angles(state.legBack * alpha, 0, 0))
			applyJointOffset(joints.leftKnee, CFrame.Angles(state.kneeBend * alpha, 0, 0))
			applyJointOffset(joints.rightKnee, CFrame.Angles(state.kneeBend * alpha, 0, 0))
			applyJointOffset(joints.leftAnkle, CFrame.Angles(-state.ankleFlex * alpha, 0, 0))
			applyJointOffset(joints.rightAnkle, CFrame.Angles(-state.ankleFlex * alpha, 0, 0))
		end
		if hangSide == "Right" then
			applyJointOffset(
				joints.leftShoulder,
				CFrame.Angles(state.freeArmBack * alpha, -state.freeArmSway * alpha, -state.freeArmOut * alpha)
			)
			applyJointOffset(joints.leftElbow, CFrame.Angles(state.freeElbow * alpha, 0, 0))
		elseif hangSide == "Left" then
			applyJointOffset(
				joints.rightShoulder,
				CFrame.Angles(state.freeArmBack * alpha, state.freeArmSway * alpha, state.freeArmOut * alpha)
			)
			applyJointOffset(joints.rightElbow, CFrame.Angles(state.freeElbow * alpha, 0, 0))
		end
	end

	return {
		clear = clear,
		step = step,
	}
end

local function createReleaseStyleController(humanoid, hrp)
	local state = {
		untilClock = -1e9,
		launchDir = Vector3.new(0, 0, -1),
		rollSign = 1,
		attachment = nil,
		orientation = nil,
	}

	local function destroy()
		if state.orientation then
			state.orientation:Destroy()
			state.orientation = nil
		end
		if state.attachment then
			state.attachment:Destroy()
			state.attachment = nil
		end
	end

	local function ensure()
		if state.orientation and state.orientation.Parent and state.attachment and state.attachment.Parent then
			return state.orientation
		end

		destroy()

		state.attachment = Instance.new("Attachment")
		state.attachment.Name = "SwingLaunchOrientationAttachment"
		state.attachment.Parent = hrp

		state.orientation = Instance.new("AlignOrientation")
		state.orientation.Name = "SwingLaunchFaceDirection"
		state.orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
		state.orientation.Attachment0 = state.attachment
		state.orientation.RigidityEnabled = false
		state.orientation.Responsiveness = C.LAUNCH_STYLE_ORIENT_RESPONSIVENESS
		state.orientation.MaxTorque = hrp.AssemblyMass * C.LAUNCH_STYLE_ORIENT_TORQUE
		state.orientation.Enabled = true
		state.orientation.Parent = hrp

		return state.orientation
	end

	local function smoothStep(alpha)
		alpha = math.clamp(alpha, 0, 1)
		return alpha * alpha * (3 - 2 * alpha)
	end

	local function launchLookCFrame(lookDir, roll)
		local upVector = Vector3.yAxis
		if math.abs(lookDir:Dot(upVector)) > 0.88 then
			upVector = -state.launchDir
			if upVector.Magnitude < 0.05 then
				upVector = hrp.CFrame.UpVector
			end
		end

		return CFrame.lookAt(hrp.Position, hrp.Position + lookDir, upVector) * CFrame.Angles(0, 0, roll)
	end

	local controller = {}

	function controller.cancel()
		state.untilClock = -1e9
		destroy()
	end

	function controller.apply(
		currentCamera,
		snapVelocity,
		snapPosition,
		snapAnchorWorld,
		heldTime,
		charge,
		forwardCharge,
		forwardHeldTime,
		momentum
	)
		if not currentCamera or not hrp.Parent then
			return
		end

		hrp.AssemblyLinearVelocity = snapVelocity
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		humanoid.PlatformStand = false
		humanoid.AutoRotate = false
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

		local velocity = snapVelocity
		local camLook = currentCamera.CFrame.LookVector
		local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
		local camFlatUnit = camFlat.Magnitude > 0.08 and camFlat.Unit or Vector3.new(0, 0, -1)
		local holdMult = math.clamp(heldTime / C.MIN_HOLD_FOR_FULL_LAUNCH, 0.92, 1)
		local launchScale = getLaunchScale()
		local radial = Vector3.new(0, 1, 0)

		if snapAnchorWorld then
			local fromAnchor = snapPosition - snapAnchorWorld
			if fromAnchor.Magnitude > 0.25 then
				radial = fromAnchor.Unit
			end
		end

		local tangVelocity = velocity - radial * velocity:Dot(radial)
		local tangSpeed = tangVelocity.Magnitude
		local facingDir = flatUnit(hrp.CFrame.LookVector) or camFlatUnit
		local launchDir = facingDir

		if tangSpeed > 2 then
			local tangentBlend = math.clamp(C.LAUNCH_MOMENTUM_RATIO + tangSpeed / 260, 0, 0.22)
			launchDir = facingDir * (1 - tangentBlend) + tangVelocity.Unit * tangentBlend
		end
		if launchDir.Magnitude > 0.05 then
			launchDir = launchDir.Unit
		else
			launchDir = facingDir
		end

		local forwardHoldBonus = math.clamp(forwardHeldTime / C.FORWARD_CHARGE_TIME, 0, 1)
		local inputBoost = math.clamp(forwardCharge + forwardHoldBonus * 0.35, 0, 1.35)
		local momentumBoost = math.clamp(momentum or 0, 0, 1)
		local cap = C.LAUNCH_SPEED_CAP
			* math.clamp(1 + (launchScale - 1) * 1.05, 0.9, 3.15)
			* (1 + momentumBoost * C.SWING_MOMENTUM_LAUNCH_BONUS * 0.86)

		local horizontalSpeed = (
			C.LAUNCH_FORWARD_DV
			+ C.LAUNCH_FORWARD_INPUT_DV * inputBoost
			+ C.LAUNCH_CHARGE_DV * charge * 0.5
			+ C.LAUNCH_FORWARD_DV * C.SWING_MOMENTUM_LAUNCH_BONUS * momentumBoost
		)
			* holdMult
			* launchScale
			* math.clamp(0.96 + (launchScale - 1) * 0.36, 0.9, 1.72)
		local upwardSpeed = (
			C.LAUNCH_UP_DV
			+ C.LAUNCH_CHARGE_DV * charge * 0.45
			+ inputBoost * 5.8
			+ momentumBoost * 6.8
		)
			* holdMult
			* launchScale
		local targetVelocity = launchDir * horizontalSpeed + Vector3.new(0, upwardSpeed, 0)

		if targetVelocity.Magnitude > cap then
			targetVelocity = targetVelocity.Unit * cap
		end
		hrp.AssemblyLinearVelocity = targetVelocity

		state.launchDir = launchDir
		local bodyRight = Vector3.new(hrp.CFrame.RightVector.X, 0, hrp.CFrame.RightVector.Z)
		local rollDot = bodyRight.Magnitude > 0.05 and targetVelocity:Dot(bodyRight.Unit) or 0
		state.rollSign = rollDot ~= 0 and math.sign(rollDot) or 1
		state.untilClock = os.clock() + C.LAUNCH_STYLE_TIME

		local orient = ensure()
		if orient then
			local lookDir = launchDir * 0.62 + Vector3.new(0, C.LAUNCH_STYLE_UP_AIM, 0)
			if lookDir.Magnitude > 0.05 then
				orient.CFrame = launchLookCFrame(lookDir.Unit, math.rad(8) * state.rollSign)
			end
		end
	end

	function controller.step(now, dt, activeLaunched, activeSwinging, launchClock)
		if not activeLaunched or now > state.untilClock then
			if activeLaunched and not activeSwinging then
				destroy()
				state.untilClock = -1e9
				humanoid.PlatformStand = false
				humanoid.AutoRotate = true
			elseif not activeSwinging then
				controller.cancel()
			end
			return
		end

		local age = now - launchClock
		if age < 0 then
			return
		end

		humanoid.AutoRotate = false
		humanoid.PlatformStand = false
		local launchDir = state.launchDir.Magnitude > 0.05 and state.launchDir.Unit
			or flatUnit(hrp.CFrame.LookVector)
			or Vector3.new(0, 0, -1)
		local velocity = hrp.AssemblyLinearVelocity
		local spinFade = 1 - math.clamp(age / C.LAUNCH_STYLE_TIME, 0, 1)
		local upAlpha = 1 - smoothStep(age / C.LAUNCH_STYLE_TILT_TIME)
		local fallCue = math.clamp((-velocity.Y + 8) / 48, 0, 1)
		local downAlpha = math.max(
			smoothStep(
				(age - C.LAUNCH_STYLE_TILT_TIME * 0.8)
					/ math.max(C.LAUNCH_STYLE_TIME - C.LAUNCH_STYLE_TILT_TIME * 0.8, 0.05)
			),
			fallCue
		)
		local verticalAim = C.LAUNCH_STYLE_UP_AIM * upAlpha - C.LAUNCH_STYLE_DOWN_AIM * downAlpha
		local lookDir = launchDir * (0.7 + downAlpha * 0.35) + Vector3.new(0, verticalAim, 0)
		if lookDir.Magnitude > 0.05 then
			local orient = ensure()
			if orient then
				local roll = math.rad(12) * state.rollSign * spinFade
				orient.Responsiveness = C.LAUNCH_STYLE_ORIENT_RESPONSIVENESS + downAlpha * 14
				orient.CFrame = launchLookCFrame(lookDir.Unit, roll)
			end
		end
		hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-10 * dt)

		if age >= C.LAUNCH_DROP_DELAY then
			local dropAlpha = math.clamp(
				(age - C.LAUNCH_DROP_DELAY) / math.max(C.LAUNCH_STYLE_TIME - C.LAUNCH_DROP_DELAY, 0.05),
				0,
				1
			)
			local nextY =
				math.max(C.LAUNCH_DROP_MAX_SPEED, velocity.Y - C.LAUNCH_DROP_ACCEL * (0.35 + dropAlpha * 0.65) * dt)
			hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, nextY, velocity.Z)
		end
	end

	return controller
end

local function boot(character)
	camera = workspace.CurrentCamera or camera

	local humanoid = character:WaitForChild("Humanoid", 30)
	local hrp = character:WaitForChild("HumanoidRootPart", 30)
	if not humanoid or not hrp then
		return function() end
	end

	local function isHrpInSafezone()
		if not SafezoneUtil or typeof(SafezoneUtil.isCharacterInSafezone) ~= "function" then
			return false
		end

		local ok, blocked = pcall(function()
			return SafezoneUtil.isCharacterInSafezone(character)
		end)
		return ok and blocked == true
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local originalFov = camera and camera.FieldOfView or 70
	local function resetFovNow()
		camera = workspace.CurrentCamera or camera
		if camera then
			camera.FieldOfView = originalFov
		end
	end

	local isSwinging = false
	local isLaunched = false
	local isAirborne = false
	local landedFromSwing = false
	local landingSpeed = 0
	local swingTimer = 0
	local swingCharge = 0
	local forwardSwingCharge = 0
	local forwardHoldTime = 0
	local swingMomentum = 0
	local swingRhythmBoost = 0
	local lastPumpInputSign = 0
	local lastPumpSwitchClock = -1e9
	local swingFaceDir = nil
	local swingPose = createSwingPose(character, hrp)
	local lastTryClock = -1e9
	local lastAttachClock = -1e9
	local lastGroundJumpClock = -1e9
	local airborneStartedClock = -1e9
	local lastLaunchClock = -1e9
	local releaseStyle = createReleaseStyleController(humanoid, hrp)
	local poseInputs = {
		radial = nil,
		moveFlatUnit = nil,
		forwardInput = 0,
		extT = 0,
		momentum = 0,
	}
	local lastLandingClock = -1e9
	local landingShakeStrength = 0
	local landingShakeSeed = math.random() * 1000
	local lastGroundDragDebrisClock = -1e9
	local swingCamRoll = 0
	local swingCamLag = Vector3.new(0, 0, 0)
	local renderBindName = "UnifiedSwingCameraFX_" .. tostring(os.clock()) .. "_" .. tostring(math.random(1, 1000000))

	local spaceHeld = false
	local gamepadHeld = false
	local mobileJumpHeld = false
	local mobileJumpBound = false

	local targetCache = {}
	local targetSet = {}
	local targetGrid = {}
	local targetGridKeyByPart = {}
	local boundVines = {}
	local targetCacheReady = false
	local lastTargetScanClock = -1e9
	local lastTargetScanMode = "none"
	local scannedVisualTarget = nil
	local scannedVisualCanSwing = false

	local currentTarget = nil
	local lastReleasedTarget = nil
	local lastReleasedTargetClock = -1e9
	local highlightedTarget = nil
	local highlightedPoint = nil
	local targetVisualShown = false
	local anchorAttachment = nil
	local bodyAttachment = nil
	local ropeConstraint = nil
	local activeRopeMaxLength = nil
	local ropeCatchUntil = -1e9
	local ropeCatchStartLength = nil
	local zipSpring = nil
	local forceAttachment = nil
	local steerForce = nil
	local orientationAttachment = nil
	local swingOrientation = nil
	local handAttachment = nil
	local swingBeam = nil
	local previewAnchorPart = nil
	local previewFrom = nil
	local previewTo = nil
	local previewBeam = nil
	local previewTarget = nil
	local previewFade = 0
	local previewFadeGoal = 0
	local lastPreviewFadeBucket = -1
	local lastPreviewColor = nil
	local targetVisualStepAccum = 0
	local targetHighlight = nil
	local targetHighlightAdornee = nil
	local targetHighlightProxyPart = nil
	local lastHighlightColor = nil
	local lastHighlightFillTransparency = nil
	local markerAnchorPart = nil
	local markerGui = nil
	local markerLabel = nil
	local markerRing = nil
	local markerStroke = nil
	local markerDot = nil
	local lastMarkerText = nil
	local lastVisualTarget = nil
	local lastVisualCanSwing = nil
	local targetReadyVisual = 0
	local targetReadyGoal = 0
	local targetVisualColor = C.NOT_READY_COLOR
	local chargeGui = nil
	local chargeDot = nil
	local fallbackMobileGui = nil
	local activeHangTrack = nil
	local currentHangSide = "Right"
	local rightHangTrack = nil
	local leftHangTrack = nil
	local fallingTrack = nil
	local landedTrack = nil
	local lastLandedAnimClock = -1e9
	local trails = {}
	local conns = {}
	local mobileConns = {}

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local function normalizeAnimationId(id)
		if typeof(id) == "Instance" then
			if id:IsA("Animation") then
				return id.AnimationId
			end
			if id:IsA("StringValue") then
				return id.Value
			end
			if id:IsA("NumberValue") or id:IsA("IntValue") then
				return id.Value
			end
			return ""
		end
		if typeof(id) == "number" then
			return "rbxassetid://" .. tostring(math.floor(id))
		end
		if typeof(id) ~= "string" then
			return ""
		end

		local cleaned = id:gsub("%s+", "")
		if cleaned == "" or cleaned == "0" then
			return ""
		end
		if cleaned:match("^%d+$") then
			return "rbxassetid://" .. cleaned
		end
		if cleaned:match("^rbxassetid://%d+$") then
			return cleaned
		end

		local assetId = cleaned:match("id=(%d+)") or cleaned:match("(%d+)")
		if assetId then
			return "rbxassetid://" .. assetId
		end

		return cleaned
	end

	local playerAnimationsFolder = nil
	local playerAnimationsFolderSearched = false

	local function getPlayerAnimationsFolder()
		if playerAnimationsFolder and playerAnimationsFolder.Parent then
			return playerAnimationsFolder
		end
		if playerAnimationsFolderSearched then
			return nil
		end
		playerAnimationsFolderSearched = true

		local animationsFolder = ReplicatedStorage:FindFirstChild(C.ANIMATIONS_FOLDER_NAME)
			or ReplicatedStorage:WaitForChild(C.ANIMATIONS_FOLDER_NAME, 5)
		playerAnimationsFolder = animationsFolder
			and (
				animationsFolder:FindFirstChild(C.PLAYER_ANIMATIONS_FOLDER_NAME)
				or animationsFolder:WaitForChild(C.PLAYER_ANIMATIONS_FOLDER_NAME, 5)
			)
		if not playerAnimationsFolder then
			warn(
				"[MergedFriendSwingSystem] Missing animation folder:",
				C.ANIMATIONS_FOLDER_NAME .. "/" .. C.PLAYER_ANIMATIONS_FOLDER_NAME
			)
		end
		return playerAnimationsFolder
	end

	local function findPlayerAnimation(name)
		local folder = getPlayerAnimationsFolder()
		local anim = folder and folder:FindFirstChild(name)
		if not anim then
			warn(
				"[MergedFriendSwingSystem] Missing animation:",
				C.ANIMATIONS_FOLDER_NAME .. "/" .. C.PLAYER_ANIMATIONS_FOLDER_NAME .. "/" .. name
			)
			return nil
		end
		if not anim:IsA("Animation") then
			warn("[MergedFriendSwingSystem] Animation object is not an Animation:", anim:GetFullName())
			return nil
		end
		return anim
	end

	local function loadAnimTrack(source, looped, priority, name)
		if not C.ENABLE_SWING_ANIMATIONS then
			return nil
		end

		local animId = normalizeAnimationId(source)
		if animId == "" then
			return nil
		end

		local anim = Instance.new("Animation")
		anim.Name = name or "SwingAnimation"
		anim.AnimationId = animId
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		anim:Destroy()
		if ok and track then
			track.Priority = priority or Enum.AnimationPriority.Action4
			track.Looped = looped == true
			return track
		end
		warn("[MergedFriendSwingSystem] Failed to load animation:", name or animId, track)
		return nil
	end

	local function playTrack(track, fadeTime, weight, speed)
		if not track then
			return
		end
		local ok, err = pcall(function()
			if not track.IsPlaying then
				track:Play(fadeTime or 0.12, weight or 1, speed or 1)
			else
				track:AdjustWeight(weight or 1, fadeTime or 0.08)
				track:AdjustSpeed(speed or 1)
			end
		end)
		if not ok then
			warn("[MergedFriendSwingSystem] Failed to play animation:", track.Name, err)
		end
	end

	local function stopTrack(track, fadeTime)
		if not track then
			return
		end
		local fade = fadeTime
		if fade == nil then
			fade = 0.08
		end
		pcall(function()
			if track.IsPlaying then
				track:AdjustWeight(0, fade)
				track:Stop(fade)
			end
		end)
	end

	local hangRightAnim = findPlayerAnimation(C.HANG_ANIM_RIGHT_NAME)
	local hangLeftAnim = findPlayerAnimation(C.HANG_ANIM_LEFT_NAME)
	local fallingAnim = findPlayerAnimation(C.FALLING_ANIM_NAME)
	local landedAnim = findPlayerAnimation(C.LANDED_ANIM_NAME)

	rightHangTrack = loadAnimTrack(hangRightAnim, true, Enum.AnimationPriority.Action4, "HangRight")
	if normalizeAnimationId(hangLeftAnim) == normalizeAnimationId(hangRightAnim) then
		leftHangTrack = rightHangTrack
	else
		leftHangTrack = loadAnimTrack(hangLeftAnim, true, Enum.AnimationPriority.Action4, "HangLeft")
	end
	fallingTrack = loadAnimTrack(fallingAnim, true, Enum.AnimationPriority.Action4, "SwingFalling")
	landedTrack = loadAnimTrack(landedAnim, false, Enum.AnimationPriority.Action4, "SwingLanded")

	local function addConn(conn)
		table.insert(conns, conn)
		return conn
	end

	local function addMobileConn(conn)
		table.insert(mobileConns, conn)
		return conn
	end

	local function handPartForSide(side)
		local names
		if side == "Left" then
			names = { "LeftHand", "Left Arm", "LeftLowerArm", "LeftUpperArm" }
		else
			names = { "RightHand", "Right Arm", "RightLowerArm", "RightUpperArm" }
		end
		for _, name in ipairs(names) do
			local p = character:FindFirstChild(name, true)
			if p and p:IsA("BasePart") then
				return p
			end
		end
		return hrp
	end

	local function getSwingSide(attachWorld)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return "Right"
		end
		local toTarget = Vector3.new(attachWorld.X - hrp.Position.X, 0, attachWorld.Z - hrp.Position.Z)
		local camRight = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
		if toTarget.Magnitude > 0.1 and camRight.Magnitude > 0.1 and toTarget.Unit:Dot(camRight.Unit) < 0 then
			return "Left"
		end
		return "Right"
	end

	local function playHangAnim(attachWorld)
		stopTrack(fallingTrack, 0.1)
		stopTrack(landedTrack, 0.08)
		local side = getSwingSide(attachWorld)
		currentHangSide = side
		local track = side == "Left" and leftHangTrack or rightHangTrack
		if activeHangTrack and activeHangTrack ~= track then
			stopTrack(activeHangTrack, 0.12)
		end
		activeHangTrack = track
		if activeHangTrack then
			playTrack(activeHangTrack, 0.12, 1, 1)
		end
	end

	local function stopHangAnim(fadeTime)
		local fade = fadeTime
		if fade == nil then
			fade = 0.08
		end
		stopTrack(rightHangTrack, fade)
		if leftHangTrack ~= rightHangTrack then
			stopTrack(leftHangTrack, fade)
		end
		activeHangTrack = nil
	end

	local function playFallingAnim(fadeTime)
		if isSwinging or not (isLaunched or landedFromSwing) then
			return
		end
		local fade = fadeTime
		if fade == nil then
			fade = 0.04
		end
		stopHangAnim(0)
		stopTrack(landedTrack, 0.04)
		if fallingTrack then
			pcall(function()
				fallingTrack.TimePosition = 0
			end)
		end
		playTrack(fallingTrack, fade, 1, 1)
	end

	local function stopFallingAnim()
		stopTrack(fallingTrack, 0.08)
	end

	local function playLandedAnim()
		stopHangAnim(0)
		stopFallingAnim()
		local now = os.clock()
		if now - lastLandedAnimClock < 0.12 then
			return
		end
		lastLandedAnimClock = now
		if landedTrack then
			pcall(function()
				landedTrack.TimePosition = 0
			end)
			playTrack(landedTrack, 0.06, 1, 1)
		end
	end

	local function makeTrails()
		local limbNames = {
			"Right Arm",
			"Left Arm",
			"Right Leg",
			"Left Leg",
			"RightHand",
			"LeftHand",
			"RightFoot",
			"LeftFoot",
		}
		local seen = {}
		for _, name in ipairs(limbNames) do
			local part = character:FindFirstChild(name, true)
			if part and part:IsA("BasePart") and not seen[part] then
				seen[part] = true
				local a0 = Instance.new("Attachment")
				a0.Position = Vector3.new(0, 0.22, 0)
				a0.Parent = part
				local a1 = Instance.new("Attachment")
				a1.Position = Vector3.new(0, -0.22, 0)
				a1.Parent = part
				local trail = Instance.new("Trail")
				trail.Attachment0 = a0
				trail.Attachment1 = a1
				trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
				trail.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.68),
					NumberSequenceKeypoint.new(1, 1),
				})
				trail.WidthScale = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.8),
					NumberSequenceKeypoint.new(1, 0),
				})
				trail.Lifetime = 0.26
				trail.Enabled = false
				trail.Parent = part
				table.insert(trails, trail)
			end
		end
	end

	makeTrails()

	local function setTrailsEnabled(on)
		for _, trail in ipairs(trails) do
			if trail and trail.Parent then
				trail.Enabled = on
			end
		end
	end

	local function closestAttachWorldOnPart(part)
		local ok, point = pcall(function()
			return part:GetClosestPointOnSurface(hrp.Position)
		end)
		if ok and typeof(point) == "Vector3" then
			return point
		end
		return part.Position
	end

	local function targetCellCoord(value)
		return math.floor(value / C.TARGET_GRID_CELL_SIZE)
	end

	local function targetGridKeyFromCoords(x, y, z)
		return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
	end

	local function targetGridKeyForPosition(pos)
		return targetGridKeyFromCoords(targetCellCoord(pos.X), targetCellCoord(pos.Y), targetCellCoord(pos.Z))
	end

	local function removeTargetFromGrid(part)
		local oldKey = targetGridKeyByPart[part]
		if not oldKey then
			return
		end

		targetGridKeyByPart[part] = nil
		local cell = targetGrid[oldKey]
		if not cell then
			return
		end

		cell[part] = nil
		if not next(cell) then
			targetGrid[oldKey] = nil
		end
	end

	local function addTargetToGrid(part)
		removeTargetFromGrid(part)

		local key = targetGridKeyForPosition(part.Position)
		targetGridKeyByPart[part] = key

		local cell = targetGrid[key]
		if not cell then
			cell = {}
			targetGrid[key] = cell
		end
		cell[part] = true
	end

	local function addSwingTarget(obj)
		if not obj:IsA("BasePart") or not obj.Parent then
			return
		end
		if targetSet[obj] then
			return
		end

		targetSet[obj] = true
		table.insert(targetCache, obj)
		addTargetToGrid(obj)
	end

	local function removeSwingTarget(obj)
		if not targetSet[obj] then
			return
		end

		targetSet[obj] = nil
		for i = #targetCache, 1, -1 do
			if targetCache[i] == obj then
				table.remove(targetCache, i)
				break
			end
		end
		removeTargetFromGrid(obj)
	end

	local function seedVineTargets(vine)
		if not vine or not C.TARGET_BACKGROUND_SEED_ENABLED then
			return
		end

		task.spawn(function()
			local stack = { vine }
			local processed = 0
			local sliceStarted = os.clock()

			while #stack > 0 and vine.Parent do
				local obj = table.remove(stack)
				if obj:IsA("BasePart") and obj.Name == C.SWING_TARGET_NAME then
					addSwingTarget(obj)
				end

				if not obj:IsA("BasePart") then
					for _, child in ipairs(obj:GetChildren()) do
						table.insert(stack, child)
					end
				end

				processed += 1
				if
					processed % C.TARGET_SEED_BATCH_SIZE == 0
					or os.clock() - sliceStarted >= C.TARGET_SEED_MAX_SLICE_TIME
				then
					task.wait(C.TARGET_SEED_STEP_WAIT)
					sliceStarted = os.clock()
				end
			end
		end)
	end

	local function bindVineFolder(vine, seedExisting)
		if not vine or not C.TARGET_ENABLE_VINE_NAME_FALLBACK then
			return
		end
		if boundVines[vine] then
			return
		end
		boundVines[vine] = true

		if seedExisting ~= false then
			seedVineTargets(vine)
		end
		addConn(vine.DescendantAdded:Connect(function(obj)
			if obj:IsA("BasePart") and obj.Name == C.SWING_TARGET_NAME then
				addSwingTarget(obj)
			end
		end))
		addConn(vine.DescendantRemoving:Connect(function(obj)
			removeSwingTarget(obj)
		end))
	end

	local function initializeTargetCache()
		if targetCacheReady then
			return
		end
		targetCacheReady = true

		local taggedTargets = CollectionService:GetTagged(C.SWING_TARGET_TAG)
		for _, obj in ipairs(taggedTargets) do
			addSwingTarget(obj)
		end
		local hasTaggedTargets = #taggedTargets > 0

		addConn(CollectionService:GetInstanceAddedSignal(C.SWING_TARGET_TAG):Connect(addSwingTarget))
		addConn(CollectionService:GetInstanceRemovedSignal(C.SWING_TARGET_TAG):Connect(removeSwingTarget))

		local map = workspace:FindFirstChild(C.MAP_FOLDER_NAME)
		local vine = map and map:FindFirstChild(C.VINE_FOLDER_NAME)
		bindVineFolder(vine, not (C.TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))

		if C.TARGET_ENABLE_VINE_NAME_FALLBACK and not vine then
			addConn(workspace.DescendantAdded:Connect(function(obj)
				if obj.Name == C.VINE_FOLDER_NAME then
					local parent = obj.Parent
					if parent and parent.Name == C.MAP_FOLDER_NAME then
						bindVineFolder(obj, not (C.TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))
					end
				elseif obj:IsA("BasePart") and obj.Name == C.SWING_TARGET_NAME then
					local ancestor = obj.Parent
					while ancestor do
						if ancestor.Name == C.VINE_FOLDER_NAME then
							addSwingTarget(obj)
							break
						end
						ancestor = ancestor.Parent
					end
				end
			end))
		end

		if not hasTaggedTargets and not C.TARGET_ENABLE_VINE_NAME_FALLBACK then
			warn(
				"[MergedFriendSwingSystem] No CollectionService 'SwingTarget' tags found. Tag the real swing parts to avoid scanning huge Vine folders."
			)
		end
	end

	local function getTargets()
		initializeTargetCache()

		for i = #targetCache, 1, -1 do
			local part = targetCache[i]
			if not part.Parent or not part:IsDescendantOf(workspace) then
				targetSet[part] = nil
				removeTargetFromGrid(part)
				table.remove(targetCache, i)
			end
		end

		return targetCache
	end

	task.defer(initializeTargetCache)

	local function getCandidateTargets(maxDistance)
		initializeTargetCache()
		if #targetCache == 0 and not C.TARGET_ENABLE_VINE_NAME_FALLBACK then
			return {}
		end

		local radius = math.max(2, (maxDistance or getSwingRange()) + C.TARGET_CANDIDATE_EXTRA_RADIUS)
		local origin = hrp.Position
		local candidates = {}
		local seen = {}
		local invalidTargets = {}

		local centerX = targetCellCoord(origin.X)
		local centerY = targetCellCoord(origin.Y)
		local centerZ = targetCellCoord(origin.Z)
		local cellRadius = math.max(1, math.ceil(radius / C.TARGET_GRID_CELL_SIZE))
		local candidateLimitHit = false

		for x = centerX - cellRadius, centerX + cellRadius do
			if candidateLimitHit then
				break
			end
			for y = centerY - cellRadius, centerY + cellRadius do
				if candidateLimitHit then
					break
				end
				for z = centerZ - cellRadius, centerZ + cellRadius do
					if candidateLimitHit then
						break
					end
					local cell = targetGrid[targetGridKeyFromCoords(x, y, z)]
					if cell then
						for part in pairs(cell) do
							if not seen[part] then
								seen[part] = true
								if not part.Parent or not part:IsDescendantOf(workspace) then
									table.insert(invalidTargets, part)
									continue
								end
								if not targetSet[part] or part:IsDescendantOf(character) then
									continue
								end

								local halfSize = part.Size.Magnitude * 0.5
								if (part.Position - origin).Magnitude <= radius + halfSize then
									table.insert(candidates, part)
									if #candidates >= C.TARGET_MAX_CANDIDATES_PER_SCAN then
										candidateLimitHit = true
										break
									end
								end
							end
						end
					end
				end
			end
		end

		for _, part in ipairs(invalidTargets) do
			removeSwingTarget(part)
		end

		if #candidates == 0 and #targetCache <= C.TARGET_FULL_SCAN_FALLBACK_LIMIT then
			for _, part in ipairs(getTargets()) do
				if
					not seen[part]
					and part.Parent
					and part:IsDescendantOf(workspace)
					and not part:IsDescendantOf(character)
				then
					local halfSize = part.Size.Magnitude * 0.5
					if (part.Position - origin).Magnitude <= radius + halfSize then
						seen[part] = true
						table.insert(candidates, part)
					end
				end
			end
		end

		return candidates
	end

	local function hasLineOfSight(part, attachWorld)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return true
		end

		local origin = camera.CFrame.Position
		local delta = attachWorld - origin
		if delta.Magnitude < 0.5 then
			return true
		end

		local ignored = { character }
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude

		for _ = 1, 8 do
			params.FilterDescendantsInstances = ignored
			local hit = workspace:Raycast(origin, delta, params)
			if not hit then
				return true
			end

			local inst = hit.Instance
			if inst == part or inst:IsDescendantOf(part) then
				return true
			end

			if inst.CanCollide and inst.Transparency < 0.85 then
				return false
			end

			table.insert(ignored, inst)
		end

		return false
	end

	local function pickSwingTarget(requireLineOfSight, maxDistanceOverride, minLookDotOverride, maxScreenRadiusOverride)
		camera = workspace.CurrentCamera or camera
		if not camera or not hrp.Parent or isHrpInSafezone() then
			return nil
		end

		local look = camera.CFrame.LookVector
		local flatLook = flatUnit(look)
		local reach = maxDistanceOverride or getSwingRange()
		local minLookDot = minLookDotOverride or C.MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or C.TARGET_SCREEN_RADIUS_LIMIT
		local best = nil
		local bestScore = -math.huge

		for _, part in ipairs(getCandidateTargets(reach)) do
			if not part.Parent or not part:IsDescendantOf(workspace) then
				continue
			end
			if part:IsDescendantOf(character) then
				continue
			end

			local attachWorld = closestAttachWorldOnPart(part)
			local offset = attachWorld - hrp.Position
			local dist = offset.Magnitude
			if dist < 2 or dist > reach then
				continue
			end
			if attachWorld.Y < hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
				continue
			end

			local toCameraTarget = attachWorld - camera.CFrame.Position
			if toCameraTarget.Magnitude < 0.5 then
				continue
			end

			local viewDot = toCameraTarget.Unit:Dot(look)
			if viewDot < minLookDot then
				continue
			end

			local viewportPoint, onScreen = camera:WorldToViewportPoint(attachWorld)
			if not onScreen then
				continue
			end

			local vp = camera.ViewportSize
			local dx = (viewportPoint.X - vp.X * 0.5) / math.max(vp.X, 1)
			local dy = (viewportPoint.Y - vp.Y * 0.5) / math.max(vp.Y, 1)
			local screenRadius = math.sqrt(dx * dx + dy * dy)
			if screenRadius > maxScreenRadius then
				continue
			end

			local align = viewDot
			local flatDir = flatUnit(offset)
			if flatDir and flatLook then
				align = math.max(viewDot, flatDir:Dot(flatLook) * 0.92)
			end
			if requireLineOfSight and not hasLineOfSight(part, attachWorld) then
				continue
			end

			local heightBonus = 0
			if attachWorld.Y > hrp.Position.Y + 5 then
				heightBonus = 0.16
			end

			local centerBias = (1 - math.clamp(screenRadius / math.max(maxScreenRadius, 0.01), 0, 1)) * 2.35

			local score = align * 1.75 + heightBonus + centerBias - (dist / reach) * 0.04
			if score > bestScore then
				bestScore = score
				best = part
			end
		end

		return best
	end

	local function getAirborneTargetUiRange()
		return math.clamp(getSwingRange() + C.AIRBORNE_TARGET_UI_EXTRA, 75, 270)
	end

	local function targetDistanceAndPoint(target)
		if not target or not target.Parent or not target:IsDescendantOf(workspace) then
			return nil, nil
		end
		if target:IsDescendantOf(character) then
			return nil, nil
		end

		local attachWorld = closestAttachWorldOnPart(target)
		if attachWorld.Y < hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
			return nil, nil
		end

		return (attachWorld - hrp.Position).Magnitude, attachWorld
	end

	local function pickNearbySwingTarget(maxDistance, preferredTarget)
		if isHrpInSafezone() then
			return nil, nil, nil
		end
		camera = workspace.CurrentCamera or camera

		local function validCandidate(target)
			local dist, point = targetDistanceAndPoint(target)
			if not dist or dist < 2 or dist > maxDistance then
				return nil, nil
			end
			if camera then
				local toCameraTarget = point - camera.CFrame.Position
				if toCameraTarget.Magnitude > 0.5 and toCameraTarget.Unit:Dot(camera.CFrame.LookVector) < 0.02 then
					return nil, nil
				end
			end
			return dist, point
		end

		if preferredTarget then
			local dist, point = validCandidate(preferredTarget)
			if dist then
				return preferredTarget, dist, point
			end
		end

		local best = nil
		local bestDist = math.huge
		local bestPoint = nil
		for _, part in ipairs(getCandidateTargets(maxDistance)) do
			local dist, point = validCandidate(part)
			if dist and dist < bestDist then
				best = part
				bestDist = dist
				bestPoint = point
			end
		end

		return best, bestDist, bestPoint
	end

	local function pickVisualSwingTarget(readyDistance, maxDistance, preferredTarget, showSafezoneBlocked)
		local inSafezone = isHrpInSafezone()
		if inSafezone and not showSafezoneBlocked then
			return nil, false
		end
		camera = workspace.CurrentCamera or camera

		local function validCandidate(target)
			local dist, point = targetDistanceAndPoint(target)
			if not dist or dist < 2 or dist > maxDistance then
				return nil
			end
			if camera then
				local toCameraTarget = point and (point - camera.CFrame.Position) or nil
				if
					toCameraTarget
					and toCameraTarget.Magnitude > 0.5
					and toCameraTarget.Unit:Dot(camera.CFrame.LookVector) < 0.02
				then
					return nil
				end
			end
			return dist
		end

		local lookedTarget = nil
		if not inSafezone then
			lookedTarget = pickSwingTarget(false, maxDistance, 0.02, 0.98)
		end
		if lookedTarget then
			local lookedDist = validCandidate(lookedTarget)
			if lookedDist then
				return lookedTarget, lookedDist <= readyDistance
			end
		end

		if preferredTarget then
			local preferredDist = validCandidate(preferredTarget)
			if preferredDist then
				return preferredTarget, (not inSafezone) and preferredDist <= readyDistance
			end
		end

		local best = nil
		local bestDist = math.huge
		for _, part in ipairs(getCandidateTargets(maxDistance)) do
			local dist = validCandidate(part)
			if dist and dist < bestDist then
				best = part
				bestDist = dist
			end
		end

		return best, best ~= nil and not inSafezone and bestDist <= readyDistance
	end

	local function attachCandidateScore(target, dist, point, maxDistance)
		camera = workspace.CurrentCamera or camera

		local distanceAlpha = 1 - math.clamp(dist / math.max(maxDistance, 1), 0, 1)
		local score = distanceAlpha * 0.72
		local toTargetFlat = flatUnit(point - hrp.Position)

		if camera and toTargetFlat then
			local lookFlat = flatUnit(camera.CFrame.LookVector)
			if lookFlat then
				local lookAlpha = math.clamp((toTargetFlat:Dot(lookFlat) + 1) * 0.5, 0, 1)
				score += lookAlpha * 1.05
			end
		end

		local moveFlat = flatUnit(humanoid.MoveDirection)
		if not moveFlat then
			moveFlat = flatUnit(hrp.AssemblyLinearVelocity)
		end
		if moveFlat and toTargetFlat then
			local moveAlpha = math.clamp((toTargetFlat:Dot(moveFlat) + 1) * 0.5, 0, 1)
			score += moveAlpha * 0.42
		end

		if target == lastReleasedTarget and os.clock() - lastReleasedTargetClock < 0.9 then
			score -= 0.95
		end
		if target == scannedVisualTarget then
			score += 0.42
		elseif target == highlightedTarget then
			score += 0.24
		end

		return score
	end

	local function pickAttachSwingTarget(maxDistance, minLookDot, maxScreenRadius)
		if isHrpInSafezone() then
			return nil
		end
		camera = workspace.CurrentCamera or camera

		local lookedTarget = pickSwingTarget(false, maxDistance, minLookDot or 0.02, maxScreenRadius or 0.98)
		if lookedTarget then
			return lookedTarget
		end

		local best = nil
		local bestScore = -math.huge
		local seen = {}

		local function consider(target)
			if not target or seen[target] then
				return
			end
			seen[target] = true

			local dist, point = targetDistanceAndPoint(target)
			if not dist or dist < 2 or dist > maxDistance then
				return
			end
			if camera then
				local toCameraTarget = point - camera.CFrame.Position
				if toCameraTarget.Magnitude > 0.5 and toCameraTarget.Unit:Dot(camera.CFrame.LookVector) < 0.02 then
					return
				end
			end

			local score = attachCandidateScore(target, dist, point, maxDistance)
			if score > bestScore then
				bestScore = score
				best = target
			end
		end

		consider(scannedVisualTarget)
		consider(highlightedTarget)
		consider(lastReleasedTarget)
		for _, part in ipairs(getCandidateTargets(maxDistance)) do
			consider(part)
		end

		return best
	end

	local function isSpecificSwingTargetReady(
		target,
		requireLineOfSight,
		maxDistanceOverride,
		minLookDotOverride,
		maxScreenRadiusOverride
	)
		camera = workspace.CurrentCamera or camera
		if not camera or not hrp.Parent or isHrpInSafezone() then
			return false
		end

		local dist, attachWorld = targetDistanceAndPoint(target)
		local reach = maxDistanceOverride or getSwingRange()
		if not dist or dist < 2 or dist > reach then
			return false
		end

		local look = camera.CFrame.LookVector
		local minLookDot = minLookDotOverride or C.MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or C.TARGET_SCREEN_RADIUS_LIMIT
		local toCameraTarget = attachWorld - camera.CFrame.Position
		if toCameraTarget.Magnitude < 0.5 or toCameraTarget.Unit:Dot(look) < minLookDot then
			return false
		end

		local viewportPoint, onScreen = camera:WorldToViewportPoint(attachWorld)
		if not onScreen then
			return false
		end

		local vp = camera.ViewportSize
		local dx = (viewportPoint.X - vp.X * 0.5) / math.max(vp.X, 1)
		local dy = (viewportPoint.Y - vp.Y * 0.5) / math.max(vp.Y, 1)
		if math.sqrt(dx * dx + dy * dy) > maxScreenRadius then
			return false
		end

		if requireLineOfSight and not hasLineOfSight(target, attachWorld) then
			return false
		end

		return true
	end

	local function isAirborneForSwing()
		local state = humanoid:GetState()
		if
			state == Enum.HumanoidStateType.Freefall
			or state == Enum.HumanoidStateType.Jumping
			or state == Enum.HumanoidStateType.FallingDown
		then
			return true
		end
		if humanoid.FloorMaterial == Enum.Material.Air and hrp.AssemblyLinearVelocity.Y < 5 then
			return true
		end
		return isAirborne
	end

	local function isGroundedForSwing()
		if isSwinging or isLaunched or isAirborneForSwing() then
			return false
		end
		if humanoid.FloorMaterial == Enum.Material.Air then
			return false
		end

		local state = humanoid:GetState()
		return state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed
			or state == Enum.HumanoidStateType.None
	end

	local function isGroundedForCameraAssist()
		if not C.ENABLE_GROUNDED_CAMERA_ASSIST then
			return false
		end
		return isGroundedForSwing()
	end

	local function closestGroundCameraTarget()
		if not isGroundedForCameraAssist() then
			return nil, nil
		end

		camera = workspace.CurrentCamera or camera
		if not camera or not targetVisualShown or not highlightedTarget or not highlightedTarget.Parent then
			return nil, nil
		end

		local point = highlightedPoint or closestAttachWorldOnPart(highlightedTarget)
		if (point - hrp.Position).Magnitude > C.CAMERA_ASSIST_RANGE then
			return nil, nil
		end

		local toPoint = point - camera.CFrame.Position
		if toPoint.Magnitude < 0.5 then
			return nil, nil
		end
		if camera.CFrame.LookVector:Dot(toPoint.Unit) < C.CAMERA_ASSIST_MIN_LOOK_DOT then
			return nil, nil
		end
		if not hasLineOfSight(highlightedTarget, point) then
			return nil, nil
		end

		return highlightedTarget, point
	end

	local function holdIsActive()
		return spaceHeld
			or gamepadHeld
			or mobileJumpHeld
			or safeIsKeyDown(Enum.KeyCode.Space)
			or safeIsKeyDown(Enum.KeyCode.ButtonA)
			or safeIsKeyDown(Enum.KeyCode.ButtonR2)
	end

	local function readyPromptText()
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
			return "[HOLD JUMP] TO SWING"
		end
		if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
			return "[HOLD R2] TO SWING"
		end
		return "[HOLD SPACE] TO SWING"
	end

	local function noteJumpPressed()
		local now = os.clock()
		local freshGroundJump = now - lastGroundJumpClock <= 0.2 and now - airborneStartedClock <= 0.2
		if isAirborneForSwing() and not freshGroundJump then
			return true
		else
			lastGroundJumpClock = now
			return false
		end
	end

	local function forwardInputAmount()
		camera = workspace.CurrentCamera or camera
		local moveDir = humanoid.MoveDirection
		local controlMoveUnit, controlMoveAmount = getControlWorldMove(camera)
		if moveDir.Magnitude < 0.05 and controlMoveUnit then
			moveDir = controlMoveUnit * math.max(controlMoveAmount, 0.5)
		end
		if moveDir.Magnitude < 0.05 then
			if safeIsKeyDown(Enum.KeyCode.W) then
				return 1
			end
			return 0
		end

		local facing = nil
		if camera then
			facing = flatUnit(camera.CFrame.LookVector)
		end
		facing = facing or flatUnit(hrp.CFrame.LookVector)
		if not facing then
			return math.clamp(moveDir.Magnitude, 0, 1)
		end

		local md = Vector3.new(moveDir.X, 0, moveDir.Z)
		if md.Magnitude < 0.05 then
			return 0
		end

		local amount = md.Unit:Dot(facing)
		if safeIsKeyDown(Enum.KeyCode.W) then
			amount = math.max(amount, 1)
		end
		return math.clamp(amount, 0, 1)
	end

	local previewTransparency

	local function cleanupWorkspaceHelpersByName(name, keep)
		for _, obj in ipairs(workspace:GetChildren()) do
			if obj.Name == name and obj ~= keep then
				obj:Destroy()
			end
		end
	end

	local function makeVisualAnchor(name)
		local existing = workspace:FindFirstChild(name)
		local part = existing and existing:IsA("BasePart") and existing or nil
		if existing and not part then
			existing:Destroy()
		end
		if not part then
			part = Instance.new("Part")
			part.Name = name
		end
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Parent = workspace
		task.defer(cleanupWorkspaceHelpersByName, name, part)
		return part
	end

	local function ensurePreviewObjects()
		if not previewAnchorPart or not previewAnchorPart.Parent then
			previewAnchorPart = makeVisualAnchor("SwingPreviewAnchor")
		end
		if not previewFrom or not previewFrom.Parent then
			previewFrom = Instance.new("Attachment")
			previewFrom.Name = "SwingPreviewFrom"
			previewFrom.Position = Vector3.new(0, 0.8, 0)
			previewFrom.Parent = hrp
		end
		if not previewTo or not previewTo.Parent then
			previewTo = Instance.new("Attachment")
			previewTo.Name = "SwingPreviewTo"
			previewTo.Parent = previewAnchorPart
		end
		if not previewBeam or not previewBeam.Parent then
			previewBeam = Instance.new("Beam")
			previewBeam.Name = "SwingPreviewBeam"
			previewBeam.Attachment0 = previewFrom
			previewBeam.Attachment1 = previewTo
			previewBeam.Width0 = 0.08
			previewBeam.Width1 = 0.06
			previewBeam.LightEmission = 0.35
			previewBeam.FaceCamera = true
			previewBeam.Segments = 1
			previewBeam.Color = ColorSequence.new(C.PREVIEW_COLOR)
			previewBeam.Transparency = previewTransparency(previewFade)
			previewBeam.Enabled = true
			previewBeam.Parent = character
			lastPreviewFadeBucket = -1
			lastPreviewColor = nil
		end
	end

	local function hidePreview()
		previewFadeGoal = 0
		previewTarget = nil
	end

	local function destroyPreview(force)
		if not force then
			hidePreview()
			return
		end
		if previewBeam then
			previewBeam:Destroy()
			previewBeam = nil
		end
		if previewFrom then
			previewFrom:Destroy()
			previewFrom = nil
		end
		if previewTo then
			previewTo:Destroy()
			previewTo = nil
		end
		if previewAnchorPart then
			previewAnchorPart:Destroy()
			previewAnchorPart = nil
		end
		previewTarget = nil
		lastPreviewFadeBucket = -1
		lastPreviewColor = nil
	end

	previewTransparency = function(alpha)
		alpha = math.clamp(alpha, 0, 1)
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1 - alpha * 0.82),
			NumberSequenceKeypoint.new(0.5, 1 - alpha * 0.35),
			NumberSequenceKeypoint.new(1, 1 - alpha * 0.82),
		})
	end

	local function applyPreviewVisual()
		if not previewBeam then
			return
		end

		local beamColor = targetReadyGoal > 0.5 and targetVisualColor:Lerp(C.PREVIEW_COLOR, 0.45) or C.NOT_READY_COLOR
		if not previewBeam.Enabled then
			previewBeam.Enabled = true
		end

		local fadeBucket = math.clamp(math.floor(previewFade * 30 + 0.5), 0, 30)
		if fadeBucket ~= lastPreviewFadeBucket then
			previewBeam.Transparency = previewTransparency(fadeBucket / 30)
			lastPreviewFadeBucket = fadeBucket
		end

		local colorChanged = not lastPreviewColor
			or math.abs(lastPreviewColor.R - beamColor.R) > 0.02
			or math.abs(lastPreviewColor.G - beamColor.G) > 0.02
			or math.abs(lastPreviewColor.B - beamColor.B) > 0.02
		if colorChanged then
			previewBeam.Color = ColorSequence.new(beamColor)
			lastPreviewColor = beamColor
		end
	end

	local function updatePreview(target)
		if isSwinging or not target or not target.Parent then
			hidePreview()
			return
		end

		local attachWorld = closestAttachWorldOnPart(target)
		ensurePreviewObjects()
		if previewTarget ~= target then
			previewTarget = target
		end

		previewAnchorPart.CFrame = CFrame.new(attachWorld)
		previewTo.Position = Vector3.new(0, 0, 0)
		applyPreviewVisual()
	end

	local function ensureTargetHighlight()
		if not C.ENABLE_TARGET_HIGHLIGHT then
			return nil
		end
		if targetHighlight and targetHighlight.Parent and targetHighlight:IsA("Highlight") then
			return targetHighlight
		end

		task.defer(cleanupWorkspaceHelpersByName, "SwingTargetHighlightProxy", nil)

		local existing = workspace:FindFirstChild("SwingTargetHighlight")
		if existing and not existing:IsA("Highlight") then
			existing:Destroy()
			existing = nil
		end

		targetHighlight = existing or Instance.new("Highlight")
		targetHighlight.Name = "SwingTargetHighlight"
		targetHighlight.FillColor = Color3.fromRGB(38, 138, 58)
		targetHighlight.OutlineColor = C.READY_COLOR
		targetHighlight.FillTransparency = C.TARGET_HIGHLIGHT_FILL_TRANSPARENCY
		targetHighlight.OutlineTransparency = 0
		targetHighlight.Enabled = false
		pcall(function()
			targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
		end)
		targetHighlight.Parent = workspace
		task.defer(cleanupWorkspaceHelpersByName, "SwingTargetHighlight", targetHighlight)
		targetHighlightAdornee = nil
		lastHighlightColor = nil
		lastHighlightFillTransparency = nil
		targetHighlightProxyPart = nil
		return targetHighlight
	end

	local function resolveTargetHighlightAdornee(target)
		if not target or not target.Parent or not target:IsDescendantOf(workspace) then
			return nil
		end
		if target:IsDescendantOf(character) then
			return nil
		end

		local vine = target.Parent
		if not vine or vine == workspace or vine:IsDescendantOf(character) then
			return nil
		end
		return vine
	end

	local function clearTargetHighlight()
		if not targetHighlight then
			return
		end
		targetHighlight.Enabled = false
	end

	local function updateTargetHighlight(target)
		local highlight = ensureTargetHighlight()
		if not highlight then
			return
		end

		if not target or isSwinging then
			clearTargetHighlight()
			return
		end

		if
			targetHighlightAdornee
			and targetHighlightAdornee.Parent
			and lastVisualTarget == target
			and highlight.Enabled
		then
			return
		end

		local adornee = resolveTargetHighlightAdornee(target)
		if not adornee then
			clearTargetHighlight()
			return
		end

		if targetHighlightAdornee ~= adornee then
			highlight.Adornee = adornee
			targetHighlightAdornee = adornee
		end
		if not highlight.Enabled then
			highlight.Enabled = true
		end
	end

	local function setTargetHighlightColor(canSwingNow)
		if not targetHighlight or not targetHighlight.Enabled then
			return
		end
		local color = canSwingNow and C.READY_COLOR or C.NOT_READY_COLOR
		local colorChanged = not lastHighlightColor
			or math.abs(lastHighlightColor.R - color.R) > 0.015
			or math.abs(lastHighlightColor.G - color.G) > 0.015
			or math.abs(lastHighlightColor.B - color.B) > 0.015
		if colorChanged then
			targetHighlight.FillColor = canSwingNow and Color3.fromRGB(38, 138, 58) or Color3.fromRGB(138, 38, 38)
			targetHighlight.OutlineColor = color
			lastHighlightColor = color
		end
		local fillTransparency = C.TARGET_HIGHLIGHT_FILL_TRANSPARENCY
		if not lastHighlightFillTransparency or math.abs(lastHighlightFillTransparency - fillTransparency) > 0.015 then
			targetHighlight.FillTransparency = fillTransparency
			targetHighlight.OutlineTransparency = 0
			lastHighlightFillTransparency = fillTransparency
		end
	end

	local function hideMarkerVisualNow()
		if markerAnchorPart then
			markerAnchorPart.CFrame = CFrame.new(C.TARGET_VISUAL_HIDDEN_POSITION)
		end
		if markerGui and not markerGui.Enabled then
			markerGui.Enabled = true
		end
		if markerLabel then
			markerLabel.TextTransparency = 1
			markerLabel.TextStrokeTransparency = 1
		end
		if markerStroke then
			markerStroke.Transparency = 1
		end
		if markerDot then
			markerDot.BackgroundTransparency = 1
		end
	end

	local function ensureVisuals()
		ensureTargetHighlight()

		if not markerAnchorPart or not markerAnchorPart.Parent then
			markerAnchorPart = makeVisualAnchor("SwingMarkerAnchor")
			markerAnchorPart.CFrame = CFrame.new(C.TARGET_VISUAL_HIDDEN_POSITION)
		end

		if not markerGui then
			local playerGui = player:WaitForChild("PlayerGui")
			markerGui = Instance.new("BillboardGui")
			markerGui.Name = "SwingTargetMarker"
			markerGui.Size = UDim2.fromOffset(128, 82)
			markerGui.AlwaysOnTop = true
			markerGui.LightInfluence = 0
			markerGui.MaxDistance = 320
			markerGui.Enabled = true
			markerGui.Adornee = markerAnchorPart
			markerGui.Parent = playerGui

			local ring = Instance.new("Frame")
			ring.Name = "Ring"
			ring.Size = UDim2.fromOffset(42, 42)
			ring.Position = UDim2.new(0.5, -21, 0, 0)
			ring.BackgroundTransparency = 1
			ring.BorderSizePixel = 0
			ring.Parent = markerGui
			markerRing = ring

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = ring

			local stroke = Instance.new("UIStroke")
			stroke.Color = C.READY_COLOR
			stroke.Thickness = 2
			stroke.Transparency = 1
			stroke.Parent = ring
			markerStroke = stroke

			local dot = Instance.new("Frame")
			dot.Name = "Dot"
			dot.Size = UDim2.fromOffset(9, 9)
			dot.Position = UDim2.new(0.5, -4.5, 0.5, -4.5)
			dot.BackgroundColor3 = C.READY_COLOR
			dot.BackgroundTransparency = 1
			dot.BorderSizePixel = 0
			dot.Parent = ring
			markerDot = dot

			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot

			markerLabel = Instance.new("TextLabel")
			markerLabel.Name = "Label"
			markerLabel.Size = UDim2.new(1, 0, 0, 24)
			markerLabel.Position = UDim2.new(0, 0, 0, 48)
			markerLabel.BackgroundTransparency = 1
			markerLabel.Font = Enum.Font.GothamBold
			markerLabel.TextColor3 = C.READY_COLOR
			markerLabel.TextTransparency = 1
			markerLabel.TextStrokeTransparency = 1
			markerLabel.TextSize = 12
			markerLabel.Text = "[HOLD SPACE] TO SWING"
			markerLabel.Parent = markerGui
		end
	end

	local function updateTargetVisual(target, canSwingNow, inactiveText)
		ensureVisuals()

		if target and not isSwinging then
			local attachWorld = closestAttachWorldOnPart(target)
			local markerOffset = Vector3.new(0, target.Size.Y * 0.5 + 0.9, 0)
			targetReadyGoal = canSwingNow and 1 or 0
			previewFadeGoal = 1
			highlightedTarget = target
			highlightedPoint = attachWorld
			targetVisualShown = true

			updateTargetHighlight(target)
			setTargetHighlightColor(canSwingNow)
			markerAnchorPart.CFrame = CFrame.new(attachWorld + markerOffset)
			if markerGui.Adornee ~= markerAnchorPart then
				markerGui.Adornee = markerAnchorPart
			end
			if markerGui.StudsOffset ~= Vector3.new(0, 0, 0) then
				markerGui.StudsOffset = Vector3.new(0, 0, 0)
			end
			if not markerGui.Enabled then
				markerGui.Enabled = true
			end

			if canSwingNow then
				local text = readyPromptText()
				if lastMarkerText ~= text then
					markerLabel.Text = text
					lastMarkerText = text
				end
				updatePreview(target)
			else
				if lastMarkerText ~= "SWING BLOCKED" then
					markerLabel.Text = "SWING BLOCKED"
					lastMarkerText = "SWING BLOCKED"
				end
				updatePreview(target)
			end
			lastVisualTarget = target
			lastVisualCanSwing = canSwingNow

			return attachWorld
		end

		targetReadyGoal = 0
		previewFadeGoal = 0
		targetVisualColor = C.NOT_READY_COLOR
		if not targetVisualShown and not highlightedTarget then
			clearTargetHighlight()
			hidePreview()
			return nil
		end
		clearTargetHighlight()
		highlightedTarget = nil
		highlightedPoint = nil
		targetVisualShown = false
		hideMarkerVisualNow()
		lastVisualTarget = nil
		lastVisualCanSwing = nil
		hidePreview()
		return nil
	end

	local function hideSwingTargetUi()
		lastTargetScanMode = "none"
		scannedVisualTarget = nil
		scannedVisualCanSwing = false
		if targetVisualShown or highlightedTarget or previewFadeGoal > 0 then
			updateTargetVisual(nil, false)
		else
			clearTargetHighlight()
			hideMarkerVisualNow()
			hidePreview()
		end
	end

	local function stepTargetVisual(dt)
		targetVisualStepAccum += dt
		if targetVisualStepAccum < C.TARGET_VISUAL_STEP_INTERVAL then
			return
		end
		dt = targetVisualStepAccum
		targetVisualStepAccum = 0

		local colorAlpha = math.clamp(dt * C.TARGET_VISUAL_SMOOTH_SPEED, 0, 1)
		local fadeAlpha = math.clamp(dt * C.PREVIEW_FADE_SPEED, 0, 1)

		targetReadyVisual += (targetReadyGoal - targetReadyVisual) * colorAlpha
		previewFade += (previewFadeGoal - previewFade) * fadeAlpha
		if math.abs(previewFade - previewFadeGoal) < 0.01 then
			previewFade = previewFadeGoal
		end

		targetVisualColor = C.NOT_READY_COLOR:Lerp(C.READY_COLOR, math.clamp(targetReadyVisual, 0, 1))

		if targetVisualShown and markerGui and markerLabel then
			local pulse = math.sin(os.clock() * 7) * 0.5 + 0.5
			local readyBob = math.sin(os.clock() * C.READY_TEXT_BOB_SPEED)
				* C.READY_TEXT_BOB_PIXELS
				* math.clamp(targetReadyVisual, 0, 1)
			markerLabel.TextColor3 = targetVisualColor
			markerLabel.TextTransparency = 0
			markerLabel.TextStrokeTransparency = 0.35
			markerLabel.Position = UDim2.new(0, 0, 0, 48 - readyBob)

			if markerStroke then
				markerStroke.Color = targetVisualColor
				markerStroke.Transparency = 0
			end
			if markerDot then
				markerDot.BackgroundColor3 = targetVisualColor
				markerDot.BackgroundTransparency = 0.05 + pulse * 0.38
			end
		end

		if previewBeam then
			applyPreviewVisual()
		end
	end

	task.defer(function()
		task.wait(0.05)
		if not hrp.Parent then
			return
		end
		ensureVisuals()
		cleanupWorkspaceHelpersByName("SwingTargetHighlightProxy", nil)
		ensurePreviewObjects()
		hidePreview()
		hideMarkerVisualNow()
		applyPreviewVisual()
	end)

	local function destroyChargeGui()
		if chargeGui then
			chargeGui:Destroy()
			chargeGui = nil
			chargeDot = nil
		end
		swingCharge = 0
	end

	local function ensureChargeGui(target)
		if chargeGui or not target then
			return
		end

		local playerGui = player:WaitForChild("PlayerGui")
		chargeGui = Instance.new("BillboardGui")
		chargeGui.Name = "SwingHoldCharge"
		chargeGui.Adornee = target
		chargeGui.Size = UDim2.fromOffset(96, 70)
		chargeGui.StudsOffset = Vector3.new(0, target.Size.Y * 0.5 + 0.9, 0)
		chargeGui.AlwaysOnTop = true
		chargeGui.LightInfluence = 0
		chargeGui.Parent = playerGui

		local ring = Instance.new("Frame")
		ring.Size = UDim2.fromOffset(46, 46)
		ring.Position = UDim2.new(0.5, -23, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Parent = chargeGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring

		local stroke = Instance.new("UIStroke")
		stroke.Color = C.READY_COLOR
		stroke.Thickness = 2.4
		stroke.Transparency = 0.05
		stroke.Parent = ring

		chargeDot = Instance.new("Frame")
		chargeDot.Size = UDim2.fromOffset(8, 8)
		chargeDot.Position = UDim2.new(0.5, -4, 0.5, -4)
		chargeDot.BackgroundColor3 = C.READY_COLOR
		chargeDot.BorderSizePixel = 0
		chargeDot.Parent = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = chargeDot
	end

	local function layoutCharge()
		if not chargeDot then
			return
		end
		local px = 8 + 34 * math.clamp(swingCharge, 0, 1)
		chargeDot.Size = UDim2.fromOffset(px, px)
		chargeDot.Position = UDim2.new(0.5, -px * 0.5, 0.5, -px * 0.5)
	end

	local function spawnSwingBeam(attachWorld)
		local side = getSwingSide(attachWorld)
		local hand = handPartForSide(side)

		handAttachment = Instance.new("Attachment")
		handAttachment.Name = "SwingHandAttachment"
		handAttachment.Parent = hand
		if hand == hrp then
			handAttachment.Position = Vector3.new(0, 1.1, 0)
		else
			handAttachment.Position = Vector3.new(0, -0.85, 0)
		end

		swingBeam = Instance.new("Beam")
		swingBeam.Name = "SwingRopeBeam"
		swingBeam.Attachment0 = handAttachment
		swingBeam.Attachment1 = anchorAttachment
		swingBeam.Width0 = 0.14
		swingBeam.Width1 = 0.09
		swingBeam.Color = ColorSequence.new(C.ROPE_COLOR_A, C.ROPE_COLOR_B)
		swingBeam.Transparency = NumberSequence.new(0.08)
		swingBeam.LightEmission = 0.35
		swingBeam.FaceCamera = true
		swingBeam.Segments = 18
		swingBeam.Parent = character
	end

	local function destroySwingObjects()
		if swingBeam then
			swingBeam:Destroy()
			swingBeam = nil
		end
		if handAttachment then
			handAttachment:Destroy()
			handAttachment = nil
		end
		if steerForce then
			steerForce:Destroy()
			steerForce = nil
		end
		if swingOrientation then
			swingOrientation:Destroy()
			swingOrientation = nil
		end
		if orientationAttachment then
			orientationAttachment:Destroy()
			orientationAttachment = nil
		end
		if forceAttachment then
			forceAttachment:Destroy()
			forceAttachment = nil
		end
		if ropeConstraint then
			ropeConstraint:Destroy()
			ropeConstraint = nil
		end
		activeRopeMaxLength = nil
		ropeCatchUntil = -1e9
		ropeCatchStartLength = nil
		if zipSpring then
			zipSpring:Destroy()
			zipSpring = nil
		end
		if anchorAttachment then
			anchorAttachment:Destroy()
			anchorAttachment = nil
		end
		if bodyAttachment then
			bodyAttachment:Destroy()
			bodyAttachment = nil
		end
		swingFaceDir = nil
		destroyChargeGui()
	end

	local function pendulumArcDir(radial)
		local gravity = Vector3.new(0, -workspace.Gravity, 0)
		local tangent = gravity - radial * gravity:Dot(radial)
		if tangent.Magnitude < 0.05 then
			return nil
		end
		return tangent.Unit
	end

	local function floorScale(anchorWorld, ropeLength)
		rayParams.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -130, 0), rayParams)
		local floorY = hit and hit.Position.Y or (hrp.Position.Y - 80)
		local minSafeY = math.max(floorY + C.FLOOR_CLEARANCE, anchorWorld.Y - (ropeLength or getRopeMaxLength()) * 0.72)
		local margin = hrp.Position.Y - minSafeY
		if margin <= 0 then
			return 0.18
		end
		if margin < 10 then
			return math.clamp(margin / 10, 0.2, 1)
		end
		return 1
	end

	local function applyAttachBoost(attachWorld)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return
		end

		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		local velocity = hrp.AssemblyLinearVelocity
		local fromAnchor = hrp.Position - attachWorld
		local radial = fromAnchor.Magnitude > 0.25 and fromAnchor.Unit or Vector3.new(0, 1, 0)

		local look = camera.CFrame.LookVector
		local desired = Vector3.new(look.X, -0.16, look.Z)
		local tangent = desired - radial * desired:Dot(radial)
		if tangent.Magnitude < 0.08 then
			local currentTang = velocity - radial * velocity:Dot(radial)
			tangent = currentTang.Magnitude > 0.08 and currentTang
				or Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		end

		if tangent.Magnitude > 0.08 then
			hrp:ApplyImpulse(tangent.Unit * getZipDv() * hrp.AssemblyMass)
		end
	end

	local function startSwing(target)
		if isSwinging or not target or not target.Parent then
			return
		end
		if isHrpInSafezone() then
			return
		end

		local now = os.clock()
		if now - lastAttachClock < C.ATTACH_COOLDOWN then
			return
		end

		local attachWorld = closestAttachWorldOnPart(target)
		local dist = (attachWorld - hrp.Position).Magnitude
		local reach = getSwingRange()
		local baseRopeMax = getRopeMaxLength()
		local ropeRestLength = getRopeRestLength()
		local attachLimit = math.max(reach, C.GROUNDED_READY_RANGE)
		if dist < 2 or dist > attachLimit then
			return
		end
		releaseStyle.cancel()
		local ropeMaxFloor = math.max(C.ROPE_SAFE_MAX_MIN_LENGTH, C.ROPE_MIN_LENGTH + C.ROPE_HANG_PULL_MIN_GAP + 8)
		local ropeStretchFloor = math.min(baseRopeMax, ropeRestLength + C.ROPE_HANG_PULL_MIN_GAP)
		local ropeStretchCeiling = math.min(
			baseRopeMax,
			ropeRestLength
				+ C.ROPE_STRETCH_MAX_EXTRA * math.clamp(0.85 + (getPowerScale() - 1) * 0.82, 0.85, 2.75)
				+ math.max(baseRopeMax - C.ROPE_MAX_LENGTH, 0) * 0.9
		)
		local ropeMax = math.max(ropeStretchFloor, ropeStretchCeiling, ropeMaxFloor)
		activeRopeMaxLength = ropeMax

		isSwinging = true
		isLaunched = false
		landedFromSwing = false
		currentTarget = target
		lastAttachClock = now
		swingTimer = 0
		swingCharge = 0
		forwardSwingCharge = 0
		forwardHoldTime = 0
		swingMomentum = 0
		swingRhythmBoost = 0
		lastPumpInputSign = 0
		lastPumpSwitchClock = now
		swingFaceDir = nil

		anchorAttachment = Instance.new("Attachment")
		anchorAttachment.Name = "SwingAnchorAttachment"
		anchorAttachment.Position = target.CFrame:PointToObjectSpace(attachWorld)
		anchorAttachment.Parent = target

		bodyAttachment = Instance.new("Attachment")
		bodyAttachment.Name = "SwingBodyAttachment"
		bodyAttachment.Parent = hrp

		local elasticRestLength = math.clamp(ropeRestLength, C.ROPE_MIN_LENGTH, ropeMax)
		local normalStartLength =
			math.clamp(math.max(dist * C.ROPE_ATTACH_START_MULT, elasticRestLength), elasticRestLength, ropeMax)
		local elasticCatchStartLength =
			math.clamp(math.max(dist * C.ROPE_CATCH_START_MULT, normalStartLength), elasticRestLength, ropeMax)
		local startLength = elasticCatchStartLength
		ropeCatchStartLength = startLength
		ropeCatchUntil = os.clock() + C.ROPE_CATCH_ELASTIC_TIME
		ropeConstraint = Instance.new("RopeConstraint")
		ropeConstraint.Name = "SwingRopeConstraint"
		ropeConstraint.Attachment0 = anchorAttachment
		ropeConstraint.Attachment1 = bodyAttachment
		ropeConstraint.Length = startLength
		ropeConstraint.Thickness = 0.08
		ropeConstraint.Visible = false
		ropeConstraint.Restitution = 0.05
		ropeConstraint.Parent = hrp

		pcall(function()
			ropeConstraint.WinchEnabled = true
			ropeConstraint.WinchResponsiveness = 46
			ropeConstraint.WinchSpeed = C.ROPE_HANG_PULL_WINCH_SPEED * C.ROPE_CATCH_REEL_MULT
			ropeConstraint.WinchForce = hrp.AssemblyMass * 3000 * C.ROPE_CATCH_FORCE_MULT
			ropeConstraint.WinchTarget = startLength
		end)

		if math.abs(dist - elasticRestLength) > 1.5 then
			zipSpring = Instance.new("SpringConstraint")
			zipSpring.Name = "SwingZipSpring"
			zipSpring.Attachment0 = anchorAttachment
			zipSpring.Attachment1 = bodyAttachment
			-- Start the helper spring at the catch length too. If this starts at rest length,
			-- the player gets yanked/snapped upward the instant a new swing attaches.
			zipSpring.FreeLength = startLength
			zipSpring.Stiffness = C.ZIP_SPRING_STIFFNESS * 0.72
			zipSpring.Damping = C.ZIP_SPRING_DAMPING * 1.12
			zipSpring.MaxForce = hrp.AssemblyMass * C.ZIP_SPRING_MAX_ACCEL * C.ROPE_CATCH_FORCE_MULT
			zipSpring.Parent = hrp
		end

		forceAttachment = Instance.new("Attachment")
		forceAttachment.Name = "SwingForceAttachment"
		forceAttachment.Parent = hrp

		steerForce = Instance.new("VectorForce")
		steerForce.Name = "SwingSteerForce"
		steerForce.Attachment0 = forceAttachment
		steerForce.RelativeTo = Enum.ActuatorRelativeTo.World
		steerForce.ApplyAtCenterOfMass = true
		steerForce.Force = Vector3.new(0, 0, 0)
		steerForce.Parent = hrp

		orientationAttachment = Instance.new("Attachment")
		orientationAttachment.Name = "SwingOrientationAttachment"
		orientationAttachment.Parent = hrp

		swingOrientation = Instance.new("AlignOrientation")
		swingOrientation.Name = "SwingFaceDirection"
		swingOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
		swingOrientation.Attachment0 = orientationAttachment
		swingOrientation.RigidityEnabled = false
		swingOrientation.Responsiveness = C.AVATAR_TURN_RESPONSIVENESS
		swingOrientation.MaxTorque = hrp.AssemblyMass * 18000
		swingOrientation.Enabled = true
		swingOrientation.Parent = hrp

		humanoid.PlatformStand = true
		humanoid.AutoRotate = false
		humanoid.Jump = false
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		applyAttachBoost(attachWorld)
		playHangAnim(attachWorld)
		spawnSwingBeam(attachWorld)
		ensureChargeGui(target)
		updateTargetVisual(nil, false)
		playOptionalSound("Catch")
		playOptionalSound("Wind")
	end

	local function stopSwing(doLaunch)
		if not isSwinging then
			return
		end

		local heldTime = swingTimer
		local charge = swingCharge
		local forwardCharge = forwardSwingCharge
		local forwardHeld = forwardHoldTime
		local releaseMomentum = swingMomentum
		local snapVelocity = hrp.AssemblyLinearVelocity
		local snapPosition = hrp.Position
		local snapAnchorWorld = anchorAttachment and anchorAttachment.Parent and anchorAttachment.WorldPosition or nil
		lastReleasedTarget = currentTarget
		lastReleasedTargetClock = os.clock()

		isSwinging = false
		currentTarget = nil
		scannedVisualTarget = nil
		scannedVisualCanSwing = false
		lastTargetScanClock = -1e9
		stopHangAnim(doLaunch and 0 or 0.08)
		swingPose.clear()
		destroySwingObjects()
		stopOptionalSound("Wind")

		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		if doLaunch then
			isLaunched = true
			landedFromSwing = true
			lastLaunchClock = os.clock()
			playFallingAnim(0.03)
			playOptionalSound("Launch")
			task.defer(function()
				if isSwinging or not hrp.Parent then
					return
				end
				camera = workspace.CurrentCamera or camera
				releaseStyle.apply(
					camera,
					snapVelocity,
					snapPosition,
					snapAnchorWorld,
					heldTime,
					charge,
					forwardCharge,
					forwardHeld,
					releaseMomentum
				)
			end)
		else
			releaseStyle.cancel()
		end
	end

	local function spawnLandingBlocks(speed)
		local alpha = math.clamp((speed - 8) / 70, 0.58, 1)
		if alpha <= 0 then
			return
		end

		rayParams.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -10, 0), rayParams)
		local pos = hit and hit.Position or (hrp.Position - Vector3.new(0, 3, 0))
		local color = hit and hit.Instance and hit.Instance.Color or Color3.fromRGB(120, 120, 120)
		local material = hit and hit.Material or Enum.Material.Concrete
		local count = math.floor(10 + alpha * 14)

		local ring = Instance.new("Part")
		ring.Name = "SwingImpactRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CanQuery = false
		ring.CastShadow = false
		ring.Material = Enum.Material.SmoothPlastic
		ring.Color = color:Lerp(Color3.new(1, 1, 1), 0.35)
		ring.Transparency = 0.24
		ring.Size = Vector3.new(0.12, 7 + alpha * 7, 7 + alpha * 7)
		ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace
		TweenService:Create(ring, TweenInfo.new(0.58, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.12, 30 + alpha * 34, 30 + alpha * 34),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring, 0.7)

		local dustRing = Instance.new("Part")
		dustRing.Name = "SwingImpactDustRing"
		dustRing.Shape = Enum.PartType.Cylinder
		dustRing.Anchored = true
		dustRing.CanCollide = false
		dustRing.CanTouch = false
		dustRing.CanQuery = false
		dustRing.CastShadow = false
		dustRing.Material = Enum.Material.SmoothPlastic
		dustRing.Color = color:Lerp(Color3.new(0, 0, 0), 0.18)
		dustRing.Transparency = 0.56
		dustRing.Size = Vector3.new(0.1, 10 + alpha * 8, 10 + alpha * 8)
		dustRing.CFrame = CFrame.new(pos + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
		dustRing.Parent = workspace
		TweenService:Create(dustRing, TweenInfo.new(0.86, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.1, 44 + alpha * 44, 44 + alpha * 44),
			Transparency = 1,
		}):Play()
		Debris:AddItem(dustRing, 0.96)

		local burst = Instance.new("Part")
		burst.Name = "SwingImpactBurst"
		burst.Shape = Enum.PartType.Ball
		burst.Anchored = true
		burst.CanCollide = false
		burst.CanTouch = false
		burst.CanQuery = false
		burst.CastShadow = false
		burst.Material = Enum.Material.SmoothPlastic
		burst.Color = color:Lerp(Color3.new(1, 1, 1), 0.18)
		burst.Transparency = 0.72
		burst.Size = Vector3.new(4 + alpha * 5, 1.2 + alpha * 1.8, 4 + alpha * 5)
		burst.CFrame = CFrame.new(pos + Vector3.new(0, 0.65, 0))
		burst.Parent = workspace
		TweenService:Create(burst, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(15 + alpha * 15, 5 + alpha * 5, 15 + alpha * 15),
			Transparency = 1,
		}):Play()
		Debris:AddItem(burst, 0.52)

		for _ = 1, count do
			local size = math.random(80, 240) / 100
			local part = Instance.new("Part")
			part.Name = "SwingLandingChunk"
			part.Size = Vector3.new(size, size * math.random(70, 130) / 100, size)
			part.Anchored = true
			part.Material = material
			part.Color = color
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.CFrame = CFrame.new(pos + Vector3.new(math.random(-42, 42) / 10, 0.22, math.random(-42, 42) / 10))
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			part.Parent = workspace

			TweenService:Create(part, TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
				CFrame = part.CFrame
					+ Vector3.new(math.random(-52, 52) / 10, math.random(24, 58) / 10, math.random(-52, 52) / 10),
				Size = Vector3.new(0.06, 0.06, 0.06),
			}):Play()
			Debris:AddItem(part, 1.16)
		end

		local chipCount = math.floor(22 + alpha * 26)
		for _ = 1, chipCount do
			local size = math.random(20, 62) / 100
			local chip = Instance.new("Part")
			chip.Name = "SwingLandingChip"
			chip.Size = Vector3.new(size, size, size)
			chip.Anchored = true
			chip.Material = material
			chip.Color = color:Lerp(Color3.new(1, 1, 1), math.random(0, 18) / 100)
			chip.CanCollide = false
			chip.CanTouch = false
			chip.CanQuery = false
			chip.CastShadow = false
			chip.CFrame = CFrame.new(pos + Vector3.new(math.random(-42, 42) / 10, 0.16, math.random(-42, 42) / 10))
			chip.Parent = workspace

			TweenService:Create(chip, TweenInfo.new(0.78, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
				CFrame = chip.CFrame
					+ Vector3.new(math.random(-62, 62) / 10, math.random(14, 34) / 10, math.random(-62, 62) / 10),
				Size = Vector3.new(0.03, 0.03, 0.03),
			}):Play()
			Debris:AddItem(chip, 0.9)
		end
	end

	local function spawnGroundDragDebris(hit, horizontalVelocity)
		if not hit then
			return
		end

		local now = os.clock()
		if now - lastGroundDragDebrisClock < C.SWING_GROUND_DRAG_DEBRIS_INTERVAL then
			return
		end
		lastGroundDragDebrisClock = now

		local speed = horizontalVelocity and horizontalVelocity.Magnitude or 0
		local pos = hit.Position
		local color = Color3.fromRGB(120, 120, 120)
		local material = hit.Material or Enum.Material.Concrete
		if hit.Instance and hit.Instance:IsA("BasePart") then
			color = hit.Instance.Color
			material = hit.Material or hit.Instance.Material
		end
		local travelDir = speed > 0.05 and horizontalVelocity.Unit
			or flatUnit(hrp.CFrame.LookVector)
			or Vector3.new(0, 0, -1)
		local right = Vector3.new(-travelDir.Z, 0, travelDir.X)
		local visualSpeed = math.max(speed, C.SWING_GROUND_DRAG_MIN_SPEED)

		local scrape = Instance.new("Part")
		scrape.Name = "SwingGroundDragScrape"
		scrape.Anchored = true
		scrape.CanCollide = false
		scrape.CanTouch = false
		scrape.CanQuery = false
		scrape.CastShadow = false
		scrape.Material = Enum.Material.SmoothPlastic
		scrape.Color = color:Lerp(Color3.new(1, 1, 1), 0.14)
		scrape.Transparency = 0.48
		scrape.Size = Vector3.new(math.random(45, 75) / 100, 0.035, math.random(130, 220) / 100)
		scrape.CFrame =
			CFrame.lookAt(pos + Vector3.new(0, 0.055, 0) - travelDir * 0.35, pos + Vector3.new(0, 0.055, 0) + travelDir)
		scrape.Parent = workspace
		TweenService:Create(scrape, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
			Size = Vector3.new(scrape.Size.X * 1.8, 0.025, scrape.Size.Z * 1.35),
		}):Play()
		Debris:AddItem(scrape, 0.34)

		local chipCount = speed >= C.SWING_GROUND_DRAG_MIN_SPEED and math.random(2, 3) or 2
		for _ = 1, chipCount do
			local size = math.random(16, 42) / 100
			local chip = Instance.new("Part")
			chip.Name = "SwingGroundDragChip"
			chip.Size = Vector3.new(size, size * math.random(70, 120) / 100, size)
			chip.Anchored = true
			chip.Material = material
			chip.Color = color:Lerp(Color3.new(1, 1, 1), math.random(0, 12) / 100)
			chip.CanCollide = false
			chip.CanTouch = false
			chip.CanQuery = false
			chip.CastShadow = false
			chip.CFrame = CFrame.new(pos + Vector3.new(0, 0.18, 0) + right * math.random(-11, 11) / 10)
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			chip.Parent = workspace

			local scatter = right * math.random(-16, 16) / 10
			local backKick = math.random(8, 16) + visualSpeed * math.random(4, 8) / 100

			TweenService:Create(
				chip,
				TweenInfo.new(C.SWING_GROUND_DRAG_DEBRIS_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{
					Transparency = 1,
					CFrame = chip.CFrame
						- travelDir * backKick * 0.08
						+ scatter
						+ Vector3.new(0, math.random(4, 10) / 10, 0),
					Size = Vector3.new(0.03, 0.03, 0.03),
				}
			):Play()
			Debris:AddItem(chip, C.SWING_GROUND_DRAG_DEBRIS_LIFETIME + 0.08)
		end
	end

	local function updateSwingRopePhysics(
		dt,
		ropeLiftForce,
		velocity,
		speed,
		anchorWorld,
		dist,
		radial,
		ropeMax,
		speedCap,
		mult
	)
		if not ropeConstraint then
			return ropeLiftForce, velocity, speed
		end

		local restLength = math.clamp(getRopeRestLength(), C.ROPE_MIN_LENGTH, ropeMax)
		local flexScale = math.clamp(0.85 + (getPowerScale() - 1) * 0.82, 0.85, 2.75)
		local stretchMinLength = math.min(ropeMax, restLength + C.ROPE_HANG_PULL_MIN_GAP)
		local stretchMaxLength = math.max(
			stretchMinLength,
			math.min(
				ropeMax,
				restLength + C.ROPE_STRETCH_MAX_EXTRA * flexScale + math.max(ropeMax - C.ROPE_MAX_LENGTH, 0) * 0.9
			)
		)
		local moveAmount = humanoid.MoveDirection.Magnitude
		local idleHoldAlpha = 0
		if moveAmount < 0.06 and forwardSwingCharge < 0.08 then
			idleHoldAlpha = 1
		end
		local speedStretch = math.clamp((speed - 18) / math.max(speedCap - 18, 1), 0, 1)
		local stretchAlpha = math.clamp(swingMomentum * 0.58 + speedStretch * 0.24 + forwardSwingCharge * 0.12, 0, 1)
		stretchAlpha = math.clamp(
			stretchAlpha * (1 - idleHoldAlpha * 0.35) + speedStretch * 0.34 + math.clamp(moveAmount, 0, 1) * 0.18,
			0,
			1
		)
		local elasticRestLength = math.clamp(
			restLength + math.max(stretchMaxLength - restLength, 0) * C.ROPE_MOMENTUM_LENGTH_MULT * stretchAlpha,
			restLength,
			stretchMaxLength
		)
		local verticalDrop = math.max(anchorWorld.Y - hrp.Position.Y, 0)
		local pullStartLength = restLength + math.max(stretchMaxLength - restLength, 0) * C.ROPE_HANG_PULL_START_MULT
		local distanceSag = math.clamp((dist - pullStartLength) / math.max(stretchMaxLength - pullStartLength, 1), 0, 1)
		local heightSag = math.clamp((verticalDrop - restLength * 0.72) / math.max(restLength * 0.42, 1), 0, 1)
		local sagAlpha = math.max(distanceSag, heightSag)
		local closeEnoughMin = restLength
		local closeEnoughMax =
			math.max(closeEnoughMin, math.min(stretchMaxLength, restLength + C.ROPE_HANG_PULL_MIN_GAP))
		local baseCloseEnoughLength = math.clamp(ropeMax * C.ROPE_HANG_PULL_TARGET_MULT, closeEnoughMin, closeEnoughMax)

		local catchAlpha = 0
		if ropeCatchUntil > os.clock() then
			catchAlpha = math.clamp((ropeCatchUntil - os.clock()) / C.ROPE_CATCH_ELASTIC_TIME, 0, 1)
			-- Smoothstep so the catch starts soft and eases back into normal rope behavior.
			catchAlpha = catchAlpha * catchAlpha * (3 - 2 * catchAlpha)
		else
			ropeCatchStartLength = nil
		end

		local catchLength =
			math.clamp(ropeCatchStartLength or ropeConstraint.Length, baseCloseEnoughLength, stretchMaxLength)
		local closeEnoughLength = baseCloseEnoughLength + (catchLength - baseCloseEnoughLength) * catchAlpha
		local catchForceMult = 1 - catchAlpha * (1 - C.ROPE_CATCH_FORCE_MULT)
		local reelAlpha =
			math.clamp(C.ROPE_REEL_ALWAYS_ALPHA + sagAlpha * 0.46 + idleHoldAlpha * 0.22 - stretchAlpha * 0.74, 0.16, 1)
		reelAlpha *= 1 - catchAlpha * (1 - C.ROPE_CATCH_REEL_MULT)

		elasticRestLength = elasticRestLength + (closeEnoughLength - elasticRestLength) * reelAlpha

		local stretchExtra = math.clamp(dist - elasticRestLength, 0, math.max(stretchMaxLength - elasticRestLength, 0))
			* C.ROPE_DISTANCE_STRETCH_MULT
			* flexScale
			* (0.25 + stretchAlpha * 0.95)
		local targetLength = math.clamp(elasticRestLength + stretchExtra, closeEnoughLength, stretchMaxLength)
		ropeConstraint.Length += (targetLength - ropeConstraint.Length) * math.clamp(
			dt * (idleHoldAlpha > 0.05 and C.ROPE_LENGTH_RESPONSE * 0.28 or C.ROPE_LENGTH_RESPONSE * 0.62),
			0,
			1
		)

		pcall(function()
			ropeConstraint.WinchTarget = closeEnoughLength
			ropeConstraint.WinchSpeed = (
				22
				+ swingCharge * 4
				+ swingMomentum * 2
				+ (C.ROPE_REEL_ALWAYS_ALPHA + sagAlpha * 0.8 + idleHoldAlpha * 0.18) * C.ROPE_HANG_PULL_WINCH_SPEED
			)
				* math.clamp(1 - stretchAlpha * (1 - idleHoldAlpha) * 0.68, 0.28, 1)
				* catchForceMult
			ropeConstraint.WinchForce = hrp.AssemblyMass
				* (3900 + sagAlpha * 2200 + idleHoldAlpha * 700)
				* math.clamp(1 - stretchAlpha * (1 - idleHoldAlpha) * 0.68, 0.28, 1)
				* catchForceMult
		end)

		if ropeConstraint.Length > stretchMaxLength then
			ropeConstraint.Length = stretchMaxLength
		elseif ropeConstraint.Length < closeEnoughLength then
			ropeConstraint.Length = closeEnoughLength
		end

		local pullGap = dist - closeEnoughLength
		local idleHangDrop = closeEnoughLength * 0.82
		local lowHang = verticalDrop > idleHangDrop + 1.25
		if pullGap > -C.ROPE_HANG_PULL_MIN_GAP * 0.35 or lowHang or idleHoldAlpha > 0.05 then
			local stallAlpha = math.clamp(1 - stretchAlpha * 0.42 + idleHoldAlpha * 0.16, 0.5, 1.12)
			local pullDir = -radial + Vector3.new(0, 0.58 + sagAlpha * 0.62 + idleHoldAlpha * 0.42, 0)
			local idlePullScale = 1
			if idleHoldAlpha > 0.05 then
				local idleTargetOffset = anchorWorld - Vector3.new(0, idleHangDrop, 0) - hrp.Position
				if idleTargetOffset.Magnitude > 0.05 then
					pullDir = idleTargetOffset.Unit
					idlePullScale =
						math.clamp(idleTargetOffset.Magnitude / math.max(closeEnoughLength * 0.7, 1), 0.18, 0.62)
				end
			end
			if pullDir.Magnitude > 0.05 then
				local upSpeedGate = math.clamp(
					(C.ROPE_HANG_PULL_MAX_UP_SPEED - math.max(velocity.Y, 0)) / C.ROPE_HANG_PULL_MAX_UP_SPEED,
					0,
					1
				)
				ropeLiftForce += pullDir.Unit * C.ROPE_HANG_PULL_FORCE * (0.62 + sagAlpha * 1.05 + idleHoldAlpha * 0.38) * stallAlpha * idlePullScale * math.clamp(
					1 - stretchAlpha * (1 - idleHoldAlpha) * 0.52,
					0.36,
					1
				) * catchForceMult * upSpeedGate * mult * hrp.AssemblyMass
			end

			local outwardSpeed = velocity:Dot(radial)
			local tangentialVelocity = velocity - radial * outwardSpeed
			local dampAlpha = math.clamp(
				dt * (3.4 + sagAlpha * 4.6 + idleHoldAlpha * 3.2) * stallAlpha * (1 - catchAlpha * 0.28),
				0,
				idleHoldAlpha > 0.65 and 0.32 or 0.46
			)
			local nextVelocity = velocity
			if outwardSpeed > 0 then
				nextVelocity -= radial * outwardSpeed * dampAlpha
			end
			if idleHoldAlpha > 0.05 then
				nextVelocity -= tangentialVelocity * math.clamp(dt * (2.8 + idleHoldAlpha * 4.5), 0, 0.28) * idleHoldAlpha
			end
			if swingMomentum < 0.22 and forwardSwingCharge < 0.12 then
				nextVelocity -= tangentialVelocity * dampAlpha * 0.22
			end
			if lowHang then
				local minUpSpeed = (5 + sagAlpha * 10 + idleHoldAlpha * 4) * mult
				if nextVelocity.Y < minUpSpeed then
					local liftBlend = math.clamp(dt * (2 + sagAlpha * 3 + idleHoldAlpha * 2.5), 0, 0.22)
					nextVelocity = Vector3.new(
						nextVelocity.X,
						nextVelocity.Y + (minUpSpeed - nextVelocity.Y) * liftBlend,
						nextVelocity.Z
					)
				end
			end
			if (nextVelocity - velocity).Magnitude > 0.01 then
				velocity = nextVelocity
				speed = velocity.Magnitude
				hrp.AssemblyLinearVelocity = velocity
			end
		end

		return ropeLiftForce, velocity, speed
	end

	local function tryAttach()
		if isSwinging or not hrp.Parent then
			return
		end

		local now = os.clock()
		if now - lastTryClock < C.ATTACH_RETRY_TIME then
			return
		end

		local maxDistance = getSwingRange()
		local lookDot = C.AIRBORNE_TARGET_LOOK_DOT
		local screenLimit = C.TARGET_SCREEN_RADIUS_LIMIT
		local groundedAttempt = false
		if isAirborneForSwing() then
			maxDistance = getSwingRange()
		elseif isGroundedForSwing() then
			groundedAttempt = true
			maxDistance = math.max(C.GROUNDED_READY_RANGE, getSwingRange())
			lookDot = C.GROUNDED_TARGET_LOOK_DOT
			screenLimit = C.GROUNDED_TARGET_SCREEN_RADIUS_LIMIT
		else
			return
		end

		local target = pickAttachSwingTarget(maxDistance, lookDot, screenLimit)
		if target then
			lastTryClock = now
			startSwing(target)
		elseif not (groundedAttempt and now - lastGroundJumpClock < 0.25) then
			lastTryClock = now
		end
	end

	local function disconnectMobileJumpButton()
		for _, conn in ipairs(mobileConns) do
			conn:Disconnect()
		end
		table.clear(mobileConns)
		mobileJumpBound = false
		mobileJumpHeld = false
	end

	local function destroyMobileFallbackButton()
		if fallbackMobileGui then
			fallbackMobileGui:Destroy()
			fallbackMobileGui = nil
		end
	end

	local function createMobileFallbackButton()
		if fallbackMobileGui or mobileJumpBound or not UserInputService.TouchEnabled then
			return
		end

		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end

		fallbackMobileGui = Instance.new("ScreenGui")
		fallbackMobileGui.Name = "SwingMobileFallback"
		fallbackMobileGui.ResetOnSpawn = false
		fallbackMobileGui.IgnoreGuiInset = true
		fallbackMobileGui.Parent = playerGui

		local button = Instance.new("TextButton")
		button.Name = "SwingHoldButton"
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.new(1, -104, 1, -172)
		button.Size = UDim2.fromOffset(82, 82)
		button.BackgroundColor3 = Color3.fromRGB(28, 31, 36)
		button.BackgroundTransparency = 0.18
		button.BorderSizePixel = 0
		button.Text = "SWING"
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextStrokeTransparency = 0.45
		button.TextSize = 13
		button.Font = Enum.Font.GothamBold
		button.Parent = fallbackMobileGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = C.READY_COLOR
		stroke.Thickness = 2
		stroke.Transparency = 0.15
		stroke.Parent = button

		addMobileConn(button.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.Touch
				and input.UserInputType ~= Enum.UserInputType.MouseButton1
			then
				return
			end
			noteJumpPressed()
			mobileJumpHeld = true
			button.BackgroundTransparency = 0.04
			tryAttach()
		end))

		addMobileConn(button.InputEnded:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.Touch
				and input.UserInputType ~= Enum.UserInputType.MouseButton1
			then
				return
			end
			mobileJumpHeld = false
			button.BackgroundTransparency = 0.18
			if isSwinging and os.clock() - lastAttachClock > C.MIN_SWING_LOCK_TIME then
				stopSwing(true)
			end
		end))
	end

	local function bindMobileJumpButton()
		if mobileJumpBound then
			return true
		end
		if not UserInputService.TouchEnabled then
			return false
		end

		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return false
		end

		local touchGui = playerGui:FindFirstChild("TouchGui")
		local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
		local button = frame and frame:FindFirstChild("JumpButton", true)
		if not (button and button:IsA("GuiButton")) then
			return false
		end

		mobileJumpBound = true
		destroyMobileFallbackButton()
		local buttonDown = false

		addMobileConn(button.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if buttonDown then
				return
			end
			buttonDown = true
			noteJumpPressed()
			mobileJumpHeld = true
			tryAttach()
		end))

		addMobileConn(button.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			buttonDown = false
			mobileJumpHeld = false
			if isSwinging and os.clock() - lastAttachClock > C.MIN_SWING_LOCK_TIME then
				stopSwing(true)
			end
		end))

		addMobileConn(button.AncestryChanged:Connect(function(_, parent)
			if not parent then
				disconnectMobileJumpButton()
				task.defer(function()
					if not bindMobileJumpButton() then
						createMobileFallbackButton()
					end
				end)
			end
		end))

		return true
	end

	if UserInputService.TouchEnabled then
		task.defer(function()
			task.wait(0.35)
			if not bindMobileJumpButton() then
				task.wait(1)
				if not bindMobileJumpButton() then
					createMobileFallbackButton()
				end
			end
		end)
		local playerGui = player:WaitForChild("PlayerGui")
		addConn(playerGui.DescendantAdded:Connect(function(desc)
			if desc.Name == "JumpButton" and desc:IsA("GuiButton") then
				task.defer(bindMobileJumpButton)
			end
		end))
	end

	addConn(UserInputService.InputBegan:Connect(function(input, processed)
		if UserInputService:GetFocusedTextBox() then
			return
		end

		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Space then
			noteJumpPressed()
			spaceHeld = true
			if not processed then
				tryAttach()
			end
		elseif
			input.UserInputType == Enum.UserInputType.Gamepad1
			and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA)
		then
			noteJumpPressed()
			gamepadHeld = true
			if not processed then
				tryAttach()
			end
		end
	end))

	addConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Space then
			spaceHeld = false
			if isSwinging and os.clock() - lastAttachClock > C.MIN_SWING_LOCK_TIME then
				stopSwing(true)
			end
		elseif
			input.UserInputType == Enum.UserInputType.Gamepad1
			and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA)
		then
			gamepadHeld = false
			if isSwinging and os.clock() - lastAttachClock > C.MIN_SWING_LOCK_TIME then
				stopSwing(true)
			end
		end
	end))

	addConn(UserInputService.JumpRequest:Connect(function()
		if UserInputService:GetFocusedTextBox() then
			return
		end
		noteJumpPressed()
		if not isSwinging then
			tryAttach()
		end
	end))

	if C.PRE_SIMULATION_SIGNAL then
		addConn(C.PRE_SIMULATION_SIGNAL:Connect(function(dt)
			swingPose.step(
				dt,
				hrp.AssemblyLinearVelocity,
				poseInputs.radial,
				poseInputs.moveFlatUnit,
				poseInputs.forwardInput,
				poseInputs.extT,
				poseInputs.momentum,
				currentHangSide,
				isSwinging,
				isLaunched,
				landedFromSwing
			)
		end))
	else
		addConn(RunService.Stepped:Connect(function(_, dt)
			swingPose.step(
				dt,
				hrp.AssemblyLinearVelocity,
				poseInputs.radial,
				poseInputs.moveFlatUnit,
				poseInputs.forwardInput,
				poseInputs.extT,
				poseInputs.momentum,
				currentHangSide,
				isSwinging,
				isLaunched,
				landedFromSwing
			)
		end))
	end

	addConn(humanoid.StateChanged:Connect(function(_, newState)
		if
			newState == Enum.HumanoidStateType.Freefall
			or newState == Enum.HumanoidStateType.Jumping
			or newState == Enum.HumanoidStateType.FallingDown
		then
			isAirborne = true
			airborneStartedClock = os.clock()
			if not isSwinging and (isLaunched or landedFromSwing) then
				playFallingAnim()
			end
		elseif newState == Enum.HumanoidStateType.Landed then
			isAirborne = false
			if isSwinging then
				return
			end
			local swingLanding = landedFromSwing or isLaunched
			releaseStyle.cancel()
			swingPose.clear()
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
			if not isSwinging and swingLanding then
				playLandedAnim()
			end
			local impactSpeed = landingSpeed
			if landedFromSwing then
				spawnLandingBlocks(impactSpeed)
				playOptionalSound("GroundSmash")
				local impactAlpha = math.clamp((impactSpeed - 8) / 70, 0.58, 1)
				lastLandingClock = os.clock()
				landingShakeStrength = math.clamp(0.42 + impactAlpha * 0.86, 0, 1.22)
				landingShakeSeed = math.random() * 1000
			end
			landedFromSwing = false
			isLaunched = false
			landingSpeed = 0
			hideSwingTargetUi()
		elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics then
			isAirborne = false
			if not isSwinging then
				releaseStyle.cancel()
				swingPose.clear()
				humanoid.PlatformStand = false
				humanoid.AutoRotate = true
			end
			stopFallingAnim()
			hideSwingTargetUi()
		end
	end))

	addConn(humanoid.Died:Connect(function()
		if isSwinging then
			stopSwing(false)
		end
		isLaunched = false
		landedFromSwing = false
		landingSpeed = 0
		lastLaunchClock = -1e9
		lastLandingClock = -1e9
		landingShakeStrength = 0
		releaseStyle.cancel()
		swingPose.clear()
		stopHangAnim(0)
		stopFallingAnim()
		stopTrack(landedTrack, 0.08)
		resetFovNow()
	end))

	RunService:BindToRenderStep(renderBindName, Enum.RenderPriority.Camera.Value + 1, function(dt)
		camera = workspace.CurrentCamera or camera
		if not camera or not hrp.Parent then
			return
		end

		local now = os.clock()
		local launchShakeActive = now - lastLaunchClock >= 0 and now - lastLaunchClock < C.LAUNCH_CAMERA_SHAKE_TIME
		local landingShakeActive = now - lastLandingClock >= 0 and now - lastLandingClock < C.LANDING_CAMERA_SHAKE_TIME
		if
			not C.ENABLE_GROUNDED_CAMERA_ASSIST
			and not isSwinging
			and not isLaunched
			and not launchShakeActive
			and not landingShakeActive
			and swingCamLag.Magnitude <= 0.001
			and math.abs(swingCamRoll) <= 0.0001
		then
			return
		end

		local cf = camera.CFrame
		local _, assistPoint = closestGroundCameraTarget()
		if assistPoint then
			local toPoint = assistPoint - cf.Position
			if toPoint.Magnitude > 0.5 then
				local assistAlpha = math.clamp(dt * C.CAMERA_ASSIST_STRENGTH, 0, 0.035)
				local look = cf.LookVector:Lerp(toPoint.Unit, assistAlpha)
				if look.Magnitude > 0.05 then
					cf = CFrame.lookAt(cf.Position, cf.Position + look.Unit, cf.UpVector)
				end
			end
		end

		local velocity = hrp.AssemblyLinearVelocity
		local speed = velocity.Magnitude
		local targetRoll = 0
		local targetLag = Vector3.new(0, 0, 0)

		if isSwinging then
			local swingSpeedRef = math.max(getMaxSwingSpeed(), 1)
			local lateral = math.clamp(velocity:Dot(cf.RightVector) / swingSpeedRef, -1, 1)
			targetRoll = -lateral * C.SWING_CAMERA_ROLL_MAX
			targetLag = -cf.LookVector * math.clamp(speed / swingSpeedRef, 0, 1) * C.SWING_CAMERA_LAG_MAX
			targetLag += Vector3.new(0, math.clamp(-velocity.Y / 160, -0.18, 0.28), 0)
		elseif isLaunched then
			local lateral = math.clamp(velocity:Dot(cf.RightVector) / math.max(C.LAUNCH_SPEED_CAP, 1), -1, 1)
			targetRoll = -lateral * C.SWING_CAMERA_ROLL_MAX * 0.55
		end

		local smooth = math.min(dt * C.SWING_CAMERA_EFFECT_SPEED, 1)
		swingCamRoll += (targetRoll - swingCamRoll) * smooth
		swingCamLag = swingCamLag:Lerp(targetLag, smooth)

		if swingCamLag.Magnitude > 0.001 or math.abs(swingCamRoll) > 0.0001 then
			local pos = cf.Position + swingCamLag
			cf = CFrame.lookAt(pos, pos + cf.LookVector, cf.UpVector) * CFrame.Angles(0, 0, swingCamRoll)
		end

		local shakeOffset = Vector3.new(0, 0, 0)
		local shakeRot = Vector3.new(0, 0, 0)
		local function addShake(startClock, duration, strength, seed, rotScale)
			local age = now - startClock
			if age < 0 or age > duration then
				return
			end
			local fade = (1 - age / duration) ^ 2
			local s = strength * fade
			local t = now * 34
			shakeOffset += Vector3.new(math.noise(seed, t, 0), math.noise(seed, t, 9), math.noise(seed, t, 18)) * s
			shakeRot += Vector3.new(
				math.noise(seed + 13, t, 4),
				math.noise(seed + 27, t, 12),
				math.noise(seed + 41, t, 20)
			) * s * rotScale
		end

		local launchAge = now - lastLaunchClock
		if launchAge >= 0 and launchAge < C.LAUNCH_CAMERA_SHAKE_TIME then
			local speedAlpha = math.clamp(speed / math.max(C.LAUNCH_SPEED_CAP, 1), 0.25, 1)
			addShake(
				lastLaunchClock,
				C.LAUNCH_CAMERA_SHAKE_TIME,
				C.LAUNCH_CAMERA_SHAKE_STRENGTH * speedAlpha,
				240.5,
				0.045
			)
		end
		addShake(
			lastLandingClock,
			C.LANDING_CAMERA_SHAKE_TIME,
			C.LANDING_CAMERA_SHAKE_STRENGTH * landingShakeStrength,
			landingShakeSeed,
			0.055
		)

		if shakeOffset.Magnitude > 0.0001 or shakeRot.Magnitude > 0.0001 then
			cf = cf * CFrame.new(shakeOffset) * CFrame.Angles(shakeRot.X, shakeRot.Y, shakeRot.Z)
		end

		camera.CFrame = cf
	end)

	addConn(RunService.Heartbeat:Connect(function(dt)
		camera = workspace.CurrentCamera or camera
		local now = os.clock()
		local velocity = hrp.AssemblyLinearVelocity
		local speed = velocity.Magnitude

		if isAirborneForSwing() then
			landingSpeed = math.max(landingSpeed, speed)
		end

		if isSwinging then
			if not currentTarget or not currentTarget.Parent or not anchorAttachment or not anchorAttachment.Parent then
				stopSwing(true)
				return
			end
			if swingTimer > C.MIN_SWING_LOCK_TIME and not holdIsActive() then
				stopSwing(true)
				return
			end

			swingTimer += dt
			humanoid.PlatformStand = true
			humanoid.AutoRotate = false
			humanoid.Jump = false

			local anchorWorld = anchorAttachment.WorldPosition
			local fromAnchor = hrp.Position - anchorWorld
			local dist = fromAnchor.Magnitude
			local radial = dist > 0.2 and fromAnchor.Unit or Vector3.new(0, 1, 0)
			local ropeMax = math.max(activeRopeMaxLength or getRopeMaxLength(), C.ROPE_SAFE_MAX_MIN_LENGTH)
			local speedCap = getMaxSwingSpeed() * (1 + swingMomentum * C.SWING_MOMENTUM_SPEED_BONUS)
			local extT = math.clamp(dist / math.max(ropeMax, 1), 0, 1.15)
			local decay = math.clamp(swingTimer / C.FORCE_DECAY_TIME, 0, 1)
			local mult = 1 - decay * (1 - C.FORCE_MIN_MULT)
			local ropeLiftForce = Vector3.new(0, 0, 0)

			rayParams.FilterDescendantsInstances = { character }
			local groundHit =
				workspace:Raycast(hrp.Position, Vector3.new(0, -C.SWING_GROUND_CLEARANCE * 1.8, 0), rayParams)
			if groundHit then
				local groundGap = hrp.Position.Y - groundHit.Position.Y
				local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
				if groundGap < C.SWING_GROUND_CLEARANCE then
					local liftAlpha =
						math.clamp((C.SWING_GROUND_CLEARANCE - groundGap) / C.SWING_GROUND_CLEARANCE, 0, 1)
					ropeLiftForce += Vector3.yAxis * C.SWING_GROUND_LIFT_FORCE * liftAlpha * hrp.AssemblyMass
					if velocity.Y < C.SWING_GROUND_MIN_UP_SPEED * liftAlpha then
						velocity = Vector3.new(velocity.X, C.SWING_GROUND_MIN_UP_SPEED * liftAlpha, velocity.Z)
						hrp.AssemblyLinearVelocity = velocity
					end
					if groundGap < C.SWING_GROUND_HARD_CLEARANCE then
						local lift = math.min(C.SWING_GROUND_HARD_CLEARANCE - groundGap + 0.12, 1.6)
						hrp.CFrame += Vector3.new(0, lift, 0)
					end
					spawnGroundDragDebris(groundHit, horizontalVelocity)
				end
			end

			if zipSpring then
				local zipAlpha = math.clamp(1 - swingTimer / C.ZIP_PULL_TIME, 0, 1)
				if zipAlpha <= 0 then
					zipSpring:Destroy()
					zipSpring = nil
				else
					zipSpring.MaxForce = hrp.AssemblyMass * C.ZIP_SPRING_MAX_ACCEL * C.ROPE_CATCH_FORCE_MULT * zipAlpha
				end
			end

			ropeLiftForce, velocity, speed = updateSwingRopePhysics(
				dt,
				ropeLiftForce,
				velocity,
				speed,
				anchorWorld,
				dist,
				radial,
				ropeMax,
				speedCap,
				mult
			)

			local camLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
			local camRight = camera and camera.CFrame.RightVector or hrp.CFrame.RightVector
			local moveDir = humanoid.MoveDirection
			local camFlat = flatUnit(camLook) or flatUnit(hrp.CFrame.LookVector)
			local moveFlat = Vector3.new(moveDir.X, 0, moveDir.Z)
			local moveFlatUnit = moveFlat.Magnitude > 0.05 and moveFlat.Unit or nil
			if not moveFlatUnit then
				local controlMoveUnit, controlMoveAmount = getControlWorldMove(camera)
				if controlMoveUnit then
					moveFlatUnit = controlMoveUnit
					moveDir = controlMoveUnit * math.max(controlMoveAmount, 0.5)
					moveFlat = Vector3.new(moveDir.X, 0, moveDir.Z)
				end
			end
			local forwardInput = forwardInputAmount()
			if moveFlatUnit and forwardInput <= 0.08 and safeIsKeyDown(Enum.KeyCode.W) then
				forwardInput = 1
			end
			if forwardInput > 0.08 then
				forwardHoldTime += dt * forwardInput
				forwardSwingCharge = math.min(1, forwardSwingCharge + dt * forwardInput / C.FORWARD_CHARGE_TIME)
			else
				forwardHoldTime = math.max(0, forwardHoldTime - dt * 0.55)
				forwardSwingCharge = math.max(0, forwardSwingCharge - dt * 0.7)
			end
			poseInputs.radial = radial
			poseInputs.moveFlatUnit = moveFlatUnit
			poseInputs.forwardInput = forwardInput
			poseInputs.extT = extT
			poseInputs.momentum = swingMomentum

			swingRhythmBoost = math.max(0, swingRhythmBoost - C.SWING_RHYTHM_DECAY_RATE * dt)
			local pumpInputSign = 0
			if camFlat and moveFlatUnit then
				local inputDot = moveFlatUnit:Dot(camFlat)
				if inputDot > 0.28 then
					pumpInputSign = 1
				elseif inputDot < -0.28 then
					pumpInputSign = -1
				end
			end
			if pumpInputSign ~= 0 then
				if lastPumpInputSign ~= 0 and pumpInputSign ~= lastPumpInputSign then
					local switchAge = now - lastPumpSwitchClock
					if switchAge > 0.1 and switchAge < 1.25 then
						local timing = 1 - math.clamp(math.abs(switchAge - 0.48) / 0.77, 0, 1)
						swingRhythmBoost = math.min(1, swingRhythmBoost + 0.24 + timing * 0.2)
					end
					lastPumpSwitchClock = now
				end
				lastPumpInputSign = pumpInputSign
			end

			local inputBias = Vector3.new(0, 0, 0)
			local moveTangent = Vector3.new(0, 0, 0)
			if moveFlatUnit then
				inputBias = camRight * camRight:Dot(moveFlat) * 0.58
				moveTangent = moveDir - radial * moveDir:Dot(radial)
			end

			local steerDir = Vector3.new(camLook.X, 0, camLook.Z) + inputBias
			local tangent = steerDir - radial * steerDir:Dot(radial)
			local camSteerForce = Vector3.new(0, 0, 0)
			if tangent.Magnitude > 0.05 then
				local steerInputScale = 0.42 + math.clamp(moveDir.Magnitude, 0, 1) * 0.58
				camSteerForce = tangent.Unit * getSteerForce() * mult * steerInputScale * hrp.AssemblyMass
			end

			local arcDir = pendulumArcDir(radial)
			local arcForce = Vector3.new(0, 0, 0)
			local pumpForce = Vector3.new(0, 0, 0)
			local deadHangForce = Vector3.new(0, 0, 0)
			local orbitInputForce = Vector3.new(0, 0, 0)
			if arcDir then
				local floorMult = floorScale(anchorWorld, ropeMax)
				local arcStrength = getArcForce() * mult * (0.42 + extT * 0.78) * floorMult
				arcForce = arcDir * arcStrength * hrp.AssemblyMass

				local tangVel = velocity - radial * velocity:Dot(radial)
				local tangSpeed = tangVel.Magnitude
				local targetTangSpeed = speedCap * (0.52 + math.clamp(extT, 0, 1) * 0.24)
				if moveTangent.Magnitude > 0.05 and tangSpeed < targetTangSpeed then
					local lowSpeedBoost = 1 - math.clamp(tangSpeed / 28, 0, 1)
					deadHangForce = moveTangent.Unit
						* C.DEAD_HANG_MOVE_FORCE
						* (0.35 + lowSpeedBoost * 0.65)
						* mult
						* hrp.AssemblyMass
					swingMomentum = math.min(
						1,
						swingMomentum
							+ C.SWING_DEAD_HANG_MOMENTUM_BUILD_RATE
								* moveTangent.Magnitude
								* (0.25 + lowSpeedBoost * 0.75)
								* dt
					)
				end

				local moveAlongTangent = 0
				if moveFlatUnit and tangVel.Magnitude > 0.05 then
					moveAlongTangent = moveFlatUnit:Dot(tangVel.Unit)
				end

				local movingWithArc = tangVel.Magnitude > 4 and tangVel:Dot(arcDir) > 0
				local pumpQuality = 0
				local rhythmQuality = swingRhythmBoost * (0.35 + math.abs(moveAlongTangent) * 0.65)
				local lowSpeedPump = 1 - math.clamp(tangSpeed / 30, 0, 1)
				if moveTangent.Magnitude > 0.05 then
					local orbitGrip = 0.58 + math.clamp(moveAlongTangent, -0.25, 1) * 0.22
					orbitGrip += lowSpeedPump * 0.25 + swingRhythmBoost * 0.18
					orbitInputForce = moveTangent.Unit
						* C.SWING_INPUT_ORBIT_FORCE
						* math.clamp(orbitGrip, 0.35, 1.25)
						* mult
						* hrp.AssemblyMass
				end
				if movingWithArc and moveFlatUnit then
					pumpQuality = math.max(pumpQuality, 0.35)
				end
				if moveFlatUnit then
					pumpQuality = math.max(pumpQuality, math.clamp(moveAlongTangent, 0, 1))
					if moveAlongTangent < -0.12 and (tangSpeed < targetTangSpeed * 0.58 or swingRhythmBoost > 0.12) then
						local reversalQuality = math.abs(moveAlongTangent) * (0.35 + lowSpeedPump * 0.65)
						pumpQuality = math.max(pumpQuality, reversalQuality * 0.72 + rhythmQuality * 0.55)
					else
						pumpQuality = math.max(pumpQuality, rhythmQuality * 0.85)
					end
				end
				pumpQuality = math.max(pumpQuality, forwardInput * 0.55)

				if pumpQuality > 0.08 and tangSpeed > 4 then
					local speedFactor = math.clamp(tangSpeed / math.max(speedCap * 0.7, 1), 0.28, 1)
					local build = (
						C.SWING_MOMENTUM_BUILD_RATE * pumpQuality * speedFactor
						+ C.SWING_MOMENTUM_FORWARD_BUILD_RATE * forwardInput
						+ C.SWING_RHYTHM_BUILD_RATE * rhythmQuality
					) * dt
					swingMomentum = math.min(1, swingMomentum + build)
				elseif not moveFlatUnit or tangSpeed < 5 then
					swingMomentum = math.max(0, swingMomentum - C.SWING_MOMENTUM_IDLE_DECAY_RATE * dt)
				elseif moveAlongTangent < -0.2 then
					if tangSpeed < targetTangSpeed * 0.62 or swingRhythmBoost > 0.12 then
						local reversalBuild = C.SWING_REVERSAL_BUILD_RATE
							* math.abs(moveAlongTangent)
							* (0.35 + lowSpeedPump * 0.65 + swingRhythmBoost * 0.35)
							* dt
						swingMomentum = math.min(1, swingMomentum + reversalBuild)
					else
						swingMomentum = math.max(
							0,
							swingMomentum
								- C.SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * math.abs(moveAlongTangent) * 0.38 * dt
						)
					end
				else
					swingMomentum = math.max(0, swingMomentum - C.SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * 0.28 * dt)
				end

				if tangSpeed < targetTangSpeed and extT > 0.28 then
					local pumpDir = arcDir
					if tangSpeed > 4 and tangVel:Dot(arcDir) > 0 then
						pumpDir = tangVel.Unit
					end
					local deficit = targetTangSpeed - tangSpeed
					pumpForce = pumpDir
						* deficit
						* getSpeedPump()
						* (1 + forwardInput * 0.3 + swingMomentum * 0.22)
						* mult
						* hrp.AssemblyMass
						* 0.02
					if moveTangent.Magnitude > 0.05 and swingRhythmBoost > 0.03 then
						pumpForce += moveTangent.Unit * C.SWING_RHYTHM_FORCE * swingRhythmBoost * (0.45 + math.abs(
							moveAlongTangent
						) * 0.55) * mult * hrp.AssemblyMass
					end
					if
						moveTangent.Magnitude > 0.05
						and moveAlongTangent < -0.12
						and (tangSpeed < targetTangSpeed * 0.62 or swingRhythmBoost > 0.12)
					then
						pumpForce += moveTangent.Unit * C.SWING_REVERSAL_FORCE * math.abs(moveAlongTangent) * (0.35 + lowSpeedPump * 0.65) * mult * hrp.AssemblyMass
					end
				end

				if floorMult < 0.3 and velocity.Y < -10 then
					hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y * 0.84, velocity.Z)
				end
			else
				if moveTangent.Magnitude > 0.05 then
					deadHangForce = moveTangent.Unit * C.DEAD_HANG_MOVE_FORCE * 0.72 * mult * hrp.AssemblyMass
					swingMomentum =
						math.min(1, swingMomentum + C.SWING_DEAD_HANG_MOMENTUM_BUILD_RATE * moveTangent.Magnitude * dt)
				else
					swingMomentum = math.max(0, swingMomentum - C.SWING_MOMENTUM_IDLE_DECAY_RATE * dt)
				end
			end

			local arcWeight = 0.36 + math.clamp((extT - 0.25) / 0.75, 0, 1) * 0.56
			if steerForce then
				steerForce.Force = camSteerForce * (1 - arcWeight * 0.45)
					+ arcForce
					+ pumpForce
					+ deadHangForce
					+ orbitInputForce
					+ ropeLiftForce
			end

			if swingOrientation then
				local currentFace = flatUnit(hrp.CFrame.LookVector)
				local flatVel = Vector3.new(velocity.X, 0, velocity.Z)
				local desiredUnit = nil
				if moveFlatUnit then
					desiredUnit = moveFlatUnit
					if flatVel.Magnitude > 8 then
						local blendedFace = moveFlatUnit * 0.72 + flatVel.Unit * 0.28
						if blendedFace.Magnitude > 0.05 then
							desiredUnit = blendedFace.Unit
						end
					end
				elseif flatVel.Magnitude > 5 then
					desiredUnit = flatVel.Unit
				end

				if desiredUnit and desiredUnit.Magnitude > 0.05 then
					local quickTurn = currentFace and desiredUnit:Dot(currentFace) < C.AVATAR_FAST_TURN_DOT
					local turnRate = quickTurn and C.AVATAR_NATURAL_FACE_FAST_TURN_RATE
						or C.AVATAR_NATURAL_FACE_TURN_RATE
					if moveFlatUnit then
						turnRate += 8
					end
					local faceAlpha = math.clamp(dt * turnRate, 0, 1)
					if swingFaceDir and swingFaceDir.Magnitude > 0.05 then
						swingFaceDir = swingFaceDir:Lerp(desiredUnit, faceAlpha)
					else
						swingFaceDir = desiredUnit
					end

					if swingFaceDir.Magnitude > 0.05 then
						local faceCFrame = CFrame.lookAt(hrp.Position, hrp.Position + swingFaceDir.Unit)
						local tangVelocity = velocity - radial * velocity:Dot(radial)
						local leanPower = math.clamp(
							tangVelocity.Magnitude / math.max(speedCap, 1) + swingMomentum * 0.45 + extT * 0.18,
							0,
							1.25
						)

						swingOrientation.Responsiveness = C.AVATAR_TURN_RESPONSIVENESS
							+ (quickTurn and 18 or 0)
							+ math.floor(leanPower * 8)
						swingOrientation.MaxTorque = hrp.AssemblyMass * 22000
						swingOrientation.CFrame = faceCFrame
					end
				end
			end

			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-C.ANGULAR_DAMP * dt)
			if speed > speedCap then
				hrp.AssemblyLinearVelocity = velocity.Unit * speedCap
			end

			swingCharge = math.min(1, swingCharge + dt / C.CHARGE_TIME)
			layoutCharge()
		else
			poseInputs.radial = nil
			poseInputs.moveFlatUnit = nil
			poseInputs.forwardInput = 0
			poseInputs.extT = 0
			poseInputs.momentum = 0

			if isLaunched then
				releaseStyle.step(now, dt, isLaunched, isSwinging, lastLaunchClock)
			end

			if holdIsActive() then
				tryAttach()
			end

			local scanMode = "none"
			if isAirborneForSwing() then
				scanMode = "air"
			elseif isGroundedForSwing() then
				scanMode = "ground"
			end

			if scanMode == "none" then
				hideSwingTargetUi()
			else
				local needsScan = scanMode ~= lastTargetScanMode
					or now - lastTargetScanClock >= C.TARGET_SCAN_INTERVAL
					or (scannedVisualTarget ~= nil and not scannedVisualTarget.Parent)

				if needsScan then
					lastTargetScanClock = now
					lastTargetScanMode = scanMode
					if scanMode == "air" then
						if isHrpInSafezone() then
							scannedVisualTarget, scannedVisualCanSwing =
								pickVisualSwingTarget(0, C.SAFEZONE_BLOCKED_UI_RANGE, highlightedTarget, true)
						else
							scannedVisualTarget, scannedVisualCanSwing =
								pickVisualSwingTarget(getSwingRange(), getSwingRange(), highlightedTarget)
						end
					else
						if isHrpInSafezone() then
							scannedVisualTarget, scannedVisualCanSwing =
								pickVisualSwingTarget(0, C.SAFEZONE_BLOCKED_UI_RANGE, highlightedTarget, true)
						else
							scannedVisualTarget, scannedVisualCanSwing = pickVisualSwingTarget(
								math.max(C.GROUNDED_READY_RANGE, getSwingRange()),
								math.max(C.GROUNDED_READY_RANGE, getSwingRange()),
								highlightedTarget
							)
						end
					end
					if
						scannedVisualTarget ~= lastVisualTarget
						or scannedVisualCanSwing ~= lastVisualCanSwing
						or targetVisualShown ~= (scannedVisualTarget ~= nil)
					then
						updateTargetVisual(scannedVisualTarget, scannedVisualCanSwing)
					end
				end
			end
		end

		stepTargetVisual(dt)

		local trailOn = (isSwinging or isLaunched or isAirborneForSwing()) and (speed > 62 or velocity.Y < -78)
		setTrailsEnabled(trailOn)

		if camera then
			local targetFov = originalFov
			if isSwinging or isLaunched then
				local t = math.clamp(speed / math.max(getMaxSwingSpeed(), 1), 0, 1)
				targetFov = originalFov + (C.FOV_MAX - originalFov) * t
			end

			local attachAge = os.clock() - lastAttachClock
			if isSwinging and attachAge >= 0 and attachAge < C.ATTACH_FOV_TIME then
				local u = attachAge / C.ATTACH_FOV_TIME
				targetFov -= C.ATTACH_FOV_PUNCH * math.sin(u * math.pi)
			end

			local launchAge = os.clock() - lastLaunchClock
			if launchAge >= 0 and launchAge < C.LAUNCH_FOV_TIME then
				local u = 1 - launchAge / C.LAUNCH_FOV_TIME
				targetFov += C.LAUNCH_FOV_BOOST * u * u
			end

			local landingAge = os.clock() - lastLandingClock
			if landingAge >= 0 and landingAge < C.LANDING_FOV_TIME then
				local u = 1 - landingAge / C.LANDING_FOV_TIME
				targetFov -= C.LANDING_FOV_KICK * u * u * landingShakeStrength
			end

			camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(dt * C.FOV_SPEED, 1)
		end
	end))

	return function()
		pcall(function()
			RunService:UnbindFromRenderStep(renderBindName)
		end)
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		table.clear(conns)
		disconnectMobileJumpButton()
		if isSwinging then
			stopSwing(false)
		end
		releaseStyle.cancel()
		swingPose.clear()
		destroySwingObjects()
		destroyPreview(true)
		if targetHighlight then
			targetHighlight:Destroy()
			targetHighlight = nil
			targetHighlightAdornee = nil
		end
		if targetHighlightProxyPart then
			targetHighlightProxyPart:Destroy()
			targetHighlightProxyPart = nil
		end
		cleanupWorkspaceHelpersByName("SwingTargetHighlightProxy", nil)
		cleanupWorkspaceHelpersByName("SwingTargetHighlight", nil)
		if markerGui then
			markerGui:Destroy()
			markerGui = nil
		end
		if markerAnchorPart then
			markerAnchorPart:Destroy()
			markerAnchorPart = nil
		end
		cleanupWorkspaceHelpersByName("SwingMarkerAnchor", nil)
		cleanupWorkspaceHelpersByName("SwingPreviewAnchor", nil)
		destroyMobileFallbackButton()
		setTrailsEnabled(false)
		for _, trail in ipairs(trails) do
			if trail and trail.Parent then
				local a0 = trail.Attachment0
				local a1 = trail.Attachment1
				trail:Destroy()
				if a0 then
					a0:Destroy()
				end
				if a1 then
					a1:Destroy()
				end
			end
		end
		stopHangAnim(0)
		stopFallingAnim()
		stopTrack(landedTrack, 0.12)
		stopOptionalSound("Wind")
		pcall(function()
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
		end)
		pcall(resetFovNow)
	end
end

local dispose = nil

player.CharacterAdded:Connect(function(character)
	if dispose then
		dispose()
		dispose = nil
	end
	dispose = boot(character)
end)

if player.Character then
	task.spawn(function(character)
		if dispose then
			dispose()
			dispose = nil
		end
		dispose = boot(character)
	end, player.Character)
end
