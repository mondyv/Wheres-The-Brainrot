-- [ACTIVE] GameplayCameraController
--[[
	Soft third-person orbit camera (Pokemon-like fluid follow).
	Replaces default Roblox Custom camera during gameplay.
	Cutscenes call pause()/resume(); CameraOffset (bush shake) is applied manually.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local BIND_NAME = "GameplayCameraUpdate"
local DEFAULT_FOV = 68
local MIN_ZOOM = 6
local MAX_ZOOM = 22
local DEFAULT_ZOOM = 13.5
local LOOK_HEIGHT = 1.55
local MOUSE_SENS = 0.0055
local TOUCH_SENS = 0.0085
local PITCH_MIN = math.rad(-35)
local PITCH_MAX = math.rad(55)
local DEFAULT_PITCH = math.rad(18)
local POS_LAG = 11
local ROT_LAG = 14
local ZOOM_LAG = 10
local OCCLUSION_PADDING = 0.55

local GameplayCameraController = {}

local enabled = false
local pauseDepth = 0
local yaw = 0
local pitch = DEFAULT_PITCH
local zoom = DEFAULT_ZOOM
local smoothZoom = DEFAULT_ZOOM
local smoothCf: CFrame? = nil
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

local function idealCFrameFromAngles(root: BasePart, useYaw: number, usePitch: number, useZoom: number): CFrame
	local focus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
	local rot = CFrame.fromOrientation(usePitch, useYaw, 0)
	local offset = rot:VectorToWorldSpace(Vector3.new(0, 0, useZoom))
	local camPos = focus + offset

	local ignore = { player.Character }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local delta = camPos - focus
	local dist = delta.Magnitude
	if dist > 0.05 then
		local hit = Workspace:Raycast(focus, delta.Unit * dist, params)
		if hit then
			camPos = hit.Position - delta.Unit * OCCLUSION_PADDING
		end
	end

	local hum = getHumanoid()
	if hum then
		local off = hum.CameraOffset
		if off.Magnitude > 0.001 then
			camPos += rot:VectorToWorldSpace(off)
		end
	end

	return CFrame.lookAt(camPos, focus)
end

function GameplayCameraController.getIdealCFrame(root: BasePart?): CFrame
	local r = root or getRoot()
	if not r then
		local cam = Workspace.CurrentCamera
		return if cam then cam.CFrame else CFrame.identity
	end
	return idealCFrameFromAngles(r, yaw, pitch, smoothZoom)
end

function GameplayCameraController.syncFromCFrame(cf: CFrame)
	local look = cf.LookVector
	local y = math.atan2(-look.X, -look.Z)
	local p = math.asin(math.clamp(look.Y, -1, 1))
	yaw = y
	pitch = clampPitch(-p + math.rad(6))
	smoothCf = cf
	local root = getRoot()
	if root then
		local focus = root.Position + Vector3.new(0, LOOK_HEIGHT, 0)
		zoom = math.clamp((cf.Position - focus).Magnitude, MIN_ZOOM, MAX_ZOOM)
		smoothZoom = zoom
	end
end

local function applyMouseDelta(dx: number, dy: number, sens: number)
	yaw -= dx * sens
	pitch = clampPitch(pitch + dy * sens)
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
	elseif UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

local function onInputBegan(input: InputObject, _processed: boolean)
	-- Ignore `processed` — SideUI / fullscreen chrome often marks RMB as processed.
	if pauseDepth > 0 or not enabled then
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
	if pauseDepth > 0 or not enabled then
		return
	end
	-- Wheel: accumulate; applied in update (also ignore processed — UI eats scroll often).
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		wheelDelta += input.Position.Z
	elseif input.UserInputType == Enum.UserInputType.Touch and touchRotateId == input.UserInputId then
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if lastTouchPos then
			local delta = pos - lastTouchPos
			applyMouseDelta(delta.X, delta.Y, TOUCH_SENS)
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
		yaw = math.atan2(-look.X, -look.Z)
	end
	pitch = DEFAULT_PITCH
	zoom = DEFAULT_ZOOM
	smoothZoom = DEFAULT_ZOOM
	smoothCf = idealCFrameFromAngles(root, yaw, pitch, smoothZoom)
end

local function update(dt: number)
	if pauseDepth > 0 or not enabled then
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

	-- Poll RMB + GetMouseDelta every frame (reliable vs InputChanged/processed).
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
	smoothZoom += (zoom - smoothZoom) * math.min(1, dt * ZOOM_LAG)

	local target = idealCFrameFromAngles(root, yaw, pitch, smoothZoom)
	if not smoothCf then
		smoothCf = target
	else
		local posAlpha = math.min(1, dt * POS_LAG)
		local rotAlpha = math.min(1, dt * ROT_LAG)
		local pos = smoothCf.Position:Lerp(target.Position, posAlpha)
		local look = smoothCf.LookVector:Lerp(target.LookVector, rotAlpha)
		if look.Magnitude < 0.05 then
			look = target.LookVector
		end
		smoothCf = CFrame.lookAt(pos, pos + look.Unit)
	end

	cam.CFrame = smoothCf :: CFrame
	if math.abs(cam.FieldOfView - DEFAULT_FOV) < 12 then
		cam.FieldOfView += (DEFAULT_FOV - cam.FieldOfView) * math.min(1, dt * 3)
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
	return enabled and pauseDepth == 0
end

function GameplayCameraController.isEnabled(): boolean
	return enabled
end

function GameplayCameraController.isPaused(): boolean
	return pauseDepth > 0
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
	elseif not smoothCf then
		seedAnglesFromCharacter()
	end
	if enabled and pauseDepth == 0 then
		local cam = Workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
			local hum = getHumanoid()
			if hum then
				cam.CameraSubject = hum
			end
			if seedCf then
				cam.CFrame = seedCf
			elseif smoothCf then
				cam.CFrame = smoothCf
			end
		end
	end
end

function GameplayCameraController.enable()
	if enabled then
		if pauseDepth == 0 then
			local cam = Workspace.CurrentCamera
			if cam then
				cam.CameraType = Enum.CameraType.Scriptable
			end
		end
		return
	end
	enabled = true
	pauseDepth = 0
	seedAnglesFromCharacter()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = DEFAULT_FOV
		local hum = getHumanoid()
		if hum then
			cam.CameraSubject = hum
		end
		if smoothCf then
			cam.CFrame = smoothCf
		end
	end
	bindRender()
end

function GameplayCameraController.disable()
	enabled = false
	pauseDepth = 0
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
				if enabled and pauseDepth == 0 then
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
