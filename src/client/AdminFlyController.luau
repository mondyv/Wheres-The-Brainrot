-- [ACTIVE] AdminFlyController
-- Client fly mode toggled by AdminFlyEnabled attribute (admin `fly` command).
-- Desktop: WASD + Space/E up, Ctrl/Q down.
-- Mobile: thumbstick + on-screen Up/Down (Jump also ascends briefly).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local M = {}

local FLY_ATTR = "AdminFlyEnabled"
local FLY_SPEED = 90
local FLY_VERTICAL = 70
local JUMP_BOOST_SEC = 0.22

local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}
local inputConns: { RBXScriptConnection } = {}
local align: AlignOrientation? = nil
local attachment: Attachment? = nil
local linearVel: LinearVelocity? = nil

local cachedControls: any = nil
local controlsLoadFailed = false

local holdUpHud = false
local holdDownHud = false
local holdUpKeys = false
local holdDownKeys = false
local jumpBoostUntil = 0

local flyGui: ScreenGui? = nil

local function isTouchPrimary(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function getPlayerControls(): any?
	if cachedControls then
		return cachedControls
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
	if not controlsOk or typeof(controls) ~= "table" then
		controlsLoadFailed = true
		return nil
	end
	cachedControls = controls
	return cachedControls
end

local function getThumbMove(flatLook: Vector3, flatRight: Vector3): Vector3
	local controls = getPlayerControls()
	if not controls or typeof(controls.GetMoveVector) ~= "function" then
		return Vector3.zero
	end
	local ok, moveVector = pcall(function()
		return controls:GetMoveVector()
	end)
	if not ok or typeof(moveVector) ~= "Vector3" or moveVector.Magnitude < 0.05 then
		return Vector3.zero
	end
	-- ControlModule: X = strafe, -Z = forward
	return flatRight * moveVector.X + flatLook * (-moveVector.Z)
end

local function cleanupMovers()
	if linearVel then
		linearVel:Destroy()
		linearVel = nil
	end
	if align then
		align:Destroy()
		align = nil
	end
	if attachment then
		attachment:Destroy()
		attachment = nil
	end
end

local function setFlyHudVisible(visible: boolean)
	if flyGui then
		flyGui.Enabled = visible
	end
end

local function destroyFlyHud()
	if flyGui then
		flyGui:Destroy()
		flyGui = nil
	end
end

local function wireHoldButton(btn: TextButton, setHeld: (boolean) -> ())
	table.insert(
		inputConns,
		btn.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				setHeld(true)
			end
		end)
	)
	table.insert(
		inputConns,
		btn.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				setHeld(false)
			end
		end)
	)
end

local function ensureFlyHud()
	if flyGui and flyGui.Parent then
		return
	end
	if not isTouchPrimary() then
		return
	end

	local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not playerGui then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminFlyHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 110
	screen.Enabled = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local function makeBtn(name: string, text: string, yScale: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(1, 1)
		btn.Position = UDim2.new(1, -18, yScale, 0)
		btn.Size = UDim2.fromOffset(72, 72)
		btn.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
		btn.BackgroundTransparency = 0.2
		btn.BorderSizePixel = 0
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(230, 255, 240)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 18
		btn.AutoButtonColor = false
		btn.Parent = screen

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 14)
		corner.Parent = btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(72, 255, 140)
		stroke.Thickness = 1.5
		stroke.Transparency = 0.35
		stroke.Parent = btn

		return btn
	end

	-- Stack above typical mobile jump button (bottom-right).
	local up = makeBtn("FlyUp", "UP", 0.62)
	local down = makeBtn("FlyDown", "DOWN", 0.78)
	wireHoldButton(up, function(v)
		holdUpHud = v
	end)
	wireHoldButton(down, function(v)
		holdDownHud = v
	end)

	screen.Parent = playerGui
	flyGui = screen
end

local function clearInputConns()
	for _, conn in inputConns do
		conn:Disconnect()
	end
	table.clear(inputConns)
end

local function stopFly()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	holdUpHud = false
	holdDownHud = false
	holdUpKeys = false
	holdDownKeys = false
	jumpBoostUntil = 0
	setFlyHudVisible(false)
	cleanupMovers()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

local function isAscendHeld(): boolean
	if holdUpHud or holdUpKeys then
		return true
	end
	if os.clock() < jumpBoostUntil then
		return true
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
		return true
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.ButtonA) then
		return true
	end
	return false
end

local function isDescendHeld(): boolean
	if holdDownHud or holdDownKeys then
		return true
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
		return true
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.ButtonB) then
		return true
	end
	return false
end

local function startFly(character: Model)
	stopFly()
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not hum then
		return
	end

	hum.PlatformStand = true
	ensureFlyHud()
	setFlyHudVisible(isTouchPrimary())

	local att = Instance.new("Attachment")
	att.Name = "AdminFlyAttachment"
	att.Parent = hrp
	attachment = att

	local lv = Instance.new("LinearVelocity")
	lv.Name = "AdminFlyVelocity"
	lv.Attachment0 = att
	lv.MaxForce = 1e6
	lv.VectorVelocity = Vector3.zero
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.Parent = hrp
	linearVel = lv

	local ao = Instance.new("AlignOrientation")
	ao.Name = "AdminFlyAlign"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.Responsiveness = 20
	ao.MaxTorque = 1e6
	ao.Parent = hrp
	align = ao

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if player:GetAttribute(FLY_ATTR) ~= true then
			stopFly()
			return
		end
		if not character.Parent or not hrp.Parent or not linearVel then
			stopFly()
			return
		end
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local look = cam.CFrame.LookVector
		local right = cam.CFrame.RightVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local flatRight = Vector3.new(right.X, 0, right.Z)
		if flatLook.Magnitude > 0.05 then
			flatLook = flatLook.Unit
		else
			flatLook = Vector3.new(0, 0, -1)
		end
		if flatRight.Magnitude > 0.05 then
			flatRight = flatRight.Unit
		else
			flatRight = Vector3.new(1, 0, 0)
		end

		local move = getThumbMove(flatLook, flatRight)

		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			move += flatLook
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			move -= flatLook
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			move -= flatRight
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			move += flatRight
		end

		if isAscendHeld() then
			move += Vector3.yAxis
		end
		if isDescendHeld() then
			move -= Vector3.yAxis
		end

		local velocity = Vector3.zero
		if move.Magnitude > 0.05 then
			local dir = move.Unit
			velocity = Vector3.new(dir.X * FLY_SPEED, dir.Y * FLY_VERTICAL, dir.Z * FLY_SPEED)
		end
		linearVel.VectorVelocity = velocity
		if align then
			align.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatLook)
		end
	end)
end

local function syncFly()
	if player:GetAttribute(FLY_ATTR) == true then
		local char = player.Character
		if char then
			startFly(char)
		end
	else
		stopFly()
	end
end

function M.init()
	player:GetAttributeChangedSignal(FLY_ATTR):Connect(syncFly)

	table.insert(
		inputConns,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or player:GetAttribute(FLY_ATTR) ~= true then
				return
			end
			if
				input.KeyCode == Enum.KeyCode.Space
				or input.KeyCode == Enum.KeyCode.ButtonA
				or input.KeyCode == Enum.KeyCode.E
			then
				holdUpKeys = true
			elseif
				input.KeyCode == Enum.KeyCode.LeftControl
				or input.KeyCode == Enum.KeyCode.Q
				or input.KeyCode == Enum.KeyCode.ButtonB
			then
				holdDownKeys = true
			end
		end)
	)
	table.insert(
		inputConns,
		UserInputService.InputEnded:Connect(function(input)
			if
				input.KeyCode == Enum.KeyCode.Space
				or input.KeyCode == Enum.KeyCode.ButtonA
				or input.KeyCode == Enum.KeyCode.E
			then
				holdUpKeys = false
			elseif
				input.KeyCode == Enum.KeyCode.LeftControl
				or input.KeyCode == Enum.KeyCode.Q
				or input.KeyCode == Enum.KeyCode.ButtonB
			then
				holdDownKeys = false
			end
		end)
	)
	table.insert(
		inputConns,
		UserInputService.JumpRequest:Connect(function()
			if player:GetAttribute(FLY_ATTR) ~= true then
				return
			end
			jumpBoostUntil = os.clock() + JUMP_BOOST_SEC
		end)
	)

	local function hookCharacter(char: Model)
		for _, conn in charConns do
			conn:Disconnect()
		end
		table.clear(charConns)
		table.insert(
			charConns,
			char.AncestryChanged:Connect(function(_, parent)
				if not parent then
					stopFly()
				end
			end)
		)
		if player:GetAttribute(FLY_ATTR) == true then
			task.defer(function()
				startFly(char)
			end)
		end
	end

	if player.Character then
		hookCharacter(player.Character)
	end
	player.CharacterAdded:Connect(hookCharacter)

	Players.PlayerRemoving:Connect(function(leaving)
		if leaving == player then
			stopFly()
			clearInputConns()
			destroyFlyHud()
			for _, conn in charConns do
				conn:Disconnect()
			end
			table.clear(charConns)
		end
	end)

	syncFly()
end

return M
