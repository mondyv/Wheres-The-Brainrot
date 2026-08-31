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
-- funnelName → last completed step number (stable funnels)
local lastFunnelStep: { [Player]: { [string]: number } } = {}
-- per-attempt sessions (shop / wave chase / this visit)
local shopSessionId: { [Player]: string } = {}
local shopSessionStep: { [Player]: number } = {}
local waveSessionId: { [Player]: string } = {}
local waveSessionStep: { [Player]: number } = {}
local playSessionId: { [Player]: string } = {}
local playSessionStart: { [Player]: number } = {}
local playSessionStep: { [Player]: number } = {}
local loopSessionId: { [Player]: string } = {}
local loopSessionStep: { [Player]: number } = {}
-- Core-loop / lucky-block: track whether starter block already counted
local openedNonStarterLucky: { [Player]: boolean } = {}

local function canSend(): boolean
	return not IS_STUDIO
end

local function stableSessionId(player: Player, funnelName: string): string
	return ("%s-%d"):format(funnelName, player.UserId)
end

local function getLast(player: Player, funnelName: string): number
	local map = lastFunnelStep[player]
	if not map then
		return 0
	end
	return map[funnelName] or 0
end

local function setLast(player: Player, funnelName: string, step: number)
	local map = lastFunnelStep[player]
	if not map then
		map = {}
		lastFunnelStep[player] = map
	end
	map[funnelName] = step
end

local function logFunnelStep(player: Player, funnelName: string, sessionId: string, step: number, name: string)
	if not canSend() then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId, step, name)
	end)
	if not ok then
		warn("[AnalyticsFunnel]", funnelName, "failed:", name, err)
	end
end

local function advanceStable(
	player: Player,
	funnelName: string,
	def: { step: number, id: string, name: string },
	opts: { allowSkip: boolean? }?
)
	local last = getLast(player, funnelName)
	if def.step <= last then
		return
	end
	local allowSkip = opts ~= nil and opts.allowSkip == true
	if not allowSkip and def.step > last + 1 then
		-- Fill skipped steps so Creator Hub drop-off stays readable.
		-- Callers that jump ahead should pass allowSkip and/or pre-fill.
		return
	end
	setLast(player, funnelName, def.step)
	logFunnelStep(player, funnelName, stableSessionId(player, funnelName), def.step, def.name)
end

----------------------------------------------------------------
-- Onboarding
----------------------------------------------------------------

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
	if not allowSkip and def.step > last + 1 then
		return
	end
	lastOnboardingStep[player] = def.step
	if stepId == "opened_bush" or stepId == "claimed_brainrot" or stepId == "placed_on_stand" then
		M.logSessionLoopId(player, stepId)
	end
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

----------------------------------------------------------------
-- World / land progression
----------------------------------------------------------------

function M.logProgressionId(player: Player, stepId: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local def = AnalyticsFunnelConfig.progressionById(stepId)
	if not def then
		return
	end
	advanceStable(player, AnalyticsFunnelConfig.WORLD_FUNNEL, def, { allowSkip = true })
end

function M.onReachedLand(player: Player, land: number)
	if typeof(land) ~= "number" then
		return
	end
	local n = math.floor(land)
	for _, def in AnalyticsFunnelConfig.WORLD do
		if typeof(def.land) == "number" and def.land <= n then
			advanceStable(player, AnalyticsFunnelConfig.WORLD_FUNNEL, def, { allowSkip = true })
		end
	end
end

----------------------------------------------------------------
-- Tim Cheese quests
----------------------------------------------------------------

function M.onTimQuestClaimed(player: Player, questIndex: number, allDone: boolean?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(questIndex) ~= "number" then
		return
	end
	local idx = math.floor(questIndex)
	-- Fill 1..idx so Hub shows a clean drop-off curve.
	for _, def in AnalyticsFunnelConfig.TIM_QUEST do
		if typeof(def.questIndex) == "number" and def.questIndex <= idx then
			advanceStable(player, AnalyticsFunnelConfig.TIM_QUEST_FUNNEL, def, { allowSkip = true })
		end
	end
	if allDone then
		local allDef = AnalyticsFunnelConfig.timQuestById("tim_all_quests")
		if allDef then
			advanceStable(player, AnalyticsFunnelConfig.TIM_QUEST_FUNNEL, allDef, { allowSkip = true })
		end
	end
end

----------------------------------------------------------------
-- Rebirth
----------------------------------------------------------------

function M.onFirstRebirth(player: Player)
	M.onRebirth(player, 1)
end

function M.onRebirth(player: Player, rebirthCount: number)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(rebirthCount) ~= "number" then
		return
	end
	local n = math.floor(rebirthCount)
	for _, def in AnalyticsFunnelConfig.REBIRTH do
		if typeof(def.rebirthCount) == "number" and def.rebirthCount <= n then
			advanceStable(player, AnalyticsFunnelConfig.REBIRTH_FUNNEL, def, { allowSkip = true })
		end
	end
end

----------------------------------------------------------------
-- Core loop (first sell / return / daily / lucky block)
----------------------------------------------------------------

function M.logCoreLoopId(player: Player, stepId: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local def = AnalyticsFunnelConfig.coreLoopById(stepId)
	if not def then
		return
	end
	-- Allow skip so first daily can fire even if they never sold, etc.
	advanceStable(player, AnalyticsFunnelConfig.CORE_LOOP_FUNNEL, def, { allowSkip = true })
end

function M.onFirstSell(player: Player)
	M.logCoreLoopId(player, "first_sell")
end

function M.onFirstReturn(player: Player)
	M.logCoreLoopId(player, "first_return")
end

function M.onFirstDailyClaim(player: Player)
	M.logCoreLoopId(player, "first_daily")
end

function M.onLuckyBlockOpened(player: Player, isStarter: boolean?)
	if isStarter == true then
		return
	end
	if openedNonStarterLucky[player] then
		return
	end
	openedNonStarterLucky[player] = true
	M.logCoreLoopId(player, "first_lucky_block")
end

----------------------------------------------------------------
-- Wave chase (per-chase session)
----------------------------------------------------------------

function M.waveChaseStarted(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local id = HttpService:GenerateGUID(false)
	waveSessionId[player] = id
	waveSessionStep[player] = 0
	local def = AnalyticsFunnelConfig.waveChaseById("wave_started")
	if not def then
		return
	end
	waveSessionStep[player] = def.step
	logFunnelStep(player, AnalyticsFunnelConfig.WAVE_CHASE_FUNNEL, id, def.step, def.name)
	M.logSessionLoopId(player, "chase_started")
end

function M.waveChaseEscaped(player: Player)
	local session = waveSessionId[player]
	if not session then
		M.waveChaseStarted(player)
		session = waveSessionId[player]
	end
	if not session then
		return
	end
	local def = AnalyticsFunnelConfig.waveChaseById("wave_escaped")
	if not def then
		return
	end
	local last = waveSessionStep[player] or 0
	if def.step <= last then
		return
	end
	waveSessionStep[player] = def.step
	logFunnelStep(player, AnalyticsFunnelConfig.WAVE_CHASE_FUNNEL, session, def.step, def.name)
	waveSessionId[player] = nil
	waveSessionStep[player] = nil
	M.logSessionLoopId(player, "chase_escaped")
end

function M.waveChaseDied(player: Player)
	-- Unfinished chase session = drop-off after "Chase Started".
	waveSessionId[player] = nil
	waveSessionStep[player] = nil
end

----------------------------------------------------------------
-- Shop checkout
----------------------------------------------------------------

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
	shopSessionStep[player] = stepNumber
	local name = stepName
	if typeof(name) ~= "string" or name == "" then
		local def = AnalyticsFunnelConfig.SHOP[stepNumber]
		name = if def then def.name else ("Step " .. tostring(stepNumber))
	end
	logFunnelStep(player, AnalyticsFunnelConfig.SHOP_FUNNEL, session, stepNumber, name)
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

----------------------------------------------------------------
-- Session stay + harvest loop (per join — drop-off means they left)
----------------------------------------------------------------

function M.logSessionLoopId(player: Player, stepId: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local def = AnalyticsFunnelConfig.sessionLoopById(stepId)
	if not def then
		return
	end
	local session = loopSessionId[player]
	if not session then
		session = HttpService:GenerateGUID(false)
		loopSessionId[player] = session
		loopSessionStep[player] = 0
	end
	local last = loopSessionStep[player] or 0
	if def.step <= last then
		return
	end
	loopSessionStep[player] = def.step
	logFunnelStep(player, AnalyticsFunnelConfig.SESSION_LOOP_FUNNEL, session, def.step, def.name)
end

function M.beginPlaySession(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if playSessionId[player] then
		return
	end
	local id = HttpService:GenerateGUID(false)
	playSessionId[player] = id
	playSessionStart[player] = os.clock()
	playSessionStep[player] = 0
	local def = AnalyticsFunnelConfig.SESSION_STAY[1]
	if def then
		playSessionStep[player] = def.step
		logFunnelStep(player, AnalyticsFunnelConfig.SESSION_STAY_FUNNEL, id, def.step, def.name)
	end
	M.logSessionLoopId(player, "joined")
end

function M.tickPlaySession(player: Player)
	local id = playSessionId[player]
	local startAt = playSessionStart[player]
	if not id or typeof(startAt) ~= "number" then
		return
	end
	local elapsed = os.clock() - startAt
	local last = playSessionStep[player] or 0
	for _, def in AnalyticsFunnelConfig.SESSION_STAY do
		local need = if typeof(def.sec) == "number" then def.sec else 0
		if elapsed >= need and def.step > last then
			playSessionStep[player] = def.step
			last = def.step
			logFunnelStep(player, AnalyticsFunnelConfig.SESSION_STAY_FUNNEL, id, def.step, def.name)
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	lastOnboardingStep[player] = nil
	lastFunnelStep[player] = nil
	shopSessionId[player] = nil
	shopSessionStep[player] = nil
	waveSessionId[player] = nil
	waveSessionStep[player] = nil
	playSessionId[player] = nil
	playSessionStart[player] = nil
	playSessionStep[player] = nil
	loopSessionId[player] = nil
	loopSessionStep[player] = nil
	openedNonStarterLucky[player] = nil
end)

return M
