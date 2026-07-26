-- [ACTIVE] GameplayCameraController
--[[
	High top-down orbit (Pokemon / ARPG).
	Uses explicit spherical elevation so the lens sits ABOVE the character.
	Swing stays Scriptable and blends into a behind-follow profile; SwingSystem
	FX still layer at Camera+1 (no hard Custom cut).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local BIND_NAME = "GameplayCameraUpdate"

-- Top-down framing (elevation = angle above horizon; 90° = straight overhead)
local DEFAULT_FOV = 60
local MIN_ZOOM = 9
local MAX_ZOOM = 28
local DEFAULT_ZOOM = 17
local LOOK_HEIGHT = 1.0
local MOUSE_SENS = 0.005
local TOUCH_SENS = 0.0075
local ELEV_MIN = math.rad(38)
local ELEV_MAX = math.rad(72)
local DEFAULT_ELEV = math.rad(55)

-- Swing framing (blend toward this — still Scriptable)
local SWING_ELEV = math.rad(22)
local SWING_ZOOM = 12
local SWING_FOV = 72
local SWING_BLEND_IN = 3.8 -- ~0.26s
local SWING_BLEND_OUT = 2.8 -- ~0.35s

-- Feel (tight follow — avoid bob/lookahead jitter)
local FOCUS_LAG = 26
local ZOOM_LAG = 11
local OCCLUSION_PADDING = 0.6
local OCCLUSION_SMOOTH = 16
local LOOKAHEAD_MAX = 0.85
local LOOKAHEAD_SPEED_REF = 20
local SPEED_FOV_MAX = 5
local SPEED_ZOOM_MAX = 1.6
local SPEED_REF = 22
local STRAFE_LEAN_MAX = math.rad(1.6)
local AUTO_YAW_DELAY = 1.0
local AUTO_YAW_SPEED = 2.0
local AUTO_YAW_MOVE_MIN = 3

local GameplayCameraController = {}

local enabled = false
local pauseDepth = 0
local swingOverride = false
local swingBlend = 0 -- 0 gameplay top-down → 1 swing profile
local yaw = 0
local elevation = DEFAULT_ELEV
local zoom = DEFAULT_ZOOM
local smoothZoom = DEFAULT_ZOOM
local smoothFocus: Vector3? = nil
local smoothOcclusionZoom: number? = nil
local smoothLean = 0
local smoothFov = DEFAULT_FOV
local lastManualOrbitClock = 0
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

local function clampElev(v: number): number
	return math.clamp(v, ELEV_MIN, ELEV_MAX)
end

-- Spherical offset: elevation 0 = horizon behind, 90° = directly above looking down.
local function sphericalOffset(useYaw: number, useElev: number, useZoom: number): Vector3
	local flat = useZoom * math.cos(useElev)
	local height = useZoom * math.sin(useElev)
	return Vector3.new(math.sin(useYaw) * flat, height, math.cos(useYaw) * flat)
end

local function orbitCFrame(focus: Vector3, useYaw: number, useElev: number, useZoom: number, lean: number): CFrame
	local offset = sphericalOffset(useYaw, useElev, useZoom)
	local right = Vector3.new(math.cos(useYaw), 0, -math.sin(useYaw))
	local camPos = focus + offset + right * (lean * useZoom * 0.08)

	local hum = getHumanoid()
	if hum then
		local off = hum.CameraOffset
		if off.Magnitude > 0.001 then
			-- Keep bush-shake offsets camera-relative-ish
			local along = offset.Magnitude > 0.05 and offset.Unit or Vector3.yAxis
			local side = right
			local up = along:Cross(side)
			if up.Magnitude > 0.05 then
				up = up.Unit
				camPos += side * off.X + up * off.Y + along * off.Z
			else
				camPos += off
			end
		end
	end

	return CFrame.lookAt(camPos, focus) * CFrame.Angles(0, 0, lean)
end

local function occlusionZoom(focus: Vector3, useYaw: number, useElev: number, desiredZoom: number): number
	local dir = sphericalOffset(useYaw, useElev, 1)
	if dir.Magnitude < 0.05 then
		return desiredZoom
	end
	dir = dir.Unit
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

local function blendedElevZoomFov(): (number, number, number)
	local e = elevation + (SWING_ELEV - elevation) * swingBlend
	-- During swing allow flatter elevation than gameplay clamp
	if swingBlend > 0.01 then
		e = math.clamp(e, math.rad(12), ELEV_MAX)
	else
		e = clampElev(e)
	end
	local z = smoothZoom + (SWING_ZOOM - smoothZoom) * swingBlend
	local f = smoothFov + (SWING_FOV - smoothFov) * swingBlend
	return e, z, f
end

function GameplayCameraController.getIdealCFrame(root: BasePart?): CFrame
	local r = root or getRoot()
	if not r then
		local cam = Workspace.CurrentCamera
		return if cam then cam.CFrame else CFrame.identity
	end
	local focus = r.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	local e, z = blendedElevZoomFov()
	return orbitCFrame(focus, yaw, e, z, 0)
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
		smoothZoom = zoom
		smoothOcclusionZoom = zoom
	end
	smoothFocus = focus
	lastManualOrbitClock = os.clock()
end

-- Mouse right → look right; mouse up → less top-down (toward horizon).
local function applyMouseDelta(dx: number, dy: number, sens: number)
	yaw -= dx * sens
	elevation = clampElev(elevation + dy * sens)
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
	if pauseDepth > 0 or not enabled then
		return
	end
	-- Allow orbit during swing blend (player can still tweak).
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
	if pauseDepth > 0 or not enabled then
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
	return (to - from + math.pi) % (math.pi * 2) - math.pi
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
		-- Place camera behind the character (opposite facing).
		yaw = math.atan2(-look.X, -look.Z) + math.pi
	end
	elevation = DEFAULT_ELEV
	zoom = DEFAULT_ZOOM
	smoothZoom = DEFAULT_ZOOM
	smoothFocus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	smoothOcclusionZoom = DEFAULT_ZOOM
	smoothLean = 0
	smoothFov = DEFAULT_FOV
	swingBlend = 0
	lastManualOrbitClock = os.clock()
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

	-- Smooth swing profile blend (no CameraType hard cut).
	local blendTarget = if swingOverride then 1 else 0
	local blendSpeed = if blendTarget > swingBlend then SWING_BLEND_IN else SWING_BLEND_OUT
	swingBlend += (blendTarget - swingBlend) * math.min(1, dt * blendSpeed)
	if math.abs(swingBlend - blendTarget) < 0.002 then
		swingBlend = blendTarget
	end

	local vel = root.AssemblyLinearVelocity
	local flatVel = Vector3.new(vel.X, 0, vel.Z)
	local speed = flatVel.Magnitude
	local speed01 = math.clamp(speed / SPEED_REF, 0, 1)

	-- During swing/launch, gently yaw toward velocity so FX feel intentional.
	if swingBlend > 0.15 and speed > 2 and not rotating then
		local moveYaw = math.atan2(flatVel.Unit.X, flatVel.Unit.Z) + math.pi
		yaw += shortestAngle(yaw, moveYaw) * math.min(1, dt * (1.8 + 2.5 * swingBlend))
	elseif not rotating and speed > AUTO_YAW_MOVE_MIN and (os.clock() - lastManualOrbitClock) > AUTO_YAW_DELAY and swingBlend < 0.05 then
		local moveYaw = math.atan2(flatVel.Unit.X, flatVel.Unit.Z) + math.pi
		yaw += shortestAngle(yaw, moveYaw) * math.min(1, dt * AUTO_YAW_SPEED * speed01)
	end

	smoothZoom += (zoom - smoothZoom) * math.min(1, dt * ZOOM_LAG)

	local lookAhead = Vector3.zero
	if speed > 1 and swingBlend < 0.5 then
		lookAhead = flatVel.Unit * (LOOKAHEAD_MAX * math.clamp(speed / LOOKAHEAD_SPEED_REF, 0, 1) * (1 - swingBlend))
	end
	local rawFocus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0) + lookAhead
	if not smoothFocus then
		smoothFocus = rawFocus
	else
		-- Tight tracking — high lag kills walk jitter.
		local a = math.min(1, dt * FOCUS_LAG)
		smoothFocus = (smoothFocus :: Vector3):Lerp(rawFocus, a)
	end

	local useElev, useZoomBase, useFov = blendedElevZoomFov()
	local speedZoom = SPEED_ZOOM_MAX * speed01 * (1 - swingBlend * 0.7)
	local desiredZoom = useZoomBase + speedZoom
	local desired = occlusionZoom(smoothFocus :: Vector3, yaw, useElev, desiredZoom)
	if not smoothOcclusionZoom then
		smoothOcclusionZoom = desired
	else
		smoothOcclusionZoom += (desired - smoothOcclusionZoom) * math.min(1, dt * OCCLUSION_SMOOTH)
	end

	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local lateral = if speed > 0.2 then flatVel:Dot(right) / math.max(speed, 1) else 0
	local targetLean = -lateral * STRAFE_LEAN_MAX * speed01 * (1 - swingBlend)
	smoothLean += (targetLean - smoothLean) * math.min(1, dt * 10)

	local gameplayFov = DEFAULT_FOV + SPEED_FOV_MAX * speed01
	smoothFov += (gameplayFov - smoothFov) * math.min(1, dt * 6)
	-- Recompute FOV after smoothFov update for this frame's blend
	local _, _, blendedFov = blendedElevZoomFov()

	cam.CFrame = orbitCFrame(smoothFocus :: Vector3, yaw, useElev, smoothOcclusionZoom :: number, smoothLean)

	if math.abs(cam.FieldOfView - blendedFov) < 18 then
		cam.FieldOfView += (blendedFov - cam.FieldOfView) * math.min(1, dt * 7)
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

-- Soft swing handoff: keep Scriptable, blend framing; SwingSystem FX stay on Camera+1.
function GameplayCameraController.setSwingOverride(active: boolean)
	if swingOverride == active then
		return
	end
	swingOverride = active
	if not active then
		lastManualOrbitClock = os.clock()
	end
	-- Stay Scriptable so we don't pop into default Custom behind-view.
	local cam = Workspace.CurrentCamera
	if cam and enabled and pauseDepth == 0 then
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
				local e, z = blendedElevZoomFov()
				cam.CFrame = orbitCFrame(smoothFocus, yaw, e, z, 0)
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
		if smoothFocus then
			cam.CFrame = orbitCFrame(smoothFocus, yaw, elevation, smoothZoom, 0)
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
