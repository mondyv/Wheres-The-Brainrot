-- [ACTIVE] FireflyController
--[[
	Soft yellow fireflies on a few bushes outside the safe zone.
	Neon spheres + PointLight only (no smoke particle textures).
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

local ACTIVE_RANGE = 55
local SELECT_PCT = 10
local MAX_ACTIVE = 2
local FLIES_PER_BUSH = 3
local REFRESH_SEC = 2
local FOLDER_NAME = "BushFireflies"

-- Brighter / lighter yellow
local YELLOW = Color3.fromRGB(255, 245, 170)
local YELLOW_CORE = Color3.fromRGB(255, 252, 220)

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
	part.Size = Vector3.new(0.28, 0.28, 0.28)
	part.Material = Enum.Material.Neon
	part.Color = YELLOW_CORE
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.15
	part.CFrame = CFrame.new(center)
	part.Parent = parent

	-- No ParticleEmitter — smoke_main texture looked like smoke clouds.

	local light = Instance.new("PointLight")
	light.Color = YELLOW
	light.Brightness = 1.35
	light.Range = 7
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
		speed = 0.55 + math.random() * 0.55,
		orbit = 0.85 + math.random() * 0.95,
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
	-- Snappier follow so motion reads more lively.
	local blend = math.clamp(dt * 2.4, 0.04, 0.14)
	for _, swarm in pairs(activeSwarms) do
		if not swarm.bush.Parent then
			destroySwarm(swarm.bush)
			continue
		end
		for _, fly in swarm.flies do
			if t >= fly.wanderNext then
				fly.wanderNext = t + 0.85 + math.random() * 1.4
				fly.wander = Vector3.new(
					(math.random() * 2 - 1) * 1.35,
					(math.random() * 2 - 1) * 0.95,
					(math.random() * 2 - 1) * 1.35
				)
			end
			local ang = t * fly.speed + fly.phase
			local drift = Vector3.new(
				math.cos(ang) * fly.orbit + math.sin(ang * 1.7) * 0.35,
				math.sin(t * 1.15 + fly.phase) * 0.55 + math.cos(t * 0.7 + fly.phase) * 0.25,
				math.sin(ang * 0.95) * fly.orbit + math.cos(ang * 1.3) * 0.3
			)
			local target = swarm.center + fly.baseOffset + drift + fly.wander
			fly.pos = fly.pos:Lerp(target, blend)
			fly.part.CFrame = CFrame.new(fly.pos)
			local pulse = 0.5 + 0.5 * math.sin(t * 2.2 + fly.phase)
			fly.light.Brightness = 1.05 + 0.55 * pulse
			fly.part.Transparency = 0.08 + 0.12 * (1 - pulse)
		end
	end
end

function FireflyController.init()
	if wired then
		return
	end
	wired = true

	ensureRoot()
	-- Wipe any leftover smoke emitters from older builds.
	task.defer(function()
		local root = Workspace:FindFirstChild(FOLDER_NAME)
		if not root then
			return
		end
		for _, d in root:GetDescendants() do
			if d:IsA("ParticleEmitter") then
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
