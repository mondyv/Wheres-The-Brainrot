-- [ACTIVE] Index.server
--[[
	Index unlocks on brainrot deposit + client state sync.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Modules = script.Parent:WaitForChild("Modules")
local IndexService = require(Modules:WaitForChild("IndexService"))
local PlayerDataService = require(Modules:WaitForChild("PlayerDataService"))
local LevelService = require(Modules:WaitForChild("LevelService"))
local IndexConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("IndexConfig"))

local function ensureRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild("IndexRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "IndexRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureInternal(): Folder
	local folder = ServerStorage:FindFirstChild("IndexInternal")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "IndexInternal"
		folder.Parent = ServerStorage
	end
	return folder :: Folder
end

local remotes = ensureRemotes()

local getStateRF = remotes:FindFirstChild("GetIndexState") :: RemoteFunction?
if not getStateRF then
	getStateRF = Instance.new("RemoteFunction")
	getStateRF.Name = "GetIndexState"
	getStateRF.Parent = remotes
end

local unlockedRE = remotes:FindFirstChild("IndexUnlocked") :: RemoteEvent?
if not unlockedRE then
	unlockedRE = Instance.new("RemoteEvent")
	unlockedRE.Name = "IndexUnlocked"
	unlockedRE.Parent = remotes
end

getStateRF.OnServerInvoke = function(player: Player, mutationId: any)
	local mut = if typeof(mutationId) == "string" then mutationId else "normal"
	if not IndexConfig.TAB_DISPLAY_NAME[mut] then
		mut = "normal"
	end
	return IndexService.packStateForClient(player, mut)
end

local collectRF = remotes:FindFirstChild("CollectIndexEntry") :: RemoteFunction?
if not collectRF then
	collectRF = Instance.new("RemoteFunction")
	collectRF.Name = "CollectIndexEntry"
	collectRF.Parent = remotes
end

local lastCollectAt: { [Player]: number } = {}

collectRF.OnServerInvoke = function(player: Player, name: any, mutationId: any)
	if typeof(name) ~= "string" or typeof(mutationId) ~= "string" then
		return { ok = false, xp = 0 }
	end
	local now = os.clock()
	if (lastCollectAt[player] or 0) + 0.25 > now then
		return { ok = false, xp = 0 }
	end
	lastCollectAt[player] = now
	local xp = IndexService.tryCollect(player, name, mutationId)
	if xp <= 0 then
		return { ok = false, xp = 0 }
	end
	LevelService.addXp(player, xp, "index_collect")
	return { ok = true, xp = xp }
end

local internal = ensureInternal()
local depositBF = internal:FindFirstChild("OnBrainrotDeposited") :: BindableFunction?
if not depositBF then
	depositBF = Instance.new("BindableFunction")
	depositBF.Name = "OnBrainrotDeposited"
	depositBF.Parent = internal
end

depositBF.OnInvoke = function(player: any, entry: any): boolean
	if typeof(player) ~= "Instance" or not (player :: Instance):IsA("Player") then
		return false
	end
	if typeof(entry) ~= "table" then
		return false
	end
	local name = entry.name
	local mutation = entry.mutation
	if typeof(name) ~= "string" or typeof(mutation) ~= "string" then
		return false
	end
	local isNew = IndexService.recordUnlock(player :: Player, name, mutation)
	if isNew then
		unlockedRE:FireClient(player :: Player, {
			name = name,
			mutation = mutation,
			goldenCount = IndexService.getGoldenCount(player :: Player),
			questComplete = (player :: Player):GetAttribute("IndexGoldenQuestComplete") == true,
		})
	end
	-- Rebirth brainrot reqs come from index unlocks only — refresh after every deposit.
	local brainrotInternal = ServerStorage:FindFirstChild("BrainrotInternal")
	local refresh = brainrotInternal and brainrotInternal:FindFirstChild("RefreshRebirthState")
	if refresh and refresh:IsA("BindableFunction") then
		pcall(function()
			(refresh :: BindableFunction):Invoke(player)
		end)
	end
	return isNew
end

local function onPlayer(player: Player)
	PlayerDataService.waitUntilLoaded(player)
	IndexService.initPlayer(player)
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do
	onPlayer(p)
end

Players.PlayerRemoving:Connect(function(player)
	lastCollectAt[player] = nil
	task.defer(function()
		IndexService.clearPlayer(player)
	end)
end)
