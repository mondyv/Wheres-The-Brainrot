--[[
	Cash boost sources (shared client + server):
	• Rebirth — cumulative display % from RebirthConfig
	• Index golden quest — +25% when complete
	• Friend in server — +10% when any friend is playing
	• Daily reward Day 3 — permanent +5% per claim (DailyCashBoostPercent attribute)
--]]

local RebirthConfig = require(script.Parent:WaitForChild("RebirthConfig"))
local IndexConfig = require(script.Parent:WaitForChild("IndexConfig"))
local StoreConfig = require(script.Parent:WaitForChild("StoreConfig"))

local M = {}

M.FRIEND_BOOST_PERCENT = 10
M.FRIEND_BOOST_ATTR = "FriendCashBoost"
M.DAILY_BOOST_ATTR = "DailyCashBoostPercent"
M.INDEX_BOOST_PERCENT = (IndexConfig.CASH_BOOST_MULT - 1) * 100

function M.rebirthBoostPercent(rebirthCount: number): number
	if rebirthCount <= 0 then
		return 0
	end
	return RebirthConfig.moneyPercentDisplayForTier(rebirthCount)
end

function M.dailyBoostPercent(player: Player): number
	local raw = player:GetAttribute(M.DAILY_BOOST_ATTR)
	if typeof(raw) ~= "number" or raw <= 0 then
		return 0
	end
	return raw
end

function M.totalDisplayPercent(
	rebirthCount: number,
	indexComplete: boolean,
	friendBoost: boolean,
	dailyPercent: number?
): number
	local total = M.rebirthBoostPercent(rebirthCount)
	if indexComplete then
		total += M.INDEX_BOOST_PERCENT
	end
	if friendBoost then
		total += M.FRIEND_BOOST_PERCENT
	end
	if typeof(dailyPercent) == "number" and dailyPercent > 0 then
		total += dailyPercent
	end
	return total
end

-- Extra display % contributed by gamepasses: VIP (+50%) and 2x Cash (+100%).
function M.gamepassBoostPercent(player: Player): number
	local pct = 0
	if player:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true then
		pct += (StoreConfig.VIP_CASH_MULTIPLIER - 1) * 100
	end
	if player:GetAttribute(StoreConfig.ATTR.DOUBLE_CASH_OWNED) == true then
		pct += (StoreConfig.DOUBLE_CASH_MULTIPLIER - 1) * 100
	end
	return pct
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
	local dailyPct = M.dailyBoostPercent(player)
	if dailyPct > 0 then
		mult *= 1 + dailyPct / 100
	end
	-- VIP and 2x Cash gamepasses (multiplicative with everything else).
	if player:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true then
		mult *= StoreConfig.VIP_CASH_MULTIPLIER
	end
	if player:GetAttribute(StoreConfig.ATTR.DOUBLE_CASH_OWNED) == true then
		mult *= StoreConfig.DOUBLE_CASH_MULTIPLIER
	end
	return mult
end

return M
