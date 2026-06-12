-- [ACTIVE] StoreHandler.server
--[[
	StoreHandler.server
	Wires every Store item that isn't already owned by another system:
	• Gamepass effects (VIP, 2x Cash, 2x Upgrades, Super/Mega Luck, X-Ray) applied
	  on PlayerAdded and re-checked after a gamepass purchase finishes.
	• Developer-product receipts (Exclusive Brainrot, Server Luck, Booster Packs,
	  Cash Bundles) registered through ProductHandlerServer.registerProductReceipt.
	• Server-wide luck timer + replication (ReplicatedStorage attributes + remote).
	• Shared helpers (grantBrainrot / grantLuckyBlock / placedIncomePerSecond) the
	  steal system also relies on.

	No new economy system is invented — brainrots are granted via the existing
	ServerStorage.BrainrotInternal.GrantBrainrotAndEquip path (same as LuckyBlock),
	lucky blocks via ServerStorage.LuckyBlockInternal.GrantLuckyBlock, and cash via
	the player "Cash" attribute used by Economy.server.
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local PlayerDataService = require(script.Parent.Modules:WaitForChild("PlayerDataService"))

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))

local STAND_TAG = "BrainrotStand"
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

local StoreServer = {}

-- ── BindableFunction lookups (created by LuckyBlock.server / brainrot system) ────

local function savePurchaseStateSoon(player: Player)
	task.defer(function()
		if not player.Parent then
			return
		end

		PlayerDataService.waitUntilLoaded(player)

		if player.Parent then
			PlayerDataService.savePlayerData(player)
		end
	end)
end

local function waitInternalBindable(folderName: string, bindableName: string, timeout: number?): BindableFunction?
	local deadline = os.clock() + (timeout or 15)
	repeat
		local folder = ServerStorage:FindFirstChild(folderName)
		local bf = folder and folder:FindFirstChild(bindableName)
		if bf and bf:IsA("BindableFunction") then
			return bf
		end
		task.wait(0.2)
	until os.clock() >= deadline
	return nil
end

local grantBrainrotBF: BindableFunction? = nil
local grantLuckyBlockBF: BindableFunction? = nil

task.spawn(function()
	grantBrainrotBF = waitInternalBindable("BrainrotInternal", "GrantBrainrotAndEquip", 60)
	if not grantBrainrotBF then
		warn("[StoreHandler] BrainrotInternal.GrantBrainrotAndEquip not found")
	end
end)
task.spawn(function()
	grantLuckyBlockBF = waitInternalBindable("LuckyBlockInternal", "GrantLuckyBlock", 60)
	if not grantLuckyBlockBF then
		warn("[StoreHandler] LuckyBlockInternal.GrantLuckyBlock not found")
	end
end)

-- ── Shared grant helpers ────────────────────────────────────────────────────────

function StoreServer.grantBrainrot(
	player: Player,
	brainrotName: string,
	opts: { equip: boolean?, sourcePath: string? }?
): boolean
	local def = Brainrots.getByName(brainrotName)
	if not def then
		warn("[StoreHandler] Unknown brainrot:", brainrotName)
		return false
	end
	local bf = grantBrainrotBF or waitInternalBindable("BrainrotInternal", "GrantBrainrotAndEquip", 5)
	if not bf then
		warn("[StoreHandler] grantBrainrot failed: BrainrotInternal.GrantBrainrotAndEquip bindable missing")
		return false
	end
	grantBrainrotBF = bf
	local shouldEquip = not (opts and opts.equip == false)
	local sourcePath = if opts and typeof(opts.sourcePath) == "string" then opts.sourcePath else ""
	local ok, granted = pcall(function()
		return bf:Invoke(player, {
			name = def.name,
			rarity = def.rarity,
			mutation = "normal",
			level = 1,
			baseIncome = def.baseIncome,
			sourcePath = sourcePath,
		}, { equip = shouldEquip })
	end)
	if not ok then
		warn("[StoreHandler] grantBrainrot invoke errored for", brainrotName, "->", granted)
		return false
	end
	if granted ~= true then
		warn("[StoreHandler] grantBrainrot returned false for", brainrotName)
	end
	return granted == true
end

function StoreServer.grantLuckyBlock(player: Player, blockName: string, variant: string?): boolean
	local bf = grantLuckyBlockBF or waitInternalBindable("LuckyBlockInternal", "GrantLuckyBlock", 5)
	if not bf then
		warn("[StoreHandler] grantLuckyBlock failed: LuckyBlockInternal.GrantLuckyBlock bindable missing")
		return false
	end
	grantLuckyBlockBF = bf
	local ok, result = pcall(function()
		return bf:Invoke(player, blockName, { equip = false, variant = variant })
	end)
	if not ok then
		warn("[StoreHandler] grantLuckyBlock invoke errored for", blockName, "->", result)
		return false
	end
	if result ~= true then
		warn("[StoreHandler] grantLuckyBlock returned false for", blockName, "variant:", variant)
	end
	return result == true
end

function StoreServer.addCash(player: Player, amount: number)
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + math.max(0, math.floor(amount)))
end

-- Sum of income/second of every brainrot currently placed on this player's stands.
function StoreServer.placedIncomePerSecond(player: Player): number
	local total = 0
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if stand:GetAttribute("StandOwnerUserId") == player.UserId then
			local name = stand:GetAttribute("BrainrotName")
			local rarity = stand:GetAttribute("BrainrotRarity")
			if typeof(name) == "string" and typeof(rarity) == "string" then
				local def = {
					name = name,
					rarity = rarity,
					baseIncome = stand:GetAttribute("BrainrotBaseIncome") or 0,
				}
				local level = stand:GetAttribute("BrainrotLevel")
				local mutation = stand:GetAttribute("BrainrotMutation")
				total += Brainrots.incomePerSecond(
					def,
					if typeof(level) == "number" then level else 1,
					if typeof(mutation) == "string" then mutation else "normal"
				)
			end
		end
	end
	return total
end

-- ── Remotes ─────────────────────────────────────────────────────────────────────

local function ensureRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "StoreRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = ensureRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local serverLuckUpdatedRE = ensureRemoteEvent("ServerLuckUpdated")
local freeBrainrotRE = ensureRemoteEvent("ClaimFreeBrainrot")
local closeStoreRE = ensureRemoteEvent("CloseStore")

local function notifyPurchaseComplete(player: Player)
	if player and player.Parent then
		closeStoreRE:FireClient(player)
	end
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local folder = ensureRemotesFolder()
	local rf = folder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = folder
	end
	return rf :: RemoteFunction
end

-- Client asks for the current cash-bundle reward amounts (depend on placed income).
local cashBundleRewardsRF = ensureRemoteFunction("GetCashBundleRewards")
cashBundleRewardsRF.OnServerInvoke = function(player: Player): { [number]: number }
	local incomePerSecond = StoreServer.placedIncomePerSecond(player)
	local offline24h = incomePerSecond * 86400
	local effective = math.max(offline24h, StoreConfig.MIN_OFFLINE_24H_CASH)
	local out: { [number]: number } = {}
	for productId, multiplier in StoreConfig.CASH_BUNDLE_MULTIPLIERS do
		out[productId] = math.floor(effective * multiplier)
	end
	return out
end

-- ── Server-wide luck ──────────────────────────────────────────────────────────────

local serverLuckMultiplier = 1
local serverLuckEndsAt = 0

local function publishServerLuck()
	ReplicatedStorage:SetAttribute(StoreConfig.SERVER_LUCK_MULT_ATTR, serverLuckMultiplier)
	ReplicatedStorage:SetAttribute(StoreConfig.SERVER_LUCK_ENDS_ATTR, serverLuckEndsAt)
	local remaining = math.max(0, serverLuckEndsAt - os.time())
	serverLuckUpdatedRE:FireAllClients(serverLuckMultiplier, remaining)
end

local function addServerLuck(player: Player?)
	local now = os.time()
	if serverLuckMultiplier <= 1 or now >= serverLuckEndsAt then
		-- Fresh activation.
		serverLuckMultiplier = 2
		serverLuckEndsAt = now + StoreConfig.SERVER_LUCK_DURATION
	else
		-- Stacks: double the multiplier and extend the timer.
		serverLuckMultiplier *= 2
		serverLuckEndsAt += StoreConfig.SERVER_LUCK_DURATION
	end
	warn(
		"[ServerLuck] purchased by",
		player and player.Name or "?",
		"new multiplier:",
		serverLuckMultiplier,
		"ends at:",
		serverLuckEndsAt
	)
	publishServerLuck()
end

publishServerLuck()

task.spawn(function()
	while true do
		task.wait(1)
		if serverLuckMultiplier > 1 and os.time() >= serverLuckEndsAt then
			serverLuckMultiplier = 1
			serverLuckEndsAt = 0
			publishServerLuck()
		end
	end
end)

-- ── Gamepass effects ─────────────────────────────────────────────────────────────

local StoreAccess = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreAccess"))

local function ownsGamePass(player: Player, gamePassId: number): boolean
	if not StoreAccess.shouldTrustMarketplaceOwnership(player) then
		return false
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	return ok and result == true
end

local function clearGamePassAttributes(player: Player)
	local A = StoreConfig.ATTR
	player:SetAttribute(A.VIP_OWNED, false)
	player:SetAttribute(A.VIP_LUCK_MULT, 1)
	player:SetAttribute(A.DOUBLE_CASH_OWNED, false)
	player:SetAttribute(A.DOUBLE_UPGRADES_OWNED, false)
	player:SetAttribute(A.SUPER_LUCK_OWNED, false)
	player:SetAttribute(A.MEGA_LUCK_OWNED, false)
	player:SetAttribute(A.XRAY_OWNED, false)
end

local function applyGamePassEffects(player: Player, fromPurchase: boolean?)
	local A = StoreConfig.ATTR
	local G = StoreConfig.GAMEPASS

	if not fromPurchase and StoreAccess.isPrivilegedMarketplaceTester(player) then
		clearGamePassAttributes(player)
		return
	end

	local ownsVip = ownsGamePass(player, G.VIP)
	local ownsCash = ownsGamePass(player, G.DOUBLE_CASH)
	local ownsUpgrades = ownsGamePass(player, G.DOUBLE_UPGRADES)
	local ownsSuper = ownsGamePass(player, G.SUPER_LUCK)
	local ownsMega = ownsGamePass(player, G.MEGA_LUCK)
	local ownsXray = ownsGamePass(player, G.XRAY)

	if ownsVip then
		player:SetAttribute(A.VIP_OWNED, true)
		player:SetAttribute(A.VIP_LUCK_MULT, StoreConfig.VIP_LUCK_MULTIPLIER)
		if fromPurchase then
			local current = player:GetAttribute(A.FREE_STEAL_COUNT)
			local count = if typeof(current) == "number" then current else 0
			if count < StoreConfig.VIP_FREE_STEALS then
				player:SetAttribute(A.FREE_STEAL_COUNT, StoreConfig.VIP_FREE_STEALS)
			end
		end
	else
		player:SetAttribute(A.VIP_OWNED, false)
		player:SetAttribute(A.VIP_LUCK_MULT, 1)
	end

	player:SetAttribute(A.DOUBLE_CASH_OWNED, ownsCash)
	player:SetAttribute(A.DOUBLE_UPGRADES_OWNED, ownsUpgrades)
	player:SetAttribute(A.SUPER_LUCK_OWNED, ownsSuper)
	player:SetAttribute(A.MEGA_LUCK_OWNED, ownsMega)
	player:SetAttribute(A.XRAY_OWNED, ownsXray)
end

local function initPlayerAttributes(player: Player)
	local A = StoreConfig.ATTR
	for _, attr in
		{
			A.EXCLUSIVE_OWNED,
			A.STARTER_PACK_BOUGHT,
			A.MYTHIC_PACK_BOUGHT,
			A.GODLY_PACK_BOUGHT,
			A.SECRET_PACK_BOUGHT,
		}
	do
		if player:GetAttribute(attr) == nil then
			player:SetAttribute(attr, if attr == A.EXCLUSIVE_OWNED then false else 0)
		end
	end
	if player:GetAttribute(A.FREE_UNCOMMON_CLAIMED) == nil then
		player:SetAttribute(A.FREE_UNCOMMON_CLAIMED, false)
	end
	if player:GetAttribute(A.FREE_STEAL_COUNT) == nil then
		player:SetAttribute(A.FREE_STEAL_COUNT, 0)
	end
	if player:GetAttribute(A.VIP_LUCK_MULT) == nil then
		player:SetAttribute(A.VIP_LUCK_MULT, 1)
	end
end

local function onPlayerAdded(player: Player)
	initPlayerAttributes(player)
	task.spawn(function()
		applyGamePassEffects(player)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	onPlayerAdded(p)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _gamePassId, wasPurchased)
	if wasPurchased and player and player.Parent then
		print(wasPurchased)
		task.spawn(function()
			applyGamePassEffects(player, true)
		end)
		notifyPurchaseComplete(player)
	end
end)

-- ── Developer-product receipt handlers ────────────────────────────────────────────

local function resolveProductHandlerServer(): any?
	local essentials = ServerScriptService:FindFirstChild("EssentialsServer")
	local folder = essentials and essentials:FindFirstChild("ProductHandler")
	local moduleScript = folder and folder:FindFirstChild("ProductHandlerServer")
	if not moduleScript then
		return nil
	end
	local ok, loaded = pcall(require, moduleScript)
	if ok then
		return loaded
	end
	return nil
end

local function registerReceipts()
	local PH = resolveProductHandlerServer()
	if not PH or typeof(PH.registerProductReceipt) ~= "function" then
		warn("[StoreHandler] ProductHandlerServer.registerProductReceipt unavailable")
		return
	end

	local P = StoreConfig.PRODUCT
	local A = StoreConfig.ATTR

	-- Exclusive Brainrot (one-time).
	PH.registerProductReceipt(P.EXCLUSIVE_BRAINROT, function(player)
		warn("[Exclusive] receipt fired for", player.Name)
		if player:GetAttribute(A.EXCLUSIVE_OWNED) == true then
			notifyPurchaseComplete(player)
			return GRANTED
		end
		if
			StoreServer.grantBrainrot(player, StoreConfig.EXCLUSIVE_BRAINROT_NAME, {
				equip = true,
				sourcePath = StoreConfig.EXCLUSIVE_BRAINROT_SOURCE_PATH,
			})
		then
			player:SetAttribute(A.EXCLUSIVE_OWNED, true)
			notifyPurchaseComplete(player)
			return GRANTED
		end
		warn("[Exclusive] grantBrainrot failed for", StoreConfig.EXCLUSIVE_BRAINROT_NAME)
		return NOT_PROCESSED
	end)

	-- Server Luck.
	PH.registerProductReceipt(P.SERVER_LUCK, function(player)
		addServerLuck(player)
		notifyPurchaseComplete(player)
		return GRANTED
	end)

	-- Booster packs.
	for _, pack in StoreConfig.PACKS do
		PH.registerProductReceipt(pack.productId, function(player)
			local bought = player:GetAttribute(pack.boughtAttr)
			local count = if typeof(bought) == "number" then bought else 0
			warn("[BoosterPack]", pack.key, "receipt fired for", player.Name, "count:", count)
			if count >= StoreConfig.PACK_PURCHASE_LIMIT then
				-- Sold out for this account; still mark granted so Roblox doesn't retry.
				warn("[BoosterPack]", pack.key, "already at purchase limit — granting nothing")
				notifyPurchaseComplete(player)
				return GRANTED
			end
			local gotBlock = StoreServer.grantLuckyBlock(player, pack.luckyBlock, pack.luckyBlockVariant)
			StoreServer.addCash(player, pack.cash)
			local gotBrainrot = StoreServer.grantBrainrot(player, pack.brainrot, { equip = false })
			warn(
				"[BoosterPack]",
				pack.key,
				"granted — luckyBlock:",
				gotBlock,
				"cash:",
				pack.cash,
				"brainrot:",
				pack.brainrot,
				gotBrainrot
			)
			player:SetAttribute(pack.boughtAttr, count + 1)
			savePurchaseStateSoon(player)
			notifyPurchaseComplete(player)
			return GRANTED
		end)
	end

	-- Cash bundles.
	for productId, multiplier in StoreConfig.CASH_BUNDLE_MULTIPLIERS do
		PH.registerProductReceipt(productId, function(player)
			warn("[CashBundle] handler fired for product:", productId, "player:", player.Name)
			local incomePerSecond = StoreServer.placedIncomePerSecond(player)
			local offline24h = incomePerSecond * 86400
			local effective = math.max(offline24h, StoreConfig.MIN_OFFLINE_24H_CASH)
			local reward = math.floor(effective * multiplier)
			warn("[CashBundle] incomePerSec:", incomePerSecond, "offline24h:", offline24h, "reward:", reward)
			StoreServer.addCash(player, reward)
			notifyPurchaseComplete(player)
			return GRANTED
		end)
	end
end

registerReceipts()

-- ── Free brainrot quick button (client-driven, one-time) ──────────────────────────

local freeBrainrotInFlight: { [Player]: boolean } = {}

freeBrainrotRE.OnServerEvent:Connect(function(player: Player)
	if freeBrainrotInFlight[player] then
		return
	end
	if player:GetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED) == true then
		return
	end
	freeBrainrotInFlight[player] = true

	local pool = Brainrots.brainrotsOfRarity("uncommon")
	if #pool == 0 then
		warn("[FreeBrainrot] no uncommon brainrots available to grant")
		freeBrainrotInFlight[player] = nil
		return
	end
	local pick = pool[math.random(1, #pool)]
	warn("[FreeBrainrot] granting", pick.name, "to", player.Name)
	if StoreServer.grantBrainrot(player, pick.name) then
		player:SetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED, true)
		notifyPurchaseComplete(player)
	else
		warn("[FreeBrainrot] grant failed for", pick.name)
	end
	freeBrainrotInFlight[player] = nil
end)

Players.PlayerRemoving:Connect(function(player)
	freeBrainrotInFlight[player] = nil
end)
