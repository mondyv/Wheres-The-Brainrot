-- [ACTIVE] CashBoostController
--[[
	Updates SideUI.Counters.Boost.CurrentBoost with total cash boost %.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CashBoostUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CashBoostUtil"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local boostLabel: TextLabel? = nil

local function refreshBoostLabel()
	if not boostLabel then
		return
	end
	local count = RebirthConfig.getRebirthCount(player)
	local indexComplete = player:GetAttribute("IndexGoldenQuestComplete") == true
	local friendBoost = player:GetAttribute(CashBoostUtil.FRIEND_BOOST_ATTR) == true
	local dailyPercent = CashBoostUtil.dailyBoostPercent(player)
	local percent = CashBoostUtil.totalDisplayPercent(count, indexComplete, friendBoost, dailyPercent)
	percent += CashBoostUtil.gamepassBoostPercent(player)
	boostLabel.Text = CashBoostUtil.formatBoostLabel(percent)
end

local function bindAttribute(attr: string)
	player:GetAttributeChangedSignal(attr):Connect(refreshBoostLabel)
end

local function init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[CashBoostController] Main ScreenGui missing")
		return
	end

	local counters = main:WaitForChild("SideUI"):WaitForChild("Counters")
	local boostFrame = counters:WaitForChild("Boost")
	local currentBoost = boostFrame:WaitForChild("CurrentBoost")
	if not currentBoost:IsA("TextLabel") then
		warn("[CashBoostController] CurrentBoost is not a TextLabel")
		return
	end
	boostLabel = currentBoost

	bindAttribute(RebirthConfig.REBIRTH_COUNT_ATTR)
	bindAttribute(RebirthConfig.MONEY_MULT_ATTR)
	bindAttribute("IndexGoldenQuestComplete")
	bindAttribute(CashBoostUtil.FRIEND_BOOST_ATTR)
	bindAttribute(CashBoostUtil.DAILY_BOOST_ATTR)
	bindAttribute(StoreConfig.ATTR.VIP_OWNED)
	bindAttribute(StoreConfig.ATTR.DOUBLE_CASH_OWNED)

	refreshBoostLabel()
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[CashBoostController]", err)
	end
end

return { init = boot }
