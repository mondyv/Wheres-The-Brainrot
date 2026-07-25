-- [ACTIVE] FireflyController
--[[
	Soft glowing fireflies around a stable random subset of bushes (~15%),
	only while the local player is outside the safe zone.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local FireflyController = {}

local player = Players.LocalPlayer

local ACTIVE_RANGE = 95
local SELECT_PCT = 15 -- ~15% of bushes
local MAX_ACTIVE_BUSHES = 10
local FLIES_PER_BUSH = 4
local REFRESH_SEC = 0.9
local SCAN_YIELD_EVERY = 350
local FOLDER_NAME = "SafeZoneFireflies"

local GLOW = Color3.fromRGB(180, 255, 120)

type Fly = {
	part: BasePart,
	light: PointLight,
	phase: number,
	speed: number,
	radius: number,
	height: number,
}

type Swarm = {
	bush: Instance,
	center: Vector3,
	folder: Folder,
	flies: { Fly },
}

local trackedBushes: { [Instance]: boolean } = {}
local eligibleBushes: { [Instance]: boolean } = {}
local activeSwarms: { [Instance]: Swarm } = {}
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local rootFolder: Folder? = nil
local refreshAccum = 0.0

local function stableHash(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

local function bushKey(bush: Instance): string
	return bush:GetFullName()
end

local function isEligibleBush(bush: Instance): boolean
	return (stableHash(bushKey(bush)) % 100) < SELECT_PCT
end

local function ensureRootFolder(): Folder
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

local function getBushCenter(bush: Instance): Vector3?
	local focus = BushRootUtil.focusWorldPosition(bush)
	if focus then
		return focus
	end
	if bush:IsA("Model") then
		local ok, pivot = pcall(function()
			return (bush :: Model):GetPivot()
		end)
		if ok and pivot then
			return pivot.Position
		end
	elseif bush:IsA("BasePart") then
		return (bush :: BasePart).Position
	end
	return nil
end

local function destroySwarm(bush: Instance)
	local swarm = activeSwarms[bush]
	if not swarm then
		return
	end
	activeSwarms[bush] = nil
	if swarm.folder and swarm.folder.Parent then
		swarm.folder:Destroy()
	end
end

local function createFly(parent: Folder, center: Vector3, index: number): Fly
	local part = Instance.new("Part")
	part.Name = "Firefly" .. index
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.18, 0.18, 0.18)
	part.Material = Enum.Material.Neon
	part.Color = GLOW
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0.15
	part.CFrame = CFrame.new(center)
	part.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = GLOW
	light.Brightness = 1.1
	light.Range = 7
	light.Shadows = false
	light.Parent = part

	local spark = Instance.new("ParticleEmitter")
	spark.Name = "Glow"
	spark.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	spark.Color = ColorSequence.new(GLOW)
	spark.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	spark.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	spark.LifetimeRate = 2
	spark.Lifetime = NumberRange.new(0.6, 1.1)
	spark.Speed = NumberRange.new(0.05, 0.2)
	spark.SpreadAngle = Vector2.new(180, 180)
	spark.LightEmission = 0.9
	spark.LightInfluence = 0
	spark.Parent = part

	return {
		part = part,
		light = light,
		phase = index * 1.7 + math.random() * 6,
		speed = 0.55 + math.random() * 0.55,
		radius = 1.2 + math.random() * 2.2,
		height = 0.6 + math.random() * 1.8,
	}
end

local function createSwarm(bush: Instance, center: Vector3): Swarm
	local folder = Instance.new("Folder")
	folder.Name = "Swarm"
	folder.Parent = ensureRootFolder()

	local flies: { Fly } = {}
	for i = 1, FLIES_PER_BUSH do
		table.insert(flies, createFly(folder, center, i))
	end

	local swarm: Swarm = {
		bush = bush,
		center = center,
		folder = folder,
		flies = flies,
	}
	activeSwarms[bush] = swarm
	return swarm
end

local function trackBush(bush: Instance)
	if trackedBushes[bush] then
		return
	end
	trackedBushes[bush] = true
	if isEligibleBush(bush) then
		eligibleBushes[bush] = true
	end
	bush.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			trackedBushes[bush] = nil
			eligibleBushes[bush] = nil
			destroySwarm(bush)
		end
	end)
end

local function scanMap(map: Instance)
	local stack = { map }
	local count = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst:IsA("Folder") and BushRootUtil.isBushFolderName(inst.Name) then
			for _, child in inst:GetChildren() do
				if BushRootUtil.isDirectBushRoot(child) then
					trackBush(child)
				end
			end
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		count += 1
		if count % SCAN_YIELD_EVERY == 0 then
			task.wait(0.03)
		end
	end
end

local function playerPos(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return (hrp :: BasePart).Position
	end
	return nil
end

local function refreshActiveSwarms()
	local outside = player.Character and not SafezoneUtil.isCharacterInSafezone(player.Character)
	if not outside then
		for bush in activeSwarms do
			destroySwarm(bush)
		end
		return
	end

	local origin = playerPos()
	if not origin then
		return
	end

	local candidates: { { bush: Instance, dist: number, center: Vector3 } } = {}
	for bush in eligibleBushes do
		if not bush.Parent then
			eligibleBushes[bush] = nil
			continue
		end
		local center = getBushCenter(bush)
		if not center then
			continue
		end
		local dist = (center - origin).Magnitude
		if dist <= ACTIVE_RANGE then
			table.insert(candidates, { bush = bush, dist = dist, center = center })
		elseif activeSwarms[bush] then
			destroySwarm(bush)
		end
	end

	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local keep: { [Instance]: boolean } = {}
	for i = 1, math.min(MAX_ACTIVE_BUSHES, #candidates) do
		local entry = candidates[i]
		keep[entry.bush] = true
		local swarm = activeSwarms[entry.bush]
		if swarm then
			swarm.center = entry.center
		else
			createSwarm(entry.bush, entry.center)
		end
	end

	for bush in activeSwarms do
		if not keep[bush] then
			destroySwarm(bush)
		end
	end
end

local function stepFlies(dt: number)
	local t = os.clock()
	for _, swarm in activeSwarms do
		if not swarm.bush.Parent then
			destroySwarm(swarm.bush)
			continue
		end
		local center = swarm.center
		for _, fly in swarm.flies do
			local ang = t * fly.speed + fly.phase
			local bob = math.sin(t * (fly.speed * 1.4) + fly.phase) * 0.55
			local pos = center
				+ Vector3.new(math.cos(ang) * fly.radius, fly.height + bob, math.sin(ang * 0.85) * fly.radius)
			fly.part.CFrame = CFrame.new(pos)
			-- Soft pulse
			local pulse = 0.75 + 0.45 * (0.5 + 0.5 * math.sin(t * 3.2 + fly.phase))
			fly.light.Brightness = pulse
			fly.part.Transparency = 0.1 + 0.25 * (1 - (pulse - 0.75) / 0.9)
		end
	end
end

function FireflyController.init()
	if wired then
		return
	end
	wired = true

	ensureRootFolder()

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		local map = Workspace:WaitForChild("Map", 120)
		if not map then
			return
		end
		scanMap(map)
		map.DescendantAdded:Connect(function(desc)
			if BushRootUtil.isDirectBushRoot(desc) then
				trackBush(desc)
			elseif desc:IsA("Folder") and BushRootUtil.isBushFolderName(desc.Name) then
				for _, child in desc:GetChildren() do
					if BushRootUtil.isDirectBushRoot(child) then
						trackBush(child)
					end
				end
			end
		end)
		refreshActiveSwarms()
	end)

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		refreshAccum += dt
		if refreshAccum >= REFRESH_SEC then
			refreshAccum = 0
			refreshActiveSwarms()
		end
		if next(activeSwarms) ~= nil then
			stepFlies(dt)
		end
	end)
end

return FireflyController
