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
	slideProgress: number,
	maxSlide: number,
	heartbeatConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
	originalWalkSpeed: number,
	originalJumpHeight: number,
	originalAutoRotate: boolean,
	disabledStates: { Enum.HumanoidStateType },
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

local function computeOutward(webPart: BasePart, hitPosition: Vector3, hrp: BasePart): Vector3
	local toPlayer = hrp.Position - hitPosition
	local flattened = toPlayer - webPart.CFrame.UpVector * toPlayer:Dot(webPart.CFrame.UpVector)
	if flattened.Magnitude > 0.35 then
		return flattened.Unit
	end
	local fromCenter = hrp.Position - webPart.Position
	flattened = fromCenter - webPart.CFrame.UpVector * fromCenter:Dot(webPart.CFrame.UpVector)
	if flattened.Magnitude > 0.35 then
		return flattened.Unit
	end
	return webPart.CFrame.LookVector.Unit
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

local function updateTrapPose(player: Player, state: TrapState, hrp: BasePart)
	local worldPos = state.anchorWorld + state.slideDir * state.slideProgress
	local lookTarget = worldPos + state.outwardDir
	local targetCf = CFrame.lookAt(worldPos, lookTarget)
	hrp.CFrame = targetCf
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

local function beginTrap(player: Player, webPart: BasePart, hitPosition: Vector3)
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

	local outward = computeOutward(webPart, hitPosition, hrp)
	local slideDir = computeSlideDir(webPart, outward)
	local anchorWorld = hitPosition - outward * WebTrapConfig.STICK_OFFSET

	local state: TrapState = {
		webPart = webPart,
		anchorWorld = anchorWorld,
		outwardDir = outward,
		slideDir = slideDir,
		slideProgress = 0,
		maxSlide = WebTrapConfig.MAX_SLIDE_DISTANCE,
		heartbeatConn = nil,
		diedConn = nil,
		originalWalkSpeed = humanoid.WalkSpeed,
		originalJumpHeight = humanoid.JumpHeight,
		originalAutoRotate = humanoid.AutoRotate,
		disabledStates = DISABLED_STATES,
	}

	trappedByPlayer[player] = state
	player:SetAttribute(WebTrapConfig.TRAPPED_ATTR, true)
	setHumanoidTrapped(humanoid, true, state)
	updateTrapPose(player, state, hrp)

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
		updateTrapPose(player, state, root)

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

	beginTrap(player, webPart, other.Position)
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
