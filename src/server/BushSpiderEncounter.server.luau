-- [ACTIVE] BushSpiderEncounter.server
--[[
	Server-authoritative kill when spider/wave web hits the player.
	Wave web deaths soft-respawn immediately onto the same plot Spawn pad as
	Return / Base button (no QuestHitbox, no long stream wait before snap).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))
local ReviveService = require(script.Parent:WaitForChild("Modules"):WaitForChild("ReviveService"))

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

	-- Immediate Base/Return pad respawn (Died handler is skipped via soft-respawn debounce).
	plr:SetAttribute(ReviveConfig.WAVE_WEB_DEATH_ATTR, true)
	local okFunnel, Funnel = pcall(function()
		return require(script.Parent:WaitForChild("Modules"):WaitForChild("AnalyticsFunnelService"))
	end)
	if okFunnel and Funnel and typeof(Funnel.waveChaseDied) == "function" then
		Funnel.waveChaseDied(plr)
	end
	ReviveService.softRespawnAtPlotBase(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
	lastKillAt[plr] = nil
end)
