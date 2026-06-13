-- [ACTIVE] TopNotifController
--[[
	SideUI.Top.Notif toasts — rarity spawns, admin broadcasts, error feedback.
	Uses the existing Notif UI (single banner) with pop + fade animations.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local POP_IN = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local TEXT_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WOBBLE_SETTLE = TweenInfo.new(0.6, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local IDLE_BOB = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local FADE_OUT = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.In)
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
local templateErrorGrad: UIGradient? = nil
local messageQueue: { QueuedMessage } = {}
local isShowing = false
local hideToken = 0
local activeFadeTween: Tween? = nil
local idleTween: Tween? = nil
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
	local text = notif:FindFirstChild("Text", true)
	if text and text:IsA("TextLabel") then
		label = text
		local err = text:FindFirstChild("Error")
		if err and err:IsA("UIGradient") then
			templateErrorGrad = err
		end
	end
end

local function clearLabelGradients(textLabel: TextLabel)
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIGradient") then
			child:Destroy()
		end
	end
end

local function applyRarityStyle(textLabel: TextLabel, rarityId: string)
	clearLabelGradients(textLabel)
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	local key = string.lower(rarityId)
	local gradName = BrainrotHeaderStyle.RARITY_GRADIENT_NAME[key]
	if gradName then
		BrainrotHeaderStyle.selectGradient(textLabel, gradName)
	end
end

local function applyErrorStyle(textLabel: TextLabel)
	clearLabelGradients(textLabel)
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	if templateErrorGrad then
		local clone = templateErrorGrad:Clone()
		clone.Name = "Error"
		clone.Enabled = true
		clone.Parent = textLabel
	end
end

local function setLabelAlpha(textLabel: TextLabel, alpha: number)
	textLabel.TextTransparency = alpha
	for _, desc in textLabel:GetDescendants() do
		if desc:IsA("UIStroke") then
			desc.Transparency = alpha
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

	local scale = getOrAddUIScale(animHost)
	scale.Scale = 0
	animHost.Rotation = -8

	-- Bedazzle pop: elastic scale overshoot + rotation wobble settle.
	activeFadeTween = TweenService:Create(scale, POP_IN, { Scale = 1 })
	activeFadeTween:Play()
	TweenService:Create(animHost, WOBBLE_SETTLE, { Rotation = 0 }):Play()
	TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
	for _, desc in label:GetDescendants() do
		if desc:IsA("UIStroke") then
			TweenService:Create(desc, TEXT_IN, { Transparency = 0 }):Play()
		end
	end

	-- Gentle idle bob once the pop settles, for some life.
	if idleTween then
		idleTween:Cancel()
		idleTween = nil
	end
	task.delay(0.6, function()
		if token ~= hideToken or not animHost then
			return
		end
		idleTween = TweenService:Create(scale, IDLE_BOB, { Scale = 1.035 })
		idleTween:Play()
	end)

	local lifetime = if entry.isError then ERROR_LIFETIME else DISPLAY_LIFETIME
	task.delay(lifetime, function()
		if token ~= hideToken or not host or not animHost or not label then
			return
		end
		cancelActiveTween()
		if idleTween then
			idleTween:Cancel()
			idleTween = nil
		end
		activeFadeTween = TweenService:Create(scale, FADE_OUT, { Scale = 0 })
		activeFadeTween:Play()
		TweenService:Create(animHost, FADE_OUT, { Rotation = 8 }):Play()
		TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
		for _, desc in label:GetDescendants() do
			if desc:IsA("UIStroke") then
				TweenService:Create(desc, FADE_OUT, { Transparency = 1 }):Play()
			end
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
			end
			scale.Scale = 1
			animHost.Rotation = 0
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
