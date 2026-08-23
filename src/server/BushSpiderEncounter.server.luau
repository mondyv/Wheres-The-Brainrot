-- [ACTIVE] BushSpiderEncounter.server
--[[
	Server-authoritative catch-up when wave web reaches the player.
	Teleports them home alive (no LoadCharacter) so the client can fade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ReviveService = require(script.Parent:WaitForChild("Modules"):WaitForChild("ReviveService"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local KILL_REMOTE = "BushSpiderEncounterKill"
local KILL_COOLDOWN = 0.8

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

	local okFunnel, Funnel = pcall(function()
		return require(script.Parent:WaitForChild("Modules"):WaitForChild("AnalyticsFunnelService"))
	end)
	if okFunnel and Funnel and typeof(Funnel.waveChaseDied) == "function" then
		Funnel.waveChaseDied(plr)
	end

	plr:SetAttribute(ReviveConfig.WAVE_WEB_DEATH_ATTR, true)

	local internal = ServerStorage:FindFirstChild("BrainrotInternal")
	local clearCarry = internal and internal:FindFirstChild("ClearHeadCarry")
	if clearCarry and clearCarry:IsA("BindableFunction") then
		local okClear, errClear = pcall(function()
			(clearCarry :: BindableFunction):Invoke(plr)
		end)
		if not okClear then
			warn("[BushSpiderEncounter] ClearHeadCarry failed:", errClear)
		end
	end

	ReviveService.softTeleportHomeAlive(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
	lastKillAt[plr] = nil
end)
