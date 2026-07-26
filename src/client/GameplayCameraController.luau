-- [ACTIVE] GameplayCameraController
--[[
	Simple high top-down orbit. Snap follow (no lag lerp). Free RMB look.
	Swing blends elevation in-place; SwingSystem FX still layer at Camera+1.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local BIND_NAME = "GameplayCameraUpdate"
local ROTATE_ACTION = "GameplayCameraRotate"

local DEFAULT_FOV = 60
local MIN_ZOOM = 9
local MAX_ZOOM = 28
local DEFAULT_ZOOM = 17
local LOOK_HEIGHT = 1.0
local MOUSE_SENS = 0.007
local TOUCH_SENS = 0.01
local ELEV_MIN = math.rad(40)
local ELEV_MAX = math.rad(70)
local DEFAULT_ELEV = math.rad(55)

local SWING_ELEV = math.rad(22)
local SWING_ZOOM = 12
local SWING_FOV = 72
local SWING_BLEND_IN = 4
local SWING_BLEND_OUT = 3

local GameplayCameraController = {}

local enabled = false
local pauseDepth = 0
local swingOverride = false
local swingBlend = 0
local yaw = 0
local elevation = DEFAULT_ELEV
local zoom = DEFAULT_ZOOM
local renderBound = false
local rotateActionBound = false
local conns: { RBXScriptConnection } = {}
local rotating = false
local touchRotateId: number? = nil
local lastTouchPos: Vector2? = nil
local wheelDelta = 0
local occZoom = DEFAULT_ZOOM
local occClock = 0

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
	local camPos = focus + sphericalOffset(useYaw, useElev, useZoom)
	local hum = getHumanoid()
	if hum and hum.CameraOffset.Magnitude > 0.001 then
		camPos += hum.CameraOffset
	end
	return CFrame.lookAt(camPos, focus)
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
	e = if swingBlend > 0.01 then math.clamp(e, math.rad(12), ELEV_MAX) else clampElev(e)
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
	yaw -= dx * sens
	elevation = clampElev(elevation + dy * sens)
end

local function setRotating(on: boolean)
	if rotating == on then
		return
	end
	rotating = on
	UserInputService.MouseBehavior = if on then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
end

local function onRotateAction(_name: string, state: Enum.UserInputState, input: InputObject)
	if pauseDepth > 0 or not enabled then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		setRotating(true)
		return Enum.ContextActionResult.Sink
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		setRotating(false)
		return Enum.ContextActionResult.Sink
	elseif state == Enum.UserInputState.Change and rotating then
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			applyLook(input.Delta.X, input.Delta.Y, MOUSE_SENS)
			return Enum.ContextActionResult.Sink
		end
	end
	return Enum.ContextActionResult.Pass
end

local function onInputBegan(input: InputObject, _processed: boolean)
	if pauseDepth > 0 or not enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		if touchRotateId == nil and not UserInputService:GetFocusedTextBox() then
			touchRotateId = input.UserInputId
			lastTouchPos = Vector2.new(input.Position.X, input.Position.Y)
		end
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch and touchRotateId == input.UserInputId then
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
		-- Backup path if ContextAction doesn't deliver Change.
		applyLook(input.Delta.X, input.Delta.Y, MOUSE_SENS)
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

	cam.CameraType = Enum.CameraType.Scriptable
	local hum = getHumanoid()
	if hum then
		cam.CameraSubject = hum
	end

	-- Poll RMB in case action binding missed end/begin.
	local rmb = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	if rmb ~= rotating then
		setRotating(rmb)
	end
	if rotating then
		local d = UserInputService:GetMouseDelta()
		if d.X ~= 0 or d.Y ~= 0 then
			applyLook(d.X, d.Y, MOUSE_SENS)
		end
	end

	if wheelDelta ~= 0 then
		zoom = math.clamp(zoom - wheelDelta * 1.4, MIN_ZOOM, MAX_ZOOM)
		wheelDelta = 0
	end

	dt = math.clamp(dt, 0, 0.05)
	local blendTarget = if swingOverride then 1 else 0
	local blendSpeed = if blendTarget > swingBlend then SWING_BLEND_IN else SWING_BLEND_OUT
	swingBlend += (blendTarget - swingBlend) * math.min(1, dt * blendSpeed)
	if math.abs(swingBlend - blendTarget) < 0.002 then
		swingBlend = blendTarget
	end

	local focus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	local useElev, useZoom, useFov = blended()

	occClock += dt
	if occClock >= 0.08 then
		occClock = 0
		occZoom = sampleOcclusion(focus, yaw, useElev, useZoom)
	else
		-- Ease toward last occlusion sample without raycasting every frame.
		occZoom += (math.min(occZoom, useZoom) - occZoom) * math.min(1, dt * 12)
		if occZoom > useZoom then
			occZoom = useZoom
		elseif occZoom < useZoom * 0.98 then
			occZoom += (useZoom - occZoom) * math.min(1, dt * 6)
		end
	end

	cam.CFrame = orbitCFrame(focus, yaw, useElev, occZoom)
	if math.abs(cam.FieldOfView - useFov) < 20 then
		cam.FieldOfView += (useFov - cam.FieldOfView) * math.min(1, dt * 8)
	end
end

local function bindRotateAction()
	if rotateActionBound then
		return
	end
	rotateActionBound = true
	ContextActionService:BindActionAtPriority(
		ROTATE_ACTION,
		onRotateAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.UserInputType.MouseButton2,
		Enum.UserInputType.MouseMovement
	)
end

local function unbindRotateAction()
	if not rotateActionBound then
		return
	end
	rotateActionBound = false
	pcall(function()
		ContextActionService:UnbindAction(ROTATE_ACTION)
	end)
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
			if seedCf then
				cam.CFrame = seedCf
			end
		end
	end
end

function GameplayCameraController.enable()
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
		cam.FieldOfView = DEFAULT_FOV
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
	end
	bindRotateAction()
	bindRender()
end

function GameplayCameraController.disable()
	enabled = false
	pauseDepth = 0
	swingOverride = false
	swingBlend = 0
	setRotating(false)
	unbindRotateAction()
	unbindRender()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
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
				end
			end)
		end)
	)
end

return GameplayCameraController
