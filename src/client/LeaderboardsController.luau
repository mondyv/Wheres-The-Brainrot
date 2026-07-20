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
local ROW_COUNT = 10
local RETRY_INTERVAL_SEC = 2

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

local function hookRowFolder(boardName: string, rowFolder: Folder)
	for _, child in rowFolder:GetChildren() do
		if child:IsA("StringValue") then
			child.Changed:Connect(function()
				local boardFolder = rowFolder.Parent
				if boardFolder and boardFolder:IsA("Folder") then
					local dataFolder = boardFolder.Parent
					if dataFolder and dataFolder:IsA("Folder") then
						task.defer(function()
							paintAllFromData(dataFolder :: Folder)
						end)
					end
				end
			end)
		end
	end
	rowFolder.ChildAdded:Connect(function(child)
		if child:IsA("StringValue") then
			child.Changed:Connect(function()
				local boardFolder = rowFolder.Parent
				if boardFolder and boardFolder:IsA("Folder") then
					local dataFolder = boardFolder.Parent
					if dataFolder and dataFolder:IsA("Folder") then
						task.defer(function()
							paintAllFromData(dataFolder :: Folder)
						end)
					end
				end
			end)
		end
	end)
end

local function hookBoardFolder(boardName: string, boardFolder: Folder)
	for rank = 1, ROW_COUNT do
		local rowFolder = boardFolder:FindFirstChild(tostring(rank))
		if rowFolder and rowFolder:IsA("Folder") then
			hookRowFolder(boardName, rowFolder)
		end
	end
	boardFolder.ChildAdded:Connect(function(child)
		if child:IsA("Folder") then
			hookRowFolder(boardName, child)
		end
	end)
	boardFolder:GetAttributeChangedSignal("UpdatedAt"):Connect(function()
		local dataFolder = boardFolder.Parent
		if dataFolder and dataFolder:IsA("Folder") then
			task.defer(function()
				paintAllFromData(dataFolder :: Folder)
			end)
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
			task.defer(function()
				paintAllFromData(dataFolder)
			end)
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
		while true do
			paintAllFromData(dataFolder)
			task.wait(RETRY_INTERVAL_SEC)
		end
	end)

	task.spawn(function()
		local dataFolder = waitForDataFolder()
		local function onWorldChange()
			task.defer(function()
				paintAllFromData(dataFolder)
			end)
		end
		Workspace.DescendantAdded:Connect(function(child)
			if
				child.Name == "LeaderBoards"
				or child.Name == "Leaderboards"
				or child.Name == "GUIPart"
				or child:IsA("SurfaceGui")
				or string.find(child.Name, "Stud UI Pack", 1, true)
			then
				onWorldChange()
			end
		end)
	end)
end

return M
