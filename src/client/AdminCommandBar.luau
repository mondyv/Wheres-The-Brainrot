-- [ACTIVE] AdminCommandBar
-- Command palette with live autocomplete, Tab fill, arrow navigation, and command history.
-- Studio: press ; (F5 is the Play shortcut). Live game: F5 or ;

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local M = {}

local ACTION_NAME = "ToggleAdminCommandBar"
local AUTOCOMPLETE_ACTION_NAME = "AdminCommandBarAutocomplete"
local COMMAND_REMOTE_NAME = "AdminCommand"
local CATALOG_REMOTE_NAME = "AdminAutocomplete"
local BIND_PRIORITY = Enum.ContextActionPriority.High.Value + 1
local AUTOCOMPLETE_PRIORITY = 10000

local TOGGLE_KEYS = {
	Enum.KeyCode.F5,
	Enum.KeyCode.Semicolon,
}

local MAX_SUGGESTION_ROWS = 8
local ROW_HEIGHT = 30
local ROOT_WIDTH = 600
local BASE_HEIGHT = 92
local MAX_HISTORY = 25

local COLORS = {
	hoverBg = Color3.fromRGB(90, 255, 140),
	hoverBgTransparency = 0.82,
	hoverStroke = Color3.fromRGB(90, 255, 140),
	hoverStrokeTransparency = 0.12,
	idleBg = Color3.fromRGB(22, 28, 36),
	idleBgTransparency = 0.38,
	idleStroke = Color3.fromRGB(70, 80, 96),
	idleStrokeTransparency = 0.62,
	selectedBg = Color3.fromRGB(70, 200, 120),
	selectedBgTransparency = 0.78,
}

local OPEN_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local gui: ScreenGui? = nil
local rootFrame: Frame? = nil
local rootScale: UIScale? = nil
local inputBox: TextBox? = nil
local statusLabel: TextLabel? = nil
local suggestionPanel: Frame? = nil
local suggestionScrollTrack: Frame? = nil
local suggestionScrollThumb: Frame? = nil
local suggestionRows: {{
	button: TextButton,
	stroke: UIStroke,
	cmdLabel: TextLabel,
	hintLabel: TextLabel,
}} = {}
local commandRF: RemoteFunction? = nil
local catalogRF: RemoteFunction? = nil
local initialized = false
local closeToken = 0
local selectedSuggestionIndex = 1
local hoveredSuggestionIndex = 0
local scrollOffset = 0
local currentMatches: { { fill: string, hint: string } } = {}
local commandHistory: { string } = {}
local historyIndex = 0

local catalog = {
	players = { "me", "all" } :: { string },
	brainrots = {} :: { string },
	luckyBlocks = { "star rainbow", "Starter Lucky Block", "Mythic Lucky Block", "Godly Luckyblock", "Secret Lucky Block" } :: { string },
	mutations = { "normal", "golden", "diamond", "lava", "galaxy", "rainbow" } :: { string },
}

local COMMAND_ALIASES: { [string]: string } = {
	addinv = "addinventory",
	give = "addinventory",
	reset = "resetdata",
	givelucky = "addluckyblock",
	giveblock = "addluckyblock",
	globalnotifs = "globalnotif",
	servernotifs = "servernotif",
}

local COMMAND_HINTS: { [string]: string } = {
	help = "List every command",
	addinventory = "Grant a brainrot to inventory",
	addcash = "Add cash to a player",
	addluckyblock = "Grant a lucky block tool",
	resetdata = "Wipe saved player data",
	rebirth = "Force rebirth (skip requirements)",
	spawnglobal = "Force a global rarity bush spawn",
	servernotif = "Top notification on this server",
	globalnotif = "Top notification on all servers",
}

local refreshSuggestions: () -> ()

local function getRemote(name: string): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(name)
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function getCommandRemote(): RemoteFunction?
	if commandRF and commandRF.Parent then
		return commandRF
	end
	commandRF = getRemote(COMMAND_REMOTE_NAME)
	return commandRF
end

local function fetchCatalog()
	local rf = catalogRF or getRemote(CATALOG_REMOTE_NAME)
	catalogRF = rf
	if not rf then
		return
	end
	local ok, data = pcall(function()
		return rf:InvokeServer()
	end)
	if not ok then
		warn("[AdminCommandBar] catalog fetch failed:", data)
		return
	end
	if typeof(data) ~= "table" then
		return
	end
	if typeof(data.players) == "table" then
		catalog.players = data.players
	end
	if typeof(data.brainrots) == "table" then
		catalog.brainrots = data.brainrots
	end
	if typeof(data.luckyBlocks) == "table" then
		catalog.luckyBlocks = data.luckyBlocks
	end
	if typeof(data.mutations) == "table" then
		catalog.mutations = data.mutations
	end
end

local function setStatus(text: string, ok: boolean?)
	local label = statusLabel
	if not label then
		return
	end
	label.Text = text
	if ok == nil then
		label.TextColor3 = Color3.fromRGB(185, 195, 210)
	elseif ok then
		label.TextColor3 = Color3.fromRGB(90, 255, 145)
	else
		label.TextColor3 = Color3.fromRGB(255, 100, 100)
	end
end

local function quoteIfNeeded(value: string): string
	if string.find(value, "[%s\"]") then
		return '"' .. value .. '"'
	end
	return value
end

local function startsWith(haystack: string, needle: string): boolean
	if needle == "" then
		return true
	end
	return string.sub(string.lower(haystack), 1, #needle) == string.lower(needle)
end

local function filterByPrefix(options: { string }, partial: string): { string }
	if partial == "" then
		return options
	end
	local out: { string } = {}
	for _, option in options do
		if startsWith(option, partial) then
			table.insert(out, option)
		end
	end
	return out
end

local function parseTokens(text: string): ({ string }, string, boolean)
	local tokens: { string } = {}
	local partial = ""
	local endsWithSpace = false
	local i = 1
	local len = #text
	while i <= len do
		local ch = string.sub(text, i, i)
		if ch == " " or ch == "\t" then
			endsWithSpace = true
			partial = ""
			i += 1
		elseif ch == '"' then
			endsWithSpace = false
			local j = i + 1
			while j <= len and string.sub(text, j, j) ~= '"' do
				j += 1
			end
			table.insert(tokens, string.sub(text, i + 1, j - 1))
			i = j + 1
			if i > len then
				endsWithSpace = true
			end
		else
			endsWithSpace = false
			local j = i
			while j <= len do
				local cj = string.sub(text, j, j)
				if cj == " " or cj == "\t" then
					break
				end
				j += 1
			end
			local token = string.sub(text, i, j - 1)
			table.insert(tokens, token)
			partial = token
			i = j
		end
	end
	if endsWithSpace then
		partial = ""
	end
	return tokens, partial, endsWithSpace
end

local function joinPrefix(tokens: { string }, count: number): string
	local parts: { string } = {}
	for idx = 1, math.min(count, #tokens) do
		table.insert(parts, quoteIfNeeded(tokens[idx]))
	end
	if #parts == 0 then
		return ""
	end
	return table.concat(parts, " ") .. " "
end

local function resolveCommandName(raw: string): string
	local lower = string.lower(raw)
	return COMMAND_ALIASES[lower] or lower
end

local function pushSuggestion(out: { { fill: string, hint: string } }, fill: string, hint: string)
	if #out >= 200 then
		return
	end
	table.insert(out, { fill = fill, hint = hint })
end

local function baseCommandExamples(): { { fill: string, hint: string } }
	return {
		{ fill = "help", hint = COMMAND_HINTS.help },
		{ fill = "addinventory me NoobiniPizzanini", hint = "Give brainrot (equipped)" },
		{ fill = "addinventory me NoobiniPizzanini 3 golden 5", hint = "Count, mutation, level" },
		{ fill = "addcash me 1000000", hint = COMMAND_HINTS.addcash },
		{ fill = "addluckyblock me \"star rainbow\"", hint = COMMAND_HINTS.addluckyblock },
		{ fill = "resetdata me", hint = COMMAND_HINTS.resetdata },
		{ fill = "rebirth me", hint = COMMAND_HINTS.rebirth },
		{ fill = "spawnglobal mythic", hint = COMMAND_HINTS.spawnglobal },
		{ fill = "servernotif Event starting now!", hint = COMMAND_HINTS.servernotif },
		{ fill = "globalnotif Double luck weekend!", hint = COMMAND_HINTS.globalnotif },
	}
end

local function buildSuggestions(text: string): { { fill: string, hint: string } }
	local trimmed = (string.gsub(text, "^%s+", ""))
	if trimmed == "" then
		return baseCommandExamples()
	end

	local lower = string.lower(trimmed)
	local out: { { fill: string, hint: string } } = {}

	for _, example in baseCommandExamples() do
		if startsWith(example.fill, trimmed) or startsWith(example.fill, lower) then
			pushSuggestion(out, example.fill, example.hint)
		end
	end

	local tokens, partial, endsWithSpace = parseTokens(trimmed)
	if #tokens == 0 then
		return out
	end

	local cmdName = resolveCommandName(tokens[1])
	local argIndex = if endsWithSpace then #tokens else #tokens - 1
	if argIndex < 1 then
		argIndex = 1
	end

	if #tokens == 1 and not endsWithSpace then
		for alias, canonical in COMMAND_ALIASES do
			if startsWith(alias, partial) and not startsWith(canonical, partial) then
				pushSuggestion(out, alias, COMMAND_HINTS[canonical] or canonical)
			end
		end
		for name, hint in COMMAND_HINTS do
			if startsWith(name, partial) then
				pushSuggestion(out, name, hint)
			end
		end
	end

	if cmdName == "addinventory" or cmdName == "addcash" or cmdName == "addluckyblock" or cmdName == "resetdata" or cmdName == "rebirth" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, playerName in filterByPrefix(catalog.players, partial) do
				pushSuggestion(out, prefix .. playerName, "player target")
			end
		end
	end

	if cmdName == "addinventory" then
		if argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			for _, brainrotName in filterByPrefix(catalog.brainrots, partial) do
				pushSuggestion(out, prefix .. quoteIfNeeded(brainrotName), "brainrot")
			end
		elseif argIndex == 3 then
			local prefix = joinPrefix(tokens, #tokens - 1)
			for _, mutation in filterByPrefix(catalog.mutations, partial) do
				pushSuggestion(out, prefix .. mutation, "mutation")
			end
		end
	elseif cmdName == "addluckyblock" then
		if argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			for _, blockName in filterByPrefix(catalog.luckyBlocks, partial) do
				pushSuggestion(out, prefix .. quoteIfNeeded(blockName), "lucky block")
			end
		end
	elseif cmdName == "spawnglobal" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, tier in { "mythic", "mythical", "legendary", "godly", "secret" } do
				if startsWith(tier, partial) then
					pushSuggestion(out, prefix .. tier, "global rarity spawn")
				end
			end
		end
	end

	if #out == 0 then
		for _, example in baseCommandExamples() do
			pushSuggestion(out, example.fill, example.hint)
		end
	end

	local deduped: { { fill: string, hint: string } } = {}
	local seen: { [string]: boolean } = {}
	for _, item in out do
		if not seen[item.fill] then
			seen[item.fill] = true
			table.insert(deduped, item)
		end
	end
	return deduped
end

local function ensureSelectionVisible()
	local total = #currentMatches
	if total == 0 then
		scrollOffset = 0
		selectedSuggestionIndex = 1
		return
	end
	selectedSuggestionIndex = math.clamp(selectedSuggestionIndex, 1, total)
	if selectedSuggestionIndex < scrollOffset + 1 then
		scrollOffset = selectedSuggestionIndex - 1
	elseif selectedSuggestionIndex > scrollOffset + MAX_SUGGESTION_ROWS then
		scrollOffset = selectedSuggestionIndex - MAX_SUGGESTION_ROWS
	end
	local maxOffset = math.max(0, total - MAX_SUGGESTION_ROWS)
	scrollOffset = math.clamp(scrollOffset, 0, maxOffset)
end

local function updateSuggestionStatus()
	local total = #currentMatches
	if total == 0 then
		return
	end
	local scrollHint = ""
	if total > MAX_SUGGESTION_ROWS then
		scrollHint = string.format(" · scroll %d-%d of %d", scrollOffset + 1, math.min(scrollOffset + MAX_SUGGESTION_ROWS, total), total)
	end
	setStatus(
		string.format("%d/%d selected · Tab fill · ↑↓ move%s · Ctrl+↑↓ history", selectedSuggestionIndex, total, scrollHint),
		nil
	)
end

local function styleSuggestionRow(visibleIndex: number)
	local row = suggestionRows[visibleIndex]
	if not row then
		return
	end
	local matchIndex = scrollOffset + visibleIndex
	local hovered = matchIndex == hoveredSuggestionIndex
	local selected = matchIndex == selectedSuggestionIndex
	local active = hovered or selected
	row.stroke.Color = if active then COLORS.hoverStroke else COLORS.idleStroke
	row.stroke.Transparency = if active then COLORS.hoverStrokeTransparency else COLORS.idleStrokeTransparency
	row.button.BackgroundColor3 = if selected then COLORS.selectedBg elseif hovered then COLORS.hoverBg else COLORS.idleBg
	row.button.BackgroundTransparency = if selected
		then COLORS.selectedBgTransparency
		elseif hovered then COLORS.hoverBgTransparency
		else COLORS.idleBgTransparency
end

local function isPointerOverAdminGui(): boolean
	local root = rootFrame
	if not root or not root.Visible then
		return false
	end
	local mouse = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	local point = Vector2.new(mouse.X, mouse.Y - inset.Y)
	local pos = root.AbsolutePosition
	local size = root.AbsoluteSize
	return point.X >= pos.X and point.X <= pos.X + size.X and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

local function updateScrollbar(total: number, visibleCount: number)
	local track = suggestionScrollTrack
	local thumb = suggestionScrollThumb
	if not track or not thumb then
		return
	end
	if total <= MAX_SUGGESTION_ROWS or visibleCount == 0 then
		track.Visible = false
		return
	end
	track.Visible = true
	local trackHeight = visibleCount * ROW_HEIGHT
	local thumbHeight = math.max(18, trackHeight * (MAX_SUGGESTION_ROWS / total))
	local maxOffset = math.max(1, total - MAX_SUGGESTION_ROWS)
	local scrollRatio = scrollOffset / maxOffset
	local travel = math.max(0, trackHeight - thumbHeight)
	thumb.Size = UDim2.new(1, -4, 0, thumbHeight)
	thumb.Position = UDim2.fromOffset(2, scrollRatio * travel)
end

local function updateRootHeight(visibleRows: number)
	local root = rootFrame
	local panel = suggestionPanel
	if not root or not panel then
		return
	end
	local panelHeight = if visibleRows > 0 then visibleRows * ROW_HEIGHT + 8 else 0
	panel.Size = UDim2.new(1, -28, 0, panelHeight)
	panel.Visible = panelHeight > 0
	root.Size = UDim2.fromOffset(ROOT_WIDTH, BASE_HEIGHT + panelHeight)
	local status = statusLabel
	if status then
		status.Position = UDim2.fromOffset(16, BASE_HEIGHT - 28 + panelHeight)
	end
end

refreshSuggestions = function()
	local box = inputBox
	local panel = suggestionPanel
	if not box or not panel then
		return
	end

	currentMatches = buildSuggestions(box.Text)
	ensureSelectionVisible()

	local visibleCount = math.min(#currentMatches, MAX_SUGGESTION_ROWS)
	for visibleIndex, row in suggestionRows do
		local matchIndex = scrollOffset + visibleIndex
		local match = currentMatches[matchIndex]
		if match and visibleIndex <= visibleCount then
			row.button.Visible = true
			row.cmdLabel.Text = match.fill
			row.hintLabel.Text = match.hint
			styleSuggestionRow(visibleIndex)
		else
			row.button.Visible = false
		end
	end
	updateRootHeight(if #currentMatches > 0 then visibleCount else 0)
	updateScrollbar(#currentMatches, visibleCount)
	if gui and gui.Enabled and #currentMatches > 0 then
		updateSuggestionStatus()
	end
end

local function applySelectedSuggestion()
	local box = inputBox
	if not box then
		return
	end
	local match = currentMatches[selectedSuggestionIndex]
	if not match then
		return
	end
	box.Text = match.fill
	historyIndex = 0
	scrollOffset = 0
	selectedSuggestionIndex = 1
	hoveredSuggestionIndex = 0
	refreshSuggestions()
	box:CaptureFocus()
end

local function cycleSuggestion(delta: number)
	if #currentMatches == 0 then
		return
	end
	selectedSuggestionIndex = math.clamp(selectedSuggestionIndex + delta, 1, #currentMatches)
	hoveredSuggestionIndex = 0
	ensureSelectionVisible()
	refreshSuggestions()
end

local function pageSuggestions(deltaPages: number)
	if #currentMatches == 0 then
		return
	end
	local jump = MAX_SUGGESTION_ROWS * deltaPages
	selectedSuggestionIndex = math.clamp(selectedSuggestionIndex + jump, 1, #currentMatches)
	hoveredSuggestionIndex = 0
	ensureSelectionVisible()
	refreshSuggestions()
end

local function pushHistory(command: string)
	local trimmed = (string.gsub(command, "^%s+", "")):gsub("%s+$", "")
	if trimmed == "" then
		return
	end
	if commandHistory[1] == trimmed then
		return
	end
	table.insert(commandHistory, 1, trimmed)
	while #commandHistory > MAX_HISTORY do
		table.remove(commandHistory)
	end
	historyIndex = 0
end

local function cycleHistory(delta: number)
	local box = inputBox
	if not box or #commandHistory == 0 then
		return
	end
	if box.Text ~= "" and historyIndex == 0 and delta < 0 then
		return
	end
	historyIndex = math.clamp(historyIndex + delta, 0, #commandHistory)
	if historyIndex == 0 then
		box.Text = ""
	else
		box.Text = commandHistory[historyIndex]
	end
	refreshSuggestions()
end

local function animateOpen(open: boolean)
	local root = rootFrame
	local scale = rootScale
	if not root or not scale then
		return
	end
	if open then
		scale.Scale = 0.94
		root.Position = UDim2.fromScale(0.5, 0.06)
		TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
		TweenService:Create(root, OPEN_TWEEN, { Position = UDim2.fromScale(0.5, 0.08) }):Play()
	else
		scale.Scale = 1
	end
end

local function setOpen(open: boolean)
	if not gui or not inputBox then
		return
	end
	if open then
		closeToken += 1
		gui.Enabled = true
		inputBox.Text = ""
		selectedSuggestionIndex = 1
		hoveredSuggestionIndex = 0
		scrollOffset = 0
		historyIndex = 0
		setStatus("Tab fill · ↑↓ navigate · PgUp/PgDn page · Enter run", nil)
		animateOpen(true)
		task.defer(fetchCatalog)
		refreshSuggestions()
		inputBox:CaptureFocus()
	else
		closeToken += 1
		local token = closeToken
		inputBox:ReleaseFocus()
		animateOpen(false)
		task.delay(0.12, function()
			if token == closeToken and gui then
				gui.Enabled = false
			end
		end)
	end
end

local function submitCommand()
	local box = inputBox
	if not box then
		return
	end
	local command = box.Text
	if command == "" then
		setOpen(false)
		return
	end

	local rf = getCommandRemote()
	if not rf then
		setStatus("Admin command service is not ready.", false)
		return
	end

	setStatus("Running...", nil)
	local ok, response = pcall(function()
		return rf:InvokeServer(command)
	end)
	if not ok then
		warn("[AdminCommandBar] command invoke failed:", response)
		setStatus("Command failed. Check client output.", false)
		return
	end

	pushHistory(command)
	if typeof(response) == "table" then
		setStatus(tostring(response.message or ""), response.ok == true)
	else
		setStatus(tostring(response), nil)
	end
	box.Text = ""
	selectedSuggestionIndex = 1
	refreshSuggestions()
	box:CaptureFocus()
end

local function createSuggestionRow(parent: Frame, index: number)
	local rowButton = Instance.new("TextButton")
	rowButton.Name = "Row" .. index
	rowButton.AutoButtonColor = false
	rowButton.Text = ""
	rowButton.BackgroundColor3 = COLORS.idleBg
	rowButton.BackgroundTransparency = COLORS.idleBgTransparency
	rowButton.BorderSizePixel = 0
	rowButton.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
	rowButton.Position = UDim2.fromOffset(0, (index - 1) * ROW_HEIGHT + 2)
	rowButton.ZIndex = 2

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = rowButton

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.idleStroke
	stroke.Transparency = COLORS.idleStrokeTransparency
	stroke.Thickness = 1.25
	stroke.Parent = rowButton

	local cmdLabel = Instance.new("TextLabel")
	cmdLabel.Name = "Command"
	cmdLabel.BackgroundTransparency = 1
	cmdLabel.Font = Enum.Font.GothamSemibold
	cmdLabel.TextSize = 14
	cmdLabel.TextColor3 = Color3.fromRGB(235, 242, 255)
	cmdLabel.TextXAlignment = Enum.TextXAlignment.Left
	cmdLabel.TextTruncate = Enum.TextTruncate.AtEnd
	cmdLabel.Position = UDim2.fromOffset(10, 0)
	cmdLabel.Size = UDim2.new(0.58, -10, 1, 0)
	cmdLabel.ZIndex = 3
	cmdLabel.Parent = rowButton

	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "Hint"
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = Enum.Font.Gotham
	hintLabel.TextSize = 12
	hintLabel.TextColor3 = Color3.fromRGB(140, 155, 175)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Right
	hintLabel.TextTruncate = Enum.TextTruncate.AtEnd
	hintLabel.Position = UDim2.new(0.58, 0, 0, 0)
	hintLabel.Size = UDim2.new(0.42, -8, 1, 0)
	hintLabel.ZIndex = 3
	hintLabel.Parent = rowButton

	rowButton.MouseEnter:Connect(function()
		hoveredSuggestionIndex = scrollOffset + index
		selectedSuggestionIndex = hoveredSuggestionIndex
		refreshSuggestions()
	end)

	rowButton.MouseLeave:Connect(function()
		if hoveredSuggestionIndex == scrollOffset + index then
			hoveredSuggestionIndex = 0
		end
		refreshSuggestions()
	end)

	rowButton.MouseButton1Click:Connect(function()
		selectedSuggestionIndex = scrollOffset + index
		applySelectedSuggestion()
	end)

	rowButton.Parent = parent
	table.insert(suggestionRows, {
		button = rowButton,
		stroke = stroke,
		cmdLabel = cmdLabel,
		hintLabel = hintLabel,
	})
end

local function buildGui(parent: PlayerGui)
	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminCommandBar"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 9999
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.fromScale(0.5, 0.08)
	root.Size = UDim2.fromOffset(ROOT_WIDTH, BASE_HEIGHT)
	root.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	root.BackgroundTransparency = 0.08
	root.BorderSizePixel = 0

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = root

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 12)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Color = Color3.fromRGB(90, 255, 140)
	rootStroke.Transparency = 0.25
	rootStroke.Thickness = 1.5
	rootStroke.Parent = root

	local box = Instance.new("TextBox")
	box.Name = "CommandInput"
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.GothamSemibold
	box.PlaceholderText = "admin command..."
	box.Text = ""
	box.TextColor3 = Color3.fromRGB(245, 248, 255)
	box.PlaceholderColor3 = Color3.fromRGB(130, 140, 155)
	box.TextSize = 18
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(14, 12)
	box.Size = UDim2.new(1, -28, 0, 36)

	local boxPadding = Instance.new("UIPadding")
	boxPadding.PaddingLeft = UDim.new(0, 10)
	boxPadding.PaddingRight = UDim.new(0, 10)
	boxPadding.Parent = box

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 8)
	boxCorner.Parent = box

	local panel = Instance.new("Frame")
	panel.Name = "Suggestions"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Position = UDim2.fromOffset(14, 54)
	panel.Size = UDim2.new(1, -28, 0, 0)
	panel.Visible = false
	panel.ZIndex = 2

	for index = 1, MAX_SUGGESTION_ROWS do
		createSuggestionRow(panel, index)
	end

	local scrollTrack = Instance.new("Frame")
	scrollTrack.Name = "ScrollTrack"
	scrollTrack.BackgroundColor3 = Color3.fromRGB(32, 38, 48)
	scrollTrack.BackgroundTransparency = 0.35
	scrollTrack.BorderSizePixel = 0
	scrollTrack.AnchorPoint = Vector2.new(1, 0)
	scrollTrack.Position = UDim2.new(1, -2, 0, 2)
	scrollTrack.Size = UDim2.new(0, 8, 1, -4)
	scrollTrack.Visible = false
	scrollTrack.ZIndex = 3
	scrollTrack.Parent = panel

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = scrollTrack

	local scrollThumb = Instance.new("Frame")
	scrollThumb.Name = "Thumb"
	scrollThumb.BackgroundColor3 = Color3.fromRGB(90, 255, 140)
	scrollThumb.BackgroundTransparency = 0.15
	scrollThumb.BorderSizePixel = 0
	scrollThumb.Position = UDim2.fromOffset(2, 0)
	scrollThumb.Size = UDim2.new(1, -4, 0, 24)
	scrollThumb.ZIndex = 4
	scrollThumb.Parent = scrollTrack

	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(1, 0)
	thumbCorner.Parent = scrollThumb

	local label = Instance.new("TextLabel")
	label.Name = "Status"
	label.Font = Enum.Font.Gotham
	label.Text = "Tab fill · ↑↓ navigate · Enter run"
	label.TextColor3 = Color3.fromRGB(185, 195, 210)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(16, BASE_HEIGHT - 28)
	label.Size = UDim2.new(1, -32, 0, 20)

	local tabGuard = false
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if tabGuard then
			return
		end
		if string.find(box.Text, "\t", 1, true) then
			tabGuard = true
			box.Text = string.gsub(box.Text, "\t", "")
			tabGuard = false
			applySelectedSuggestion()
			return
		end
		refreshSuggestions()
	end)

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submitCommand()
		end
	end)

	root.Parent = screen
	box.Parent = root
	panel.Parent = root
	label.Parent = root
	screen.Parent = parent

	gui = screen
	rootFrame = root
	rootScale = scale
	inputBox = box
	statusLabel = label
	suggestionPanel = panel
	suggestionScrollTrack = scrollTrack
	suggestionScrollThumb = scrollThumb
end

local function isToggleKey(keyCode: Enum.KeyCode): boolean
	for _, key in TOGGLE_KEYS do
		if key == keyCode then
			return true
		end
	end
	return false
end

local function isAdminInputFocused(): boolean
	local box = inputBox
	return box ~= nil and UserInputService:GetFocusedTextBox() == box
end

function M.init()
	if initialized then
		return
	end
	initialized = true

	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[AdminCommandBar] PlayerGui missing; admin bar not wired")
		return
	end
	buildGui(playerGui)

	local lastToggleAt = 0
	local function onToggleAdmin()
		local now = os.clock()
		if now - lastToggleAt < 0.15 then
			return
		end
		lastToggleAt = now
		if isAdminInputFocused() then
			return
		end
		setOpen(not (gui and gui.Enabled))
	end

	ContextActionService:UnbindAction(ACTION_NAME)
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		function(_name, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return Enum.ContextActionResult.Pass
			end
			if not isToggleKey(input.KeyCode) then
				return Enum.ContextActionResult.Pass
			end
			onToggleAdmin()
			return Enum.ContextActionResult.Sink
		end,
		false,
		BIND_PRIORITY,
		table.unpack(TOGGLE_KEYS)
	)

	ContextActionService:UnbindAction(AUTOCOMPLETE_ACTION_NAME)
	ContextActionService:BindActionAtPriority(
		AUTOCOMPLETE_ACTION_NAME,
		function(_name, state, input)
			if not isAdminInputFocused() or not (gui and gui.Enabled) then
				return Enum.ContextActionResult.Pass
			end
			if state ~= Enum.UserInputState.Begin or input.UserInputType ~= Enum.UserInputType.Keyboard then
				return Enum.ContextActionResult.Pass
			end
			if input.KeyCode == Enum.KeyCode.Tab then
				applySelectedSuggestion()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		AUTOCOMPLETE_PRIORITY,
		Enum.KeyCode.Tab
	)

	UserInputService.InputChanged:Connect(function(input, _gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		if not gui or not gui.Enabled then
			return
		end
		if not isAdminInputFocused() and not isPointerOverAdminGui() then
			return
		end
		if #currentMatches == 0 then
			return
		end
		cycleSuggestion(if input.Position.Z > 0 then -1 else 1)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if isToggleKey(input.KeyCode) and not gameProcessed then
			onToggleAdmin()
		elseif input.KeyCode == Enum.KeyCode.Escape and gui and gui.Enabled then
			setOpen(false)
		elseif isAdminInputFocused() and gui and gui.Enabled then
			if input.KeyCode == Enum.KeyCode.Tab then
				applySelectedSuggestion()
			elseif input.KeyCode == Enum.KeyCode.Up then
				if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
					cycleHistory(-1)
				else
					cycleSuggestion(-1)
				end
			elseif input.KeyCode == Enum.KeyCode.Down then
				if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
					cycleHistory(1)
				else
					cycleSuggestion(1)
				end
			elseif input.KeyCode == Enum.KeyCode.PageUp then
				pageSuggestions(-1)
			elseif input.KeyCode == Enum.KeyCode.PageDown then
				pageSuggestions(1)
			elseif
				input.KeyCode == Enum.KeyCode.L
				and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl))
			then
				local box = inputBox
				if box then
					box.Text = ""
				end
				selectedSuggestionIndex = 1
				scrollOffset = 0
				refreshSuggestions()
			end
		end
	end)

	task.defer(fetchCatalog)

	local studioHint = if RunService:IsStudio() then " — Studio: press ;" else ""
	warn("[AdminCommandBar] Ready — F5 or ; to open" .. studioHint)
end

return M
