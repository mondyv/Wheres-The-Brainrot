-- [ACTIVE] Leaderboards.server
--[[
	Global Most Cash (plot $/s) + Play Time leaderboards.
	Pushes OrderedDataStore scores on the server and mirrors top 10 rows to
	ReplicatedStorage.LeaderboardData for the client to paint workspace SurfaceGuis.

	"Most Cash" tracks current placed plot income/sec (not wallet Cash).
	Scores can go down when generation drops so the board stays live.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local LiveDataStores = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveDataStores"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

-- v2: plot income/sec. Old GlobalCashLeaderboard_v1 was peak wallet Cash and polluted rankings.
local CASH_STORE_NAME = "GlobalPlotIncomeLeaderboard_v1"
local TIME_STORE_NAME = "GlobalPlayTimeLeaderboard_v1"
local ROW_COUNT = 10
local PUSH_INTERVAL_SEC = 45
local REFRESH_INTERVAL_SEC = 90
local DATA_FOLDER_NAME = "LeaderboardData"
local STAND_TAG = "BrainrotStand"

local leaderboardsEnabled = LiveDataStores.isEnabled()
local cashStore = if leaderboardsEnabled then DataStoreService:GetOrderedDataStore(CASH_STORE_NAME) else nil
local timeStore = if leaderboardsEnabled then DataStoreService:GetOrderedDataStore(TIME_STORE_NAME) else nil

local nameCache: { [number]: string } = {}

local function formatIncomePerSecond(n: number): string
	return BrainrotEconomy.formatCashShort(n) .. "/s"
end

local function placedIncomePerSecond(player: Player): number
	local total = 0
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if stand:GetAttribute("StandOwnerUserId") == player.UserId then
			local name = stand:GetAttribute("BrainrotName")
			local rarity = stand:GetAttribute("BrainrotRarity")
			if typeof(name) == "string" and typeof(rarity) == "string" then
				local def = {
					name = name,
					rarity = rarity,
					baseIncome = stand:GetAttribute("BrainrotBaseIncome") or 0,
				}
				local level = stand:GetAttribute("BrainrotLevel")
				local mutation = stand:GetAttribute("BrainrotMutation")
				total += Brainrots.incomePerSecond(
					def,
					if typeof(level) == "number" then level else 1,
					if typeof(mutation) == "string" then mutation else "normal"
				)
			end
		end
	end
	return total
end

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

local function setNumber(parent: Instance, name: string, value: number)
	local node = parent:FindFirstChild(name)
	if not node then
		node = Instance.new("IntValue")
		node.Name = name
		node.Parent = parent
	end
	if node:IsA("IntValue") then
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
			setNumber(rowFolder, "UserId", entry.userId)
		else
			setString(rowFolder, "Rank", "#" .. tostring(rank))
			setString(rowFolder, "User", "---")
			setString(rowFolder, "Amount", "---")
			setNumber(rowFolder, "UserId", 0)
		end
	end
	board:SetAttribute("UpdatedAt", os.time())
end

local function getDisplayName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.DisplayName
		return player.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local display = if ok and typeof(name) == "string" then name else ("User" .. tostring(userId))
	nameCache[userId] = display
	return display
end

-- peakOnly: never lower a stored score (play time). Live boards overwrite with current value.
local function pushScore(store: OrderedDataStore?, userId: number, score: number, peakOnly: boolean)
	if not store then
		return
	end
	local key = tostring(userId)
	local value = math.max(0, math.floor(score))
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(oldValue)
			if peakOnly and typeof(oldValue) == "number" and oldValue >= value then
				return oldValue
			end
			return value
		end)
	end)
	if not ok then
		warn("[Leaderboards] UpdateAsync failed for key", key, ":", err)
	end
end

local function pushPlayerScores(player: Player)
	if not leaderboardsEnabled or player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true then
		return
	end
	pushScore(cashStore, player.UserId, placedIncomePerSecond(player), false)
	pushScore(timeStore, player.UserId, PlayerDataService.getTotalPlayTimeSeconds(player), true)
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
		local cashEntries = buildSessionEntries(placedIncomePerSecond, formatIncomePerSecond)
		local timeEntries = buildSessionEntries(function(player: Player)
			return PlayerDataService.getTotalPlayTimeSeconds(player)
		end, BrainrotEconomy.formatPlayTime)
		publishBoard("Cash", cashEntries)
		publishBoard("Time", timeEntries)
		return
	end

	local cashEntries = fetchTop(cashStore, formatIncomePerSecond)
	if #cashEntries == 0 then
		cashEntries = buildSessionEntries(placedIncomePerSecond, formatIncomePerSecond)
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

local loadedConns: { [Player]: RBXScriptConnection } = {}

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
				loadedConns[player] = nil
				task.defer(tryPush)
			end
		end)
		loadedConns[player] = conn
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local conn = loadedConns[player]
	if conn then
		conn:Disconnect()
		loadedConns[player] = nil
	end
end)

task.defer(refreshPublishedBoards)

-- Studio without DataStore API: session boards still refresh often so the UI isn't empty.
task.spawn(function()
	task.wait(3)
	refreshPublishedBoards()
	for _ = 1, 10 do
		task.wait(5)
		refreshPublishedBoards()
	end
end)
