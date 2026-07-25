-- [ACTIVE] FootstepController
--[[
	Plays walking SFX from SoundService.SoundEffects.Footsteps:
	• GrassWalking — when standing on grass-like ground
	• RegularWalking — otherwise
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)

local FootstepController = {}

local player = Players.LocalPlayer

local STEP_INTERVAL_BASE = 0.34
local MIN_MOVE_SPEED = 1.2
local RAY_DIST = 5
local PITCH_MIN = 0.94
local PITCH_MAX = 1.06

local GRASS_MATERIALS: { [Enum.Material]: boolean } = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Mud] = true,
}

local regularSounds: { Sound } = {}
local grassSounds: { Sound } = {}
local wired = false
local stepAccum = 0.0
local lastIndexRegular = 0
local lastIndexGrass = 0
local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}
local rayParams = RaycastParams.new()

local function collectSounds(folder: Instance?): { Sound }
	local list: { Sound } = {}
	if not folder then
		return list
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Sound") then
			table.insert(list, child)
		end
	end
	return list
end

local function loadTemplates()
	local effects = SoundService:FindFirstChild("SoundEffects")
	local footsteps = effects and effects:FindFirstChild("Footsteps")
	if not footsteps then
		return
	end
	regularSounds = collectSounds(footsteps:FindFirstChild("RegularWalking"))
	grassSounds = collectSounds(footsteps:FindFirstChild("GrassWalking"))
end

local function pickNext(list: { Sound }, lastIndex: number): (Sound?, number)
	if #list == 0 then
		return nil, lastIndex
	end
	if #list == 1 then
		return list[1], 1
	end
	local idx = lastIndex
	for _ = 1, 5 do
		idx = math.random(1, #list)
		if idx ~= lastIndex then
			break
		end
	end
	return list[idx], idx
end

local function playOne(template: Sound)
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local clone = template:Clone()
	clone.Name = "FootstepPlay"
	clone.Looped = false
	clone.PlaybackSpeed = PITCH_MIN + math.random() * (PITCH_MAX - PITCH_MIN)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
	task.delay(3, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function isOnGrass(hrp: BasePart): boolean
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local char = player.Character
	rayParams.FilterDescendantsInstances = if char then { char } else {}
	local hit = Workspace:Raycast(hrp.Position + Vector3.new(0, 0.5, 0), Vector3.new(0, -RAY_DIST, 0), rayParams)
	if not hit then
		return false
	end
	if GRASS_MATERIALS[hit.Material] then
		return true
	end
	local name = string.lower(hit.Instance.Name)
	if string.find(name, "grass", 1, true) or string.find(name, "leaf", 1, true) or string.find(name, "mud", 1, true) then
		return true
	end
	return false
end

local function clearCharConns()
	for _, c in charConns do
		c:Disconnect()
	end
	table.clear(charConns)
end

local function bindCharacter(character: Model)
	clearCharConns()
	stepAccum = 0
	local humanoid = character:WaitForChild("Humanoid", 10)
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or not hrp or not hrp:IsA("BasePart") then
		return
	end

	table.insert(
		charConns,
		humanoid.Died:Connect(function()
			stepAccum = 0
		end)
	)
end

function FootstepController.init()
	if wired then
		return
	end
	wired = true

	loadTemplates()
	if #regularSounds == 0 and #grassSounds == 0 then
		warn("[FootstepController] No Footsteps sounds under SoundEffects.Footsteps")
		return
	end

	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		bindCharacter(character)
	end)

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		local character = player.Character
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not hrp or not hrp:IsA("BasePart") then
			return
		end
		if humanoid.Health <= 0 then
			return
		end

		local speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
		if humanoid.FloorMaterial == Enum.Material.Air or speed < MIN_MOVE_SPEED then
			stepAccum = 0
			return
		end

		local interval = STEP_INTERVAL_BASE * (16 / math.max(humanoid.WalkSpeed, 8))
		stepAccum += dt
		if stepAccum < interval then
			return
		end
		stepAccum = 0

		local useGrass = isOnGrass(hrp :: BasePart) and #grassSounds > 0
		if useGrass then
			local s, idx = pickNext(grassSounds, lastIndexGrass)
			lastIndexGrass = idx
			if s then
				playOne(s)
			end
		else
			local s, idx = pickNext(regularSounds, lastIndexRegular)
			lastIndexRegular = idx
			if s then
				playOne(s)
			end
		end
	end)
end

return FootstepController
