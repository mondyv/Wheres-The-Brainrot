-- [ACTIVE] TopNotifController
--[[
	SideUI.Top.Notif toasts — rarity spawns, admin broadcasts, error feedback.
	Admin/global command messages use a sender card (avatar, name, verified badge)
	with typewriter text, hover ticks, and fade in/out.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local VerifiedCreators = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VerifiedCreators"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local RaritySpawnStyle = require(script.Parent.RaritySpawnStyle)

local player = Players.LocalPlayer
local IS_TOUCH = UserInputService.TouchEnabled

local POP_IN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TEXT_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BANNER_IN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BANNER_OUT = TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local ERROR_ACCENT = Color3.fromRGB(255, 72, 72)
local ERROR_TEXT_STROKE = Color3.fromRGB(0, 0, 0)
local DISPLAY_LIFETIME = 10
local BROADCAST_HOLD = 4.4
local ERROR_LIFETIME = 3.5
local CANT_AFFORD_MESSAGE = "You can't afford this!"
local BANNER_NAME = "AdminBroadcastBanner"

local TopNotifController = {}

type QueuedMessage = {
	message: string,
	isError: boolean,
	rarityId: string?,
	lifetimeSec: number?,
	senderName: string?,
	senderUserId: number?,
}

type BroadcastBanner = {
	root: Frame,
	scale: UIScale,
	stroke: UIStroke,
	avatar: ImageLabel,
	avatarStroke: UIStroke,
	nameRow: Frame,
	nameLabel: TextLabel,
	nameStroke: UIStroke,
	badge: ImageLabel,
	message: TextLabel,
	messageStroke: UIStroke,
	fadeParts: { GuiObject },
	avatarSize: number,
}

local host: GuiObject? = nil
local animHost: GuiObject? = nil
local label: TextLabel? = nil
local panelStroke: UIStroke? = nil
local labelStroke: UIStroke? = nil
local animScale: UIScale? = nil
local topHost: GuiObject? = nil
local banner: BroadcastBanner? = nil
local cachedStrokes: { UIStroke } = {}
local _savedLabelStrokeThickness: number? = nil
local savedPanelStrokeTransparency: number? = nil
local _savedTextStrokeTransparency: number = 1
local messageQueue: { QueuedMessage } = {}
local isShowing = false
local hideToken = 0
local activeFadeTween: Tween? = nil
local activeIsError = false
local activeIsBroadcast = false
local errorHideThread: thread? = nil
local typewriterThread: thread? = nil
local broadcastConn: RBXScriptConnection? = nil
local _defaultPanelStrokeColor: Color3? = nil
local thumbnailCache: { [number]: string } = {}

local scheduleErrorHide: (token: number, lifetime: number) -> ()
local processQueue: () -> ()
local enqueueFallback: (QueuedMessage) -> ()

local function globalMessagesEnabled(): boolean
	return player:GetAttribute(PlayerDataSchema.SETTINGS_GLOBAL_MESSAGES_ATTR) ~= false
end

local function isCountdownMessage(message: string): boolean
	return string.find(message, "Server shutdown", 1, true) ~= nil
		or string.find(message, "Server restart", 1, true) ~= nil
end

local function graphemeCount(text: string): number
	local n = 0
	for _ in utf8.graphemes(text) do
		n += 1
	end
	return n
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
	textLabel.RichText = true
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIScale") then
			child:Destroy()
		elseif child:IsA("UIGradient") then
			child.Enabled = false
			child.Offset = Vector2.new(0, 0)
		end
		-- Leave existing UIStroke alone — Studio already styled it.
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
			if desc:IsA("Frame") then
				desc.BackgroundTransparency = 1
			end
			desc.BorderSizePixel = 0
			if desc:IsA("ImageLabel") then
				desc.Visible = false
			end
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
	if top and top:IsA("GuiObject") then
		topHost = top
	end
	if not notif or not notif:IsA("GuiObject") then
		return
	end
	host = notif :: GuiObject
	animHost = host
	animScale = getOrAddAnimScale(host)
	prepareNotifHost(host)

	panelStroke = host:FindFirstChildOfClass("UIStroke")
	if panelStroke then
		_defaultPanelStrokeColor = panelStroke.Color
	end

	local text = notif:FindFirstChild("Text")
	if not text or not text:IsA("TextLabel") then
		text = notif:FindFirstChild("Text", true)
	end
	if text and text:IsA("TextLabel") then
		label = text
		_savedTextStrokeTransparency = label.TextStrokeTransparency
		prepareNotifLabel(label)
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			labelStroke = stroke
			_savedLabelStrokeThickness = stroke.Thickness
		end
	end
end

-- Touch existing stroke lightly for rarity text only — never create or thicken.
local function ensureBlackTextOutline()
	if not labelStroke or not labelStroke.Parent then
		return
	end
	labelStroke.Enabled = true
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

local function setPanelAccent(color: Color3, _rarityId: string?)
	if not panelStroke then
		return
	end
	panelStroke.Color = color
	local grad = panelStroke:FindFirstChild("RaritySpawnGradient")
	if grad and grad:IsA("UIGradient") then
		grad:Destroy()
	end
end

local function applyRarityPanelStyle(rarityId: string)
	if not panelStroke then
		return
	end
	panelStroke.Transparency = savedPanelStrokeTransparency or panelStroke.Transparency
	setPanelAccent(RaritySpawnStyle.accentColor(rarityId), nil)
end

local function applyRarityStyle(textLabel: TextLabel, rarityId: string)
	disableDecorativeStrokes()
	textLabel.TextStrokeTransparency = 1
	textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	disableOtherGradients(textLabel, "RaritySpawnGradient")
	RaritySpawnStyle.applyTextGradient(textLabel, rarityId)
	ensureBlackTextOutline()
	if panelStroke then
		panelStroke.Enabled = true
		panelStroke.Transparency = savedPanelStrokeTransparency or 0
	end
	applyRarityPanelStyle(rarityId)
end

local function applyErrorStyle(textLabel: TextLabel)
	for _, child in textLabel:GetChildren() do
		if child:IsA("UIGradient") then
			child.Enabled = false
		end
	end

	disableDecorativeStrokes()
	textLabel.TextColor3 = ERROR_ACCENT
	-- Prefer UIStroke outline (studio outline was left disabled); hide legacy TextStroke.
	textLabel.TextStrokeColor3 = ERROR_TEXT_STROKE
	textLabel.TextStrokeTransparency = 1
	ensureBlackTextOutline()

	if panelStroke then
		panelStroke.Enabled = false
		panelStroke.Transparency = 1
		local grad = panelStroke:FindFirstChild("RaritySpawnGradient")
		if grad and grad:IsA("UIGradient") then
			grad.Enabled = false
		end
	end
end

local function setLabelAlpha(textLabel: TextLabel, alpha: number, _isError: boolean)
	textLabel.TextTransparency = alpha
	if labelStroke and labelStroke.Parent then
		labelStroke.Transparency = alpha
	end
end

local function cancelActiveTween()
	if activeFadeTween then
		activeFadeTween:Cancel()
		activeFadeTween = nil
	end
end

local function cancelErrorHideThread()
	if errorHideThread then
		task.cancel(errorHideThread)
		errorHideThread = nil
	end
end

local function cancelTypewriterThread()
	if typewriterThread then
		task.cancel(typewriterThread)
		typewriterThread = nil
	end
end

local function hideClassicHost()
	if host then
		host.Visible = false
	end
	if label then
		label.Visible = false
		label.Rotation = 0
	end
	if animScale then
		animScale.Scale = 1
	end
end

local function applyHeadshot(image: ImageLabel, userId: number)
	local cached = thumbnailCache[userId]
	if cached then
		image.Image = cached
		return
	end
	image.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if not ok then
			warn("[TopNotifController] thumbnail failed:", content)
			return
		end
		if typeof(content) == "string" and content ~= "" then
			thumbnailCache[userId] = content
			if image.Parent then
				image.Image = content
			end
		end
	end)
end

local function setBannerAlpha(alpha: number)
	local chrome = banner
	if not chrome then
		return
	end
	chrome.root.BackgroundTransparency = 0.08 + alpha * 0.92
	chrome.stroke.Transparency = alpha
	chrome.avatar.ImageTransparency = alpha
	chrome.avatarStroke.Transparency = 0.15 + alpha * 0.85
	chrome.nameLabel.TextTransparency = alpha
	chrome.nameStroke.Transparency = alpha
	chrome.badge.ImageTransparency = alpha
	chrome.message.TextTransparency = alpha
	chrome.messageStroke.Transparency = alpha
	for _, part in chrome.fadeParts do
		if part:IsA("Frame") then
			part.BackgroundTransparency = 0.35 + alpha * 0.65
		end
	end
end

local function ensureBroadcastBanner()
	if banner and banner.root.Parent then
		return banner
	end
	if not topHost then
		return nil
	end
	local existing = topHost:FindFirstChild(BANNER_NAME)
	if existing then
		existing:Destroy()
	end

	local width = if IS_TOUCH then 560 else 520
	local pad = if IS_TOUCH then 14 else 12
	local avatarSize = if IS_TOUCH then 56 else 50

	local root = Instance.new("Frame")
	root.Name = BANNER_NAME
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, if IS_TOUCH then 10 else 8)
	root.Size = UDim2.fromOffset(width, avatarSize + pad * 2)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundColor3 = Color3.fromRGB(14, 10, 14)
	root.BackgroundTransparency = 0.08
	root.BorderSizePixel = 0
	root.ClipsDescendants = false
	root.Visible = false
	root.ZIndex = 40

	local scale = Instance.new("UIScale")
	scale.Name = "BannerScale"
	scale.Scale = 1
	scale.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Edge"
	stroke.Color = Color3.fromRGB(255, 214, 96)
	stroke.Thickness = 2.2
	stroke.Transparency = 0
	stroke.Parent = root

	local padObj = Instance.new("UIPadding")
	padObj.PaddingTop = UDim.new(0, pad)
	padObj.PaddingBottom = UDim.new(0, pad)
	padObj.PaddingLeft = UDim.new(0, pad)
	padObj.PaddingRight = UDim.new(0, pad)
	padObj.Parent = root

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.BackgroundColor3 = Color3.fromRGB(255, 214, 96)
	accent.BackgroundTransparency = 0.35
	accent.BorderSizePixel = 0
	accent.AnchorPoint = Vector2.new(0.5, 0)
	accent.Position = UDim2.new(0.5, 0, 0, -pad + 3)
	accent.Size = UDim2.new(1, pad * 2 - 18, 0, 3)
	accent.ZIndex = 41
	accent.Parent = root
	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(1, 0)
	accentCorner.Parent = accent

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.BackgroundColor3 = Color3.fromRGB(22, 16, 20)
	avatar.BackgroundTransparency = 0.15
	avatar.BorderSizePixel = 0
	avatar.Position = UDim2.fromOffset(0, 2)
	avatar.Size = UDim2.fromOffset(avatarSize, avatarSize)
	avatar.Image = ""
	avatar.ScaleType = Enum.ScaleType.Crop
	avatar.ZIndex = 42
	avatar.Parent = root
	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar
	local avatarStroke = Instance.new("UIStroke")
	avatarStroke.Color = Color3.fromRGB(255, 214, 96)
	avatarStroke.Thickness = 2
	avatarStroke.Transparency = 0.15
	avatarStroke.Parent = avatar

	local nameRow = Instance.new("Frame")
	nameRow.Name = "NameRow"
	nameRow.BackgroundTransparency = 1
	nameRow.Position = UDim2.fromOffset(avatarSize + 12, 0)
	nameRow.Size = UDim2.new(1, -(avatarSize + 12), 0, if IS_TOUCH then 26 else 22)
	nameRow.ZIndex = 42
	nameRow.Parent = root

	local nameLayout = Instance.new("UIListLayout")
	nameLayout.FillDirection = Enum.FillDirection.Horizontal
	nameLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	nameLayout.Padding = UDim.new(0, 6)
	nameLayout.SortOrder = Enum.SortOrder.LayoutOrder
	nameLayout.Parent = nameRow

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Username"
	nameLabel.BackgroundTransparency = 1
	nameLabel.BorderSizePixel = 0
	nameLabel.AutomaticSize = Enum.AutomaticSize.X
	nameLabel.Size = UDim2.new(0, 0, 1, 0)
	nameLabel.FontFace = UiFonts.DISPLAY_FACE
	nameLabel.Text = ""
	nameLabel.TextColor3 = Color3.fromRGB(255, 214, 96)
	nameLabel.TextSize = if IS_TOUCH then 20 else 18
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextYAlignment = Enum.TextYAlignment.Center
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.LayoutOrder = 1
	nameLabel.ZIndex = 43
	nameLabel.Parent = nameRow
	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 1.6
	nameStroke.Parent = nameLabel

	local badge = Instance.new("ImageLabel")
	badge.Name = "Verified"
	badge.BackgroundTransparency = 1
	badge.BorderSizePixel = 0
	badge.Size = UDim2.fromOffset(if IS_TOUCH then 22 else 20, if IS_TOUCH then 22 else 20)
	badge.Image = VerifiedCreators.BADGE_IMAGE
	badge.ScaleType = Enum.ScaleType.Fit
	badge.LayoutOrder = 2
	badge.ZIndex = 43
	badge.Parent = nameRow

	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.BackgroundTransparency = 1
	message.BorderSizePixel = 0
	message.Position = UDim2.fromOffset(avatarSize + 12, if IS_TOUCH then 28 else 24)
	message.Size = UDim2.new(1, -(avatarSize + 12), 0, 0)
	message.AutomaticSize = Enum.AutomaticSize.Y
	message.FontFace = UiFonts.DISPLAY_FACE
	message.Text = ""
	message.TextColor3 = Color3.fromRGB(255, 246, 230)
	message.TextSize = if IS_TOUCH then 20 else 18
	message.TextWrapped = true
	message.TextXAlignment = Enum.TextXAlignment.Left
	message.TextYAlignment = Enum.TextYAlignment.Top
	message.ZIndex = 42
	message.Parent = root
	local msgStroke = Instance.new("UIStroke")
	msgStroke.Color = Color3.fromRGB(0, 0, 0)
	msgStroke.Thickness = 1.4
	msgStroke.Parent = message
	RaritySpawnStyle.applyTextGradient(message, "legendary")

	root.Parent = topHost
	banner = {
		root = root,
		scale = scale,
		stroke = stroke,
		avatar = avatar,
		avatarStroke = avatarStroke,
		nameRow = nameRow,
		nameLabel = nameLabel,
		nameStroke = nameStroke,
		badge = badge,
		message = message,
		messageStroke = msgStroke,
		fadeParts = { accent },
		avatarSize = avatarSize,
	}
	return banner
end

local function hideBroadcastBanner()
	cancelTypewriterThread()
	if banner then
		banner.root.Visible = false
		banner.scale.Scale = 1
		banner.message.MaxVisibleGraphemes = 0
	end
	activeIsBroadcast = false
end

local function playBroadcastBanner(entry: QueuedMessage, token: number)
	local chrome = ensureBroadcastBanner()
	if not chrome then
		enqueueFallback(entry)
		return
	end

	hideClassicHost()
	activeIsBroadcast = true
	chrome.nameLabel.Text = entry.senderName or "Admin"
	chrome.badge.Visible = true
	chrome.message.Text = entry.message
	chrome.message.MaxVisibleGraphemes = 0
	local hasAvatar = typeof(entry.senderUserId) == "number"
	local indent = if hasAvatar then chrome.avatarSize + 12 else 0
	chrome.avatar.Visible = hasAvatar
	chrome.nameRow.Position = UDim2.fromOffset(indent, 0)
	chrome.nameRow.Size = UDim2.new(1, -indent, 0, if IS_TOUCH then 26 else 22)
	chrome.message.Position = UDim2.fromOffset(indent, if IS_TOUCH then 28 else 24)
	chrome.message.Size = UDim2.new(1, -indent, 0, 0)
	if hasAvatar then
		applyHeadshot(chrome.avatar, entry.senderUserId :: number)
	end

	chrome.scale.Scale = 0.78
	setBannerAlpha(1)
	chrome.root.Visible = true
	cancelActiveTween()
	activeFadeTween = TweenService:Create(chrome.scale, BANNER_IN, { Scale = 1 })
	activeFadeTween:Play()
	TweenService:Create(chrome.root, TEXT_IN, { BackgroundTransparency = 0.08 }):Play()
	TweenService:Create(chrome.stroke, TEXT_IN, { Transparency = 0 }):Play()
	TweenService:Create(chrome.avatar, TEXT_IN, { ImageTransparency = 0 }):Play()
	TweenService:Create(chrome.avatarStroke, TEXT_IN, { Transparency = 0.15 }):Play()
	TweenService:Create(chrome.nameLabel, TEXT_IN, { TextTransparency = 0 }):Play()
	TweenService:Create(chrome.nameStroke, TEXT_IN, { Transparency = 0 }):Play()
	TweenService:Create(chrome.badge, TEXT_IN, { ImageTransparency = 0 }):Play()
	TweenService:Create(chrome.message, TEXT_IN, { TextTransparency = 0 }):Play()
	TweenService:Create(chrome.messageStroke, TEXT_IN, { Transparency = 0 }):Play()
	for _, part in chrome.fadeParts do
		TweenService:Create(part, TEXT_IN, { BackgroundTransparency = 0.35 }):Play()
	end

	local letters = graphemeCount(entry.message)
	local delaySec = if letters > 90 then 0.016 elseif letters > 48 then 0.022 else 0.03
	local hold = if typeof(entry.lifetimeSec) == "number" then math.max(2.2, entry.lifetimeSec) else BROADCAST_HOLD

	cancelTypewriterThread()
	typewriterThread = task.spawn(function()
		task.wait(0.12)
		if token ~= hideToken or not banner then
			return
		end
		local i = 0
		for first, last in utf8.graphemes(entry.message) do
			if token ~= hideToken or not banner then
				return
			end
			i += 1
			banner.message.MaxVisibleGraphemes = i
			local g = string.sub(entry.message, first, last)
			if g ~= " " and g ~= "\n" and g ~= "\t" then
				UIInteractionSounds.playTypewriterTick()
			end
			task.wait(delaySec)
		end
		if token == hideToken and banner then
			banner.message.MaxVisibleGraphemes = -1
		end
	end)

	task.delay(0.12 + letters * delaySec + hold, function()
		if token ~= hideToken or not banner then
			return
		end
		cancelActiveTween()
		activeFadeTween = TweenService:Create(banner.scale, BANNER_OUT, { Scale = 0.86 })
		activeFadeTween:Play()
		TweenService:Create(banner.root, BANNER_OUT, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(banner.stroke, BANNER_OUT, { Transparency = 1 }):Play()
		TweenService:Create(banner.avatar, BANNER_OUT, { ImageTransparency = 1 }):Play()
		TweenService:Create(banner.avatarStroke, BANNER_OUT, { Transparency = 1 }):Play()
		TweenService:Create(banner.nameLabel, BANNER_OUT, { TextTransparency = 1 }):Play()
		TweenService:Create(banner.nameStroke, BANNER_OUT, { Transparency = 1 }):Play()
		TweenService:Create(banner.badge, BANNER_OUT, { ImageTransparency = 1 }):Play()
		TweenService:Create(banner.message, BANNER_OUT, { TextTransparency = 1 }):Play()
		TweenService:Create(banner.messageStroke, BANNER_OUT, { Transparency = 1 }):Play()
		for _, part in banner.fadeParts do
			TweenService:Create(part, BANNER_OUT, { BackgroundTransparency = 1 }):Play()
		end
		task.delay(BANNER_OUT.Time, function()
			if token ~= hideToken then
				return
			end
			hideBroadcastBanner()
			isShowing = false
			activeIsError = false
			processQueue()
		end)
	end)
end

enqueueFallback = function(entry: QueuedMessage)
	-- Used if the banner host is missing; fall back to the classic toast.
	if not host or not label then
		isShowing = false
		return
	end
	local display = VerifiedCreators.formatBroadcast(entry.message, entry.senderName, entry.senderUserId)
	label.Visible = true
	label.Text = display
	label.Rotation = 0
	applyRarityStyle(label, "legendary")
	if animScale then
		animScale.Scale = 0.6
	end
	setLabelAlpha(label, 0, false)
	host.Visible = true
	if animScale then
		activeFadeTween = TweenService:Create(animScale, POP_IN, { Scale = 1 })
		activeFadeTween:Play()
	end
	TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
	if labelStroke then
		TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
	end
	local lifetime = if typeof(entry.lifetimeSec) == "number" then math.max(2.5, entry.lifetimeSec) else DISPLAY_LIFETIME
	local token = hideToken
	task.delay(lifetime, function()
		if token ~= hideToken or not host or not label then
			return
		end
		cancelActiveTween()
		if animScale then
			activeFadeTween = TweenService:Create(animScale, FADE_OUT, { Scale = 0.55 })
			activeFadeTween:Play()
		end
		TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
		end
		task.delay(FADE_OUT.Time, function()
			if token ~= hideToken then
				return
			end
			isShowing = false
			hideClassicHost()
			processQueue()
		end)
	end)
end

local function purgeQueuedErrors()
	local i = 1
	while i <= #messageQueue do
		if messageQueue[i].isError then
			table.remove(messageQueue, i)
		else
			i += 1
		end
	end
end

processQueue = function()
	if isShowing or #messageQueue == 0 then
		return
	end

	local entry = table.remove(messageQueue, 1)
	isShowing = true
	activeIsError = entry.isError
	activeIsBroadcast = false
	hideToken += 1
	local token = hideToken
	cancelActiveTween()
	cancelErrorHideThread()
	cancelTypewriterThread()

	if entry.senderName and not entry.isError then
		playBroadcastBanner(entry, token)
		return
	end

	hideBroadcastBanner()
	if not host or not animHost or not label or not animScale then
		isShowing = false
		return
	end

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
		TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
		end
	else
		activeFadeTween = TweenService:Create(animScale, POP_IN, { Scale = 1 })
		activeFadeTween:Play()
		TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
		end
	end

	local lifetime = if entry.isError
		then ERROR_LIFETIME
		else (if typeof(entry.lifetimeSec) == "number" then math.max(2.5, entry.lifetimeSec) else DISPLAY_LIFETIME)
	if entry.isError then
		scheduleErrorHide(token, lifetime)
		return
	end
	task.delay(lifetime, function()
		if token ~= hideToken or not host or not label or not animScale then
			return
		end
		cancelActiveTween()
		activeFadeTween = TweenService:Create(animScale, FADE_OUT, { Scale = 0.55 })
		activeFadeTween:Play()
		TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
		end
		task.delay(FADE_OUT.Time, function()
			if token ~= hideToken then
				return
			end
			isShowing = false
			activeIsError = false
			hideClassicHost()
			processQueue()
		end)
	end)
end

scheduleErrorHide = function(token: number, lifetime: number)
	cancelErrorHideThread()
	errorHideThread = task.delay(lifetime, function()
		errorHideThread = nil
		if token ~= hideToken or not host or not label or not animScale then
			return
		end
		cancelActiveTween()
		TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
		if labelStroke then
			TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
		end
		task.delay(FADE_OUT.Time, function()
			if token ~= hideToken then
				return
			end
			isShowing = false
			activeIsError = false
			hideClassicHost()
			processQueue()
		end)
	end)
end

local function showErrorNow(message: string)
	if not host or not animHost or not label or not animScale then
		return
	end
	hideBroadcastBanner()
	isShowing = true
	activeIsError = true
	hideToken += 1
	local token = hideToken
	cancelActiveTween()
	cancelErrorHideThread()
	label.Visible = true
	label.Text = message
	label.Rotation = 0
	applyErrorStyle(label)
	animScale.Scale = 1
	setLabelAlpha(label, 1, true)
	host.Visible = true
	TweenService:Create(label, TEXT_IN, { TextTransparency = 0 }):Play()
	if labelStroke then
		TweenService:Create(labelStroke, TEXT_IN, { Transparency = 0 }):Play()
	end
	scheduleErrorHide(token, ERROR_LIFETIME)
end

local function enqueue(
	message: string,
	isError: boolean,
	rarityId: string?,
	lifetimeSec: number?,
	senderName: string?,
	senderUserId: number?
)
	table.insert(messageQueue, {
		message = message,
		isError = isError,
		rarityId = rarityId,
		lifetimeSec = lifetimeSec,
		senderName = senderName,
		senderUserId = senderUserId,
	})
	processQueue()
end

function TopNotifController.dismissActive()
	if not isShowing then
		return
	end
	hideToken += 1
	isShowing = false
	cancelActiveTween()
	cancelTypewriterThread()
	hideBroadcastBanner()
	hideClassicHost()
	processQueue()
end

function TopNotifController.showRaritySpawn(message: string, rarityId: string, lifetimeSec: number?, ignoreGlobalFilter: boolean?)
	if not ignoreGlobalFilter and not globalMessagesEnabled() then
		return
	end
	if not host then
		TopNotifController.init()
	end
	UIInteractionSounds.playNotif()
	enqueue(message, false, rarityId, lifetimeSec)
end

function TopNotifController.showPersonal(message: string, rarityId: string?, lifetimeSec: number?)
	TopNotifController.showRaritySpawn(message, rarityId or "legendary", lifetimeSec, true)
end

function TopNotifController.showBroadcast(
	message: string,
	_scope: string?,
	senderName: string?,
	senderUserId: number?,
	lifetimeSec: number?
)
	if not globalMessagesEnabled() then
		return
	end
	if not host and not topHost then
		TopNotifController.init()
	end

	-- Countdown / persistent admin banners: refresh text in place instead of stacking.
	if isShowing and not activeIsError and isCountdownMessage(message) then
		if activeIsBroadcast and banner then
			cancelTypewriterThread()
			banner.message.Text = message
			banner.message.MaxVisibleGraphemes = -1
			banner.message.TextTransparency = 0
		elseif host and label then
			label.Text = VerifiedCreators.formatBroadcast(message, senderName, senderUserId)
		end
		hideToken += 1
		local token = hideToken
		local lifetime = if typeof(lifetimeSec) == "number" then math.max(1.2, lifetimeSec) else DISPLAY_LIFETIME
		task.delay(lifetime, function()
			if token ~= hideToken then
				return
			end
			cancelActiveTween()
			if activeIsBroadcast and banner then
				activeFadeTween = TweenService:Create(banner.scale, BANNER_OUT, { Scale = 0.86 })
				activeFadeTween:Play()
				TweenService:Create(banner.root, BANNER_OUT, { BackgroundTransparency = 1 }):Play()
				TweenService:Create(banner.stroke, BANNER_OUT, { Transparency = 1 }):Play()
				TweenService:Create(banner.message, BANNER_OUT, { TextTransparency = 1 }):Play()
				TweenService:Create(banner.messageStroke, BANNER_OUT, { Transparency = 1 }):Play()
				TweenService:Create(banner.nameLabel, BANNER_OUT, { TextTransparency = 1 }):Play()
				TweenService:Create(banner.nameStroke, BANNER_OUT, { Transparency = 1 }):Play()
				TweenService:Create(banner.badge, BANNER_OUT, { ImageTransparency = 1 }):Play()
				TweenService:Create(banner.avatar, BANNER_OUT, { ImageTransparency = 1 }):Play()
				TweenService:Create(banner.avatarStroke, BANNER_OUT, { Transparency = 1 }):Play()
			elseif label then
				if animScale then
					activeFadeTween = TweenService:Create(animScale, FADE_OUT, { Scale = 0.55 })
					activeFadeTween:Play()
				end
				TweenService:Create(label, FADE_OUT, { TextTransparency = 1 }):Play()
				if labelStroke then
					TweenService:Create(labelStroke, FADE_OUT, { Transparency = 1 }):Play()
				end
			end
			task.delay((if activeIsBroadcast then BANNER_OUT else FADE_OUT).Time, function()
				if token ~= hideToken then
					return
				end
				isShowing = false
				hideBroadcastBanner()
				hideClassicHost()
				processQueue()
			end)
		end)
		return
	end

	UIInteractionSounds.playNotif()
	if typeof(senderName) == "string" and senderName ~= "" then
		enqueue(message, false, "legendary", lifetimeSec, senderName, senderUserId)
	else
		enqueue(message, false, "legendary", lifetimeSec)
	end
end

function TopNotifController.showError(message: string)
	if not host then
		TopNotifController.init()
	end
	purgeQueuedErrors()
	if isShowing and activeIsError then
		GameSoundEffects.playErrorNotif()
		showErrorNow(message)
		return
	end
	GameSoundEffects.playErrorNotif()
	enqueue(message, true, nil)
end

function TopNotifController.showCantAfford(message: string?)
	TopNotifController.showError(message or CANT_AFFORD_MESSAGE)
end

function TopNotifController.init()
	findParts()
	ensureBroadcastBanner()
	if not host or not label then
		warn("[TopNotifController] SideUI.Top.Notif missing")
		if not banner then
			return
		end
	end
	if host then
		local legacyPanel = host:FindFirstChild("ManagedNotifPanel")
		if legacyPanel then
			legacyPanel:Destroy()
		end
		host.Visible = false
	end
	if label then
		label.Visible = false
	end
	if banner then
		banner.root.Visible = false
	end

	if broadcastConn then
		broadcastConn:Disconnect()
		broadcastConn = nil
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("BroadcastTopNotif")
	if ev and ev:IsA("RemoteEvent") then
		broadcastConn = (ev :: RemoteEvent).OnClientEvent:Connect(function(message: any, _scope: any, senderName: any, senderUserId: any, lifetimeSec: any)
			if typeof(message) ~= "string" then
				return
			end
			TopNotifController.showBroadcast(
				message,
				if typeof(_scope) == "string" then _scope else nil,
				if typeof(senderName) == "string" then senderName else nil,
				if typeof(senderUserId) == "number" then senderUserId else nil,
				if typeof(lifetimeSec) == "number" then lifetimeSec else nil
			)
		end)
	end
end

return TopNotifController
