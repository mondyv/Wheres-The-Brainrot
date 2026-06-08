-- [ACTIVE] Leaderboards.server
--[[
	Global Cash + Play Time leaderboards.
	Pushes OrderedDataStore scores on the server and mirrors top 10 rows to
	ReplicatedStorage.LeaderboardData for the client to paint workspace SurfaceGuis.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local LiveDataStores = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveDataStores"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

local CASH_STORE_NAME = "GlobalCashLeaderboard_v1"
local TIME_STORE_NAME = "GlobalPlayTimeLeaderboard_v1"
local ROW_COUNT = 10
local PUSH_INTERVAL_SEC = 45
local REFRESH_INTERVAL_SEC = 90
local DATA_FOLDER_NAME = "LeaderboardData"

local leaderboardsEnabled = LiveDataStores.isEnabled()
local cashStore = if leaderboardsEnabled then DataStoreService:GetOrderedDataStore(CASH_STORE_NAME) else nil
local timeStore = if leaderboardsEnabled then DataStoreService:GetOrderedDataStore(TIME_STORE_NAME) else nil

local nameCache: { [number]: string } = {}

local function ensureDataFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(DATA_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = DATA_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function setString(parent: Instance, name: string, value: string)
	local node = parent:FindFirstChild(name)
	if not node then
		node = Instance.new("StringValue")
		node.Name = name
		node.Parent = parent
	end
	if node:IsA("StringValue") then
		node.Value = value
	end
end

local function publishBoard(boardName: string, entries: { { rank: number, userId: number, displayName: string, amountText: string } })
	local root = ensureDataFolder()
	local board = root:FindFirstChild(boardName)
	if not board then
		board = Instance.new("Folder")
		board.Name = boardName
		board.Parent = root
	end
	for rank = 1, ROW_COUNT do
		local rowFolder = board:FindFirstChild(tostring(rank))
		if not rowFolder then
			rowFolder = Instance.new("Folder")
			rowFolder.Name = tostring(rank)
			rowFolder.Parent = board
		end
		local entry = entries[rank]
		if entry then
			setString(rowFolder, "Rank", "#" .. tostring(entry.rank))
			setString(rowFolder, "User", entry.displayName)
			setString(rowFolder, "Amount", entry.amountText)
		else
			setString(rowFolder, "Rank", "#" .. tostring(rank))
			setString(rowFolder, "User", "---")
			setString(rowFolder, "Amount", "---")
		end
	end
	board:SetAttribute("UpdatedAt", os.time())
end

local function getDisplayName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local display = if ok and typeof(name) == "string" then name else ("User" .. tostring(userId))
	nameCache[userId] = display
	return display
end

local function pushScore(store: OrderedDataStore?, userId: number, score: number)
	if not store then
		return
	end
	local key = tostring(userId)
	local value = math.max(0, math.floor(score))
	pcall(function()
		store:UpdateAsync(key, function(oldValue)
			if typeof(oldValue) == "number" and oldValue >= value then
				return oldValue
			end
			return value
		end)
	end)
end

local function pushPlayerScores(player: Player)
	if not leaderboardsEnabled or player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true then
		return
	end
	local cash = player:GetAttribute("Cash")
	if typeof(cash) == "number" then
		pushScore(cashStore, player.UserId, cash)
	end
	pushScore(timeStore, player.UserId, PlayerDataService.getTotalPlayTimeSeconds(player))
end

local function pushAllPlayerScores()
	if not leaderboardsEnabled then
		return
	end
	for _, player in Players:GetPlayers() do
		pushPlayerScores(player)
	end
end

local function buildSessionEntries(
	scoreForPlayer: (Player) -> number,
	formatAmount: (number) -> string
): { { rank: number, userId: number, displayName: string, amountText: string } }
	local scored: { { userId: number, score: number } } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) == true then
			table.insert(scored, {
				userId = player.UserId,
				score = scoreForPlayer(player),
			})
		end
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	local entries: { { rank: number, userId: number, displayName: string, amountText: string } } = {}
	for index, row in ipairs(scored) do
		if index > ROW_COUNT then
			break
		end
		entries[index] = {
			rank = index,
			userId = row.userId,
			displayName = getDisplayName(row.userId),
			amountText = formatAmount(row.score),
		}
	end
	return entries
end

local function fetchTop(store: OrderedDataStore?, formatAmount: (number) -> string): { { rank: number, userId: number, displayName: string, amountText: string } }
	local entries: { { rank: number, userId: number, displayName: string, amountText: string } } = {}
	if not store then
		return entries
	end
	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, ROW_COUNT)
	end)
	if not ok or not pages then
		warn("[Leaderboards] GetSortedAsync failed for store")
		return entries
	end
	local page = pages:GetCurrentPage()
	for index, item in ipairs(page) do
		local userId = tonumber(item.key)
		local value = if typeof(item.value) == "number" then item.value else tonumber(item.value)
		if userId and typeof(value) == "number" then
			table.insert(entries, {
				rank = index,
				userId = userId,
				displayName = getDisplayName(userId),
				amountText = formatAmount(value),
			})
		end
	end
	return entries
end

local function refreshPublishedBoards()
	if not leaderboardsEnabled then
		local cashEntries = buildSessionEntries(function(player: Player)
			local cash = player:GetAttribute("Cash")
			return if typeof(cash) == "number" then cash else 0
		end, BrainrotEconomy.formatCashShort)
		local timeEntries = buildSessionEntries(function(player: Player)
			return PlayerDataService.getTotalPlayTimeSeconds(player)
		end, BrainrotEconomy.formatPlayTime)
		publishBoard("Cash", cashEntries)
		publishBoard("Time", timeEntries)
		return
	end

	local cashEntries = fetchTop(cashStore, BrainrotEconomy.formatCashShort)
	if #cashEntries == 0 then
		cashEntries = buildSessionEntries(function(player: Player)
			local cash = player:GetAttribute("Cash")
			return if typeof(cash) == "number" then cash else 0
		end, BrainrotEconomy.formatCashShort)
	end
	local timeEntries = fetchTop(timeStore, BrainrotEconomy.formatPlayTime)
	if #timeEntries == 0 then
		timeEntries = buildSessionEntries(function(player: Player)
			return PlayerDataService.getTotalPlayTimeSeconds(player)
		end, BrainrotEconomy.formatPlayTime)
	end
	publishBoard("Cash", cashEntries)
	publishBoard("Time", timeEntries)
end

task.spawn(function()
	while true do
		task.wait(PUSH_INTERVAL_SEC)
		pushAllPlayerScores()
		task.wait(2)
		refreshPublishedBoards()
	end
end)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL_SEC)
		refreshPublishedBoards()
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if not leaderboardsEnabled then
		return
	end
	pushPlayerScores(player)
	task.defer(refreshPublishedBoards)
end)

Players.PlayerAdded:Connect(function(player)
	local function tryPush()
		pushPlayerScores(player)
		task.delay(2, refreshPublishedBoards)
	end
	if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) == true then
		task.defer(tryPush)
	else
		local conn: RBXScriptConnection?
		conn = player:GetAttributeChangedSignal(PlayerDataSchema.LOADED_ATTR):Connect(function()
			if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) == true then
				if conn then
					conn:Disconnect()
				end
				task.defer(tryPush)
			end
		end)
	end
end)

task.defer(refreshPublishedBoards)

if not leaderboardsEnabled then
	warn("[Leaderboards] OrderedDataStore leaderboards disabled — publish or enable Studio API access")
end
