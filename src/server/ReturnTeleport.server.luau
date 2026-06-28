-- [ACTIVE] ReturnTeleport.server
--[[
	Validates and teleports players back to their assigned plot spawn when they use the Return button.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local RETURN_COOLDOWN_SEC = 2.5
local lastReturnAt: { [Player]: number } = {}

local returnRF: RemoteFunction? = nil

local function ensureReturnRemote(): RemoteFunction
	if returnRF and returnRF.Parent then
		return returnRF
	end
	local existing = ReplicatedStorage:FindFirstChild("ReturnToPlot")
	if existing and existing:IsA("RemoteFunction") then
		returnRF = existing
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = "ReturnToPlot"
	rf.Parent = ReplicatedStorage
	returnRF = rf
	return rf
end

local function countCarriedBrainrots(character: Model): number
	local n = 0
	for _, d in character:GetDescendants() do
		if d:IsA("Model") then
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" or phase == "Pop" then
				n += 1
			end
		elseif d:IsA("WeldConstraint") and d.Name == "BrainrotCarryWeld" then
			n += 1
		end
	end
	return n
end

local function canReturnToPlot(player: Player): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "No character"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Cannot return right now"
	end

	if SafezoneUtil.isCharacterInSafezone(character) then
		return false, "Already in the safe zone"
	end

	local carryCount = player:GetAttribute("BrainrotCarryCount")
	if typeof(carryCount) == "number" and carryCount > 0 then
		return false, "Drop your brainrot first"
	end

	if countCarriedBrainrots(character) > 0 then
		return false, "Drop your brainrot first"
	end

	local now = os.clock()
	if (lastReturnAt[player] or 0) + RETURN_COOLDOWN_SEC > now then
		return false, "Please wait a moment"
	end

	local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
	if not spawnCf then
		return false, "Base not ready yet"
	end

	return true, nil
end

local function onReturnRequest(player: Player): (boolean, string?)
	local ok, reason = canReturnToPlot(player)
	if not ok then
		return false, reason or "Cannot return"
	end

	local character = player.Character
	if not character then
		return false, "No character"
	end

	local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
	if not spawnCf then
		return false, "Base not ready yet"
	end

	PlotSpawnUtil.teleportCharacterToCFrame(character, spawnCf)
	lastReturnAt[player] = os.clock()
	return true, nil
end

ensureReturnRemote().OnServerInvoke = onReturnRequest

Players.PlayerRemoving:Connect(function(player)
	lastReturnAt[player] = nil
end)
