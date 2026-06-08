-- [ACTIVE] LeaderboardUI
--[[
	Finds workspace leaderboard SurfaceGuis and renders row text (client + server).
--]]

local Workspace = game:GetService("Workspace")

local M = {}

export type RowEntry = {
	rank: number,
	userId: number,
	displayName: string,
	amountText: string,
}

local ROW_COUNT = 10

function M.findLeaderboardsRoot(): Instance?
	local buildingAssets = Workspace:FindFirstChild("Building Assets")
	if not buildingAssets then
		return nil
	end
	for _, child in buildingAssets:GetChildren() do
		if string.find(child.Name, "Stud UI Pack", 1, true) then
			local modelGui = child:FindFirstChild("ModelGUI") or child:FindFirstChild("ModelGui")
			if modelGui then
				return modelGui:FindFirstChild("LeaderBoards") or modelGui:FindFirstChild("Leaderboards")
			end
		end
	end
	return nil
end

function M.findBoardContainer(boardName: string): Frame?
	local root = M.findLeaderboardsRoot()
	if not root then
		return nil
	end
	local board = root:FindFirstChild(boardName)
	if not board then
		return nil
	end
	local guiPart = board:FindFirstChild("GUIPart")
	if not guiPart then
		return nil
	end
	local surfaceGui = guiPart:FindFirstChildOfClass("SurfaceGui")
	if not surfaceGui then
		return nil
	end
	local frame = surfaceGui:FindFirstChild("Frame")
	if not frame then
		return nil
	end
	local container = frame:FindFirstChild("Container")
	if container and container:IsA("Frame") then
		return container
	end
	return nil
end

local function setTextLabel(node: Instance?, text: string)
	if not node then
		return
	end
	if node:IsA("TextLabel") or node:IsA("TextButton") then
		node.Text = text
	end
end

function M.renderBoard(container: Frame?, entries: { RowEntry })
	if not container then
		return false
	end
	for rank = 1, ROW_COUNT do
		local row = container:FindFirstChild(tostring(rank))
		if not row or not row:IsA("GuiObject") then
			continue
		end
		local entry = entries[rank]
		local rankLabel = row:FindFirstChild("Rank", true)
		local userLabel = row:FindFirstChild("User", true)
		local amountLabel = row:FindFirstChild("Amount", true)
		if entry then
			setTextLabel(rankLabel, "#" .. tostring(entry.rank))
			local userText = entry.displayName
			if userText ~= "" and string.sub(userText, 1, 1) ~= "@" then
				userText = "@" .. userText
			end
			setTextLabel(userLabel, userText)
			setTextLabel(amountLabel, entry.amountText)
		else
			setTextLabel(rankLabel, "#" .. tostring(rank))
			setTextLabel(userLabel, "---")
			setTextLabel(amountLabel, "---")
		end
		row.Visible = true
	end
	return true
end

function M.renderBoardByName(boardName: string, entries: { RowEntry }): boolean
	return M.renderBoard(M.findBoardContainer(boardName), entries)
end

return M
