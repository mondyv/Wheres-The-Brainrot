-- [ACTIVE] LuckBoost
--[[
	LuckBoost
	Shared (client + server) calculation of a player's total luck multiplier.

	Sources, all multiplied together:
	• VIP gamepass        → VIPLuckMultiplier attribute (4x)
	• Super Luck gamepass → SuperLuckOwned attribute   (2x)
	• MEGA Luck gamepass  → MegaLuckOwned attribute     (3.5x)
	• Server Luck product → ReplicatedStorage ServerLuckMultiplier attribute

	The server reads this when rolling bush harvests; the client reads it for the
	"Overall Luck" HUD display so both stay in sync.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(script.Parent.StoreConfig)

local LuckBoost = {}

function LuckBoost.serverLuckMultiplier(): number
	local v = ReplicatedStorage:GetAttribute(StoreConfig.SERVER_LUCK_MULT_ATTR)
	if typeof(v) == "number" and v > 0 then
		return v
	end
	return 1
end

function LuckBoost.playerLuckMultiplier(player: Player): number
	local mult = 1

	local vip = player:GetAttribute(StoreConfig.ATTR.VIP_LUCK_MULT)
	if typeof(vip) == "number" and vip > 1 then
		mult *= vip
	end

	if player:GetAttribute(StoreConfig.ATTR.SUPER_LUCK_OWNED) == true then
		mult *= StoreConfig.SUPER_LUCK_MULTIPLIER
	end

	if player:GetAttribute(StoreConfig.ATTR.MEGA_LUCK_OWNED) == true then
		mult *= StoreConfig.MEGA_LUCK_MULTIPLIER
	end

	return mult
end

-- Total including the server-wide multiplier.
function LuckBoost.totalLuckMultiplier(player: Player): number
	return LuckBoost.playerLuckMultiplier(player) * LuckBoost.serverLuckMultiplier()
end

return LuckBoost
