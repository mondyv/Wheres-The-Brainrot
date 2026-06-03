--[[
	StoreHandler.server
	Wires every Store item that isn't already owned by another system:
	• Gamepass effects (VIP, 2x Cash, 2x Upgrades, Super/Mega Luck, X-Ray) applied
	  on PlayerAdded and re-checked after a gamepass purchase finishes.
	• Developer-product receipts (Exclusive Brainrot, Server Luck, Booster Packs,
	  Cash Bundles) registered through ProductHandlerServer.registerProductReceipt.
	• Server-wide luck timer + replication (ReplicatedStorage attributes + remote).
	• VIP chat tag.
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

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))

local STAND_TAG = "BrainrotStand"
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

local StoreServer = {}

-- ── BindableFunction lookups (created by LuckyBlock.server / brainrot system) ────

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

function StoreServer.grantBrainrot(player: Player, brainrotName: string, opts: { equip: boolean? }?): boolean
	local def = Brainrots.getByName(brainrotName)
	if not def then
		warn("[StoreHandler] Unknown brainrot:", brainrotName)
		return false
	end
	local bf = grantBrainrotBF or waitInternalBindable("BrainrotInternal", "GrantBrainrotAndEquip", 5)
	if not bf then
		return false
	end
	grantBrainrotBF = bf
	local shouldEquip = not (opts and opts.equip == false)
	local ok = pcall(function()
		bf:Invoke(player, {
			name = def.name,
			rarity = def.rarity,
			mutation = "normal",
			level = 1,
			baseIncome = def.baseIncome,
		}, { equip = shouldEquip })
	end)
	return ok
end

function StoreServer.grantLuckyBlock(player: Player, blockName: string): boolean
	local bf = grantLuckyBlockBF or waitInternalBindable("LuckyBlockInternal", "GrantLuckyBlock", 5)
	if not bf then
		return false
	end
	grantLuckyBlockBF = bf
	local ok, result = pcall(function()
		return bf:Invoke(player, blockName, { equip = false })
	end)
	return ok and result == true
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

local function addServerLuck()
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
	publishServerLuck()
end

publishServerLuck()

task.spawn(function()
	while true do
		task.wait(1)
		if serverLuckMultiplier > 1 then
			if os.time() >= serverLuckEndsAt then
				serverLuckMultiplier = 1
				serverLuckEndsAt = 0
			end
			publishServerLuck()
		end
	end
end)

-- ── Gamepass effects ─────────────────────────────────────────────────────────────

local function ownsGamePass(player: Player, gamePassId: number): boolean
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	return ok and result == true
end

local function applyGamePassEffects(player: Player)
	local A = StoreConfig.ATTR
	local G = StoreConfig.GAMEPASS

	-- VIP
	if ownsGamePass(player, G.VIP) then
		if player:GetAttribute(A.VIP_OWNED) ~= true then
			player:SetAttribute(A.VIP_OWNED, true)
			player:SetAttribute(A.VIP_LUCK_MULT, StoreConfig.VIP_LUCK_MULTIPLIER)
			-- Grant free steals once on first detection.
			if player:GetAttribute(A.FREE_STEAL_COUNT) == nil then
				player:SetAttribute(A.FREE_STEAL_COUNT, StoreConfig.VIP_FREE_STEALS)
			end
		end
	end

	if ownsGamePass(player, G.DOUBLE_CASH) then
		player:SetAttribute(A.DOUBLE_CASH_OWNED, true)
	end
	if ownsGamePass(player, G.DOUBLE_UPGRADES) then
		player:SetAttribute(A.DOUBLE_UPGRADES_OWNED, true)
	end
	if ownsGamePass(player, G.SUPER_LUCK) then
		player:SetAttribute(A.SUPER_LUCK_OWNED, true)
	end
	if ownsGamePass(player, G.MEGA_LUCK) then
		player:SetAttribute(A.MEGA_LUCK_OWNED, true)
	end
	if ownsGamePass(player, G.XRAY) then
		player:SetAttribute(A.XRAY_OWNED, true)
	end
end

local function initPlayerAttributes(player: Player)
	local A = StoreConfig.ATTR
	for _, attr in {
		A.EXCLUSIVE_OWNED,
		A.STARTER_PACK_BOUGHT,
		A.MYTHIC_PACK_BOUGHT,
		A.GODLY_PACK_BOUGHT,
		A.SECRET_PACK_BOUGHT,
	} do
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
		task.spawn(function()
			applyGamePassEffects(player)
		end)
	end
end)

-- VIP chat tag is applied client-side via TextChatService.OnIncomingMessage in
-- StoreController (reads the replicated VIPOwned attribute of each sender).

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
		if player:GetAttribute(A.EXCLUSIVE_OWNED) == true then
			-- Already owned — refund decision so it isn't re-charged repeatedly.
			return GRANTED
		end
		if StoreServer.grantBrainrot(player, StoreConfig.EXCLUSIVE_BRAINROT_NAME) then
			player:SetAttribute(A.EXCLUSIVE_OWNED, true)
			return GRANTED
		end
		return NOT_PROCESSED
	end)

	-- Server Luck.
	PH.registerProductReceipt(P.SERVER_LUCK, function()
		addServerLuck()
		return GRANTED
	end)

	-- Booster packs.
	for _, pack in StoreConfig.PACKS do
		PH.registerProductReceipt(pack.productId, function(player)
			local bought = player:GetAttribute(pack.boughtAttr)
			local count = if typeof(bought) == "number" then bought else 0
			if count >= StoreConfig.PACK_PURCHASE_LIMIT then
				-- Sold out for this account; still mark granted so Roblox doesn't retry.
				return GRANTED
			end
			StoreServer.grantLuckyBlock(player, pack.luckyBlock)
			StoreServer.addCash(player, pack.cash)
			StoreServer.grantBrainrot(player, pack.brainrot, { equip = false })
			player:SetAttribute(pack.boughtAttr, count + 1)
			return GRANTED
		end)
	end

	-- Cash bundles.
	for productId, multiplier in StoreConfig.CASH_BUNDLE_MULTIPLIERS do
		PH.registerProductReceipt(productId, function(player)
			local incomePerSecond = StoreServer.placedIncomePerSecond(player)
			local offline24h = incomePerSecond * 86400
			local effective = math.max(offline24h, StoreConfig.MIN_OFFLINE_24H_CASH)
			local reward = math.floor(effective * multiplier)
			StoreServer.addCash(player, reward)
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
		freeBrainrotInFlight[player] = nil
		return
	end
	local pick = pool[math.random(1, #pool)]
	if StoreServer.grantBrainrot(player, pick.name) then
		player:SetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED, true)
	end
	freeBrainrotInFlight[player] = nil
end)

Players.PlayerRemoving:Connect(function(player)
	freeBrainrotInFlight[player] = nil
end)
