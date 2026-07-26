-- [ACTIVE] GameplayCameraController
--[[
	High top-down orbit camera (Pokemon / ARPG feel).
	- Soft focus lag + velocity look-ahead
	- Speed FOV + distance bloom
	- Light strafe lean / walk bob
	- Idle yaw auto-recenter toward move direction
	Cutscenes: pause()/resume(). Swing: setSwingOverride(true).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local BIND_NAME = "GameplayCameraUpdate"

-- Framing (steep top-down)
local DEFAULT_FOV = 62
local MIN_ZOOM = 8
local MAX_ZOOM = 26
local DEFAULT_ZOOM = 16
local LOOK_HEIGHT = 1.15
local MOUSE_SENS = 0.0052
local TOUCH_SENS = 0.008
local PITCH_MIN = math.rad(28) -- keep fairly top-down
local PITCH_MAX = math.rad(68)
local DEFAULT_PITCH = math.rad(48)

-- Feel
local FOCUS_LAG_XY = 14
local FOCUS_LAG_Z = 10
local ZOOM_LAG = 10
local OCCLUSION_PADDING = 0.55
local OCCLUSION_SMOOTH = 12
local LOOKAHEAD_MAX = 3.2
local LOOKAHEAD_SPEED_REF = 18
local SPEED_FOV_MAX = 7
local SPEED_ZOOM_MAX = 2.4
local SPEED_REF = 22
local STRAFE_LEAN_MAX = math.rad(3.2)
local BOB_AMOUNT = 0.07
local BOB_SPEED = 9.5
local AUTO_YAW_DELAY = 0.85
local AUTO_YAW_SPEED = 2.4
local AUTO_YAW_MOVE_MIN = 2.5

local GameplayCameraController = {}

local enabled = false
local pauseDepth = 0
local swingOverride = false
local yaw = 0
local pitch = DEFAULT_PITCH
local zoom = DEFAULT_ZOOM
local smoothZoom = DEFAULT_ZOOM
local smoothFocus: Vector3? = nil
local smoothOcclusionZoom: number? = nil
local smoothLean = 0
local smoothBob = 0
local smoothFov = DEFAULT_FOV
local lastManualOrbitClock = 0
local bobPhase = 0
local renderBound = false
local conns: { RBXScriptConnection } = {}
local rotating = false
local touchRotateId: number? = nil
local lastTouchPos: Vector2? = nil
local wheelDelta = 0

local function getRoot(): BasePart?
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
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function clampPitch(v: number): number
	return math.clamp(v, PITCH_MIN, PITCH_MAX)
end

local function orbitCFrame(
	focus: Vector3,
	useYaw: number,
	usePitch: number,
	useZoom: number,
	lean: number,
	bob: number
): CFrame
	local rot = CFrame.fromOrientation(usePitch, useYaw, 0)
	local camPos = focus + rot:VectorToWorldSpace(Vector3.new(0, 0, useZoom))
	-- Soft strafe lean + walk bob in camera-local space
	camPos += rot:VectorToWorldSpace(Vector3.new(lean * useZoom * 0.12, bob, 0))

	local hum = getHumanoid()
	if hum then
		local off = hum.CameraOffset
		if off.Magnitude > 0.001 then
			camPos += rot:VectorToWorldSpace(off)
		end
	end

	local lookTarget = focus + Vector3.new(0, bob * 0.35, 0)
	return CFrame.lookAt(camPos, lookTarget) * CFrame.Angles(0, 0, lean)
end

local function occlusionZoom(focus: Vector3, useYaw: number, usePitch: number, desiredZoom: number): number
	local rot = CFrame.fromOrientation(usePitch, useYaw, 0)
	local dir = rot:VectorToWorldSpace(Vector3.new(0, 0, 1))
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(focus, dir * desiredZoom, params)
	if hit then
		return math.max(MIN_ZOOM * 0.55, hit.Distance - OCCLUSION_PADDING)
	end
	return desiredZoom
end

function GameplayCameraController.getIdealCFrame(root: BasePart?): CFrame
	local r = root or getRoot()
	if not r then
		local cam = Workspace.CurrentCamera
		return if cam then cam.CFrame else CFrame.identity
	end
	local focus = r.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	return orbitCFrame(focus, yaw, pitch, smoothZoom, 0, 0)
end

function GameplayCameraController.syncFromCFrame(cf: CFrame)
	local look = cf.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	local p = math.asin(math.clamp(look.Y, -1, 1))
	-- Steep top-down: pitch is elevation of the orbit (positive = higher / more top-down).
	pitch = clampPitch(-p)
	local root = getRoot()
	if root then
		local focus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
		smoothFocus = focus
		zoom = math.clamp((cf.Position - focus).Magnitude, MIN_ZOOM, MAX_ZOOM)
		smoothZoom = zoom
		smoothOcclusionZoom = zoom
	end
	lastManualOrbitClock = os.clock()
end

-- Horizontal: mouse right → look right (yaw decreases). Vertical already feels correct.
local function applyMouseDelta(dx: number, dy: number, sens: number)
	yaw -= dx * sens
	pitch = clampPitch(pitch - dy * sens)
	lastManualOrbitClock = os.clock()
end

local function touchOverBlockingGui(pos: Vector3): boolean
	local guis = player:FindFirstChildOfClass("PlayerGui")
	if not guis then
		return false
	end
	local objs = guis:GetGuiObjectsAtPosition(pos.X, pos.Y)
	for _, obj in objs do
		if obj:IsA("GuiButton") or obj:IsA("TextBox") or obj:IsA("ScrollingFrame") then
			return true
		end
	end
	return false
end

local function setRotating(on: boolean)
	if rotating == on then
		return
	end
	rotating = on
	if on then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		lastManualOrbitClock = os.clock()
	elseif UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

local function onInputBegan(input: InputObject, _processed: boolean)
	if pauseDepth > 0 or not enabled or swingOverride then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRotating(true)
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if touchRotateId == nil and not UserInputService:GetFocusedTextBox() and not touchOverBlockingGui(input.Position) then
			touchRotateId = input.UserInputId
			lastTouchPos = Vector2.new(input.Position.X, input.Position.Y)
		end
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRotating(false)
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if touchRotateId == input.UserInputId then
			touchRotateId = nil
			lastTouchPos = nil
		end
	end
end

local function onInputChanged(input: InputObject, _processed: boolean)
	if pauseDepth > 0 or not enabled or swingOverride then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		wheelDelta += input.Position.Z
		lastManualOrbitClock = os.clock()
	elseif input.UserInputType == Enum.UserInputType.Touch and touchRotateId == input.UserInputId then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if lastTouchPos then
			local delta = pos - lastTouchPos
			applyMouseDelta(delta.X, delta.Y, TOUCH_SENS)
		end
		lastTouchPos = pos
	end
end

local function shortestAngle(from: number, to: number): number
	local d = (to - from + math.pi) % (math.pi * 2) - math.pi
	return d
end

local function seedAnglesFromCharacter()
	local root = getRoot()
	if not root then
		return
	end
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		yaw = 0
	else
		look = look.Unit
		yaw = math.atan2(-look.X, -look.Z)
	end
	pitch = DEFAULT_PITCH
	zoom = DEFAULT_ZOOM
	smoothZoom = DEFAULT_ZOOM
	smoothFocus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	smoothOcclusionZoom = DEFAULT_ZOOM
	smoothLean = 0
	smoothBob = 0
	smoothFov = DEFAULT_FOV
	bobPhase = 0
	lastManualOrbitClock = os.clock()
end

local function canDriveCamera(): boolean
	return enabled and pauseDepth == 0 and not swingOverride
end

local function update(dt: number)
	if not canDriveCamera() then
		return
	end
	local cam = Workspace.CurrentCamera
	local root = getRoot()
	if not cam or not root then
		return
	end

	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local hum = getHumanoid()
	if hum and cam.CameraSubject ~= hum then
		cam.CameraSubject = hum
	end

	local rmbDown = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	if rmbDown ~= rotating then
		setRotating(rmbDown)
	end
	if rotating then
		local delta = UserInputService:GetMouseDelta()
		if delta.X ~= 0 or delta.Y ~= 0 then
			applyMouseDelta(delta.X, delta.Y, MOUSE_SENS)
		end
	end
	if wheelDelta ~= 0 then
		zoom = math.clamp(zoom - wheelDelta * 1.35, MIN_ZOOM, MAX_ZOOM)
		wheelDelta = 0
	end

	dt = math.clamp(dt, 0, 0.05)
	local vel = root.AssemblyLinearVelocity
	local flatVel = Vector3.new(vel.X, 0, vel.Z)
	local speed = flatVel.Magnitude
	local speed01 = math.clamp(speed / SPEED_REF, 0, 1)

	-- Soft auto-recenter yaw toward move direction after a short idle-orbit delay.
	if not rotating and speed > AUTO_YAW_MOVE_MIN and (os.clock() - lastManualOrbitClock) > AUTO_YAW_DELAY then
		local moveYaw = math.atan2(-flatVel.Unit.X, -flatVel.Unit.Z)
		local deltaYaw = shortestAngle(yaw, moveYaw)
		yaw += deltaYaw * math.min(1, dt * AUTO_YAW_SPEED * speed01)
	end

	smoothZoom += (zoom - smoothZoom) * math.min(1, dt * ZOOM_LAG)

	-- Velocity look-ahead so the camera leads into turns / runs.
	local lookAhead = Vector3.zero
	if speed > 0.4 then
		lookAhead = flatVel.Unit * (LOOKAHEAD_MAX * math.clamp(speed / LOOKAHEAD_SPEED_REF, 0, 1))
	end
	local rawFocus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0) + lookAhead
	if not smoothFocus then
		smoothFocus = rawFocus
	else
		local cur = smoothFocus :: Vector3
		local xyAlpha = math.min(1, dt * FOCUS_LAG_XY)
		local zAlpha = math.min(1, dt * FOCUS_LAG_Z)
		smoothFocus = Vector3.new(
			cur.X + (rawFocus.X - cur.X) * xyAlpha,
			cur.Y + (rawFocus.Y - cur.Y) * zAlpha,
			cur.Z + (rawFocus.Z - cur.Z) * xyAlpha
		)
	end

	-- Speed bloom: pull out + widen FOV while moving.
	local speedZoom = SPEED_ZOOM_MAX * speed01
	local desiredZoom = smoothZoom + speedZoom
	local desired = occlusionZoom(smoothFocus :: Vector3, yaw, pitch, desiredZoom)
	if not smoothOcclusionZoom then
		smoothOcclusionZoom = desired
	else
		smoothOcclusionZoom += (desired - smoothOcclusionZoom) * math.min(1, dt * OCCLUSION_SMOOTH)
	end

	-- Strafe lean from camera-relative sideways velocity.
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local lateral = if speed > 0.2 then flatVel:Dot(right) / math.max(speed, 1) else 0
	local targetLean = -lateral * STRAFE_LEAN_MAX * speed01
	smoothLean += (targetLean - smoothLean) * math.min(1, dt * 8)

	-- Subtle walk bob when grounded and moving.
	local targetBob = 0
	if hum and hum.FloorMaterial ~= Enum.Material.Air and speed > 1.5 then
		bobPhase += dt * BOB_SPEED * (0.65 + speed01)
		targetBob = math.sin(bobPhase) * BOB_AMOUNT * speed01
	else
		bobPhase = 0
	end
	smoothBob += (targetBob - smoothBob) * math.min(1, dt * 10)

	local targetFov = DEFAULT_FOV + SPEED_FOV_MAX * speed01
	smoothFov += (targetFov - smoothFov) * math.min(1, dt * 5)

	cam.CFrame = orbitCFrame(
		smoothFocus :: Vector3,
		yaw,
		pitch,
		smoothOcclusionZoom :: number,
		smoothLean,
		smoothBob
	)

	-- Don't fight swing FOV punches far outside our band.
	if math.abs(cam.FieldOfView - smoothFov) < 14 then
		cam.FieldOfView += (smoothFov - cam.FieldOfView) * math.min(1, dt * 6)
	end
end

local function bindRender()
	if renderBound then
		return
	end
	renderBound = true
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value, update)
end

local function unbindRender()
	if not renderBound then
		return
	end
	renderBound = false
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
end

local function disconnectAll()
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
end

function GameplayCameraController.isActive(): boolean
	return canDriveCamera()
end

function GameplayCameraController.isEnabled(): boolean
	return enabled
end

function GameplayCameraController.isPaused(): boolean
	return pauseDepth > 0
end

function GameplayCameraController.isSwingOverride(): boolean
	return swingOverride
end

function GameplayCameraController.setSwingOverride(active: boolean)
	if swingOverride == active then
		return
	end
	swingOverride = active
	setRotating(false)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if active then
		cam.CameraType = Enum.CameraType.Custom
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
	elseif enabled and pauseDepth == 0 then
		GameplayCameraController.syncFromCFrame(cam.CFrame)
		cam.CameraType = Enum.CameraType.Scriptable
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
	end
end

function GameplayCameraController.pause()
	pauseDepth += 1
	setRotating(false)
end

function GameplayCameraController.resume(seedCf: CFrame?)
	if pauseDepth > 0 then
		pauseDepth -= 1
	end
	if seedCf then
		GameplayCameraController.syncFromCFrame(seedCf)
	elseif not smoothFocus then
		seedAnglesFromCharacter()
	end
	if canDriveCamera() then
		local cam = Workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			local hum = getHumanoid()
			if hum then
				cam.CameraSubject = hum
			end
			if seedCf then
				cam.CFrame = seedCf
			elseif smoothFocus then
				cam.CFrame = orbitCFrame(smoothFocus, yaw, pitch, smoothOcclusionZoom or smoothZoom, 0, 0)
			end
		end
	end
end

function GameplayCameraController.enable()
	if enabled then
		if canDriveCamera() then
			local cam = Workspace.CurrentCamera
			if cam then
				cam.CameraType = Enum.CameraType.Scriptable
			end
		end
		return
	end
	enabled = true
	pauseDepth = 0
	swingOverride = false
	seedAnglesFromCharacter()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = DEFAULT_FOV
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
		if smoothFocus then
			cam.CFrame = orbitCFrame(smoothFocus, yaw, pitch, smoothZoom, 0, 0)
		end
	end
	bindRender()
end

function GameplayCameraController.disable()
	enabled = false
	pauseDepth = 0
	swingOverride = false
	setRotating(false)
	unbindRender()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
	end
end

function GameplayCameraController.init()
	disconnectAll()
	table.insert(conns, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(conns, UserInputService.InputEnded:Connect(onInputEnded))
	table.insert(conns, UserInputService.InputChanged:Connect(onInputChanged))
	table.insert(
		conns,
		player.CharacterAdded:Connect(function()
			task.defer(function()
				if canDriveCamera() then
					seedAnglesFromCharacter()
					local cam = Workspace.CurrentCamera
					if cam then
						cam.CameraType = Enum.CameraType.Scriptable
						local hum = getHumanoid()
						if hum then
							cam.CameraSubject = hum
						end
					end
				end
			end)
		end)
	)
end

return GameplayCameraController
