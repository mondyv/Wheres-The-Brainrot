-- [ACTIVE] AdminPollComposer
--[[
	Admin-only poll builder. Opened by the `polls` command.
	Unchecked option rows are omitted (2–4 answers).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AdminPollConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminPollConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local COLORS = {
	panel = Color3.fromRGB(14, 18, 26),
	panelTop = Color3.fromRGB(24, 32, 46),
	accent = Color3.fromRGB(255, 214, 96),
	inputBg = Color3.fromRGB(10, 14, 20),
	idle = Color3.fromRGB(28, 36, 48),
	text = Color3.fromRGB(245, 250, 255),
	muted = Color3.fromRGB(150, 165, 185),
	stroke = Color3.fromRGB(48, 58, 72),
	success = Color3.fromRGB(140, 210, 165),
	danger = Color3.fromRGB(255, 95, 110),
	server = Color3.fromRGB(110, 190, 255),
	global = Color3.fromRGB(255, 168, 82),
}

local OPTION_LETTERS = { "A", "B", "C", "D" }

local AdminPollComposer = {}

local gui: ScreenGui? = nil
local root: Frame? = nil
local rootScale: UIScale? = nil
local questionBox: TextBox? = nil
local statusLabel: TextLabel? = nil
local sendButton: TextButton? = nil
local serverBtn: TextButton? = nil
local globalBtn: TextButton? = nil
local scope: "server" | "global" = "server"
local optionRows: {
	{
		enabled: boolean,
		toggle: TextButton,
		box: TextBox,
		row: Frame,
	}
} = {}
local sending = false
local closeToken = 0
local initialized = false

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
		serverBtn.BackgroundTransparency = if on then 0.12 else 0.35
		serverBtn.TextColor3 = if on then Color3.fromRGB(8, 16, 28) else COLORS.muted
	end
	if globalBtn then
		local on = scope == "global"
		globalBtn.BackgroundColor3 = if on then COLORS.global else COLORS.idle
		globalBtn.BackgroundTransparency = if on then 0.08 else 0.35
		globalBtn.TextColor3 = if on then Color3.fromRGB(28, 14, 6) else COLORS.muted
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
	row.row.BackgroundTransparency = if row.enabled then 0.28 else 0.55
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
		setStatus("Uncheck a row to drop that option.", nil)
		task.defer(function()
			if questionBox and gui and gui.Enabled then
				questionBox:CaptureFocus()
			end
		end)
	else
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
	task.spawn(function()
		local ok, response = pcall(function()
			return rf:InvokeServer({
				question = q,
				options = options,
				scope = scope,
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
	panel.Size = UDim2.fromOffset(520, 560)
	panel.BackgroundColor3 = COLORS.panel
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	addCorner(panel, 16)
	addStroke(panel, COLORS.stroke, 1.4, 0.25)
	local scale = Instance.new("UIScale")
	scale.Name = "AnimScale"
	scale.Scale = 1
	scale.Parent = panel
	if UserInputService.TouchEnabled then
		scale.Scale = 0.92
		panel.Size = UDim2.fromOffset(500, 580)
	end

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundColor3 = COLORS.panelTop
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, 0, 0, 56)
	header.ZIndex = 3
	addCorner(header, 16)
	header.Parent = panel
	local headerClip = Instance.new("Frame")
	headerClip.BackgroundColor3 = COLORS.panelTop
	headerClip.BorderSizePixel = 0
	headerClip.Position = UDim2.new(0, 0, 1, -16)
	headerClip.Size = UDim2.new(1, 0, 0, 16)
	headerClip.ZIndex = 3
	headerClip.Parent = header
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(22, 0)
	title.Size = UDim2.new(1, -80, 1, 0)
	title.FontFace = UiFonts.DISPLAY_FACE
	title.Text = "CREATE POLL"
	title.TextColor3 = COLORS.accent
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 4
	title.Parent = header
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AutoButtonColor = false
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -16, 0.5, 0)
	close.Size = UDim2.fromOffset(32, 32)
	close.BackgroundColor3 = COLORS.idle
	close.Text = "X"
	close.TextColor3 = COLORS.text
	close.TextSize = 16
	close.ZIndex = 4
	addCorner(close, 8)
	close.Parent = header
	close.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(20, 68)
	body.Size = UDim2.new(1, -40, 1, -86)
	body.ZIndex = 3
	body.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body

	local scopeLabel = Instance.new("TextLabel")
	scopeLabel.BackgroundTransparency = 1
	scopeLabel.Size = UDim2.new(1, 0, 0, 16)
	scopeLabel.FontFace = UiFonts.DISPLAY_FACE
	scopeLabel.Text = "SCOPE"
	scopeLabel.TextColor3 = COLORS.muted
	scopeLabel.TextSize = 12
	scopeLabel.TextXAlignment = Enum.TextXAlignment.Left
	scopeLabel.LayoutOrder = 1
	scopeLabel.ZIndex = 3
	scopeLabel.Parent = body

	local scopeRow = Instance.new("Frame")
	scopeRow.BackgroundTransparency = 1
	scopeRow.Size = UDim2.new(1, 0, 0, 40)
	scopeRow.LayoutOrder = 2
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
		btn.BackgroundTransparency = 0.35
		btn.Text = labelText
		btn.TextColor3 = COLORS.muted
		btn.TextSize = 15
		btn.FontFace = UiFonts.DISPLAY_FACE
		btn.ZIndex = 4
		addCorner(btn, 10)
		addStroke(btn, COLORS.stroke, 1.1, 0.35)
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

	local qLabel = Instance.new("TextLabel")
	qLabel.BackgroundTransparency = 1
	qLabel.Size = UDim2.new(1, 0, 0, 16)
	qLabel.FontFace = UiFonts.DISPLAY_FACE
	qLabel.Text = "QUESTION"
	qLabel.TextColor3 = COLORS.muted
	qLabel.TextSize = 12
	qLabel.TextXAlignment = Enum.TextXAlignment.Left
	qLabel.LayoutOrder = 3
	qLabel.ZIndex = 3
	qLabel.Parent = body

	local qBox = Instance.new("TextBox")
	qBox.Name = "Question"
	qBox.ClearTextOnFocus = false
	qBox.Size = UDim2.new(1, 0, 0, 44)
	qBox.BackgroundColor3 = COLORS.inputBg
	qBox.Text = ""
	qBox.PlaceholderText = "Ask anything…"
	qBox.PlaceholderColor3 = Color3.fromRGB(90, 102, 118)
	qBox.TextColor3 = COLORS.text
	qBox.TextSize = 16
	qBox.TextXAlignment = Enum.TextXAlignment.Left
	qBox.FontFace = UiFonts.DISPLAY_FACE
	qBox.LayoutOrder = 4
	qBox.ZIndex = 4
	addCorner(qBox, 10)
	addStroke(qBox, COLORS.stroke, 1.1, 0.3)
	local qPad = Instance.new("UIPadding")
	qPad.PaddingLeft = UDim.new(0, 12)
	qPad.PaddingRight = UDim.new(0, 12)
	qPad.Parent = qBox
	qBox.Parent = body
	questionBox = qBox

	local oLabel = Instance.new("TextLabel")
	oLabel.BackgroundTransparency = 1
	oLabel.Size = UDim2.new(1, 0, 0, 16)
	oLabel.FontFace = UiFonts.DISPLAY_FACE
	oLabel.Text = "OPTIONS  ·  uncheck to hide"
	oLabel.TextColor3 = COLORS.muted
	oLabel.TextSize = 12
	oLabel.TextXAlignment = Enum.TextXAlignment.Left
	oLabel.LayoutOrder = 5
	oLabel.ZIndex = 3
	oLabel.Parent = body

	for i = 1, AdminPollConfig.MAX_OPTIONS do
		local row = Instance.new("Frame")
		row.Name = "Option" .. i
		row.BackgroundColor3 = COLORS.idle
		row.BackgroundTransparency = 0.28
		row.Size = UDim2.new(1, 0, 0, 44)
		row.LayoutOrder = 5 + i
		row.ZIndex = 3
		addCorner(row, 10)
		addStroke(row, COLORS.stroke, 1, 0.4)
		row.Parent = body

		local toggle = Instance.new("TextButton")
		toggle.Name = "Toggle"
		toggle.AutoButtonColor = false
		toggle.Position = UDim2.fromOffset(8, 8)
		toggle.Size = UDim2.fromOffset(28, 28)
		toggle.BackgroundColor3 = COLORS.accent
		toggle.Text = "✓"
		toggle.TextColor3 = Color3.fromRGB(18, 16, 10)
		toggle.TextSize = 16
		toggle.FontFace = UiFonts.DISPLAY_FACE
		toggle.ZIndex = 4
		addCorner(toggle, 7)
		toggle.Parent = row

		local letter = Instance.new("TextLabel")
		letter.BackgroundTransparency = 1
		letter.Position = UDim2.fromOffset(42, 0)
		letter.Size = UDim2.fromOffset(22, 44)
		letter.FontFace = UiFonts.DISPLAY_FACE
		letter.Text = OPTION_LETTERS[i]
		letter.TextColor3 = COLORS.accent
		letter.TextSize = 16
		letter.ZIndex = 4
		letter.Parent = row

		local box = Instance.new("TextBox")
		box.Name = "Text"
		box.ClearTextOnFocus = false
		box.Position = UDim2.fromOffset(66, 6)
		box.Size = UDim2.new(1, -78, 1, -12)
		box.BackgroundColor3 = COLORS.inputBg
		box.Text = ""
		box.PlaceholderText = "Option " .. OPTION_LETTERS[i]
		box.PlaceholderColor3 = Color3.fromRGB(90, 102, 118)
		box.TextColor3 = COLORS.text
		box.TextSize = 15
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.FontFace = UiFonts.DISPLAY_FACE
		box.ZIndex = 4
		addCorner(box, 8)
		local boxPad = Instance.new("UIPadding")
		boxPad.PaddingLeft = UDim.new(0, 10)
		boxPad.Parent = box
		box.Parent = row

		local entry = {
			enabled = i <= 2,
			toggle = toggle,
			box = box,
			row = row,
		}
		optionRows[i] = entry
		toggle.MouseButton1Click:Connect(function()
			entry.enabled = not entry.enabled
			paintOptionRow(i)
			UIInteractionSounds.playClick()
		end)
		paintOptionRow(i)
	end

	local send = Instance.new("TextButton")
	send.Name = "Send"
	send.AutoButtonColor = false
	send.Size = UDim2.new(1, 0, 0, 46)
	send.BackgroundColor3 = COLORS.accent
	send.Text = "SEND POLL"
	send.TextColor3 = Color3.fromRGB(22, 18, 8)
	send.TextSize = 18
	send.FontFace = UiFonts.DISPLAY_FACE
	send.LayoutOrder = 12
	send.ZIndex = 4
	addCorner(send, 12)
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
	status.LayoutOrder = 13
	status.ZIndex = 3
	status.Parent = body
	statusLabel = status

	panel.Parent = screen
	screen.Parent = parent
	gui = screen
	root = panel
	rootScale = scale
	paintScope()
end

function AdminPollComposer.open()
	if not initialized then
		AdminPollComposer.init()
	end
	if not isAdmin() then
		return
	end
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
