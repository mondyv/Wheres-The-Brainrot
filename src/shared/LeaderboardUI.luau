-- [ACTIVE] LeaderboardUI
--[[
	Finds workspace leaderboard SurfaceGuis and renders row text.
	Scans every SurfaceGui under Cash/Time boards (GUIPart, Model, nested layouts).
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

local BOARD_KEYS = { "Cash", "Time" }

local function _lowerName(inst: Instance): string
	return string.lower(inst.Name)
end

local function boardKeyFromName(name: string): string?
	local lower = string.lower(name)
	if string.find(lower, "cash", 1, true) or string.find(lower, "money", 1, true) then
		return "Cash"
	end
	if
		string.find(lower, "time", 1, true)
		or string.find(lower, "playtime", 1, true)
		or string.find(lower, "play time", 1, true)
	then
		return "Time"
	end
	return nil
end

local function boardKeyFromHeaderText(text: string): string?
	local lower = string.lower(text)
	if string.find(lower, "cash", 1, true) or string.find(lower, "money", 1, true) then
		return "Cash"
	end
	if string.find(lower, "time", 1, true) or string.find(lower, "play", 1, true) then
		return "Time"
	end
	return nil
end

function M.findLeaderboardsRoot(): Instance?
	local buildingAssets = Workspace:FindFirstChild("Building Assets")
	if buildingAssets then
		for _, child in buildingAssets:GetChildren() do
			if string.find(child.Name, "Stud UI Pack", 1, true) then
				local modelGui = child:FindFirstChild("ModelGUI") or child:FindFirstChild("ModelGui")
				if modelGui then
					local boards = modelGui:FindFirstChild("LeaderBoards") or modelGui:FindFirstChild("Leaderboards")
					if boards then
						return boards
					end
				end
			end
		end
	end
	for _, desc in Workspace:GetDescendants() do
		if desc.Name == "LeaderBoards" or desc.Name == "Leaderboards" then
			if desc:FindFirstChild("Cash", true) or desc:FindFirstChild("Time", true) then
				return desc
			end
			if desc:FindFirstChild("Most Cash", true) or desc:FindFirstChild("Most Time", true) then
				return desc
			end
		end
	end
	return nil
end

local function findBoardFolder(root: Instance, boardName: string): Instance?
	local aliases = if boardName == "Cash"
		then { "Cash", "Most Cash", "MostCash", "Money" }
		else { "Time", "Most Time", "MostTime", "PlayTime", "Play Time" }
	for _, alias in aliases do
		local found = root:FindFirstChild(alias, true)
		if found then
			return found
		end
	end
	for _, desc in root:GetDescendants() do
		if boardKeyFromName(desc.Name) == boardName then
			return desc
		end
	end
	return nil
end

function M.detectBoardKey(surfaceGui: SurfaceGui): string?
	local node: Instance? = surfaceGui
	while node and node ~= Workspace do
		local key = boardKeyFromName(node.Name)
		if key then
			return key
		end
		node = node.Parent
	end
	for _, desc in surfaceGui:GetDescendants() do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			local key = boardKeyFromHeaderText((desc :: TextLabel).Text)
			if key then
				return key
			end
		end
	end
	return nil
end

local function guiSortY(a: GuiObject, b: GuiObject): boolean
	local ay = a.Position.Y.Scale * 1000 + a.Position.Y.Offset
	local by = b.Position.Y.Scale * 1000 + b.Position.Y.Offset
	if math.abs(ay - by) > 0.5 then
		return ay < by
	end
	local ax = a.Position.X.Scale * 1000 + a.Position.X.Offset
	local bx = b.Position.X.Scale * 1000 + b.Position.X.Offset
	return ax < bx
end

local function rowHasScoreColumns(row: Instance): boolean
	local rankNode = row:FindFirstChild("Rank", true)
	local userNode = row:FindFirstChild("User", true)
		or row:FindFirstChild("Name", true)
		or row:FindFirstChild("Player", true)
	local amountNode = row:FindFirstChild("Amount", true)
		or row:FindFirstChild("Value", true)
		or row:FindFirstChild("Cash", true)
		or row:FindFirstChild("Time", true)
	return rankNode ~= nil and userNode ~= nil and amountNode ~= nil
end

local function findEntriesRoot(surfaceGui: SurfaceGui): Instance
	local preferred = { "Container", "Entries", "List", "Rows", "ScrollingFrame", "Frame" }
	for _, name in preferred do
		for _, desc in surfaceGui:GetDescendants() do
			if desc.Name == name and (desc:IsA("Frame") or desc:IsA("ScrollingFrame")) then
				if desc:FindFirstChild("1", true) or rowHasScoreColumns(desc) then
					return desc
				end
			end
		end
	end
	return surfaceGui
end

local function findRowFrames(surfaceGui: SurfaceGui): { Instance }
	local root = findEntriesRoot(surfaceGui)
	local rows: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	for rank = 1, ROW_COUNT do
		local candidates = {
			root:FindFirstChild(tostring(rank)),
			root:FindFirstChild("Row" .. tostring(rank)),
			root:FindFirstChild("Slot" .. tostring(rank)),
		}
		for _, row in candidates do
			if row and not seen[row] then
				seen[row] = true
				rows[rank] = row
				break
			end
		end
	end

	local filled = 0
	for rank = 1, ROW_COUNT do
		if rows[rank] then
			filled += 1
		end
	end
	if filled >= 3 then
		local ordered: { Instance } = {}
		for rank = 1, ROW_COUNT do
			if rows[rank] then
				table.insert(ordered, rows[rank])
			end
		end
		return ordered
	end

	table.clear(rows)
	for _, desc in root:GetDescendants() do
		if (desc:IsA("Frame") or desc:IsA("ImageLabel")) and rowHasScoreColumns(desc) then
			if not seen[desc] then
				seen[desc] = true
				table.insert(rows, desc)
			end
		end
	end

	if #rows == 0 then
		for _, child in root:GetChildren() do
			if child:IsA("GuiObject") and (child:IsA("Frame") or child:IsA("ImageLabel") or child:IsA("TextLabel")) then
				if not seen[child] then
					seen[child] = true
					table.insert(rows, child)
				end
			end
		end
	end

	table.sort(rows, function(a, b)
		if a:IsA("GuiObject") and b:IsA("GuiObject") then
			return guiSortY(a :: GuiObject, b :: GuiObject)
		end
		return false
	end)

	local trimmed: { Instance } = {}
	for index, row in ipairs(rows) do
		if index > ROW_COUNT then
			break
		end
		table.insert(trimmed, row)
	end
	return trimmed
end

function M.findAllBoardContainers(boardName: string): { Frame }
	local root = M.findLeaderboardsRoot()
	if not root then
		return {}
	end
	local board = findBoardFolder(root, boardName)
	if not board then
		return {}
	end
	local out: { Frame } = {}
	local seen: { [Frame]: boolean } = {}
	for _, desc in board:GetDescendants() do
		if desc:IsA("SurfaceGui") then
			desc.Enabled = true
			pcall(function()
				(desc :: SurfaceGui).MaxDistance = math.max((desc :: SurfaceGui).MaxDistance, 120)
			end)
			local entriesRoot = findEntriesRoot(desc :: SurfaceGui)
			if entriesRoot:IsA("Frame") and not seen[entriesRoot] then
				seen[entriesRoot] = true
				table.insert(out, entriesRoot)
			end
		end
	end
	return out
end

function M.findBoardContainer(boardName: string): Frame?
	local all = M.findAllBoardContainers(boardName)
	return all[1]
end

local function setLabelText(label: TextLabel | TextButton, text: string)
	label.Text = text
end

local function collectRowTextLabels(row: Instance): { TextLabel | TextButton }
	local labels: { TextLabel | TextButton } = {}
	for _, d in row:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			table.insert(labels, d :: TextLabel | TextButton)
		end
	end
	table.sort(labels, function(a, b)
		local ax = a.Position.X.Scale * 1000 + a.Position.X.Offset
		local bx = b.Position.X.Scale * 1000 + b.Position.X.Offset
		if math.abs(ax - bx) > 0.5 then
			return ax < bx
		end
		local ay = a.Position.Y.Scale * 1000 + a.Position.Y.Offset
		local by = b.Position.Y.Scale * 1000 + b.Position.Y.Offset
		return ay < by
	end)
	return labels
end

local function looksLikeRank(text: string): boolean
	return string.match(text, "^#%d+") ~= nil
end

local function looksLikeAmount(text: string): boolean
	if string.find(text, "%$", 1, true) then
		return true
	end
	if string.match(text, "%d+[dhms]") then
		return true
	end
	if string.match(text, "^[%d,%.]+[KMBT]?$") then
		return true
	end
	return false
end

local function looksLikeUser(text: string): boolean
	if text == "" or text == "---" then
		return false
	end
	if string.sub(text, 1, 1) == "@" then
		return true
	end
	return not looksLikeRank(text) and not looksLikeAmount(text)
end

local function formatUserText(displayName: string): string
	if displayName == "" or displayName == "---" then
		return "---"
	end
	if string.sub(displayName, 1, 1) == "@" then
		return displayName
	end
	return "@" .. displayName
end

local function paintRow(row: Instance, entry: RowEntry?, rank: number)
	local rankText = "#" .. tostring(if entry then entry.rank else rank)
	local userText = "---"
	local amountText = "---"
	if entry then
		userText = formatUserText(entry.displayName)
		amountText = entry.amountText
	end

	local byName = {
		Rank = row:FindFirstChild("Rank", true),
		User = row:FindFirstChild("User", true),
		Name = row:FindFirstChild("Name", true),
		Player = row:FindFirstChild("Player", true),
		Amount = row:FindFirstChild("Amount", true),
		Value = row:FindFirstChild("Value", true),
		Cash = row:FindFirstChild("Cash", true),
		Time = row:FindFirstChild("Time", true),
	}

	local function applyNamed(node: Instance?, text: string): boolean
		if not node then
			return false
		end
		if node:IsA("TextLabel") or node:IsA("TextButton") then
			setLabelText(node, text)
			return true
		end
		local nested = node:FindFirstChildWhichIsA("TextLabel", true) or node:FindFirstChildWhichIsA("TextButton", true)
		if nested then
			setLabelText(nested, text)
			return true
		end
		return false
	end

	local paintedRank = applyNamed(byName.Rank, rankText)
	local paintedUser = applyNamed(byName.User, userText)
		or applyNamed(byName.Name, userText)
		or applyNamed(byName.Player, userText)
	local paintedAmount = applyNamed(byName.Amount, amountText)
		or applyNamed(byName.Value, amountText)
		or applyNamed(byName.Cash, amountText)
		or applyNamed(byName.Time, amountText)

	if not (paintedRank and paintedUser and paintedAmount) then
		local labels = collectRowTextLabels(row)
		local rankLabel: (TextLabel | TextButton)? = nil
		local userLabel: (TextLabel | TextButton)? = nil
		local amountLabel: (TextLabel | TextButton)? = nil
		for _, label in labels do
			local t = label.Text
			if not rankLabel and (label.Name == "Rank" or looksLikeRank(t)) then
				rankLabel = label
			elseif not amountLabel and (label.Name == "Amount" or label.Name == "Value" or label.Name == "Cash" or label.Name == "Time" or looksLikeAmount(t)) then
				amountLabel = label
			elseif not userLabel and (label.Name == "User" or label.Name == "Name" or label.Name == "Player" or looksLikeUser(t)) then
				userLabel = label
			end
		end
		if not rankLabel and labels[1] then
			rankLabel = labels[1]
		end
		if not userLabel and labels[2] then
			userLabel = labels[2]
		end
		if not amountLabel and labels[3] then
			amountLabel = labels[3]
		elseif not amountLabel and #labels >= 1 then
			amountLabel = labels[#labels]
		end
		if rankLabel then
			setLabelText(rankLabel, rankText)
		end
		if userLabel then
			setLabelText(userLabel, userText)
		end
		if amountLabel then
			setLabelText(amountLabel, amountText)
		end
	end

	if row:IsA("GuiObject") then
		(row :: GuiObject).Visible = true
	end
end

function M.renderSurfaceGui(surfaceGui: SurfaceGui, entries: { RowEntry }): boolean
	local rows = findRowFrames(surfaceGui)
	if #rows == 0 then
		return false
	end
	surfaceGui.Enabled = true
	for index, row in ipairs(rows) do
		paintRow(row, entries[index], index)
	end
	return true
end

function M.renderBoard(container: Frame?, entries: { RowEntry })
	if not container then
		return false
	end
	local painted = false
	local surfaceGui = container:FindFirstAncestorWhichIsA("SurfaceGui")
	if surfaceGui and surfaceGui:IsA("SurfaceGui") then
		return M.renderSurfaceGui(surfaceGui, entries)
	end
	for rank = 1, ROW_COUNT do
		local row = container:FindFirstChild(tostring(rank))
			or container:FindFirstChild("Row" .. tostring(rank))
			or container:FindFirstChild("Slot" .. tostring(rank))
		if row then
			paintRow(row, entries[rank], rank)
			painted = true
		end
	end
	if not painted then
		local index = 0
		for _, child in container:GetChildren() do
			if child:IsA("GuiObject") then
				index += 1
				if index > ROW_COUNT then
					break
				end
				paintRow(child, entries[index], index)
				painted = true
			end
		end
	end
	return painted
end

function M.renderBoardByName(boardName: string, entries: { RowEntry }): boolean
	local any = false
	for _, container in M.findAllBoardContainers(boardName) do
		if M.renderBoard(container, entries) then
			any = true
		end
	end
	for _, desc in Workspace:GetDescendants() do
		if desc:IsA("SurfaceGui") then
			local key = M.detectBoardKey(desc :: SurfaceGui)
			if key == boardName then
				if M.renderSurfaceGui(desc :: SurfaceGui, entries) then
					any = true
				end
			end
		end
	end
	return any
end

function M.renderAllBoards(entriesByBoard: { [string]: { RowEntry } }): boolean
	local any = false
	for _, boardName in BOARD_KEYS do
		local entries = entriesByBoard[boardName]
		if entries and M.renderBoardByName(boardName, entries) then
			any = true
		end
	end
	return any
end

return M
