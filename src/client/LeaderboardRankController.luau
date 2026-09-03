-- [ACTIVE] LeaderboardRankController
--[[
	Top-10 cash/time overhead badges, VIP crown, + chat tags (board itself shows top 100).
	Reads ReplicatedStorage.LeaderboardData published by Leaderboards.server.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)

local M = {}

local DATA_FOLDER_NAME = "LeaderboardData"
local BOARD_NAMES = { "Cash", "Time" }
local TAG_ROW_COUNT = 10 -- badges/tags only; boards show top 100
local SAFEZONE_POLL_INTERVAL = if UserInputService.TouchEnabled then 0.55 else 0.2

local localPlayer = Players.LocalPlayer

local ICON_BY_BOARD = {
	Cash = "rbxassetid://74007287247874",
	Time = "rbxassetid://119045246423817",
}

local EMOJI_BY_BOARD = {
	Cash = "💰",
	Time = "🕐",
}

local RANK_GRADIENTS: { [number]: ColorSequence } = {
	[1] = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 228, 120)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 190, 55)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 140, 30)),
	}),
	[2] = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(235, 242, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 200, 215)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(145, 155, 170)),
	}),
	[3] = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 190, 130)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 140, 75)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 95, 45)),
	}),
}

local DEFAULT_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 255, 180)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 210, 130)),
})

type BoardRank = {
	board: string,
	rank: number,
}

local VIP_CROWN_EMOJI = "👑"
local VIP_CROWN_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 140)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 196, 60)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 140, 30)),
})

local function playerOwnsVip(player: Player): boolean
	return player:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true
end

local ranksByUserId: { [number]: { BoardRank } } = {}
local badgeByPlayer: { [Player]: BillboardGui } = {}
local playerConns: { [Player]: { RBXScriptConnection } } = {}
local chatBubbleSuppress: { [Player]: boolean } = {}
local localWorldNotifSuppress = false
local wiredData = false

local function readBoardRanks(boardFolder: Folder): { [number]: BoardRank }
	local out: { [number]: BoardRank } = {}
	local boardName = boardFolder.Name
	for rank = 1, TAG_ROW_COUNT do
		local rowFolder = boardFolder:FindFirstChild(tostring(rank))
		if not rowFolder then
			continue
		end
		local userIdVal = rowFolder:FindFirstChild("UserId")
		local userId = if userIdVal and userIdVal:IsA("IntValue") then userIdVal.Value else 0
		if userId > 0 then
			out[userId] = { board = boardName, rank = rank }
		end
	end
	return out
end

local function rebuildRankCache(dataFolder: Folder)
	table.clear(ranksByUserId)
	for _, boardName in BOARD_NAMES do
		local boardFolder = dataFolder:FindFirstChild(boardName)
		if boardFolder and boardFolder:IsA("Folder") then
			for userId, info in readBoardRanks(boardFolder) do
				local list = ranksByUserId[userId]
				if not list then
					list = {}
					ranksByUserId[userId] = list
				end
				table.insert(list, info)
			end
		end
	end
	for _, list in ranksByUserId do
		table.sort(list, function(a, b)
			return a.rank < b.rank
		end)
	end
end

function M.getChatTagsForUserId(userId: number): string
	local list = ranksByUserId[userId]
	if not list or #list == 0 then
		return ""
	end
	local parts: { string } = {}
	for _, info in list do
		local emoji = EMOJI_BY_BOARD[info.board] or ""
		table.insert(parts, string.format("<b>[#%d %s]</b>", info.rank, emoji))
	end
	return table.concat(parts, " ")
end

local function applyRankGradient(label: TextLabel, rank: number)
	for _, child in label:GetChildren() do
		if child:IsA("UIGradient") then
			child:Destroy()
		end
	end
	local grad = Instance.new("UIGradient")
	grad.Color = RANK_GRADIENTS[rank] or DEFAULT_GRADIENT
	grad.Rotation = 90
	grad.Parent = label
	label.TextColor3 = Color3.new(1, 1, 1)
end

local function destroyBadge(player: Player)
	local badge = badgeByPlayer[player]
	if badge then
		badge:Destroy()
		badgeByPlayer[player] = nil
	end
end

local COL_W_STUDS = 1.35
local COL_H_STUDS = 1.55
local COL_GAP_STUDS = 0.2
local MAX_VIEW_DISTANCE = 42

local function buildBadge(player: Player, entries: { BoardRank }): BillboardGui?
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return nil
	end

	local showVip = playerOwnsVip(player)
	local count = #entries + if showVip then 1 else 0
	if count <= 0 then
		return nil
	end
	local totalW = count * COL_W_STUDS + math.max(0, count - 1) * COL_GAP_STUDS
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LeaderboardRankBadge"
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = MAX_VIEW_DISTANCE
	billboard.Size = UDim2.fromScale(totalW, COL_H_STUDS)
	billboard.StudsOffset = Vector3.new(0, 2.15, 0)
	billboard.Adornee = head
	billboard.ResetOnSpawn = false
	billboard.Parent = char

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = billboard

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(COL_GAP_STUDS / math.max(totalW, 0.01), 0)
	layout.Parent = root

	local colScaleW = COL_W_STUDS / math.max(totalW, 0.01)
	local order = 0

	if showVip then
		order += 1
		local col = Instance.new("Frame")
		col.Name = "VIP"
		col.BackgroundTransparency = 1
		col.Size = UDim2.fromScale(colScaleW, 1)
		col.LayoutOrder = order
		col.Parent = root

		local crown = Instance.new("TextLabel")
		crown.Name = "Crown"
		crown.BackgroundTransparency = 1
		crown.AnchorPoint = Vector2.new(0.5, 0)
		crown.Position = UDim2.fromScale(0.5, 0)
		crown.Size = UDim2.fromScale(1, 0.62)
		crown.Text = VIP_CROWN_EMOJI
		crown.TextScaled = true
		crown.Parent = col
		UiFonts.applyDisplayLabel(crown, 32, 20)

		local vipLabel = Instance.new("TextLabel")
		vipLabel.Name = "VIP"
		vipLabel.BackgroundTransparency = 1
		vipLabel.AnchorPoint = Vector2.new(0.5, 1)
		vipLabel.Position = UDim2.fromScale(0.5, 1)
		vipLabel.Size = UDim2.fromScale(1, 0.42)
		UiFonts.applyDisplayLabel(vipLabel, 22, 14)
		vipLabel.TextScaled = true
		vipLabel.Text = "VIP"
		vipLabel.TextColor3 = Color3.new(1, 1, 1)
		vipLabel.Parent = col
		local vipGrad = Instance.new("UIGradient")
		vipGrad.Color = VIP_CROWN_GRADIENT
		vipGrad.Rotation = 90
		vipGrad.Parent = vipLabel
		local vipStroke = Instance.new("UIStroke")
		vipStroke.Thickness = 1.6
		vipStroke.Color = Color3.fromRGB(10, 14, 18)
		vipStroke.Transparency = 0.15
		vipStroke.Parent = vipLabel
	end

	for _, info in ipairs(entries) do
		order += 1
		local col = Instance.new("Frame")
		col.Name = info.board
		col.BackgroundTransparency = 1
		col.Size = UDim2.fromScale(colScaleW, 1)
		col.LayoutOrder = order
		col.Parent = root

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.fromScale(0.5, 0)
		icon.Size = UDim2.fromScale(0.72, 0.58)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = ICON_BY_BOARD[info.board] or ""
		icon.Parent = col

		local rankLabel = Instance.new("TextLabel")
		rankLabel.Name = "Rank"
		rankLabel.BackgroundTransparency = 1
		rankLabel.AnchorPoint = Vector2.new(0.5, 1)
		rankLabel.Position = UDim2.fromScale(0.5, 1)
		rankLabel.Size = UDim2.fromScale(1, 0.42)
		UiFonts.applyDisplayLabel(rankLabel, 28, 18)
		rankLabel.TextScaled = true
		rankLabel.Text = "#" .. tostring(info.rank)
		rankLabel.Parent = col
		applyRankGradient(rankLabel, info.rank)

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.6
		stroke.Color = Color3.fromRGB(10, 14, 18)
		stroke.Transparency = 0.15
		stroke.Parent = rankLabel
	end

	return billboard
end

local function isInSafezone(player: Player): boolean
	return SafezoneUtil.isCharacterInSafezone(player.Character)
end

local function shouldShowBadge(player: Player): boolean
	-- Hide overhead rank icons while that player's custom chat bubble is up.
	if chatBubbleSuppress[player] == true then
		return false
	end
	-- Hide local overhead rank icons while a character world notif (Try again, etc.) is up.
	if localWorldNotifSuppress and player == localPlayer then
		return false
	end
	-- Hide overhead rank icons while that player is working out (dumbbell on feet).
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
		return false
	end
	-- Hide overhead rank icons during cutscenes / panel HUD hide.
	if GameplayUiVisibility.isHidden() then
		return false
	end
	-- Only visible while you and they are both in the safezone.
	if not isInSafezone(localPlayer) then
		return false
	end
	if not isInSafezone(player) then
		return false
	end
	local entries = ranksByUserId[player.UserId]
	if entries and #entries > 0 then
		return true
	end
	return playerOwnsVip(player)
end

local function refreshPlayerBadge(player: Player, forceRebuild: boolean?)
	local want = shouldShowBadge(player)
	local existing = badgeByPlayer[player]
	if not want then
		destroyBadge(player)
		return
	end
	if existing and existing.Parent and not forceRebuild then
		existing.Enabled = true
		return
	end
	destroyBadge(player)
	local entries = ranksByUserId[player.UserId] or {}
	if #entries == 0 and not playerOwnsVip(player) then
		return
	end
	local badge = buildBadge(player, entries)
	if badge then
		badgeByPlayer[player] = badge
	end
end

function M.setChatBubbleSuppress(player: Player, suppressed: boolean)
	if suppressed then
		chatBubbleSuppress[player] = true
	else
		chatBubbleSuppress[player] = nil
	end
	refreshPlayerBadge(player)
end

function M.setLocalWorldNotifSuppress(suppressed: boolean)
	localWorldNotifSuppress = suppressed == true
	refreshPlayerBadge(localPlayer)
end

local function refreshAllBadges(forceRebuild: boolean?)
	for _, player in Players:GetPlayers() do
		refreshPlayerBadge(player, forceRebuild)
	end
end

local function hookPlayer(player: Player)
	local existing = playerConns[player]
	if existing then
		for _, c in existing do
			c:Disconnect()
		end
	end
	local conns: { RBXScriptConnection } = {}
	table.insert(
		conns,
		player.CharacterAdded:Connect(function()
			task.defer(function()
				refreshPlayerBadge(player)
			end)
		end)
	)
	table.insert(
		conns,
		player:GetAttributeChangedSignal(GearConfig.WORKOUT_ACTIVE_ATTR):Connect(function()
			refreshPlayerBadge(player)
		end)
	)
	table.insert(
		conns,
		player:GetAttributeChangedSignal(StoreConfig.ATTR.VIP_OWNED):Connect(function()
			refreshPlayerBadge(player, true)
		end)
	)
	playerConns[player] = conns
	if player.Character then
		task.defer(function()
			refreshPlayerBadge(player)
		end)
	end
end

local function hookDataFolder(dataFolder: Folder)
	if wiredData then
		return
	end
	wiredData = true

	local function onDataChanged()
		rebuildRankCache(dataFolder)
		refreshAllBadges(true)
	end

	for _, boardName in BOARD_NAMES do
		local boardFolder = dataFolder:FindFirstChild(boardName)
		if boardFolder and boardFolder:IsA("Folder") then
			for rank = 1, TAG_ROW_COUNT do
				local rowFolder = boardFolder:FindFirstChild(tostring(rank))
				if rowFolder and rowFolder:IsA("Folder") then
					for _, child in rowFolder:GetChildren() do
						if child:IsA("ValueBase") then
							child.Changed:Connect(onDataChanged)
						end
					end
					rowFolder.ChildAdded:Connect(function(child)
						if child:IsA("ValueBase") then
							child.Changed:Connect(onDataChanged)
							onDataChanged()
						end
					end)
				end
			end
			boardFolder:GetAttributeChangedSignal("UpdatedAt"):Connect(onDataChanged)
		end
	end

	dataFolder.ChildAdded:Connect(function(child)
		if child:IsA("Folder") and table.find(BOARD_NAMES, child.Name) then
			onDataChanged()
		end
	end)

	onDataChanged()
end

function M.init()
	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
	end)

	task.spawn(function()
		local dataFolder = ReplicatedStorage:WaitForChild(DATA_FOLDER_NAME, 120)
		if not dataFolder or not dataFolder:IsA("Folder") then
			return
		end
		hookDataFolder(dataFolder)
	end)

	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		destroyBadge(player)
		chatBubbleSuppress[player] = nil
		local conns = playerConns[player]
		if conns then
			for _, c in conns do
				c:Disconnect()
			end
			playerConns[player] = nil
		end
	end)

	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end

	local pollAccum = 0
	local wasHudHidden = false
	RunService.Heartbeat:Connect(function(dt)
		local hudHidden = GameplayUiVisibility.isHidden()
		if hudHidden ~= wasHudHidden then
			wasHudHidden = hudHidden
			refreshAllBadges()
		end
		pollAccum += dt
		if pollAccum < SAFEZONE_POLL_INTERVAL then
			return
		end
		pollAccum = 0
		refreshAllBadges()
	end)
end

return M
