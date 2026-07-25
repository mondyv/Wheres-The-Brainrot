-- [ACTIVE] FireflyController
--[[
	Small yellow glowing fireflies that float around a random subset of registered
	bushes while the player is outside the safe zone.
	Uses BushHoldInteraction's bush registry (same bushes that are searchable).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)

local FireflyController = {}

local player = Players.LocalPlayer

local ACTIVE_RANGE = 90
local SELECT_PCT = 35
local MAX_ACTIVE = 12
local FLIES_PER_BUSH = 4
local REFRESH_SEC = 0.6
local FOLDER_NAME = "BushFireflies"

local YELLOW = Color3.fromRGB(255, 220, 70)

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

local function bushCenter(bush: Instance): Vector3?
	if bush:IsA("Model") then
		local ok, pivot = pcall(function()
			return (bush :: Model):GetPivot()
		end)
		if ok and pivot then
			return pivot.Position + Vector3.new(0, 2.2, 0)
		end
	elseif bush:IsA("BasePart") then
		return (bush :: BasePart).Position + Vector3.new(0, 2.2, 0)
	end
	return nil
end

local function isEligible(bush: Instance): boolean
	local center = bushCenter(bush)
	if not center then
		return false
	end
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

local function makeFly(parent: Folder, center: Vector3, index: number): Fly
	local part = Instance.new("Part")
	part.Name = "Firefly"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.35, 0.35, 0.35)
	part.Material = Enum.Material.Neon
	part.Color = YELLOW
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0
	part.CFrame = CFrame.new(center)
	part.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = YELLOW
	light.Brightness = 3
	light.Range = 12
	light.Shadows = false
	light.Parent = part

	return {
		part = part,
		light = light,
		phase = index * 2.1 + math.random() * 4,
		speed = 0.7 + math.random() * 0.7,
		radius = 1.6 + math.random() * 2.2,
		height = 0.4 + math.random() * 1.8,
	}
end

local function createSwarm(bush: Instance, center: Vector3)
	local folder = Instance.new("Folder")
	folder.Name = "Swarm_" .. bush.Name
	folder.Parent = ensureRoot()

	local flies = {}
	for i = 1, FLIES_PER_BUSH do
		table.insert(flies, makeFly(folder, center, i))
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

	local candidates: { { bush: Instance, dist: number, center: Vector3 } } = {}
	BushHoldInteraction.forEachRegisteredBush(function(bush)
		if not isEligible(bush) then
			return
		end
		local center = bushCenter(bush)
		if not center then
			return
		end
		local dist = (center - origin).Magnitude
		if dist <= ACTIVE_RANGE then
			table.insert(candidates, { bush = bush, dist = dist, center = center })
		elseif activeSwarms[bush] then
			destroySwarm(bush)
		end
	end)

	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local keep: { [Instance]: boolean } = {}
	for i = 1, math.min(MAX_ACTIVE, #candidates) do
		local entry = candidates[i]
		keep[entry.bush] = true
		local swarm = activeSwarms[entry.bush]
		if swarm then
			swarm.center = entry.center
		else
			createSwarm(entry.bush, entry.center)
		end
	end

	for bush in pairs(activeSwarms) do
		if not keep[bush] then
			destroySwarm(bush)
		end
	end
end

local function stepFlies()
	local t = os.clock()
	for _, swarm in pairs(activeSwarms) do
		if not swarm.bush.Parent then
			destroySwarm(swarm.bush)
			continue
		end
		for _, fly in swarm.flies do
			local ang = t * fly.speed + fly.phase
			local bob = math.sin(t * 2.2 + fly.phase) * 0.45
			fly.part.CFrame = CFrame.new(
				swarm.center
					+ Vector3.new(
						math.cos(ang) * fly.radius,
						fly.height + bob,
						math.sin(ang * 0.9) * fly.radius
					)
			)
			fly.light.Brightness = 2.2 + 1.4 * (0.5 + 0.5 * math.sin(t * 4 + fly.phase))
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
		-- Wait for bush registry to populate
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
			stepFlies()
		end
	end)
end

return FireflyController
