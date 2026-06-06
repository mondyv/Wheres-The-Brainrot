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
local SWING_TARGET_TAG = "SwingTarget"
local SWING_TARGET_NAME = "SwingTarget"
local MAP_FOLDER_NAME = "Map"
local VINE_FOLDER_NAME = "Vine"

-- Tuning.
local SWING_RANGE = 64
local ROPE_MAX_LENGTH = 56
local ROPE_MIN_LENGTH = 13
local ROPE_REST_LENGTH_MULT = 0.5
local ROPE_MOMENTUM_LENGTH_MULT = 0.24
local ROPE_DISTANCE_STRETCH_MULT = 0.055
local ROPE_LENGTH_RESPONSE = 9
local ROPE_ATTACH_START_MULT = 0.9
local MIN_LOOK_DOT = 0.3
local AIRBORNE_TARGET_LOOK_DOT = 0.18
local TARGET_SCREEN_RADIUS_LIMIT = 0.52
local MIN_TARGET_HEIGHT_OFFSET = -8
local TARGET_SCAN_INTERVAL = 0.08
local TARGET_CANDIDATE_EXTRA_RADIUS = 8
local TARGET_GRID_CELL_SIZE = 64
local TARGET_MAX_CANDIDATES_PER_SCAN = 90
local TARGET_FULL_SCAN_FALLBACK_LIMIT = 180
local TARGET_ENABLE_VINE_NAME_FALLBACK = false
local TARGET_BACKGROUND_SEED_ENABLED = false
local TARGET_SKIP_VINE_SEED_WHEN_TAGGED = true
local TARGET_SEED_BATCH_SIZE = 12
local TARGET_SEED_MAX_SLICE_TIME = 0.004
local TARGET_SEED_STEP_WAIT = 0.05
local ENABLE_TARGET_HIGHLIGHT = false
local ATTACH_RETRY_TIME = 0.08
local ATTACH_COOLDOWN = 0.18
local MIN_SWING_LOCK_TIME = 0.28
-- Swinging is air-gated: ground never shows UI and never attaches.
local AIRBORNE_TARGET_UI_EXTRA = 18

local STEER_FORCE = 70
local ARC_FORCE = 44
local SPEED_PUMP = 1.1
local MAX_SWING_SPEED = 94
local FORCE_DECAY_TIME = 6
local FORCE_MIN_MULT = 0.76
local ANGULAR_DAMP = 7.5
local FLOOR_CLEARANCE = 5

local ZIP_SPRING_STIFFNESS = 22
local ZIP_SPRING_DAMPING = 16
local ZIP_SPRING_MAX_ACCEL = 700
local ATTACH_ZIP_DV = 13
local ZIP_PULL_TIME = 0.5

local LAUNCH_FORWARD_DV = 72
local LAUNCH_MOMENTUM_RATIO = 0.14
local LAUNCH_UP_DV = 31
local LAUNCH_CHARGE_DV = 8
local LAUNCH_FORWARD_INPUT_DV = 18
local LAUNCH_SPEED_CAP = 120
local MIN_HOLD_FOR_FULL_LAUNCH = 0.14
local CHARGE_TIME = 0.95
local FORWARD_CHARGE_TIME = 1.05
local SWING_MOMENTUM_BUILD_RATE = 0.68
local SWING_MOMENTUM_FORWARD_BUILD_RATE = 0.34
local SWING_MOMENTUM_IDLE_DECAY_RATE = 0.82
local SWING_MOMENTUM_BAD_INPUT_DECAY_RATE = 0.7
local SWING_DEAD_HANG_MOMENTUM_BUILD_RATE = 0.54
local SWING_RHYTHM_BUILD_RATE = 0.58
local SWING_RHYTHM_DECAY_RATE = 1.25
local SWING_REVERSAL_BUILD_RATE = 0.46
local SWING_RHYTHM_FORCE = 54
local SWING_REVERSAL_FORCE = 62
local SWING_INPUT_ORBIT_FORCE = 42
local SWING_MOMENTUM_SPEED_BONUS = 0.36
local SWING_MOMENTUM_LAUNCH_BONUS = 0.3

local FOV_SPEED = 4.5
local FOV_MAX = 96
local ATTACH_FOV_PUNCH = 5
local ATTACH_FOV_TIME = 0.28
local LAUNCH_FOV_BOOST = 7
local LAUNCH_FOV_TIME = 0.34
local LANDING_FOV_KICK = 5
local LANDING_FOV_TIME = 0.34

-- Set this false if you decide the grounded camera assist feels annoying.
local ENABLE_GROUNDED_CAMERA_ASSIST = false
local CAMERA_ASSIST_RANGE = 50
local CAMERA_ASSIST_STRENGTH = 0.72
local CAMERA_ASSIST_MIN_LOOK_DOT = 0.52

local DEAD_HANG_MOVE_FORCE = 68
local AVATAR_TURN_RESPONSIVENESS = 38
local AVATAR_FAST_TURN_DOT = -0.12
local AVATAR_NATURAL_FACE_TURN_RATE = 12
local AVATAR_NATURAL_FACE_FAST_TURN_RATE = 22

local SWING_CAMERA_ROLL_MAX = math.rad(5)
local SWING_CAMERA_LAG_MAX = 0.72
local SWING_CAMERA_EFFECT_SPEED = 7
local LAUNCH_CAMERA_SHAKE_TIME = 0.3
local LAUNCH_CAMERA_SHAKE_STRENGTH = 0.22
local LANDING_CAMERA_SHAKE_TIME = 0.46
local LANDING_CAMERA_SHAKE_STRENGTH = 0.62

local PREVIEW_COLOR = Color3.fromRGB(90, 220, 255)
local READY_COLOR = Color3.fromRGB(70, 255, 115)
local NOT_READY_COLOR = Color3.fromRGB(255, 70, 70)
local TARGET_VISUAL_SMOOTH_SPEED = 10
local PREVIEW_FADE_SPEED = 12
local READY_TEXT_BOB_SPEED = 8
local READY_TEXT_BOB_PIXELS = 5
local ROPE_COLOR_A = Color3.fromRGB(255, 255, 255)
local ROPE_COLOR_B = Color3.fromRGB(90, 220, 255)

-- Swing animations live in ReplicatedStorage/Animations/Player.
-- Expected Animation names: Hang_Left, Hang_Right, Falling, Landed.
local ENABLE_SWING_ANIMATIONS = true
local ANIMATIONS_FOLDER_NAME = "Animations"
local PLAYER_ANIMATIONS_FOLDER_NAME = "Player"
local HANG_ANIM_RIGHT_NAME = "Hang_Right"
local HANG_ANIM_LEFT_NAME = "Hang_Left"
local FALLING_ANIM_NAME = "Falling"
local LANDED_ANIM_NAME = "Landed"

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
			return math.clamp(stats.maxSwingSpeed / MAX_SWING_SPEED, 0.75, 1.7)
		end
		if typeof(stats.steeringForce) == "number" and stats.steeringForce > 0 then
			return math.clamp(stats.steeringForce / STEER_FORCE, 0.75, 1.7)
		end
	end

	local rawPower = getFirstNumberAttribute({ "SwingPower", "Power" })
	if not rawPower then
		local force = getFirstNumberAttribute({ "SwingForce" })
		if force and force > 0 then
			return math.clamp(force / STEER_FORCE, 0.75, 1.7)
		end
		return 1
	end

	if rawPower > 10 then
		rawPower = rawPower / 100
	end

	return math.clamp(rawPower, 0.65, 1.55)
end

local function getSwingRange()
	local ropeStats = getRopeStats()
	if ropeStats and typeof(ropeStats.reachStuds) == "number" and ropeStats.reachStuds > 0 then
		return math.clamp(ropeStats.reachStuds, 32, 140)
	end

	local rangeAttr = getFirstNumberAttribute({ "SwingRange", "ReachDistance", "Reach_Distance" })
	if rangeAttr and rangeAttr > 0 then
		return math.clamp(rangeAttr, 32, 140)
	end

	local powerScale = getPowerScale()
	return math.clamp(SWING_RANGE * (0.9 + (powerScale - 1) * 0.25), 42, 100)
end

local function getRopeMaxLength()
	local ropeStats = getRopeStats()
	if ropeStats and typeof(ropeStats.reachStuds) == "number" and ropeStats.reachStuds > 0 then
		local ropePts = getFirstNumberAttribute({ "RopeLength", "RopeLenght" }) or 0
		return math.clamp(ropeStats.reachStuds + ropePts * 2, ROPE_MIN_LENGTH + 6, 150)
	end

	local ropeAttr = getFirstNumberAttribute({ "RopeLength", "RopeLenght" })
	if ropeAttr and ropeAttr > 0 then
		return math.clamp(ropeAttr, ROPE_MIN_LENGTH + 6, 150)
	end

	local powerScale = getPowerScale()
	return math.clamp(ROPE_MAX_LENGTH * (0.86 + (powerScale - 1) * 0.25), 36, 100)
end

local function getLaunchScale()
	local stats = getPowerStats()
	if stats and typeof(stats.maxLaunchSpeed) == "number" and stats.maxLaunchSpeed > 0 then
		return math.clamp(stats.maxLaunchSpeed / LAUNCH_SPEED_CAP, 0.86, 1.4)
	end
	return math.clamp(0.92 + (getPowerScale() - 1) * 0.32, 0.86, 1.35)
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
	return STEER_FORCE * getPowerScale()
end

local function getMaxSwingSpeed()
	local stats = getPowerStats()
	if stats and typeof(stats.maxSwingSpeed) == "number" and stats.maxSwingSpeed > 0 then
		return stats.maxSwingSpeed
	end
	return MAX_SWING_SPEED * getLaunchScale()
end

local function getArcForce()
	local stats = getPowerStats()
	if stats and typeof(stats.swingArcForce) == "number" and stats.swingArcForce > 0 then
		return stats.swingArcForce
	end
	return ARC_FORCE * getPowerScale()
end

local function getSpeedPump()
	local stats = getPowerStats()
	if stats and typeof(stats.swingSpeedPump) == "number" and stats.swingSpeedPump > 0 then
		return stats.swingSpeedPump
	end
	return SPEED_PUMP * getPowerScale()
end

local function getZipDv()
	local stats = getPowerStats()
	if stats and typeof(stats.zipToward) == "number" and stats.zipToward > 0 then
		return stats.zipToward
	end
	return ATTACH_ZIP_DV * getPowerScale()
end

local function playOptionalSound(name)
	local s = script:FindFirstChild(name)
	if s and s:IsA("Sound") then
		pcall(function()
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
	local lastTryClock = -1e9
	local lastAttachClock = -1e9
	local lastGroundJumpClock = -1e9
	local airborneStartedClock = -1e9
	local lastLaunchClock = -1e9
	local lastLandingClock = -1e9
	local landingShakeStrength = 0
	local landingShakeSeed = math.random() * 1000
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
	local highlightedTarget = nil
	local highlightedPoint = nil
	local targetVisualShown = false
	local anchorAttachment = nil
	local bodyAttachment = nil
	local ropeConstraint = nil
	local activeRopeMaxLength = nil
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
	local highlight = nil
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
	local targetVisualColor = NOT_READY_COLOR
	local chargeGui = nil
	local chargeDot = nil
	local fallbackMobileGui = nil
	local activeHangTrack = nil
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

		local animationsFolder = ReplicatedStorage:FindFirstChild(ANIMATIONS_FOLDER_NAME)
			or ReplicatedStorage:WaitForChild(ANIMATIONS_FOLDER_NAME, 5)
		playerAnimationsFolder = animationsFolder
			and (
				animationsFolder:FindFirstChild(PLAYER_ANIMATIONS_FOLDER_NAME)
				or animationsFolder:WaitForChild(PLAYER_ANIMATIONS_FOLDER_NAME, 5)
			)
		if not playerAnimationsFolder then
			warn(
				"[MergedFriendSwingSystem] Missing animation folder:",
				ANIMATIONS_FOLDER_NAME .. "/" .. PLAYER_ANIMATIONS_FOLDER_NAME
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
				ANIMATIONS_FOLDER_NAME .. "/" .. PLAYER_ANIMATIONS_FOLDER_NAME .. "/" .. name
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
		if not ENABLE_SWING_ANIMATIONS then
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
		pcall(function()
			if track.IsPlaying then
				track:Stop(fadeTime or 0.14)
			end
		end)
	end

	local hangRightAnim = findPlayerAnimation(HANG_ANIM_RIGHT_NAME)
	local hangLeftAnim = findPlayerAnimation(HANG_ANIM_LEFT_NAME)
	local fallingAnim = findPlayerAnimation(FALLING_ANIM_NAME)
	local landedAnim = findPlayerAnimation(LANDED_ANIM_NAME)

	rightHangTrack = loadAnimTrack(hangRightAnim, true, Enum.AnimationPriority.Action4, "HangRight")
	if normalizeAnimationId(hangLeftAnim) == normalizeAnimationId(hangRightAnim) then
		leftHangTrack = rightHangTrack
	else
		leftHangTrack = loadAnimTrack(hangLeftAnim, true, Enum.AnimationPriority.Action4, "HangLeft")
	end
	fallingTrack = loadAnimTrack(fallingAnim, true, Enum.AnimationPriority.Action3, "SwingFalling")
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
		local track = side == "Left" and leftHangTrack or rightHangTrack
		if activeHangTrack and activeHangTrack ~= track then
			stopTrack(activeHangTrack, 0.12)
		end
		activeHangTrack = track
		if activeHangTrack then
			playTrack(activeHangTrack, 0.12, 1, 1)
		end
	end

	local function stopHangAnim()
		stopTrack(rightHangTrack, 0.16)
		if leftHangTrack ~= rightHangTrack then
			stopTrack(leftHangTrack, 0.16)
		end
		activeHangTrack = nil
	end

	local function playFallingAnim()
		if isSwinging or not (isLaunched or landedFromSwing) then
			return
		end
		stopHangAnim()
		stopTrack(landedTrack, 0.08)
		playTrack(fallingTrack, 0.14, 1, 1)
	end

	local function stopFallingAnim()
		stopTrack(fallingTrack, 0.14)
	end

	local function playLandedAnim()
		stopHangAnim()
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
		return math.floor(value / TARGET_GRID_CELL_SIZE)
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
		if not vine or not TARGET_BACKGROUND_SEED_ENABLED then
			return
		end

		task.spawn(function()
			local stack = { vine }
			local processed = 0
			local sliceStarted = os.clock()

			while #stack > 0 and vine.Parent do
				local obj = table.remove(stack)
				if obj:IsA("BasePart") and obj.Name == SWING_TARGET_NAME then
					addSwingTarget(obj)
				end

				if not obj:IsA("BasePart") then
					for _, child in ipairs(obj:GetChildren()) do
						table.insert(stack, child)
					end
				end

				processed += 1
				if
					processed % TARGET_SEED_BATCH_SIZE == 0
					or os.clock() - sliceStarted >= TARGET_SEED_MAX_SLICE_TIME
				then
					task.wait(TARGET_SEED_STEP_WAIT)
					sliceStarted = os.clock()
				end
			end
		end)
	end

	local function bindVineFolder(vine, seedExisting)
		if not vine or not TARGET_ENABLE_VINE_NAME_FALLBACK then
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
			if obj:IsA("BasePart") and obj.Name == SWING_TARGET_NAME then
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

		local taggedTargets = CollectionService:GetTagged(SWING_TARGET_TAG)
		for _, obj in ipairs(taggedTargets) do
			addSwingTarget(obj)
		end
		local hasTaggedTargets = #taggedTargets > 0

		addConn(CollectionService:GetInstanceAddedSignal(SWING_TARGET_TAG):Connect(addSwingTarget))
		addConn(CollectionService:GetInstanceRemovedSignal(SWING_TARGET_TAG):Connect(removeSwingTarget))

		local map = workspace:FindFirstChild(MAP_FOLDER_NAME)
		local vine = map and map:FindFirstChild(VINE_FOLDER_NAME)
		bindVineFolder(vine, not (TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))

		if TARGET_ENABLE_VINE_NAME_FALLBACK and not vine then
			addConn(workspace.DescendantAdded:Connect(function(obj)
				if obj.Name == VINE_FOLDER_NAME then
					local parent = obj.Parent
					if parent and parent.Name == MAP_FOLDER_NAME then
						bindVineFolder(obj, not (TARGET_SKIP_VINE_SEED_WHEN_TAGGED and hasTaggedTargets))
					end
				elseif obj:IsA("BasePart") and obj.Name == SWING_TARGET_NAME then
					local ancestor = obj.Parent
					while ancestor do
						if ancestor.Name == VINE_FOLDER_NAME then
							addSwingTarget(obj)
							break
						end
						ancestor = ancestor.Parent
					end
				end
			end))
		end

		if not hasTaggedTargets and not TARGET_ENABLE_VINE_NAME_FALLBACK then
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
		if #targetCache == 0 and not TARGET_ENABLE_VINE_NAME_FALLBACK then
			return {}
		end

		local radius = math.max(2, (maxDistance or getSwingRange()) + TARGET_CANDIDATE_EXTRA_RADIUS)
		local origin = hrp.Position
		local candidates = {}
		local seen = {}
		local invalidTargets = {}

		local centerX = targetCellCoord(origin.X)
		local centerY = targetCellCoord(origin.Y)
		local centerZ = targetCellCoord(origin.Z)
		local cellRadius = math.max(1, math.ceil(radius / TARGET_GRID_CELL_SIZE))
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
									if #candidates >= TARGET_MAX_CANDIDATES_PER_SCAN then
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

		if #candidates == 0 and #targetCache <= TARGET_FULL_SCAN_FALLBACK_LIMIT then
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
		local minLookDot = minLookDotOverride or MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or TARGET_SCREEN_RADIUS_LIMIT
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
			if attachWorld.Y < hrp.Position.Y + MIN_TARGET_HEIGHT_OFFSET then
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

			local centerBias = -screenRadius * 0.45

			local score = align * 1.45 + heightBonus + centerBias - (dist / reach) * 0.12
			if score > bestScore then
				bestScore = score
				best = part
			end
		end

		return best
	end

	local function getAirborneTargetUiRange()
		return math.clamp(getSwingRange() + AIRBORNE_TARGET_UI_EXTRA, 42, 138)
	end

	local function targetDistanceAndPoint(target)
		if not target or not target.Parent or not target:IsDescendantOf(workspace) then
			return nil, nil
		end
		if target:IsDescendantOf(character) then
			return nil, nil
		end

		local attachWorld = closestAttachWorldOnPart(target)
		if attachWorld.Y < hrp.Position.Y + MIN_TARGET_HEIGHT_OFFSET then
			return nil, nil
		end

		return (attachWorld - hrp.Position).Magnitude, attachWorld
	end

	local function pickNearbySwingTarget(maxDistance, preferredTarget)
		if isHrpInSafezone() then
			return nil, nil, nil
		end

		local function validCandidate(target)
			local dist, point = targetDistanceAndPoint(target)
			if not dist or dist < 2 or dist > maxDistance then
				return nil, nil
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
		local minLookDot = minLookDotOverride or MIN_LOOK_DOT
		local maxScreenRadius = maxScreenRadiusOverride or TARGET_SCREEN_RADIUS_LIMIT
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
		if not ENABLE_GROUNDED_CAMERA_ASSIST then
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
		if highlight and not highlight.Enabled then
			return nil, nil
		end

		local point = highlightedPoint or closestAttachWorldOnPart(highlightedTarget)
		if (point - hrp.Position).Magnitude > CAMERA_ASSIST_RANGE then
			return nil, nil
		end

		local toPoint = point - camera.CFrame.Position
		if toPoint.Magnitude < 0.5 then
			return nil, nil
		end
		if camera.CFrame.LookVector:Dot(toPoint.Unit) < CAMERA_ASSIST_MIN_LOOK_DOT then
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
		if moveDir.Magnitude < 0.05 then
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

	local function makeVisualAnchor(name)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Parent = workspace
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
			previewBeam.Color = ColorSequence.new(PREVIEW_COLOR)
			previewBeam.Transparency = previewTransparency(previewFade)
			previewBeam.Enabled = false
			previewBeam.Parent = character
		end
	end

	local function hidePreview()
		previewFadeGoal = 0
		previewTarget = nil
		if previewBeam and previewFade <= 0.025 then
			previewBeam.Enabled = false
		end
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

		previewBeam.Enabled = previewFade > 0.025
		previewBeam.Transparency = previewTransparency(previewFade)
		previewBeam.Color = ColorSequence.new(targetVisualColor:Lerp(PREVIEW_COLOR, 0.45))
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

	local function ensureVisuals()
		if ENABLE_TARGET_HIGHLIGHT and not highlight then
			highlight = Instance.new("Highlight")
			highlight.Name = "SwingTargetHighlight"
			highlight.FillTransparency = 0.72
			highlight.OutlineTransparency = 0
			highlight.FillColor = READY_COLOR
			highlight.OutlineColor = READY_COLOR
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Enabled = false
			highlight.Parent = workspace
		end

		if not markerAnchorPart or not markerAnchorPart.Parent then
			markerAnchorPart = makeVisualAnchor("SwingMarkerAnchor")
		end

		if not markerGui then
			local playerGui = player:WaitForChild("PlayerGui")
			markerGui = Instance.new("BillboardGui")
			markerGui.Name = "SwingTargetMarker"
			markerGui.Size = UDim2.fromOffset(128, 82)
			markerGui.AlwaysOnTop = true
			markerGui.LightInfluence = 0
			markerGui.Enabled = false
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
			stroke.Color = READY_COLOR
			stroke.Thickness = 2
			stroke.Parent = ring
			markerStroke = stroke

			local dot = Instance.new("Frame")
			dot.Name = "Dot"
			dot.Size = UDim2.fromOffset(9, 9)
			dot.Position = UDim2.new(0.5, -4.5, 0.5, -4.5)
			dot.BackgroundColor3 = READY_COLOR
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
			markerLabel.TextColor3 = READY_COLOR
			markerLabel.TextStrokeTransparency = 0.35
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
			previewFadeGoal = canSwingNow and 1 or 0
			highlightedTarget = target
			highlightedPoint = attachWorld
			targetVisualShown = true

			markerAnchorPart.CFrame = CFrame.new(attachWorld + markerOffset)
			if ENABLE_TARGET_HIGHLIGHT and highlight and lastVisualTarget ~= target then
				highlight.Adornee = target
			end
			if ENABLE_TARGET_HIGHLIGHT and highlight and not highlight.Enabled then
				highlight.Enabled = true
			end
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
				hidePreview()
			end
			lastVisualTarget = target
			lastVisualCanSwing = canSwingNow

			return attachWorld
		end

		targetReadyGoal = 0
		previewFadeGoal = 0
		targetVisualColor = NOT_READY_COLOR
		if not targetVisualShown and not highlightedTarget then
			hidePreview()
			return nil
		end
		if ENABLE_TARGET_HIGHLIGHT and highlight and highlight.Enabled then
			highlight.Enabled = false
			highlight.Adornee = nil
		end
		highlightedTarget = nil
		highlightedPoint = nil
		targetVisualShown = false
		if markerGui then
			markerGui.Enabled = false
		end
		lastVisualTarget = nil
		lastVisualCanSwing = nil
		hidePreview()
		return nil
	end

	local function hideSwingTargetUi()
		lastTargetScanMode = "none"
		scannedVisualTarget = nil
		scannedVisualCanSwing = false
		if targetVisualShown or highlightedTarget or previewFadeGoal > 0 or (markerGui and markerGui.Enabled) then
			updateTargetVisual(nil, false)
		else
			hidePreview()
		end
	end

	local function stepTargetVisual(dt)
		local colorAlpha = math.clamp(dt * TARGET_VISUAL_SMOOTH_SPEED, 0, 1)
		local fadeAlpha = math.clamp(dt * PREVIEW_FADE_SPEED, 0, 1)

		targetReadyVisual += (targetReadyGoal - targetReadyVisual) * colorAlpha
		previewFade += (previewFadeGoal - previewFade) * fadeAlpha
		if math.abs(previewFade - previewFadeGoal) < 0.01 then
			previewFade = previewFadeGoal
		end

		targetVisualColor = NOT_READY_COLOR:Lerp(READY_COLOR, math.clamp(targetReadyVisual, 0, 1))

		if targetVisualShown and markerGui and markerLabel then
			local pulse = math.sin(os.clock() * 7) * 0.5 + 0.5
			local readyBob = math.sin(os.clock() * READY_TEXT_BOB_SPEED)
				* READY_TEXT_BOB_PIXELS
				* math.clamp(targetReadyVisual, 0, 1)
			if ENABLE_TARGET_HIGHLIGHT then
				if highlight then
					highlight.FillColor = targetVisualColor
					highlight.OutlineColor = targetVisualColor
					highlight.FillTransparency = 0.62 + pulse * 0.18
				end
			end
			markerLabel.TextColor3 = targetVisualColor
			markerLabel.Position = UDim2.new(0, 0, 0, 48 - readyBob)

			if markerStroke then
				markerStroke.Color = targetVisualColor
			end
			if markerDot then
				markerDot.BackgroundColor3 = targetVisualColor
				markerDot.BackgroundTransparency = 0.05 + pulse * 0.38
			end
		end

		if previewBeam then
			applyPreviewVisual()
			if previewFadeGoal <= 0 and previewFade <= 0.025 then
				previewBeam.Enabled = false
			end
		end
	end

	task.defer(function()
		task.wait(0.4)
		if not hrp.Parent then
			return
		end
		ensureVisuals()
		ensurePreviewObjects()
		hidePreview()
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
		stroke.Color = READY_COLOR
		stroke.Thickness = 2.4
		stroke.Transparency = 0.05
		stroke.Parent = ring

		chargeDot = Instance.new("Frame")
		chargeDot.Size = UDim2.fromOffset(8, 8)
		chargeDot.Position = UDim2.new(0.5, -4, 0.5, -4)
		chargeDot.BackgroundColor3 = READY_COLOR
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
		swingBeam.Color = ColorSequence.new(ROPE_COLOR_A, ROPE_COLOR_B)
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
		local minSafeY = math.max(floorY + FLOOR_CLEARANCE, anchorWorld.Y - (ropeLength or getRopeMaxLength()) * 0.72)
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
		if now - lastAttachClock < ATTACH_COOLDOWN then
			return
		end

		local attachWorld = closestAttachWorldOnPart(target)
		local dist = (attachWorld - hrp.Position).Magnitude
		local reach = getSwingRange()
		local baseRopeMax = getRopeMaxLength()
		local attachLimit = reach
		if dist < 2 or dist > attachLimit then
			return
		end
		local ropeMax = math.clamp(dist * 1.08, ROPE_MIN_LENGTH + 4, math.max(baseRopeMax, reach))
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

		local elasticRestLength = math.clamp(ropeMax * ROPE_REST_LENGTH_MULT, ROPE_MIN_LENGTH, ropeMax)
		local startLength =
			math.clamp(math.max(dist * ROPE_ATTACH_START_MULT, elasticRestLength), ROPE_MIN_LENGTH, ropeMax)
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
			ropeConstraint.WinchResponsiveness = 48
			ropeConstraint.WinchSpeed = 12
			ropeConstraint.WinchForce = hrp.AssemblyMass * 1850
			ropeConstraint.WinchTarget = elasticRestLength
		end)

		if math.abs(dist - elasticRestLength) > 1.5 then
			zipSpring = Instance.new("SpringConstraint")
			zipSpring.Name = "SwingZipSpring"
			zipSpring.Attachment0 = anchorAttachment
			zipSpring.Attachment1 = bodyAttachment
			zipSpring.FreeLength = elasticRestLength
			zipSpring.Stiffness = ZIP_SPRING_STIFFNESS
			zipSpring.Damping = ZIP_SPRING_DAMPING
			zipSpring.MaxForce = hrp.AssemblyMass * ZIP_SPRING_MAX_ACCEL
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
		swingOrientation.Responsiveness = AVATAR_TURN_RESPONSIVENESS
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

	local function applyReleaseLaunch(
		snapVelocity,
		snapPosition,
		snapAnchorWorld,
		heldTime,
		charge,
		forwardCharge,
		forwardHeldTime,
		momentum
	)
		camera = workspace.CurrentCamera or camera
		if not camera or not hrp.Parent then
			return
		end

		hrp.AssemblyLinearVelocity = snapVelocity
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

		local velocity = snapVelocity
		local camLook = camera.CFrame.LookVector
		local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
		local camFlatUnit = camFlat.Magnitude > 0.08 and camFlat.Unit or Vector3.new(0, 0, -1)
		local holdMult = math.clamp(heldTime / MIN_HOLD_FOR_FULL_LAUNCH, 0.92, 1)
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
		local facingDir = camFlatUnit
		local launchDir = facingDir

		if tangSpeed > 2 then
			local tangentBlend = math.clamp(LAUNCH_MOMENTUM_RATIO + tangSpeed / 260, 0, 0.22)
			launchDir = facingDir * (1 - tangentBlend) + tangVelocity.Unit * tangentBlend
		end
		if launchDir.Magnitude > 0.05 then
			launchDir = launchDir.Unit
		else
			launchDir = facingDir
		end

		local forwardHoldBonus = math.clamp(forwardHeldTime / FORWARD_CHARGE_TIME, 0, 1)
		local inputBoost = math.clamp(forwardCharge + forwardHoldBonus * 0.35, 0, 1.35)
		local momentumBoost = math.clamp(momentum or 0, 0, 1)
		local cap = LAUNCH_SPEED_CAP
			* math.clamp(0.95 + (launchScale - 1) * 0.45, 0.9, 1.15)
			* (1 + momentumBoost * SWING_MOMENTUM_LAUNCH_BONUS)

		local horizontalSpeed = (
			LAUNCH_FORWARD_DV
			+ LAUNCH_FORWARD_INPUT_DV * inputBoost
			+ LAUNCH_CHARGE_DV * charge * 0.35
			+ LAUNCH_FORWARD_DV * SWING_MOMENTUM_LAUNCH_BONUS * momentumBoost
		)
			* holdMult
			* launchScale
		local upwardSpeed = (LAUNCH_UP_DV + LAUNCH_CHARGE_DV * charge * 0.45 + inputBoost * 3 + momentumBoost * 4)
			* holdMult
			* launchScale
		local targetVelocity = launchDir * horizontalSpeed + Vector3.new(0, upwardSpeed, 0)

		if targetVelocity.Magnitude > cap then
			targetVelocity = targetVelocity.Unit * cap
		end
		hrp.AssemblyLinearVelocity = targetVelocity
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

		isSwinging = false
		currentTarget = nil
		stopHangAnim()
		destroySwingObjects()
		stopOptionalSound("Wind")

		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		if doLaunch then
			isLaunched = true
			landedFromSwing = true
			lastLaunchClock = os.clock()
			playFallingAnim()
			playOptionalSound("Launch")
			task.defer(function()
				applyReleaseLaunch(
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
		end
	end

	local function spawnLandingBlocks(speed)
		local alpha = math.clamp((speed - 16) / 86, 0, 1)
		if alpha <= 0 then
			return
		end

		rayParams.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -10, 0), rayParams)
		local pos = hit and hit.Position or (hrp.Position - Vector3.new(0, 3, 0))
		local color = hit and hit.Instance and hit.Instance.Color or Color3.fromRGB(120, 120, 120)
		local material = hit and hit.Material or Enum.Material.Concrete
		local count = math.floor(10 + alpha * 24)

		local ring = Instance.new("Part")
		ring.Name = "SwingImpactRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CastShadow = false
		ring.Material = Enum.Material.SmoothPlastic
		ring.Color = color:Lerp(Color3.new(1, 1, 1), 0.35)
		ring.Transparency = 0.58
		ring.Size = Vector3.new(0.08, 2.5 + alpha * 2.5, 2.5 + alpha * 2.5)
		ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace
		TweenService:Create(ring, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.08, 12 + alpha * 11, 12 + alpha * 11),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring, 0.5)

		for _ = 1, count do
			local size = math.random(42, 135) / 100
			local part = Instance.new("Part")
			part.Name = "SwingLandingChunk"
			part.Size = Vector3.new(size, size * math.random(70, 130) / 100, size)
			part.Material = material
			part.Color = color
			part.CanCollide = false
			part.CastShadow = false
			part.CFrame = CFrame.new(pos + Vector3.new(math.random(-22, 22) / 10, 0.2, math.random(-22, 22) / 10))
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			part.Parent = workspace

			local angle = math.random() * math.pi * 2
			local outSpeed = math.random(18, 42) * (0.78 + alpha * 0.5)
			local upSpeed = math.random(14, 34) * (0.78 + alpha * 0.5)
			part.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * outSpeed, upSpeed, math.sin(angle) * outSpeed)
			part.AssemblyAngularVelocity = Vector3.new(math.random(-13, 13), math.random(-13, 13), math.random(-13, 13))

			TweenService:Create(part, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
				Size = Vector3.new(0.06, 0.06, 0.06),
			}):Play()
			Debris:AddItem(part, 0.9)
		end

		local chipCount = math.floor(8 + alpha * 18)
		for _ = 1, chipCount do
			local size = math.random(16, 36) / 100
			local chip = Instance.new("Part")
			chip.Name = "SwingLandingChip"
			chip.Size = Vector3.new(size, size, size)
			chip.Material = material
			chip.Color = color:Lerp(Color3.new(1, 1, 1), math.random(0, 18) / 100)
			chip.CanCollide = false
			chip.CastShadow = false
			chip.CFrame = CFrame.new(pos + Vector3.new(math.random(-18, 18) / 10, 0.16, math.random(-18, 18) / 10))
			chip.Parent = workspace

			local angle = math.random() * math.pi * 2
			local outSpeed = math.random(24, 54) * (0.8 + alpha * 0.55)
			local upSpeed = math.random(18, 42) * (0.75 + alpha * 0.55)
			chip.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * outSpeed, upSpeed, math.sin(angle) * outSpeed)
			chip.AssemblyAngularVelocity = Vector3.new(math.random(-18, 18), math.random(-18, 18), math.random(-18, 18))

			TweenService:Create(chip, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
				Size = Vector3.new(0.03, 0.03, 0.03),
			}):Play()
			Debris:AddItem(chip, 0.65)
		end
	end

	local function tryAttach()
		if isSwinging or not hrp.Parent then
			return
		end

		local now = os.clock()
		if now - lastTryClock < ATTACH_RETRY_TIME then
			return
		end
		lastTryClock = now

		local maxDistance = getSwingRange()
		local lookDot = AIRBORNE_TARGET_LOOK_DOT
		local screenLimit = TARGET_SCREEN_RADIUS_LIMIT
		if not isAirborneForSwing() then
			return
		end

		local target = pickSwingTarget(true, maxDistance, lookDot, screenLimit)
		if target then
			startSwing(target)
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
		stroke.Color = READY_COLOR
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
			if isSwinging and os.clock() - lastAttachClock > MIN_SWING_LOCK_TIME then
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
			if isSwinging and os.clock() - lastAttachClock > MIN_SWING_LOCK_TIME then
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
			if isSwinging and os.clock() - lastAttachClock > MIN_SWING_LOCK_TIME then
				stopSwing(true)
			end
		elseif
			input.UserInputType == Enum.UserInputType.Gamepad1
			and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonA)
		then
			gamepadHeld = false
			if isSwinging and os.clock() - lastAttachClock > MIN_SWING_LOCK_TIME then
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
			local swingLanding = landedFromSwing or isLaunched
			if not isSwinging and swingLanding then
				playLandedAnim()
			end
			local impactSpeed = landingSpeed
			if landedFromSwing then
				spawnLandingBlocks(impactSpeed)
				playOptionalSound("Land")
				local impactAlpha = math.clamp((impactSpeed - 16) / 86, 0.2, 1)
				lastLandingClock = os.clock()
				landingShakeStrength = math.clamp(0.28 + impactAlpha * 0.72, 0, 1)
				landingShakeSeed = math.random() * 1000
			end
			landedFromSwing = false
			isLaunched = false
			landingSpeed = 0
			hideSwingTargetUi()
		elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics then
			isAirborne = false
			stopFallingAnim()
			hideSwingTargetUi()
		end
	end))

	addConn(humanoid.Died:Connect(function()
		if isSwinging then
			stopSwing(false)
		end
		stopHangAnim()
		stopFallingAnim()
		stopTrack(landedTrack, 0.08)
	end))

	RunService:BindToRenderStep(renderBindName, Enum.RenderPriority.Camera.Value + 1, function(dt)
		camera = workspace.CurrentCamera or camera
		if not camera or not hrp.Parent then
			return
		end

		local now = os.clock()
		local launchShakeActive = now - lastLaunchClock >= 0 and now - lastLaunchClock < LAUNCH_CAMERA_SHAKE_TIME
		local landingShakeActive = now - lastLandingClock >= 0 and now - lastLandingClock < LANDING_CAMERA_SHAKE_TIME
		if
			not ENABLE_GROUNDED_CAMERA_ASSIST
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
				local assistAlpha = math.clamp(dt * CAMERA_ASSIST_STRENGTH, 0, 0.035)
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
			targetRoll = -lateral * SWING_CAMERA_ROLL_MAX
			targetLag = -cf.LookVector * math.clamp(speed / swingSpeedRef, 0, 1) * SWING_CAMERA_LAG_MAX
			targetLag += Vector3.new(0, math.clamp(-velocity.Y / 160, -0.18, 0.28), 0)
		elseif isLaunched then
			local lateral = math.clamp(velocity:Dot(cf.RightVector) / math.max(LAUNCH_SPEED_CAP, 1), -1, 1)
			targetRoll = -lateral * SWING_CAMERA_ROLL_MAX * 0.55
		end

		local smooth = math.min(dt * SWING_CAMERA_EFFECT_SPEED, 1)
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
		if launchAge >= 0 and launchAge < LAUNCH_CAMERA_SHAKE_TIME then
			local speedAlpha = math.clamp(speed / math.max(LAUNCH_SPEED_CAP, 1), 0.25, 1)
			addShake(lastLaunchClock, LAUNCH_CAMERA_SHAKE_TIME, LAUNCH_CAMERA_SHAKE_STRENGTH * speedAlpha, 240.5, 0.045)
		end
		addShake(
			lastLandingClock,
			LANDING_CAMERA_SHAKE_TIME,
			LANDING_CAMERA_SHAKE_STRENGTH * landingShakeStrength,
			landingShakeSeed,
			0.055
		)

		if shakeOffset.Magnitude > 0.0001 or shakeRot.Magnitude > 0.0001 then
			cf = cf * CFrame.new(shakeOffset) * CFrame.Angles(shakeRot.X, shakeRot.Y, shakeRot.Z)
		end

		camera.CFrame = cf
	end)

	local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
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
			if swingTimer > MIN_SWING_LOCK_TIME and not holdIsActive() then
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
			local ropeMax = activeRopeMaxLength or getRopeMaxLength()
			local speedCap = getMaxSwingSpeed() * (1 + swingMomentum * SWING_MOMENTUM_SPEED_BONUS)
			local extT = math.clamp(dist / math.max(ropeMax, 1), 0, 1.15)
			local decay = math.clamp(swingTimer / FORCE_DECAY_TIME, 0, 1)
			local mult = 1 - decay * (1 - FORCE_MIN_MULT)

			if zipSpring then
				local zipAlpha = math.clamp(1 - swingTimer / ZIP_PULL_TIME, 0, 1)
				if zipAlpha <= 0 then
					zipSpring:Destroy()
					zipSpring = nil
				else
					zipSpring.MaxForce = hrp.AssemblyMass * ZIP_SPRING_MAX_ACCEL * zipAlpha
				end
			end

			if ropeConstraint then
				local baseRestLength = math.clamp(ropeMax * ROPE_REST_LENGTH_MULT, ROPE_MIN_LENGTH, ropeMax)
				local speedStretch = math.clamp((speed - 18) / math.max(speedCap - 18, 1), 0, 1)
				local stretchAlpha =
					math.clamp(swingMomentum * 0.72 + speedStretch * 0.28 + forwardSwingCharge * 0.1, 0, 1)
				local elasticRestLength = math.clamp(
					baseRestLength + ropeMax * ROPE_MOMENTUM_LENGTH_MULT * stretchAlpha,
					ROPE_MIN_LENGTH,
					ropeMax
				)
				local stretchExtra = math.clamp(dist - elasticRestLength, 0, ropeMax)
					* ROPE_DISTANCE_STRETCH_MULT
					* (0.35 + stretchAlpha * 0.65)
				local targetLength = math.clamp(elasticRestLength + stretchExtra, elasticRestLength, ropeMax)
				local lengthAlpha = math.clamp(dt * ROPE_LENGTH_RESPONSE, 0, 1)
				ropeConstraint.Length += (targetLength - ropeConstraint.Length) * lengthAlpha
				pcall(function()
					ropeConstraint.WinchTarget = elasticRestLength
					ropeConstraint.WinchSpeed = 10 + swingCharge * 4 + swingMomentum * 3
				end)
				if ropeConstraint.Length > ropeMax then
					ropeConstraint.Length = ropeMax
				end
			end

			local camLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
			local camRight = camera and camera.CFrame.RightVector or hrp.CFrame.RightVector
			local moveDir = humanoid.MoveDirection
			local camFlat = flatUnit(camLook) or flatUnit(hrp.CFrame.LookVector)
			local moveFlat = Vector3.new(moveDir.X, 0, moveDir.Z)
			local moveFlatUnit = moveFlat.Magnitude > 0.05 and moveFlat.Unit or nil
			local forwardInput = forwardInputAmount()
			if forwardInput > 0.08 then
				forwardHoldTime += dt * forwardInput
				forwardSwingCharge = math.min(1, forwardSwingCharge + dt * forwardInput / FORWARD_CHARGE_TIME)
			else
				forwardHoldTime = math.max(0, forwardHoldTime - dt * 0.55)
				forwardSwingCharge = math.max(0, forwardSwingCharge - dt * 0.7)
			end

			swingRhythmBoost = math.max(0, swingRhythmBoost - SWING_RHYTHM_DECAY_RATE * dt)
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
						* DEAD_HANG_MOVE_FORCE
						* (0.35 + lowSpeedBoost * 0.65)
						* mult
						* hrp.AssemblyMass
					swingMomentum = math.min(
						1,
						swingMomentum
							+ SWING_DEAD_HANG_MOMENTUM_BUILD_RATE
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
						* SWING_INPUT_ORBIT_FORCE
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
						SWING_MOMENTUM_BUILD_RATE * pumpQuality * speedFactor
						+ SWING_MOMENTUM_FORWARD_BUILD_RATE * forwardInput
						+ SWING_RHYTHM_BUILD_RATE * rhythmQuality
					) * dt
					swingMomentum = math.min(1, swingMomentum + build)
				elseif not moveFlatUnit or tangSpeed < 5 then
					swingMomentum = math.max(0, swingMomentum - SWING_MOMENTUM_IDLE_DECAY_RATE * dt)
				elseif moveAlongTangent < -0.2 then
					if tangSpeed < targetTangSpeed * 0.62 or swingRhythmBoost > 0.12 then
						local reversalBuild = SWING_REVERSAL_BUILD_RATE
							* math.abs(moveAlongTangent)
							* (0.35 + lowSpeedPump * 0.65 + swingRhythmBoost * 0.35)
							* dt
						swingMomentum = math.min(1, swingMomentum + reversalBuild)
					else
						swingMomentum = math.max(
							0,
							swingMomentum - SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * math.abs(moveAlongTangent) * 0.38 * dt
						)
					end
				else
					swingMomentum = math.max(0, swingMomentum - SWING_MOMENTUM_BAD_INPUT_DECAY_RATE * 0.28 * dt)
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
						pumpForce += moveTangent.Unit * SWING_RHYTHM_FORCE * swingRhythmBoost * (0.45 + math.abs(
							moveAlongTangent
						) * 0.55) * mult * hrp.AssemblyMass
					end
					if
						moveTangent.Magnitude > 0.05
						and moveAlongTangent < -0.12
						and (tangSpeed < targetTangSpeed * 0.62 or swingRhythmBoost > 0.12)
					then
						pumpForce += moveTangent.Unit * SWING_REVERSAL_FORCE * math.abs(moveAlongTangent) * (0.35 + lowSpeedPump * 0.65) * mult * hrp.AssemblyMass
					end
				end

				if floorMult < 0.3 and velocity.Y < -10 then
					hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y * 0.84, velocity.Z)
				end
			else
				if moveTangent.Magnitude > 0.05 then
					deadHangForce = moveTangent.Unit * DEAD_HANG_MOVE_FORCE * 0.72 * mult * hrp.AssemblyMass
					swingMomentum =
						math.min(1, swingMomentum + SWING_DEAD_HANG_MOMENTUM_BUILD_RATE * moveTangent.Magnitude * dt)
				else
					swingMomentum = math.max(0, swingMomentum - SWING_MOMENTUM_IDLE_DECAY_RATE * dt)
				end
			end

			local arcWeight = 0.36 + math.clamp((extT - 0.25) / 0.75, 0, 1) * 0.56
			if steerForce then
				steerForce.Force = camSteerForce * (1 - arcWeight * 0.45)
					+ arcForce
					+ pumpForce
					+ deadHangForce
					+ orbitInputForce
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
					local quickTurn = currentFace and desiredUnit:Dot(currentFace) < AVATAR_FAST_TURN_DOT
					local turnRate = quickTurn and AVATAR_NATURAL_FACE_FAST_TURN_RATE or AVATAR_NATURAL_FACE_TURN_RATE
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
						swingOrientation.Responsiveness = AVATAR_TURN_RESPONSIVENESS + (quickTurn and 14 or 0)
						swingOrientation.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + swingFaceDir.Unit)
					end
				end
			end

			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-ANGULAR_DAMP * dt)
			if speed > speedCap then
				hrp.AssemblyLinearVelocity = velocity.Unit * speedCap
			end

			swingCharge = math.min(1, swingCharge + dt / CHARGE_TIME)
			layoutCharge()
		else
			if holdIsActive() then
				tryAttach()
			end

			local scanMode = isAirborneForSwing() and "air" or "none"

			if scanMode == "none" then
				hideSwingTargetUi()
			else
				local needsScan = scanMode ~= lastTargetScanMode
					or now - lastTargetScanClock >= TARGET_SCAN_INTERVAL
					or not scannedVisualTarget
					or not scannedVisualTarget.Parent

				if needsScan then
					lastTargetScanClock = now
					lastTargetScanMode = scanMode
					local readyTarget =
						pickSwingTarget(false, getSwingRange(), AIRBORNE_TARGET_LOOK_DOT, TARGET_SCREEN_RADIUS_LIMIT)
					if readyTarget then
						scannedVisualTarget = readyTarget
						scannedVisualCanSwing = true
					else
						scannedVisualTarget = pickNearbySwingTarget(getAirborneTargetUiRange(), highlightedTarget)
						scannedVisualCanSwing = false
					end
					updateTargetVisual(scannedVisualTarget, scannedVisualCanSwing)
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
				targetFov = originalFov + (FOV_MAX - originalFov) * t
			end

			local attachAge = os.clock() - lastAttachClock
			if isSwinging and attachAge >= 0 and attachAge < ATTACH_FOV_TIME then
				local u = attachAge / ATTACH_FOV_TIME
				targetFov -= ATTACH_FOV_PUNCH * math.sin(u * math.pi)
			end

			local launchAge = os.clock() - lastLaunchClock
			if launchAge >= 0 and launchAge < LAUNCH_FOV_TIME then
				local u = 1 - launchAge / LAUNCH_FOV_TIME
				targetFov += LAUNCH_FOV_BOOST * u * u
			end

			local landingAge = os.clock() - lastLandingClock
			if landingAge >= 0 and landingAge < LANDING_FOV_TIME then
				local u = 1 - landingAge / LANDING_FOV_TIME
				targetFov -= LANDING_FOV_KICK * u * u * landingShakeStrength
			end

			camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(dt * FOV_SPEED, 1)
		end
	end)

	addConn(heartbeatConn)

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
		destroySwingObjects()
		destroyPreview(true)
		if highlight then
			highlight:Destroy()
			highlight = nil
		end
		if markerGui then
			markerGui:Destroy()
			markerGui = nil
		end
		if markerAnchorPart then
			markerAnchorPart:Destroy()
			markerAnchorPart = nil
		end
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
		stopHangAnim()
		stopFallingAnim()
		stopTrack(landedTrack, 0.12)
		stopOptionalSound("Wind")
		pcall(function()
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
		end)
		pcall(function()
			if camera then
				camera.FieldOfView = originalFov
			end
		end)
	end
end

local dispose = nil

local function onCharacter(character)
	if dispose then
		dispose()
		dispose = nil
	end
	dispose = boot(character)
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end
