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
local WOBBLE_SETTLE = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local ERROR_ACCENT = Color3.fromRGB(255, 86, 86)
local DISPLAY_LIFETIME = 10
local ERROR_LIFETIME = 3.5
local ERROR_COOLDOWN = 0.35

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
local templateErrorGrad: UIGradient? = nil
local messageQueue: { QueuedMessage } = {}
local isShowing = false
local hideToken = 0
local activeFadeTween: Tween? = nil
local lastErrorAt = 0
local broadcastConn: RBXScriptConnection? = nil

local function globalMessagesEnabled(): boolean
	return player:GetAttribute(PlayerDataSchema.SETTINGS_GLOBAL_MESSAGES_ATTR) ~= false
end

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
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
	panelStroke = notif:FindFirstChildWhichIsA("UIStroke", true)
	local text = notif:FindFirstChild("Text", true)
	if text and text:IsA("TextLabel") then
		label = text
		local err = text:FindFirstChild("Error")
		if err and err:IsA("UIGradient") then
			templateErrorGrad = err
		end
		local stroke = text:FindFirstChildOfClass("UIStroke")
		if stroke then
			labelStroke = stroke
		else
			stroke = Instance.new("UIStroke")
			stroke.Name = "TextOutline"
			stroke.Color = Color3.fromRGB(0, 0, 0)
			stroke.Thickness = 2
			stroke.Parent = text
			labelStroke = stroke
		end
	end
end

local function ensureBlackTextOutline()
	if not labelStroke then
		return
	end
	labelStroke.Color = Color3.fromRGB(0, 0, 0)
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

local function applyRarityStyle(textLabel: TextLabel, rarityId: string)
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	disableOtherGradients(textLabel, "RaritySpawnGradient")
	RaritySpawnStyle.applyTextGradient(textLabel, rarityId)
	ensureBlackTextOutline()
end

local function applyErrorStyle(textLabel: TextLabel)
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	disableOtherGradients(textLabel, "Error")
	local err = textLabel:FindFirstChild("Error")
	if err and err:IsA("UIGradient") then
		err.Enabled = true
	elseif templateErrorGrad then
		local clone = templateErrorGrad:Clone()
		clone.Name = "Error"
		clone.Enabled = true
		clone.Parent = textLabel
	end
	setPanelAccent(ERROR_ACCENT, nil)
end

local function setLabelAlpha(textLabel: TextLabel, alpha: number)
	textLabel.TextTransparency = alpha
	if labelStroke then
		labelStroke.Transparency = alpha
	end
end

local function cancelActiveTween()
	if activeFadeTween then
		activeFadeTween:Cancel()
		activeFadeTween = nil
	end
end

local function processQueue()
	if isShowing or #messageQueue == 0 or not host or not animHost or not label then
		return
	end

	local entry = table.remove(messageQueue, 1)
	isShowing = true
	hideToken += 1
	local token = hideToken
	cancelActiveTween()

	label.Visible = true
	label.Text = entry.message
	if entry.isError then
		applyErrorStyle(label)
	else
		applyRarityStyle(label, entry.rarityId or "legendary")
	end

	setLabelAlpha(label, 0)
	host.Visible = true

	-- Scale the label only (not the layout frame) so the panel never "resizes weirdly".
	local scale = getOrAddUIScale(label)
	scale.Scale = 0.55
	label.Rotation = -5

	-- Single-shot bedazzle pop: Back overshoot + small wobble settle, lands at scale 1.
	cancelActiveTween()
	activeFadeTween = TweenService:Create(scale, POP_IN, { Scale = 1 })
	activeFadeTween:Play()
	TweenService:Create(label, WOBBLE_SETTLE, { Rotation = 0 }):Play()
	TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
	if labelStroke then
		TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
	end

	local lifetime = if entry.isError then ERROR_LIFETIME else DISPLAY_LIFETIME
	task.delay(lifetime, function()
		if token ~= hideToken or not host or not label then
			return
		end
		cancelActiveTween()
		activeFadeTween = TweenService:Create(scale, FADE_OUT, { Scale = 0.55 })
		activeFadeTween:Play()
		TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
		end
		activeFadeTween.Completed:Once(function()
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
			scale.Scale = 1
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
