-- [ACTIVE] GameplayCameraController
--[[
	Free third-person orbit camera.
	- Full yaw + wide pitch (not locked to a tiny top-down cone)
	- RMB orbit, scroll zoom
	- Soft swing framing blend (stays Scriptable)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local BIND_NAME = "GameplayCameraUpdate"

local DEFAULT_FOV = 70
local MIN_ZOOM = 6
local MAX_ZOOM = 40
local DEFAULT_ZOOM = 14
local LOOK_HEIGHT = 1.35
local MOUSE_SENS = 0.0055
local TOUCH_SENS = 0.0085
-- Near-free pitch (avoid exact ±90° gimbal lock).
local ELEV_MIN = math.rad(2)
local ELEV_MAX = math.rad(89)
local DEFAULT_ELEV = math.rad(28)

local SWING_ELEV = math.rad(18)
local SWING_ZOOM = 11
local SWING_FOV = 74
local SWING_BLEND_SPEED = 3.2

local MOVE_EPS = 0.35
local OCCLUSION_INTERVAL = 0.2

local GameplayCameraController = {}

local enabled = false
local pauseDepth = 0
local swingOverride = false
local swingBlend = 0
local yaw = 0
local elevation = DEFAULT_ELEV
local zoom = DEFAULT_ZOOM
local renderBound = false
local conns: { RBXScriptConnection } = {}
local rotating = false
local touchRotateId: number? = nil
local lastTouchPos: Vector2? = nil
local wheelDelta = 0
local pendingLookX = 0
local pendingLookY = 0
local occZoom = DEFAULT_ZOOM
local occAccum = 0
local savedMouseBehavior: Enum.MouseBehavior? = nil
local inputWired = false

local function getRoot(): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function clampElev(v: number): number
	return math.clamp(v, ELEV_MIN, ELEV_MAX)
end

local function sphericalOffset(useYaw: number, useElev: number, useZoom: number): Vector3
	local flat = useZoom * math.cos(useElev)
	local height = useZoom * math.sin(useElev)
	return Vector3.new(math.sin(useYaw) * flat, height, math.cos(useYaw) * flat)
end

local function orbitCFrame(focus: Vector3, useYaw: number, useElev: number, useZoom: number): CFrame
	return CFrame.lookAt(focus + sphericalOffset(useYaw, useElev, useZoom), focus)
end

local function sampleOcclusion(focus: Vector3, useYaw: number, useElev: number, desired: number): number
	local dir = sphericalOffset(useYaw, useElev, 1)
	if dir.Magnitude < 0.05 then
		return desired
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(focus, dir.Unit * desired, params)
	if hit then
		return math.max(MIN_ZOOM * 0.55, hit.Distance - 0.55)
	end
	return desired
end

local function blended(): (number, number, number)
	local e = elevation + (SWING_ELEV - elevation) * swingBlend
	e = clampElev(e)
	local z = zoom + (SWING_ZOOM - zoom) * swingBlend
	local f = DEFAULT_FOV + (SWING_FOV - DEFAULT_FOV) * swingBlend
	return e, z, f
end

function GameplayCameraController.getIdealCFrame(root: BasePart?): CFrame
	local r = root or getRoot()
	if not r then
		local cam = Workspace.CurrentCamera
		return if cam then cam.CFrame else CFrame.identity
	end
	local e, z = blended()
	return orbitCFrame(r.Position + Vector3.new(0, LOOK_HEIGHT, 0), yaw, e, z)
end

function GameplayCameraController.syncFromCFrame(cf: CFrame)
	local root = getRoot()
	local focus = if root then root.Position + Vector3.new(0, LOOK_HEIGHT, 0) else cf.Position + cf.LookVector * 12
	local toCam = cf.Position - focus
	if toCam.Magnitude > 0.5 then
		local flat = Vector3.new(toCam.X, 0, toCam.Z)
		if flat.Magnitude > 0.05 then
			yaw = math.atan2(flat.X, flat.Z)
		end
		elevation = clampElev(math.asin(math.clamp(toCam.Unit.Y, -1, 1)))
		zoom = math.clamp(toCam.Magnitude, MIN_ZOOM, MAX_ZOOM)
		occZoom = zoom
	end
end

local function applyLook(dx: number, dy: number, sens: number)
	if dx == 0 and dy == 0 then
		return
	end
	yaw -= dx * sens
	elevation = clampElev(elevation + dy * sens)
end

local function setRotating(on: boolean)
	if rotating == on then
		return
	end
	rotating = on
	if on then
		savedMouseBehavior = UserInputService.MouseBehavior
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		pendingLookX = 0
		pendingLookY = 0
	else
		UserInputService.MouseBehavior = savedMouseBehavior or Enum.MouseBehavior.Default
		savedMouseBehavior = nil
		pendingLookX = 0
		pendingLookY = 0
	end
end

local function onInputBegan(input: InputObject, processed: boolean)
	if pauseDepth > 0 or not enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRotating(true)
	elseif input.UserInputType == Enum.UserInputType.Touch and not processed then
		if touchRotateId == nil and not UserInputService:GetFocusedTextBox() then
			touchRotateId = input.UserInputId
			lastTouchPos = Vector2.new(input.Position.X, input.Position.Y)
		end
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRotating(false)
	elseif input.UserInputType == Enum.UserInputType.Touch and touchRotateId == input.UserInputId then
		touchRotateId = nil
		lastTouchPos = nil
	end
end

local function onInputChanged(input: InputObject, _processed: boolean)
	if pauseDepth > 0 or not enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		wheelDelta += input.Position.Z
	elseif input.UserInputType == Enum.UserInputType.MouseMovement and rotating then
		pendingLookX += input.Delta.X
		pendingLookY += input.Delta.Y
	elseif input.UserInputType == Enum.UserInputType.Touch and touchRotateId == input.UserInputId then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if lastTouchPos then
			applyLook(pos.X - lastTouchPos.X, pos.Y - lastTouchPos.Y, TOUCH_SENS)
		end
		lastTouchPos = pos
	end
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
		yaw = math.atan2(-look.X, -look.Z) + math.pi
	end
	elevation = DEFAULT_ELEV
	zoom = DEFAULT_ZOOM
	occZoom = DEFAULT_ZOOM
	swingBlend = 0
end

local function canDriveCamera(): boolean
	return enabled and pauseDepth == 0
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
	-- Scriptable + Humanoid subject can fight free orbit; leave subject nil.
	if cam.CameraSubject ~= nil then
		cam.CameraSubject = nil
	end

	local rmb = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	if rmb ~= rotating then
		setRotating(rmb)
	end

	if rotating then
		local dx = pendingLookX
		local dy = pendingLookY
		pendingLookX = 0
		pendingLookY = 0
		if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then
			local d = UserInputService:GetMouseDelta()
			dx = d.X
			dy = d.Y
		end
		applyLook(dx, dy, MOUSE_SENS)
	end

	if wheelDelta ~= 0 then
		zoom = math.clamp(zoom - wheelDelta * 1.6, MIN_ZOOM, MAX_ZOOM)
		wheelDelta = 0
	end

	dt = math.clamp(dt, 0, 0.05)
	local blendTarget = if swingOverride then 1 else 0
	swingBlend += (blendTarget - swingBlend) * math.min(1, dt * SWING_BLEND_SPEED)
	if math.abs(swingBlend - blendTarget) < 0.002 then
		swingBlend = blendTarget
	end

	local focus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	local useElev, useZoom, useFov = blended()

	local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	local standingStill = speed < MOVE_EPS and not rotating and swingBlend < 0.05

	if standingStill then
		occZoom = useZoom
		occAccum = 0
	else
		occAccum += dt
		if occAccum >= OCCLUSION_INTERVAL or rotating then
			occAccum = 0
			local desired = sampleOcclusion(focus, yaw, useElev, useZoom)
			occZoom += (desired - occZoom) * 0.45
		else
			occZoom += (useZoom - occZoom) * math.min(1, dt * 5)
		end
	end

	local cf = orbitCFrame(focus, yaw, useElev, occZoom)
	local hum = getHumanoid()
	if hum and hum.CameraOffset.Magnitude > 0.001 then
		cf = cf * CFrame.new(hum.CameraOffset)
	end
	cam.CFrame = cf

	if swingBlend > 0.02 or math.abs(cam.FieldOfView - useFov) > 0.15 then
		if math.abs(cam.FieldOfView - useFov) < 22 then
			cam.FieldOfView += (useFov - cam.FieldOfView) * math.min(1, dt * 6)
		end
	elseif math.abs(cam.FieldOfView - DEFAULT_FOV) > 0.05 and math.abs(cam.FieldOfView - DEFAULT_FOV) < 14 then
		cam.FieldOfView = DEFAULT_FOV
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
	return swingOverride or swingBlend > 0.05
end

function GameplayCameraController.setSwingOverride(active: boolean)
	if swingOverride == active then
		return
	end
	swingOverride = active
	local cam = Workspace.CurrentCamera
	if cam and enabled and pauseDepth == 0 then
		cam.CameraType = Enum.CameraType.Scriptable
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
	else
		seedAnglesFromCharacter()
	end
	if canDriveCamera() then
		local cam = Workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CameraSubject = nil
			if seedCf then
				cam.CFrame = seedCf
			end
		end
	end
end

function GameplayCameraController.enable()
	if not inputWired then
		GameplayCameraController.init()
	end
	if enabled then
		return
	end
	enabled = true
	pauseDepth = 0
	swingOverride = false
	swingBlend = 0
	seedAnglesFromCharacter()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		cam.FieldOfView = DEFAULT_FOV
		local root = getRoot()
		if root then
			cam.CFrame = orbitCFrame(root.Position + Vector3.new(0, LOOK_HEIGHT, 0), yaw, elevation, zoom)
		end
	end
	bindRender()
end

function GameplayCameraController.disable()
	enabled = false
	pauseDepth = 0
	swingOverride = false
	swingBlend = 0
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
	inputWired = true
	table.insert(conns, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(conns, UserInputService.InputEnded:Connect(onInputEnded))
	table.insert(conns, UserInputService.InputChanged:Connect(onInputChanged))
	table.insert(
		conns,
		player.CharacterAdded:Connect(function()
			task.defer(function()
				if canDriveCamera() then
					seedAnglesFromCharacter()
				end
			end)
		end)
	)
end

return GameplayCameraController
