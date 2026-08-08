-- [ACTIVE] BushSpiderEncounter.server
--[[
	Server-authoritative kill when spider/wave web hits the player (Revive flow).
	Wave web deaths pin plot Base spawn instead of QuestHitbox.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local KILL_REMOTE = "BushSpiderEncounterKill"
local KILL_COOLDOWN = 2.5

local lastKillAt: { [Player]: number } = {}

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local killRE = ensureRemoteEvent(KILL_REMOTE)

killRE.OnServerEvent:Connect(function(plr: Player)
	local now = os.clock()
	if (lastKillAt[plr] or 0) + KILL_COOLDOWN > now then
		return
	end
	lastKillAt[plr] = now

	-- Prefer plot Base on next soft respawn (Wave Web chase uses this kill remote).
	plr:SetAttribute(ReviveConfig.WAVE_WEB_DEATH_ATTR, true)
	local baseCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(plr)
	if baseCf then
		plr:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, baseCf.Position)
		plr:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, baseCf.LookVector)
		pcall(function()
			plr:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, baseCf)
		end)
	end

	local character = plr.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		local dyingChar = character
		humanoid.BreakJointsOnDeath = true
		humanoid.Health = 0
		task.defer(function()
			if plr.Character ~= dyingChar then
				return
			end
			if dyingChar.Parent and humanoid.Parent == dyingChar and humanoid.Health <= 0 then
				dyingChar:BreakJoints()
			end
		end)
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	lastKillAt[plr] = nil
end)
