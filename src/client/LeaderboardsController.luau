-- [ACTIVE] LeaderboardsController
--[[
	Renders global leaderboard rows on workspace SurfaceGuis (client-local, streaming-safe).
	Server publishes rows under ReplicatedStorage.LeaderboardData.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LeaderboardUI = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LeaderboardUI"))

local M = {}

local DATA_FOLDER_NAME = "LeaderboardData"
local BOARD_NAMES = { "Cash", "Time" }
local ROW_COUNT = 100
local RETRY_INTERVAL_SEC = 8
local PAINT_DEBOUNCE_SEC = 0.25

local paintScheduled = false

local function readRows(boardFolder: Folder): { LeaderboardUI.RowEntry }
	local rows: { LeaderboardUI.RowEntry } = {}
	for rank = 1, ROW_COUNT do
		local rowFolder = boardFolder:FindFirstChild(tostring(rank))
		if not rowFolder then
			continue
		end
		local userVal = rowFolder:FindFirstChild("User")
		local amountVal = rowFolder:FindFirstChild("Amount")
		local userIdVal = rowFolder:FindFirstChild("UserId")
		local userText = if userVal and userVal:IsA("StringValue") then userVal.Value else "---"
		local amountText = if amountVal and amountVal:IsA("StringValue") then amountVal.Value else "---"
		local userId = if userIdVal and userIdVal:IsA("IntValue") then userIdVal.Value else 0
		rows[rank] = {
			rank = rank,
			userId = userId,
			displayName = userText,
			amountText = amountText,
		}
	end
	return rows
end

local function readAllBoardData(dataFolder: Folder): { [string]: { LeaderboardUI.RowEntry } }
	local out: { [string]: { LeaderboardUI.RowEntry } } = {}
	for _, boardName in BOARD_NAMES do
		local boardFolder = dataFolder:FindFirstChild(boardName)
		if boardFolder and boardFolder:IsA("Folder") then
			out[boardName] = readRows(boardFolder)
		end
	end
	return out
end

local function paintAllFromData(dataFolder: Folder): boolean
	return LeaderboardUI.renderAllBoards(readAllBoardData(dataFolder))
end

local function schedulePaint(dataFolder: Folder)
	if paintScheduled then
		return
	end
	paintScheduled = true
	task.delay(PAINT_DEBOUNCE_SEC, function()
		paintScheduled = false
		if dataFolder.Parent then
			paintAllFromData(dataFolder)
		end
	end)
end

local function hookBoardFolder(_boardName: string, boardFolder: Folder)
	boardFolder:GetAttributeChangedSignal("UpdatedAt"):Connect(function()
		local dataFolder = boardFolder.Parent
		if dataFolder and dataFolder:IsA("Folder") then
			schedulePaint(dataFolder)
		end
	end)
end

local function hookDataFolder(dataFolder: Folder)
	for _, boardName in BOARD_NAMES do
		local boardFolder = dataFolder:FindFirstChild(boardName)
		if boardFolder and boardFolder:IsA("Folder") then
			hookBoardFolder(boardName, boardFolder)
		end
	end
	dataFolder.ChildAdded:Connect(function(child)
		if child:IsA("Folder") and table.find(BOARD_NAMES, child.Name) then
			hookBoardFolder(child.Name, child :: Folder)
			schedulePaint(dataFolder)
		end
	end)
end

local function waitForDataFolder(): Folder
	while true do
		local found = ReplicatedStorage:FindFirstChild(DATA_FOLDER_NAME)
		if found and found:IsA("Folder") then
			return found
		end
		task.wait(0.5)
	end
end

function M.init()
	task.spawn(function()
		local dataFolder = waitForDataFolder()
		hookDataFolder(dataFolder)
		local paintedOk = false
		while true do
			if paintAllFromData(dataFolder) then
				paintedOk = true
			end
			-- Once boards paint successfully, only refresh on data hooks — slow retry for streaming.
			task.wait(if paintedOk then RETRY_INTERVAL_SEC else 2)
		end
	end)

	task.spawn(function()
		local dataFolder = waitForDataFolder()
		local function onWorldChange()
			LeaderboardUI.invalidateBoardCache()
			schedulePaint(dataFolder)
		end
		local function isLeaderboardWorldInst(inst: Instance): boolean
			local n = inst.Name
			if
				n == "LeaderBoards"
				or n == "Leaderboards"
				or n == "TimeLeaderboard"
				or n == "CashLeaderboard"
			then
				return true
			end
			if inst:IsA("SurfaceGui") then
				local p = inst.Parent
				while p and p ~= Workspace do
					local pn = p.Name
					if
						pn == "LeaderBoards"
						or pn == "Leaderboards"
						or pn == "TimeLeaderboard"
						or pn == "CashLeaderboard"
					then
						return true
					end
					p = p.Parent
				end
			end
			return false
		end
		Workspace.DescendantAdded:Connect(function(child)
			if isLeaderboardWorldInst(child) then
				onWorldChange()
			end
		end)
	end)
end

return M
