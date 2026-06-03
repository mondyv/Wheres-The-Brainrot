--[[
	VipChatController
	Client-only VIP chat prefix via TextChatService.OnIncomingMessage.

	OnIncomingMessage is a client callback — assign it directly (never read it back).
	Always return TextChatMessageProperties; only change PrefixText for VIP senders.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local VIP_GAMEPASS_ID = StoreConfig.GAMEPASS.VIP

local VipChatController = {}

-- Avoid yielding UserOwnsGamePassAsync on every chat line for the same user.
local vipOwnershipCache: { [number]: boolean } = {}

local function senderIsVip(userId: number): boolean
	local cached = vipOwnershipCache[userId]
	if cached ~= nil then
		return cached
	end

	local player = Players:GetPlayerByUserId(userId)
	if player and player:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true then
		vipOwnershipCache[userId] = true
		return true
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, VIP_GAMEPASS_ID)
	end)
	local isVip = ok and owns == true
	vipOwnershipCache[userId] = isVip
	return isVip
end

local function clearVipCache(userId: number)
	vipOwnershipCache[userId] = nil
end

local function init()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local props = Instance.new("TextChatMessageProperties")

		local source = message.TextSource
		if source and senderIsVip(source.UserId) then
			props.PrefixText = "<font color='rgb(255,165,0)'>[VIP]</font> " .. message.PrefixText
		end

		return props
	end

	-- Invalidate cache when server replicates ownership (e.g. after purchase this session).
	Players.PlayerAdded:Connect(function(plr)
		plr:GetAttributeChangedSignal(StoreConfig.ATTR.VIP_OWNED):Connect(function()
			clearVipCache(plr.UserId)
		end)
	end)
	for _, plr in Players:GetPlayers() do
		plr:GetAttributeChangedSignal(StoreConfig.ATTR.VIP_OWNED):Connect(function()
			clearVipCache(plr.UserId)
		end)
	end
	Players.PlayerRemoving:Connect(function(plr)
		clearVipCache(plr.UserId)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if wasPurchased and gamePassId == VIP_GAMEPASS_ID then
			clearVipCache(plr.UserId)
		end
	end)
end

function VipChatController.init()
	local ok, err = pcall(init)
	if not ok then
		warn("[VIPChat] setup failed:", err)
	end
end

return VipChatController
