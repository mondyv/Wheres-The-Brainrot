-- [ACTIVE] CustomBubbleChatController
--[[
	Replaces default Roblox bubble chat with stand-dialogue style bubbles:
	black panel, sharp white stroke edges, Arcade typewriter (no voice SFX).
	While a bubble is up for a player, their leaderboard overhead icons hide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local LeaderboardRankController = require(script.Parent.LeaderboardRankController)

local CustomBubbleChatController = {}

local BUBBLE_NAME = "CustomChatBubble"
local LETTER_DELAY = 0.038
local HOLD_AFTER_SEC = 2.4
local MAX_DISTANCE = 80
local MAX_CHARS = 120
local TEXT_SIZE = 13
local STUDS_OFFSET = Vector3.new(0, 2.55, 0)

local bubbleByPlayer: { [Player]: BillboardGui } = {}
local tokenByPlayer: { [Player]: number } = {}
local wired = false

local function disableDefaultBubbles()
	local bubbleConfig = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if bubbleConfig then
		pcall(function()
			(bubbleConfig :: any).Enabled = false
		end)
	end
	pcall(function()
		local cfg = (TextChatService :: any).BubbleChatConfiguration
		if cfg then
			cfg.Enabled = false
		end
	end)
end

local function stripRichText(text: string): string
	local cleaned = string.gsub(text, "<.->", "")
	cleaned = string.gsub(cleaned, "&lt;", "<")
	cleaned = string.gsub(cleaned, "&gt;", ">")
	cleaned = string.gsub(cleaned, "&amp;", "&")
	cleaned = string.gsub(cleaned, "&quot;", '"')
	cleaned = string.gsub(cleaned, "&#39;", "'")
	return cleaned
end

local function resolveAdornee(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function destroyBubble(player: Player)
	local bb = bubbleByPlayer[player]
	if bb then
		bb:Destroy()
		bubbleByPlayer[player] = nil
	end
	LeaderboardRankController.setChatBubbleSuppress(player, false)
end

local function estimateBubbleSize(message: string): UDim2
	local len = #message
	local width = math.clamp(48 + len * 7.2, 90, 260)
	local lines = math.max(1, math.ceil(len / 28))
	local height = math.clamp(34 + (lines - 1) * 16, 34, 90)
	return UDim2.fromOffset(width, height)
end

local function showBubble(player: Player, rawMessage: string)
	local character = player.Character
	if not character then
		return
	end
	local adornee = resolveAdornee(character)
	if not adornee then
		return
	end

	local message = stripRichText(rawMessage)
	message = string.gsub(message, "^%s+", "")
	message = string.gsub(message, "%s+$", "")
	if message == "" then
		return
	end
	if #message > MAX_CHARS then
		message = string.sub(message, 1, MAX_CHARS - 1) .. "…"
	end

	tokenByPlayer[player] = (tokenByPlayer[player] or 0) + 1
	local token = tokenByPlayer[player]

	destroyBubble(player)
	LeaderboardRankController.setChatBubbleSuppress(player, true)

	local bb = Instance.new("BillboardGui")
	bb.Name = BUBBLE_NAME
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = MAX_DISTANCE
	bb.Size = estimateBubbleSize(message)
	bb.StudsOffset = STUDS_OFFSET
	bb.Adornee = adornee
	bb.ResetOnSpawn = false
	bb.Parent = character
	bubbleByPlayer[player] = bb

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb

	local box = Instance.new("Frame")
	box.Name = "Bubble"
	box.BackgroundColor3 = Color3.new(0, 0, 0)
	box.BorderSizePixel = 0
	box.AnchorPoint = Vector2.new(0.5, 0)
	box.Position = UDim2.new(0.5, 0, 0, 0)
	box.Size = UDim2.new(1, 0, 1, -8)
	box.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Edge"
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = box

	-- Outer accent edge (cool double-border feel like stand dialogue).
	local outer = Instance.new("UIStroke")
	outer.Name = "OuterEdge"
	outer.Color = Color3.fromRGB(40, 40, 40)
	outer.Thickness = 5
	outer.Transparency = 0.35
	outer.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outer.Parent = box

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = box

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.2
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextSize = TEXT_SIZE
	label.Parent = box
	UiFonts.applyBody(label)
	UiFonts.ensureTextSizeConstraint(label, TEXT_SIZE, 10)

	-- Sharp tail under the bubble.
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.BackgroundColor3 = Color3.new(0, 0, 0)
	tail.BorderSizePixel = 0
	tail.AnchorPoint = Vector2.new(0.5, 0)
	tail.Position = UDim2.new(0.5, 0, 1, -10)
	tail.Size = UDim2.fromOffset(12, 12)
	tail.Rotation = 45
	tail.ZIndex = 0
	tail.Parent = root

	local tailStroke = Instance.new("UIStroke")
	tailStroke.Color = Color3.new(1, 1, 1)
	tailStroke.Thickness = 2
	tailStroke.Parent = tail

	local typeDuration = #message * LETTER_DELAY + 0.12
	task.spawn(function()
		for i = 1, #message do
			if tokenByPlayer[player] ~= token or not bb.Parent then
				return
			end
			label.Text = string.sub(message, 1, i)
			task.wait(LETTER_DELAY)
		end
		if tokenByPlayer[player] == token and bb.Parent then
			label.Text = message
		end
	end)

	local hold = math.clamp(HOLD_AFTER_SEC + #message * 0.035, HOLD_AFTER_SEC, 6.5)
	task.delay(typeDuration + hold, function()
		if tokenByPlayer[player] ~= token or not bb.Parent then
			return
		end
		local fadeInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(label, fadeInfo, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		TweenService:Create(box, fadeInfo, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(stroke, fadeInfo, { Transparency = 1 }):Play()
		TweenService:Create(outer, fadeInfo, { Transparency = 1 }):Play()
		TweenService:Create(tail, fadeInfo, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(tailStroke, fadeInfo, { Transparency = 1 }):Play()
		task.delay(0.26, function()
			if tokenByPlayer[player] == token then
				destroyBubble(player)
			end
		end)
	end)
end

local function onChatMessage(message: TextChatMessage)
	-- Accept delivered chat; ignore only clear failures when Status is present.
	local status = (message :: any).Status
	if status ~= nil and status ~= Enum.TextChatMessageStatus.Success then
		return
	end
	local source = message.TextSource
	if not source then
		return
	end
	local text = message.Text
	if typeof(text) ~= "string" or text == "" then
		return
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	if not player then
		return
	end
	showBubble(player, text)
end

function CustomBubbleChatController.init()
	if wired then
		return
	end
	wired = true

	disableDefaultBubbles()
	task.defer(disableDefaultBubbles)

	TextChatService.MessageReceived:Connect(onChatMessage)

	Players.PlayerRemoving:Connect(function(player)
		tokenByPlayer[player] = nil
		destroyBubble(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			destroyBubble(player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterRemoving:Connect(function()
			destroyBubble(player)
		end)
	end
end

return CustomBubbleChatController
