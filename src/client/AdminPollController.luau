-- [ACTIVE] AdminPollController
--[[
	Live poll HUD for everyone. Chunky HUD style: thick black outlines,
	bubbly option cards, and count-up bars like the level / quest meters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local AdminPollConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminPollConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local player = Players.LocalPlayer
local IS_TOUCH = UserInputService.TouchEnabled

-- Sell green, My Base blue, Upgrade orange, quest gold.
local OPTION_COLORS = {
	Color3.fromRGB(72, 210, 92),
	Color3.fromRGB(48, 168, 255),
	Color3.fromRGB(255, 148, 42),
	Color3.fromRGB(255, 214, 64),
}
local OPTION_SHADES = {
	Color3.fromRGB(28, 92, 42),
	Color3.fromRGB(22, 72, 128),
	Color3.fromRGB(128, 68, 18),
	Color3.fromRGB(128, 96, 18),
}
local LETTERS = { "A", "B", "C", "D" }
local ROW_H = if IS_TOUCH then 70 else 62
local BAR_H = if IS_TOUCH then 14 else 12

local COUNT_TWEEN = TweenInfo.new(0.62, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BAR_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local POP_IN = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local AdminPollController = {}

type OptionRow = {
	root: TextButton,
	fill: Frame,
	label: TextLabel,
	count: TextLabel,
	percent: TextLabel,
	letter: TextLabel,
	stroke: UIStroke,
	scale: UIScale,
	countValue: NumberValue,
	countTween: Tween?,
	barTween: Tween?,
	countConn: RBXScriptConnection?,
}

local gui: ScreenGui? = nil
local root: Frame? = nil
local rootScale: UIScale? = nil
local questionLabel: TextLabel? = nil
local metaLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local timerPill: Frame? = nil
local hintLabel: TextLabel? = nil
local rows: { OptionRow } = {}
local timerConn: RBXScriptConnection? = nil
local startConn: RBXScriptConnection? = nil
local updateConn: RBXScriptConnection? = nil
local pollId: string? = nil
local optionCount = 0
local myVote: number? = nil
local endsAt = 0
local lastCounts: { number } = { 0, 0, 0, 0 }
local hideToken = 0
local initialized = false

local function getRemote(name: string): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild(name)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function waitForRemote(name: string, timeoutSec: number): RemoteEvent?
	local ev = getRemote(name)
	if ev then
		return ev
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes", timeoutSec)
	if not remotes then
		return nil
	end
	local found = remotes:WaitForChild(name, timeoutSec)
	if found and found:IsA("RemoteEvent") then
		return found
	end
	return nil
end

local function disconnectTimer()
	if timerConn then
		timerConn:Disconnect()
		timerConn = nil
	end
end

local function addCorner(guiObj: GuiObject, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = guiObj
end

local function addBlackStroke(guiObj: GuiObject, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(12, 10, 16)
	s.Thickness = thickness
	s.Transparency = 0
	s.Parent = guiObj
	return s
end

local function outlineText(guiObj: TextLabel | TextButton, thickness: number)
	guiObj.TextColor3 = Color3.fromRGB(255, 255, 255)
	guiObj.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	guiObj.TextStrokeTransparency = 0
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(0, 0, 0)
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = guiObj
end

local function formatRemain(sec: number): string
	return string.format("%ds", math.max(0, math.ceil(sec)))
end

local function paintVoteHighlight()
	for i, row in rows do
		local chosen = myVote == i
		row.stroke.Color = Color3.fromRGB(12, 10, 16)
		row.stroke.Thickness = if chosen then 5 else 3.4
		row.stroke.Transparency = 0
		row.root.BackgroundColor3 = if chosen then OPTION_COLORS[i] else OPTION_SHADES[i]
	end
end

local function setCountText(row: OptionRow, value: number)
	row.count.Text = tostring(math.max(0, math.floor(value + 0.5)))
end

local function tweenCount(row: OptionRow, target: number)
	if row.countTween then
		row.countTween:Cancel()
		row.countTween = nil
	end
	local tw = TweenService:Create(row.countValue, COUNT_TWEEN, { Value = target })
	row.countTween = tw
	tw:Play()
	if row.scale then
		row.scale.Scale = 1.18
		TweenService:Create(row.scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end
end

local function tweenBar(row: OptionRow, pct: number)
	if row.barTween then
		row.barTween:Cancel()
		row.barTween = nil
	end
	row.barTween = TweenService:Create(row.fill, BAR_TWEEN, {
		Size = UDim2.fromScale(math.clamp(pct, 0, 1), 1),
	})
	row.barTween:Play()
end

local function applyCounts(counts: { number }, total: number)
	local n = optionCount
	for i = 1, 4 do
		local row = rows[i]
		if i > n then
			continue
		end
		local votes = counts[i] or 0
		lastCounts[i] = votes
		tweenCount(row, votes)
		local pct = if total > 0 then votes / total else 0
		tweenBar(row, pct)
		row.percent.Text = if total > 0 then string.format("%d%%", math.floor(pct * 100 + 0.5)) else "0%"
	end
	if hintLabel then
		hintLabel.Text = if total == 1 then "1 vote" else string.format("%d votes", total)
	end
end

local function hideHud()
	hideToken += 1
	disconnectTimer()
	pollId = nil
	myVote = nil
	endsAt = 0
	if root then
		root.Visible = false
	end
	if gui then
		gui.Enabled = false
	end
end

local function finishPoll()
	local best = 1
	local bestVotes = -1
	for i = 1, optionCount do
		if (lastCounts[i] or 0) > bestVotes then
			bestVotes = lastCounts[i] or 0
			best = i
		end
	end
	for i, row in rows do
		if i > optionCount then
			continue
		end
		if i == best then
			row.root.BackgroundColor3 = OPTION_COLORS[i]
			row.stroke.Thickness = 5
			row.scale.Scale = 1.08
			TweenService:Create(row.scale, TweenInfo.new(0.4, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		else
			row.root.BackgroundColor3 = OPTION_SHADES[i]:Lerp(Color3.fromRGB(20, 18, 24), 0.45)
			row.fill.BackgroundTransparency = 0.35
		end
	end
	if hintLabel then
		hintLabel.Text = "Winner · " .. (rows[best] and rows[best].label.Text or LETTERS[best])
	end
	if timerLabel then
		timerLabel.Text = "DONE"
		timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
	if timerPill then
		timerPill.BackgroundColor3 = OPTION_COLORS[best]
	end
	local token = hideToken
	task.delay(AdminPollConfig.END_HOLD_SEC, function()
		if token == hideToken then
			hideHud()
		end
	end)
end

local function startTimer()
	disconnectTimer()
	timerConn = RunService.Heartbeat:Connect(function()
		if not pollId then
			disconnectTimer()
			return
		end
		local remain = endsAt - Workspace:GetServerTimeNow()
		if timerLabel then
			if remain <= 0 then
				timerLabel.Text = "0s"
			else
				timerLabel.Text = formatRemain(remain)
			end
		end
		if timerPill then
			if remain <= 0 then
				timerPill.BackgroundColor3 = Color3.fromRGB(255, 92, 92)
			elseif remain <= 8 then
				timerPill.BackgroundColor3 = Color3.fromRGB(255, 168, 48)
			else
				timerPill.BackgroundColor3 = Color3.fromRGB(255, 214, 64)
			end
		end
		if remain <= 0 then
			disconnectTimer()
			finishPoll()
		end
	end)
end

local function vote(index: number)
	if not pollId then
		return
	end
	if Workspace:GetServerTimeNow() >= endsAt then
		return
	end
	if index < 1 or index > optionCount then
		return
	end
	local ev = getRemote(AdminPollConfig.VOTE_REMOTE)
	if not ev then
		return
	end
	myVote = index
	paintVoteHighlight()
	UIInteractionSounds.playClick()
	ev:FireServer(pollId, index)
end

local function showPoll(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.id) ~= "string" or typeof(payload.question) ~= "string" then
		return
	end
	if typeof(payload.options) ~= "table" then
		return
	end
	hideToken += 1
	disconnectTimer()
	pollId = payload.id
	myVote = nil
	endsAt = if typeof(payload.endsAt) == "number" then payload.endsAt else Workspace:GetServerTimeNow() + AdminPollConfig.DURATION_SEC
	optionCount = math.clamp(#payload.options, 0, 4)
	if optionCount < 2 then
		return
	end

	if questionLabel then
		questionLabel.Text = payload.question
	end
	if metaLabel then
		local scope = if payload.scope == "global" then "ALL SERVERS" else "THIS SERVER"
		metaLabel.Text = "POLL  ·  " .. scope
	end
	if hintLabel then
		hintLabel.Text = "Tap an option"
	end
	if timerPill then
		timerPill.BackgroundColor3 = Color3.fromRGB(255, 214, 64)
	end

	for i = 1, 4 do
		local row = rows[i]
		local on = i <= optionCount
		row.root.Visible = on
		row.root.BackgroundColor3 = OPTION_SHADES[i]
		row.fill.BackgroundTransparency = 0
		row.fill.Size = UDim2.fromScale(0, 1)
		row.countValue.Value = 0
		setCountText(row, 0)
		row.percent.Text = "0%"
		row.scale.Scale = 0.86
		row.stroke.Thickness = 3.4
		if on then
			row.label.Text = tostring(payload.options[i])
			lastCounts[i] = 0
			task.delay(0.06 * i, function()
				if pollId == payload.id then
					TweenService:Create(row.scale, POP_IN, { Scale = 1 }):Play()
				end
			end)
		end
	end
	paintVoteHighlight()

	if gui then
		gui.Enabled = true
	end
	if root then
		root.Visible = true
	end
	if rootScale then
		rootScale.Scale = 0.9
		TweenService:Create(rootScale, POP_IN, { Scale = 1 }):Play()
	end

	local counts = payload.counts
	local total = if typeof(payload.total) == "number" then payload.total else 0
	if typeof(counts) == "table" then
		applyCounts(counts, total)
	end
	startTimer()
end

local function onUpdate(payload: any)
	if typeof(payload) ~= "table" or payload.id ~= pollId then
		return
	end
	if typeof(payload.counts) ~= "table" then
		return
	end
	local total = if typeof(payload.total) == "number" then payload.total else 0
	applyCounts(payload.counts, total)
end

local function buildHud(parent: PlayerGui)
	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminPollHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 88
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local panel = Instance.new("Frame")
	panel.Name = "Root"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	-- Sit under Sell / My Base / Upgrade.
	panel.Position = UDim2.new(0.5, 0, 0, if IS_TOUCH then 108 else 124)
	if IS_TOUCH then
		panel.Size = UDim2.new(0.92, 0, 0, 0)
	else
		panel.Size = UDim2.fromOffset(460, 0)
	end
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(28, 24, 36)
	panel.BackgroundTransparency = 0.04
	panel.BorderSizePixel = 0
	panel.Visible = false
	addCorner(panel, 14)
	addBlackStroke(panel, 4)
	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(480, 4000)
	maxWidth.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Name = "AnimScale"
	scale.Parent = panel

	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, if IS_TOUCH then 34 else 30)
	header.LayoutOrder = 1
	header.Parent = panel
	local meta = Instance.new("TextLabel")
	meta.BackgroundTransparency = 1
	meta.Size = UDim2.new(1, -88, 1, 0)
	meta.FontFace = UiFonts.DISPLAY_FACE
	meta.Text = "POLL"
	meta.TextSize = if IS_TOUCH then 16 else 15
	meta.TextXAlignment = Enum.TextXAlignment.Left
	outlineText(meta, 2)
	meta.Parent = header

	local pill = Instance.new("Frame")
	pill.Name = "TimerPill"
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.new(1, 0, 0.5, 0)
	pill.Size = UDim2.fromOffset(if IS_TOUCH then 78 else 70, if IS_TOUCH then 30 else 26)
	pill.BackgroundColor3 = Color3.fromRGB(255, 214, 64)
	pill.BorderSizePixel = 0
	addCorner(pill, 10)
	addBlackStroke(pill, 3)
	pill.Parent = header
	local timer = Instance.new("TextLabel")
	timer.BackgroundTransparency = 1
	timer.Size = UDim2.fromScale(1, 1)
	timer.FontFace = UiFonts.DISPLAY_FACE
	timer.Text = "45s"
	timer.TextSize = if IS_TOUCH then 16 else 15
	outlineText(timer, 2)
	timer.Parent = pill

	local question = Instance.new("TextLabel")
	question.BackgroundTransparency = 1
	question.Size = UDim2.new(1, 0, 0, 28)
	question.AutomaticSize = Enum.AutomaticSize.Y
	question.FontFace = UiFonts.DISPLAY_FACE
	question.Text = ""
	question.TextSize = if IS_TOUCH then 22 else 20
	question.TextWrapped = true
	question.TextXAlignment = Enum.TextXAlignment.Left
	question.LayoutOrder = 2
	outlineText(question, 2.2)
	question.Parent = panel

	for i = 1, 4 do
		local color = OPTION_COLORS[i]
		local btn = Instance.new("TextButton")
		btn.Name = "Option" .. i
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.BackgroundColor3 = OPTION_SHADES[i]
		btn.BorderSizePixel = 0
		btn.Size = UDim2.new(1, 0, 0, ROW_H)
		btn.LayoutOrder = 2 + i
		btn.ClipsDescendants = true
		addCorner(btn, 12)
		local rowStroke = addBlackStroke(btn, 3.4)

		local gloss = Instance.new("UIGradient")
		gloss.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(220, 220, 220)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 160, 160)),
		})
		gloss.Rotation = 90
		gloss.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.72),
			NumberSequenceKeypoint.new(1, 0.92),
		})
		gloss.Parent = btn

		local letterBadge = Instance.new("Frame")
		letterBadge.BackgroundColor3 = color
		letterBadge.BorderSizePixel = 0
		letterBadge.Position = UDim2.fromOffset(8, 8)
		letterBadge.Size = UDim2.fromOffset(28, 28)
		letterBadge.ZIndex = 2
		addCorner(letterBadge, 8)
		addBlackStroke(letterBadge, 2.4)
		letterBadge.Parent = btn
		local letter = Instance.new("TextLabel")
		letter.BackgroundTransparency = 1
		letter.Size = UDim2.fromScale(1, 1)
		letter.FontFace = UiFonts.DISPLAY_FACE
		letter.Text = LETTERS[i]
		letter.TextSize = 16
		letter.ZIndex = 3
		outlineText(letter, 1.8)
		letter.Parent = letterBadge

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(44, 4)
		label.Size = UDim2.new(1, -130, 0, 26)
		label.FontFace = UiFonts.DISPLAY_FACE
		label.Text = ""
		label.TextSize = if IS_TOUCH then 17 else 16
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.ZIndex = 2
		outlineText(label, 1.8)
		label.Parent = btn

		local percent = Instance.new("TextLabel")
		percent.BackgroundTransparency = 1
		percent.Position = UDim2.fromOffset(44, 30)
		percent.Size = UDim2.new(0.4, 0, 0, 14)
		percent.FontFace = UiFonts.DISPLAY_FACE
		percent.Text = "0%"
		percent.TextSize = 12
		percent.TextXAlignment = Enum.TextXAlignment.Left
		percent.ZIndex = 2
		outlineText(percent, 1.4)
		percent.Parent = btn

		local count = Instance.new("TextLabel")
		count.BackgroundTransparency = 1
		count.AnchorPoint = Vector2.new(1, 0)
		count.Position = UDim2.new(1, -10, 0, 4)
		count.Size = UDim2.fromOffset(72, 32)
		count.FontFace = UiFonts.DISPLAY_FACE
		count.Text = "0"
		count.TextSize = if IS_TOUCH then 28 else 26
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.ZIndex = 3
		outlineText(count, 2.4)
		count.Parent = btn
		local countScale = Instance.new("UIScale")
		countScale.Parent = count

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.AnchorPoint = Vector2.new(0, 1)
		track.Position = UDim2.new(0, 8, 1, -8)
		track.Size = UDim2.new(1, -16, 0, BAR_H)
		track.BackgroundColor3 = Color3.fromRGB(12, 10, 16)
		track.BorderSizePixel = 0
		track.ZIndex = 2
		addCorner(track, 6)
		addBlackStroke(track, 2)
		track.Parent = btn

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = color
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(0, 1)
		fill.ZIndex = 3
		addCorner(fill, 6)
		fill.Parent = track

		local nv = Instance.new("NumberValue")
		nv.Name = "DisplayCount"
		nv.Value = 0
		nv.Parent = btn
		local countConn = nv.Changed:Connect(function(v)
			count.Text = tostring(math.max(0, math.floor(v + 0.5)))
		end)

		btn.Parent = panel
		local index = i
		btn.MouseButton1Click:Connect(function()
			vote(index)
		end)

		rows[i] = {
			root = btn,
			fill = fill,
			label = label,
			count = count,
			percent = percent,
			letter = letter,
			stroke = rowStroke,
			scale = countScale,
			countValue = nv,
			countTween = nil,
			barTween = nil,
			countConn = countConn,
		}
	end

	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Size = UDim2.new(1, 0, 0, 18)
	hint.FontFace = UiFonts.DISPLAY_FACE
	hint.Text = "Tap an option"
	hint.TextSize = 13
	hint.LayoutOrder = 8
	outlineText(hint, 1.6)
	hint.Parent = panel

	panel.Parent = screen
	screen.Parent = parent
	gui = screen
	root = panel
	rootScale = scale
	questionLabel = question
	metaLabel = meta
	timerLabel = timer
	timerPill = pill
	hintLabel = hint
end

function AdminPollController.init()
	if initialized then
		return
	end
	initialized = true
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[AdminPollController] PlayerGui missing")
		return
	end
	buildHud(playerGui)

	task.spawn(function()
		local startRE = waitForRemote(AdminPollConfig.START_REMOTE, 30)
		local updateRE = waitForRemote(AdminPollConfig.UPDATE_REMOTE, 30)
		if startRE then
			startConn = startRE.OnClientEvent:Connect(function(payload)
				showPoll(payload)
			end)
		else
			warn("[AdminPollController] start remote missing")
		end
		if updateRE then
			updateConn = updateRE.OnClientEvent:Connect(function(payload)
				onUpdate(payload)
			end)
		else
			warn("[AdminPollController] update remote missing")
		end
	end)
end

return AdminPollController
