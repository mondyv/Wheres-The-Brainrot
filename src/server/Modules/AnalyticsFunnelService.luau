-- [ACTIVE] AnalyticsFunnelService
--[[
	Server-only Creator Hub funnel logging.
	Events only reach analytics in published games (not Studio / not clients).
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsFunnelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AnalyticsFunnelConfig"))

local M = {}

local IS_STUDIO = RunService:IsStudio()

local lastOnboardingStep: { [Player]: number } = {}
local lastProgressionStep: { [Player]: number } = {}
local shopSessionId: { [Player]: string } = {}
local shopSessionStep: { [Player]: number } = {}

local function canSend(): boolean
	return not IS_STUDIO
end

local function progressionSessionId(player: Player): string
	-- Stable per-user id so one-time progression continues across joins.
	return ("prog-%d"):format(player.UserId)
end

function M.logOnboardingId(player: Player, stepId: string, opts: { allowSkip: boolean? }?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local def = AnalyticsFunnelConfig.onboardingById(stepId)
	if not def then
		return
	end
	local last = lastOnboardingStep[player] or 0
	if def.step <= last then
		return
	end
	local allowSkip = opts ~= nil and opts.allowSkip == true
	-- Client reports must advance one step at a time (anti-exploit).
	if not allowSkip and def.step > last + 1 then
		return
	end
	lastOnboardingStep[player] = def.step
	if not canSend() then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, def.step, def.name)
	end)
	if not ok then
		warn("[AnalyticsFunnel] onboarding failed:", stepId, err)
	end
end

function M.logOnboardingStep(player: Player, stepNumber: number, opts: { allowSkip: boolean? }?)
	local def = AnalyticsFunnelConfig.onboardingByStep(stepNumber)
	if not def then
		return
	end
	M.logOnboardingId(player, def.id, opts)
end

function M.logProgressionId(player: Player, stepId: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local def = AnalyticsFunnelConfig.progressionById(stepId)
	if not def then
		return
	end
	local last = lastProgressionStep[player] or 0
	if def.step <= last then
		return
	end
	lastProgressionStep[player] = def.step
	if not canSend() then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			player,
			AnalyticsFunnelConfig.PROGRESSION_FUNNEL,
			progressionSessionId(player),
			def.step,
			def.name
		)
	end)
	if not ok then
		warn("[AnalyticsFunnel] progression failed:", stepId, err)
	end
end

function M.onReachedLand(player: Player, land: number)
	if typeof(land) ~= "number" then
		return
	end
	local n = math.floor(land)
	-- Log every milestone up to current land (skipped steps auto-complete in Hub).
	for _, def in AnalyticsFunnelConfig.PROGRESSION do
		if typeof(def.land) == "number" and def.land <= n then
			M.logProgressionId(player, def.id)
		end
	end
end

function M.onTimQuestClaimed(player: Player, questIndex: number, allDone: boolean?)
	local def = AnalyticsFunnelConfig.progressionForQuest(questIndex)
	if def then
		M.logProgressionId(player, def.id)
	end
	if allDone then
		M.logProgressionId(player, "tim_all_quests")
	end
end

function M.onFirstRebirth(player: Player)
	M.logProgressionId(player, "first_rebirth")
end

function M.beginShopSession(player: Player): string?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	local id = HttpService:GenerateGUID(false)
	shopSessionId[player] = id
	shopSessionStep[player] = 0
	M.logShopStep(player, 1, AnalyticsFunnelConfig.SHOP[1].name)
	return id
end

function M.logShopStep(player: Player, stepNumber: number, stepName: string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local session = shopSessionId[player]
	if not session then
		session = HttpService:GenerateGUID(false)
		shopSessionId[player] = session
		shopSessionStep[player] = 0
	end
	local last = shopSessionStep[player] or 0
	if stepNumber <= last then
		return
	end
	-- Checkout sessions may jump Opened → Prompted if open wasn't reported.
	shopSessionStep[player] = stepNumber
	local name = stepName
	if typeof(name) ~= "string" or name == "" then
		local def = AnalyticsFunnelConfig.SHOP[stepNumber]
		name = if def then def.name else ("Step " .. tostring(stepNumber))
	end
	if not canSend() then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			player,
			AnalyticsFunnelConfig.SHOP_FUNNEL,
			session,
			stepNumber,
			name
		)
	end)
	if not ok then
		warn("[AnalyticsFunnel] shop failed:", stepNumber, err)
	end
end

function M.shopOpened(player: Player)
	M.beginShopSession(player)
end

function M.shopPrompted(player: Player)
	if not shopSessionId[player] then
		M.beginShopSession(player)
	end
	M.logShopStep(player, 2, AnalyticsFunnelConfig.SHOP[2].name)
end

function M.shopPurchased(player: Player)
	if not shopSessionId[player] then
		M.beginShopSession(player)
		M.logShopStep(player, 2, AnalyticsFunnelConfig.SHOP[2].name)
	end
	M.logShopStep(player, 3, AnalyticsFunnelConfig.SHOP[3].name)
	shopSessionId[player] = nil
	shopSessionStep[player] = nil
end

function M.getLastOnboardingStep(player: Player): number
	return lastOnboardingStep[player] or 0
end

Players.PlayerRemoving:Connect(function(player)
	lastOnboardingStep[player] = nil
	lastProgressionStep[player] = nil
	shopSessionId[player] = nil
	shopSessionStep[player] = nil
end)

return M
