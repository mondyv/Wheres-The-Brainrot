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

local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local M = {}

local ACTION_NAME = "ToggleAdminCommandBar"
local AUTOCOMPLETE_ACTION_NAME = "AdminCommandBarAutocomplete"
local COMMAND_REMOTE_NAME = "AdminCommand"
local CATALOG_REMOTE_NAME = "AdminAutocomplete"
local ADMIN_ALLOWED_ATTR = "AdminPanelAllowed"
local BIND_PRIORITY = Enum.ContextActionPriority.High.Value + 1
local AUTOCOMPLETE_PRIORITY = 10000

local TOGGLE_KEYS = {
	Enum.KeyCode.F5,
	Enum.KeyCode.Semicolon,
}

local MAX_HISTORY = 25
local HEADER_HEIGHT = 44
local INPUT_HEIGHT = 42
local STATUS_HEIGHT = 26
local CONTENT_PAD = 14

-- Desktop defaults; mobile overrides applied in applyLayout().
local MAX_SUGGESTION_ROWS = 8
local ROW_HEIGHT = 34
local ROOT_WIDTH = 620
local BASE_HEIGHT = HEADER_HEIGHT + CONTENT_PAD + INPUT_HEIGHT + 10 + STATUS_HEIGHT
local ROOT_WIDTH_SCALE = 0
local IS_MOBILE_LAYOUT = false

local COLORS = {
	panel = Color3.fromRGB(14, 18, 26),
	panelTop = Color3.fromRGB(22, 30, 42),
	accent = Color3.fromRGB(220, 228, 240),
	accentDim = Color3.fromRGB(140, 150, 165),
	success = Color3.fromRGB(140, 210, 165),
	inputBg = Color3.fromRGB(10, 14, 20),
	hoverBg = Color3.fromRGB(255, 255, 255),
	hoverBgTransparency = 0.9,
	hoverStroke = Color3.fromRGB(48, 58, 72),
	hoverStrokeTransparency = 0.4,
	idleBg = Color3.fromRGB(24, 30, 40),
	idleBgTransparency = 0.35,
	idleStroke = Color3.fromRGB(48, 58, 72),
	idleStrokeTransparency = 0.5,
	selectedBg = Color3.fromRGB(255, 255, 255),
	selectedBgTransparency = 0.88,
	runBtn = Color3.fromRGB(230, 235, 245),
	runBtnHover = Color3.fromRGB(245, 248, 255),
	textPrimary = Color3.fromRGB(245, 250, 255),
	textMuted = Color3.fromRGB(150, 165, 185),
	danger = Color3.fromRGB(255, 95, 110),
	panelStroke = Color3.fromRGB(48, 58, 72),
	rootBgTransparency = 0.42,
}

local OPEN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local gui: ScreenGui? = nil
local backdrop: TextButton? = nil
local rootFrame: Frame? = nil
local rootScale: UIScale? = nil
local inputBox: TextBox? = nil
local _runButton: TextButton? = nil
local _closeButton: TextButton? = nil
local statusLabel: TextLabel? = nil
local suggestionPanel: Frame? = nil
local suggestionScrollTrack: Frame? = nil
local suggestionScrollThumb: Frame? = nil
local titleLabel: TextLabel? = nil
local suggestionRows: {
	{
		button: TextButton,
		stroke: UIStroke,
		cmdLabel: TextLabel,
		hintLabel: TextLabel,
	}
} =
	{}
local commandRF: RemoteFunction? = nil
local catalogRF: RemoteFunction? = nil
local initialized = false
local closeToken = 0
local backdropGuardUntil = 0
local selectedSuggestionIndex = 1
local hoveredSuggestionIndex = 0
local scrollOffset = 0
local currentMatches: { { fill: string, hint: string } } = {}
local commandHistory: { string } = {}
local historyIndex = 0
local mobileAdminFrame: GuiObject? = nil
local mobileAdminButtonHost: GuiObject? = nil
local mobileAdminWired = false
local suggestionScrollTouch: InputObject? = nil
local suggestionScrollStartY = 0
local suggestionScrollStartOffset = 0
local suggestionScrollDragged = false
local suppressSuggestionRowTap = false
local SUGGESTION_SCROLL_DRAG_PX = 10

local catalog = {
	players = { "me", "all" } :: { string },
	brainrots = {} :: { string },
	luckyBlocks = {
		"star rainbow",
		"Starter Lucky Block",
		"Mythic Lucky Block",
		"Godly Luckyblock",
		"Secret Lucky Block",
	} :: { string },
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
	shutdown = "servershutdown",
	servershut = "servershutdown",
	sluck = "serverluck",
	gluck = "globalluck",
	spawnglobal = "serverspawn",
	land = "tpland",
	teleportland = "tpland",
	gotoland = "tpland",
	tpl = "tpland",
	teleport = "tp",
	["goto"] = "tp",
}

local COMMAND_HINTS: { [string]: string } = {
	help = "List every command",
	addinventory = "Grant a brainrot to inventory",
	addcash = "Add cash to a player",
	addluckyblock = "Grant a lucky block tool",
	resetdata = "Wipe saved player data",
	rebirth = "Force rebirth (skip requirements)",
	tp = "Teleport to a player, or teleport players to someone",
	tpland = "Teleport players to a land revive/spawn pad",
	serverspawn = "Force a rarity spawn on this server",
	globalspawn = "Force a rarity spawn on every server",
	servernotif = "Top notification on this server",
	globalnotif = "Top notification on all servers",
	servershutdown = "Countdown then shut down THIS server only",
	serverluck = "Set luck on THIS server + announce",
	globalluck = "Set luck on ALL servers + announce",
	kick = "Kick a player from this server",
	ban = "Ban a player from the experience",
	unban = "Remove an experience ban",
	playtutorial = "Replay the first-join tutorial",
	fly = "Toggle fly mode for yourself",
}

local function isPhoneLike(): boolean
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return true
	end
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and preferred == Enum.PreferredInput.Touch then
		return true
	end
	return false
end

local function isAdminAllowed(): boolean
	return player:GetAttribute(ADMIN_ALLOWED_ATTR) == true
end

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
		label.TextColor3 = COLORS.textMuted
	elseif ok then
		label.TextColor3 = COLORS.success
	else
		label.TextColor3 = COLORS.danger
	end
end

local function quoteIfNeeded(value: string): string
	if string.find(value, '[%s"]') then
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
		{ fill = "tp PlayerName", hint = "Teleport yourself to a player" },
		{ fill = "tp PlayerName me", hint = "Bring a player to you" },
		{ fill = "tp all me", hint = "Bring everyone to you" },
		{ fill = "tpland 1", hint = COMMAND_HINTS.tpland },
		{ fill = "tpland PlayerName 3", hint = "Teleport a player to a land" },
		{ fill = "tpland all 1", hint = "Teleport everyone to a land" },
		{ fill = "addinventory me NoobiniPizzanini", hint = "Give brainrot (equipped)" },
		{ fill = "addinventory me NoobiniPizzanini 3 golden 5", hint = "Count, mutation, level" },
		{ fill = "addcash me 1000000", hint = COMMAND_HINTS.addcash },
		{ fill = 'addluckyblock me "star rainbow"', hint = COMMAND_HINTS.addluckyblock },
		{ fill = "resetdata me", hint = COMMAND_HINTS.resetdata },
		{ fill = "rebirth me", hint = COMMAND_HINTS.rebirth },
		{ fill = "serverspawn mythic", hint = COMMAND_HINTS.serverspawn },
		{ fill = "globalspawn mythic", hint = COMMAND_HINTS.globalspawn },
		{ fill = "servernotif Event starting now!", hint = COMMAND_HINTS.servernotif },
		{ fill = "globalnotif Double luck weekend!", hint = COMMAND_HINTS.globalnotif },
		{ fill = "servershutdown 60", hint = COMMAND_HINTS.servershutdown },
		{ fill = "servershutdown 5m", hint = "Shut down this server in 5 minutes" },
		{ fill = "serverluck 4x 10m", hint = COMMAND_HINTS.serverluck },
		{ fill = "globalluck 4x 10m", hint = COMMAND_HINTS.globalluck },
		{ fill = "serverluck off", hint = "Clear luck on this server" },
		{ fill = "kick PlayerName", hint = COMMAND_HINTS.kick },
		{ fill = "ban PlayerName 7d", hint = COMMAND_HINTS.ban },
		{ fill = "ban PlayerName forever", hint = "Permanent experience ban" },
		{ fill = "unban PlayerName", hint = COMMAND_HINTS.unban },
		{ fill = "playtutorial", hint = COMMAND_HINTS.playtutorial },
		{ fill = "fly", hint = COMMAND_HINTS.fly },
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

	if
		cmdName == "addinventory"
		or cmdName == "addcash"
		or cmdName == "addluckyblock"
		or cmdName == "resetdata"
		or cmdName == "rebirth"
		or cmdName == "kick"
		or cmdName == "ban"
		or cmdName == "unban"
		or cmdName == "tp"
	then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, playerName in filterByPrefix(catalog.players, partial) do
				if playerName ~= "all" or (cmdName ~= "kick" and cmdName ~= "ban" and cmdName ~= "unban") then
					pushSuggestion(out, prefix .. playerName, "player target")
				end
			end
			if cmdName == "tp" and startsWith("to", partial) then
				pushSuggestion(out, prefix .. "to", "optional keyword")
			end
		end
	end

	if cmdName == "tp" then
		if argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			local prev = string.lower(tokens[2] or "")
			if prev == "to" then
				-- tp all to <player>
				for _, playerName in filterByPrefix(catalog.players, partial) do
					if playerName ~= "all" then
						pushSuggestion(out, prefix .. playerName, "destination")
					end
				end
			else
				if startsWith("to", partial) then
					pushSuggestion(out, prefix .. "to", "optional keyword")
				end
				for _, playerName in filterByPrefix(catalog.players, partial) do
					if playerName ~= "all" then
						pushSuggestion(out, prefix .. playerName, "destination")
					end
				end
			end
		elseif argIndex >= 3 and (#tokens > 3 or (endsWithSpace and #tokens >= 3)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(3, #tokens - 1))
			for _, playerName in filterByPrefix(catalog.players, partial) do
				if playerName ~= "all" then
					pushSuggestion(out, prefix .. playerName, "destination")
				end
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
	elseif cmdName == "serverspawn" or cmdName == "globalspawn" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, tier in { "mythic", "legendary", "godly", "secret" } do
				if startsWith(tier, partial) then
					pushSuggestion(
						out,
						prefix .. tier,
						if cmdName == "globalspawn" then "all servers" else "this server"
					)
				end
			end
		end
	elseif cmdName == "tpland" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for land = 1, 10 do
				local landStr = tostring(land)
				if startsWith(landStr, partial) then
					pushSuggestion(out, prefix .. landStr, "land spawn / revive pad")
				end
			end
			for _, playerName in filterByPrefix(catalog.players, partial) do
				pushSuggestion(out, prefix .. playerName, "player to teleport")
			end
		elseif argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			local first = tokens[2]
			if tonumber(first) then
				for _, playerName in filterByPrefix(catalog.players, partial) do
					pushSuggestion(out, prefix .. playerName, "player to teleport")
				end
			else
				for land = 1, 10 do
					local landStr = tostring(land)
					if startsWith(landStr, partial) then
						pushSuggestion(out, prefix .. landStr, "land spawn / revive pad")
					end
				end
			end
		end
	elseif cmdName == "servershutdown" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, sample in { "30", "60", "30s", "2m", "5m" } do
				if startsWith(sample, partial) then
					pushSuggestion(out, prefix .. sample, "this server only")
				end
			end
		end
	elseif cmdName == "serverluck" or cmdName == "globalluck" then
		if argIndex == 1 and (#tokens > 1 or endsWithSpace) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(1, #tokens - 1))
			for _, sample in { "2x", "4x", "8x", "off" } do
				if startsWith(sample, partial) then
					pushSuggestion(
						out,
						prefix .. sample,
						if cmdName == "globalluck" then "all servers" else "this server"
					)
				end
			end
		elseif argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			for _, sample in { "5m", "10m", "30m", "1h" } do
				if startsWith(sample, partial) then
					pushSuggestion(out, prefix .. sample, "duration")
				end
			end
		end
	elseif cmdName == "ban" then
		if argIndex == 2 and (#tokens > 2 or (endsWithSpace and #tokens >= 2)) then
			local prefix = joinPrefix(tokens, if endsWithSpace then #tokens else math.max(2, #tokens - 1))
			for _, sample in { "1h", "1d", "7d", "30d", "forever" } do
				if startsWith(sample, partial) then
					pushSuggestion(out, prefix .. sample, "ban duration")
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
		if IS_MOBILE_LAYOUT then
			scrollHint = string.format(" · drag %d-%d of %d", scrollOffset + 1, math.min(scrollOffset + MAX_SUGGESTION_ROWS, total), total)
		else
			scrollHint = string.format(
				" · scroll %d-%d of %d",
				scrollOffset + 1,
				math.min(scrollOffset + MAX_SUGGESTION_ROWS, total),
				total
			)
		end
	end
	setStatus(
		string.format(
			if IS_MOBILE_LAYOUT
				then "%d/%d selected · Tap to fill%s"
				else "%d/%d selected · Tab fill · ↑↓ move%s · Ctrl+↑↓ history",
			selectedSuggestionIndex,
			total,
			scrollHint
		),
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
	row.button.BackgroundColor3 = if selected
		then COLORS.selectedBg
		elseif hovered then COLORS.hoverBg
		else COLORS.idleBg
	row.button.BackgroundTransparency = if selected
		then COLORS.selectedBgTransparency
		elseif hovered then COLORS.hoverBgTransparency
		else COLORS.idleBgTransparency
end

local function isPointOverSuggestions(screenPos: Vector2): boolean
	local panel = suggestionPanel
	if not panel or not panel.Visible then
		return false
	end
	local inset = GuiService:GetGuiInset()
	local point = Vector2.new(screenPos.X, screenPos.Y - inset.Y)
	local pos = panel.AbsolutePosition
	local size = panel.AbsoluteSize
	return point.X >= pos.X and point.X <= pos.X + size.X and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

local function setSuggestionScrollOffset(nextOffset: number)
	local total = #currentMatches
	if total <= MAX_SUGGESTION_ROWS then
		scrollOffset = 0
		return
	end
	local maxOffset = math.max(0, total - MAX_SUGGESTION_ROWS)
	scrollOffset = math.clamp(nextOffset, 0, maxOffset)
	refreshSuggestions()
end

local function wireSuggestionTouchScroll()
	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not gui or not gui.Enabled or #currentMatches <= MAX_SUGGESTION_ROWS then
			return
		end
		if not isPointOverSuggestions(input.Position) then
			return
		end
		suggestionScrollTouch = input
		suggestionScrollStartY = input.Position.Y
		suggestionScrollStartOffset = scrollOffset
		suggestionScrollDragged = false
	end)

	UserInputService.InputEnded:Connect(function(input)
		if suggestionScrollTouch ~= input then
			return
		end
		if suggestionScrollDragged then
			suppressSuggestionRowTap = true
			task.defer(function()
				suppressSuggestionRowTap = false
			end)
		end
		suggestionScrollTouch = nil
		suggestionScrollDragged = false
	end)
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
	local sidePad = if IS_MOBILE_LAYOUT then 12 else 14
	panel.Size = UDim2.new(1, -sidePad * 2, 0, panelHeight)
	panel.Visible = panelHeight > 0
	local totalH = BASE_HEIGHT + panelHeight
	if ROOT_WIDTH_SCALE > 0 then
		root.Size = UDim2.new(ROOT_WIDTH_SCALE, 0, 0, totalH)
	else
		root.Size = UDim2.fromOffset(ROOT_WIDTH, totalH)
	end
	local status = statusLabel
	if status then
		status.Position = UDim2.fromOffset(sidePad + 2, HEADER_HEIGHT + CONTENT_PAD + INPUT_HEIGHT + 8 + panelHeight)
	end
end

local function applyLayoutMetrics()
	IS_MOBILE_LAYOUT = isPhoneLike()
	if IS_MOBILE_LAYOUT then
		MAX_SUGGESTION_ROWS = 4
		ROW_HEIGHT = 36
		ROOT_WIDTH = 0
		ROOT_WIDTH_SCALE = 0.86
		BASE_HEIGHT = HEADER_HEIGHT + CONTENT_PAD + INPUT_HEIGHT + 12 + STATUS_HEIGHT + 4
	else
		MAX_SUGGESTION_ROWS = 8
		ROW_HEIGHT = 34
		ROOT_WIDTH = 620
		ROOT_WIDTH_SCALE = 0
		BASE_HEIGHT = HEADER_HEIGHT + CONTENT_PAD + INPUT_HEIGHT + 10 + STATUS_HEIGHT
	end
	for index, row in suggestionRows do
		row.button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
		row.button.Position = UDim2.fromOffset(0, (index - 1) * ROW_HEIGHT + 2)
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
	local dim = backdrop
	if not root or not scale then
		return
	end
	local targetY = if IS_MOBILE_LAYOUT then 0.1 else 0.09
	if open then
		scale.Scale = 0.9
		root.Position = UDim2.fromScale(0.5, targetY - 0.02)
		root.BackgroundTransparency = 0.55
		TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
		TweenService:Create(root, OPEN_TWEEN, {
			Position = UDim2.fromScale(0.5, targetY),
			BackgroundTransparency = COLORS.rootBgTransparency,
		}):Play()
		if dim then
			dim.Visible = true
			dim.BackgroundTransparency = 1
			TweenService:Create(dim, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 0.62,
			}):Play()
		end
	else
		TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.94 }):Play()
		if dim then
			TweenService:Create(dim, CLOSE_TWEEN, { BackgroundTransparency = 1 }):Play()
		end
	end
end

local function setOpen(open: boolean)
	if not gui or not inputBox then
		return
	end
	applyLayoutMetrics()
	if open then
		closeToken += 1
		backdropGuardUntil = os.clock() + 0.35
		gui.Enabled = true
		inputBox.Text = ""
		selectedSuggestionIndex = 1
		hoveredSuggestionIndex = 0
		scrollOffset = 0
		historyIndex = 0
		local hint = if IS_MOBILE_LAYOUT
			then "Drag list to scroll · Tap suggestion · Run · X to close"
			else "Tab fill · ↑↓ navigate · Enter run · Esc close"
		setStatus(hint, nil)
		if titleLabel then
			titleLabel.Text = if IS_MOBILE_LAYOUT then "ADMIN COMMANDS" else "ADMIN"
		end
		animateOpen(true)
		task.defer(fetchCatalog)
		refreshSuggestions()
		task.defer(function()
			if inputBox and gui and gui.Enabled then
				inputBox:CaptureFocus()
			end
		end)
	else
		closeToken += 1
		local token = closeToken
		inputBox:ReleaseFocus()
		animateOpen(false)
		task.delay(0.14, function()
			if token == closeToken and gui then
				gui.Enabled = false
				if backdrop then
					backdrop.Visible = false
				end
			end
		end)
	end
end

function M.toggle()
	setOpen(not (gui and gui.Enabled))
end

function M.setOpen(open: boolean)
	setOpen(open)
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
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = rowButton

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.idleStroke
	stroke.Transparency = COLORS.idleStrokeTransparency
	stroke.Thickness = 1.2
	stroke.Parent = rowButton

	local cmdLabel = Instance.new("TextLabel")
	cmdLabel.Name = "Command"
	cmdLabel.BackgroundTransparency = 1
	UiFonts.applyButtonLabel(cmdLabel, 11, 8)
	cmdLabel.TextColor3 = COLORS.textPrimary
	cmdLabel.TextXAlignment = Enum.TextXAlignment.Left
	cmdLabel.TextTruncate = Enum.TextTruncate.AtEnd
	cmdLabel.Position = UDim2.fromOffset(12, 0)
	cmdLabel.Size = UDim2.new(0.58, -12, 1, 0)
	cmdLabel.ZIndex = 3
	cmdLabel.Parent = rowButton

	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "Hint"
	hintLabel.BackgroundTransparency = 1
	UiFonts.applyButtonLabel(hintLabel, 9, 7)
	hintLabel.TextColor3 = COLORS.textMuted
	hintLabel.TextXAlignment = Enum.TextXAlignment.Right
	hintLabel.TextTruncate = Enum.TextTruncate.AtEnd
	hintLabel.Position = UDim2.new(0.58, 0, 0, 0)
	hintLabel.Size = UDim2.new(0.42, -10, 1, 0)
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
		if suppressSuggestionRowTap then
			return
		end
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
	applyLayoutMetrics()

	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminCommandBar"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 9999
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local dim = Instance.new("TextButton")
	dim.Name = "Backdrop"
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Visible = false
	dim.ZIndex = 1
	dim.Parent = screen
	dim.MouseButton1Click:Connect(function()
		if os.clock() < backdropGuardUntil then
			return
		end
		setOpen(false)
	end)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.fromScale(0.5, 0.09)
	if ROOT_WIDTH_SCALE > 0 then
		root.Size = UDim2.new(ROOT_WIDTH_SCALE, 0, 0, BASE_HEIGHT)
	else
		root.Size = UDim2.fromOffset(ROOT_WIDTH, BASE_HEIGHT)
	end
	root.BackgroundColor3 = COLORS.panel
	root.BackgroundTransparency = COLORS.rootBgTransparency
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.ZIndex = 2

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = root

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 16)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Color = COLORS.panelStroke
	rootStroke.Transparency = 0.52
	rootStroke.Thickness = 1.25
	rootStroke.Parent = root

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundColor3 = COLORS.panelTop
	header.BackgroundTransparency = 0.35
	header.BorderSizePixel = 0
	header.ZIndex = 3
	header.Parent = root

	local headerAccent = Instance.new("Frame")
	headerAccent.Name = "AccentBar"
	headerAccent.Size = UDim2.new(1, 0, 0, 1)
	headerAccent.Position = UDim2.new(0, 0, 1, -1)
	headerAccent.BackgroundColor3 = COLORS.panelStroke
	headerAccent.BackgroundTransparency = 0.45
	headerAccent.BorderSizePixel = 0
	headerAccent.ZIndex = 4
	headerAccent.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	UiFonts.applyButtonLabel(title, 13, 10)
	title.Text = "ADMIN"
	title.TextColor3 = COLORS.textPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(16, 0)
	title.Size = UDim2.new(1, -70, 1, 0)
	title.ZIndex = 4
	title.Parent = header

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AutoButtonColor = false
	closeBtn.Text = "X"
	UiFonts.applyButtonLabel(closeBtn, 16, 11)
	closeBtn.TextColor3 = COLORS.textMuted
	closeBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 48)
	closeBtn.BackgroundTransparency = 0.2
	closeBtn.BorderSizePixel = 0
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -12, 0.5, 0)
	closeBtn.Size = UDim2.fromOffset(32, 32)
	closeBtn.ZIndex = 5
	closeBtn.Parent = header
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeBtn
	closeBtn.MouseButton1Click:Connect(function()
		UIInteractionSounds.playClick()
		setOpen(false)
	end)
	closeBtn.MouseEnter:Connect(function()
		closeBtn.TextColor3 = COLORS.danger
		TweenService:Create(closeBtn, TweenInfo.new(0.1), { BackgroundTransparency = 0 }):Play()
	end)
	closeBtn.MouseLeave:Connect(function()
		closeBtn.TextColor3 = COLORS.textMuted
		TweenService:Create(closeBtn, TweenInfo.new(0.1), { BackgroundTransparency = 0.2 }):Play()
	end)

	local box = Instance.new("TextBox")
	box.Name = "CommandInput"
	box.ClearTextOnFocus = false
	UiFonts.applyInput(box)
	box.PlaceholderText = "Type a command…  e.g. tpland 3"
	box.Text = ""
	box.TextColor3 = COLORS.textPrimary
	box.PlaceholderColor3 = Color3.fromRGB(110, 125, 145)
	box.TextSize = 17
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.BackgroundColor3 = COLORS.inputBg
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(14, HEADER_HEIGHT + CONTENT_PAD)
	box.Size = UDim2.new(1, -108, 0, INPUT_HEIGHT)
	box.ZIndex = 3

	local boxPadding = Instance.new("UIPadding")
	boxPadding.PaddingLeft = UDim.new(0, 12)
	boxPadding.PaddingRight = UDim.new(0, 12)
	boxPadding.Parent = box

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 10)
	boxCorner.Parent = box

	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = COLORS.idleStroke
	boxStroke.Transparency = 0.35
	boxStroke.Thickness = 1.2
	boxStroke.Parent = box

	local runBtn = Instance.new("TextButton")
	runBtn.Name = "Run"
	runBtn.AutoButtonColor = false
	runBtn.Text = "Run"
	UiFonts.applyButtonLabel(runBtn, 12, 9)
	runBtn.TextColor3 = Color3.fromRGB(18, 22, 30)
	runBtn.BackgroundColor3 = COLORS.runBtn
	runBtn.BorderSizePixel = 0
	runBtn.AnchorPoint = Vector2.new(1, 0)
	runBtn.Position = UDim2.new(1, -14, 0, HEADER_HEIGHT + CONTENT_PAD)
	runBtn.Size = UDim2.fromOffset(80, INPUT_HEIGHT)
	runBtn.ZIndex = 3
	local runCorner = Instance.new("UICorner")
	runCorner.CornerRadius = UDim.new(0, 10)
	runCorner.Parent = runBtn
	runBtn.MouseButton1Click:Connect(function()
		UIInteractionSounds.playClick()
		submitCommand()
	end)
	runBtn.MouseEnter:Connect(function()
		TweenService:Create(runBtn, TweenInfo.new(0.1), {
			BackgroundColor3 = COLORS.runBtnHover,
		}):Play()
	end)
	runBtn.MouseLeave:Connect(function()
		TweenService:Create(runBtn, TweenInfo.new(0.1), {
			BackgroundColor3 = COLORS.runBtn,
		}):Play()
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Suggestions"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Position = UDim2.fromOffset(14, HEADER_HEIGHT + CONTENT_PAD + INPUT_HEIGHT + 8)
	panel.Size = UDim2.new(1, -28, 0, 0)
	panel.Visible = false
	panel.ZIndex = 2

	-- Pre-create enough rows for desktop max; mobile shows fewer via MAX_SUGGESTION_ROWS.
	for index = 1, 8 do
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
	scrollThumb.BackgroundColor3 = COLORS.accentDim
	scrollThumb.BackgroundTransparency = 0.25
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
	UiFonts.applyBodyLabel(label, 10, 7)
	label.Text = "Ready"
	label.TextColor3 = COLORS.textMuted
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(16, BASE_HEIGHT - STATUS_HEIGHT)
	label.Size = UDim2.new(1, -32, 0, STATUS_HEIGHT - 4)
	label.ZIndex = 3

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
	runBtn.Parent = root
	panel.Parent = root
	label.Parent = root
	screen.Parent = parent

	gui = screen
	backdrop = dim
	rootFrame = root
	rootScale = scale
	inputBox = box
	_runButton = runBtn
	_closeButton = closeBtn
	statusLabel = label
	suggestionPanel = panel
	suggestionScrollTrack = scrollTrack
	suggestionScrollThumb = scrollThumb
	titleLabel = title
end

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

local function ensureClickButton(host: GuiObject): GuiButton
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local existing = host:FindFirstChild("_AdminClick")
	if existing and existing:IsA("GuiButton") then
		return existing :: GuiButton
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_AdminClick"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 50
	btn.Parent = host
	return btn
end

local function highlightOn(host: GuiObject): GuiObject?
	local decor = host:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local on = highlight and highlight:FindFirstChild("On")
	if on and on:IsA("GuiObject") then
		return on :: GuiObject
	end
	return nil
end

local function syncMobileAdminButton()
	local frame = mobileAdminFrame
	local host = mobileAdminButtonHost
	local show = isAdminAllowed() and isPhoneLike()
	if frame then
		frame.Visible = show
	end
	if host then
		host.Visible = show
	end
end

local function wireMobileAdminButton()
	if mobileAdminWired then
		return
	end
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return
	end
	local sideUI = main:FindFirstChild("SideUI")
	-- Prefer SideUI.AdminFrame; fall back to any AdminFrame under Main (Studio moves).
	local adminFrame = (sideUI and sideUI:FindFirstChild("AdminFrame"))
		or main:FindFirstChild("AdminFrame", true)
	if not adminFrame or not adminFrame:IsA("GuiObject") then
		return
	end
	local host = adminFrame:FindFirstChild("Admin Panel Button")
		or adminFrame:FindFirstChild("AdminPanelButton")
	if not host or not host:IsA("GuiObject") then
		return
	end

	mobileAdminWired = true
	mobileAdminFrame = adminFrame :: GuiObject
	mobileAdminButtonHost = host :: GuiObject
	;(adminFrame :: GuiObject).Visible = false
	host.Visible = false
	;(adminFrame :: GuiObject).Active = false
	host.Active = true
	pcall(function()
		(host :: any).Interactable = true
	end)

	local on = highlightOn(host)
	if on then
		on.Visible = false
	end

	local scale = getOrAddUIScale(host)
	local btn: GuiButton = if host:IsA("GuiButton") then host :: GuiButton else ensureClickButton(host)
	local tiltTarget: GuiObject = host
	local adminIcon = host:FindFirstChild("Admin", true)
	if adminIcon and adminIcon:IsA("GuiObject") then
		tiltTarget = adminIcon
	end

	UIButtonEffects.wireTiltHoverButton(btn, function()
		if not isAdminAllowed() then
			return
		end
		-- Open only (don't toggle): MouseButton1Down + backdrop Click would open then close.
		if gui and gui.Enabled then
			setOpen(false)
		else
			setOpen(true)
		end
	end, host, tiltTarget, true)

	-- Keep Studio Decor.Highlight.On in sync with hover.
	btn.MouseEnter:Connect(function()
		if on then
			on.Visible = true
		end
	end)
	btn.MouseLeave:Connect(function()
		if on then
			on.Visible = false
		end
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)

	syncMobileAdminButton()
	player:GetAttributeChangedSignal(ADMIN_ALLOWED_ATTR):Connect(syncMobileAdminButton)
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(syncMobileAdminButton)
	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(syncMobileAdminButton)
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
	wireSuggestionTouchScroll()
	task.spawn(function()
		for _ = 1, 30 do
			wireMobileAdminButton()
			if mobileAdminWired then
				break
			end
			task.wait(0.5)
		end
		if not mobileAdminWired then
			warn("[AdminCommandBar] SideUI.AdminFrame['Admin Panel Button'] not found — mobile admin button skipped")
		end
	end)

	local lastToggleAt = 0
	local function onToggleAdmin()
		if not isAdminAllowed() and not RunService:IsStudio() then
			-- Attribute may still be syncing; allow Studio always via allowlist server-side.
			return
		end
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
	ContextActionService:BindActionAtPriority(ACTION_NAME, function(_name, state, input)
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
	end, false, BIND_PRIORITY, table.unpack(TOGGLE_KEYS))

	ContextActionService:UnbindAction(AUTOCOMPLETE_ACTION_NAME)
	ContextActionService:BindActionAtPriority(AUTOCOMPLETE_ACTION_NAME, function(_name, state, input)
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
	end, false, AUTOCOMPLETE_PRIORITY, Enum.KeyCode.Tab)

	UserInputService.InputChanged:Connect(function(input, _gameProcessed)
		if
			suggestionScrollTouch
			and input == suggestionScrollTouch
			and input.UserInputType == Enum.UserInputType.Touch
		then
			local dy = input.Position.Y - suggestionScrollStartY
			if not suggestionScrollDragged and math.abs(dy) < SUGGESTION_SCROLL_DRAG_PX then
				return
			end
			suggestionScrollDragged = true
			local rowDelta = -dy / ROW_HEIGHT
			setSuggestionScrollOffset(math.floor(suggestionScrollStartOffset + rowDelta + 0.5))
			return
		end
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
				if
					UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
				then
					cycleHistory(-1)
				else
					cycleSuggestion(-1)
				end
			elseif input.KeyCode == Enum.KeyCode.Down then
				if
					UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
				then
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
				and (
					UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
				)
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
end

return M
