-- [ACTIVE] FireflyController
--[[
	Soft yellow fireflies spread across a few registered bushes outside the safe zone.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))

local FireflyController = {}

local player = Players.LocalPlayer

local ACTIVE_RANGE = 85
local SELECT_PCT = 12
local MAX_ACTIVE = 6
local FLIES_PER_BUSH = 10
local REFRESH_SEC = 1.0
local FOLDER_NAME = "BushFireflies"

local YELLOW = Color3.fromRGB(255, 220, 90)

type Fly = {
	part: BasePart,
	light: PointLight,
	phase: number,
	speed: number,
	orbit: number,
	baseOffset: Vector3,
	wander: Vector3,
	wanderNext: number,
	pos: Vector3,
}

type Swarm = {
	bush: Instance,
	center: Vector3,
	folder: Folder,
	flies: { Fly },
}

local activeSwarms: { [Instance]: Swarm } = {}
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local rootFolder: Folder? = nil
local refreshAccum = 0.0

local function ensureRoot(): Folder
	if rootFolder and rootFolder.Parent then
		return rootFolder
	end
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		rootFolder = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	rootFolder = folder
	return folder
end

local function bushBounds(bush: Instance): (Vector3, Vector3)
	local center = Vector3.zero
	local half = Vector3.new(2.5, 2.2, 2.5)

	if bush:IsA("Model") then
		local ok, cf, size = pcall(function()
			return (bush :: Model):GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			center = cf.Position
			half = Vector3.new(
				math.clamp(size.X * 0.45, 1.4, 7),
				math.clamp(size.Y * 0.4, 1.2, 5),
				math.clamp(size.Z * 0.45, 1.4, 7)
			)
			return center, half
		end
	end

	local focus = BushRootUtil.focusWorldPosition(bush)
	if focus then
		center = focus
	elseif bush:IsA("BasePart") then
		center = (bush :: BasePart).Position + Vector3.new(0, 1.5, 0)
		local s = (bush :: BasePart).Size
		half = Vector3.new(math.max(s.X * 0.4, 1.5), math.max(s.Y * 0.35, 1.2), math.max(s.Z * 0.4, 1.5))
	end
	return center, half
end

local function isEligible(bush: Instance): boolean
	local center = select(1, bushBounds(bush))
	local n = 0
	for i = 1, #bush.Name do
		n += string.byte(bush.Name, i)
	end
	local h = math.abs(math.floor(center.X * 3 + center.Z * 7 + n * 13))
	return (h % 100) < SELECT_PCT
end

local function destroySwarm(bush: Instance)
	local swarm = activeSwarms[bush]
	if not swarm then
		return
	end
	activeSwarms[bush] = nil
	if swarm.folder.Parent then
		swarm.folder:Destroy()
	end
end

local function clearAll()
	local list = {}
	for bush in pairs(activeSwarms) do
		table.insert(list, bush)
	end
	for _, bush in list do
		destroySwarm(bush)
	end
end

local function makeFly(parent: Folder, center: Vector3, half: Vector3, index: number): Fly
	local part = Instance.new("Part")
	part.Name = "Firefly"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Material = Enum.Material.Neon
	part.Color = YELLOW
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.55
	part.CFrame = CFrame.new(center)
	part.Parent = parent

	-- Soft yellow glow (no smoke trails)
	local glow = Instance.new("ParticleEmitter")
	glow.Name = "SoftGlow"
	glow.Texture = "rbxasset://textures/particles/smoke_main.dds"
	glow.Color = ColorSequence.new(YELLOW)
	glow.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.5, 0.7),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	glow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	glow.Rate = 3
	glow.Lifetime = NumberRange.new(0.35, 0.55)
	glow.Speed = NumberRange.new(0, 0.04)
	glow.SpreadAngle = Vector2.new(180, 180)
	glow.LightEmission = 0.7
	glow.LightInfluence = 0
	glow.LockedToPart = true
	glow.Parent = part

	local light = Instance.new("PointLight")
	light.Color = YELLOW
	light.Brightness = 0.55
	light.Range = 5.5
	light.Shadows = false
	light.Parent = part

	local baseOffset = Vector3.new(
		(math.random() * 2 - 1) * half.X,
		(math.random() * 2 - 1) * half.Y * 0.85,
		(math.random() * 2 - 1) * half.Z
	)

	return {
		part = part,
		light = light,
		phase = index * 1.35 + math.random() * 6,
		speed = 0.07 + math.random() * 0.06,
		orbit = 0.3 + math.random() * 0.35,
		baseOffset = baseOffset,
		wander = Vector3.zero,
		wanderNext = 0,
		pos = center + baseOffset,
	}
end

local function createSwarm(bush: Instance)
	local center, half = bushBounds(bush)
	local folder = Instance.new("Folder")
	folder.Name = "Swarm_" .. bush.Name
	folder.Parent = ensureRoot()

	local flies = {}
	for i = 1, FLIES_PER_BUSH do
		table.insert(flies, makeFly(folder, center, half, i))
	end

	activeSwarms[bush] = {
		bush = bush,
		center = center,
		folder = folder,
		flies = flies,
	}
end

local function playerPos(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function refresh()
	local char = player.Character
	if not char or SafezoneUtil.isCharacterInSafezone(char) then
		clearAll()
		return
	end

	local origin = playerPos()
	if not origin then
		return
	end

	local candidates: { { bush: Instance, dist: number } } = {}
	BushHoldInteraction.forEachRegisteredBush(function(bush)
		if not isEligible(bush) then
			return
		end
		local center = select(1, bushBounds(bush))
		local dist = (center - origin).Magnitude
		if dist <= ACTIVE_RANGE then
			table.insert(candidates, { bush = bush, dist = dist })
		elseif activeSwarms[bush] then
			destroySwarm(bush)
		end
	end)

	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local keep: { [Instance]: boolean } = {}
	for i = 1, math.min(MAX_ACTIVE, #candidates) do
		local bush = candidates[i].bush
		keep[bush] = true
		local swarm = activeSwarms[bush]
		if swarm then
			swarm.center = select(1, bushBounds(bush))
		else
			createSwarm(bush)
		end
	end

	for bush in pairs(activeSwarms) do
		if not keep[bush] then
			destroySwarm(bush)
		end
	end
end

local function stepFlies(dt: number)
	local t = os.clock()
	local blend = math.clamp(dt * 0.85, 0.015, 0.045)
	for _, swarm in pairs(activeSwarms) do
		if not swarm.bush.Parent then
			destroySwarm(swarm.bush)
			continue
		end
		for _, fly in swarm.flies do
			if t >= fly.wanderNext then
				fly.wanderNext = t + 3.5 + math.random() * 4
				fly.wander = Vector3.new(
					(math.random() * 2 - 1) * 0.45,
					(math.random() * 2 - 1) * 0.3,
					(math.random() * 2 - 1) * 0.45
				)
			end
			local ang = t * fly.speed + fly.phase
			local drift = Vector3.new(
				math.cos(ang) * fly.orbit,
				math.sin(t * 0.4 + fly.phase) * 0.22,
				math.sin(ang * 0.9) * fly.orbit
			)
			local target = swarm.center + fly.baseOffset + drift + fly.wander
			fly.pos = fly.pos:Lerp(target, blend)
			fly.part.CFrame = CFrame.new(fly.pos)
			fly.light.Brightness = 0.4 + 0.2 * (0.5 + 0.5 * math.sin(t * 0.9 + fly.phase))
		end
	end
end

function FireflyController.init()
	if wired then
		return
	end
	wired = true

	ensureRoot()
	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(12)
		task.wait(2)
		refresh()
	end)

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		refreshAccum += dt
		if refreshAccum >= REFRESH_SEC then
			refreshAccum = 0
			refresh()
		end
		if next(activeSwarms) ~= nil then
			stepFlies(dt)
		end
	end)
end

return FireflyController
