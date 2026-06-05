-- [ACTIVE] FriendCashBoost.server
--[[
	Tracks whether each player has a friend in the server (+10% cash boost).
--]]

local Players = game:GetService("Players")

local CashBoostUtil = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("CashBoostUtil"))

local recomputeScheduled = false

local function recomputeForPlayer(player: Player)
	if player:GetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR) == nil then
		player:SetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR, false)
	end

	for _, other in Players:GetPlayers() do
		if other ~= player then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWith(other.UserId)
			end)
			if ok and isFriend then
				player:SetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR, true)
				return
			end
		end
	end
	player:SetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR, false)
end

local function recomputeAll()
	recomputeScheduled = false
	for _, player in Players:GetPlayers() do
		task.spawn(recomputeForPlayer, player)
	end
end

local function scheduleRecomputeAll()
	if recomputeScheduled then
		return
	end
	recomputeScheduled = true
	task.defer(recomputeAll)
end

local function bindPlayer(player: Player)
	if player:GetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR) == nil then
		player:SetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR, false)
	end
	task.spawn(recomputeForPlayer, player)
	scheduleRecomputeAll()
end

Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(function()
	scheduleRecomputeAll()
end)

for _, player in Players:GetPlayers() do
	bindPlayer(player)
end
