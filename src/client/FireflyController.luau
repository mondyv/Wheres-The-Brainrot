-- [ACTIVE] FireflyController
--[[
	Soft orange fireflies that orbit *around* bushes outside the safe zone.
	Body + PointLight only (no particle VFX). Sticky range so swarms don't pop.
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

-- Enter closer than ACTIVATE, leave farther than DEACTIVATE (hysteresis).
local ACTIVATE_RANGE = 52
local DEACTIVATE_RANGE = 78
local SELECT_PCT = 16
local MAX_ACTIVE = 6
local FLIES_PER_BUSH = 5
local REFRESH_SEC = 1.25
local FOLDER_NAME = "BushFireflies"

-- Warm orange (not pale yellow — pale + bright light reads white).
local GLOW = Color3.fromRGB(255, 150, 55)
local BODY = Color3.fromRGB(255, 130, 40)
local LIGHT_RANGE = 9
local LIGHT_BRIGHTNESS = 1.15
local FLY_SIZE = 0.22
-- Orbit outside the bush mesh, not inside the foliage volume.
local ORBIT_PAD = 1.85
local ORBIT_JITTER = 0.9
-- Slow lazy drift (rad/sec) + soft long glow breathe.
local SPEED_MIN = 0.1
local SPEED_MAX = 0.18
local BOB_SPEED = 0.45
local FOLLOW_BLEND = 1.05
local GLOW_PULSE_SPEED = 0.55
local GLOW_PULSE_MIN = 0.72
local GLOW_PULSE_MAX = 1

type Fly = {
	part: BasePart,
	light: PointLight,
	phase: number,
	speed: number,
	radius: number,
	heightBias: number,
	wander: Vector3,
	wanderNext: number,
	pos: Vector3,
}

type Swarm = {
	bush: Instance,
	center: Vector3,
	half: Vector3,
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
				math.clamp(size.X * 0.5, 1.6, 8),
				math.clamp(size.Y * 0.45, 1.4, 6),
				math.clamp(size.Z * 0.5, 1.6, 8)
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
		half = Vector3.new(math.max(s.X * 0.45, 1.6), math.max(s.Y * 0.4, 1.4), math.max(s.Z * 0.45, 1.6))
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

local function horizontalRadius(half: Vector3): number
	return math.max(half.X, half.Z) + ORBIT_PAD
end

local function makeFly(parent: Folder, center: Vector3, half: Vector3, index: number): Fly
	local part = Instance.new("Part")
	part.Name = "Firefly"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(FLY_SIZE, FLY_SIZE, FLY_SIZE)
	part.Material = Enum.Material.Neon
	part.Color = BODY
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.15
	part.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = GLOW
	light.Brightness = LIGHT_BRIGHTNESS
	light.Range = LIGHT_RANGE
	light.Shadows = false
	light.Parent = part

	local baseRadius = horizontalRadius(half) + math.random() * ORBIT_JITTER
	local startAng = (index / FLIES_PER_BUSH) * math.pi * 2 + math.random() * 0.6
	local heightBias = (math.random() * 2 - 0.35) * half.Y * 0.55
	local startPos = center
		+ Vector3.new(math.cos(startAng) * baseRadius, heightBias, math.sin(startAng) * baseRadius)
	part.CFrame = CFrame.new(startPos)

	return {
		part = part,
		light = light,
		phase = startAng,
		speed = SPEED_MIN + math.random() * (SPEED_MAX - SPEED_MIN),
		radius = baseRadius,
		heightBias = heightBias,
		wander = Vector3.zero,
		wanderNext = 0,
		pos = startPos,
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
		half = half,
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

	-- Sticky: keep existing swarms until they leave DEACTIVATE_RANGE.
	for bush, swarm in pairs(activeSwarms) do
		if not bush.Parent then
			destroySwarm(bush)
			continue
		end
		local center = select(1, bushBounds(bush))
		swarm.center = center
		if (center - origin).Magnitude > DEACTIVATE_RANGE then
			destroySwarm(bush)
		end
	end

	local candidates: { { bush: Instance, dist: number } } = {}
	BushHoldInteraction.forEachRegisteredBush(function(bush)
		if not isEligible(bush) then
			return
		end
		if activeSwarms[bush] then
			return
		end
		local center = select(1, bushBounds(bush))
		local dist = (center - origin).Magnitude
		if dist <= ACTIVATE_RANGE then
			table.insert(candidates, { bush = bush, dist = dist })
		end
	end)

	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local activeCount = 0
	for _ in pairs(activeSwarms) do
		activeCount += 1
	end

	for i = 1, #candidates do
		if activeCount >= MAX_ACTIVE then
			break
		end
		createSwarm(candidates[i].bush)
		activeCount += 1
	end
end

local function stepFlies(dt: number)
	local t = os.clock()
	local blend = math.clamp(dt * FOLLOW_BLEND, 0.02, 0.07)
	for _, swarm in pairs(activeSwarms) do
		if not swarm.bush.Parent then
			destroySwarm(swarm.bush)
			continue
		end
		local center = swarm.center
		local half = swarm.half
		local minRadius = horizontalRadius(half)
		for _, fly in swarm.flies do
			if t >= fly.wanderNext then
				fly.wanderNext = t + 2.2 + math.random() * 2.8
				fly.wander = Vector3.new(
					(math.random() * 2 - 1) * 0.35,
					(math.random() * 2 - 1) * 0.28,
					(math.random() * 2 - 1) * 0.35
				)
				fly.radius = minRadius + math.random() * ORBIT_JITTER
			end
			local ang = t * fly.speed + fly.phase
			local bob = math.sin(t * BOB_SPEED + fly.phase) * 0.32 + math.cos(t * (BOB_SPEED * 0.55) + fly.phase) * 0.14
			local target = center
				+ Vector3.new(
					math.cos(ang) * fly.radius,
					fly.heightBias + bob,
					math.sin(ang) * fly.radius
				)
				+ fly.wander
			-- Keep them outside the bush horizontal footprint.
			local flat = Vector3.new(target.X - center.X, 0, target.Z - center.Z)
			if flat.Magnitude < minRadius then
				flat = if flat.Magnitude > 0.05 then flat.Unit * minRadius else Vector3.new(minRadius, 0, 0)
				target = Vector3.new(center.X + flat.X, target.Y, center.Z + flat.Z)
			end
			fly.pos = fly.pos:Lerp(target, blend)
			fly.part.CFrame = CFrame.new(fly.pos)

			-- Soft long glow breathe — always lit, never a split-second flash.
			local wave = 0.5 + 0.5 * math.sin(t * GLOW_PULSE_SPEED + fly.phase)
			local pulse = GLOW_PULSE_MIN + (GLOW_PULSE_MAX - GLOW_PULSE_MIN) * wave
			fly.light.Brightness = LIGHT_BRIGHTNESS * pulse
			fly.light.Range = LIGHT_RANGE * (0.92 + 0.08 * wave)
			fly.light.Color = GLOW
			fly.part.Color = BODY
			fly.part.Transparency = 0.05 + 0.08 * (1 - wave)
		end
	end
end

function FireflyController.init()
	if wired then
		return
	end
	wired = true

	ensureRoot()
	task.defer(function()
		local root = Workspace:FindFirstChild(FOLDER_NAME)
		if not root then
			return
		end
		for _, d in root:GetDescendants() do
			if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
				d:Destroy()
			end
		end
	end)

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
