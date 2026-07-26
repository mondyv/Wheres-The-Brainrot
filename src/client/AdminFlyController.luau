-- [ACTIVE] AdminFlyController
-- Client fly mode toggled by AdminFlyEnabled attribute (admin `fly` command).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local M = {}

local FLY_ATTR = "AdminFlyEnabled"
local FLY_SPEED = 90
local FLY_VERTICAL = 70

local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}
local align: AlignOrientation? = nil
local attachment: Attachment? = nil
local linearVel: LinearVelocity? = nil

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

local function stopFly()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	cleanupMovers()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

local function startFly(character: Model)
	stopFly()
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not hum then
		return
	end

	hum.PlatformStand = true

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

		local move = Vector3.zero
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
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
			move += Vector3.yAxis
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
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
			for _, conn in charConns do
				conn:Disconnect()
			end
			table.clear(charConns)
		end
	end)

	syncFly()
end

return M
