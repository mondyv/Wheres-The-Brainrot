-- [ACTIVE] StoreAccess
--[[
	Helpers for store ownership checks.
	Roblox reports UserOwnsGamePassAsync = true for game/group owners even without a purchase.
	Real Robux purchases are persisted via Purchased* attributes / purchasedGamepasses save data.
--]]

local M = {}

local StoreConfig = require(script.Parent:WaitForChild("StoreConfig"))

local GROUP_OWNER_RANK = 254

function M.isPrivilegedMarketplaceTester(player: Player): boolean
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	if game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		if ok and typeof(rank) == "number" and rank >= GROUP_OWNER_RANK then
			return true
		end
	end
	return false
end

function M.shouldTrustMarketplaceOwnership(player: Player): boolean
	return not M.isPrivilegedMarketplaceTester(player)
end

function M.getGiftedGamePassAttribute(gamePassId: number): string?
	return StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID[gamePassId]
end

function M.hasGiftedGamePass(player: Player, gamePassId: number): boolean
	local attr = M.getGiftedGamePassAttribute(gamePassId)
	return attr ~= nil and player:GetAttribute(attr) == true
end

function M.getPurchasedGamePassAttribute(gamePassId: number): string?
	return StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID[gamePassId]
end

function M.hasPurchasedGamePass(player: Player, gamePassId: number): boolean
	local attr = M.getPurchasedGamePassAttribute(gamePassId)
	return attr ~= nil and player:GetAttribute(attr) == true
end

function M.hasEntitledGamePass(player: Player, gamePassId: number): boolean
	return M.hasGiftedGamePass(player, gamePassId) or M.hasPurchasedGamePass(player, gamePassId)
end

return M
