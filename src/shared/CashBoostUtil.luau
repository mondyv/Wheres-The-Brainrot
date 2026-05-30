--[[
	Cash boost sources (shared client + server):
	• Rebirth — cumulative display % from RebirthConfig
	• Index golden quest — +25% when complete
	• Friend in server — +10% when any friend is playing
--]]

local RebirthConfig = require(script.Parent:WaitForChild("RebirthConfig"))
local IndexConfig = require(script.Parent:WaitForChild("IndexConfig"))

local M = {}

M.FRIEND_BOOST_PERCENT = 10
M.FRIEND_BOOST_ATTR = "FriendCashBoost"
M.INDEX_BOOST_PERCENT = (IndexConfig.CASH_BOOST_MULT - 1) * 100

function M.rebirthBoostPercent(rebirthCount: number): number
	if rebirthCount <= 0 then
		return 0
	end
	return RebirthConfig.moneyPercentDisplayForTier(rebirthCount)
end

function M.totalDisplayPercent(rebirthCount: number, indexComplete: boolean, friendBoost: boolean): number
	local total = M.rebirthBoostPercent(rebirthCount)
	if indexComplete then
		total += M.INDEX_BOOST_PERCENT
	end
	if friendBoost then
		total += M.FRIEND_BOOST_PERCENT
	end
	return total
end

function M.formatBoostLabel(percent: number): string
	return string.format("Cash Boost: +%d%%", math.floor(percent + 0.5))
end

function M.getMoneyMultiplier(player: Player): number
	local mult = 1
	if player:GetAttribute("IndexGoldenQuestComplete") == true then
		mult *= IndexConfig.CASH_BOOST_MULT
	end
	local rebirthMult = player:GetAttribute(RebirthConfig.MONEY_MULT_ATTR)
	if typeof(rebirthMult) == "number" and rebirthMult > 0 then
		mult *= rebirthMult
	end
	if player:GetAttribute(M.FRIEND_BOOST_ATTR) == true then
		mult *= 1 + M.FRIEND_BOOST_PERCENT / 100
	end
	return mult
end

return M
