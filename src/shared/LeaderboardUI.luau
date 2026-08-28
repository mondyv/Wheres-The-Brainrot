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

local ROW_COUNT = 100
local AUTHORED_SLOT_MAX = 10

local BOARD_KEYS = { "Cash", "Time" }
local SPAWN_FOLDER_NAMES = { "Spawn And Bases", "Spawn and Bases", "SpawnAndBases" }

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
	local map = Workspace:FindFirstChild("Map")
	if map then
		for _, spawnName in SPAWN_FOLDER_NAMES do
			local spawn = map:FindFirstChild(spawnName)
			if spawn then
				local boards = spawn:FindFirstChild("Leaderboards") or spawn:FindFirstChild("LeaderBoards")
				if boards then
					return boards
				end
			end
		end
		local direct = map:FindFirstChild("Leaderboards") or map:FindFirstChild("LeaderBoards")
		if direct then
			return direct
		end
	end
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
	return nil
end

local function findBoardFolder(root: Instance, boardName: string): Instance?
	-- Prefer TimeLeaderboard / CashLeaderboard children. Never recursive-search "Cash"
	-- or "Time" — those names live on row labels and would bind the wrong board.
	local unlabeled: { Instance } = {}
	local cashChild: Instance? = nil
	for _, child in root:GetChildren() do
		local key = boardKeyFromName(child.Name)
		if key == boardName then
			return child
		elseif key == "Cash" then
			cashChild = child
		elseif key == nil then
			table.insert(unlabeled, child)
		end
	end
	-- Cash board is named; the other sibling is the time board.
	if boardName == "Time" and cashChild and #unlabeled == 1 then
		return unlabeled[1]
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
	local headerNames = { "Header", "Title", "BoardTitle", "BoardName" }
	for _, name in headerNames do
		local header = surfaceGui:FindFirstChild(name, true)
		if header and (header:IsA("TextLabel") or header:IsA("TextButton")) then
			local key = boardKeyFromHeaderText((header :: TextLabel).Text)
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

local function numberedSlotCount(root: Instance): number
	local n = 0
	for _, child in root:GetChildren() do
		if child:IsA("GuiObject") and tonumber(child.Name) then
			n += 1
		end
	end
	return n
end

local function findAuthoredContainer(surfaceGui: SurfaceGui): Instance?
	local frame = surfaceGui:FindFirstChild("Frame")
	if frame then
		local container = frame:FindFirstChild("Container")
		if container and numberedSlotCount(container) > 0 then
			return container
		end
		if numberedSlotCount(frame) > 0 then
			return frame
		end
	end
	local container = surfaceGui:FindFirstChild("Container")
	if container and numberedSlotCount(container) > 0 then
		return container
	end
	return nil
end

local function findSurfaceGuiOnBoard(board: Instance): SurfaceGui?
	local guiPart = board:FindFirstChild("GUIPart")
	if guiPart then
		local sg = guiPart:FindFirstChildWhichIsA("SurfaceGui")
		if sg then
			return sg
		end
		local nested = guiPart:FindFirstChildWhichIsA("SurfaceGui", true)
		if nested then
			return nested
		end
	end
	return board:FindFirstChildWhichIsA("SurfaceGui", true)
end

local function cloneAuthoredLayoutIfNeeded(surfaceGui: SurfaceGui)
	if findAuthoredContainer(surfaceGui) then
		return
	end
	local root = M.findLeaderboardsRoot()
	if not root then
		return
	end
	local myKey = M.detectBoardKey(surfaceGui)
	for _, sibling in root:GetChildren() do
		if boardKeyFromName(sibling.Name) == nil or boardKeyFromName(sibling.Name) == myKey then
			continue
		end
		local otherGui = findSurfaceGuiOnBoard(sibling)
		if not otherGui or otherGui == surfaceGui then
			continue
		end
		local srcFrame = otherGui:FindFirstChild("Frame")
		if srcFrame and numberedSlotCount(srcFrame:FindFirstChild("Container") or srcFrame) > 0 then
			srcFrame:Clone().Parent = surfaceGui
			return
		end
	end
end

local function findEntriesRoot(surfaceGui: SurfaceGui): Instance
	cloneAuthoredLayoutIfNeeded(surfaceGui)
	local authored = findAuthoredContainer(surfaceGui)
	if authored then
		return authored
	end
	local scroll = surfaceGui:FindFirstChild("LeaderboardScroll", true)
	if scroll and scroll:IsA("ScrollingFrame") then
		return scroll
	end
	local preferred = { "Container", "Entries", "List", "Rows", "ScrollingFrame", "Frame" }
	for _, name in preferred do
		for _, desc in surfaceGui:GetDescendants() do
			if desc.Name == name and (desc:IsA("Frame") or desc:IsA("ScrollingFrame")) then
				if desc:FindFirstChild("1") or rowHasScoreColumns(desc) then
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

	local slotMax = if numberedSlotCount(root) > 0 then AUTHORED_SLOT_MAX else ROW_COUNT
	for rank = 1, slotMax do
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
	for rank = 1, slotMax do
		if rows[rank] then
			filled += 1
		end
	end
	if filled >= 1 then
		local ordered: { Instance } = {}
		for rank = 1, slotMax do
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
			if child.Name == "SPACE" or child:IsA("UIBase") then
				continue
			end
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
		Username = row:FindFirstChild("Username", true),
		DisplayName = row:FindFirstChild("DisplayName", true),
		Amount = row:FindFirstChild("Amount", true),
		Value = row:FindFirstChild("Value", true),
		Score = row:FindFirstChild("Score", true),
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
		or applyNamed(byName.Username, userText)
		or applyNamed(byName.DisplayName, userText)
	local paintedAmount = applyNamed(byName.Amount, amountText)
		or applyNamed(byName.Value, amountText)
		or applyNamed(byName.Score, amountText)
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

local function ensureScrollableRows(surfaceGui: SurfaceGui): GuiObject?
	surfaceGui.Enabled = true
	surfaceGui.Active = true
	pcall(function()
		surfaceGui.MaxDistance = math.max(surfaceGui.MaxDistance, 180)
	end)
	cloneAuthoredLayoutIfNeeded(surfaceGui)
	local authored = findAuthoredContainer(surfaceGui)
	if authored and authored:IsA("GuiObject") then
		-- Studio already laid out slots 1–10 + SPACE + UIListLayout. Do not wrap or clone 100 rows.
		return authored
	end
	local root = findEntriesRoot(surfaceGui)
	if not (root and root:IsA("GuiObject")) then
		return nil
	end

	local scroll: ScrollingFrame? = nil
	if root:IsA("ScrollingFrame") then
		scroll = root
	elseif root.Parent and root.Parent:IsA("ScrollingFrame") then
		scroll = root.Parent :: ScrollingFrame
	else
		local existing = root:FindFirstChild("LeaderboardScroll")
		if existing and existing:IsA("ScrollingFrame") then
			scroll = existing
		else
			local sf = Instance.new("ScrollingFrame")
			sf.Name = "LeaderboardScroll"
			sf.BackgroundTransparency = 1
			sf.BorderSizePixel = 0
			sf.Size = UDim2.fromScale(1, 1)
			sf.Position = UDim2.fromScale(0, 0)
			sf.ScrollBarThickness = 8
			sf.ScrollingDirection = Enum.ScrollingDirection.Y
			sf.ScrollingEnabled = true
			sf.Active = true
			sf.Selectable = true
			sf.CanvasSize = UDim2.fromOffset(0, 0)
			pcall(function()
				(sf :: any).AutomaticCanvasSize = Enum.AutomaticSize.Y
			end)
			-- Move existing row children into the scroll pane.
			local toMove: { Instance } = {}
			for _, child in root:GetChildren() do
				if child:IsA("GuiObject") then
					local n = child.Name
					if tonumber(n) or string.match(n, "^Row%d+") or string.match(n, "^Slot%d+") then
						table.insert(toMove, child)
					elseif rowHasScoreColumns(child) then
						table.insert(toMove, child)
					end
				end
			end
			sf.Parent = root
			for _, child in toMove do
				child.Parent = sf
			end
			scroll = sf
		end
	end

	if not scroll then
		return root
	end

	scroll.ScrollingEnabled = true
	scroll.Active = true
	scroll.Visible = true
	pcall(function()
		(scroll :: any).AutomaticCanvasSize = Enum.AutomaticSize.Y
	end)

	local list = scroll:FindFirstChildOfClass("UIListLayout")
	if not list then
		list = Instance.new("UIListLayout")
		list.Name = "LeaderboardList"
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 2)
		list.Parent = scroll
	end

	local template = scroll:FindFirstChild("1")
		or scroll:FindFirstChild("Row1")
		or scroll:FindFirstChild("Slot1")
	if not template then
		for _, child in scroll:GetChildren() do
			if child:IsA("GuiObject") and rowHasScoreColumns(child) then
				template = child
				break
			end
		end
	end
	if not template or not template:IsA("GuiObject") then
		return scroll
	end

	local rowH = template.AbsoluteSize.Y
	if rowH < 4 then
		rowH = math.max(template.Size.Y.Offset, 28)
	end

	for rank = 1, ROW_COUNT do
		local name = tostring(rank)
		local row = scroll:FindFirstChild(name)
		if not row then
			row = template:Clone()
			row.Name = name
			row.Parent = scroll
		end
		if row:IsA("GuiObject") then
			row.LayoutOrder = rank
			row.Visible = true
			if row.Size.Y.Offset <= 0 and row.Size.Y.Scale <= 0 then
				row.Size = UDim2.new(1, 0, 0, rowH)
			end
		end
	end

	-- Hide leftover non-numeric template duplicates that would clutter the list.
	for _, child in scroll:GetChildren() do
		if child:IsA("GuiObject") and child ~= list then
			local n = child.Name
			if not tonumber(n) and (string.match(n, "^Row%d+") or string.match(n, "^Slot%d+") or child == template) then
				if child.Name ~= "1" then
					child.Visible = false
				end
			end
		end
	end

	scroll.CanvasSize = UDim2.fromOffset(0, ROW_COUNT * (rowH + 2) + 8)
	return scroll
end

function M.renderSurfaceGui(surfaceGui: SurfaceGui, entries: { RowEntry }): boolean
	ensureScrollableRows(surfaceGui)
	local rows = findRowFrames(surfaceGui)
	if #rows == 0 then
		return false
	end
	surfaceGui.Enabled = true
	surfaceGui.Active = true
	for index, row in ipairs(rows) do
		paintRow(row, entries[index], index)
	end
	-- Hide unused cloned rows past published entry count.
	for index = #entries + 1, #rows do
		local row = rows[index]
		if row and row:IsA("GuiObject") then
			-- Keep slot visible with placeholder via paintRow(nil) for empty ranks.
			paintRow(row, nil, index)
		end
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

local cachedSurfaceGuisByBoard: { [string]: { SurfaceGui } } = {
	Cash = {},
	Time = {},
}
local boardCacheBuiltAt = 0.0
local BOARD_CACHE_TTL = 12

function M.invalidateBoardCache()
	boardCacheBuiltAt = 0
	cachedSurfaceGuisByBoard = { Cash = {}, Time = {} }
end

local function rebuildBoardSurfaceCache()
	cachedSurfaceGuisByBoard = { Cash = {}, Time = {} }
	local root = M.findLeaderboardsRoot()
	if not root then
		boardCacheBuiltAt = os.clock()
		return
	end
	for _, child in root:GetChildren() do
		local folderKey = boardKeyFromName(child.Name)
		if not folderKey then
			if findBoardFolder(root, "Time") == child then
				folderKey = "Time"
			elseif findBoardFolder(root, "Cash") == child then
				folderKey = "Cash"
			end
		end
		for _, desc in child:GetDescendants() do
			if desc:IsA("SurfaceGui") then
				local key = folderKey or M.detectBoardKey(desc :: SurfaceGui)
				if key == "Cash" or key == "Time" then
					table.insert(cachedSurfaceGuisByBoard[key], desc :: SurfaceGui)
				end
			end
		end
	end
	boardCacheBuiltAt = os.clock()
end

function M.renderBoardByName(boardName: string, entries: { RowEntry }): boolean
	local any = false
	if os.clock() - boardCacheBuiltAt > BOARD_CACHE_TTL then
		rebuildBoardSurfaceCache()
	end
	for _, container in M.findAllBoardContainers(boardName) do
		if M.renderBoard(container, entries) then
			any = true
		end
	end
	local guis = cachedSurfaceGuisByBoard[boardName]
	if guis then
		for _, gui in guis do
			if gui.Parent then
				if M.renderSurfaceGui(gui, entries) then
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
