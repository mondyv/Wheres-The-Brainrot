-- [ACTIVE] Daily.server
--[[
	Daily.server
	Hosts the daily rewards calendar: remotes, claim grant function, Skip-All dev product
	receipt routing. Reward delivery delegates to existing systems
	(Rebirth.performRebirth, BushHarvest's BrainrotInternal bindables, LuckyBlock).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ProductHandlerServer =
	require(game:GetService("ServerScriptService").EssentialsServer.ProductHandler.ProductHandlerServer)

local DailyConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DailyConfig"))
local CashBoostUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CashBoostUtil"))

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))
local DailyService = require(Modules:WaitForChild("DailyService"))

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("DailyRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DailyRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local folder = getRemotesFolder()
	local rf = folder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = folder
	end
	return rf :: RemoteFunction
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local getStateRF = ensureRemoteFunction("GetDailyState")
local claimRF = ensureRemoteFunction("ClaimDaily")
local updatedRE = ensureRemoteEvent("DailyUpdated")
local claimedRE = ensureRemoteEvent("DailyClaimed")
local promptSkipRE = ensureRemoteEvent("DailyPromptSkipAll")

DailyService.setRemote(updatedRE)

-- ── Helpers to talk to other server systems ──────────────────────────────────

local function brainrotInternalBF(name: string): BindableFunction?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		return nil
	end
	local bf = folder:FindFirstChild(name)
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

local function waitForBrainrotInternalBF(name: string, timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 60)
	while os.clock() < deadline do
		local bf = brainrotInternalBF(name)
		if bf then
			return bf
		end
		task.wait(0.25)
	end
	return brainrotInternalBF(name)
end

local function ensureLuckyBlockInternalBF(name: string, timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 60)
	while os.clock() < deadline do
		local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
		if folder then
			local bf = folder:FindFirstChild(name)
			if bf and bf:IsA("BindableFunction") then
				return bf
			end
		end
		task.wait(0.25)
	end
	return nil
end

local function pickRandomBrainrotByRarity(rarity: string): { name: string, rarity: string, baseIncome: number }?
	local candidates = {}
	for _, def in ipairs(Brainrots.BRAINROTS) do
		if def.rarity == rarity and Brainrots.isPlayableBrainrotName(def.name) then
			table.insert(candidates, def)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

local function addCash(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	local cur = player:GetAttribute("Cash")
	local c = if typeof(cur) == "number" then cur else 0
	player:SetAttribute("Cash", c + amount)
end

local function addDailyCashBoostPercent(player: Player, amount: number)
	local cur = player:GetAttribute(CashBoostUtil.DAILY_BOOST_ATTR)
	local c = if typeof(cur) == "number" then cur else 0
	player:SetAttribute(CashBoostUtil.DAILY_BOOST_ATTR, c + amount)
end

local function waitForRebirthBindable(timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 30)
	while os.clock() < deadline do
		local folder = ServerStorage:FindFirstChild("RebirthInternal")
		if folder then
			local bf = folder:FindFirstChild("PerformRebirth")
			if bf and bf:IsA("BindableFunction") then
				return bf
			end
		end
		task.wait(0.25)
	end
	return nil
end

local function tryPerformFreeRebirth(player: Player): boolean
	local bf = waitForRebirthBindable(60)
	if not bf then
		return false
	end
	local ok, success = pcall(function()
		return bf:Invoke(player, { skipRequirements = true, keepUpgrades = true })
	end)
	return ok and success == true
end

local function grantBrainrotRandomLegendary(player: Player): boolean
	local pick = pickRandomBrainrotByRarity("legendary")
	if not pick then
		return false
	end
	local grant = waitForBrainrotInternalBF("GrantBrainrotAndEquip", 60)
	if not grant then
		return false
	end
	local ok, success = pcall(function()
		return grant:Invoke(player, {
			name = pick.name,
			rarity = pick.rarity,
			mutation = "normal",
			level = 1,
			baseIncome = pick.baseIncome,
		}, { equip = true })
	end)
	return ok and success == true
end

local function grantLuckyBlockStarRainbow(player: Player): boolean
	local grant = ensureLuckyBlockInternalBF("GrantLuckyBlock", 5)
	if not grant then
		return false
	end
	local ok, success = pcall(function()
		return grant:Invoke(player, "star rainbow", { equip = true })
	end)
	return ok and success == true
end

-- ── Grant function ───────────────────────────────────────────────────────────

DailyService.setGrantFn(function(player: Player, reward: DailyConfig.DailyReward): (boolean, string?)
	if reward.kind == "cash" then
		addCash(player, reward.amount or 0)
		return true, nil
	elseif reward.kind == "cash_boost_percent" then
		addDailyCashBoostPercent(player, reward.amount or 0)
		return true, nil
	elseif reward.kind == "rebirth_free" then
		if tryPerformFreeRebirth(player) then
			return true, nil
		end
		return false, "rebirth_failed"
	elseif reward.kind == "random_legendary" then
		if grantBrainrotRandomLegendary(player) then
			return true, nil
		end
		return false, "brainrot_grant_failed"
	elseif reward.kind == "lucky_block_star_rainbow" then
		if grantLuckyBlockStarRainbow(player) then
			return true, nil
		end
		return false, "lucky_block_grant_failed"
	end
	return false, "unknown_kind"
end)

-- ── Remotes ─────────────────────────────────────────────────────────────────

getStateRF.OnServerInvoke = function(player: Player)
	return DailyService.getState(player)
end

claimRF.OnServerInvoke = function(player: Player, dayArg: any)
	if typeof(dayArg) ~= "number" then
		return false, "invalid_day"
	end
	local day = math.floor(dayArg)
	local ok, err, state = DailyService.claim(player, day)
	if ok then
		claimedRE:FireClient(player, { day = day, state = state })
	end
	return ok, err, state
end

-- ── Player lifecycle + Skip-All dev product ───────────────────────────────────

ProductHandlerServer.registerProductReceipt(DailyConfig.SKIP_ALL_DEV_PRODUCT_ID, function(player: Player)
	DailyService.grantSkipAll(player)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end)

local function onPlayer(player: Player)
	DailyService.initPlayer(player)
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in ipairs(Players:GetPlayers()) do
	task.defer(function()
		onPlayer(p)
	end)
end

-- Client can request a Skip-All prompt without bouncing through ProductHandler so the daily UI
-- stays self-contained; the actual purchase still goes through MarketplaceService.
promptSkipRE.OnServerEvent:Connect(function(player: Player)
	if player:GetAttribute(DailyConfig.SKIP_ALL_ATTR) == true then
		return
	end
	pcall(function()
		MarketplaceService:PromptProductPurchase(player, DailyConfig.SKIP_ALL_DEV_PRODUCT_ID)
	end)
end)
