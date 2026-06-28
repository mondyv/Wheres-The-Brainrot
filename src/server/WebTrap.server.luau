-- [ACTIVE] WebTrap.server
--[[
	Spider webs under Workspace.Map.Webs trap players on touch:
	stuck in place, slow slide down the web, bleed out until death.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WebTrapConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WebTrapConfig"))

type TrapState = {
	webPart: BasePart,
	anchorWorld: Vector3,
	outwardDir: Vector3,
	slideDir: Vector3,
	trapRotation: CFrame,
	slideProgress: number,
	maxSlide: number,
	heartbeatConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
	alignPos: AlignPosition?,
	alignOri: AlignOrientation?,
	rootAttachment: Attachment?,
	originalWalkSpeed: number,
	originalJumpHeight: number,
	originalAutoRotate: boolean,
}

local trappedByPlayer: { [Player]: TrapState } = {}
local touchDebounceUntil: { [Player]: number } = {}
local wiredParts: { [BasePart]: boolean } = {}

local DISABLED_STATES = {
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Freefall,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Flying,
}

local function findWebsFolder(): Instance?
	local node: Instance = Workspace
	for _, name in WebTrapConfig.WEBS_FOLDER_PATH do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function computeSlideDir(webPart: BasePart, outward: Vector3): Vector3
	local gravity = Vector3.new(0, -1, 0)
	local slide = gravity - outward * gravity:Dot(outward)
	if slide.Magnitude < 0.08 then
		slide = -webPart.CFrame.UpVector
	end
	if slide.Magnitude < 0.08 then
		slide = Vector3.new(0, -1, 0)
	end
	return slide.Unit
end

local function computeOutward(webPart: BasePart, hrp: BasePart): Vector3
	local toPlayer = hrp.Position - webPart.Position
	local flattened = toPlayer - webPart.CFrame.UpVector * toPlayer:Dot(webPart.CFrame.UpVector)
	if flattened.Magnitude > 0.35 then
		return flattened.Unit
	end
	flattened = hrp.CFrame.LookVector - webPart.CFrame.UpVector * hrp.CFrame.LookVector:Dot(webPart.CFrame.UpVector)
	if flattened.Magnitude > 0.35 then
		return flattened.Unit
	end
	return webPart.CFrame.LookVector.Unit
end

local function buildTrapRotation(outward: Vector3): CFrame
	local look = outward
	local up = Vector3.yAxis
	if math.abs(look:Dot(up)) > 0.92 then
		up = Vector3.new(0, 0, -1)
	end
	local right = up:Cross(look)
	if right.Magnitude < 0.05 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local stableUp = look:Cross(right).Unit
	return CFrame.fromMatrix(Vector3.zero, right, stableUp)
end

local function setHumanoidTrapped(humanoid: Humanoid, trapped: boolean, state: TrapState?)
	if trapped then
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		for _, st in DISABLED_STATES do
			pcall(function()
				humanoid:SetStateEnabled(st, false)
			end)
		end
		return
	end

	if state then
		humanoid.WalkSpeed = state.originalWalkSpeed
		humanoid.JumpHeight = state.originalJumpHeight
		humanoid.AutoRotate = state.originalAutoRotate
	end
	humanoid.PlatformStand = false
	for _, st in DISABLED_STATES do
		pcall(function()
			humanoid:SetStateEnabled(st, true)
		end)
	end
end

local function destroyConstraints(state: TrapState)
	if state.alignPos then
		state.alignPos:Destroy()
		state.alignPos = nil
	end
	if state.alignOri then
		state.alignOri:Destroy()
		state.alignOri = nil
	end
	if state.rootAttachment then
		state.rootAttachment:Destroy()
		state.rootAttachment = nil
	end
end

local function createConstraints(hrp: BasePart, state: TrapState)
	destroyConstraints(state)

	local att = Instance.new("Attachment")
	att.Name = "WebTrapAttachment"
	att.Parent = hrp
	state.rootAttachment = att

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "WebTrapAlignPosition"
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.RigidityEnabled = true
	alignPos.Responsiveness = 200
	alignPos.MaxForce = 500_000
	alignPos.MaxVelocity = WebTrapConfig.SLIDE_SPEED + 2
	alignPos.Position = state.anchorWorld
	alignPos.Parent = hrp
	state.alignPos = alignPos

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "WebTrapAlignOrientation"
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att
	alignOri.RigidityEnabled = true
	alignOri.Responsiveness = 200
	alignOri.MaxTorque = 500_000
	alignOri.CFrame = state.trapRotation + state.anchorWorld
	alignOri.Parent = hrp
	state.alignOri = alignOri
end

local function releaseTrap(player: Player)
	local state = trappedByPlayer[player]
	if not state then
		if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true then
			player:SetAttribute(WebTrapConfig.TRAPPED_ATTR, false)
		end
		return
	end

	trappedByPlayer[player] = nil

	if state.heartbeatConn then
		state.heartbeatConn:Disconnect()
		state.heartbeatConn = nil
	end
	if state.diedConn then
		state.diedConn:Disconnect()
		state.diedConn = nil
	end

	destroyConstraints(state)

	player:SetAttribute(WebTrapConfig.TRAPPED_ATTR, false)

	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		setHumanoidTrapped(humanoid, false, state)
	end
end

local function zeroCharacterMotion(character: Model, root: BasePart)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function updateTrapTarget(state: TrapState)
	local worldPos = state.anchorWorld + state.slideDir * state.slideProgress
	if state.alignPos then
		state.alignPos.Position = worldPos
	end
end

local function beginTrap(player: Player, webPart: BasePart)
	if trappedByPlayer[player] then
		return
	end

	local now = os.clock()
	if touchDebounceUntil[player] and now < touchDebounceUntil[player] then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp or humanoid.Health <= 0 then
		return
	end

	local outward = computeOutward(webPart, hrp)
	local slideDir = computeSlideDir(webPart, outward)
	local anchorWorld = hrp.Position - outward * WebTrapConfig.STICK_OFFSET
	local trapRotation = buildTrapRotation(outward)

	local state: TrapState = {
		webPart = webPart,
		anchorWorld = anchorWorld,
		outwardDir = outward,
		slideDir = slideDir,
		trapRotation = trapRotation,
		slideProgress = 0,
		maxSlide = WebTrapConfig.MAX_SLIDE_DISTANCE,
		heartbeatConn = nil,
		diedConn = nil,
		alignPos = nil,
		alignOri = nil,
		rootAttachment = nil,
		originalWalkSpeed = humanoid.WalkSpeed,
		originalJumpHeight = humanoid.JumpHeight,
		originalAutoRotate = humanoid.AutoRotate,
	}

	trappedByPlayer[player] = state
	player:SetAttribute(WebTrapConfig.TRAPPED_ATTR, true)
	setHumanoidTrapped(humanoid, true, state)
	createConstraints(hrp, state)
	updateTrapTarget(state)
	zeroCharacterMotion(character, hrp)

	local bleedPerSecond = humanoid.MaxHealth / math.max(WebTrapConfig.BLEED_DURATION, 0.5)

	state.diedConn = humanoid.Died:Connect(function()
		releaseTrap(player)
	end)

	state.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		if not player.Parent then
			releaseTrap(player)
			return
		end

		local char = player.Character
		if not char then
			releaseTrap(player)
			return
		end

		local hum = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hum or not root or hum.Health <= 0 then
			releaseTrap(player)
			return
		end

		if not state.webPart or not state.webPart.Parent then
			releaseTrap(player)
			return
		end

		state.slideProgress = math.min(state.slideProgress + WebTrapConfig.SLIDE_SPEED * dt, state.maxSlide)

		setHumanoidTrapped(hum, true, state)
		hum.Jump = false
		updateTrapTarget(state)
		zeroCharacterMotion(char, root)

		local damage = bleedPerSecond * dt
		if damage > 0 then
			hum:TakeDamage(damage)
		end
	end)
end

local function onWebTouched(webPart: BasePart, other: BasePart)
	if not other or not other:IsA("BasePart") then
		return
	end

	local character = other:FindFirstAncestorWhichIsA("Model")
	if not character then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	beginTrap(player, webPart)
end

local function wireWebPart(part: BasePart)
	if wiredParts[part] then
		return
	end
	if not part:IsA("BasePart") then
		return
	end

	wiredParts[part] = true
	part.CanTouch = true
	part.Touched:Connect(function(hit)
		onWebTouched(part, hit)
	end)
end

local function wireWebsRoot(root: Instance)
	if root:IsA("BasePart") then
		wireWebPart(root)
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			wireWebPart(desc)
		end
	end
	root.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			task.defer(wireWebPart, desc)
		end
	end)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		releaseTrap(player)
		touchDebounceUntil[player] = os.clock() + 0.35
	end)
end

for _, player in Players:GetPlayers() do
	hookPlayer(player)
end
Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(function(player)
	releaseTrap(player)
	touchDebounceUntil[player] = nil
end)

task.spawn(function()
	local folder = findWebsFolder()
	if not folder then
		local map = Workspace:WaitForChild("Map", 120)
		local webs = map and map:WaitForChild("Webs", 120)
		folder = webs
	end
	if not folder then
		warn("[WebTrap] Workspace.Map.Webs not found — web traps disabled")
		return
	end
	wireWebsRoot(folder)
end)
