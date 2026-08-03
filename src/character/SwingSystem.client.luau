local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TextChatService = game:GetService("TextChatService")

local C = {}
C.PRE_SIMULATION_SIGNAL = nil
pcall(function()
	C.PRE_SIMULATION_SIGNAL = RunService.PreSimulation
end)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local floatingClaimCutsceneMod = nil
local spiderEncounterMod = nil
local standDialogueCutsceneMod = nil

local function getClientModule(name)
	local ps = player:FindFirstChild("PlayerScripts")
	local client = ps and ps:FindFirstChild("Client")
	local mod = client and client:FindFirstChild(name)
	if mod and mod:IsA("ModuleScript") then
		local ok, result = pcall(require, mod)
		if ok then
			return result
		end
	end
	return nil
end

local function isChatInputFocused(): boolean
	local ok, focused = pcall(function()
		return TextChatService.ChatInputBarConfiguration.IsFocused
	end)
	return ok and focused == true
end

local function isTypingBlocked()
	-- TextChatService chat bar is in CoreGui — GetFocusedTextBox() returns nil for it.
	return UserInputService:GetFocusedTextBox() ~= nil or isChatInputFocused()
end

local function moduleIsActive(cached: any, name: string): (any, boolean)
	local mod = cached
	if mod == nil then
		mod = getClientModule(name) or false
	end
	if mod and typeof(mod.isActive) == "function" and mod.isActive() then
		return mod, true
	end
	return mod, false
end

local function isGameplayCutsceneActive()
	local active = false
	floatingClaimCutsceneMod, active = moduleIsActive(floatingClaimCutsceneMod, "FloatingClaimCutscene")
	if active then
		return true
	end
	spiderEncounterMod, active = moduleIsActive(spiderEncounterMod, "BushSpiderEncounterController")
	if active then
		return true
	end
	standDialogueCutsceneMod, active = moduleIsActive(standDialogueCutsceneMod, "StandDialogueCutscene")
	if active then
		return true
	end
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in { "FloatingClaimCutscene", "BushSpiderCutscene", "StandDialogueCutscene" } do
			local gui = pg:FindFirstChild(name)
			if gui and gui:IsA("ScreenGui") and gui.Enabled then
				return true
			end
		end
	end
	return false
end

local function isSwingInputBlocked()
	return isTypingBlocked() or isGameplayCutsceneActive()
end

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
local WebTrapConfig = tryRequireModule(sharedFolder, "WebTrapConfig")
local UiFonts = tryRequireModule(sharedFolder, "UiFonts")

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
C.ROPE_STRETCH_MAX_EXTRA = 38
-- Rope stretch flex must NOT scale with launch power — that hung players into kill zones.
C.ROPE_STRETCH_FLEX_CAP = 1.45
C.ROPE_ABSOLUTE_MAX = 108
C.ROPE_MAX_HANG_DEPTH = 56
C.ROPE_MOMENTUM_LENGTH_MULT = 0.68
C.ROPE_DISTANCE_STRETCH_MULT = 0.22
C.ROPE_LENGTH_RESPONSE = 24
C.ROPE_ATTACH_START_MULT = 0.58

C.ROPE_VISUAL_IDLE_STRAIGHT_SPEED = 36
C.ROPE_VISUAL_FULL_SAG_SPEED = 78

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
C.LOOK_DOWN_PITCH = -0.22
C.LOOK_DOWN_FORWARD_DOT = 0.12
C.MIN_TARGET_HEIGHT_OFFSET = -8
-- Aim scoring: crosshair / screen-center dominates, but nearer vines along look must win.
C.TARGET_SCORE_ALIGN = 4.8
C.TARGET_SCORE_CENTER = 5.2
C.TARGET_SCORE_CENTER_LOOK_DOWN = 3.2
C.TARGET_SCORE_DIST_WEIGHT = 1.15
C.TARGET_SCORE_PREFER_NEAR_STUDS = 90
C.TARGET_SCORE_PREFER_NEAR_REACH_FRAC = 0.32
C.TARGET_SCORE_NEAR_AIM_BONUS = 1.8
C.TARGET_SCORE_LATERAL = 8.5
C.TARGET_SCORE_LATERAL_WORLD = 5.5
C.TARGET_SCORE_BEHIND_REJECT = 0.05
C.TARGET_CAMERA_RAY_BONUS = 25
C.TARGET_SCREEN_LOCK_RADIUS = 0.22
C.TARGET_SCREEN_LOCK_BONUS = 22
-- Look-cone for "first vine in front of camera" (angular, clamped — not depth*loose).
C.TARGET_LOOK_CONE_TAN = 0.16
C.TARGET_LOOK_CONE_MIN_LATERAL = 5.5
C.TARGET_LOOK_CONE_MAX_LATERAL = 8.5
-- High reach must not latch a far vine when a nearer one sits along the same look line.
C.TARGET_DEPTH_FRONT_SLACK = 12
C.TARGET_DEPTH_TIE_EPS = 1.0
C.AIRBORNE_TARGET_LOOK_DOT = 0.08
C.GROUNDED_TARGET_LOOK_DOT = 0.12
C.TARGET_SCREEN_RADIUS_LIMIT = 0.72
C.GROUNDED_TARGET_SCREEN_RADIUS_LIMIT = 0.65
C.TARGET_MAX_SCREEN_DX = 0.48
C.TARGET_SCAN_INTERVAL = 0.12
C.TARGET_SCAN_INTERVAL_GROUNDED = 0.14
C.TARGET_SCAN_INTERVAL_FAST = 0.05
C.TARGET_SCAN_FAST_SPEED = 55
C.TARGET_CANDIDATE_EXTRA_RADIUS = 4
C.TARGET_GRID_CELL_SIZE = 64
C.TARGET_MAX_CANDIDATES_PER_SCAN = 45
C.TARGET_MAX_CANDIDATES_GROUNDED = 28
C.TARGET_MAX_CANDIDATES_HIGH_REACH = 72
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
C.MIN_SWING_LOCK_TIME = 0.18
C.MOBILE_JUMP_HOLD_GRACE = 0.06
C.MOBILE_REAL_JUMP_PRESS_WINDOW = 0.28
-- Grounded range should match actual swing reach, otherwise the UI can show red even when attach is allowed.
-- These are fallback floors only; the live grounded ready distance uses getSwingRange().
C.GROUNDED_READY_RANGE = 75
C.GROUNDED_BLOCKED_UI_RANGE = 50
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
C.LAUNCH_UP_DV = 62
C.LAUNCH_CHARGE_DV = 22
C.LAUNCH_FORWARD_INPUT_DV = 68
C.LAUNCH_SPEED_CAP = 175
-- After a launch, always allow re-latch onto the vine you came from (even past normal reach).
C.RETURN_SWING_REACH_MULT = 5.0
C.RETURN_SWING_REACH_BONUS = 280
C.RETURN_SWING_MAX_DIST = 450
C.LAUNCH_STYLE_TIME = 1.85
C.LAUNCH_STYLE_TILT_TIME = 0.38
C.LAUNCH_STYLE_ORIENT_RESPONSIVENESS = 62
C.LAUNCH_STYLE_ORIENT_TORQUE = 26000
C.LAUNCH_STYLE_UP_AIM = 1.42
C.LAUNCH_STYLE_DOWN_AIM = 2.65
C.LAUNCH_DROP_DELAY = 0.62
C.LAUNCH_DROP_ACCEL = 31
C.LAUNCH_DROP_MAX_SPEED = -124
C.LAUNCH_HANG_RELEASE_FADE = 0.24
C.LAUNCH_FALL_ANIM_FADE = 0.28
C.LAUNCH_FALL_STOP_FADE = 0.18
C.LAUNCH_LAND_ANIM_FADE = 0.14
-- Landed animation should be a quick impact pose, not a full 3-second body lock.
-- If this is too short/long, tune only this value.
C.LAUNCH_LAND_MAX_PLAY_TIME = 0.55
C.LAUNCH_LAND_CONTROL_RELEASE_DELAY = 0.02
-- Roblox can sometimes enter FallingDown/Ragdoll/Physics after a fast angled swing landing.
-- These keep landing snappy and immediately controllable instead of waiting for the default get-up delay.
C.SWING_DISABLE_FALLDOWN_STATES = true
C.SWING_LANDING_GROUND_RAY = 7.5
C.SWING_LANDING_RECOVERY_DELAY = 0.06
C.SWING_LANDING_RECOVERY_REPEAT_DELAY = 0.35
C.SWING_LANDING_MAX_Y_SPEED_FOR_RECOVERY = 14
C.SWING_LANDED_ANIM_WEIGHT = 0.85
C.SWING_ENABLE_LANDED_IMPACT_ANIM = true
C.LAUNCH_VELOCITY_AIM_BLEND = 1.35
C.LAUNCH_FALL_EXTRA_DOWN_AIM = 1.15
C.LAUNCH_MAX_ROLL_DEG = 22
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
C.ATTACH_CAMERA_SHAKE_TIME = 0.24
C.ATTACH_CAMERA_SHAKE_STRENGTH = 0.38
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
C.SWING_IDLE_FLOW_DAMPING = 0.78
C.SWING_IDLE_FLOW_MIN_SPEED = 1.45
C.SWING_IDLE_SWAY_DELAY = 0.65
C.SWING_IDLE_SWAY_FORCE = 6.5
C.SWING_IDLE_SWAY_SPEED = 1.25
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
-- Faint continuous wind buffet while swinging / airborne (keep slight)
C.SWING_WIND_SHAKE_POS = 0.048
C.SWING_WIND_SHAKE_ROT = 0.0075
C.SWING_WIND_SHAKE_SPEED = 8.2
C.SWING_WIND_SHAKE_MIN_SPEED = 6
C.SWING_WIND_SHAKE_REF_SPEED = 52
C.SWING_WIND_SHAKE_HANG = 0.22
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
C.ROPE_COLOR_A = Color3.fromRGB(135, 82, 38)
C.ROPE_COLOR_B = Color3.fromRGB(86, 51, 24)

C.ROPE_BRICK_COLOR = BrickColor.new("Reddish brown")
C.ROPE_VISUAL_THICKNESS = 0.18
C.ROPE_VISUAL_SAG = 0.65
C.ROPE_VISUAL_SHOOT_SPEED = 1200
C.ROPE_VISUAL_SHOOT_MIN_TIME = 0.02
C.ROPE_VISUAL_SHOOT_MAX_TIME = 0.06
C.ROPE_VISUAL_MIN_LENGTH = 0.25
C.ROPE_THROW_BEAM_WIDTH0 = 0.24
C.ROPE_THROW_BEAM_WIDTH1 = 0.11
C.ROPE_THROW_BEAM_COLOR = Color3.fromRGB(238, 244, 255)
C.ROPE_THROW_BEAM_TIP_COLOR = Color3.fromRGB(90, 220, 255)
C.ROPE_THROW_BEAM_LIGHT = 0.9
C.ROPE_THROW_LAUNCH_EASE = 2.65
C.ROPE_THROW_LATCH_DISTANCE = 2.5
C.ROPE_THROW_ARC_HEIGHT_MULT = 0.06
C.ROPE_THROW_ARC_MIN = 0.6
C.ROPE_THROW_ARC_MAX = 7
C.ROPE_THROW_ARC_SWAY_MULT = 0.018
C.ROPE_THROW_HOOK_SIZE = Vector3.new(0.28, 0.28, 0.36)
C.ROPE_THROW_RECOIL_DV = 8
C.ROPE_THROW_LAUNCH_VFX_SIZE = 1.15
C.ROPE_THROW_LAUNCH_VFX_TIME = 0.22
C.ROPE_THROW_TRAIL_LIFE = 0.18
C.ROPE_LATCH_FLASH_SIZE = 3.2
C.ROPE_LATCH_FLASH_TIME = 0.32
C.ROPE_LATCH_RING_COUNT = 2

C.ROPE_THROW_BRICK_COLOR = BrickColor.new("Reddish brown")
C.ROPE_LOCKED_BRICK_COLOR = BrickColor.new("Reddish brown")

C.ROPE_VISUAL_SHOOT_THICKNESS = 0.09
C.ROPE_VISUAL_LOCKED_THICKNESS = 0.18

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
			return math.clamp(stats.maxSwingSpeed / C.MAX_SWING_SPEED, 0.75, 6.5)
		end
		if typeof(stats.steeringForce) == "number" and stats.steeringForce > 0 then
			return math.clamp(stats.steeringForce / C.STEER_FORCE, 0.75, 6.5)
		end
	end

	local rawPower = getFirstNumberAttribute({ "SwingPower", "Power" })
	if not rawPower then
		local force = getFirstNumberAttribute({ "SwingForce" })
		if force and force > 0 then
			return math.clamp(force / C.STEER_FORCE, 0.75, 6.5)
		end
		return 1
	end

	if rawPower > 10 then
		rawPower = rawPower / 100
	end

	return math.clamp(rawPower, 0.65, 6.5)
end

local function getSwingRange()
	local ropeStats = getRopeStats()
	if ropeStats and typeof(ropeStats.reachStuds) == "number" and ropeStats.reachStuds > 0 then
		return math.clamp(ropeStats.reachStuds, 40, 380)
	end

	local rangeAttr = getFirstNumberAttribute({ "SwingRange", "ReachDistance", "Reach_Distance" })
	if rangeAttr and rangeAttr > 0 then
		return math.clamp(rangeAttr, 40, 380)
	end

	local powerScale = getPowerScale()
	return math.clamp(C.SWING_RANGE * (0.9 + (powerScale - 1) * 0.25), 65, 280)
end

-- Latch/UI ready range = live swing reach (Reach upgrade). Do NOT cap to rope hang max.
local function getLatchRange()
	return getSwingRange()
end

local function getRopeMaxLength()
	return math.clamp(
		C.ROPE_MAX_LENGTH + math.max(getSwingRange() - C.SWING_RANGE, 0) * 0.35,
		C.ROPE_MIN_LENGTH + C.ROPE_HANG_PULL_MIN_GAP + 4,
		C.ROPE_ABSOLUTE_MAX
	)
end

local function getRopeFlexScale()
	-- Keep rope hang length stable; launch power is separate.
	return math.clamp(0.9 + (getPowerScale() - 1) * 0.08, 0.85, C.ROPE_STRETCH_FLEX_CAP)
end

local function getRopeRestLength()
	return math.clamp(C.ROPE_MAX_LENGTH * C.ROPE_REST_LENGTH_MULT, C.ROPE_MIN_LENGTH, C.ROPE_MAX_LENGTH)
end

local function getLaunchScale()
	local stats = getPowerStats()
	if stats and typeof(stats.maxLaunchSpeed) == "number" and stats.maxLaunchSpeed > 0 then
		return math.clamp(stats.maxLaunchSpeed / C.LAUNCH_SPEED_CAP, 0.86, 6.0)
	end
	return math.clamp(0.9 + (getPowerScale() - 1) * 0.82, 0.86, 5.5)
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

local function resolveOptionalSound(name)
	local s = script:FindFirstChild(name)
	if not s then
		local soundEffects = SoundService:FindFirstChild("SoundEffects")
		s = soundEffects and soundEffects:FindFirstChild(name)
	end
	if s and s:IsA("Sound") then
		return s
	end
	if s then
		local nested = s:FindFirstChildWhichIsA("Sound")
		if nested then
			return nested
		end
	end
	return nil
end

local function playOptionalSound(name)
	local s = resolveOptionalSound(name)
	if s and s:IsA("Sound") then
		pcall(function()
			if name == "Wind Loop" then
				s.Looped = true
			end
			s.TimePosition = 0
			s:Play()
		end)
	end
end

local function stopOptionalSound(name)
	local s = resolveOptionalSound(name)
	if s and s:IsA("Sound") then
		pcall(function()
			s:Stop()
		end)
	end
end

local function stopWindLoopSfx()
	stopOptionalSound("Wind Loop")
	stopOptionalSound("Wind")
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
			* math.clamp(1 + (launchScale - 1) * 1.05, 0.9, 5.8)
			* (1 + momentumBoost * C.SWING_MOMENTUM_LAUNCH_BONUS * 0.86)

		local horizontalSpeed = (
			C.LAUNCH_FORWARD_DV
			+ C.LAUNCH_FORWARD_INPUT_DV * inputBoost
			+ C.LAUNCH_CHARGE_DV * charge * 0.5
			+ C.LAUNCH_FORWARD_DV * C.SWING_MOMENTUM_LAUNCH_BONUS * momentumBoost
		)
			* holdMult
			* launchScale
			* math.clamp(0.96 + (launchScale - 1) * 0.36, 0.9, 2.35)
		local upwardSpeed = (
			C.LAUNCH_UP_DV
			+ C.LAUNCH_CHARGE_DV * charge * 0.72
			+ inputBoost * 9.5
			+ momentumBoost * 12.5
		)
			* holdMult
			* launchScale
			* math.clamp(1 + momentumBoost * 0.22, 1, 1.28)
		local targetVelocity = launchDir * horizontalSpeed + Vector3.new(0, upwardSpeed, 0)

		if targetVelocity.Magnitude > cap then
			targetVelocity = targetVelocity.Unit * cap
		end
		hrp.AssemblyLinearVelocity = targetVelocity

		state.launchDir = launchDir
		local bodyRight = Vector3.new(hrp.CFrame.RightVector.X, 0, hrp.CFrame.RightVector.Z)
		local rollDot = bodyRight.Magnitude > 0.05 and targetVelocity:Dot(bodyRight.Unit) or 0
		state.rollSign = rollDot ~= 0 and math.sign(rollDot) or 1
		state.untilClock = os.clock() + C.LAUNCH_STYLE_TIME + math.clamp(momentumBoost * 0.35, 0, 0.35)

		local orient = ensure()
		if orient then
			local initialVelocityDir = targetVelocity.Magnitude > 1 and targetVelocity.Unit or launchDir
			local lookDir = launchDir * 0.5 + initialVelocityDir * 0.35 + Vector3.new(0, C.LAUNCH_STYLE_UP_AIM, 0)
			if lookDir.Magnitude > 0.05 then
				orient.CFrame = launchLookCFrame(lookDir.Unit, math.rad(10) * state.rollSign)
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
		local speed = velocity.Magnitude
		local velocityDir = speed > 1 and velocity.Unit or launchDir

		local spinFade = 1 - math.clamp(age / C.LAUNCH_STYLE_TIME, 0, 1)
		local upAlpha = 1 - smoothStep(age / C.LAUNCH_STYLE_TILT_TIME)
		local fallCue = math.clamp((-velocity.Y + 10) / 68, 0, 1)
		local fallSpeedAlpha = math.clamp(-velocity.Y / 105, 0, 1)
		local timeDownAlpha = smoothStep(
			(age - C.LAUNCH_STYLE_TILT_TIME * 0.72)
				/ math.max(C.LAUNCH_STYLE_TIME - C.LAUNCH_STYLE_TILT_TIME * 0.72, 0.05)
		)
		local downAlpha = math.max(timeDownAlpha, fallCue)

		-- Aim with the actual velocity, not only the original launch direction.
		-- This makes the avatar pitch down harder when falling straight down.
		local velocityBlend = math.clamp(downAlpha * C.LAUNCH_VELOCITY_AIM_BLEND, 0, 1.55)
		local horizontalBlend = math.clamp(1 - fallSpeedAlpha * 0.62, 0.22, 1)
		local verticalAim = C.LAUNCH_STYLE_UP_AIM * upAlpha
			- (C.LAUNCH_STYLE_DOWN_AIM + C.LAUNCH_FALL_EXTRA_DOWN_AIM * fallSpeedAlpha) * downAlpha

		local lookDir = launchDir * (0.62 * horizontalBlend)
			+ velocityDir * velocityBlend
			+ Vector3.new(0, verticalAim, 0)

		if lookDir.Magnitude > 0.05 then
			local orient = ensure()
			if orient then
				local rollAmount = math.rad(C.LAUNCH_MAX_ROLL_DEG)
					* state.rollSign
					* spinFade
					* math.clamp(0.45 + downAlpha * 0.75, 0, 1.15)
				orient.Responsiveness = C.LAUNCH_STYLE_ORIENT_RESPONSIVENESS + downAlpha * 24 + fallSpeedAlpha * 18
				orient.MaxTorque = hrp.AssemblyMass * C.LAUNCH_STYLE_ORIENT_TORQUE * (1 + downAlpha * 0.35)
				orient.CFrame = launchLookCFrame(lookDir.Unit, rollAmount)
			end
		end

		hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-12 * dt)

		if age >= C.LAUNCH_DROP_DELAY then
			local dropAlpha = math.clamp(
				(age - C.LAUNCH_DROP_DELAY) / math.max(C.LAUNCH_STYLE_TIME - C.LAUNCH_DROP_DELAY, 0.05),
				0,
				1
			)
			local nextY =
				math.max(C.LAUNCH_DROP_MAX_SPEED, velocity.Y - C.LAUNCH_DROP_ACCEL * (0.22 + dropAlpha * 0.78) * dt)
			hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, nextY, velocity.Z)
		end
	end

	return controller
end

local function getThrowArcWorldPos(handWorld, anchorWorld, alpha)
	local delta = anchorWorld - handWorld
	local dist = delta.Magnitude
	if dist < 0.05 then
		return handWorld
	end

	local launchT = 1 - (1 - math.clamp(alpha, 0, 1)) ^ C.ROPE_THROW_LAUNCH_EASE
	local arcHeight = math.clamp(dist * C.ROPE_THROW_ARC_HEIGHT_MULT, C.ROPE_THROW_ARC_MIN, C.ROPE_THROW_ARC_MAX)
	local basePos = handWorld:Lerp(anchorWorld, launchT)
	local arcLift = math.sin(launchT * math.pi) * arcHeight

	local side = delta:Cross(Vector3.yAxis)
	local swayDir = side.Magnitude > 0.05 and side.Unit or Vector3.new()
	local swayAmt = math.sin(launchT * math.pi) * math.clamp(dist * C.ROPE_THROW_ARC_SWAY_MULT, 0, 1.4)

	return basePos + Vector3.new(0, arcLift, 0) + swayDir * swayAmt
end

local function getSwingAttachCenterWorld(part)
	if part:IsA("BasePart") then
		return part.Position
	end

	local ok, cf = pcall(function()
		return part:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" then
		return cf.Position
	end

	return part:GetPivot().Position
end

local function resolveLockedSwingAttachWorld(part)
	local centerWorld = getSwingAttachCenterWorld(part)
	local ok, point = pcall(function()
		return part:GetClosestPointOnSurface(centerWorld)
	end)
	if ok and typeof(point) == "Vector3" then
		return point
	end
	return centerWorld
end

local function setupHandThrowAttachment(hand, hrp, side)
	local attachment = Instance.new("Attachment")
	attachment.Name = "SwingHandAttachment"

	if hand ~= hrp then
		attachment.Parent = hand
		local gripName = side == "Left" and "LeftGripAttachment" or "RightGripAttachment"
		local grip = hand:FindFirstChild(gripName)
		if grip and grip:IsA("Attachment") then
			attachment.CFrame = grip.CFrame
		elseif hand.Name:find("Hand") then
			attachment.Position = Vector3.new(0, 0, -0.34)
		else
			attachment.Position = Vector3.new(0, -0.45, 0)
		end
	else
		attachment.Parent = hrp
		local lateral = side == "Left" and -1.2 or 1.2
		attachment.Position = Vector3.new(lateral, 0.45, -0.5)
	end

	return attachment
end

local function spawnThrowLaunchVfx(worldPos)
	local burst = Instance.new("Part")
	burst.Name = "SwingThrowLaunchBurst"
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.new(0.45, 0.45, 0.45)
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanTouch = false
	burst.CanQuery = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = Color3.fromRGB(255, 255, 255)
	burst.Transparency = 0.1
	burst.CFrame = CFrame.new(worldPos)
	burst.Parent = workspace

	local endSize = C.ROPE_THROW_LAUNCH_VFX_SIZE
	TweenService:Create(burst, TweenInfo.new(C.ROPE_THROW_LAUNCH_VFX_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(endSize, endSize, endSize),
		Transparency = 1,
	}):Play()
	Debris:AddItem(burst, C.ROPE_THROW_LAUNCH_VFX_TIME + 0.06)

	for i = 1, 2 do
		local ring = Instance.new("Part")
		ring.Name = "SwingThrowLaunchRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.05, 0.55 + i * 0.15, 0.55 + i * 0.15)
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CanQuery = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = i == 1 and Color3.fromRGB(255, 255, 255) or C.PREVIEW_COLOR
		ring.Transparency = 0.15 + i * 0.08
		ring.CFrame = CFrame.new(worldPos) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace

		local delay = (i - 1) * 0.04
		task.delay(delay, function()
			if not ring.Parent then
				return
			end
			TweenService:Create(
				ring,
				TweenInfo.new(C.ROPE_THROW_LAUNCH_VFX_TIME * 1.05, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{
					Size = Vector3.new(0.05, endSize * (2 + i * 0.45), endSize * (2 + i * 0.45)),
					Transparency = 1,
				}
			):Play()
		end)
		Debris:AddItem(ring, C.ROPE_THROW_LAUNCH_VFX_TIME + 0.12 + delay)
	end
end

local function cameraFacingDiscCFrame(worldPos)
	local cam = workspace.CurrentCamera
	if not cam then
		return CFrame.new(worldPos) * CFrame.Angles(math.rad(90), 0, 0)
	end

	local toCamera = cam.CFrame.Position - worldPos
	if toCamera.Magnitude < 0.05 then
		toCamera = -cam.CFrame.LookVector
	else
		toCamera = toCamera.Unit
	end

	local right = toCamera:Cross(Vector3.yAxis)
	if right.Magnitude < 0.001 then
		right = Vector3.xAxis
	else
		right = right.Unit
	end

	return CFrame.fromMatrix(worldPos, right, toCamera)
end

local function spawnRopeLatchVfx(worldPos)
	local flash = Instance.new("Part")
	flash.Name = "SwingRopeLatchFlash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(0.65, 0.65, 0.65)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanTouch = false
	flash.CanQuery = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 255, 255)
	flash.Transparency = 0.06
	flash.CFrame = CFrame.new(worldPos)
	flash.Parent = workspace

	local flashSize = C.ROPE_LATCH_FLASH_SIZE
	TweenService:Create(flash, TweenInfo.new(C.ROPE_LATCH_FLASH_TIME * 0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(flashSize * 0.55, flashSize * 0.55, flashSize * 0.55),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, C.ROPE_LATCH_FLASH_TIME + 0.08)

	for i = 1, C.ROPE_LATCH_RING_COUNT do
		local ring = Instance.new("Part")
		ring.Name = "SwingRopeLatchRing"
		ring.Shape = Enum.PartType.Cylinder
		local startDiameter = 0.85 + i * 0.18
		ring.Size = Vector3.new(0.07, startDiameter, startDiameter)
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CanQuery = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = i == 1 and C.READY_COLOR or C.PREVIEW_COLOR
		ring.Transparency = 0.1 + i * 0.05
		ring.CFrame = cameraFacingDiscCFrame(worldPos)
		ring.Parent = workspace

		local endDiameter = flashSize * (1.65 + i * 0.42)
		TweenService:Create(
			ring,
			TweenInfo.new(C.ROPE_LATCH_FLASH_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{
				Size = Vector3.new(0.07, endDiameter, endDiameter),
				Transparency = 1,
			}
		):Play()
		Debris:AddItem(ring, C.ROPE_LATCH_FLASH_TIME + 0.14)
	end
end

local function pendulumArcDir(radial)
	local gravity = Vector3.new(0, -workspace.Gravity, 0)
	local tangent = gravity - radial * gravity:Dot(radial)
	if tangent.Magnitude < 0.05 then
		return nil
	end
	return tangent.Unit
end

local function raycastCollidableGround(origin: Vector3, direction: Vector3, character: Model, rayParams: RaycastParams): RaycastResult?
	local ignore: { Instance } = { character }
	local remaining = direction
	local from = origin
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	for _ = 1, 14 do
		rayParams.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(from, remaining, rayParams)
		if not hit then
			return nil
		end

		local inst = hit.Instance
		if inst:IsA("Terrain") then
			return hit
		end
		if inst:IsA("BasePart") and inst.CanCollide and inst.Transparency < 0.95 then
			return hit
		end

		table.insert(ignore, inst)
		local traveled = (hit.Position - from).Magnitude
		local left = remaining.Magnitude - traveled
		if left < 0.08 then
			return nil
		end
		from = hit.Position + remaining.Unit * 0.06
		remaining = remaining.Unit * left
	end

	return nil
end

local function groundVisualFromHit(hit: RaycastResult?): (Color3, Enum.Material)
	if not hit then
		return Color3.fromRGB(110, 90, 55), Enum.Material.Ground
	end

	local mat = hit.Material
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		local ok, terrainColor = pcall(function()
			return workspace.Terrain:GetMaterialColor(mat)
		end)
		if ok and typeof(terrainColor) == "Color3" then
			return terrainColor, mat
		end
		return Color3.fromRGB(105, 88, 50), mat
	end
	if inst:IsA("BasePart") then
		return inst.Color, inst.Material
	end
	return Color3.fromRGB(110, 90, 55), mat
end

local function spawnLandingBlocks(character, hrp, rayParams, speed)
	local alpha = math.clamp((speed - 8) / 70, 0.58, 1)
	if alpha <= 0 then
		return
	end

	local hit = raycastCollidableGround(hrp.Position, Vector3.new(0, -12, 0), character, rayParams)
	if not hit then
		return
	end

	local pos = hit.Position
	local color, material = groundVisualFromHit(hit)
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
	ring.Color = color:Lerp(Color3.new(0, 0, 0), 0.08)
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
	burst.Color = color
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
		part.Color = color:Lerp(Color3.new(0, 0, 0), math.random(0, 12) / 100)
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
		chip.Color = color:Lerp(Color3.new(0, 0, 0), math.random(0, 10) / 100)
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

local function canPlaySwingLandingImpact(character, hrp, rayParams): boolean
	return raycastCollidableGround(
		hrp.Position,
		Vector3.new(0, -C.SWING_LANDING_GROUND_RAY, 0),
		character,
		rayParams
	) ~= nil
end

local function spawnGroundDragDebris(hrp, hit, horizontalVelocity, lastClock)
	if not hit then
		return lastClock
	end

	local now = os.clock()
	if now - lastClock < C.SWING_GROUND_DRAG_DEBRIS_INTERVAL then
		return lastClock
	end

	local speed = horizontalVelocity and horizontalVelocity.Magnitude or 0
	local pos = hit.Position
	local color = Color3.fromRGB(110, 90, 55)
	local material = hit.Material or Enum.Material.Concrete
	if hit.Instance and hit.Instance:IsA("BasePart") then
		if not hit.Instance.CanCollide or hit.Instance.Transparency >= 0.95 then
			return lastClock
		end
		color = hit.Instance.Color
		material = hit.Material or hit.Instance.Material
	elseif hit.Instance and hit.Instance:IsA("Terrain") then
		local ok, terrainColor = pcall(function()
			return workspace.Terrain:GetMaterialColor(hit.Material)
		end)
		if ok and typeof(terrainColor) == "Color3" then
			color = terrainColor
		end
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

	return now
end

local function boot(character)
	camera = workspace.CurrentCamera or camera

	local humanoid = character:WaitForChild("Humanoid", 30)
	local hrp = character:WaitForChild("HumanoidRootPart", 30)
	if not humanoid or not hrp then
		return function() end
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local st = {
		character = character,
		humanoid = humanoid,
		hrp = hrp,
		animator = animator,
		originalFov = camera and camera.FieldOfView or 70,
		isSwinging = false,
		isLaunched = false,
		isAirborne = false,
		landedFromSwing = false,
		landingSpeed = 0,
		swingTimer = 0,
		swingCharge = 0,
		forwardSwingCharge = 0,
		forwardHoldTime = 0,
		swingMomentum = 0,
		swingRhythmBoost = 0,
		lastPumpInputSign = 0,
		lastPumpSwitchClock = -1e9,
		lastSwingInputClock = os.clock(),
		swingFaceDir = nil,
		lastTryClock = -1e9,
		lastAttachClock = -1e9,
		lastGroundJumpClock = -1e9,
		swingPressIntentUntil = -1e9,
		airborneStartedClock = -1e9,
		lastLaunchClock = -1e9,
		poseInputs = {
			radial = nil,
			moveFlatUnit = nil,
			forwardInput = 0,
			extT = 0,
			momentum = 0,
		},
		lastLandingClock = -1e9,
		landingShakeStrength = 0,
		landingShakeSeed = math.random() * 1000,
		attachShakeStrength = 0,
		attachShakeSeed = math.random() * 1000,
		windShakeSeed = math.random() * 1000,
		windShakeIntensity = 0,
		lastGroundDragDebrisClock = -1e9,
		swingCamRoll = 0,
		swingCamLag = Vector3.new(0, 0, 0),
		spaceHeld = false,
		gamepadHeld = false,
		mobileJumpHoldUntil = -1e9,
		mobileJumpHeld = false,
		mobileRealJumpPressUntil = -1e9,
		-- Toggle mode: ignore release until the attach jump is fully released.
		toggleNeedsJumpRelease = false,
		targetCache = {},
		targetSet = {},
		targetGrid = {},
		targetGridKeyByPart = {},
		boundVines = {},
		targetCacheReady = false,
		lastTargetScanClock = -1e9,
		lastTargetScanMode = "none",
		scannedVisualTarget = nil,
		scannedVisualCanSwing = false,
		lastCameraRayTarget = nil,
		currentTarget = nil,
		lastReleasedTarget = nil,
		lastReleasedTargetClock = -1e9,
		returnSwingTarget = nil,
		highlightedTarget = nil,
		highlightedPoint = nil,
		targetVisualShown = false,
		anchorAttachment = nil,
		bodyAttachment = nil,
		ropeConstraint = nil,
		activeRopeMaxLength = nil,
		ropeCatchUntil = -1e9,
		ropeCatchStartLength = nil,
		zipSpring = nil,
		forceAttachment = nil,
		steerForce = nil,
		orientationAttachment = nil,
		swingOrientation = nil,
		handAttachment = nil,
		swingRopeVisual = nil,
		pendingSwingParams = nil,
		lockedAttachWorld = nil,
		previewAnchorPart = nil,
		previewFrom = nil,
		previewTo = nil,
		previewBeam = nil,
		previewTarget = nil,
		previewFade = 0,
		previewFadeGoal = 0,
		lastPreviewFadeBucket = -1,
		lastPreviewColor = nil,
		targetVisualStepAccum = 0,
		targetHighlight = nil,
		targetHighlightAdornee = nil,
		targetHighlightProxyPart = nil,
		lastHighlightColor = nil,
		lastHighlightFillTransparency = nil,
		markerAnchorPart = nil,
		markerGui = nil,
		markerLabel = nil,
		markerRing = nil,
		markerStroke = nil,
		markerDot = nil,
		lastMarkerText = nil,
		lastVisualTarget = nil,
		lastVisualCanSwing = nil,
		targetReadyVisual = 0,
		targetReadyGoal = 0,
		targetVisualColor = C.NOT_READY_COLOR,
		chargeGui = nil,
		chargeDot = nil,
		activeHangTrack = nil,
		currentHangSide = "Right",
		nextSwingHandSide = "Right",
		rightHangTrack = nil,
		leftHangTrack = nil,
		fallingTrack = nil,
		landedTrack = nil,
		lastLandedAnimClock = -1e9,
		trails = {},
		conns = {},
		playerAnimationsFolder = nil,
		playerAnimationsFolderSearched = false,
	}
	st.swingPose = createSwingPose(st.character, st.hrp)
	st.releaseStyle = createReleaseStyleController(st.humanoid, st.hrp)
	st.renderBindName = "UnifiedSwingCameraFX_" .. tostring(os.clock()) .. "_" .. tostring(math.random(1, 1000000))
	st.rayParams = RaycastParams.new()
	st.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	st.rayParams.FilterDescendantsInstances = { st.character }

	function st.isHrpInSafezone()
		if not SafezoneUtil or typeof(SafezoneUtil.isCharacterInSafezone) ~= "function" then
			return false
		end

		local ok, blocked = pcall(function()
			return SafezoneUtil.isCharacterInSafezone(st.character)
		end)
		return ok and blocked == true
	end

	function st.isWebTrapped()
		if not WebTrapConfig or typeof(WebTrapConfig.TRAPPED_ATTR) ~= "string" then
			return false
		end
		return player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true
	end

	function st.resetFovNow()
		camera = workspace.CurrentCamera or camera
		if camera then
			camera.FieldOfView = st.originalFov
		end
	end


	if C.SWING_DISABLE_FALLDOWN_STATES then
		pcall(function()
			st.humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		end)
		pcall(function()
			st.humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		end)
	end

	function st.isSwingLandingRecoveryState(state)
		return state == Enum.HumanoidStateType.FallingDown
			or state == Enum.HumanoidStateType.Ragdoll
			or state == Enum.HumanoidStateType.Physics
			or state == Enum.HumanoidStateType.GettingUp
	end

	function st.isCloseToGroundForSwingLanding()
		if st.humanoid.FloorMaterial ~= Enum.Material.Air then
			return true
		end
		return raycastCollidableGround(
			st.hrp.Position,
			Vector3.new(0, -C.SWING_LANDING_GROUND_RAY, 0),
			st.character,
			st.rayParams
		) ~= nil
	end

	function st.forceSwingHumanoidControl()
		if st.isWebTrapped() then
			return
		end
		st.releaseStyle.cancel()
		st.swingPose.clear()
		st.humanoid.PlatformStand = false
		st.humanoid.AutoRotate = true
		st.humanoid.Sit = false
		st.hrp.AssemblyAngularVelocity = Vector3.zero
		if st.humanoid.Health > 0 then
			pcall(function()
				local state = st.humanoid:GetState()
				if st.isSwingLandingRecoveryState(state) then
					st.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				else
					st.humanoid:ChangeState(Enum.HumanoidStateType.Running)
				end
			end)
		end
	end

	function st.normalizeAnimationId(id)
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

	function st.getPlayerAnimationsFolder()
		if st.playerAnimationsFolder and st.playerAnimationsFolder.Parent then
			return st.playerAnimationsFolder
		end
		if st.playerAnimationsFolderSearched then
			return nil
		end
		st.playerAnimationsFolderSearched = true

		local animationsFolder = ReplicatedStorage:FindFirstChild(C.ANIMATIONS_FOLDER_NAME)
			or ReplicatedStorage:WaitForChild(C.ANIMATIONS_FOLDER_NAME, 5)
		st.playerAnimationsFolder = animationsFolder
			and (
				animationsFolder:FindFirstChild(C.PLAYER_ANIMATIONS_FOLDER_NAME)
				or animationsFolder:WaitForChild(C.PLAYER_ANIMATIONS_FOLDER_NAME, 5)
			)
		if not st.playerAnimationsFolder then
			warn(
				"[MergedFriendSwingSystem] Missing animation folder:",
				C.ANIMATIONS_FOLDER_NAME .. "/" .. C.PLAYER_ANIMATIONS_FOLDER_NAME
			)
		end
		return st.playerAnimationsFolder
	end

	function st.findPlayerAnimation(name)
		local folder = st.getPlayerAnimationsFolder()
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

	function st.loadAnimTrack(source, looped, priority, name)
		if not C.ENABLE_SWING_ANIMATIONS then
			return nil
		end

		local animId = st.normalizeAnimationId(source)
		if animId == "" then
			return nil
		end

		local anim = Instance.new("Animation")
		anim.Name = name or "SwingAnimation"
		anim.AnimationId = animId
		local ok, track = pcall(function()
			return st.animator:LoadAnimation(anim)
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

	function st.playTrack(track, fadeTime, weight, speed)
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

	function st.stopTrack(track, fadeTime)
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

	local hangRightAnim = st.findPlayerAnimation(C.HANG_ANIM_RIGHT_NAME)
	local hangLeftAnim = st.findPlayerAnimation(C.HANG_ANIM_LEFT_NAME)
	local fallingAnim = st.findPlayerAnimation(C.FALLING_ANIM_NAME)
	local landedAnim = st.findPlayerAnimation(C.LANDED_ANIM_NAME)

	st.rightHangTrack = st.loadAnimTrack(hangRightAnim, true, Enum.AnimationPriority.Action4, "HangRight")
	if st.normalizeAnimationId(hangLeftAnim) == st.normalizeAnimationId(hangRightAnim) then
		st.leftHangTrack = st.rightHangTrack
	else
		st.leftHangTrack = st.loadAnimTrack(hangLeftAnim, true, Enum.AnimationPriority.Action4, "HangLeft")
	end
	st.fallingTrack = st.loadAnimTrack(fallingAnim, true, Enum.AnimationPriority.Action4, "SwingFalling")
	-- Use Action instead of Action4 so the landing clip does not overpower normal movement for several seconds.
	st.landedTrack = st.loadAnimTrack(landedAnim, false, Enum.AnimationPriority.Action2, "SwingLanded")

	function st.addConn(conn)
		table.insert(st.conns, conn)
		return conn
	end

	-- Mobile fallback button removed in no-register build.

	function st.advanceSwingHandSide()
		local side = st.nextSwingHandSide
		st.nextSwingHandSide = side == "Left" and "Right" or "Left"
		st.currentHangSide = side
		return side
	end

	function st.handPartForSide(side)
		local names
		if side == "Left" then
			names = { "LeftHand", "Left Arm", "LeftLowerArm", "LeftUpperArm" }
		else
			names = { "RightHand", "Right Arm", "RightLowerArm", "RightUpperArm" }
		end
		for _, name in ipairs(names) do
			local p = st.character:FindFirstChild(name, true)
			if p and p:IsA("BasePart") then
				return p
			end
		end
		return st.hrp
	end

	function st.playHangAnim(_attachWorld)
		st.stopTrack(st.fallingTrack, 0.1)
		st.stopTrack(st.landedTrack, 0.08)
		local side = st.currentHangSide or "Right"
		local track = side == "Left" and st.leftHangTrack or st.rightHangTrack
		if st.activeHangTrack and st.activeHangTrack ~= track then
			st.stopTrack(st.activeHangTrack, 0.12)
		end
		st.activeHangTrack = track
		if st.activeHangTrack then
			st.playTrack(st.activeHangTrack, 0.12, 1, 1)
		end
	end

	function st.stopHangAnim(fadeTime)
		local fade = fadeTime
		if fade == nil then
			fade = 0.08
		end
		st.stopTrack(st.rightHangTrack, fade)
		if st.leftHangTrack ~= st.rightHangTrack then
			st.stopTrack(st.leftHangTrack, fade)
		end
		st.activeHangTrack = nil
	end

	function st.playFallingAnim(fadeTime)
		if st.isSwinging or not (st.isLaunched or st.landedFromSwing) then
			return
		end

		local fade = fadeTime
		if fade == nil then
			fade = C.LAUNCH_FALL_ANIM_FADE
		end

		-- Smoothly crossfade from the hanging pose into the falling pose.
		-- The old version stopped hang instantly and restarted Falling every state change,
		-- which made release -> fall -> land feel rushed/snappy.
		st.stopHangAnim(C.LAUNCH_HANG_RELEASE_FADE)
		st.stopTrack(st.landedTrack, C.LAUNCH_LAND_ANIM_FADE)

		if st.fallingTrack then
			pcall(function()
				if not st.fallingTrack.IsPlaying then
					st.fallingTrack.TimePosition = 0
				end
			end)
		end

		st.playTrack(st.fallingTrack, fade, 1, 1)
	end

	function st.stopFallingAnim(fadeTime)
		local fade = fadeTime
		if fade == nil then
			fade = C.LAUNCH_FALL_STOP_FADE
		end
		st.stopTrack(st.fallingTrack, fade)
	end

	function st.playLandedAnim()
		st.stopHangAnim(C.LAUNCH_HANG_RELEASE_FADE)
		st.stopFallingAnim(C.LAUNCH_FALL_STOP_FADE)

		local now = os.clock()
		if now - st.lastLandedAnimClock < 0.12 then
			return
		end

		st.lastLandedAnimClock = now
		st.forceSwingHumanoidControl()

		if not C.SWING_ENABLE_LANDED_IMPACT_ANIM then
			st.stopTrack(st.landedTrack, 0.05)
			return
		end

		if st.landedTrack then
			pcall(function()
				st.landedTrack.TimePosition = 0
			end)
			-- Low weight + short lifetime = quick impact flavor without stealing movement control.
			st.playTrack(st.landedTrack, C.LAUNCH_LAND_ANIM_FADE, C.SWING_LANDED_ANIM_WEIGHT, 0.9)

			local playToken = st.lastLandedAnimClock
			task.spawn(function()
				local stopAt = os.clock() + C.LAUNCH_LAND_MAX_PLAY_TIME
				while os.clock() < stopAt do
					if st.lastLandedAnimClock ~= playToken then
						return
					end
					if st.isSwinging then
						st.stopTrack(st.landedTrack, 0.05)
						return
					end
					-- If the player tries to move/jump, instantly fade the impact pose out.
					local playedFor = os.clock() - playToken

					if st.humanoid.Jump then
						st.stopTrack(st.landedTrack, 0.05)
						return
					end

					if playedFor > 0.28 and st.humanoid.MoveDirection.Magnitude > 0.35 then
						st.stopTrack(st.landedTrack, 0.08)
						return
					end

					RunService.Heartbeat:Wait()
				end
				if st.lastLandedAnimClock == playToken then
					st.stopTrack(st.landedTrack, 0.1)
				end
			end)
		end

		-- Extra delayed recovery catches the frames where Roblox briefly switches to GettingUp/Physics after impact.
		task.delay(C.LAUNCH_LAND_CONTROL_RELEASE_DELAY, function()
			if st.humanoid.Parent and not st.isSwinging then
				st.forceSwingHumanoidControl()
			end
		end)
		task.delay(C.SWING_LANDING_RECOVERY_REPEAT_DELAY, function()
			if st.humanoid.Parent and not st.isSwinging then
				st.forceSwingHumanoidControl()

				if os.clock() - st.lastLandedAnimClock >= C.LAUNCH_LAND_MAX_PLAY_TIME then
					st.stopTrack(st.landedTrack, 0.08)
				end
			end
		end)
	end

	function st.makeTrails()
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
			local part = st.character:FindFirstChild(name, true)
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
				table.insert(st.trails, trail)
			end
		end
	end

	st.makeTrails()

	function st.setTrailsEnabled(on)
		for _, trail in ipairs(st.trails) do
			if trail and trail.Parent then
				trail.Enabled = on
			end
		end
	end

	function st.closestAttachWorldOnPart(part)
		local ok, point = pcall(function()
			return part:GetClosestPointOnSurface(st.hrp.Position)
		end)
		if ok and typeof(point) == "Vector3" then
			return point
		end
		return part.Position
	end

	-- Front-most depth of a vine along the camera look (bbox corners — not center/aim point).
	function st.nearestLookDepthOnPart(part: BasePart): number
		camera = workspace.CurrentCamera or camera
		if not camera then
			return (part.Position - st.hrp.Position).Magnitude
		end
		local origin = camera.CFrame.Position
		local look = camera.CFrame.LookVector
		local cf = part.CFrame
		local hs = part.Size * 0.5
		local minDepth = math.huge
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local corner = cf:PointToWorldSpace(Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz))
					local depth = (corner - origin):Dot(look)
					if depth > 0 then
						minDepth = math.min(minDepth, depth)
					end
				end
			end
		end
		if minDepth < math.huge then
			return minDepth
		end
		return math.max((part.Position - origin):Dot(look), 0.05)
	end

	function st.getFrontLookDepthCutoff(maxDist: number, minLookDot: number?): number?
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent then
			return nil
		end
		local minDepth = math.huge
		local minLook = minLookDot or C.MIN_LOOK_DOT
		for _, part in ipairs(st.getCandidateTargets(maxDist)) do
			if not part.Parent or part:IsDescendantOf(st.character) then
				continue
			end
			local attachWorld = st.closestAttachWorldOnPart(part)
			local bodyDist = (attachWorld - st.hrp.Position).Magnitude
			if bodyDist < 2 or bodyDist > maxDist then
				continue
			end
			if attachWorld.Y < st.hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
				continue
			end
			local aimWorld = st.aimPointOnPart(part)
			local _dx, _dy, _screenR, viewDot, onScreen = st.getScreenAimMetrics(aimWorld)
			if viewDot < minLook or (not onScreen and viewDot < 0.35) then
				continue
			end
			local frontDepth = st.nearestLookDepthOnPart(part)
			if frontDepth >= 4 and frontDepth <= maxDist then
				minDepth = math.min(minDepth, frontDepth)
			end
		end
		if minDepth >= math.huge then
			return nil
		end
		return minDepth + C.TARGET_DEPTH_FRONT_SLACK
	end

	function st.isBehindFrontSwingDepth(part: BasePart, maxDist: number, depthCutoff: number?, minLookDot: number?): boolean
		if not depthCutoff then
			return false
		end
		local frontDepth = st.nearestLookDepthOnPart(part)
		if frontDepth <= depthCutoff then
			return false
		end
		-- Side vines at a similar depth stay eligible; only drop vines clearly behind the front row.
		local aimWorld = st.aimPointOnPart(part)
		local _dx, _dy, screenR, viewDot, onScreen = st.getScreenAimMetrics(aimWorld)
		if not onScreen or viewDot < (minLookDot or C.MIN_LOOK_DOT) then
			return false
		end
		return screenR <= C.TARGET_SCREEN_RADIUS_LIMIT
	end

	-- Aim point = vine nearest the camera look-ray (NOT nearest the body — that picks side vines).
	function st.aimPointOnPart(part: BasePart): Vector3
		camera = workspace.CurrentCamera or camera
		local center = part.Position
		if not camera then
			return center
		end
		local origin = camera.CFrame.Position
		local look = camera.CFrame.LookVector
		local along = math.max((center - origin):Dot(look), 0.05)
		local onRay = origin + look * along
		local ok, point = pcall(function()
			return part:GetClosestPointOnSurface(onRay)
		end)
		if ok and typeof(point) == "Vector3" then
			return point
		end
		return center
	end

	function st.getScreenAimMetrics(aimWorld: Vector3): (number, number, number, number, boolean)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return 1, 1, 1, -1, false
		end
		local look = camera.CFrame.LookVector
		local toCam = aimWorld - camera.CFrame.Position
		if toCam.Magnitude < 0.5 then
			return 1, 1, 1, -1, false
		end
		local viewDot = toCam.Unit:Dot(look)
		local vp, onScreen = camera:WorldToViewportPoint(aimWorld)
		local size = camera.ViewportSize
		local dx = (vp.X - size.X * 0.5) / math.max(size.X, 1)
		local dy = (vp.Y - size.Y * 0.5) / math.max(size.Y, 1)
		local screenR = math.sqrt(dx * dx + dy * dy)
		if vp.Z <= 0 then
			return dx, dy, 2, viewDot, false
		end
		return dx, dy, screenR, viewDot, onScreen == true
	end

	function st.resolveSwingPartFromHit(inst: Instance?): BasePart?
		local cur: Instance? = inst
		while cur do
			if cur:IsA("BasePart") and st.targetSet[cur] then
				return cur
			end
			cur = cur.Parent
		end
		return nil
	end

	-- Crosshair vine: nearest vine in the look cone (first in front of camera).
	-- High reach must NOT skip a close vine for a far one dead-center at max range.
	function st.pickCameraLookSwingTarget(reach: number): BasePart?
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent then
			return nil
		end
		local maxDist = math.max(reach, 8)
		local origin = camera.CFrame.Position
		local look = camera.CFrame.LookVector
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignored: { Instance } = { st.character }
		params.FilterDescendantsInstances = ignored

		local function acceptAim(aimWorld: Vector3): (boolean, number, number)
			local dx, _dy, screenR, viewDot, onScreen = st.getScreenAimMetrics(aimWorld)
			if viewDot < 0.22 or (not onScreen and viewDot < 0.55) then
				return false, screenR, viewDot
			end
			if math.abs(dx) > C.TARGET_MAX_SCREEN_DX then
				return false, screenR, viewDot
			end
			return true, screenR, viewDot
		end

		local function maxLookLateral(depth: number): number
			-- Angular cone with a near floor + far cap so high reach can't "see through"
			-- a slightly off-center near vine to a dead-center far one.
			return math.clamp(
				depth * C.TARGET_LOOK_CONE_TAN,
				C.TARGET_LOOK_CONE_MIN_LATERAL,
				C.TARGET_LOOK_CONE_MAX_LATERAL
			)
		end

		local depthCutoff = st.getFrontLookDepthCutoff(maxDist, 0.22)

		-- Prefer the nearest vine along look. Ray can miss thin near vines and hit far ones.
		local best: BasePart? = nil
		local bestDepth = math.huge
		local bestScreenR = math.huge
		for _, part in ipairs(st.getCandidateTargets(maxDist)) do
			if not part.Parent then
				continue
			end
			if st.isBehindFrontSwingDepth(part, maxDist, depthCutoff, 0.22) then
				continue
			end
			local attachWorld = st.closestAttachWorldOnPart(part)
			local bodyDist = (attachWorld - st.hrp.Position).Magnitude
			if bodyDist < 2 or bodyDist > maxDist then
				continue
			end
			if attachWorld.Y < st.hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
				continue
			end
			local aimWorld = st.aimPointOnPart(part)
			local frontDepth = st.nearestLookDepthOnPart(part)
			if frontDepth < 4 or frontDepth > maxDist then
				continue
			end
			local onRay = origin + look * frontDepth
			local lateral = (aimWorld - onRay).Magnitude
			if lateral > maxLookLateral(frontDepth) then
				continue
			end
			local okAim, screenR = acceptAim(aimWorld)
			if not okAim then
				continue
			end
			-- Nearer along look always wins; screen-center only breaks near ties at similar depth.
			if
				frontDepth + C.TARGET_DEPTH_TIE_EPS < bestDepth
				or (math.abs(frontDepth - bestDepth) <= C.TARGET_DEPTH_TIE_EPS and screenR < bestScreenR)
			then
				bestDepth = frontDepth
				bestScreenR = screenR
				best = part
			end
		end
		if best then
			return best
		end

		-- Fallback: center ray (thin vines / empty candidate grid). Walk the ray and keep
		-- the nearest valid swing target — never stop at the first far vine the ray reaches.
		local dirs = {
			look,
			(look + camera.CFrame.RightVector * 0.03).Unit,
			(look - camera.CFrame.RightVector * 0.03).Unit,
			(look + camera.CFrame.UpVector * 0.03).Unit,
			(look - camera.CFrame.UpVector * 0.03).Unit,
		}

		local rayBest: BasePart? = nil
		local rayBestDepth = math.huge
		for _, dir in ipairs(dirs) do
			table.clear(ignored)
			table.insert(ignored, st.character)
			for _ = 1, 8 do
				params.FilterDescendantsInstances = ignored
				local hit = workspace:Raycast(origin, dir * maxDist, params)
				if not hit then
					break
				end
				local swing = st.resolveSwingPartFromHit(hit.Instance)
				if swing then
					local attachWorld = st.closestAttachWorldOnPart(swing)
					local dist = (attachWorld - st.hrp.Position).Magnitude
					if dist < 2 or dist > maxDist then
						table.insert(ignored, hit.Instance)
						continue
					end
					if attachWorld.Y < st.hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
						table.insert(ignored, hit.Instance)
						continue
					end
					if st.isBehindFrontSwingDepth(swing, maxDist, depthCutoff, 0.22) then
						table.insert(ignored, swing)
						continue
					end
					local aimWorld = st.aimPointOnPart(swing)
					local okAim = acceptAim(aimWorld)
					if not okAim then
						table.insert(ignored, swing)
						continue
					end
					local frontDepth = st.nearestLookDepthOnPart(swing)
					if frontDepth < rayBestDepth then
						rayBestDepth = frontDepth
						rayBest = swing
					end
					table.insert(ignored, swing)
					continue
				end
				local inst = hit.Instance
				if inst:IsA("BasePart") and inst.CanCollide and inst.Transparency < 0.55 and inst.Size.Magnitude > 6 then
					break
				end
				table.insert(ignored, inst)
			end
		end

		return rayBest
	end

	function st.targetCellCoord(value)
		return math.floor(value / C.TARGET_GRID_CELL_SIZE)
	end

	function st.targetGridKeyFromCoords(x, y, z)
		return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
	end

	function st.targetGridKeyForPosition(pos)
		return st.targetGridKeyFromCoords(st.targetCellCoord(pos.X), st.targetCellCoord(pos.Y), st.targetCellCoord(pos.Z))
	end

	function st.removeTargetFromGrid(part)
		local oldKey = st.targetGridKeyByPart[part]
		if not oldKey then
			return
		end

		st.targetGridKeyByPart[part] = nil
		local cell = st.targetGrid[oldKey]
		if not cell then
			return
		end

		cell[part] = nil
		if not next(cell) then
			st.targetGrid[oldKey] = nil
		end
	end

	function st.addTargetToGrid(part)
		st.removeTargetFromGrid(part)

		local key = st.targetGridKeyForPosition(part.Position)
		st.targetGridKeyByPart[part] = key

		local cell = st.targetGrid[key]
		if not cell then
			cell = {}
			st.targetGrid[key] = cell
		end
		cell[part] = true
	end

	function st.addSwingTarget(obj)
		if not obj:IsA("BasePart") or not obj.Parent then
			return
		end
		if st.targetSet[obj] then
			return
		end

		st.targetSet[obj] = true
		table.insert(st.targetCache, obj)
		st.addTargetToGrid(obj)
	end

	function st.removeSwingTarget(obj)
		if not st.targetSet[obj] then
			return
		end

		st.targetSet[obj] = nil
		for i = #st.targetCache, 1, -1 do
			if st.targetCache[i] == obj then
				table.remove(st.targetCache, i)
				break
			end
		end
		st.removeTargetFromGrid(obj)
	end

	function st.seedVineTargets(vine)
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
					st.addSwingTarget(obj)
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

	function st.bindVineFolder(vine, seedExisting)
		if not vine or not C.TARGET_ENABLE_VINE_NAME_FALLBACK then
			return
		end
		if st.boundVines[vine] then
			return
		end
		st.boundVines[vine] = true

		if seedExisting ~= false then
			st.seedVineTargets(vine)
		end
		st.addConn(vine.DescendantAdded:Connect(function(obj)
			if obj:IsA("BasePart") and obj.Name == C.SWING_TARGET_NAME then
				st.addSwingTarget(obj)
			end
		end))
		st.addConn(vine.DescendantRemoving:Connect(function(obj)
			st.removeSwingTarget(obj)
		end))
	end

	function st.initializeTargetCache()
		if st.targetCacheReady then
			return
		end
		st.targetCacheReady = true

		local taggedTargets = CollectionService:GetTagged(C.SWING_TARGET_TAG)
		for _, obj in ipairs(taggedTargets) do
			st.addSwingTarget(obj)
		end
		local hasTaggedTargets = #taggedTargets > 0

		st.addConn(CollectionService:GetInstanceAddedSignal(C.SWING_TARGET_TAG):Connect(st.addSwingTarget))
		st.addConn(CollectionService:GetInstanceRemovedSignal(C.SWING_TARGET_TAG):Connect(st.removeSwingTarget))

		local map = workspace:FindFirstChild(C.MAP_FOLDER_NAME)
		local vine = map and map:FindFirstChild(C.VINE_FOLDER_NAME)
		st.bindVineFolder(vine, not (C.TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))

		if C.TARGET_ENABLE_VINE_NAME_FALLBACK and not vine then
			st.addConn(workspace.DescendantAdded:Connect(function(obj)
				if obj.Name == C.VINE_FOLDER_NAME then
					local parent = obj.Parent
					if parent and parent.Name == C.MAP_FOLDER_NAME then
						st.bindVineFolder(obj, not (C.TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))
					end
				elseif obj:IsA("BasePart") and obj.Name == C.SWING_TARGET_NAME then
					local ancestor = obj.Parent
					while ancestor do
						if ancestor.Name == C.VINE_FOLDER_NAME then
							st.addSwingTarget(obj)
							break
						end
						ancestor = ancestor.Parent
					end
				end
			end))
		end

		-- No warn: tags often arrive a moment after TagSwingTargets.server finishes.
		-- GetInstanceAddedSignal above picks them up; empty cache just means no swing points yet.
	end

	function st.getTargets()
		st.initializeTargetCache()

		for i = #st.targetCache, 1, -1 do
			local part = st.targetCache[i]
			if not part.Parent then
				st.targetSet[part] = nil
				st.removeTargetFromGrid(part)
				table.remove(st.targetCache, i)
			end
		end

		return st.targetCache
	end

	task.defer(st.initializeTargetCache)

	function st.getCandidateTargets(maxDistance)
		st.initializeTargetCache()
		if #st.targetCache == 0 and not C.TARGET_ENABLE_VINE_NAME_FALLBACK then
			return {}
		end

		local radius = math.max(2, (maxDistance or getSwingRange()) + C.TARGET_CANDIDATE_EXTRA_RADIUS)
		local origin = st.hrp.Position
		local candidates = {}
		local seen = {}
		local invalidTargets = {}
		local candidateCap = math.max(
			C.TARGET_MAX_CANDIDATES_PER_SCAN,
			if radius > 140 then C.TARGET_MAX_CANDIDATES_HIGH_REACH else C.TARGET_MAX_CANDIDATES_PER_SCAN
		)

		local centerX = st.targetCellCoord(origin.X)
		local centerY = st.targetCellCoord(origin.Y)
		local centerZ = st.targetCellCoord(origin.Z)
		local cellRadius = math.max(1, math.ceil(radius / C.TARGET_GRID_CELL_SIZE))

		-- Walk cells center-out so high reach doesn't fill the candidate cap with far vines first.
		for shell = 0, cellRadius do
			local x0, x1 = centerX - shell, centerX + shell
			local y0, y1 = centerY - shell, centerY + shell
			local z0, z1 = centerZ - shell, centerZ + shell
			for x = x0, x1 do
				for y = y0, y1 do
					for z = z0, z1 do
						if shell > 0 and x ~= x0 and x ~= x1 and y ~= y0 and y ~= y1 and z ~= z0 and z ~= z1 then
							continue
						end
						local cell = st.targetGrid[st.targetGridKeyFromCoords(x, y, z)]
						if cell then
							for part in pairs(cell) do
								if not seen[part] then
									seen[part] = true
									if not part.Parent then
										table.insert(invalidTargets, part)
										continue
									end
									if not st.targetSet[part] or part:IsDescendantOf(st.character) then
										continue
									end

									local halfSize = part.Size.Magnitude * 0.5
									if (part.Position - origin).Magnitude <= radius + halfSize then
										table.insert(candidates, part)
									end
								end
							end
						end
					end
				end
			end
			-- Once the near shells already exceed the cap, keep nearest below.
			if shell >= 1 and #candidates >= candidateCap * 2 then
				break
			end
		end

		for _, part in ipairs(invalidTargets) do
			st.removeSwingTarget(part)
		end

		if #candidates == 0 and #st.targetCache <= C.TARGET_FULL_SCAN_FALLBACK_LIMIT then
			for _, part in ipairs(st.getTargets()) do
				if
					not seen[part]
					and part.Parent
					and part.Parent
					and not part:IsDescendantOf(st.character)
				then
					local halfSize = part.Size.Magnitude * 0.5
					if (part.Position - origin).Magnitude <= radius + halfSize then
						seen[part] = true
						table.insert(candidates, part)
					end
				end
			end
		end

		if #candidates > candidateCap then
			table.sort(candidates, function(a, b)
				local da = (a.Position - origin).Magnitude
				local db = (b.Position - origin).Magnitude
				return da < db
			end)
			local trimmed = table.create(candidateCap)
			for i = 1, candidateCap do
				trimmed[i] = candidates[i]
			end
			return trimmed
		end

		return candidates
	end

	function st.hasLineOfSight(part, attachWorld)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return true
		end

		local origin = camera.CFrame.Position
		local delta = attachWorld - origin
		if delta.Magnitude < 0.5 then
			return true
		end

		local ignored = { st.character }
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

	function st.pickSwingTarget(requireLineOfSight, maxDistanceOverride, minLookDotOverride, maxScreenRadiusOverride)
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent or st.isHrpInSafezone() then
			return nil
		end

		local look = camera.CFrame.LookVector
		local lookingDown = look.Y <= C.LOOK_DOWN_PITCH
		local flatLook = flatUnit(look) or flatUnit(st.hrp.CFrame.LookVector)
		local reach = maxDistanceOverride or getSwingRange()
		local minLookDot = minLookDotOverride or C.MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or C.TARGET_SCREEN_RADIUS_LIMIT
		local maxDx = C.TARGET_MAX_SCREEN_DX
		local depthCutoff = st.getFrontLookDepthCutoff(reach, minLookDot)

		-- Crosshair vine always wins when the look-ray hits one (no laggy multi-ray spam).
		local rayHit = st.pickCameraLookSwingTarget(reach)
		st.lastCameraRayTarget = rayHit
		if rayHit then
			local attachWorld = st.closestAttachWorldOnPart(rayHit)
			if not requireLineOfSight or st.hasLineOfSight(rayHit, attachWorld) then
				return rayHit
			end
		end

		local best = nil
		local bestScore = -math.huge
		local bestScreenR = math.huge
		local bestFrontDepth = math.huge

		for _, part in ipairs(st.getCandidateTargets(reach)) do
			if not part.Parent then
				continue
			end
			if part:IsDescendantOf(st.character) then
				continue
			end
			if st.isBehindFrontSwingDepth(part, reach, depthCutoff, minLookDot) then
				continue
			end

			local attachWorld = st.closestAttachWorldOnPart(part)
			local offset = attachWorld - st.hrp.Position
			local dist = offset.Magnitude
			if dist < 2 or dist > reach then
				continue
			end
			if attachWorld.Y < st.hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
				continue
			end

			-- Score aim from camera look → vine, not body → vine.
			local aimWorld = st.aimPointOnPart(part)
			local dx, _dy, screenRadius, viewDot, onScreen = st.getScreenAimMetrics(aimWorld)
			if viewDot < -0.05 then
				continue
			end

			local toCameraTarget = aimWorld - camera.CFrame.Position
			if toCameraTarget.Magnitude < 0.5 then
				continue
			end

			local flatDir = flatUnit(aimWorld - camera.CFrame.Position)
			local flatAlign = if flatDir and flatLook then flatDir:Dot(flatLook) else nil

			-- Never latch onto something behind the camera facing.
			if flatAlign ~= nil and flatAlign < C.TARGET_SCORE_BEHIND_REJECT then
				continue
			end

			-- Behind the camera plane — never.
			if not onScreen and viewDot < 0.35 then
				continue
			end

			local horizontallyOnScreen = math.abs(dx) <= maxDx

			if lookingDown then
				if not horizontallyOnScreen then
					continue
				end
				if flatAlign == nil or flatAlign < C.LOOK_DOWN_FORWARD_DOT then
					continue
				end
			else
				if not onScreen then
					continue
				end
				if viewDot < minLookDot then
					continue
				end
				if screenRadius > maxScreenRadius then
					continue
				end
				if math.abs(dx) > maxDx then
					continue
				end
			end

			local align = viewDot
			if flatAlign ~= nil then
				align = math.max(viewDot, flatAlign * (if lookingDown then 1.02 else 0.85))
			end
			if requireLineOfSight and not st.hasLineOfSight(part, attachWorld) then
				continue
			end

			local heightBonus = 0
			if attachWorld.Y > st.hrp.Position.Y + 5 then
				heightBonus = 0.05
			end

			-- Screen-center / look-ray dominance (what you're actually aiming at).
			local centerBias
			if lookingDown then
				centerBias = (1 - math.clamp(math.abs(dx) / maxDx, 0, 1)) * C.TARGET_SCORE_CENTER_LOOK_DOWN
			else
				centerBias = (1 - math.clamp(screenRadius / math.max(maxScreenRadius, 0.01), 0, 1))
					* C.TARGET_SCORE_CENTER
			end
			local lateralPenalty = math.abs(dx) * C.TARGET_SCORE_LATERAL
			local alongLook = math.max(toCameraTarget:Dot(look), 0.05)
			local onLookRay = camera.CFrame.Position + look * alongLook
			local worldLateral = (aimWorld - onLookRay).Magnitude
			lateralPenalty += (worldLateral / math.max(dist, 8)) * C.TARGET_SCORE_LATERAL_WORLD

			-- Tiny sticky bias only — never enough to beat a clearly aimed vine.
			local stickBonus = 0
			if part == st.highlightedTarget or part == st.scannedVisualTarget then
				stickBonus = if lookingDown then 0.2 else 0.04
			end

			local nearScale = math.max(
				C.TARGET_SCORE_PREFER_NEAR_STUDS,
				math.max(reach, 1) * C.TARGET_SCORE_PREFER_NEAR_REACH_FRAC
			)
			local distancePenalty = (dist / nearScale) * C.TARGET_SCORE_DIST_WEIGHT
			-- Extra push so high reach can't crown a max-range vine over the first one in view.
			if dist > nearScale then
				distancePenalty += ((dist - nearScale) / math.max(reach - nearScale, 1)) * 3.2
			end
			local nearAimBonus = (1 - math.clamp(dist / nearScale, 0, 1)) * C.TARGET_SCORE_NEAR_AIM_BONUS
			if viewDot >= 0.82 and screenRadius < 0.28 then
				nearAimBonus *= 1.35
			end
			local frontDepth = st.nearestLookDepthOnPart(part)
			local alignPower = align * align * math.max(align, 0)
			local screenLockBonus = 0
			if screenRadius <= C.TARGET_SCREEN_LOCK_RADIUS then
				screenLockBonus = C.TARGET_SCREEN_LOCK_BONUS * (1 - screenRadius / C.TARGET_SCREEN_LOCK_RADIUS)
			end
			if part == st.lastCameraRayTarget then
				screenLockBonus += C.TARGET_CAMERA_RAY_BONUS
			end

			local score = alignPower * C.TARGET_SCORE_ALIGN
				+ heightBonus
				+ centerBias
				+ stickBonus
				+ nearAimBonus
				+ screenLockBonus
				- distancePenalty
				- lateralPenalty
				- (frontDepth / math.max(nearScale, 1)) * 2.8

			-- Prefer nearer vines when scores are close (high reach must not skip first vine).
			local better = score > bestScore + 0.08
			if not better and math.abs(score - bestScore) <= 0.35 then
				local bestDist = if best then (st.closestAttachWorldOnPart(best) - st.hrp.Position).Magnitude else math.huge
				if dist + 4 < bestDist then
					better = true
				elseif frontDepth + C.TARGET_DEPTH_TIE_EPS < bestFrontDepth then
					better = true
				elseif math.abs(dist - bestDist) <= 4 and screenRadius + 0.02 < bestScreenR then
					better = true
				elseif
					math.abs(frontDepth - bestFrontDepth) <= C.TARGET_DEPTH_TIE_EPS
					and screenRadius + 0.02 < bestScreenR
				then
					better = true
				end
			elseif not better and math.abs(score - bestScore) <= 0.08 then
				if frontDepth + C.TARGET_DEPTH_TIE_EPS < bestFrontDepth then
					better = true
				elseif math.abs(frontDepth - bestFrontDepth) <= C.TARGET_DEPTH_TIE_EPS and screenRadius + 0.02 < bestScreenR then
					better = true
				end
			end
			if better then
				bestScore = score
				bestScreenR = screenRadius
				bestFrontDepth = frontDepth
				best = part
			end
		end

		return best
	end

	function st.getAirborneTargetUiRange()
		return getLatchRange()
	end

	function st.targetDistanceAndPoint(target)
		if not target or not target.Parent then
			return nil, nil
		end
		if target:IsDescendantOf(st.character) then
			return nil, nil
		end

		local attachWorld = st.closestAttachWorldOnPart(target)
		if attachWorld.Y < st.hrp.Position.Y + C.MIN_TARGET_HEIGHT_OFFSET then
			return nil, nil
		end

		return (attachWorld - st.hrp.Position).Magnitude, attachWorld
	end

	function st.pickNearbySwingTarget(maxDistance, preferredTarget)
		if st.isHrpInSafezone() then
			return nil, nil, nil
		end
		camera = workspace.CurrentCamera or camera

		local function validCandidate(target)
			local dist, point = st.targetDistanceAndPoint(target)
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
		for _, part in ipairs(st.getCandidateTargets(maxDistance)) do
			local dist, point = validCandidate(part)
			if dist and dist < bestDist then
				best = part
				bestDist = dist
				bestPoint = point
			end
		end

		return best, bestDist, bestPoint
	end

	function st.pickVisualSwingTarget(
		readyDistance,
		maxDistance,
		preferredTarget,
		showSafezoneBlocked,
		minLookDot,
		maxScreenRadius
	)
		local inSafezone = st.isHrpInSafezone()
		if inSafezone and not showSafezoneBlocked then
			return nil, false
		end
		camera = workspace.CurrentCamera or camera
		minLookDot = minLookDot or C.MIN_LOOK_DOT
		maxScreenRadius = maxScreenRadius or C.TARGET_SCREEN_RADIUS_LIMIT
		local lookingDown = camera ~= nil and camera.CFrame.LookVector.Y <= C.LOOK_DOWN_PITCH

		local function passesVisibleChecks(target, distanceLimit)
			local limit = math.min(distanceLimit, st.getEffectiveLatchLimit(target))
			return st.isVisibleSwingTarget(target, limit, minLookDot)
		end

		local function passesAttachChecks(target, distanceLimit)
			local limit = math.min(distanceLimit, st.getEffectiveLatchLimit(target))
			return st.isSpecificSwingTargetReady(target, false, limit, minLookDot, maxScreenRadius)
		end

		local function preferredStillForward(target)
			local dist, point = st.targetDistanceAndPoint(target)
			if not dist or not point then
				return false
			end
			local flatTo = flatUnit(point - st.hrp.Position)
			local face = (camera and flatUnit(camera.CFrame.LookVector)) or flatUnit(st.hrp.CFrame.LookVector)
			if not flatTo or not face then
				return false
			end
			return flatTo:Dot(face) >= C.LOOK_DOWN_FORWARD_DOT
		end

		-- Looking down for swing control: cling to the current forward vine instead of
		-- re-picking whatever sits near screen-center (often a left/side vine).
		if lookingDown and preferredTarget and not inSafezone then
			if passesVisibleChecks(preferredTarget, maxDistance) and preferredStillForward(preferredTarget) then
				return preferredTarget, passesAttachChecks(preferredTarget, readyDistance)
			end
		end

		local lookedTarget = nil
		if not inSafezone then
			lookedTarget = st.pickSwingTarget(false, maxDistance, minLookDot, maxScreenRadius)
		end
		if lookedTarget and passesVisibleChecks(lookedTarget, maxDistance) then
			return lookedTarget, (not inSafezone) and passesAttachChecks(lookedTarget, readyDistance)
		end

		if preferredTarget and passesVisibleChecks(preferredTarget, maxDistance) then
			if not lookingDown or preferredStillForward(preferredTarget) then
				return preferredTarget, (not inSafezone) and passesAttachChecks(preferredTarget, readyDistance)
			end
		end

		-- Fallback: camera-aim score, never "nearest vine wins".
		local best = nil
		local bestScore = -math.huge
		local depthCutoff = st.getFrontLookDepthCutoff(maxDistance, minLookDot)
		local function considerVisual(part: BasePart?)
			if not part then
				return
			end
			if st.isBehindFrontSwingDepth(part, maxDistance, depthCutoff, minLookDot) then
				return
			end
			local limit = st.getEffectiveLatchLimit(part)
			local dist, point = st.targetDistanceAndPoint(part)
			if dist and point and dist >= 2 and dist <= limit and passesVisibleChecks(part, limit) then
				local score = st.attachCandidateScore(part, dist, point, limit)
				if score > bestScore then
					best = part
					bestScore = score
				end
			end
		end
		for _, part in ipairs(st.getCandidateTargets(maxDistance)) do
			considerVisual(part)
		end
		considerVisual(st.returnSwingTarget)

		return best, best ~= nil and not inSafezone and passesAttachChecks(best, readyDistance)
	end

	function st.attachCandidateScore(target, dist, point, maxDistance)
		camera = workspace.CurrentCamera or camera

		if target:IsA("BasePart") then
			local depthCutoff = st.getFrontLookDepthCutoff(maxDistance, C.MIN_LOOK_DOT)
			if st.isBehindFrontSwingDepth(target, maxDistance, depthCutoff, C.MIN_LOOK_DOT) then
				return -1000
			end
		end

		-- Camera / screen-center first, but high reach must still prefer the nearer vine.
		local nearCap = math.max(
			C.TARGET_SCORE_PREFER_NEAR_STUDS,
			math.max(maxDistance, 1) * C.TARGET_SCORE_PREFER_NEAR_REACH_FRAC
		)
		local nearAlpha = 1 - math.clamp(dist / nearCap, 0, 1)
		local score = nearAlpha * nearAlpha * 5.5
		local aimWorld = if target:IsA("BasePart") then st.aimPointOnPart(target) else point
		local toTargetFlat = flatUnit(aimWorld - st.hrp.Position)

		if camera then
			local look = camera.CFrame.LookVector
			local lookFlat = flatUnit(look)
			local camFlat = flatUnit(aimWorld - camera.CFrame.Position)
			if lookFlat and camFlat then
				local lookDot = camFlat:Dot(lookFlat)
				if lookDot < C.TARGET_SCORE_BEHIND_REJECT then
					return -1000
				end
				score += math.max(0, lookDot) ^ 3 * 5.5
			end
			local dx, _dy, screenR, viewDot, onScreen = st.getScreenAimMetrics(aimWorld)
			if viewDot < -0.05 then
				return -1000
			end
			score += math.max(0, viewDot) ^ 3 * 4.0
			local toCam = aimWorld - camera.CFrame.Position
			local depth = toCam:Dot(look)
			local frontDepth = if target:IsA("BasePart") then st.nearestLookDepthOnPart(target) else depth
			if toCam.Magnitude > 0.5 then
				local along = math.max(depth, 0.05)
				local onRay = camera.CFrame.Position + look * along
				local lateral = (aimWorld - onRay).Magnitude
				score -= (lateral / math.max(dist, 8)) * C.TARGET_SCORE_LATERAL_WORLD
				-- Depth along look: nearer vines in the cone beat far centered ones.
				score -= (math.max(frontDepth, 0) / math.max(nearCap, 1)) * 3.6
				if maxDistance > 120 and dist > nearCap then
					score -= ((dist - nearCap) / math.max(maxDistance - nearCap, 1)) * 5.5
				end
			end
			if not onScreen then
				score -= 5.0
			else
				score -= math.abs(dx) * C.TARGET_SCORE_LATERAL
				score -= screenR * 4.5
				if screenR <= C.TARGET_SCREEN_LOCK_RADIUS then
					score += C.TARGET_SCREEN_LOCK_BONUS * (1 - screenR / C.TARGET_SCREEN_LOCK_RADIUS)
				end
			end
		end

		local moveFlat = flatUnit(st.humanoid.MoveDirection)
		if not moveFlat then
			moveFlat = flatUnit(st.hrp.AssemblyLinearVelocity)
		end
		-- Move direction is a weak hint only — never let strafe steal aim from look.
		if moveFlat and toTargetFlat then
			local moveAlpha = math.clamp((toTargetFlat:Dot(moveFlat) + 1) * 0.5, 0, 1)
			score += moveAlpha * 0.05
		end

		if target == st.lastReleasedTarget and os.clock() - st.lastReleasedTargetClock < 0.9 then
			local returnGrace = target == st.returnSwingTarget
			if not returnGrace then
				score -= 0.95
			end
		end
		if target == st.returnSwingTarget then
			score += 0.8
		end
		if target == st.lastCameraRayTarget then
			score += C.TARGET_CAMERA_RAY_BONUS
		end
		if target == st.scannedVisualTarget then
			score += 0.1
		elseif target == st.highlightedTarget then
			score += 0.05
		end

		return score
	end

	function st.pickAttachSwingTarget(maxDistance, minLookDot, maxScreenRadius)
		if st.isHrpInSafezone() then
			return nil
		end
		camera = workspace.CurrentCamera or camera

		local lookDot = minLookDot or C.MIN_LOOK_DOT
		local screenLimit = maxScreenRadius or C.TARGET_SCREEN_RADIUS_LIMIT

		-- Hard prefer whatever is under / nearest the crosshair.
		local rayHit = st.pickCameraLookSwingTarget(maxDistance)
		st.lastCameraRayTarget = rayHit
		if rayHit and st.canAttachToSwingTarget(rayHit, maxDistance, lookDot, screenLimit) then
			return rayHit
		end

		local lookedTarget = st.pickSwingTarget(false, maxDistance, lookDot, screenLimit)
		if lookedTarget and st.canAttachToSwingTarget(lookedTarget, maxDistance, lookDot, screenLimit) then
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

			if not st.canAttachToSwingTarget(target, maxDistance, minLookDot, maxScreenRadius) then
				return
			end

			local dist, point = st.targetDistanceAndPoint(target)
			if not dist or dist < 2 or dist > maxDistance then
				return
			end

			local score = st.attachCandidateScore(target, dist, point, maxDistance)
			if score > bestScore then
				bestScore = score
				best = target
			end
		end

		if st.scannedVisualCanSwing then
			consider(st.scannedVisualTarget)
		end
		consider(st.highlightedTarget)
		consider(st.lastReleasedTarget)
		consider(st.returnSwingTarget)
		for _, part in ipairs(st.getCandidateTargets(maxDistance)) do
			consider(part)
		end
		-- Far return vine may be outside the normal candidate grid — still try it.
		if st.returnSwingTarget then
			consider(st.returnSwingTarget)
		end

		return best
	end

	function st.isVisibleSwingTarget(target, maxDistance, minLookDot)
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent or st.isHrpInSafezone() then
			return false
		end
		if not target or not target.Parent then
			return false
		end

		local dist, attachWorld = st.targetDistanceAndPoint(target)
		local reach = maxDistance
		if not dist or dist < 2 or dist > reach then
			return false
		end

		local isReturnGrace = st.isReturnSwingTarget(target)
			and st.isAirborneForSwing()
			and not st.hasFloorSupportForSwing()
			and dist > getSwingRange() * 0.9
		local look = camera.CFrame.LookVector
		local lookingDown = look.Y <= C.LOOK_DOWN_PITCH
		minLookDot = minLookDot or C.MIN_LOOK_DOT
		if isReturnGrace then
			minLookDot = math.min(minLookDot, -0.15)
		end
		local toCameraTarget = attachWorld - camera.CFrame.Position
		if toCameraTarget.Magnitude < 0.5 then
			return false
		end

		local flatDir = flatUnit(attachWorld - st.hrp.Position)
		local face = flatUnit(look) or flatUnit(st.hrp.CFrame.LookVector)
		local minFlat = if isReturnGrace then -0.35 else C.TARGET_SCORE_BEHIND_REJECT
		if flatDir and face and flatDir:Dot(face) < minFlat then
			return false
		end

		local vp = camera:WorldToViewportPoint(attachWorld)
		if vp.Z <= 0 and not isReturnGrace then
			return false
		end

		if lookingDown then
			local lookDownFlat = if isReturnGrace then minFlat else C.LOOK_DOWN_FORWARD_DOT
			if not flatDir or not face or flatDir:Dot(face) < lookDownFlat then
				return false
			end
		elseif toCameraTarget.Unit:Dot(look) < minLookDot then
			return false
		end

		return true
	end

	function st.isReturnSwingTarget(target: BasePart?): boolean
		return target ~= nil and target == st.returnSwingTarget and target.Parent ~= nil
	end

	function st.getAttachReachForTarget(target: BasePart?): number
		local base = getSwingRange()
		if st.isReturnSwingTarget(target) then
			return math.min(C.RETURN_SWING_MAX_DIST, math.max(base * C.RETURN_SWING_REACH_MULT, base + C.RETURN_SWING_REACH_BONUS))
		end
		return base
	end

	-- Shared UI+press latch distance. Return-vine grace is air-only — on ground it caused
	-- green prompts past what jump would accept.
	function st.getEffectiveLatchLimit(target: BasePart?): number
		local base = getLatchRange()
		if
			target
			and st.isReturnSwingTarget(target)
			and st.isAirborneForSwing()
			and not st.hasFloorSupportForSwing()
		then
			return math.max(base, st.getAttachReachForTarget(target))
		end
		return base
	end

	function st.clearReturnSwingTarget()
		st.returnSwingTarget = nil
	end

	function st.isSpecificSwingTargetReady(
		target,
		requireLineOfSight,
		maxDistanceOverride,
		minLookDotOverride,
		maxScreenRadiusOverride
	)
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent or st.isHrpInSafezone() then
			return false
		end

		local dist, attachWorld = st.targetDistanceAndPoint(target)
		local baseReach = getSwingRange()
		local reach = maxDistanceOverride or st.getAttachReachForTarget(target)
		if not dist or dist < 2 or dist > reach then
			return false
		end

		local isReturnGrace = st.isReturnSwingTarget(target)
			and st.isAirborneForSwing()
			and not st.hasFloorSupportForSwing()
			and dist > baseReach * 0.9
		local isCameraRayHit = target == st.lastCameraRayTarget
		local look = camera.CFrame.LookVector
		local lookingDown = look.Y <= C.LOOK_DOWN_PITCH
		local minLookDot = minLookDotOverride or C.MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or C.TARGET_SCREEN_RADIUS_LIMIT
		if isReturnGrace then
			minLookDot = math.min(minLookDot, -0.15)
			maxScreenRadius = math.max(maxScreenRadius, 1.15)
		end
		local toCameraTarget = attachWorld - camera.CFrame.Position
		if toCameraTarget.Magnitude < 0.5 then
			return false
		end

		local flatDir = flatUnit(attachWorld - st.hrp.Position)
		local faceFlat = flatUnit(look) or flatUnit(st.hrp.CFrame.LookVector)
		local flatAlign = if flatDir and faceFlat then flatDir:Dot(faceFlat) else nil
		local minFlat = if isReturnGrace then -0.35 else C.TARGET_SCORE_BEHIND_REJECT
		if flatAlign ~= nil and flatAlign < minFlat then
			return false
		end

		-- Crosshair ray already proved this vine is under the look — don't fail on screen edge.
		if isCameraRayHit then
			if requireLineOfSight and not st.hasLineOfSight(target, attachWorld) then
				return false
			end
			return true
		end

		if lookingDown then
			if flatAlign == nil or flatAlign < (if isReturnGrace then minFlat else C.LOOK_DOWN_FORWARD_DOT) then
				return false
			end
		elseif toCameraTarget.Unit:Dot(look) < minLookDot then
			return false
		end

		local viewportPoint, onScreen = camera:WorldToViewportPoint(attachWorld)
		local vp = camera.ViewportSize
		local dx = (viewportPoint.X - vp.X * 0.5) / math.max(vp.X, 1)
		local dy = (viewportPoint.Y - vp.Y * 0.5) / math.max(vp.Y, 1)
		local maxDx = if isReturnGrace then 0.92 else C.TARGET_MAX_SCREEN_DX
		local horizontallyOnScreen = viewportPoint.Z > 0 and math.abs(dx) <= maxDx

		if lookingDown then
			if not horizontallyOnScreen then
				return false
			end
		else
			if viewportPoint.Z <= 0 then
				return false
			end
			if not onScreen and not isReturnGrace then
				return false
			end
			if isReturnGrace then
				if viewportPoint.Z <= 0 and not horizontallyOnScreen then
					return false
				end
			elseif math.sqrt(dx * dx + dy * dy) > maxScreenRadius then
				return false
			elseif math.abs(dx) > maxDx then
				return false
			end
		end

		if requireLineOfSight and not st.hasLineOfSight(target, attachWorld) then
			return false
		end

		return true
	end

	function st.isAirborneForSwing()
		local state = st.humanoid:GetState()
		if
			state == Enum.HumanoidStateType.Freefall
			or state == Enum.HumanoidStateType.Jumping
			or state == Enum.HumanoidStateType.FallingDown
		then
			return true
		end
		if st.humanoid.FloorMaterial == Enum.Material.Air and st.hrp.AssemblyLinearVelocity.Y < 5 then
			return true
		end
		return st.isAirborne
	end

	function st.hasFloorSupportForSwing(): boolean
		if st.humanoid.FloorMaterial ~= Enum.Material.Air then
			return true
		end
		-- Short ray so a real jump leaves "floor support" quickly (land mesh Air + long ray
		-- kept press attach on grounded limits and forced a second jump).
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { st.character }
		local hit = workspace:Raycast(st.hrp.Position, Vector3.new(0, -3.15, 0), params)
		return hit ~= nil
	end

	function st.isGroundedForSwing()
		if st.isSwinging or st.isLaunched or st.isAirborneForSwing() then
			return false
		end
		if st.hasFloorSupportForSwing() then
			return true
		end

		local state = st.humanoid:GetState()
		return state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed
			or state == Enum.HumanoidStateType.None
	end

	function st.getSwingAttachLimits()
		local range = getLatchRange()
		if st.isAirborneForSwing() and not st.hasFloorSupportForSwing() then
			return range, C.AIRBORNE_TARGET_LOOK_DOT, C.TARGET_SCREEN_RADIUS_LIMIT
		end
		-- Standing / land / ambiguous — NEVER return nil (that forced jump-then-grapple).
		return range, C.GROUNDED_TARGET_LOOK_DOT, C.GROUNDED_TARGET_SCREEN_RADIUS_LIMIT
	end

	-- Press latch: same latch range as UI ready (rope-capped).
	function st.getSwingPressAttachLimits()
		local range = getLatchRange()
		return range, C.AIRBORNE_TARGET_LOOK_DOT, C.TARGET_SCREEN_RADIUS_LIMIT
	end

	function st.canAttachToSwingTarget(target, attachLimit, minLookDot, maxScreenRadius)
		if not target or not target.Parent or not attachLimit then
			return false
		end
		local reach = math.min(attachLimit, st.getEffectiveLatchLimit(target))
		return st.isSpecificSwingTargetReady(target, false, reach, minLookDot, maxScreenRadius)
	end

	function st.isGroundedForCameraAssist()
		if not C.ENABLE_GROUNDED_CAMERA_ASSIST then
			return false
		end
		return st.isGroundedForSwing()
	end

	function st.closestGroundCameraTarget()
		if not st.isGroundedForCameraAssist() then
			return nil, nil
		end

		camera = workspace.CurrentCamera or camera
		if not camera or not st.targetVisualShown or not st.highlightedTarget or not st.highlightedTarget.Parent then
			return nil, nil
		end

		local point = st.highlightedPoint or st.closestAttachWorldOnPart(st.highlightedTarget)
		if (point - st.hrp.Position).Magnitude > C.CAMERA_ASSIST_RANGE then
			return nil, nil
		end

		local toPoint = point - camera.CFrame.Position
		if toPoint.Magnitude < 0.5 then
			return nil, nil
		end
		if camera.CFrame.LookVector:Dot(toPoint.Unit) < C.CAMERA_ASSIST_MIN_LOOK_DOT then
			return nil, nil
		end
		if not st.hasLineOfSight(st.highlightedTarget, point) then
			return nil, nil
		end

		return st.highlightedTarget, point
	end

	function st.isHoldToSwingMode()
		-- Default off: press jump to latch, press again to release.
		return player:GetAttribute("HoldToSwingEnabled") == true
	end

	function st.holdIsActive()
		if isSwingInputBlocked() then
			return false
		end
		-- Toggle mode: once swinging, stay latched without holding jump.
		if not st.isHoldToSwingMode() and st.isSwinging then
			return true
		end
		return st.spaceHeld
			or st.gamepadHeld
			or safeIsKeyDown(Enum.KeyCode.Space)
			or safeIsKeyDown(Enum.KeyCode.ButtonA)
			or safeIsKeyDown(Enum.KeyCode.ButtonR2)
			or (
				UserInputService.TouchEnabled
				and (st.mobileJumpHeld or (os.clock() <= st.mobileJumpHoldUntil and os.clock() <= st.mobileRealJumpPressUntil))
			)
	end

	function st.readyPromptText()
		if not st.isHoldToSwingMode() then
			if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
				return "[PRESS JUMP] TO SWING"
			end
			if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
				return "[PRESS R2] TO SWING"
			end
			return "[PRESS SPACE] TO SWING"
		end
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
			return "[HOLD JUMP] TO SWING"
		end
		if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
			return "[HOLD R2] TO SWING"
		end
		return "[HOLD SPACE] TO SWING"
	end

	function st.tryReleaseSwingFromJump()
		if not st.isSwinging then
			return false
		end
		-- Same held jump that attached — wait for a fresh press.
		if not st.isHoldToSwingMode() and st.toggleNeedsJumpRelease then
			return false
		end
		local released = false
		if st.pendingSwingParams and not st.ropeConstraint then
			st.stopSwing(false)
			released = true
		elseif os.clock() - st.lastAttachClock > C.MIN_SWING_LOCK_TIME then
			st.stopSwing(true)
			released = true
		end
		if released and not st.isHoldToSwingMode() then
			-- Consume this jump press so we don't instantly latch onto another vine.
			st.toggleNeedsJumpRelease = true
			-- Kill press-intent retries — release must not auto-grab the next vine.
			st.swingPressIntentUntil = -1e9
		end
		return released
	end

	function st.clearToggleJumpLatch()
		st.toggleNeedsJumpRelease = false
	end

	function st.isToggleAttachBlocked(): boolean
		return not st.isHoldToSwingMode() and st.toggleNeedsJumpRelease == true
	end

	function st.noteJumpPressed()
		local now = os.clock()
		local freshGroundJump = now - st.lastGroundJumpClock <= 0.2 and now - st.airborneStartedClock <= 0.2
		if st.isAirborneForSwing() and not freshGroundJump then
			return true
		else
			st.lastGroundJumpClock = now
			return false
		end
	end

	function st.forwardInputAmount()
		camera = workspace.CurrentCamera or camera
		local moveDir = st.humanoid.MoveDirection
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
		facing = facing or flatUnit(st.hrp.CFrame.LookVector)
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

	function st.cleanupWorkspaceHelpersByName(name, keep)
		for _, obj in ipairs(workspace:GetChildren()) do
			if obj.Name == name and obj ~= keep then
				obj:Destroy()
			end
		end
	end

	function st.makeVisualAnchor(name)
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
		task.defer(st.cleanupWorkspaceHelpersByName, name, part)
		return part
	end

	function st.ensurePreviewObjects()
		if not st.previewAnchorPart or not st.previewAnchorPart.Parent then
			st.previewAnchorPart = st.makeVisualAnchor("SwingPreviewAnchor")
		end
		if not st.previewFrom or not st.previewFrom.Parent then
			st.previewFrom = Instance.new("Attachment")
			st.previewFrom.Name = "SwingPreviewFrom"
			st.previewFrom.Position = Vector3.new(0, 0.8, 0)
			st.previewFrom.Parent = st.hrp
		end
		if not st.previewTo or not st.previewTo.Parent then
			st.previewTo = Instance.new("Attachment")
			st.previewTo.Name = "SwingPreviewTo"
			st.previewTo.Parent = st.previewAnchorPart
		end
		if not st.previewBeam or not st.previewBeam.Parent then
			st.previewBeam = Instance.new("Beam")
			st.previewBeam.Name = "SwingPreviewBeam"
			st.previewBeam.Attachment0 = st.previewFrom
			st.previewBeam.Attachment1 = st.previewTo
			st.previewBeam.Width0 = 0.08
			st.previewBeam.Width1 = 0.06
			st.previewBeam.LightEmission = 0.35
			st.previewBeam.FaceCamera = true
			st.previewBeam.Segments = 1
			st.previewBeam.Color = ColorSequence.new(C.PREVIEW_COLOR)
			st.previewBeam.Transparency = NumberSequence.new(1)
			st.previewBeam.Enabled = false
			st.previewBeam.Parent = st.character
			st.lastPreviewFadeBucket = -1
			st.lastPreviewColor = nil
		end
	end

	function st.hidePreview()
		st.previewFadeGoal = 0
		st.previewFade = 0
		st.previewTarget = nil
		st.lastPreviewFadeBucket = -1
		if st.previewBeam then
			st.previewBeam.Enabled = false
			st.previewBeam.Transparency = NumberSequence.new(1)
		end
	end

	function st.destroyPreview(force)
		st.hidePreview()
		if not force then
			return
		end
		if st.previewBeam then
			st.previewBeam:Destroy()
			st.previewBeam = nil
		end
		if st.previewFrom then
			st.previewFrom:Destroy()
			st.previewFrom = nil
		end
		if st.previewTo then
			st.previewTo:Destroy()
			st.previewTo = nil
		end
		if st.previewAnchorPart then
			st.previewAnchorPart:Destroy()
			st.previewAnchorPart = nil
		end
		st.previewTarget = nil
		st.lastPreviewFadeBucket = -1
		st.lastPreviewColor = nil
	end

	st.previewTransparency = function(alpha)
		alpha = math.clamp(alpha, 0, 1)
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1 - alpha * 0.82),
			NumberSequenceKeypoint.new(0.5, 1 - alpha * 0.35),
			NumberSequenceKeypoint.new(1, 1 - alpha * 0.82),
		})
	end

	function st.applyPreviewVisual()
		if not st.previewBeam then
			return
		end
		if st.isHrpInSafezone() or st.previewFade <= 0.01 then
			st.previewBeam.Enabled = false
			return
		end

		local beamColor = st.targetReadyGoal > 0.5 and st.targetVisualColor:Lerp(C.PREVIEW_COLOR, 0.45) or C.NOT_READY_COLOR
		if not st.previewBeam.Enabled then
			st.previewBeam.Enabled = true
		end

		local fadeBucket = math.clamp(math.floor(st.previewFade * 30 + 0.5), 0, 30)
		if fadeBucket ~= st.lastPreviewFadeBucket then
			st.previewBeam.Transparency = st.previewTransparency(fadeBucket / 30)
			st.lastPreviewFadeBucket = fadeBucket
		end

		local colorChanged = not st.lastPreviewColor
			or math.abs(st.lastPreviewColor.R - beamColor.R) > 0.02
			or math.abs(st.lastPreviewColor.G - beamColor.G) > 0.02
			or math.abs(st.lastPreviewColor.B - beamColor.B) > 0.02
		if colorChanged then
			st.previewBeam.Color = ColorSequence.new(beamColor)
			st.lastPreviewColor = beamColor
		end
	end

	function st.resolveUiAttachWorld(target)
		if not target or not target.Parent then
			return nil
		end
		return resolveLockedSwingAttachWorld(target)
	end

	function st.updatePreview(target)
		if st.isHrpInSafezone() or st.isSwinging or not target or not target.Parent then
			st.hidePreview()
			return
		end

		local attachWorld = st.resolveUiAttachWorld(target)
		if not attachWorld then
			st.hidePreview()
			return
		end
		st.ensurePreviewObjects()
		if st.previewTarget ~= target then
			st.previewTarget = target
		end

		st.previewAnchorPart.CFrame = CFrame.new(attachWorld)
		st.previewTo.Position = Vector3.new(0, 0, 0)
		st.applyPreviewVisual()
	end

	function st.ensureTargetHighlight()
		if not C.ENABLE_TARGET_HIGHLIGHT then
			return nil
		end
		if st.targetHighlight and st.targetHighlight.Parent and st.targetHighlight:IsA("Highlight") then
			return st.targetHighlight
		end

		task.defer(st.cleanupWorkspaceHelpersByName, "SwingTargetHighlightProxy", nil)

		local existing = workspace:FindFirstChild("SwingTargetHighlight")
		if existing and not existing:IsA("Highlight") then
			existing:Destroy()
			existing = nil
		end

		st.targetHighlight = existing or Instance.new("Highlight")
		st.targetHighlight.Name = "SwingTargetHighlight"
		st.targetHighlight.FillColor = Color3.fromRGB(38, 138, 58)
		st.targetHighlight.OutlineColor = C.READY_COLOR
		st.targetHighlight.FillTransparency = C.TARGET_HIGHLIGHT_FILL_TRANSPARENCY
		st.targetHighlight.OutlineTransparency = 0
		st.targetHighlight.Enabled = false
		pcall(function()
			st.targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
		end)
		st.targetHighlight.Parent = workspace
		task.defer(st.cleanupWorkspaceHelpersByName, "SwingTargetHighlight", st.targetHighlight)
		st.targetHighlightAdornee = nil
		st.lastHighlightColor = nil
		st.lastHighlightFillTransparency = nil
		st.targetHighlightProxyPart = nil
		return st.targetHighlight
	end

	function st.resolveTargetHighlightAdornee(target)
		if not target or not target.Parent then
			return nil
		end
		if target:IsDescendantOf(st.character) then
			return nil
		end

		local vine = target.Parent
		if not vine or vine == workspace or vine:IsDescendantOf(st.character) then
			return nil
		end
		return vine
	end

	function st.clearTargetHighlight()
		if not st.targetHighlight then
			return
		end
		st.targetHighlight.Enabled = false
	end

	function st.updateTargetHighlight(target)
		local highlight = st.ensureTargetHighlight()
		if not highlight then
			return
		end

		if not target or st.isSwinging then
			st.clearTargetHighlight()
			return
		end

		if
			st.targetHighlightAdornee
			and st.targetHighlightAdornee.Parent
			and st.lastVisualTarget == target
			and highlight.Enabled
		then
			return
		end

		local adornee = st.resolveTargetHighlightAdornee(target)
		if not adornee then
			st.clearTargetHighlight()
			return
		end

		if st.targetHighlightAdornee ~= adornee then
			highlight.Adornee = adornee
			st.targetHighlightAdornee = adornee
		end
		if not highlight.Enabled then
			highlight.Enabled = true
		end
	end

	function st.setTargetHighlightColor(canSwingNow)
		if not st.targetHighlight or not st.targetHighlight.Enabled then
			return
		end
		local color = canSwingNow and C.READY_COLOR or C.NOT_READY_COLOR
		local colorChanged = not st.lastHighlightColor
			or math.abs(st.lastHighlightColor.R - color.R) > 0.015
			or math.abs(st.lastHighlightColor.G - color.G) > 0.015
			or math.abs(st.lastHighlightColor.B - color.B) > 0.015
		if colorChanged then
			st.targetHighlight.FillColor = canSwingNow and Color3.fromRGB(38, 138, 58) or Color3.fromRGB(138, 38, 38)
			st.targetHighlight.OutlineColor = color
			st.lastHighlightColor = color
		end
		local fillTransparency = C.TARGET_HIGHLIGHT_FILL_TRANSPARENCY
		if not st.lastHighlightFillTransparency or math.abs(st.lastHighlightFillTransparency - fillTransparency) > 0.015 then
			st.targetHighlight.FillTransparency = fillTransparency
			st.targetHighlight.OutlineTransparency = 0
			st.lastHighlightFillTransparency = fillTransparency
		end
	end

	function st.hideMarkerVisualNow()
		if st.markerAnchorPart then
			st.markerAnchorPart.CFrame = CFrame.new(C.TARGET_VISUAL_HIDDEN_POSITION)
		end
		if st.markerGui and not st.markerGui.Enabled then
			st.markerGui.Enabled = true
		end
		if st.markerLabel then
			st.markerLabel.TextTransparency = 1
			st.markerLabel.TextStrokeTransparency = 1
		end
		if st.markerStroke then
			st.markerStroke.Transparency = 1
		end
		if st.markerDot then
			st.markerDot.BackgroundTransparency = 1
		end
	end

	function st.ensureVisuals()
		st.ensureTargetHighlight()

		if not st.markerAnchorPart or not st.markerAnchorPart.Parent then
			st.markerAnchorPart = st.makeVisualAnchor("SwingMarkerAnchor")
			st.markerAnchorPart.CFrame = CFrame.new(C.TARGET_VISUAL_HIDDEN_POSITION)
		end

		if not st.markerGui then
			local playerGui = player:WaitForChild("PlayerGui")
			st.markerGui = Instance.new("BillboardGui")
			st.markerGui.Name = "SwingTargetMarker"
			st.markerGui.Size = UDim2.fromOffset(148, 102)
			st.markerGui.AlwaysOnTop = true
			st.markerGui.LightInfluence = 0
			st.markerGui.MaxDistance = 320
			st.markerGui.Enabled = true
			st.markerGui.Adornee = st.markerAnchorPart
			st.markerGui.Parent = playerGui

			local ring = Instance.new("Frame")
			ring.Name = "Ring"
			ring.Size = UDim2.fromOffset(42, 42)
			ring.Position = UDim2.new(0.5, -21, 0.5, -21)
			ring.BackgroundTransparency = 1
			ring.BorderSizePixel = 0
			ring.Parent = st.markerGui
			st.markerRing = ring

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = ring

			local stroke = Instance.new("UIStroke")
			stroke.Color = C.READY_COLOR
			stroke.Thickness = 2
			stroke.Transparency = 1
			stroke.Parent = ring
			st.markerStroke = stroke

			local dot = Instance.new("Frame")
			dot.Name = "Dot"
			dot.Size = UDim2.fromOffset(9, 9)
			dot.Position = UDim2.new(0.5, -4.5, 0.5, -4.5)
			dot.BackgroundColor3 = C.READY_COLOR
			dot.BackgroundTransparency = 1
			dot.BorderSizePixel = 0
			dot.Parent = ring
			st.markerDot = dot

			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot

			st.markerLabel = Instance.new("TextLabel")
			st.markerLabel.Name = "Label"
			st.markerLabel.Size = UDim2.new(1, 0, 0, 30)
			st.markerLabel.Position = UDim2.new(0, 0, 0.5, 28)
			st.markerLabel.BackgroundTransparency = 1
			if UiFonts then
				UiFonts.applyDisplayLabel(st.markerLabel, 15, 11)
			else
				st.markerLabel.FontFace = Font.fromEnum(Enum.Font.GothamBold)
				st.markerLabel.TextSize = 15
			end
			st.markerLabel.TextColor3 = C.READY_COLOR
			st.markerLabel.TextTransparency = 1
			st.markerLabel.TextStrokeTransparency = 1
			st.markerLabel.Text = "[HOLD SPACE] TO SWING"
			st.markerLabel.Parent = st.markerGui
		end
	end

	function st.updateTargetVisual(target, canSwingNow, inactiveText)
		st.ensureVisuals()

		-- Only show when jump can latch (no out-of-range AIM tease).
		if target and not st.isSwinging and canSwingNow == true then
			local attachWorld = st.resolveUiAttachWorld(target)
			if not attachWorld then
				return nil
			end
			st.targetReadyGoal = 1
			st.previewFadeGoal = 1
			st.highlightedTarget = target
			st.highlightedPoint = attachWorld
			st.targetVisualShown = true

			st.updateTargetHighlight(target)
			st.setTargetHighlightColor(true)
			st.markerAnchorPart.CFrame = CFrame.new(attachWorld)
			if st.markerGui.Adornee ~= st.markerAnchorPart then
				st.markerGui.Adornee = st.markerAnchorPart
			end
			if st.markerGui.StudsOffset ~= Vector3.new(0, 0, 0) then
				st.markerGui.StudsOffset = Vector3.new(0, 0, 0)
			end
			if not st.markerGui.Enabled then
				st.markerGui.Enabled = true
			end

			local text = st.readyPromptText()
			if st.lastMarkerText ~= text then
				st.markerLabel.Text = text
				st.lastMarkerText = text
			end
			st.updatePreview(target)
			player:SetAttribute("SwingPromptReady", true)
			st.lastVisualTarget = target
			st.lastVisualCanSwing = true

			return attachWorld
		end

		st.targetReadyGoal = 0
		st.previewFadeGoal = 0
		st.targetVisualColor = C.NOT_READY_COLOR
		player:SetAttribute("SwingPromptReady", false)
		if not st.targetVisualShown and not st.highlightedTarget then
			st.clearTargetHighlight()
			st.hidePreview()
			return nil
		end
		st.clearTargetHighlight()
		st.highlightedTarget = nil
		st.highlightedPoint = nil
		st.targetVisualShown = false
		st.hideMarkerVisualNow()
		st.lastVisualTarget = nil
		st.lastVisualCanSwing = nil
		st.hidePreview()
		return nil
	end

	function st.hideSwingTargetUi()
		st.lastTargetScanMode = "none"
		st.scannedVisualTarget = nil
		st.scannedVisualCanSwing = false
		st.targetVisualShown = false
		st.highlightedTarget = nil
		st.highlightedPoint = nil
		st.lastVisualTarget = nil
		st.lastVisualCanSwing = nil
		player:SetAttribute("SwingPromptReady", false)
		st.clearTargetHighlight()
		st.hideMarkerVisualNow()
		st.hidePreview()
	end

	function st.stepTargetVisual(dt)
		st.targetVisualStepAccum += dt
		if st.targetVisualStepAccum < C.TARGET_VISUAL_STEP_INTERVAL then
			return
		end
		dt = st.targetVisualStepAccum
		st.targetVisualStepAccum = 0

		local colorAlpha = math.clamp(dt * C.TARGET_VISUAL_SMOOTH_SPEED, 0, 1)
		local fadeAlpha = math.clamp(dt * C.PREVIEW_FADE_SPEED, 0, 1)

		st.targetReadyVisual += (st.targetReadyGoal - st.targetReadyVisual) * colorAlpha
		st.previewFade += (st.previewFadeGoal - st.previewFade) * fadeAlpha
		if math.abs(st.previewFade - st.previewFadeGoal) < 0.01 then
			st.previewFade = st.previewFadeGoal
		end

		st.targetVisualColor = C.NOT_READY_COLOR:Lerp(C.READY_COLOR, math.clamp(st.targetReadyVisual, 0, 1))

		if st.targetVisualShown and st.markerGui and st.markerLabel then
			local pulse = math.sin(os.clock() * 7) * 0.5 + 0.5
			local readyBob = math.sin(os.clock() * C.READY_TEXT_BOB_SPEED)
				* C.READY_TEXT_BOB_PIXELS
				* math.clamp(st.targetReadyVisual, 0, 1)
			st.markerLabel.TextColor3 = st.targetVisualColor
			st.markerLabel.TextTransparency = 0
			st.markerLabel.TextStrokeTransparency = 0.35
			st.markerLabel.Position = UDim2.new(0, 0, 0.5, 28 - readyBob)

			if st.markerStroke then
				st.markerStroke.Color = st.targetVisualColor
				st.markerStroke.Transparency = 0
			end
			if st.markerDot then
				st.markerDot.BackgroundColor3 = st.targetVisualColor
				st.markerDot.BackgroundTransparency = 0.05 + pulse * 0.38
			end
		end

		if st.previewBeam then
			st.applyPreviewVisual()
		end
	end

	task.defer(function()
		task.wait(0.05)
		if not st.hrp.Parent then
			return
		end
		st.ensureVisuals()
		st.cleanupWorkspaceHelpersByName("SwingTargetHighlightProxy", nil)
		st.ensurePreviewObjects()
		st.hidePreview()
		st.hideMarkerVisualNow()
		st.applyPreviewVisual()
	end)

	function st.destroyChargeGui()
		if st.chargeGui then
			st.chargeGui:Destroy()
			st.chargeGui = nil
			st.chargeDot = nil
		end
		st.swingCharge = 0
	end

	function st.ensureChargeGui(target)
		if st.chargeGui or not target then
			return
		end

		local playerGui = player:WaitForChild("PlayerGui")
		st.chargeGui = Instance.new("BillboardGui")
		st.chargeGui.Name = "SwingHoldCharge"
		st.chargeGui.Adornee = target
		st.chargeGui.Size = UDim2.fromOffset(96, 70)
		st.chargeGui.StudsOffset = Vector3.new(0, target.Size.Y * 0.5 + 0.9, 0)
		st.chargeGui.AlwaysOnTop = true
		st.chargeGui.LightInfluence = 0
		st.chargeGui.Parent = playerGui

		local ring = Instance.new("Frame")
		ring.Size = UDim2.fromOffset(46, 46)
		ring.Position = UDim2.new(0.5, -23, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Parent = st.chargeGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring

		local stroke = Instance.new("UIStroke")
		stroke.Color = C.READY_COLOR
		stroke.Thickness = 2.4
		stroke.Transparency = 0.05
		stroke.Parent = ring

		st.chargeDot = Instance.new("Frame")
		st.chargeDot.Size = UDim2.fromOffset(8, 8)
		st.chargeDot.Position = UDim2.new(0.5, -4, 0.5, -4)
		st.chargeDot.BackgroundColor3 = C.READY_COLOR
		st.chargeDot.BorderSizePixel = 0
		st.chargeDot.Parent = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = st.chargeDot
	end

	function st.layoutCharge()
		if not st.chargeDot then
			return
		end
		local px = 8 + 34 * math.clamp(st.swingCharge, 0, 1)
		st.chargeDot.Size = UDim2.fromOffset(px, px)
		st.chargeDot.Position = UDim2.new(0.5, -px * 0.5, 0.5, -px * 0.5)
	end

	function st.spawnSwingRopeVisual(attachWorld, onLatch)
		local side = st.currentHangSide or "Right"
		local hand = st.handPartForSide(side)

		if st.handAttachment then
			st.handAttachment:Destroy()
			st.handAttachment = nil
		end
		st.handAttachment = setupHandThrowAttachment(hand, st.hrp, side)

		st.hidePreview()

		if st.swingRopeVisual then
			local old = st.swingRopeVisual
			st.swingRopeVisual = nil

			if old.ShootConn then
				old.ShootConn:Disconnect()
			end

			if old.Tween then
				pcall(function()
					old.Tween:Cancel()
				end)
			end

			if old.TweenConn then
				old.TweenConn:Disconnect()
			end

			for _, inst in pairs(old) do
				if typeof(inst) == "Instance" and inst.Parent then
					inst:Destroy()
				end
			end
		end

		local function makeVisualPart(name, worldPos)
			local part = Instance.new("Part")
			part.Name = name
			part.Size = Vector3.new(0.15, 0.15, 0.15)
			part.Transparency = 1
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.CFrame = CFrame.new(worldPos)
			part.Parent = workspace
			return part
		end

		local startHandWorld = st.handAttachment.WorldPosition
		spawnThrowLaunchVfx(startHandWorld)

		local handPart = makeVisualPart("SwingRopeHandVisualAnchor", startHandWorld)
		local tipPart = makeVisualPart("SwingRopeTipVisualAnchor", startHandWorld)
		local anchorPart = makeVisualPart("SwingRopeAnchorVisualAnchor", attachWorld)

		local handVisualAttachment = Instance.new("Attachment")
		handVisualAttachment.Name = "SwingRopeVisualHandAttachment"
		handVisualAttachment.Parent = handPart

		local tipVisualAttachment = Instance.new("Attachment")
		tipVisualAttachment.Name = "SwingRopeVisualTipAttachment"
		tipVisualAttachment.Parent = tipPart

		local anchorVisualAttachment = Instance.new("Attachment")
		anchorVisualAttachment.Name = "SwingRopeVisualAnchorAttachment"
		anchorVisualAttachment.Parent = anchorPart

		local throwBeam = Instance.new("Beam")
		throwBeam.Name = "SwingThrowBeam"
		throwBeam.Attachment0 = handVisualAttachment
		throwBeam.Attachment1 = tipVisualAttachment
		throwBeam.Width0 = C.ROPE_THROW_BEAM_WIDTH0
		throwBeam.Width1 = C.ROPE_THROW_BEAM_WIDTH1
		throwBeam.LightEmission = C.ROPE_THROW_BEAM_LIGHT
		throwBeam.FaceCamera = true
		throwBeam.Segments = 12
		throwBeam.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.55, C.ROPE_THROW_BEAM_COLOR),
			ColorSequenceKeypoint.new(1, C.ROPE_THROW_BEAM_TIP_COLOR),
		})
		throwBeam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.02),
			NumberSequenceKeypoint.new(1, 0.12),
		})
		throwBeam.Parent = handPart

		local hookHead = Instance.new("Part")
		hookHead.Name = "SwingRopeHookHead"
		hookHead.Size = C.ROPE_THROW_HOOK_SIZE
		hookHead.Anchored = false
		hookHead.CanCollide = false
		hookHead.CanTouch = false
		hookHead.CanQuery = false
		hookHead.CastShadow = false
		hookHead.Material = Enum.Material.Neon
		hookHead.Color = Color3.fromRGB(255, 255, 255)
		hookHead.Transparency = 0.02
		hookHead.Parent = tipPart

		local hookWeld = Instance.new("WeldConstraint")
		hookWeld.Part0 = tipPart
		hookWeld.Part1 = hookHead
		hookWeld.Parent = hookHead

		local trailA0 = Instance.new("Attachment")
		trailA0.Name = "SwingHookTrailA0"
		trailA0.Position = Vector3.new(0, 0, hookHead.Size.Z * 0.22)
		trailA0.Parent = hookHead

		local trailA1 = Instance.new("Attachment")
		trailA1.Name = "SwingHookTrailA1"
		trailA1.Position = Vector3.new(0, 0, -hookHead.Size.Z * 0.22)
		trailA1.Parent = hookHead

		local hookTrail = Instance.new("Trail")
		hookTrail.Name = "SwingHookTrail"
		hookTrail.Attachment0 = trailA0
		hookTrail.Attachment1 = trailA1
		hookTrail.Lifetime = C.ROPE_THROW_TRAIL_LIFE
		hookTrail.MinLength = 0.02
		hookTrail.LightEmission = 1
		hookTrail.FaceCamera = true
		hookTrail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, C.ROPE_THROW_BEAM_TIP_COLOR),
		})
		hookTrail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.08),
			NumberSequenceKeypoint.new(1, 1),
		})
		hookTrail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		hookTrail.Parent = hookHead

		local shootDistance = (attachWorld - startHandWorld).Magnitude
		local shootTime = math.clamp(
			shootDistance / C.ROPE_VISUAL_SHOOT_SPEED,
			C.ROPE_VISUAL_SHOOT_MIN_TIME,
			C.ROPE_VISUAL_SHOOT_MAX_TIME
		)

		local visualState = {
			HandPart = handPart,
			TipPart = tipPart,
			AnchorPart = anchorPart,
			TargetAttachWorld = attachWorld,

			HandAttachment = handVisualAttachment,
			TipAttachment = tipVisualAttachment,
			AnchorAttachment = anchorVisualAttachment,

			ThrowBeam = throwBeam,
			Rope = nil,
			HookHead = hookHead,
			OnLatch = onLatch,
			Locked = false,
			LatchFired = false,
			ShootStart = os.clock(),
			ShootTime = shootTime,
			ShootConn = nil,
		}

		st.swingRopeVisual = visualState

		local throwSignal = C.PRE_SIMULATION_SIGNAL or RunService.RenderStepped

		local function stepThrowVisual()
			if st.swingRopeVisual ~= visualState then
				if visualState.ShootConn then
					visualState.ShootConn:Disconnect()
					visualState.ShootConn = nil
				end
				return
			end

			if not st.handAttachment or not st.handAttachment.Parent then
				return
			end

			local handWorld = st.handAttachment.WorldPosition
			local anchorWorld = st.lockedAttachWorld or visualState.TargetAttachWorld

			if visualState.HandPart then
				visualState.HandPart.CFrame = CFrame.new(handWorld)
			end

			if visualState.AnchorPart then
				visualState.AnchorPart.CFrame = CFrame.new(anchorWorld)
			end

			local elapsed = os.clock() - visualState.ShootStart
			local alpha = math.clamp(elapsed / visualState.ShootTime, 0, 1)
			local tipWorld = getThrowArcWorldPos(handWorld, anchorWorld, alpha)

			if visualState.TipPart then
				local lookDir = anchorWorld - tipWorld
				if lookDir.Magnitude > 0.05 then
					visualState.TipPart.CFrame = CFrame.lookAt(tipWorld, tipWorld + lookDir.Unit)
				else
					visualState.TipPart.CFrame = CFrame.new(tipWorld)
				end
			end

			if visualState.ThrowBeam then
				local pulse = 0.82 + 0.18 * math.sin(elapsed * 34)
				visualState.ThrowBeam.Width0 = C.ROPE_THROW_BEAM_WIDTH0 * pulse
				visualState.ThrowBeam.Width1 = C.ROPE_THROW_BEAM_WIDTH1 * (0.9 + 0.1 * pulse)
			end

			local tipDistance = (anchorWorld - tipWorld).Magnitude
			local throwFinished = alpha >= 1 and elapsed >= visualState.ShootTime * 0.98
			local tipAtTarget = tipDistance <= C.ROPE_THROW_LATCH_DISTANCE

			if throwFinished and tipAtTarget and not visualState.LatchFired then
				visualState.LatchFired = true
				visualState.Locked = true

				if visualState.ShootConn then
					visualState.ShootConn:Disconnect()
					visualState.ShootConn = nil
				end

				if visualState.TipPart then
					visualState.TipPart.CFrame = CFrame.new(anchorWorld)
				end

				if visualState.ThrowBeam then
					visualState.ThrowBeam:Destroy()
					visualState.ThrowBeam = nil
				end

				if visualState.HookHead and visualState.HookHead.Parent then
					visualState.HookHead:Destroy()
					visualState.HookHead = nil
				end

				if visualState.TipPart then
					visualState.TipPart:Destroy()
					visualState.TipPart = nil
					visualState.TipAttachment = nil
				end

				local visualRope = Instance.new("RopeConstraint")
				visualRope.Name = "SwingVisualRopeConstraint"
				visualRope.Attachment0 = visualState.HandAttachment
				visualRope.Attachment1 = visualState.AnchorAttachment
				visualRope.Length = math.max((anchorWorld - handWorld).Magnitude + 0.03, C.ROPE_VISUAL_MIN_LENGTH)
				visualRope.Thickness = C.ROPE_VISUAL_LOCKED_THICKNESS
				visualRope.Visible = true
				visualRope.Restitution = 0
				visualRope.Parent = visualState.HandPart
				pcall(function()
					visualRope.Color = C.ROPE_LOCKED_BRICK_COLOR
				end)
				visualState.Rope = visualRope

				spawnRopeLatchVfx(anchorWorld)

				local latchCallback = visualState.OnLatch
				visualState.OnLatch = nil
				if latchCallback then
					latchCallback(anchorWorld)
				end
			end
		end

		visualState.ShootConn = throwSignal:Connect(stepThrowVisual)
		stepThrowVisual()
	end

	function st.updateSwingRopeVisual(anchorWorld)
		local visualState = st.swingRopeVisual
		if not visualState or not st.handAttachment or not st.handAttachment.Parent then
			return
		end

		local anchorPos = st.lockedAttachWorld or anchorWorld or visualState.TargetAttachWorld

		local handWorld = st.handAttachment.WorldPosition

		if visualState.HandPart then
			visualState.HandPart.CFrame = CFrame.new(handWorld)
		end

		if visualState.AnchorPart then
			visualState.AnchorPart.CFrame = CFrame.new(anchorPos)
		end

		if visualState.ThrowBeam then
			return
		end

		if not visualState.Rope then
			return
		end

		if visualState.Locked then
			local distance = (anchorPos - handWorld).Magnitude
			local speed = st.hrp.AssemblyLinearVelocity.Magnitude

			local speedSagAlpha = math.clamp(
				(speed - C.ROPE_VISUAL_IDLE_STRAIGHT_SPEED)
					/ math.max(C.ROPE_VISUAL_FULL_SAG_SPEED - C.ROPE_VISUAL_IDLE_STRAIGHT_SPEED, 1),
				0,
				1
			)

			local momentumSagAlpha = math.clamp((st.swingMomentum or 0) * 0.32, 0, 1)
			local sagAlpha = math.max(speedSagAlpha, momentumSagAlpha)

			visualState.Rope.Length = math.max(distance + C.ROPE_VISUAL_SAG * sagAlpha, C.ROPE_VISUAL_MIN_LENGTH)
		end
	end

	function st.destroySwingObjects()
		st.pendingSwingParams = nil
		st.lockedAttachWorld = nil
		if st.swingRopeVisual then
			local visualState = st.swingRopeVisual
			st.swingRopeVisual = nil

			if visualState.ShootConn then
				visualState.ShootConn:Disconnect()
				visualState.ShootConn = nil
			end

			if visualState.Tween then
				pcall(function()
					visualState.Tween:Cancel()
				end)
			end

			if visualState.TweenConn then
				visualState.TweenConn:Disconnect()
			end

			for _, inst in pairs(visualState) do
				if typeof(inst) == "Instance" and inst.Parent then
					inst:Destroy()
				end
			end
		end
		if st.handAttachment then
			st.handAttachment:Destroy()
			st.handAttachment = nil
		end
		if st.steerForce then
			st.steerForce:Destroy()
			st.steerForce = nil
		end
		if st.swingOrientation then
			st.swingOrientation:Destroy()
			st.swingOrientation = nil
		end
		if st.orientationAttachment then
			st.orientationAttachment:Destroy()
			st.orientationAttachment = nil
		end
		if st.forceAttachment then
			st.forceAttachment:Destroy()
			st.forceAttachment = nil
		end
		if st.ropeConstraint then
			st.ropeConstraint:Destroy()
			st.ropeConstraint = nil
		end
		st.activeRopeMaxLength = nil
		st.ropeCatchUntil = -1e9
		st.ropeCatchStartLength = nil
		if st.zipSpring then
			st.zipSpring:Destroy()
			st.zipSpring = nil
		end
		if st.anchorAttachment then
			st.anchorAttachment:Destroy()
			st.anchorAttachment = nil
		end
		if st.bodyAttachment then
			st.bodyAttachment:Destroy()
			st.bodyAttachment = nil
		end
		st.swingFaceDir = nil
		st.destroyChargeGui()
	end

	function st.floorScale(anchorWorld, ropeLength)
		st.rayParams.FilterDescendantsInstances = { st.character }
		local hit = workspace:Raycast(st.hrp.Position, Vector3.new(0, -130, 0), st.rayParams)
		local floorY = hit and hit.Position.Y or (st.hrp.Position.Y - 80)
		local hangCap = math.min((ropeLength or getRopeMaxLength()) * 0.55, C.ROPE_MAX_HANG_DEPTH)
		local minSafeY = math.max(floorY + C.FLOOR_CLEARANCE, anchorWorld.Y - hangCap)
		local margin = st.hrp.Position.Y - minSafeY
		if margin <= 0 then
			return 0.18
		end
		if margin < 10 then
			return math.clamp(margin / 10, 0.2, 1)
		end
		return 1
	end

	function st.applyAttachBoost(attachWorld)
		camera = workspace.CurrentCamera or camera
		if not camera then
			return
		end

		st.hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		local velocity = st.hrp.AssemblyLinearVelocity
		local fromAnchor = st.hrp.Position - attachWorld
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
			st.hrp:ApplyImpulse(tangent.Unit * getZipDv() * st.hrp.AssemblyMass)
		end
	end

	function st.finalizeSwingAttach(target, ropeMax, startLength, elasticRestLength, attachWorld)
		if not st.isSwinging or not target or not target.Parent then
			return
		end

		attachWorld = st.lockedAttachWorld or attachWorld
		local dist = (attachWorld - st.hrp.Position).Magnitude

		st.pendingSwingParams = nil
		st.lastAttachClock = os.clock()
		st.attachShakeStrength = 0.82
		st.attachShakeSeed = math.random() * 1000
		st.swingTimer = 0
		st.activeRopeMaxLength = ropeMax
		st.returnSwingTarget = nil

		st.ropeCatchStartLength = startLength
		st.ropeCatchUntil = os.clock() + C.ROPE_CATCH_ELASTIC_TIME

		st.anchorAttachment = Instance.new("Attachment")
		st.anchorAttachment.Name = "SwingAnchorAttachment"
		st.anchorAttachment.Position = target.CFrame:PointToObjectSpace(attachWorld)
		st.anchorAttachment.Parent = target

		st.bodyAttachment = Instance.new("Attachment")
		st.bodyAttachment.Name = "SwingBodyAttachment"
		st.bodyAttachment.Parent = st.hrp

		st.ropeConstraint = Instance.new("RopeConstraint")
		st.ropeConstraint.Name = "SwingRopeConstraint"
		st.ropeConstraint.Attachment0 = st.anchorAttachment
		st.ropeConstraint.Attachment1 = st.bodyAttachment
		st.ropeConstraint.Length = startLength
		st.ropeConstraint.Thickness = 0.08
		st.ropeConstraint.Visible = false
		st.ropeConstraint.Restitution = 0.05
		st.ropeConstraint.Parent = st.hrp

		pcall(function()
			st.ropeConstraint.WinchEnabled = true
			st.ropeConstraint.WinchResponsiveness = 46
			st.ropeConstraint.WinchSpeed = C.ROPE_HANG_PULL_WINCH_SPEED * C.ROPE_CATCH_REEL_MULT
			st.ropeConstraint.WinchForce = st.hrp.AssemblyMass * 3000 * C.ROPE_CATCH_FORCE_MULT
			st.ropeConstraint.WinchTarget = startLength
		end)

		if math.abs(dist - elasticRestLength) > 1.5 then
			st.zipSpring = Instance.new("SpringConstraint")
			st.zipSpring.Name = "SwingZipSpring"
			st.zipSpring.Attachment0 = st.anchorAttachment
			st.zipSpring.Attachment1 = st.bodyAttachment
			st.zipSpring.FreeLength = startLength
			st.zipSpring.Stiffness = C.ZIP_SPRING_STIFFNESS * 0.72
			st.zipSpring.Damping = C.ZIP_SPRING_DAMPING * 1.12
			st.zipSpring.MaxForce = st.hrp.AssemblyMass * C.ZIP_SPRING_MAX_ACCEL * C.ROPE_CATCH_FORCE_MULT
			st.zipSpring.Parent = st.hrp
		end

		st.forceAttachment = Instance.new("Attachment")
		st.forceAttachment.Name = "SwingForceAttachment"
		st.forceAttachment.Parent = st.hrp

		st.steerForce = Instance.new("VectorForce")
		st.steerForce.Name = "SwingSteerForce"
		st.steerForce.Attachment0 = st.forceAttachment
		st.steerForce.RelativeTo = Enum.ActuatorRelativeTo.World
		st.steerForce.ApplyAtCenterOfMass = true
		st.steerForce.Force = Vector3.new(0, 0, 0)
		st.steerForce.Parent = st.hrp

		st.orientationAttachment = Instance.new("Attachment")
		st.orientationAttachment.Name = "SwingOrientationAttachment"
		st.orientationAttachment.Parent = st.hrp

		st.swingOrientation = Instance.new("AlignOrientation")
		st.swingOrientation.Name = "SwingFaceDirection"
		st.swingOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
		st.swingOrientation.Attachment0 = st.orientationAttachment
		st.swingOrientation.RigidityEnabled = false
		st.swingOrientation.Responsiveness = C.AVATAR_TURN_RESPONSIVENESS
		st.swingOrientation.MaxTorque = st.hrp.AssemblyMass * 18000
		st.swingOrientation.Enabled = true
		st.swingOrientation.Parent = st.hrp

		st.humanoid.PlatformStand = true
		st.humanoid.AutoRotate = false
		st.humanoid.Jump = false
		st.hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		st.applyAttachBoost(attachWorld)
		st.playHangAnim(attachWorld)
		st.ensureChargeGui(target)
		playOptionalSound("Catch")
		playOptionalSound("Wind Loop")
	end

	function st.startSwing(target, trustReady: boolean?)
		if st.isWebTrapped() or st.isSwinging or not target or not target.Parent then
			return
		end
		if st.isHrpInSafezone() then
			return
		end

		local now = os.clock()
		if now - st.lastAttachClock < C.ATTACH_COOLDOWN then
			return
		end

		local attachLimit, minLookDot, maxScreenRadius = st.getSwingPressAttachLimits()
		if not attachLimit then
			return
		end

		local closestWorld = st.closestAttachWorldOnPart(target)
		local dist = (closestWorld - st.hrp.Position).Magnitude
		local latchLimit = math.min(attachLimit, st.getEffectiveLatchLimit(target))
		if dist < 2 or dist > latchLimit then
			return
		end

		-- UI already marked this vine ready — don't fail the press on a flaky re-aim check.
		if not trustReady then
			if not st.canAttachToSwingTarget(target, latchLimit, minLookDot, maxScreenRadius) then
				return
			end
		end

		local attachWorld = resolveLockedSwingAttachWorld(target)
		st.lockedAttachWorld = attachWorld
		st.advanceSwingHandSide()
		local _reach = getLatchRange()
		local baseRopeMax = getRopeMaxLength()
		local ropeRestLength = getRopeRestLength()

		-- Don't gate on Running vs Jumping vs FloorMaterial quirks — land meshes desync those.
		-- Distance + canAttach already validated the vine.

		st.releaseStyle.cancel()

		local ropeMaxFloor = math.max(C.ROPE_SAFE_MAX_MIN_LENGTH, C.ROPE_MIN_LENGTH + C.ROPE_HANG_PULL_MIN_GAP + 8)
		local flexScale = getRopeFlexScale()
		local ropeStretchFloor = math.min(baseRopeMax, ropeRestLength + C.ROPE_HANG_PULL_MIN_GAP)
		local ropeStretchCeiling = math.min(
			baseRopeMax,
			ropeRestLength
				+ C.ROPE_STRETCH_MAX_EXTRA * flexScale
				+ math.max(baseRopeMax - C.ROPE_MAX_LENGTH, 0) * 0.45
		)
		local ropeMax = math.min(C.ROPE_ABSOLUTE_MAX, math.max(ropeStretchFloor, ropeStretchCeiling, ropeMaxFloor))

		local elasticRestLength = math.clamp(ropeRestLength, C.ROPE_MIN_LENGTH, ropeMax)
		local normalStartLength =
			math.clamp(math.max(dist * C.ROPE_ATTACH_START_MULT, elasticRestLength), elasticRestLength, ropeMax)
		local elasticCatchStartLength =
			math.clamp(math.max(dist * C.ROPE_CATCH_START_MULT, normalStartLength), elasticRestLength, ropeMax)
		local startLength = elasticCatchStartLength

		st.isSwinging = true
		pcall(function()
			player:SetAttribute("IsSwinging", true)
		end)
		st.isLaunched = false
		st.landedFromSwing = false
		st.currentTarget = target
		-- Toggle: don't treat the still-held attach jump as a release.
		if not st.isHoldToSwingMode() then
			st.toggleNeedsJumpRelease = true
		else
			st.toggleNeedsJumpRelease = false
		end
		st.swingTimer = 0
		st.swingCharge = 0
		st.forwardSwingCharge = 0
		st.forwardHoldTime = 0
		st.swingMomentum = 0
		st.swingRhythmBoost = 0
		st.lastPumpInputSign = 0
		st.lastPumpSwitchClock = now
		st.swingFaceDir = nil

		st.pendingSwingParams = {
			target = target,
			ropeMax = ropeMax,
			startLength = startLength,
			elasticRestLength = elasticRestLength,
			attachWorld = attachWorld,
		}

		local flatFromAnchor = st.hrp.Position - attachWorld
		local flatRecoil = Vector3.new(flatFromAnchor.X, 0, flatFromAnchor.Z)
		if flatRecoil.Magnitude > 0.12 then
			st.hrp:ApplyImpulse(flatRecoil.Unit * C.ROPE_THROW_RECOIL_DV * st.hrp.AssemblyMass)
		end

		-- Attach immediately — throw VFX is cosmetic only (no latch wait).
		st.spawnSwingRopeVisual(attachWorld, function(_latchWorld) end)
		-- Toggle mode latches without requiring jump to stay held.
		if (not st.isHoldToSwingMode() or st.holdIsActive()) and target.Parent then
			st.finalizeSwingAttach(target, ropeMax, startLength, elasticRestLength, attachWorld)
		else
			st.stopSwing(false)
			return
		end

		st.updateTargetVisual(nil, false)
		playOptionalSound("Throw")
	end

	function st.stopSwing(doLaunch)
		if not st.isSwinging then
			return
		end

		local heldTime = st.swingTimer
		local charge = st.swingCharge
		local forwardCharge = st.forwardSwingCharge
		local forwardHeld = st.forwardHoldTime
		local releaseMomentum = st.swingMomentum
		local snapVelocity = st.hrp.AssemblyLinearVelocity
		local snapPosition = st.hrp.Position
		local snapAnchorWorld = st.anchorAttachment and st.anchorAttachment.Parent and st.anchorAttachment.WorldPosition or nil
		st.lastReleasedTarget = st.currentTarget
		st.lastReleasedTargetClock = os.clock()
		if doLaunch and st.currentTarget then
			st.returnSwingTarget = st.currentTarget
		end

		st.isSwinging = false
		pcall(function()
			player:SetAttribute("IsSwinging", false)
		end)
		st.currentTarget = nil
		st.toggleNeedsJumpRelease = false
		st.swingPressIntentUntil = -1e9
		st.scannedVisualTarget = nil
		st.scannedVisualCanSwing = false
		st.lastTargetScanClock = -1e9
		st.stopHangAnim(doLaunch and C.LAUNCH_HANG_RELEASE_FADE or 0.08)
		st.swingPose.clear()
		st.destroySwingObjects()
		-- Keep Wind Loop through air after a launch; only stop if the swing is cancelled.
		if not doLaunch then
			stopWindLoopSfx()
		end

		st.humanoid.PlatformStand = false
		st.humanoid.AutoRotate = true
		st.hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		if doLaunch then
			st.isLaunched = true
			st.landedFromSwing = true
			st.lastLaunchClock = os.clock()
			st.playFallingAnim(C.LAUNCH_FALL_ANIM_FADE)
			playOptionalSound("Launch")
			-- Ensure air wind keeps looping if Catch/Wind somehow missed on attach.
			local wind = resolveOptionalSound("Wind Loop")
			if wind and wind:IsA("Sound") and not wind.IsPlaying then
				playOptionalSound("Wind Loop")
			end
			if not st.isSwinging and st.hrp.Parent then
				camera = workspace.CurrentCamera or camera
				st.releaseStyle.apply(
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
			end
		else
			st.releaseStyle.cancel()
		end
	end

	if UserInputService.TouchEnabled then
		task.defer(function()
			local playerGui = player:WaitForChild("PlayerGui", 10)
			if not playerGui then
				return
			end

			local touchGui = playerGui:WaitForChild("TouchGui", 10)
			local touchFrame = touchGui and touchGui:WaitForChild("TouchControlFrame", 10)
			local jumpButton = touchFrame and touchFrame:WaitForChild("JumpButton", 10)

			if not jumpButton or not jumpButton:IsA("GuiButton") then
				return
			end

			function st.mobileJumpPressed()
				if isSwingInputBlocked() then
					return
				end
				local now = os.clock()

				st.mobileJumpHeld = true
				st.mobileJumpHoldUntil = now + C.MOBILE_JUMP_HOLD_GRACE
				st.mobileRealJumpPressUntil = now + C.MOBILE_REAL_JUMP_PRESS_WINDOW
				if not st.isHoldToSwingMode() and st.isSwinging then
					st.tryReleaseSwingFromJump()
					return
				end
				-- Only arm attach-intent when this press is trying to latch (not release).
				st.swingPressIntentUntil = now + 0.18
			end

			function st.mobileJumpReleased()
				st.mobileJumpHeld = false
				st.mobileJumpHoldUntil = -1e9
				st.mobileRealJumpPressUntil = -1e9
				st.clearToggleJumpLatch()

				-- Hold mode only: releasing jump launches. Toggle mode waits for next press.
				if st.isHoldToSwingMode() and st.isSwinging then
					st.tryReleaseSwingFromJump()
				end
			end

			st.addConn(jumpButton.MouseButton1Down:Connect(st.mobileJumpPressed))
			st.addConn(jumpButton.MouseButton1Up:Connect(st.mobileJumpReleased))

			st.addConn(jumpButton.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					st.mobileJumpPressed()
				end
			end))

			st.addConn(jumpButton.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then
					st.mobileJumpReleased()
				end
			end))
		end)
	end

	function st.updateSwingRopePhysics(
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
		if not st.ropeConstraint then
			return ropeLiftForce, velocity, speed
		end

		local restLength = math.clamp(getRopeRestLength(), C.ROPE_MIN_LENGTH, ropeMax)
		local flexScale = getRopeFlexScale()
		local stretchMinLength = math.min(ropeMax, restLength + C.ROPE_HANG_PULL_MIN_GAP)
		local stretchMaxLength = math.max(
			stretchMinLength,
			math.min(
				ropeMax,
				restLength + C.ROPE_STRETCH_MAX_EXTRA * flexScale + math.max(ropeMax - C.ROPE_MAX_LENGTH, 0) * 0.45
			)
		)
		-- Floor-aware hang cap: allow real stretch play, but never pay rope into void/kill depth.
		local maxPowerStretch = restLength + C.ROPE_STRETCH_MAX_EXTRA * flexScale
		st.rayParams.FilterDescendantsInstances = { st.character }
		local floorHit = workspace:Raycast(
			anchorWorld,
			Vector3.new(0, -(math.max(ropeMax, stretchMaxLength) + 40), 0),
			st.rayParams
		)
		local floorCap = math.min(maxPowerStretch, restLength + C.ROPE_MAX_HANG_DEPTH)
		if floorHit then
			-- Leave more hang room above floor so the rope still feels elastic.
			local floorRoom = (anchorWorld.Y - floorHit.Position.Y) - math.max(C.FLOOR_CLEARANCE * 0.55, 2.5)
			floorCap = math.min(
				floorCap,
				math.max(restLength + C.ROPE_HANG_PULL_MIN_GAP, floorRoom)
			)
		end
		stretchMaxLength = math.min(stretchMaxLength, floorCap)

		local moveAmount = st.humanoid.MoveDirection.Magnitude
		local idleHoldAlpha = 0
		if moveAmount < 0.06 and st.forwardSwingCharge < 0.08 then
			idleHoldAlpha = 1
		end
		local speedStretch = math.clamp((speed - 18) / math.max(speedCap - 18, 1), 0, 1)
		local stretchAlpha = math.clamp(st.swingMomentum * 0.58 + speedStretch * 0.24 + st.forwardSwingCharge * 0.12, 0, 1)
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
		local verticalDrop = math.max(anchorWorld.Y - st.hrp.Position.Y, 0)
		local pullStartLength = restLength + math.max(stretchMaxLength - restLength, 0) * C.ROPE_HANG_PULL_START_MULT
		local distanceSag = math.clamp((dist - pullStartLength) / math.max(stretchMaxLength - pullStartLength, 1), 0, 1)
		local heightSag = math.clamp((verticalDrop - restLength * 0.72) / math.max(restLength * 0.42, 1), 0, 1)
		local sagAlpha = math.max(distanceSag, heightSag)
		local closeEnoughMin = restLength
		local closeEnoughMax =
			math.max(closeEnoughMin, math.min(stretchMaxLength, restLength + C.ROPE_HANG_PULL_MIN_GAP))
		local baseCloseEnoughLength = math.clamp(ropeMax * C.ROPE_HANG_PULL_TARGET_MULT, closeEnoughMin, closeEnoughMax)

		local catchAlpha = 0
		if st.ropeCatchUntil > os.clock() then
			catchAlpha = math.clamp((st.ropeCatchUntil - os.clock()) / C.ROPE_CATCH_ELASTIC_TIME, 0, 1)
			-- Smoothstep so the catch starts soft and eases back into normal rope behavior.
			catchAlpha = catchAlpha * catchAlpha * (3 - 2 * catchAlpha)
		else
			st.ropeCatchStartLength = nil
		end

		local catchLength =
			math.clamp(st.ropeCatchStartLength or st.ropeConstraint.Length, baseCloseEnoughLength, stretchMaxLength)
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
		st.ropeConstraint.Length += (targetLength - st.ropeConstraint.Length) * math.clamp(
			dt * (idleHoldAlpha > 0.05 and C.ROPE_LENGTH_RESPONSE * 0.28 or C.ROPE_LENGTH_RESPONSE * 0.62),
			0,
			1
		)

		pcall(function()
			st.ropeConstraint.WinchTarget = closeEnoughLength
			st.ropeConstraint.WinchSpeed = (
				22
				+ st.swingCharge * 4
				+ st.swingMomentum * 2
				+ (C.ROPE_REEL_ALWAYS_ALPHA + sagAlpha * 0.8 + idleHoldAlpha * 0.18) * C.ROPE_HANG_PULL_WINCH_SPEED
			)
				* math.clamp(1 - stretchAlpha * (1 - idleHoldAlpha) * 0.68, 0.28, 1)
				* catchForceMult
			st.ropeConstraint.WinchForce = st.hrp.AssemblyMass
				* (3900 + sagAlpha * 2200 + idleHoldAlpha * 700)
				* math.clamp(1 - stretchAlpha * (1 - idleHoldAlpha) * 0.68, 0.28, 1)
				* catchForceMult
		end)

		if st.ropeConstraint.Length > stretchMaxLength then
			st.ropeConstraint.Length = stretchMaxLength
		elseif st.ropeConstraint.Length < closeEnoughLength then
			st.ropeConstraint.Length = closeEnoughLength
		end

		local pullGap = dist - closeEnoughLength
		local idleHangDrop = closeEnoughLength * 0.82
		local lowHang = verticalDrop > idleHangDrop + 1.25
		if pullGap > -C.ROPE_HANG_PULL_MIN_GAP * 0.35 or lowHang or idleHoldAlpha > 0.05 then
			local stallAlpha = math.clamp(1 - stretchAlpha * 0.42 + idleHoldAlpha * 0.16, 0.5, 1.12)
			local pullDir = -radial + Vector3.new(0, 0.58 + sagAlpha * 0.62 + idleHoldAlpha * 0.42, 0)
			local idlePullScale = 1
			if idleHoldAlpha > 0.05 then
				local idleTargetOffset = anchorWorld - Vector3.new(0, idleHangDrop, 0) - st.hrp.Position
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
				) * catchForceMult * upSpeedGate * mult * st.hrp.AssemblyMass
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
			if st.swingMomentum < 0.22 and st.forwardSwingCharge < 0.12 then
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
				st.hrp.AssemblyLinearVelocity = velocity
			end
		end

		return ropeLiftForce, velocity, speed
	end

	function st.tryAttach()
		if st.isWebTrapped() or st.isSwinging or not st.hrp.Parent then
			return
		end
		if isSwingInputBlocked() then
			return
		end
		-- Toggle: after releasing (or attaching), wait until jump is fully released before a new latch.
		if st.isToggleAttachBlocked() then
			return
		end

		local now = os.clock()
		if now - st.lastTryClock < C.ATTACH_RETRY_TIME then
			return
		end

		local maxDistance, lookDot, screenLimit = st.getSwingPressAttachLimits()
		if not maxDistance then
			return
		end
		local groundedAttempt = st.isGroundedForSwing() or st.hasFloorSupportForSwing()

		-- If the prompt already says ready, latch THAT vine — don't lose it to a re-pick miss.
		if st.scannedVisualCanSwing and st.scannedVisualTarget and st.scannedVisualTarget.Parent then
			local readyDist = select(1, st.targetDistanceAndPoint(st.scannedVisualTarget))
			local latchLimit = st.getEffectiveLatchLimit(st.scannedVisualTarget)
			if readyDist and readyDist >= 2 and readyDist <= latchLimit then
				st.lastTryClock = now
				st.humanoid.Jump = false
				st.startSwing(st.scannedVisualTarget, true)
				return
			end
		end

		-- Live pick on press — don't depend only on the last visual scan tick.
		local target = st.pickAttachSwingTarget(maxDistance, lookDot, screenLimit)
		if not target and st.scannedVisualTarget then
			local readyDist = select(1, st.targetDistanceAndPoint(st.scannedVisualTarget))
			local latchLimit = st.getEffectiveLatchLimit(st.scannedVisualTarget)
			if
				readyDist
				and readyDist >= 2
				and readyDist <= latchLimit
				and st.canAttachToSwingTarget(st.scannedVisualTarget, latchLimit, lookDot, screenLimit)
			then
				target = st.scannedVisualTarget
			end
		end
		if not target and st.highlightedTarget then
			local readyDist = select(1, st.targetDistanceAndPoint(st.highlightedTarget))
			local latchLimit = st.getEffectiveLatchLimit(st.highlightedTarget)
			if
				readyDist
				and readyDist >= 2
				and readyDist <= latchLimit
				and st.canAttachToSwingTarget(st.highlightedTarget, latchLimit, lookDot, screenLimit)
			then
				target = st.highlightedTarget
			end
		end
		if not target then
			if not (groundedAttempt and now - st.lastGroundJumpClock < 0.25) then
				st.lastTryClock = now
			end
			return
		end

		st.lastTryClock = now
		st.humanoid.Jump = false
		st.startSwing(target, false)
	end

	-- Mobile fallback removed to keep Luau boot() under the 200 local-register limit.

	if WebTrapConfig and typeof(WebTrapConfig.TRAPPED_ATTR) == "string" then
		st.addConn(player:GetAttributeChangedSignal(WebTrapConfig.TRAPPED_ATTR):Connect(function()
			if st.isWebTrapped() then
				if st.isSwinging then
					st.stopSwing(false)
				end
				st.isLaunched = false
				st.landedFromSwing = false
				stopWindLoopSfx()
				st.releaseStyle.cancel()
				st.hideSwingTargetUi()
			end
		end))
	end

	st.addConn(UserInputService.InputBegan:Connect(function(input, processed)
		if st.isWebTrapped() then
			return
		end

		if isSwingInputBlocked() or processed then
			st.spaceHeld = false
			st.gamepadHeld = false
			return
		end

		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Space then
			st.noteJumpPressed()
			if not st.isHoldToSwingMode() and st.isSwinging then
				st.tryReleaseSwingFromJump()
				return
			end
			if st.isToggleAttachBlocked() then
				st.spaceHeld = true
				return
			end
			st.spaceHeld = true
			-- Short grounded settle only — never a long air auto-latch window.
			if st.isGroundedForSwing() or st.hasFloorSupportForSwing() then
				st.swingPressIntentUntil = os.clock() + 0.18
			else
				st.swingPressIntentUntil = -1e9
			end
			st.tryAttach()
		elseif
			input.UserInputType == Enum.UserInputType.Gamepad1
			and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA)
		then
			st.noteJumpPressed()
			if not st.isHoldToSwingMode() and st.isSwinging then
				st.tryReleaseSwingFromJump()
				return
			end
			if st.isToggleAttachBlocked() then
				st.gamepadHeld = true
				return
			end
			st.gamepadHeld = true
			if st.isGroundedForSwing() or st.hasFloorSupportForSwing() then
				st.swingPressIntentUntil = os.clock() + 0.18
			else
				st.swingPressIntentUntil = -1e9
			end
			st.tryAttach()
		end
	end))

	st.addConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Space then
			st.spaceHeld = false
			st.clearToggleJumpLatch()
			if st.isHoldToSwingMode() and st.isSwinging then
				st.tryReleaseSwingFromJump()
			end
		elseif
			input.UserInputType == Enum.UserInputType.Gamepad1
			and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA)
		then
			st.gamepadHeld = false
			st.clearToggleJumpLatch()
			if st.isHoldToSwingMode() and st.isSwinging then
				st.tryReleaseSwingFromJump()
			end
		end
	end))

	st.addConn(UserInputService.JumpRequest:Connect(function()
		if st.isWebTrapped() then
			st.humanoid.Jump = false
			return
		end

		if isSwingInputBlocked() then
			st.humanoid.Jump = false
			st.spaceHeld = false
			st.gamepadHeld = false
			st.mobileJumpHeld = false
			return
		end

		local now = os.clock()
		local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

		if touchOnly then
			if not st.mobileJumpHeld and now > st.mobileRealJumpPressUntil then
				return
			end
			st.mobileJumpHoldUntil = now + C.MOBILE_JUMP_HOLD_GRACE
		end

		st.noteJumpPressed()

		if st.isSwinging then
			if not st.isHoldToSwingMode() then
				-- Holding jump after attach must not spam-release; only a fresh press does.
				st.tryReleaseSwingFromJump()
			end
			-- Always stop here while/after a swing jump — never fall through into tryAttach.
			return
		end

		if st.isToggleAttachBlocked() then
			return
		end

		-- Only steal the hop when a vine is actually latchable this press.
		local maxDistance, lookDot, screenLimit = st.getSwingPressAttachLimits()
		local liveTarget = nil
		-- Prefer UI-ready vine so green prompt always matches the jump press.
		if st.scannedVisualCanSwing and st.scannedVisualTarget and st.scannedVisualTarget.Parent then
			local readyDist = select(1, st.targetDistanceAndPoint(st.scannedVisualTarget))
			local latchLimit = st.getEffectiveLatchLimit(st.scannedVisualTarget)
			if readyDist and readyDist >= 2 and readyDist <= latchLimit then
				liveTarget = st.scannedVisualTarget
			end
		end
		if not liveTarget then
			liveTarget = st.pickAttachSwingTarget(maxDistance, lookDot, screenLimit)
		end
		if not liveTarget and st.highlightedTarget then
			local readyDist = select(1, st.targetDistanceAndPoint(st.highlightedTarget))
			local latchLimit = st.getEffectiveLatchLimit(st.highlightedTarget)
			if
				readyDist
				and readyDist >= 2
				and readyDist <= latchLimit
				and st.canAttachToSwingTarget(st.highlightedTarget, latchLimit, lookDot, screenLimit)
			then
				liveTarget = st.highlightedTarget
			end
		end
		local grounded = st.isGroundedForSwing() or st.hasFloorSupportForSwing()
		if liveTarget then
			st.humanoid.Jump = false
			if grounded then
				st.swingPressIntentUntil = now + 0.22
			else
				st.swingPressIntentUntil = -1e9
			end
		elseif touchOnly and grounded then
			-- Mobile ground with no latchable vine: allow a real jump.
			return
		elseif st.isAirborneForSwing() then
			st.humanoid.Jump = false
		end

		st.stopTrack(st.landedTrack, 0.08)
		st.humanoid.PlatformStand = false
		st.humanoid.AutoRotate = true
		if liveTarget and st.scannedVisualCanSwing and liveTarget == st.scannedVisualTarget then
			st.lastTryClock = now
			st.startSwing(liveTarget, true)
		else
			st.tryAttach()
		end
	end))

	if C.PRE_SIMULATION_SIGNAL then
		st.addConn(C.PRE_SIMULATION_SIGNAL:Connect(function(dt)
			st.swingPose.step(
				dt,
				st.hrp.AssemblyLinearVelocity,
				st.poseInputs.radial,
				st.poseInputs.moveFlatUnit,
				st.poseInputs.forwardInput,
				st.poseInputs.extT,
				st.poseInputs.momentum,
				st.currentHangSide,
				st.isSwinging and st.ropeConstraint ~= nil,
				st.isLaunched,
				st.landedFromSwing
			)
		end))
	else
		st.addConn(RunService.Stepped:Connect(function(_, dt)
			st.swingPose.step(
				dt,
				st.hrp.AssemblyLinearVelocity,
				st.poseInputs.radial,
				st.poseInputs.moveFlatUnit,
				st.poseInputs.forwardInput,
				st.poseInputs.extT,
				st.poseInputs.momentum,
				st.currentHangSide,
				st.isSwinging and st.ropeConstraint ~= nil,
				st.isLaunched,
				st.landedFromSwing
			)
		end))
	end

	st.addConn(st.humanoid.StateChanged:Connect(function(_, newState)
		if st.isSwingLandingRecoveryState(newState) then
			-- Fast angled landings can put the Humanoid into Roblox's get-up/ragdoll states.
			-- During swing launch recovery, skip that delay and immediately restore player control.
			if
				not st.isSwinging
				and (st.isLaunched or st.landedFromSwing or os.clock() - st.lastLaunchClock < C.LAUNCH_STYLE_TIME + 0.45)
			then
				local wasLandedFromSwing = st.landedFromSwing
				local impactSpeed = st.landingSpeed
				st.landedFromSwing = false
				st.isLaunched = false
				st.clearReturnSwingTarget()
				st.landingSpeed = 0
				st.isAirborne = false
				stopWindLoopSfx()
				st.forceSwingHumanoidControl()
				st.stopFallingAnim(C.LAUNCH_FALL_STOP_FADE)

				if wasLandedFromSwing and canPlaySwingLandingImpact(st.character, st.hrp, st.rayParams) then
					st.playLandedAnim()
					spawnLandingBlocks(st.character, st.hrp, st.rayParams, impactSpeed)
					playOptionalSound("GroundSmash")
					local impactAlpha = math.clamp((impactSpeed - 8) / 70, 0.58, 1)
					st.lastLandingClock = os.clock()
					st.landingShakeStrength = math.clamp(0.42 + impactAlpha * 0.86, 0, 1.22)
					st.landingShakeSeed = math.random() * 1000
				else
					st.stopTrack(st.landedTrack, 0.05)
				end
				st.hideSwingTargetUi()
				task.delay(C.SWING_LANDING_RECOVERY_DELAY, function()
					if st.humanoid.Parent and not st.isSwinging then
						st.forceSwingHumanoidControl()
					end
				end)
				return
			end
		elseif newState == Enum.HumanoidStateType.Freefall or newState == Enum.HumanoidStateType.Jumping then
			st.isAirborne = true
			st.airborneStartedClock = os.clock()
			if not st.isSwinging and (st.isLaunched or st.landedFromSwing) then
				st.playFallingAnim()
			end
		elseif newState == Enum.HumanoidStateType.Landed then
			st.isAirborne = false
			if st.isSwinging then
				return
			end

			local swingLanding = st.landedFromSwing or st.isLaunched
			local wasLandedFromSwing = st.landedFromSwing
			local impactSpeed = st.landingSpeed

			-- Clear the swing flags BEFORE playing the landing animation.
			-- Otherwise the landing auto-stop task can think the launch is still active and leave the clip running.
			st.landedFromSwing = false
			st.isLaunched = false
			st.clearReturnSwingTarget()
			st.landingSpeed = 0
			stopWindLoopSfx()

			st.forceSwingHumanoidControl()
			local solidGround = canPlaySwingLandingImpact(st.character, st.hrp, st.rayParams)
			if swingLanding and solidGround then
				st.playLandedAnim()
			end

			if wasLandedFromSwing and solidGround then
				spawnLandingBlocks(st.character, st.hrp, st.rayParams, impactSpeed)
				playOptionalSound("GroundSmash")
				local impactAlpha = math.clamp((impactSpeed - 8) / 70, 0.58, 1)
				st.lastLandingClock = os.clock()
				st.landingShakeStrength = math.clamp(0.42 + impactAlpha * 0.86, 0, 1.22)
				st.landingShakeSeed = math.random() * 1000
			end

			st.hideSwingTargetUi()
			task.delay(C.SWING_LANDING_RECOVERY_DELAY, function()
				if st.humanoid.Parent and not st.isSwinging then
					st.forceSwingHumanoidControl()
				end
			end)
		elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics then
			st.isAirborne = false
			if not st.isSwinging then
				st.clearReturnSwingTarget()
			end

			if not st.isSwinging then
				st.forceSwingHumanoidControl()
			end

			st.stopFallingAnim()

			local landingAnimRecentlyPlayed = os.clock() - st.lastLandedAnimClock < C.LAUNCH_LAND_MAX_PLAY_TIME
			if not landingAnimRecentlyPlayed then
				st.stopTrack(st.landedTrack, 0.08)
			end
		end
	end))

	st.addConn(st.humanoid.Died:Connect(function()
		if st.isSwinging then
			st.stopSwing(false)
		end
		st.isLaunched = false
		st.landedFromSwing = false
		st.landingSpeed = 0
		stopWindLoopSfx()
		st.lastLaunchClock = -1e9
		st.lastLandingClock = -1e9
		st.landingShakeStrength = 0
		st.releaseStyle.cancel()
		st.swingPose.clear()
		st.stopHangAnim(0)
		st.stopFallingAnim()
		st.stopTrack(st.landedTrack, 0.08)
		st.resetFovNow()
	end))

	RunService:BindToRenderStep(st.renderBindName, Enum.RenderPriority.Camera.Value + 1, function(dt)
		camera = workspace.CurrentCamera or camera
		if not camera or not st.hrp.Parent then
			return
		end

		local now = os.clock()
		local launchShakeActive = now - st.lastLaunchClock >= 0 and now - st.lastLaunchClock < C.LAUNCH_CAMERA_SHAKE_TIME
		local landingShakeActive = now - st.lastLandingClock >= 0 and now - st.lastLandingClock < C.LANDING_CAMERA_SHAKE_TIME
		local attachShakeActive = now - st.lastAttachClock >= 0 and now - st.lastAttachClock < C.ATTACH_CAMERA_SHAKE_TIME
		local swingCamBusy = st.isSwinging
			or st.isLaunched
			or launchShakeActive
			or landingShakeActive
			or attachShakeActive

		if
			not C.ENABLE_GROUNDED_CAMERA_ASSIST
			and not swingCamBusy
			and st.swingCamLag.Magnitude <= 0.001
			and math.abs(st.swingCamRoll) <= 0.0001
			and (st.windShakeIntensity or 0) <= 0.01
		then
			return
		end

		local cf = camera.CFrame
		local _, assistPoint = st.closestGroundCameraTarget()
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

		local velocity = st.hrp.AssemblyLinearVelocity
		local speed = velocity.Magnitude
		local targetRoll = 0
		local targetLag = Vector3.new(0, 0, 0)

		if st.isSwinging then
			local swingSpeedRef = math.max(getMaxSwingSpeed(), 1)
			local lateral = math.clamp(velocity:Dot(cf.RightVector) / swingSpeedRef, -1, 1)
			targetRoll = -lateral * C.SWING_CAMERA_ROLL_MAX
			targetLag = -cf.LookVector * math.clamp(speed / swingSpeedRef, 0, 1) * C.SWING_CAMERA_LAG_MAX
			targetLag += Vector3.new(0, math.clamp(-velocity.Y / 160, -0.18, 0.28), 0)
		elseif st.isLaunched then
			local lateral = math.clamp(velocity:Dot(cf.RightVector) / math.max(C.LAUNCH_SPEED_CAP, 1), -1, 1)
			targetRoll = -lateral * C.SWING_CAMERA_ROLL_MAX * 0.55
		end

		local smooth = math.min(dt * C.SWING_CAMERA_EFFECT_SPEED, 1)
		st.swingCamRoll += (targetRoll - st.swingCamRoll) * smooth
		st.swingCamLag = st.swingCamLag:Lerp(targetLag, smooth)

		if st.swingCamLag.Magnitude > 0.001 or math.abs(st.swingCamRoll) > 0.0001 then
			local pos = cf.Position + st.swingCamLag
			cf = CFrame.lookAt(pos, pos + cf.LookVector, cf.UpVector) * CFrame.Angles(0, 0, st.swingCamRoll)
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

		local launchAge = now - st.lastLaunchClock
		if launchAge >= 0 and launchAge < C.LAUNCH_CAMERA_SHAKE_TIME then
			local speedAlpha = math.clamp(speed / math.max(C.LAUNCH_SPEED_CAP, 1), 0.25, 1)
			addShake(
				st.lastLaunchClock,
				C.LAUNCH_CAMERA_SHAKE_TIME,
				C.LAUNCH_CAMERA_SHAKE_STRENGTH * speedAlpha,
				240.5,
				0.045
			)
		end
		addShake(
			st.lastLandingClock,
			C.LANDING_CAMERA_SHAKE_TIME,
			C.LANDING_CAMERA_SHAKE_STRENGTH * st.landingShakeStrength,
			st.landingShakeSeed,
			0.055
		)
		addShake(
			st.lastAttachClock,
			C.ATTACH_CAMERA_SHAKE_TIME,
			C.ATTACH_CAMERA_SHAKE_STRENGTH * st.attachShakeStrength,
			st.attachShakeSeed,
			0.036
		)

		-- Continuous soft wind buffet while swinging / flying through air
		local windTarget = 0
		if st.isSwinging or st.isLaunched then
			local speedAlpha = math.clamp(
				(speed - C.SWING_WIND_SHAKE_MIN_SPEED)
					/ math.max(C.SWING_WIND_SHAKE_REF_SPEED - C.SWING_WIND_SHAKE_MIN_SPEED, 1),
				0,
				1
			)
			if st.isSwinging then
				windTarget = C.SWING_WIND_SHAKE_HANG + speedAlpha * (1 - C.SWING_WIND_SHAKE_HANG)
			else
				windTarget = speedAlpha * 0.9
			end
		end
		st.windShakeIntensity += (windTarget - st.windShakeIntensity) * math.min(dt * 5.5, 1)
		local windIntensity = st.windShakeIntensity
		if windIntensity > 0.01 then
			local seed = st.windShakeSeed
			local t = now * C.SWING_WIND_SHAKE_SPEED
			local gust = Vector3.new(
				math.noise(seed, t * 0.34, 1),
				math.noise(seed, t * 0.26, 7) * 0.75,
				math.noise(seed, t * 0.3, 14)
			)
			local flutter = Vector3.new(
				math.noise(seed + 4, t * 1.55, 2),
				math.noise(seed + 4, t * 1.85, 9),
				math.noise(seed + 4, t * 1.35, 16)
			)
			local wind = gust * 0.7 + flutter * 0.3
			shakeOffset += wind * C.SWING_WIND_SHAKE_POS * windIntensity
			shakeRot += wind * C.SWING_WIND_SHAKE_ROT * windIntensity
		end

		if shakeOffset.Magnitude > 0.0001 or shakeRot.Magnitude > 0.0001 then
			cf = cf * CFrame.new(shakeOffset) * CFrame.Angles(shakeRot.X, shakeRot.Y, shakeRot.Z)
		end

		camera.CFrame = cf
	end)

	st.addConn(RunService.Heartbeat:Connect(function(dt)
		if st.isWebTrapped() then
			if st.isSwinging then
				st.stopSwing(false)
			end
			st.hideSwingTargetUi()
			if player:GetAttribute("IsSwinging") ~= false then
				player:SetAttribute("IsSwinging", false)
			end
			return
		end

		local swingTravel = st.isSwinging or st.isLaunched
		if player:GetAttribute("IsSwinging") ~= swingTravel then
			player:SetAttribute("IsSwinging", swingTravel)
		end

		camera = workspace.CurrentCamera or camera
		local now = os.clock()
		local velocity = st.hrp.AssemblyLinearVelocity
		local speed = velocity.Magnitude

		if st.isAirborneForSwing() then
			st.landingSpeed = math.max(st.landingSpeed, speed)
		end

		-- Landing watchdog: sometimes Roblox skips the clean Landed state and leaves the st.character
		-- briefly in Physics/FallingDown/GettingUp. If the launched player is now grounded or close
		-- to ground while no longer moving upward, instantly return control.
		if
			not st.isSwinging
			and (st.isLaunched or st.landedFromSwing)
			and now - st.lastLaunchClock > 0.16
			and velocity.Y <= C.SWING_LANDING_MAX_Y_SPEED_FOR_RECOVERY
			and st.isCloseToGroundForSwingLanding()
		then
			local wasLandedFromSwing = st.landedFromSwing
			local impactSpeed = st.landingSpeed
			st.landedFromSwing = false
			st.isLaunched = false
			st.clearReturnSwingTarget()
			st.landingSpeed = 0
			st.isAirborne = false
			stopWindLoopSfx()
			st.forceSwingHumanoidControl()
			st.stopFallingAnim(C.LAUNCH_FALL_STOP_FADE)
			if wasLandedFromSwing and canPlaySwingLandingImpact(st.character, st.hrp, st.rayParams) then
				st.playLandedAnim()
				spawnLandingBlocks(st.character, st.hrp, st.rayParams, impactSpeed)
				playOptionalSound("GroundSmash")
				local impactAlpha = math.clamp((impactSpeed - 8) / 70, 0.58, 1)
				st.lastLandingClock = now
				st.landingShakeStrength = math.clamp(0.42 + impactAlpha * 0.86, 0, 1.22)
				st.landingShakeSeed = math.random() * 1000
			end
			st.hideSwingTargetUi()
		end

		if st.isSwinging then
			if isSwingInputBlocked() then
				st.stopSwing(false)
				return
			end
			if not st.currentTarget or not st.currentTarget.Parent then
				st.stopSwing(true)
				return
			end

			if st.pendingSwingParams and not st.ropeConstraint then
				if not st.holdIsActive() then
					st.stopSwing(false)
					return
				end

				st.updateSwingRopeVisual(st.lockedAttachWorld)
				return
			end

			if not st.anchorAttachment or not st.anchorAttachment.Parent then
				st.stopSwing(true)
				return
			end
			if st.swingTimer > C.MIN_SWING_LOCK_TIME and not st.holdIsActive() then
				st.stopSwing(true)
				return
			end

			st.swingTimer += dt
			st.humanoid.PlatformStand = true
			st.humanoid.AutoRotate = false
			st.humanoid.Jump = false

			local anchorWorld = st.anchorAttachment.WorldPosition
			st.updateSwingRopeVisual(anchorWorld)

			local fromAnchor = st.hrp.Position - anchorWorld
			local dist = fromAnchor.Magnitude
			local radial = dist > 0.2 and fromAnchor.Unit or Vector3.new(0, 1, 0)
			local ropeMax = math.max(st.activeRopeMaxLength or getRopeMaxLength(), C.ROPE_SAFE_MAX_MIN_LENGTH)
			local speedCap = getMaxSwingSpeed() * (1 + st.swingMomentum * C.SWING_MOMENTUM_SPEED_BONUS)
			local extT = math.clamp(dist / math.max(ropeMax, 1), 0, 1.15)
			local decay = math.clamp(st.swingTimer / C.FORCE_DECAY_TIME, 0, 1)
			local mult = 1 - decay * (1 - C.FORCE_MIN_MULT)
			local ropeLiftForce = Vector3.new(0, 0, 0)

			st.rayParams.FilterDescendantsInstances = { st.character }
			local groundHit =
				workspace:Raycast(st.hrp.Position, Vector3.new(0, -C.SWING_GROUND_CLEARANCE * 1.8, 0), st.rayParams)
			if groundHit then
				local groundGap = st.hrp.Position.Y - groundHit.Position.Y
				local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
				if groundGap < C.SWING_GROUND_CLEARANCE then
					local liftAlpha =
						math.clamp((C.SWING_GROUND_CLEARANCE - groundGap) / C.SWING_GROUND_CLEARANCE, 0, 1)
					ropeLiftForce += Vector3.yAxis * C.SWING_GROUND_LIFT_FORCE * liftAlpha * st.hrp.AssemblyMass
					if velocity.Y < C.SWING_GROUND_MIN_UP_SPEED * liftAlpha then
						velocity = Vector3.new(velocity.X, C.SWING_GROUND_MIN_UP_SPEED * liftAlpha, velocity.Z)
						st.hrp.AssemblyLinearVelocity = velocity
					end
					if groundGap < C.SWING_GROUND_HARD_CLEARANCE then
						local lift = math.min(C.SWING_GROUND_HARD_CLEARANCE - groundGap + 0.12, 1.6)
						st.hrp.CFrame += Vector3.new(0, lift, 0)
					end
					st.lastGroundDragDebrisClock = spawnGroundDragDebris(st.hrp, groundHit, horizontalVelocity, st.lastGroundDragDebrisClock)
				end
			end

			if st.zipSpring then
				local zipAlpha = math.clamp(1 - st.swingTimer / C.ZIP_PULL_TIME, 0, 1)
				if zipAlpha <= 0 then
					st.zipSpring:Destroy()
					st.zipSpring = nil
				else
					st.zipSpring.MaxForce = st.hrp.AssemblyMass * C.ZIP_SPRING_MAX_ACCEL * C.ROPE_CATCH_FORCE_MULT * zipAlpha
				end
			end

			ropeLiftForce, velocity, speed = st.updateSwingRopePhysics(
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

			local camLook = camera and camera.CFrame.LookVector or st.hrp.CFrame.LookVector
			local camRight = camera and camera.CFrame.RightVector or st.hrp.CFrame.RightVector
			local moveDir = st.humanoid.MoveDirection
			local camFlat = flatUnit(camLook) or flatUnit(st.hrp.CFrame.LookVector)
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
			local forwardInput = st.forwardInputAmount()
			if moveFlatUnit and forwardInput <= 0.08 and safeIsKeyDown(Enum.KeyCode.W) then
				forwardInput = 1
			end
			if forwardInput > 0.08 then
				st.forwardHoldTime += dt * forwardInput
				st.forwardSwingCharge = math.min(1, st.forwardSwingCharge + dt * forwardInput / C.FORWARD_CHARGE_TIME)
			else
				st.forwardHoldTime = math.max(0, st.forwardHoldTime - dt * 0.55)
				st.forwardSwingCharge = math.max(0, st.forwardSwingCharge - dt * 0.7)
			end

			if moveFlatUnit or forwardInput > 0.08 then
				st.lastSwingInputClock = now
			end
			st.poseInputs.radial = radial
			st.poseInputs.moveFlatUnit = moveFlatUnit
			st.poseInputs.forwardInput = forwardInput
			st.poseInputs.extT = extT
			st.poseInputs.momentum = st.swingMomentum

			st.swingRhythmBoost = math.max(0, st.swingRhythmBoost - C.SWING_RHYTHM_DECAY_RATE * dt)
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
				if st.lastPumpInputSign ~= 0 and pumpInputSign ~= st.lastPumpInputSign then
					local switchAge = now - st.lastPumpSwitchClock
					if switchAge > 0.1 and switchAge < 1.25 then
						local timing = 1 - math.clamp(math.abs(switchAge - 0.48) / 0.77, 0, 1)
						st.swingRhythmBoost = math.min(1, st.swingRhythmBoost + 0.24 + timing * 0.2)
					end
					st.lastPumpSwitchClock = now
				end
				st.lastPumpInputSign = pumpInputSign
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
				camSteerForce = tangent.Unit * getSteerForce() * mult * steerInputScale * st.hrp.AssemblyMass
			end

			local arcDir = pendulumArcDir(radial)
			local arcForce = Vector3.new(0, 0, 0)
			local pumpForce = Vector3.new(0, 0, 0)
			local deadHangForce = Vector3.new(0, 0, 0)
			local orbitInputForce = Vector3.new(0, 0, 0)
			if arcDir then
				local floorMult = st.floorScale(anchorWorld, ropeMax)
				local arcStrength = getArcForce() * mult * (0.42 + extT * 0.78) * floorMult
				arcForce = arcDir * arcStrength * st.hrp.AssemblyMass

				local tangVel = velocity - radial * velocity:Dot(radial)
				local tangSpeed = tangVel.Magnitude
				local targetTangSpeed = speedCap * (0.52 + math.clamp(extT, 0, 1) * 0.24)
				if moveTangent.Magnitude > 0.05 and tangSpeed < targetTangSpeed then
					local lowSpeedBoost = 1 - math.clamp(tangSpeed / 28, 0, 1)
					deadHangForce = moveTangent.Unit
						* C.DEAD_HANG_MOVE_FORCE
						* (0.35 + lowSpeedBoost * 0.65)
						* mult
						* st.hrp.AssemblyMass
					st.swingMomentum = math.min(
						1,
						st.swingMomentum
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
				local rhythmQuality = st.swingRhythmBoost * (0.35 + math.abs(moveAlongTangent) * 0.65)
				local lowSpeedPump = 1 - math.clamp(tangSpeed / 30, 0, 1)
				if moveTangent.Magnitude > 0.05 then
					local orbitGrip = 0.58 + math.clamp(moveAlongTangent, -0.25, 1) * 0.22
					orbitGrip += lowSpeedPump * 0.25 + st.swingRhythmBoost * 0.18
					orbitInputForce = moveTangent.Unit
						* C.SWING_INPUT_ORBIT_FORCE
						* math.clamp(orbitGrip, 0.35, 1.25)
						* mult
						* st.hrp.AssemblyMass
				end
				if movingWithArc and moveFlatUnit then
					pumpQuality = math.max(pumpQuality, 0.35)
				end
				if moveFlatUnit then
					pumpQuality = math.max(pumpQuality, math.clamp(moveAlongTangent, 0, 1))
					if moveAlongTangent < -0.12 and (tangSpeed < targetTangSpeed * 0.58 or st.swingRhythmBoost > 0.12) then
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
					st.swingMomentum = math.min(1, st.swingMomentum + build)
				elseif not moveFlatUnit or tangSpeed < 5 then
					st.swingMomentum = math.max(0, st.swingMomentum - C.SWING_MOMENTUM_IDLE_DECAY_RATE * dt)
				elseif moveAlongTangent < -0.2 then
					if tangSpeed < targetTangSpeed * 0.62 or st.swingRhythmBoost > 0.12 then
						local reversalBuild = C.SWING_REVERSAL_BUILD_RATE
							* math.abs(moveAlongTangent)
							* (0.35 + lowSpeedPump * 0.65 + st.swingRhythmBoost * 0.35)
							* dt
						st.swingMomentum = math.min(1, st.swingMomentum + reversalBuild)
					else
						st.swingMomentum = math.max(
							0,
							st.swingMomentum
								- C.SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * math.abs(moveAlongTangent) * 0.38 * dt
						)
					end
				else
					st.swingMomentum = math.max(0, st.swingMomentum - C.SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * 0.28 * dt)
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
						* (1 + forwardInput * 0.3 + st.swingMomentum * 0.22)
						* mult
						* st.hrp.AssemblyMass
						* 0.02
					if moveTangent.Magnitude > 0.05 and st.swingRhythmBoost > 0.03 then
						pumpForce += moveTangent.Unit * C.SWING_RHYTHM_FORCE * st.swingRhythmBoost * (0.45 + math.abs(
							moveAlongTangent
						) * 0.55) * mult * st.hrp.AssemblyMass
					end
					if
						moveTangent.Magnitude > 0.05
						and moveAlongTangent < -0.12
						and (tangSpeed < targetTangSpeed * 0.62 or st.swingRhythmBoost > 0.12)
					then
						pumpForce += moveTangent.Unit * C.SWING_REVERSAL_FORCE * math.abs(moveAlongTangent) * (0.35 + lowSpeedPump * 0.65) * mult * st.hrp.AssemblyMass
					end
				end

				if floorMult < 0.3 and velocity.Y < -10 then
					st.hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y * 0.84, velocity.Z)
				end
			else
				if moveTangent.Magnitude > 0.05 then
					st.lastSwingInputClock = now

					deadHangForce = moveTangent.Unit * C.DEAD_HANG_MOVE_FORCE * 0.72 * mult * st.hrp.AssemblyMass
					st.swingMomentum =
						math.min(1, st.swingMomentum + C.SWING_DEAD_HANG_MOMENTUM_BUILD_RATE * moveTangent.Magnitude * dt)
				else
					-- No input: keep the swing flowing, then slowly bleed speed away.
					st.swingMomentum = math.max(0, st.swingMomentum - C.SWING_MOMENTUM_IDLE_DECAY_RATE * 0.32 * dt)

					local tangVelocity = velocity - radial * velocity:Dot(radial)
					local tangSpeed = tangVelocity.Magnitude

					if tangSpeed > C.SWING_IDLE_FLOW_MIN_SPEED then
						deadHangForce = -tangVelocity * C.SWING_IDLE_FLOW_DAMPING * st.hrp.AssemblyMass
					elseif now - st.lastSwingInputClock > C.SWING_IDLE_SWAY_DELAY and arcDir then
						deadHangForce = arcDir
							* math.sin(now * C.SWING_IDLE_SWAY_SPEED)
							* C.SWING_IDLE_SWAY_FORCE
							* mult
							* st.hrp.AssemblyMass
					end
				end
			end

			local arcWeight = 0.36 + math.clamp((extT - 0.25) / 0.75, 0, 1) * 0.56
			if st.steerForce then
				st.steerForce.Force = camSteerForce * (1 - arcWeight * 0.45)
					+ arcForce
					+ pumpForce
					+ deadHangForce
					+ orbitInputForce
					+ ropeLiftForce
			end

			if st.swingOrientation then
				local currentFace = flatUnit(st.hrp.CFrame.LookVector)
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
					if st.swingFaceDir and st.swingFaceDir.Magnitude > 0.05 then
						st.swingFaceDir = st.swingFaceDir:Lerp(desiredUnit, faceAlpha)
					else
						st.swingFaceDir = desiredUnit
					end

					if st.swingFaceDir.Magnitude > 0.05 then
						local faceCFrame = CFrame.lookAt(st.hrp.Position, st.hrp.Position + st.swingFaceDir.Unit)
						local tangVelocity = velocity - radial * velocity:Dot(radial)
						local leanPower = math.clamp(
							tangVelocity.Magnitude / math.max(speedCap, 1) + st.swingMomentum * 0.45 + extT * 0.18,
							0,
							1.25
						)

						st.swingOrientation.Responsiveness = C.AVATAR_TURN_RESPONSIVENESS
							+ (quickTurn and 18 or 0)
							+ math.floor(leanPower * 8)
						st.swingOrientation.MaxTorque = st.hrp.AssemblyMass * 22000
						st.swingOrientation.CFrame = faceCFrame
					end
				end
			end

			st.hrp.AssemblyAngularVelocity = st.hrp.AssemblyAngularVelocity * math.exp(-C.ANGULAR_DAMP * dt)
			if speed > speedCap then
				st.hrp.AssemblyLinearVelocity = velocity.Unit * speedCap
			end

			st.swingCharge = math.min(1, st.swingCharge + dt / C.CHARGE_TIME)
			st.layoutCharge()
		else
			st.poseInputs.radial = nil
			st.poseInputs.moveFlatUnit = nil
			st.poseInputs.forwardInput = 0
			st.poseInputs.extT = 0
			st.poseInputs.momentum = 0

			if st.isLaunched then
				st.releaseStyle.step(now, dt, st.isLaunched, st.isSwinging, st.lastLaunchClock)
			end

			-- Hold mode: keep trying while jump is held.
			-- Toggle mode: short ground-only settle window (never air auto-latch after release).
			if st.isHoldToSwingMode() and st.holdIsActive() then
				st.tryAttach()
			elseif
				not st.isHoldToSwingMode()
				and now < st.swingPressIntentUntil
				and (st.isGroundedForSwing() or st.hasFloorSupportForSwing())
			then
				st.tryAttach()
			end

			local scanMode = "none"
			if isGameplayCutsceneActive() or st.isHrpInSafezone() then
				st.hideSwingTargetUi()
			elseif st.isAirborneForSwing() then
				scanMode = "air"
			elseif st.isGroundedForSwing() then
				scanMode = "ground"
			end

			if scanMode == "none" then
				st.hideSwingTargetUi()
			else
				local scanInterval = if scanMode == "ground" then C.TARGET_SCAN_INTERVAL_GROUNDED else C.TARGET_SCAN_INTERVAL
				if speed >= C.TARGET_SCAN_FAST_SPEED then
					scanInterval = math.min(scanInterval, C.TARGET_SCAN_INTERVAL_FAST)
				end
				local needsScan = scanMode ~= st.lastTargetScanMode
					or now - st.lastTargetScanClock >= scanInterval
					or (st.scannedVisualTarget ~= nil and not st.scannedVisualTarget.Parent)
					or (not st.targetVisualShown and st.scannedVisualTarget == nil)

				if needsScan then
					st.lastTargetScanClock = now
					st.lastTargetScanMode = scanMode
					local prevCandidateCap = C.TARGET_MAX_CANDIDATES_PER_SCAN
					local reachNow = getSwingRange()
					if scanMode == "ground" then
						C.TARGET_MAX_CANDIDATES_PER_SCAN = if reachNow > 140
							then C.TARGET_MAX_CANDIDATES_HIGH_REACH
							else C.TARGET_MAX_CANDIDATES_GROUNDED
					elseif reachNow > 140 then
						C.TARGET_MAX_CANDIDATES_PER_SCAN = math.max(prevCandidateCap, C.TARGET_MAX_CANDIDATES_HIGH_REACH)
					end
					local scanDistance, scanLookDot, scanScreenLimit = st.getSwingAttachLimits()
					-- Ground UI: show latchable with the same press checks (don't green-light far vines
					-- that jump can't actually grab until you walk closer).
					if scanMode == "ground" then
						local pressDist, pressLook, pressScreen = st.getSwingPressAttachLimits()
						scanLookDot, scanScreenLimit = pressLook, pressScreen
						-- Keep ground ready range honest — not inflated beyond live swing reach.
						scanDistance = pressDist
						st.clearReturnSwingTarget()
					elseif scanMode == "air" and st.returnSwingTarget then
						scanDistance = math.max(scanDistance, st.getEffectiveLatchLimit(st.returnSwingTarget))
					end
					if not scanDistance then
						scanDistance, scanLookDot, scanScreenLimit = 0, nil, nil
					end
					st.scannedVisualTarget, st.scannedVisualCanSwing =
						st.pickVisualSwingTarget(scanDistance, scanDistance, st.highlightedTarget, false, scanLookDot, scanScreenLimit)
					C.TARGET_MAX_CANDIDATES_PER_SCAN = prevCandidateCap
					if
						st.scannedVisualTarget ~= st.lastVisualTarget
						or st.scannedVisualCanSwing ~= st.lastVisualCanSwing
						or st.targetVisualShown ~= (st.scannedVisualTarget ~= nil)
					then
						st.updateTargetVisual(st.scannedVisualTarget, st.scannedVisualCanSwing)
					end
				end
			end
		end

		if st.targetVisualShown or st.scannedVisualTarget ~= nil or st.isSwinging then
			st.stepTargetVisual(dt)
		end

		local trailOn = (st.isSwinging or st.isLaunched or st.isAirborneForSwing()) and (speed > 62 or velocity.Y < -78)
		st.setTrailsEnabled(trailOn)

		if camera then
			local targetFov = st.originalFov
			if st.isSwinging or st.isLaunched then
				local t = math.clamp(speed / math.max(getMaxSwingSpeed(), 1), 0, 1)
				targetFov = st.originalFov + (C.FOV_MAX - st.originalFov) * t
			end

			local attachAge = os.clock() - st.lastAttachClock
			if st.isSwinging and attachAge >= 0 and attachAge < C.ATTACH_FOV_TIME then
				local u = attachAge / C.ATTACH_FOV_TIME
				targetFov -= C.ATTACH_FOV_PUNCH * math.sin(u * math.pi)
			end

			local launchAge = os.clock() - st.lastLaunchClock
			if launchAge >= 0 and launchAge < C.LAUNCH_FOV_TIME then
				local u = 1 - launchAge / C.LAUNCH_FOV_TIME
				targetFov += C.LAUNCH_FOV_BOOST * u * u
			end

			local landingAge = os.clock() - st.lastLandingClock
			if landingAge >= 0 and landingAge < C.LANDING_FOV_TIME then
				local u = 1 - landingAge / C.LANDING_FOV_TIME
				targetFov -= C.LANDING_FOV_KICK * u * u * st.landingShakeStrength
			end

			local fovDelta = targetFov - camera.FieldOfView
			if math.abs(fovDelta) > 0.03 then
				camera.FieldOfView += fovDelta * math.min(dt * C.FOV_SPEED, 1)
			elseif math.abs(camera.FieldOfView - st.originalFov) < 0.05 and not st.isSwinging and not st.isLaunched then
				-- Settled — avoid writing FieldOfView every Heartbeat while idle.
			elseif math.abs(fovDelta) > 0.001 then
				camera.FieldOfView = targetFov
			end
		end
	end))

	return function()
		pcall(function()
			RunService:UnbindFromRenderStep(st.renderBindName)
		end)
		for _, conn in ipairs(st.conns) do
			conn:Disconnect()
		end
		table.clear(st.conns)
		if st.isSwinging then
			st.stopSwing(false)
		end
		st.releaseStyle.cancel()
		st.swingPose.clear()
		st.destroySwingObjects()
		st.destroyPreview(true)
		if st.targetHighlight then
			st.targetHighlight:Destroy()
			st.targetHighlight = nil
			st.targetHighlightAdornee = nil
		end
		if st.targetHighlightProxyPart then
			st.targetHighlightProxyPart:Destroy()
			st.targetHighlightProxyPart = nil
		end
		st.cleanupWorkspaceHelpersByName("SwingTargetHighlightProxy", nil)
		st.cleanupWorkspaceHelpersByName("SwingTargetHighlight", nil)
		if st.markerGui then
			st.markerGui:Destroy()
			st.markerGui = nil
		end
		if st.markerAnchorPart then
			st.markerAnchorPart:Destroy()
			st.markerAnchorPart = nil
		end
		st.cleanupWorkspaceHelpersByName("SwingMarkerAnchor", nil)
		st.cleanupWorkspaceHelpersByName("SwingPreviewAnchor", nil)
		st.setTrailsEnabled(false)
		for _, trail in ipairs(st.trails) do
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
		st.stopHangAnim(0)
		st.stopFallingAnim()
		st.stopTrack(st.landedTrack, 0.12)
		stopWindLoopSfx()
		pcall(function()
			st.humanoid.PlatformStand = false
			st.humanoid.AutoRotate = true
		end)
		pcall(st.resetFovNow)
	end
end

local dispose = nil

player.CharacterAdded:Connect(function(character)
	pcall(function()
		player:SetAttribute("IsSwinging", false)
	end)
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
