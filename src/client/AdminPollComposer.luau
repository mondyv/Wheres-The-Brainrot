-- [ACTIVE] AdminPollComposer
--[[
	Admin-only poll builder. Opened by the `polls` command.
	OPS DESK styling. Unchecked option rows are omitted (2–4 answers).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AdminPollConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminPollConfig"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer
local IS_TOUCH = UserInputService.TouchEnabled

local COLORS = {
	panel = Color3.fromRGB(14, 10, 14),
	panelTop = Color3.fromRGB(28, 16, 22),
	accent = Color3.fromRGB(255, 214, 96),
	inputBg = Color3.fromRGB(8, 7, 10),
	idle = Color3.fromRGB(22, 16, 20),
	text = Color3.fromRGB(255, 246, 230),
	muted = Color3.fromRGB(168, 148, 140),
	stroke = Color3.fromRGB(255, 214, 96),
	success = Color3.fromRGB(140, 210, 165),
	danger = Color3.fromRGB(255, 95, 110),
	server = Color3.fromRGB(110, 190, 255),
	global = Color3.fromRGB(255, 168, 82),
}

local OPTION_LETTERS = { "A", "B", "C", "D" }
local ROW_H = if IS_TOUCH then 52 else 44
local CHIP_H = if IS_TOUCH then 44 else 38
local SEND_H = if IS_TOUCH then 52 else 46

local AdminPollComposer = {}

local gui: ScreenGui? = nil
local root: Frame? = nil
local rootScale: UIScale? = nil
local questionBox: TextBox? = nil
local statusLabel: TextLabel? = nil
local sendButton: TextButton? = nil
local serverBtn: TextButton? = nil
local globalBtn: TextButton? = nil
local durationBtns: { TextButton } = {}
local questionModeBtn: TextButton? = nil
local rewardModeBtn: TextButton? = nil
local titleLabel: TextLabel? = nil
local subtitleLabel: TextLabel? = nil
local questionHeader: TextLabel? = nil
local optionsHeader: TextLabel? = nil
local scope: "server" | "global" = "server"
local pollMode: "question" | "reward" = "question"
local durationSec = AdminPollConfig.DURATION_SEC
local KIND_ORDER = { "brainrot", "luckyBlock", "gear" }
local KIND_LABEL = {
	brainrot = "BR",
	luckyBlock = "BLOCK",
	gear = "GEAR",
}
local KIND_PLACEHOLDER = {
	brainrot = "Search brainrot · Tab",
	luckyBlock = "Search lucky block · Tab",
	gear = "Search gear · Tab",
}
local optionRows: {
	{
		enabled: boolean,
		toggle: TextButton,
		box: TextBox,
		row: Frame,
		letter: TextLabel,
		kindBtn: TextButton,
		rewardKind: string,
	}
} = {}
local sending = false
local closeToken = 0
local initialized = false
local TAB_ACTION = "AdminPollComposerTabFill"
local SUGGEST_COUNT = 8
type SuggestItem = { fill: string, label: string }
local catalogCache: { [string]: { SuggestItem } } = {}
local suggestPanel: Frame? = nil
local suggestButtons: { TextButton } = {}
local suggestMatches: { SuggestItem } = {}
local suggestCursor = 0
local suggestRowIndex = 0
local tabBound = false

local function isAdmin(): boolean
	return player:GetAttribute("AdminPanelAllowed") == true
end

local function getCreateRemote(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(AdminPollConfig.CREATE_REMOTE)
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function setStatus(text: string, ok: boolean?)
	if not statusLabel then
		return
	end
	statusLabel.Text = text
	if ok == true then
		statusLabel.TextColor3 = COLORS.success
	elseif ok == false then
		statusLabel.TextColor3 = COLORS.danger
	else
		statusLabel.TextColor3 = COLORS.muted
	end
end

local function paintScope()
	if serverBtn then
		local on = scope == "server"
		serverBtn.BackgroundColor3 = if on then COLORS.server else COLORS.idle
		serverBtn.BackgroundTransparency = if on then 0.08 else 0.2
		serverBtn.TextColor3 = if on then Color3.fromRGB(8, 16, 28) else COLORS.muted
	end
	if globalBtn then
		local on = scope == "global"
		globalBtn.BackgroundColor3 = if on then COLORS.global else COLORS.idle
		globalBtn.BackgroundTransparency = if on then 0.04 else 0.2
		globalBtn.TextColor3 = if on then Color3.fromRGB(28, 14, 6) else COLORS.muted
	end
end

local function paintDuration()
	for _, btn in durationBtns do
		local sec = btn:GetAttribute("DurationSec")
		local on = typeof(sec) == "number" and sec == durationSec
		btn.BackgroundColor3 = if on then COLORS.accent else COLORS.idle
		btn.BackgroundTransparency = if on then 0 else 0.18
		btn.TextColor3 = if on then Color3.fromRGB(22, 14, 8) else COLORS.muted
	end
end

local function paintOptionRow(index: number)
	local row = optionRows[index]
	if not row then
		return
	end
	row.toggle.Text = if row.enabled then "✓" else ""
	row.toggle.BackgroundColor3 = if row.enabled then COLORS.accent else COLORS.idle
	row.toggle.TextColor3 = Color3.fromRGB(18, 16, 10)
	row.box.TextEditable = row.enabled
	row.box.TextTransparency = if row.enabled then 0 else 0.45
	row.row.BackgroundTransparency = if row.enabled then 0.12 else 0.4
	local reward = pollMode == "reward"
	row.letter.Visible = not reward
	row.kindBtn.Visible = reward
	row.kindBtn.Text = KIND_LABEL[row.rewardKind] or "BR"
	if reward then
		row.box.PlaceholderText = KIND_PLACEHOLDER[row.rewardKind] or "Reward"
		row.box.Position = UDim2.fromOffset(if IS_TOUCH then 118 else 112, 6)
		row.box.Size = UDim2.new(1, if IS_TOUCH then -128 else -122, 1, -12)
	else
		row.box.PlaceholderText = "Option " .. OPTION_LETTERS[index]
		row.box.Position = UDim2.fromOffset(if IS_TOUCH then 70 else 66, 6)
		row.box.Size = UDim2.new(1, if IS_TOUCH then -82 else -78, 1, -12)
	end
end

local function paintMode()
	if questionModeBtn then
		local on = pollMode == "question"
		questionModeBtn.BackgroundColor3 = if on then COLORS.accent else COLORS.idle
		questionModeBtn.TextColor3 = if on then Color3.fromRGB(22, 14, 8) else COLORS.muted
	end
	if rewardModeBtn then
		local on = pollMode == "reward"
		rewardModeBtn.BackgroundColor3 = if on then COLORS.accent else COLORS.idle
		rewardModeBtn.TextColor3 = if on then Color3.fromRGB(22, 14, 8) else COLORS.muted
	end
	if titleLabel then
		titleLabel.Text = if pollMode == "reward" then "REWARD POLL" else "POLL DESK"
	end
	if subtitleLabel then
		subtitleLabel.Text = if pollMode == "reward" then "PICK  ·  CLAIM  ·  SKY DROP" else "SERVER  ·  GLOBAL  ·  TIMER"
	end
	if questionHeader then
		questionHeader.Text = if pollMode == "reward" then "TITLE  ·  optional" else "QUESTION"
	end
	if optionsHeader then
		optionsHeader.Text = if pollMode == "reward" then "REWARDS  ·  type to search  ·  Tab to fill" else "OPTIONS  ·  uncheck to hide"
	end
	if questionBox then
		questionBox.PlaceholderText = if pollMode == "reward" then "Pick your reward" else "Ask anything…"
	end
	if sendButton then
		sendButton.Text = if pollMode == "reward" then "SEND REWARD POLL" else "SEND POLL"
	end
	for i = 1, #optionRows do
		paintOptionRow(i)
	end
	if pollMode ~= "reward" and suggestPanel then
		suggestPanel.Visible = false
	end
end

local function addCorner(guiObj: GuiObject, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = guiObj
end

local function addStroke(guiObj: GuiObject, color: Color3, thickness: number, trans: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = trans
	s.Parent = guiObj
end

local function collectOptions(): { string }
	local out = {}
	for _, row in optionRows do
		if row.enabled then
			local text = string.gsub(row.box.Text, "^%s*(.-)%s*$", "%1")
			if text ~= "" then
				table.insert(out, text)
			end
		end
	end
	return out
end

local function collectRewards(): { { kind: string, id: string } }
	local out = {}
	for _, row in optionRows do
		if row.enabled then
			local text = string.gsub(row.box.Text, "^%s*(.-)%s*$", "%1")
			if text ~= "" then
				table.insert(out, {
					kind = row.rewardKind,
					id = text,
				})
			end
		end
	end
	return out
end

local function catalogForKind(kind: string): { SuggestItem }
	local cached = catalogCache[kind]
	if cached then
		return cached
	end
	local items: { SuggestItem } = {}
	if kind == "brainrot" then
		local names = BrainrotsConfig:GetNames()
		for _, name in names do
			table.insert(items, { fill = name, label = name })
		end
	elseif kind == "luckyBlock" then
		for _, def in LuckyBlockCatalog.BLOCKS do
			table.insert(items, { fill = def.id, label = def.displayName })
		end
	elseif kind == "gear" then
		for _, def in GearConfig.GEARS do
			table.insert(items, { fill = tostring(def.id), label = def.name .. "  #" .. tostring(def.id) })
		end
	end
	catalogCache[kind] = items
	return items
end

local function filterCatalog(kind: string, query: string): { SuggestItem }
	local q = string.lower((string.gsub(query, "^%s*(.-)%s*$", "%1")))
	local items = catalogForKind(kind)
	if q == "" then
		local slice = {}
		for i = 1, math.min(SUGGEST_COUNT, #items) do
			table.insert(slice, items[i])
		end
		return slice
	end
	local prefix: { SuggestItem } = {}
	local mid: { SuggestItem } = {}
	for _, item in items do
		local fillL = string.lower(item.fill)
		local labelL = string.lower(item.label)
		if string.sub(fillL, 1, #q) == q or string.sub(labelL, 1, #q) == q then
			table.insert(prefix, item)
		elseif string.find(fillL, q, 1, true) or string.find(labelL, q, 1, true) then
			table.insert(mid, item)
		end
	end
	local out = prefix
	for _, item in mid do
		if #out >= SUGGEST_COUNT then
			break
		end
		table.insert(out, item)
	end
	return out
end

local function hideSuggestions()
	if suggestPanel then
		suggestPanel.Visible = false
	end
	suggestMatches = {}
	suggestCursor = 0
	suggestRowIndex = 0
end

local function paintSuggestHighlight()
	for i, btn in suggestButtons do
		local on = i == suggestCursor
		btn.BackgroundColor3 = if on then COLORS.accent else COLORS.idle
		btn.TextColor3 = if on then Color3.fromRGB(22, 14, 8) else COLORS.text
	end
end

local function placeSuggestPanel(box: TextBox)
	if not suggestPanel then
		return
	end
	local abs = box.AbsolutePosition
	local size = box.AbsoluteSize
	suggestPanel.Position = UDim2.fromOffset(abs.X, abs.Y + size.Y + 4)
	suggestPanel.Size = UDim2.fromOffset(math.max(240, size.X), 0)
end

local refreshSuggestions: (number) -> ()

local function tabFill(delta: number)
	if pollMode ~= "reward" then
		return
	end
	local focused = UserInputService:GetFocusedTextBox()
	local rowIndex = 0
	for i, row in optionRows do
		if row.box == focused then
			rowIndex = i
			break
		end
	end
	if rowIndex == 0 then
		return
	end
	if suggestRowIndex ~= rowIndex or #suggestMatches == 0 then
		refreshSuggestions(rowIndex)
	end
	if #suggestMatches == 0 then
		return
	end
	if suggestCursor <= 0 then
		suggestCursor = 1
	else
		suggestCursor += delta
		if suggestCursor < 1 then
			suggestCursor = #suggestMatches
		elseif suggestCursor > #suggestMatches then
			suggestCursor = 1
		end
	end
	paintSuggestHighlight()
	local item = suggestMatches[suggestCursor]
	if item then
		local row = optionRows[rowIndex]
		row.box.Text = item.fill
		row.box.CursorPosition = #item.fill + 1
	end
end

refreshSuggestions = function(rowIndex: number)
	local row = optionRows[rowIndex]
	if not row or pollMode ~= "reward" or not row.enabled then
		hideSuggestions()
		return
	end
	suggestRowIndex = rowIndex
	suggestMatches = filterCatalog(row.rewardKind, row.box.Text)
	if not suggestPanel then
		return
	end
	for i = 1, SUGGEST_COUNT do
		local btn = suggestButtons[i]
		local item = suggestMatches[i]
		if item and btn then
			btn.Visible = true
			btn.Text = item.label
			btn.LayoutOrder = i
		elseif btn then
			btn.Visible = false
		end
	end
	if #suggestMatches == 0 then
		hideSuggestions()
		return
	end
	suggestCursor = 0
	paintSuggestHighlight()
	placeSuggestPanel(row.box)
	suggestPanel.Visible = true
end

local function bindTabFill()
	if tabBound then
		return
	end
	tabBound = true
	ContextActionService:BindActionAtPriority(TAB_ACTION, function(_name, state)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if not gui or not gui.Enabled or pollMode ~= "reward" then
			return Enum.ContextActionResult.Pass
		end
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		tabFill(if shift then -1 else 1)
		return Enum.ContextActionResult.Sink
	end, false, 20000, Enum.KeyCode.Tab)
end

local function unbindTabFill()
	if not tabBound then
		return
	end
	tabBound = false
	ContextActionService:UnbindAction(TAB_ACTION)
	hideSuggestions()
end

local function setOpen(open: boolean)
	if not gui or not root or not rootScale then
		return
	end
	if open then
		if not isAdmin() then
			return
		end
		closeToken += 1
		gui.Enabled = true
		root.Visible = true
		rootScale.Scale = 0.92
		root.BackgroundTransparency = 0.2
		TweenService:Create(rootScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
		setStatus(if pollMode == "reward" then "Type to search rewards. Tab fills, Shift+Tab cycles." else "Uncheck a row to drop that option.", nil)
		bindTabFill()
		if not IS_TOUCH then
			task.defer(function()
				if questionBox and gui and gui.Enabled then
					questionBox:CaptureFocus()
				end
			end)
		end
	else
		unbindTabFill()
		closeToken += 1
		local token = closeToken
		if questionBox then
			questionBox:ReleaseFocus()
		end
		for _, row in optionRows do
			row.box:ReleaseFocus()
		end
		TweenService:Create(rootScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = 0.94,
		}):Play()
		task.delay(0.14, function()
			if token == closeToken and gui then
				gui.Enabled = false
			end
		end)
	end
end

local function sendPoll()
	if sending then
		return
	end
	if not isAdmin() then
		setStatus("You are not allowed to send polls.", false)
		return
	end
	local q = questionBox and string.gsub(questionBox.Text, "^%s*(.-)%s*$", "%1") or ""
	if pollMode == "reward" then
		if q == "" then
			q = "Pick your reward"
		end
		local rewards = collectRewards()
		if #rewards < AdminPollConfig.MIN_OPTIONS then
			setStatus("Need at least two filled, checked rewards.", false)
			return
		end
		local rf = getCreateRemote()
		if not rf then
			setStatus("Poll service is not ready.", false)
			return
		end
		sending = true
		setStatus("Sending...", nil)
		if sendButton then
			sendButton.Active = false
		end
		local clamped = math.clamp(durationSec, AdminPollConfig.MIN_DURATION_SEC, AdminPollConfig.MAX_DURATION_SEC)
		task.spawn(function()
			local ok, response = pcall(function()
				return rf:InvokeServer({
					question = q,
					mode = "reward",
					rewards = rewards,
					scope = scope,
					durationSec = clamped,
				})
			end)
			sending = false
			if sendButton then
				sendButton.Active = true
			end
			if not ok then
				warn("[AdminPollComposer] create invoke failed:", response)
				setStatus("Send failed. Check output.", false)
				return
			end
			if typeof(response) == "table" and response.ok == true then
				setStatus(tostring(response.message or "Sent."), true)
				TopNotifController.showPersonal(tostring(response.message or "Reward poll sent."), "legendary", 2.6)
				UIInteractionSounds.playClick()
				setOpen(false)
			else
				local msg = if typeof(response) == "table" then tostring(response.message or "Could not send.") else "Could not send."
				setStatus(msg, false)
			end
		end)
		return
	end
	if q == "" then
		setStatus("Write a question first.", false)
		return
	end
	local options = collectOptions()
	if #options < AdminPollConfig.MIN_OPTIONS then
		setStatus("Need at least two filled, checked options.", false)
		return
	end
	local rf = getCreateRemote()
	if not rf then
		setStatus("Poll service is not ready.", false)
		return
	end
	sending = true
	setStatus("Sending...", nil)
	if sendButton then
		sendButton.Active = false
	end
	local clamped = math.clamp(durationSec, AdminPollConfig.MIN_DURATION_SEC, AdminPollConfig.MAX_DURATION_SEC)
	task.spawn(function()
		local ok, response = pcall(function()
			return rf:InvokeServer({
				question = q,
				options = options,
				scope = scope,
				durationSec = clamped,
				mode = "question",
			})
		end)
		sending = false
		if sendButton then
			sendButton.Active = true
		end
		if not ok then
			warn("[AdminPollComposer] create invoke failed:", response)
			setStatus("Send failed. Check output.", false)
			return
		end
		if typeof(response) == "table" and response.ok == true then
			setStatus(tostring(response.message or "Sent."), true)
			TopNotifController.showPersonal(tostring(response.message or "Poll sent."), "legendary", 2.6)
			UIInteractionSounds.playClick()
			setOpen(false)
		else
			local msg = if typeof(response) == "table" then tostring(response.message or "Could not send.") else "Could not send."
			setStatus(msg, false)
		end
	end)
end

local function makeSectionLabel(parent: Instance, text: string, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 16)
	label.FontFace = UiFonts.DISPLAY_FACE
	label.Text = text
	label.TextColor3 = COLORS.muted
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = order
	label.ZIndex = 3
	label.Parent = parent
	return label
end

local function buildGui(parent: PlayerGui)
	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminPollComposer"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local dim = Instance.new("TextButton")
	dim.Name = "Backdrop"
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 0.42
	dim.BorderSizePixel = 0
	dim.ZIndex = 1
	dim.Parent = screen
	dim.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Root"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	if IS_TOUCH then
		panel.Size = UDim2.new(0.92, 0, 0.86, 0)
	else
		panel.Size = UDim2.fromOffset(520, 640)
	end
	panel.BackgroundColor3 = COLORS.panel
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	addCorner(panel, 6)
	addStroke(panel, COLORS.stroke, 1.5, 0.45)

	local scale = Instance.new("UIScale")
	scale.Name = "AnimScale"
	scale.Scale = 1
	scale.Parent = panel

	local goldCap = Instance.new("Frame")
	goldCap.Name = "GoldCap"
	goldCap.Size = UDim2.new(1, 0, 0, 3)
	goldCap.BackgroundColor3 = COLORS.accent
	goldCap.BorderSizePixel = 0
	goldCap.ZIndex = 6
	goldCap.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundColor3 = COLORS.panelTop
	header.BackgroundTransparency = 0.12
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, 0, 0, 56)
	header.ZIndex = 3
	header.Parent = panel
	local headerAccent = Instance.new("Frame")
	headerAccent.Size = UDim2.new(1, 0, 0, 1)
	headerAccent.Position = UDim2.new(0, 0, 1, -1)
	headerAccent.BackgroundColor3 = COLORS.accent
	headerAccent.BackgroundTransparency = 0.55
	headerAccent.BorderSizePixel = 0
	headerAccent.ZIndex = 4
	headerAccent.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(18, 4)
	title.Size = UDim2.new(1, -70, 0, 26)
	title.FontFace = UiFonts.DISPLAY_FACE
	title.Text = "POLL DESK"
	title.TextColor3 = COLORS.accent
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 4
	title.Parent = header
	titleLabel = title
	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(18, 30)
	subtitle.Size = UDim2.new(1, -70, 0, 18)
	UiFonts.applyBody(subtitle)
	subtitle.Text = "SERVER  ·  GLOBAL  ·  TIMER"
	subtitle.TextColor3 = COLORS.muted
	subtitle.TextSize = 9
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 4
	subtitle.Parent = header
	subtitleLabel = subtitle

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AutoButtonColor = false
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -10, 0.5, 0)
	close.Size = UDim2.fromOffset(if IS_TOUCH then 40 else 32, if IS_TOUCH then 40 else 32)
	close.BackgroundTransparency = 1
	close.Text = "×"
	close.TextColor3 = COLORS.muted
	close.TextSize = 22
	close.ZIndex = 4
	close.Parent = header
	close.MouseButton1Click:Connect(function()
		setOpen(false)
	end)
	close.MouseEnter:Connect(function()
		close.TextColor3 = COLORS.danger
	end)
	close.MouseLeave:Connect(function()
		close.TextColor3 = COLORS.muted
	end)

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.fromOffset(18, 64)
	body.Size = UDim2.new(1, -36, 1, -76)
	body.CanvasSize = UDim2.new(0, 0, 0, 0)
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollBarThickness = if IS_TOUCH then 6 else 4
	body.ScrollBarImageColor3 = COLORS.accent
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.ZIndex = 3
	body.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body
	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingBottom = UDim.new(0, 12)
	bodyPad.PaddingRight = UDim.new(0, 8)
	bodyPad.Parent = body

	makeSectionLabel(body, "TYPE", 1)

	local modeRow = Instance.new("Frame")
	modeRow.BackgroundTransparency = 1
	modeRow.Size = UDim2.new(1, 0, 0, CHIP_H)
	modeRow.LayoutOrder = 2
	modeRow.ZIndex = 3
	modeRow.Parent = body
	local modeLayout = Instance.new("UIListLayout")
	modeLayout.FillDirection = Enum.FillDirection.Horizontal
	modeLayout.Padding = UDim.new(0, 10)
	modeLayout.Parent = modeRow
	local function makeModeChip(name: string, labelText: string): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AutoButtonColor = false
		btn.Size = UDim2.new(0.5, -5, 1, 0)
		btn.BackgroundColor3 = COLORS.idle
		btn.Text = labelText
		btn.TextColor3 = COLORS.muted
		btn.TextSize = if IS_TOUCH then 14 else 15
		btn.FontFace = UiFonts.DISPLAY_FACE
		btn.ZIndex = 4
		addCorner(btn, 4)
		addStroke(btn, COLORS.stroke, 1.1, 0.55)
		btn.Parent = modeRow
		return btn
	end
	questionModeBtn = makeModeChip("QuestionMode", "QUESTION POLL")
	rewardModeBtn = makeModeChip("RewardMode", "REWARD POLL")
	questionModeBtn.MouseButton1Click:Connect(function()
		pollMode = "question"
		paintMode()
		UIInteractionSounds.playClick()
	end)
	rewardModeBtn.MouseButton1Click:Connect(function()
		pollMode = "reward"
		paintMode()
		UIInteractionSounds.playClick()
	end)

	makeSectionLabel(body, "SCOPE", 3)

	local scopeRow = Instance.new("Frame")
	scopeRow.BackgroundTransparency = 1
	scopeRow.Size = UDim2.new(1, 0, 0, CHIP_H)
	scopeRow.LayoutOrder = 4
	scopeRow.ZIndex = 3
	scopeRow.Parent = body
	local scopeLayout = Instance.new("UIListLayout")
	scopeLayout.FillDirection = Enum.FillDirection.Horizontal
	scopeLayout.Padding = UDim.new(0, 10)
	scopeLayout.Parent = scopeRow

	local function makeScopeChip(name: string, labelText: string): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AutoButtonColor = false
		btn.Size = UDim2.new(0.5, -5, 1, 0)
		btn.BackgroundColor3 = COLORS.idle
		btn.BackgroundTransparency = 0.2
		btn.Text = labelText
		btn.TextColor3 = COLORS.muted
		btn.TextSize = if IS_TOUCH then 14 else 15
		btn.FontFace = UiFonts.DISPLAY_FACE
		btn.ZIndex = 4
		addCorner(btn, 4)
		addStroke(btn, COLORS.stroke, 1.1, 0.55)
		btn.Parent = scopeRow
		return btn
	end
	serverBtn = makeScopeChip("Server", "THIS SERVER")
	globalBtn = makeScopeChip("Global", "ALL SERVERS")
	serverBtn.MouseButton1Click:Connect(function()
		scope = "server"
		paintScope()
		UIInteractionSounds.playClick()
	end)
	globalBtn.MouseButton1Click:Connect(function()
		scope = "global"
		paintScope()
		UIInteractionSounds.playClick()
	end)

	makeSectionLabel(body, "TIMER", 5)

	local timerRow = Instance.new("Frame")
	timerRow.BackgroundTransparency = 1
	timerRow.Size = UDim2.new(1, 0, 0, if IS_TOUCH then CHIP_H * 2 + 8 else CHIP_H)
	timerRow.LayoutOrder = 6
	timerRow.ZIndex = 3
	timerRow.Parent = body
	if IS_TOUCH then
		local timerGrid = Instance.new("UIGridLayout")
		timerGrid.CellSize = UDim2.new(1 / 3, -6, 0, CHIP_H)
		timerGrid.CellPadding = UDim2.fromOffset(8, 8)
		timerGrid.FillDirectionMaxCells = 3
		timerGrid.SortOrder = Enum.SortOrder.LayoutOrder
		timerGrid.Parent = timerRow
	else
		local timerLayout = Instance.new("UIListLayout")
		timerLayout.FillDirection = Enum.FillDirection.Horizontal
		timerLayout.Padding = UDim.new(0, 6)
		timerLayout.Parent = timerRow
	end

	local presets = AdminPollConfig.DURATION_PRESETS
	local chipCount = #presets
	for i, sec in ipairs(presets) do
		local btn = Instance.new("TextButton")
		btn.Name = "Dur" .. tostring(sec)
		btn.AutoButtonColor = false
		btn.Size = UDim2.new(1 / chipCount, -5, 1, 0)
		btn.BackgroundColor3 = COLORS.idle
		btn.BackgroundTransparency = 0.18
		btn.Text = tostring(sec) .. "s"
		btn.TextColor3 = COLORS.muted
		btn.TextSize = if IS_TOUCH then 15 else 14
		btn.FontFace = UiFonts.DISPLAY_FACE
		btn.ZIndex = 4
		btn.LayoutOrder = i
		btn:SetAttribute("DurationSec", sec)
		addCorner(btn, 4)
		addStroke(btn, COLORS.stroke, 1, 0.6)
		btn.Parent = timerRow
		durationBtns[i] = btn
		local picked = sec
		btn.MouseButton1Click:Connect(function()
			durationSec = picked
			paintDuration()
			UIInteractionSounds.playClick()
		end)
	end

	questionHeader = makeSectionLabel(body, "QUESTION", 7)

	local qBox = Instance.new("TextBox")
	qBox.Name = "Question"
	qBox.ClearTextOnFocus = false
	qBox.Size = UDim2.new(1, 0, 0, ROW_H)
	qBox.BackgroundColor3 = COLORS.inputBg
	qBox.Text = ""
	qBox.PlaceholderText = "Ask anything…"
	qBox.PlaceholderColor3 = Color3.fromRGB(120, 100, 96)
	qBox.TextColor3 = COLORS.text
	qBox.TextSize = 16
	qBox.TextXAlignment = Enum.TextXAlignment.Left
	UiFonts.applyInput(qBox)
	qBox.LayoutOrder = 8
	qBox.ZIndex = 4
	addCorner(qBox, 4)
	addStroke(qBox, COLORS.stroke, 1.1, 0.55)
	local qPad = Instance.new("UIPadding")
	qPad.PaddingLeft = UDim.new(0, 12)
	qPad.PaddingRight = UDim.new(0, 12)
	qPad.Parent = qBox
	qBox.Parent = body
	questionBox = qBox

	optionsHeader = makeSectionLabel(body, "OPTIONS  ·  uncheck to hide", 9)

	for i = 1, AdminPollConfig.MAX_OPTIONS do
		local row = Instance.new("Frame")
		row.Name = "Option" .. i
		row.BackgroundColor3 = COLORS.idle
		row.BackgroundTransparency = 0.12
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.LayoutOrder = 9 + i
		row.ZIndex = 3
		addCorner(row, 4)
		addStroke(row, Color3.fromRGB(62, 42, 48), 1, 0.45)
		row.Parent = body

		local toggle = Instance.new("TextButton")
		toggle.Name = "Toggle"
		toggle.AutoButtonColor = false
		toggle.Position = UDim2.fromOffset(8, math.floor((ROW_H - 28) / 2))
		toggle.Size = UDim2.fromOffset(if IS_TOUCH then 32 else 28, if IS_TOUCH then 32 else 28)
		toggle.BackgroundColor3 = COLORS.accent
		toggle.Text = "✓"
		toggle.TextColor3 = Color3.fromRGB(18, 16, 10)
		toggle.TextSize = 16
		toggle.FontFace = UiFonts.DISPLAY_FACE
		toggle.ZIndex = 4
		addCorner(toggle, 4)
		toggle.Parent = row

		local letter = Instance.new("TextLabel")
		letter.BackgroundTransparency = 1
		letter.Position = UDim2.fromOffset(if IS_TOUCH then 46 else 42, 0)
		letter.Size = UDim2.fromOffset(22, ROW_H)
		letter.FontFace = UiFonts.DISPLAY_FACE
		letter.Text = OPTION_LETTERS[i]
		letter.TextColor3 = COLORS.accent
		letter.TextSize = 16
		letter.ZIndex = 4
		letter.Parent = row

		local kindBtn = Instance.new("TextButton")
		kindBtn.Name = "Kind"
		kindBtn.AutoButtonColor = false
		kindBtn.Position = UDim2.fromOffset(if IS_TOUCH then 46 else 42, math.floor((ROW_H - 28) / 2))
		kindBtn.Size = UDim2.fromOffset(if IS_TOUCH then 64 else 62, if IS_TOUCH then 32 else 28)
		kindBtn.BackgroundColor3 = COLORS.inputBg
		kindBtn.Text = "BR"
		kindBtn.TextColor3 = COLORS.accent
		kindBtn.TextSize = 11
		kindBtn.FontFace = UiFonts.DISPLAY_FACE
		kindBtn.Visible = false
		kindBtn.ZIndex = 4
		addCorner(kindBtn, 4)
		addStroke(kindBtn, COLORS.stroke, 1, 0.55)
		kindBtn.Parent = row

		local box = Instance.new("TextBox")
		box.Name = "Text"
		box.ClearTextOnFocus = false
		box.Position = UDim2.fromOffset(if IS_TOUCH then 70 else 66, 6)
		box.Size = UDim2.new(1, if IS_TOUCH then -82 else -78, 1, -12)
		box.BackgroundColor3 = COLORS.inputBg
		box.Text = ""
		box.PlaceholderText = "Option " .. OPTION_LETTERS[i]
		box.PlaceholderColor3 = Color3.fromRGB(120, 100, 96)
		box.TextColor3 = COLORS.text
		box.TextSize = 15
		box.TextXAlignment = Enum.TextXAlignment.Left
		UiFonts.applyInput(box)
		box.ZIndex = 4
		addCorner(box, 4)
		local boxPad = Instance.new("UIPadding")
		boxPad.PaddingLeft = UDim.new(0, 10)
		boxPad.Parent = box
		box.Parent = row

		local entry = {
			enabled = i <= 2,
			toggle = toggle,
			box = box,
			row = row,
			letter = letter,
			kindBtn = kindBtn,
			rewardKind = "brainrot",
		}
		optionRows[i] = entry
		toggle.MouseButton1Click:Connect(function()
			entry.enabled = not entry.enabled
			paintOptionRow(i)
			UIInteractionSounds.playClick()
		end)
		kindBtn.MouseButton1Click:Connect(function()
			local idx = 1
			for k, name in KIND_ORDER do
				if name == entry.rewardKind then
					idx = k
					break
				end
			end
			entry.rewardKind = KIND_ORDER[(idx % #KIND_ORDER) + 1]
			paintOptionRow(i)
			UIInteractionSounds.playClick()
			if UserInputService:GetFocusedTextBox() == box then
				refreshSuggestions(i)
			end
		end)
		box.Focused:Connect(function()
			if pollMode == "reward" and entry.enabled then
				refreshSuggestions(i)
			end
		end)
		box.FocusLost:Connect(function()
			task.delay(0.12, function()
				if UserInputService:GetFocusedTextBox() ~= box then
					if suggestRowIndex == i then
						hideSuggestions()
					end
				end
			end)
		end)
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if pollMode == "reward" and UserInputService:GetFocusedTextBox() == box then
				refreshSuggestions(i)
			end
		end)
		paintOptionRow(i)
	end

	local send = Instance.new("TextButton")
	send.Name = "Send"
	send.AutoButtonColor = false
	send.Size = UDim2.new(1, 0, 0, SEND_H)
	send.BackgroundColor3 = COLORS.accent
	send.Text = "SEND POLL"
	send.TextColor3 = Color3.fromRGB(22, 14, 8)
	send.TextSize = 18
	send.FontFace = UiFonts.DISPLAY_FACE
	send.LayoutOrder = 14
	send.ZIndex = 4
	addCorner(send, 6)
	send.Parent = body
	sendButton = send
	local wired = false
	local okWire, errWire = pcall(function()
		UIButtonEffects.wireScaleButtonAnim(send, sendPoll)
		wired = true
	end)
	if not okWire then
		warn("[AdminPollComposer] send button effects:", errWire)
	end
	if not wired then
		send.MouseButton1Click:Connect(sendPoll)
	end

	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, 0, 0, 18)
	status.FontFace = UiFonts.DISPLAY_FACE
	status.Text = ""
	status.TextColor3 = COLORS.muted
	status.TextSize = 13
	status.LayoutOrder = 15
	status.ZIndex = 3
	status.Parent = body
	statusLabel = status

	local suggest = Instance.new("Frame")
	suggest.Name = "Suggest"
	suggest.BackgroundColor3 = COLORS.panel
	suggest.BorderSizePixel = 0
	suggest.Visible = false
	suggest.ZIndex = 20
	suggest.AutomaticSize = Enum.AutomaticSize.Y
	suggest.Size = UDim2.fromOffset(280, 0)
	addCorner(suggest, 4)
	addStroke(suggest, COLORS.stroke, 1.2, 0.4)
	local suggestList = Instance.new("UIListLayout")
	suggestList.FillDirection = Enum.FillDirection.Vertical
	suggestList.SortOrder = Enum.SortOrder.LayoutOrder
	suggestList.Padding = UDim.new(0, 2)
	suggestList.Parent = suggest
	local suggestPad = Instance.new("UIPadding")
	suggestPad.PaddingTop = UDim.new(0, 4)
	suggestPad.PaddingBottom = UDim.new(0, 4)
	suggestPad.PaddingLeft = UDim.new(0, 4)
	suggestPad.PaddingRight = UDim.new(0, 4)
	suggestPad.Parent = suggest
	for i = 1, SUGGEST_COUNT do
		local btn = Instance.new("TextButton")
		btn.Name = "Hit" .. i
		btn.AutoButtonColor = false
		btn.BackgroundColor3 = COLORS.idle
		btn.Size = UDim2.new(1, 0, 0, if IS_TOUCH then 36 else 28)
		btn.Text = ""
		btn.TextColor3 = COLORS.text
		btn.TextSize = 13
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.FontFace = UiFonts.DISPLAY_FACE
		btn.Visible = false
		btn.ZIndex = 21
		addCorner(btn, 3)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.Parent = btn
		btn.Parent = suggest
		suggestButtons[i] = btn
		local captured = i
		btn.MouseButton1Click:Connect(function()
			local item = suggestMatches[captured]
			local row = optionRows[suggestRowIndex]
			if item and row then
				row.box.Text = item.fill
				row.box.CursorPosition = #item.fill + 1
				hideSuggestions()
				UIInteractionSounds.playClick()
			end
		end)
	end
	suggest.Parent = screen
	suggestPanel = suggest

	panel.Parent = screen
	screen.Parent = parent
	gui = screen
	root = panel
	rootScale = scale
	paintScope()
	paintDuration()
	paintMode()
end

function AdminPollComposer.open(mode: string?)
	if not initialized then
		AdminPollComposer.init()
	end
	if not isAdmin() then
		return
	end
	pollMode = if mode == "reward" then "reward" else "question"
	paintMode()
	setOpen(true)
end

function AdminPollComposer.close()
	setOpen(false)
end

function AdminPollComposer.init()
	if initialized then
		return
	end
	initialized = true
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[AdminPollComposer] PlayerGui missing")
		return
	end
	buildGui(playerGui)
end

return AdminPollComposer
