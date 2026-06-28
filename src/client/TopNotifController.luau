-- [ACTIVE] TopNotifController
--[[
	SideUI.Top.Notif toasts — rarity spawns, admin broadcasts, error feedback.
	Uses the existing Notif UI (single banner) with pop + fade animations.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local RaritySpawnStyle = require(script.Parent.RaritySpawnStyle)

local player = Players.LocalPlayer

local POP_IN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TEXT_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local ERROR_ACCENT = Color3.fromRGB(255, 72, 72)
local ERROR_TEXT_STROKE = Color3.fromRGB(0, 0, 0)
local DISPLAY_LIFETIME = 10
local ERROR_LIFETIME = 3.5
local ERROR_COOLDOWN = 0.35
local CANT_AFFORD_MESSAGE = "You can't afford this!"

local TopNotifController = {}

type QueuedMessage = {
	message: string,
	isError: boolean,
	rarityId: string?,
}

local host: GuiObject? = nil
local animHost: GuiObject? = nil
local label: TextLabel? = nil
local panelStroke: UIStroke? = nil
local labelStroke: UIStroke? = nil
local animScale: UIScale? = nil
local cachedStrokes: { UIStroke } = {}
local savedLabelStrokeThickness: number? = nil
local savedPanelStrokeTransparency: number? = nil
local savedTextStrokeTransparency: number = 1
local messageQueue: { QueuedMessage } = {}
local isShowing = false
local hideToken = 0
local activeFadeTween: Tween? = nil
local lastErrorAt = 0
local broadcastConn: RBXScriptConnection? = nil
local defaultPanelStrokeColor: Color3? = nil

local function globalMessagesEnabled(): boolean
	return player:GetAttribute(PlayerDataSchema.SETTINGS_GLOBAL_MESSAGES_ATTR) ~= false
end

local function getOrAddAnimScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChild("NotifAnimScale")
	if s and s:IsA("UIScale") then
		return s
	end
	s = Instance.new("UIScale")
	s.Name = "NotifAnimScale"
	s.Scale = 1
	s.Parent = obj
	return s
end

local function prepareNotifLabel(textLabel: TextLabel)
	textLabel.BackgroundTransparency = 1
	textLabel.BorderSizePixel = 0
	textLabel.Rotation = 0
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIScale") then
			child:Destroy()
		elseif child:IsA("UIGradient") then
			child.Enabled = false
			child.Offset = Vector2.new(0, 0)
		elseif child:IsA("UIStroke") then
			child.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			child.Thickness = math.clamp(child.Thickness, 1, 2.5)
		end
	end
end

local function cacheStrokes(root: Instance)
	table.clear(cachedStrokes)
	for _, desc in root:GetDescendants() do
		if desc:IsA("UIStroke") then
			table.insert(cachedStrokes, desc)
		end
	end
	local hostStroke = root:FindFirstChildOfClass("UIStroke")
	if hostStroke and hostStroke.Parent == root then
		local found = false
		for _, stroke in cachedStrokes do
			if stroke == hostStroke then
				found = true
				break
			end
		end
		if not found then
			table.insert(cachedStrokes, hostStroke)
		end
	end
end

-- Only the panel outline + the text outline are ours to toggle. Enabling every descendant UIStroke
-- (decorative inner frames) drew extra rectangular outlines behind the text — the "outline background" bug.
local function setManagedStrokesEnabled(enabled: boolean)
	if panelStroke and panelStroke.Parent then
		panelStroke.Enabled = enabled
	end
	if labelStroke and labelStroke.Parent then
		labelStroke.Enabled = enabled
	end
end

-- Force every other (decorative) stroke off so rarity styling never lights up inner-frame outlines.
local function disableDecorativeStrokes()
	for _, stroke in cachedStrokes do
		if stroke.Parent and stroke ~= panelStroke and stroke ~= labelStroke then
			stroke.Enabled = false
		end
	end
end

local function prepareNotifHost(notif: GuiObject)
	if notif:IsA("GuiObject") then
		notif.BackgroundTransparency = 1
		notif.BorderSizePixel = 0
	end
	for _, desc in notif:GetDescendants() do
		if desc:IsA("Frame") or desc:IsA("ImageLabel") then
			desc.BackgroundTransparency = 1
			desc.BorderSizePixel = 0
		end
	end
	local directStroke = notif:FindFirstChildOfClass("UIStroke")
	if directStroke then
		savedPanelStrokeTransparency = directStroke.Transparency
	end
	cacheStrokes(notif)
end

local function findParts()
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main:FindFirstChild("SideUI")
	local top = sideUI and sideUI:FindFirstChild("Top")
	local notif = top and top:FindFirstChild("Notif")
	if not notif or not notif:IsA("GuiObject") then
		return
	end
	host = notif :: GuiObject
	animHost = (notif:FindFirstChildWhichIsA("Frame") or notif) :: GuiObject
	animScale = getOrAddAnimScale(animHost)
	prepareNotifHost(host)

	panelStroke = host:FindFirstChildOfClass("UIStroke")
	if panelStroke then
		defaultPanelStrokeColor = panelStroke.Color
	end

	local text = notif:FindFirstChild("Text", true)
	if text and text:IsA("TextLabel") then
		label = text
		savedTextStrokeTransparency = label.TextStrokeTransparency
		prepareNotifLabel(label)
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			labelStroke = stroke
			savedLabelStrokeThickness = stroke.Thickness
		end
	end
end

local function ensureBlackTextOutline()
	if not labelStroke then
		return
	end
	labelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	labelStroke.Color = Color3.fromRGB(0, 0, 0)
	if savedLabelStrokeThickness then
		labelStroke.Thickness = savedLabelStrokeThickness
	end
	local grad = labelStroke:FindFirstChild("RaritySpawnGradient")
	if grad and grad:IsA("UIGradient") then
		grad.Enabled = false
	end
end

local function disableOtherGradients(textLabel: TextLabel, keepName: string)
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIGradient") and child.Name ~= keepName then
			child.Enabled = false
		end
	end
end

local function setPanelAccent(color: Color3, rarityId: string?)
	if not panelStroke then
		return
	end
	panelStroke.Color = color
	local grad = panelStroke:FindFirstChild("RaritySpawnGradient")
	if rarityId then
		if not grad or not grad:IsA("UIGradient") then
			grad = Instance.new("UIGradient")
			grad.Name = "RaritySpawnGradient"
			grad.Parent = panelStroke
		end
		(grad :: UIGradient).Color = RaritySpawnStyle.colorSequence(rarityId);
		(grad :: UIGradient).Rotation = 90
		(grad :: UIGradient).Enabled = true
	elseif grad and grad:IsA("UIGradient") then
		grad.Enabled = false
	end
end

local function applyRarityPanelStyle(rarityId: string)
	if not panelStroke then
		return
	end
	panelStroke.Transparency = savedPanelStrokeTransparency or 0
	setPanelAccent(Color3.fromRGB(255, 255, 255), rarityId)
end

local function applyRarityStyle(textLabel: TextLabel, rarityId: string)
	disableDecorativeStrokes()
	setManagedStrokesEnabled(true)
	textLabel.TextStrokeTransparency = savedTextStrokeTransparency
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	disableOtherGradients(textLabel, "RaritySpawnGradient")
	RaritySpawnStyle.applyTextGradient(textLabel, rarityId)
	ensureBlackTextOutline()
	applyRarityPanelStyle(rarityId)
end

local function applyErrorStyle(textLabel: TextLabel)
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIGradient") then
			child.Enabled = false
		end
	end

	disableDecorativeStrokes()
	setManagedStrokesEnabled(false)
	textLabel.TextColor3 = ERROR_ACCENT
	textLabel.TextStrokeColor3 = ERROR_TEXT_STROKE
	textLabel.TextStrokeTransparency = 0

	if panelStroke then
		panelStroke.Transparency = 1
		local grad = panelStroke:FindFirstChild("RaritySpawnGradient")
		if grad and grad:IsA("UIGradient") then
			grad.Enabled = false
		end
	end
end

local function setLabelAlpha(textLabel: TextLabel, alpha: number, isError: boolean)
	textLabel.TextTransparency = alpha
	if isError then
		textLabel.TextStrokeTransparency = alpha
	else
		if labelStroke then
			labelStroke.Transparency = alpha
		end
	end
end

local function cancelActiveTween()
	if activeFadeTween then
		activeFadeTween:Cancel()
		activeFadeTween = nil
	end
end

local function processQueue()
	if isShowing or #messageQueue == 0 or not host or not animHost or not label or not animScale then
		return
	end

	local entry = table.remove(messageQueue, 1)
	isShowing = true
	hideToken += 1
	local token = hideToken
	cancelActiveTween()

	label.Visible = true
	label.Text = entry.message
	label.Rotation = 0

	if entry.isError then
		applyErrorStyle(label)
		animScale.Scale = 1
	else
		applyRarityStyle(label, entry.rarityId or "legendary")
		animScale.Scale = 0.6
	end

	setLabelAlpha(label, if entry.isError then 1 else 0, entry.isError)
	host.Visible = true

	cancelActiveTween()
	if entry.isError then
		TweenService:Create(label, TEXT_IN, { TextTransparency = 0, TextStrokeTransparency = 0 }):Play()
	else
		activeFadeTween = TweenService:Create(animScale, POP_IN, { Scale = 1 })
		activeFadeTween:Play()
		TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
		end
	end

	local lifetime = if entry.isError then ERROR_LIFETIME else DISPLAY_LIFETIME
	task.delay(lifetime, function()
		if token ~= hideToken or not host or not label or not animScale then
			return
		end
		cancelActiveTween()
		if entry.isError then
			TweenService:Create(label, FADE_OUT, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		else
			activeFadeTween = TweenService:Create(animScale, FADE_OUT, { Scale = 0.55 })
			activeFadeTween:Play()
			TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
			if labelStroke then
				TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
			end
		end
		task.delay(FADE_OUT.Time, function()
			if token ~= hideToken then
				return
			end
			isShowing = false
			if host then
				host.Visible = false
			end
			if label then
				label.Visible = false
				label.Rotation = 0
			end
			animScale.Scale = 1
			processQueue()
		end)
	end)
end

local function enqueue(message: string, isError: boolean, rarityId: string?)
	table.insert(messageQueue, {
		message = message,
		isError = isError,
		rarityId = rarityId,
	})
	processQueue()
end

function TopNotifController.showRaritySpawn(message: string, rarityId: string)
	if not globalMessagesEnabled() then
		return
	end
	if not host then
		TopNotifController.init()
	end
	GameSoundEffects.playNotification1()
	enqueue(message, false, rarityId)
end

function TopNotifController.showBroadcast(message: string, _scope: string?)
	if not globalMessagesEnabled() then
		return
	end
	if not host then
		TopNotifController.init()
	end
	GameSoundEffects.playNotification1()
	enqueue(message, false, "legendary")
end

function TopNotifController.showError(message: string)
	if not host then
		TopNotifController.init()
	end
	local now = os.clock()
	if now - lastErrorAt < ERROR_COOLDOWN then
		return
	end
	lastErrorAt = now
	GameSoundEffects.playErrorNotif()
	enqueue(message, true, nil)
end

function TopNotifController.showCantAfford(message: string?)
	TopNotifController.showError(message or CANT_AFFORD_MESSAGE)
end

function TopNotifController.init()
	findParts()
	if not host or not label then
		warn("[TopNotifController] SideUI.Top.Notif missing")
		return
	end
	host.Visible = false
	label.Visible = false

	if broadcastConn then
		broadcastConn:Disconnect()
		broadcastConn = nil
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("BroadcastTopNotif")
	if ev and ev:IsA("RemoteEvent") then
		broadcastConn = (ev :: RemoteEvent).OnClientEvent:Connect(function(message: any, _scope: any)
			if typeof(message) ~= "string" then
				return
			end
			TopNotifController.showBroadcast(message, if typeof(_scope) == "string" then _scope else nil)
		end)
	end
end

return TopNotifController
