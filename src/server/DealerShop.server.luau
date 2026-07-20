-- [ACTIVE] DealerShop
--[[
	Bootstraps DealerShopService, wires ReplicatedStorage.DealerRemotes, and
	registers the developer-product receipts (personal restock + 1x Robux buy).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DealerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DealerConfig"))
local DealerShopService = require(script.Parent:WaitForChild("Modules"):WaitForChild("DealerShopService"))

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

-- ── Remotes ─────────────────────────────────────────────────────────────────────

local function ensureDealerRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("DealerRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DealerRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local folder = ensureDealerRemotesFolder()
	local rf = folder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = folder
	end
	return rf :: RemoteFunction
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = ensureDealerRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

-- Reuse the existing Index-style TopNotif broadcast channel that
-- TopNotifController already listens to (ReplicatedStorage.Remotes.BroadcastTopNotif).
local function ensureTopNotifRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild("BroadcastTopNotif")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "BroadcastTopNotif"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local getStateRF = ensureRemoteFunction("GetState")
local buyCashRF = ensureRemoteFunction("BuyCash")
local buyRobuxRF = ensureRemoteFunction("BuyRobuxPrompt")
local stateChangedRE = ensureRemoteEvent("StateChanged")
-- Keep RestockNotify registered for older clients; StateChanged handles refresh now.
ensureRemoteEvent("RestockNotify")
local topNotifRE = ensureTopNotifRemote()

getStateRF.OnServerInvoke = function(player: Player)
	local ok, result = pcall(DealerShopService.getStateForPlayer, player)
	if not ok then
		warn("[DealerShop] GetState failed for", player.Name, result)
		return { nextRestockAt = os.time(), slots = {} }
	end
	return result
end

buyCashRF.OnServerInvoke = function(player: Player, slotIndex: any): (boolean, string?, any?)
	if typeof(slotIndex) ~= "number" then
		return false, "bad_slot", nil
	end
	local ok, granted, reason, state = pcall(DealerShopService.buyCash, player, slotIndex)
	if not ok then
		warn("[DealerShop] BuyCash errored for", player.Name, granted)
		return false, "internal_error", nil
	end
	return granted, reason, state
end

buyRobuxRF.OnServerInvoke = function(player: Player, slotIndex: any): (boolean, string?)
	if typeof(slotIndex) ~= "number" then
		return false, "bad_slot"
	end
	local ok, approved, reason = pcall(DealerShopService.requestRobuxBuy, player, slotIndex)
	if not ok then
		warn("[DealerShop] BuyRobuxPrompt errored for", player.Name, approved)
		return false, "internal_error"
	end
	-- Client prompts DealerConfig.PRODUCT.ROBUX_BUY_1X via PurchasePrompt after approval.
	return approved, reason
end

DealerShopService.onStateChanged(function(restocked: boolean, targetPlayer: Player?)
	if targetPlayer then
		if targetPlayer.Parent then
			stateChangedRE:FireClient(targetPlayer)
		end
		return
	end

	stateChangedRE:FireAllClients()
	if restocked then
		-- TopNotif only — RestockNotify is for shop refresh (StateChanged already covers that).
		topNotifRE:FireAllClients("The Brainrot Dealer just restocked!", "global")
	end
end)

DealerShopService.start()

-- ── Dev product receipts ─────────────────────────────────────────────────────────

local function resolveProductHandlerServer(): any?
	local essentials = ServerScriptService:FindFirstChild("EssentialsServer")
	local folder = essentials and essentials:FindFirstChild("ProductHandler")
	local moduleScript = folder and folder:FindFirstChild("ProductHandlerServer")
	if not moduleScript then
		return nil
	end
	local ok, loaded = pcall(require, moduleScript)
	return ok and loaded or nil
end

local function registerReceipts(): boolean
	local PH = resolveProductHandlerServer()
	if not PH or typeof(PH.registerProductReceipt) ~= "function" then
		return false
	end

	PH.registerProductReceipt(DealerConfig.PRODUCT.PERSONAL_RESTOCK, function(player: Player, _receiptInfo: any)
		local ok, err = pcall(DealerShopService.personalRestock, player)
		if not ok then
			warn("[DealerShop] personalRestock failed for", player.Name, err)
			return NOT_PROCESSED
		end
		return GRANTED
	end)

	PH.registerProductReceipt(DealerConfig.PRODUCT.ROBUX_BUY_1X, function(player: Player, _receiptInfo: any)
		local ok, granted = pcall(DealerShopService.grantRobuxBuy, player)
		if not ok or not granted then
			warn("[DealerShop] Robux buy grant failed for", player.Name, granted)
			return NOT_PROCESSED
		end
		return GRANTED
	end)

	return true
end

task.spawn(function()
	for _ = 1, 40 do
		if registerReceipts() then
			return
		end
		task.wait(0.5)
	end
	warn("[DealerShop] ProductHandlerServer.registerProductReceipt unavailable")
end)
