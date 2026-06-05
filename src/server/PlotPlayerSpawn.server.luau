-- [ACTIVE] PlotPlayerSpawn.server
--[[
	PlotPlayerSpawn (server)
	Teleports players onto their assigned plot's first floor on join and respawn.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local SPAWN_CLEARANCE = 4
local ASSIGN_WAIT_SEC = 20

local function expandPartBounds(cf: CFrame, size: Vector3, minV: Vector3, maxV: Vector3): (Vector3, Vector3)
	local hs = size * 0.5
	local newMin = minV
	local newMax = maxV
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local world = cf:PointToWorldSpace(Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz))
				newMin = Vector3.new(math.min(newMin.X, world.X), math.min(newMin.Y, world.Y), math.min(newMin.Z, world.Z))
				newMax = Vector3.new(math.max(newMax.X, world.X), math.max(newMax.Y, world.Y), math.max(newMax.Z, world.Z))
			end
		end
	end
	return newMin, newMax
end

local function boundingBoxOf(root: Instance): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			any = true
			minV, maxV = expandPartBounds(d.CFrame, d.Size, minV, maxV)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function cfOnTopOfBounds(minV: Vector3, maxV: Vector3, face: Vector3): CFrame
	local center = (minV + maxV) * 0.5
	local topY = maxV.Y + SPAWN_CLEARANCE
	local pos = Vector3.new(center.X, topY, center.Z)
	local flat = Vector3.new(face.X, 0, face.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

local function findFirstFloorSpawnCFrame(plot: Instance): CFrame?
	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil
	end

	local spawnNode = story1:FindFirstChild("Spawn")
	if spawnNode then
		local anchor: BasePart? = nil
		if spawnNode:IsA("BasePart") then
			anchor = spawnNode
		else
			anchor = spawnNode:FindFirstChildWhichIsA("BasePart", true)
		end
		if anchor then
			local top = anchor.CFrame.Position + Vector3.new(0, anchor.Size.Y * 0.5 + SPAWN_CLEARANCE, 0)
			local look = anchor.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 0.08 then
				flat = Vector3.new(0, 0, -1)
			end
			return CFrame.lookAt(top, top + flat.Unit)
		end
	end

	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	local bboxRoot: Instance = if floor then floor else story1
	local minV, maxV = boundingBoxOf(bboxRoot)
	if not minV or not maxV then
		return nil
	end

	local face = Vector3.new(0, 0, -1)
	local posPart = PlotPaths.findSpawnAndBasesFolder()
	local slotId = plot:GetAttribute("PlotSlotId")
	if posPart and typeof(slotId) == "number" then
		local anchor = posPart:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
		if anchor and anchor:IsA("BasePart") then
			local look = (anchor :: BasePart).CFrame.LookVector
			face = Vector3.new(look.X, 0, look.Z)
		end
	end

	return cfOnTopOfBounds(minV, maxV, face)
end

local function waitForAssignedPlot(player: Player, character: Model): Instance?
	local deadline = os.clock() + ASSIGN_WAIT_SEC
	while os.clock() < deadline do
		if not character.Parent or not player.Parent then
			return nil
		end
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot and plot.Parent then
			return plot
		end
		task.wait(0.1)
	end
	return PlotPaths.findPlotForAssignedSlot(player)
end

local function teleportCharacterToCFrame(character: Model, spawnCf: CFrame)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = character:WaitForChild("HumanoidRootPart", 8) :: BasePart?
	end
	if not hrp then
		return
	end

	if character.PrimaryPart then
		character:PivotTo(spawnCf)
	else
		hrp.CFrame = spawnCf
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end

local function teleportToPlotSpawn(player: Player, character: Model)
	local reviveCf = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR)
	if typeof(reviveCf) == "CFrame" then
		player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
		teleportCharacterToCFrame(character, reviveCf)
		return
	end

	local plot = waitForAssignedPlot(player, character)
	if not plot or not plot.Parent then
		return
	end

	local spawnCf = findFirstFloorSpawnCFrame(plot)
	if not spawnCf then
		return
	end

	teleportCharacterToCFrame(character, spawnCf)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		task.wait(0.05)
		teleportToPlotSpawn(player, character)
	end)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		local char = player.Character
		if char then
			task.defer(function()
				teleportToPlotSpawn(player, char)
			end)
		end
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
end

for _, player in Players:GetPlayers() do
	hookPlayer(player)
end
Players.PlayerAdded:Connect(hookPlayer)
