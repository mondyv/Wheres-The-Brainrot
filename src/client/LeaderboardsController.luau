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
local RETRY_INTERVAL_SEC = 3

local function readRows(boardFolder: Folder): { LeaderboardUI.RowEntry }
	local rows: { LeaderboardUI.RowEntry } = {}
	for rank = 1, ROW_COUNT do
		local rowFolder = boardFolder:FindFirstChild(tostring(rank))
		if not rowFolder then
			continue
		end
		local userVal = rowFolder:FindFirstChild("User")
		local amountVal = rowFolder:FindFirstChild("Amount")
		local userText = if userVal and userVal:IsA("StringValue") then userVal.Value else "---"
		local amountText = if amountVal and amountVal:IsA("StringValue") then amountVal.Value else "---"
		rows[rank] = {
			rank = rank,
			userId = 0,
			displayName = userText,
			amountText = amountText,
		}
	end
	return rows
end

local function paintBoard(boardName: string, boardFolder: Folder?): boolean
	if not boardFolder then
		return false
	end
	local container = LeaderboardUI.findBoardContainer(boardName)
	if not container then
		return false
	end
	return LeaderboardUI.renderBoard(container, readRows(boardFolder))
end

local function paintAllFromData(dataFolder: Folder): boolean
	local anyPainted = false
	for _, boardName in BOARD_NAMES do
		local boardFolder = dataFolder:FindFirstChild(boardName)
		if boardFolder and boardFolder:IsA("Folder") then
			if paintBoard(boardName, boardFolder) then
				anyPainted = true
			end
		end
	end
	return anyPainted
end

local function hookRowFolder(boardName: string, rowFolder: Folder)
	for _, child in rowFolder:GetChildren() do
		if child:IsA("StringValue") then
			child.Changed:Connect(function()
				local boardFolder = rowFolder.Parent
				if boardFolder and boardFolder:IsA("Folder") then
					task.defer(function()
						paintBoard(boardName, boardFolder :: Folder)
					end)
				end
			end)
		end
	end
	rowFolder.ChildAdded:Connect(function(child)
		if child:IsA("StringValue") then
			child.Changed:Connect(function()
				local boardFolder = rowFolder.Parent
				if boardFolder and boardFolder:IsA("Folder") then
					task.defer(function()
						paintBoard(boardName, boardFolder :: Folder)
					end)
				end
			end)
			task.defer(function()
				local boardFolder = rowFolder.Parent
				if boardFolder and boardFolder:IsA("Folder") then
					paintBoard(boardName, boardFolder :: Folder)
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
			task.defer(function()
				paintBoard(boardName, boardFolder)
			end)
		end
	end)
	boardFolder:GetAttributeChangedSignal("UpdatedAt"):Connect(function()
		task.defer(function()
			paintBoard(boardName, boardFolder)
		end)
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
				paintBoard(child.Name, child :: Folder)
			end)
		end
	end)
end

function M.init()
	task.spawn(function()
		Workspace:WaitForChild("Building Assets", 300)
		local dataFolder = ReplicatedStorage:WaitForChild(DATA_FOLDER_NAME, 120)
		if not dataFolder or not dataFolder:IsA("Folder") then
			warn("[LeaderboardsController] LeaderboardData folder missing")
			return
		end
		hookDataFolder(dataFolder)
		while true do
			paintAllFromData(dataFolder)
			task.wait(RETRY_INTERVAL_SEC)
		end
	end)

	task.spawn(function()
		Workspace:WaitForChild("Building Assets", 300)
		local dataFolder = ReplicatedStorage:WaitForChild(DATA_FOLDER_NAME, 120)
		if not dataFolder or not dataFolder:IsA("Folder") then
			return
		end
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Building Assets" or string.find(child.Name, "Stud UI Pack", 1, true) then
				task.defer(function()
					paintAllFromData(dataFolder :: Folder)
				end)
			end
		end)
	end)
end

return M
