--// < Made by: MikePlayz163 >

-->> || Services || <<--

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

-->> || Variables || <<--

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

-->> || Modules || <<--

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local ItemService = require(script.Parent:WaitForChild("ItemService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local Utils = require(script.Parent:WaitForChild("Utils"))

local STAND_TAG = "BrainrotStand"

local function playerPlotIncomePerSecond(player: Player): number
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

-->> || Types || <<--

export type GiftType = "Item" | "Product" | "Gamepass"

export type GiftResultPayload = {
	success: boolean,
	giftType: GiftType,
	message: string,
	status: string?,
	targetUserId: number?,
	itemUid: string?,
	productId: number?,
	gamepassId: number?,
}

export type GiftNotificationPayload = {
	giftType: GiftType,
	fromUserId: number,
	fromName: string,
	itemUid: string?,
	itemName: string?,
	productId: number?,
	gamepassId: number?,
}

export type PendingProductGift = {
	targetUserId: number,
	productId: number,
	createdAt: number,
}

export type PendingGamepassGift = {
	targetUserId: number,
	gamepassId: number,
	giftProductId: number,
	createdAt: number,
}

export type Controller = {
	__index: any,
	_CONFIG: {
		GIFT_DISTANCE: number,
		GIFT_COOLDOWN: number,
		PENDING_GIFT_TIMEOUT: number,
	},
	_pendingProductGifts: { [number]: PendingProductGift },
	_pendingGamepassGifts: { [number]: PendingGamepassGift },
	_giftCooldowns: { [string]: number },
	_activeGiftRequests: { [string]: boolean },

	Init: (self: Controller) -> (),
	Setup: (self: Controller) -> (),
	Cleanup: (self: Controller) -> (),

	RequestItemGift: (self: Controller, sender: Player, targetUserId: number, itemUid: string) -> (boolean, string?),
	RequestProductGift: (
		self: Controller,
		sender: Player,
		targetUserId: number,
		productId: number
	) -> (boolean, string?),
	RequestGamepassGift: (
		self: Controller,
		sender: Player,
		targetUserId: number,
		gamepassId: number
	) -> (boolean, string?),

	ConsumePendingProductGift: (self: Controller, purchaser: Player, productId: number) -> PendingProductGift?,
	ConsumePendingGamepassGift: (self: Controller, purchaser: Player, gamepassId: number) -> PendingGamepassGift?,

	GrantGiftedGamepass: (self: Controller, target: Player, gamepassId: number) -> (boolean, string?),
	PlayerHasGiftedGamepass: (self: Controller, player: Player, gamepassId: number) -> boolean,
}

-->> || Configuration || <<--

local _CONFIG = {
	GIFT_DISTANCE = 12,
	GIFT_COOLDOWN = 2,
	PENDING_GIFT_TIMEOUT = 60,
}

local OWNED_ATTR_BY_GAMEPASS_ID: { [number]: string } = {
	[StoreConfig.GAMEPASS.VIP] = StoreConfig.ATTR.VIP_OWNED,
	[StoreConfig.GAMEPASS.XRAY] = StoreConfig.ATTR.XRAY_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = StoreConfig.ATTR.DOUBLE_CASH_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_POWER] = StoreConfig.ATTR.DOUBLE_POWER_OWNED,
	[StoreConfig.GAMEPASS.MEGA_LUCK] = StoreConfig.ATTR.MEGA_LUCK_OWNED,
	[StoreConfig.GAMEPASS.AUTOCOLLECT] = StoreConfig.ATTR.AUTOCOLLECT_OWNED,
}

-->> || Main ~ Utilities || <<--

local Main = {} :: Controller
Main.__index = Main

Main._CONFIG = _CONFIG
Main._pendingProductGifts = {}
Main._pendingGamepassGifts = {}
Main._giftCooldowns = {}
Main._activeGiftRequests = {}

local _remotesFolder = nil
local requestItemGiftRE = nil
local requestProductGiftRE = nil
local requestGamepassGiftRE = nil
local giftResultRE = nil
local giftNotificationRE = nil
local connections: { RBXScriptConnection } = {}
local disconnectReceiptInterceptor: (() -> ())? = nil
local initialized = false

local function cooldownKey(player: Player, giftType: GiftType): string
	return tostring(player.UserId) .. ":" .. giftType
end

local function activeKey(player: Player, giftType: GiftType): string
	return tostring(player.UserId) .. ":" .. giftType
end

local function ensureGiftRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("GiftRemotes")
	if folder and folder:IsA("Folder") then
		_remotesFolder = folder
		return folder
	end

	local created = Instance.new("Folder")
	created.Name = "GiftRemotes"
	created.Parent = ReplicatedStorage
	_remotesFolder = created
	return created
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = ensureGiftRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

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

-->> || Private API || <<--

function Main:_fireResult(sender: Player?, payload: GiftResultPayload)
	if sender and sender.Parent and giftResultRE then
		giftResultRE:FireClient(sender, payload)
	end
end

function Main:_fireFailure(sender: Player?, giftType: GiftType, message: string, extra: any?): (boolean, string)
	local payload: any = {
		success = false,
		giftType = giftType,
		message = message,
		status = "Failed",
	}

	if typeof(extra) == "table" then
		for key, value in extra do
			payload[key] = value
		end
	end

	self:_fireResult(sender, payload)
	return false, message
end

function Main:_fireSuccess(sender: Player?, giftType: GiftType, message: string, extra: any?): (boolean, string?)
	local payload: any = {
		success = true,
		giftType = giftType,
		message = message,
		status = "Completed",
	}

	if typeof(extra) == "table" then
		for key, value in extra do
			payload[key] = value
		end
	end

	self:_fireResult(sender, payload)
	return true, nil
end

function Main:_fireNotification(target: Player, payload: GiftNotificationPayload)
	if target.Parent and giftNotificationRE then
		giftNotificationRE:FireClient(target, payload)
	end
end

function Main:_validateTarget(sender: Player, targetUserId: number, giftType: GiftType): (Player?, string?)
	local senderValid, senderErr = Utils:ValidatePlayer(sender)
	if not senderValid then
		return nil, senderErr or "Invalid sender."
	end

	if typeof(targetUserId) ~= "number" then
		return nil, "Target player was not found."
	end

	local target = Players:GetPlayerByUserId(math.floor(targetUserId))
	if not target then
		return nil, "Target player was not found."
	end

	if target == sender then
		return nil, "You cannot gift yourself."
	end

	if not Utils:IsAlive(sender) or not Utils:IsAlive(target) then
		return nil, "Both players must be alive."
	end

	if not Utils:IsWithinDistance(sender, target, self._CONFIG.GIFT_DISTANCE) then
		return nil, "Target is too far away."
	end

	local key = cooldownKey(sender, giftType)
	local lastGift = self._giftCooldowns[key]
	if typeof(lastGift) == "number" and os.clock() - lastGift < self._CONFIG.GIFT_COOLDOWN then
		return nil, "You are gifting too quickly."
	end

	local requestKey = activeKey(sender, giftType)
	if self._activeGiftRequests[requestKey] then
		return nil, "You already have an active gift request."
	end

	return target, nil
end

function Main:_markRequestStarted(sender: Player, giftType: GiftType)
	self._activeGiftRequests[activeKey(sender, giftType)] = true
end

function Main:_markRequestFinished(sender: Player, giftType: GiftType, applyCooldown: boolean?)
	self._activeGiftRequests[activeKey(sender, giftType)] = nil

	if applyCooldown ~= false then
		self._giftCooldowns[cooldownKey(sender, giftType)] = os.clock()
	end
end

function Main:_pendingIsFresh(createdAt: number): boolean
	return os.clock() - createdAt <= self._CONFIG.PENDING_GIFT_TIMEOUT
end

function Main:_clearPendingForPlayer(player: Player)
	local userId = player.UserId
	local userPrefix = tostring(userId) .. ":"

	self._pendingProductGifts[userId] = nil
	self._pendingGamepassGifts[userId] = nil

	for purchaserUserId, pending in self._pendingProductGifts do
		if pending.targetUserId == userId then
			self._pendingProductGifts[purchaserUserId] = nil

			local purchaser = Players:GetPlayerByUserId(purchaserUserId)
			if purchaser then
				self:_markRequestFinished(purchaser, "Product", false)
				self:_fireFailure(purchaser, "Product", "Gift purchase expired.", {
					status = "Expired",
					productId = pending.productId,
					targetUserId = userId,
				})
			else
				self._activeGiftRequests[tostring(purchaserUserId) .. ":Product"] = nil
			end
		end
	end

	for purchaserUserId, pending in self._pendingGamepassGifts do
		if pending.targetUserId == userId then
			self._pendingGamepassGifts[purchaserUserId] = nil

			local purchaser = Players:GetPlayerByUserId(purchaserUserId)
			if purchaser then
				self:_markRequestFinished(purchaser, "Gamepass", false)
				self:_fireFailure(purchaser, "Gamepass", "Gift purchase expired.", {
					status = "Expired",
					gamepassId = pending.gamepassId,
					productId = pending.giftProductId,
					targetUserId = userId,
				})
			else
				self._activeGiftRequests[tostring(purchaserUserId) .. ":Gamepass"] = nil
			end
		end
	end

	for key in self._activeGiftRequests do
		if string.find(key, userPrefix, 1, true) == 1 then
			self._activeGiftRequests[key] = nil
		end
	end

	for key in self._giftCooldowns do
		if string.find(key, userPrefix, 1, true) == 1 then
			self._giftCooldowns[key] = nil
		end
	end
end

function Main:_clearExpiredPendingForPlayer(player: Player)
	local productPending = self._pendingProductGifts[player.UserId]
	if productPending and not self:_pendingIsFresh(productPending.createdAt) then
		self._pendingProductGifts[player.UserId] = nil
		self:_markRequestFinished(player, "Product", false)
		self:_fireFailure(player, "Product", "Gift purchase expired.", {
			status = "Expired",
			productId = productPending.productId,
			targetUserId = productPending.targetUserId,
		})
	end

	local gamepassPending = self._pendingGamepassGifts[player.UserId]
	if gamepassPending and not self:_pendingIsFresh(gamepassPending.createdAt) then
		self._pendingGamepassGifts[player.UserId] = nil
		self:_markRequestFinished(player, "Gamepass", false)
		self:_fireFailure(player, "Gamepass", "Gift purchase expired.", {
			status = "Expired",
			gamepassId = gamepassPending.gamepassId,
			targetUserId = gamepassPending.targetUserId,
		})
	end
end

function Main:_validateItemGift(sender: Player, target: Player, itemUid: string): (boolean, string?, any?)
	if typeof(itemUid) ~= "string" or itemUid == "" then
		return false, "Item was not found in your inventory.", nil
	end

	local _, item = ItemService:FindItemByUid(sender, itemUid)
	if not item then
		return false, "Item was not found in your inventory.", nil
	end

	if item.locked == true or item.favorited == true then
		return false, "That item cannot be gifted.", nil
	end

	local canReceive, receiveErr = ItemService:CanReceiveBrainrot(target)
	if not canReceive then
		local message = if receiveErr == "target_inventory_full"
			then "Target inventory is full."
			else "Target cannot receive this item."
		return false, message, nil
	end

	return true, nil, item
end

function Main:_validateProductGift(productId: number): (boolean, string?, any?)
	if typeof(productId) ~= "number" then
		return false, "That product cannot be gifted.", nil
	end

	local giftable = StoreConfig.GIFTABLE_PRODUCTS[math.floor(productId)]
	if typeof(giftable) ~= "table" then
		return false, "That product cannot be gifted.", nil
	end

	return true, nil, giftable
end

function Main:_validateGamepassGift(gamepassId: number): (boolean, string?, any?)
	if typeof(gamepassId) ~= "number" then
		return false, "That gamepass cannot be gifted.", nil
	end

	local giftable = StoreConfig.GIFTABLE_GAMEPASSES[math.floor(gamepassId)]
	if typeof(giftable) ~= "table" then
		return false, "That gamepass cannot be gifted.", nil
	end

	if typeof(giftable.giftProductId) ~= "number" or giftable.giftProductId <= 0 then
		return false, "Gift product is not configured yet.", nil
	end

	return true, nil, giftable
end

function Main:_grantGiftableProduct(target: Player, productId: number, giftable: any): (boolean, string?, string?)
	if giftable.rewardKind == "randomBrainrot" then
		local ok, err = ItemService:GiveRandomBrainrot(target, nil, {
			equip = false,
			plotIncomePerSecond = playerPlotIncomePerSecond(target),
		})
		if ok then
			return true, nil, "Random Brainrot"
		end
		return false, err or "product_grant_failed", nil
	end

	return false, "unknown_product_reward", nil
end

function Main:_processProductGiftReceipt(purchaser: Player, productId: number): Enum.ProductPurchaseDecision?
	local pending = self._pendingProductGifts[purchaser.UserId]
	if not pending or pending.productId ~= productId then
		return nil
	end

	if not self:_pendingIsFresh(pending.createdAt) then
		self._pendingProductGifts[purchaser.UserId] = nil
		self:_markRequestFinished(purchaser, "Product", false)
		self:_fireFailure(purchaser, "Product", "Gift purchase expired.", {
			status = "Expired",
			productId = productId,
			targetUserId = pending.targetUserId,
		})
		return NOT_PROCESSED
	end

	local giftable = StoreConfig.GIFTABLE_PRODUCTS[productId]
	local target = Players:GetPlayerByUserId(pending.targetUserId)
	if not target or typeof(giftable) ~= "table" then
		self:_fireFailure(purchaser, "Product", "Gift purchase expired.", {
			status = "Expired",
			productId = productId,
			targetUserId = pending.targetUserId,
		})
		return NOT_PROCESSED
	end

	local granted, grantErr, itemName = self:_grantGiftableProduct(target, productId, giftable)
	if not granted then
		self:_fireFailure(purchaser, "Product", "Gift could not be delivered.", {
			status = "Failed",
			productId = productId,
			targetUserId = target.UserId,
		})
		warn("[GiftsService] Product gift grant failed:", productId, grantErr)
		return NOT_PROCESSED
	end

	self._pendingProductGifts[purchaser.UserId] = nil
	self:_markRequestFinished(purchaser, "Product")

	self:_fireSuccess(purchaser, "Product", "Gift sent successfully.", {
		status = "Completed",
		productId = productId,
		targetUserId = target.UserId,
	})

	self:_fireNotification(target, {
		giftType = "Product",
		fromUserId = purchaser.UserId,
		fromName = purchaser.Name,
		productId = productId,
		itemName = itemName,
	})

	return GRANTED
end

function Main:_consumePendingGamepassProduct(purchaser: Player, productId: number): PendingGamepassGift?
	local pending = self._pendingGamepassGifts[purchaser.UserId]
	if not pending then
		return nil
	end

	if pending.giftProductId ~= productId then
		return nil
	end

	if not self:_pendingIsFresh(pending.createdAt) then
		self._pendingGamepassGifts[purchaser.UserId] = nil
		self:_markRequestFinished(purchaser, "Gamepass", false)
		self:_fireFailure(purchaser, "Gamepass", "Gift purchase expired.", {
			status = "Expired",
			gamepassId = pending.gamepassId,
			targetUserId = pending.targetUserId,
		})
		return nil
	end

	self._pendingGamepassGifts[purchaser.UserId] = nil
	self:_markRequestFinished(purchaser, "Gamepass")
	return pending
end

function Main:_processGamepassGiftReceipt(purchaser: Player, productId: number): Enum.ProductPurchaseDecision?
	local pending = self._pendingGamepassGifts[purchaser.UserId]
	if not pending or pending.giftProductId ~= productId then
		return nil
	end

	if not self:_pendingIsFresh(pending.createdAt) then
		self._pendingGamepassGifts[purchaser.UserId] = nil
		self:_markRequestFinished(purchaser, "Gamepass", false)
		self:_fireFailure(purchaser, "Gamepass", "Gift purchase expired.", {
			status = "Expired",
			gamepassId = pending.gamepassId,
			productId = productId,
			targetUserId = pending.targetUserId,
		})
		return NOT_PROCESSED
	end

	local target = Players:GetPlayerByUserId(pending.targetUserId)
	if not target then
		self:_fireFailure(purchaser, "Gamepass", "Gift purchase expired.", {
			status = "Expired",
			gamepassId = pending.gamepassId,
			productId = productId,
			targetUserId = pending.targetUserId,
		})
		return NOT_PROCESSED
	end

	local granted, grantErr = self:GrantGiftedGamepass(target, pending.gamepassId)
	if not granted then
		self:_fireFailure(purchaser, "Gamepass", "Gift could not be delivered.", {
			status = "Failed",
			gamepassId = pending.gamepassId,
			productId = productId,
			targetUserId = target.UserId,
		})
		warn("[GiftsService] Gamepass gift grant failed:", pending.gamepassId, grantErr)
		return NOT_PROCESSED
	end

	self._pendingGamepassGifts[purchaser.UserId] = nil
	self:_markRequestFinished(purchaser, "Gamepass")

	self:_fireSuccess(purchaser, "Gamepass", "Gift sent successfully.", {
		status = "Completed",
		gamepassId = pending.gamepassId,
		productId = productId,
		targetUserId = target.UserId,
	})

	self:_fireNotification(target, {
		giftType = "Gamepass",
		fromUserId = purchaser.UserId,
		fromName = purchaser.Name,
		gamepassId = pending.gamepassId,
	})

	return GRANTED
end

function Main:_receiptInterceptor(player: Player, receiptInfo: any): Enum.ProductPurchaseDecision?
	if typeof(receiptInfo) ~= "table" or typeof(receiptInfo.ProductId) ~= "number" then
		return nil
	end

	local productDecision = self:_processProductGiftReceipt(player, receiptInfo.ProductId)
	if productDecision ~= nil then
		return productDecision
	end

	local gamepassDecision = self:_processGamepassGiftReceipt(player, receiptInfo.ProductId)
	if gamepassDecision ~= nil then
		return gamepassDecision
	end

	return nil
end

function Main:_registerReceiptInterceptor()
	if disconnectReceiptInterceptor then
		return
	end

	local productHandler = resolveProductHandlerServer()
	if not productHandler or typeof(productHandler.registerReceiptInterceptor) ~= "function" then
		warn("[GiftsService] ProductHandlerServer.registerReceiptInterceptor unavailable")
		return
	end

	disconnectReceiptInterceptor = productHandler.registerReceiptInterceptor(function(player: Player, receiptInfo: any)
		return self:_receiptInterceptor(player, receiptInfo)
	end)
end

-->> || Public API || <<--

function Main:Setup()
	if initialized then
		return
	end

	requestItemGiftRE = ensureRemoteEvent("RequestItemGift")
	requestProductGiftRE = ensureRemoteEvent("RequestProductGift")
	requestGamepassGiftRE = ensureRemoteEvent("RequestGamepassGift")
	giftResultRE = ensureRemoteEvent("GiftResult")
	giftNotificationRE = ensureRemoteEvent("GiftNotification")

	table.insert(
		connections,
		requestItemGiftRE.OnServerEvent:Connect(function(sender: Player, targetUserId: any, itemUid: any)
			self:RequestItemGift(sender, targetUserId, itemUid)
		end)
	)

	table.insert(
		connections,
		requestProductGiftRE.OnServerEvent:Connect(function(sender: Player, targetUserId: any, productId: any)
			self:RequestProductGift(sender, targetUserId, productId)
		end)
	)

	table.insert(
		connections,
		requestGamepassGiftRE.OnServerEvent:Connect(function(sender: Player, targetUserId: any, gamepassId: any)
			self:RequestGamepassGift(sender, targetUserId, gamepassId)
		end)
	)

	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			self:_clearPendingForPlayer(player)
		end)
	)

	self:_registerReceiptInterceptor()
	initialized = true
end

function Main:Init()
	self:Setup()
end

function Main:Cleanup()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	if disconnectReceiptInterceptor then
		disconnectReceiptInterceptor()
		disconnectReceiptInterceptor = nil
	end

	table.clear(self._pendingProductGifts)
	table.clear(self._pendingGamepassGifts)
	table.clear(self._giftCooldowns)
	table.clear(self._activeGiftRequests)
	initialized = false
end

function Main:RequestItemGift(sender: Player, targetUserId: number, itemUid: string): (boolean, string?)
	local target, targetErr = self:_validateTarget(sender, targetUserId, "Item")
	if not target then
		return self:_fireFailure(sender, "Item", targetErr or "Target player was not found.", {
			targetUserId = targetUserId,
			itemUid = itemUid,
		})
	end

	local validItem, itemErr, item = self:_validateItemGift(sender, target, itemUid)
	if not validItem then
		return self:_fireFailure(sender, "Item", itemErr or "That item cannot be gifted.", {
			targetUserId = target.UserId,
			itemUid = itemUid,
		})
	end

	self:_markRequestStarted(sender, "Item")
	local transferred, transferErr, transferredItem =
		ItemService:TransferBrainrot(sender, target, itemUid, { equip = false })
	self:_markRequestFinished(sender, "Item")

	if not transferred then
		return self:_fireFailure(sender, "Item", transferErr or "Gift could not be delivered.", {
			status = "Failed",
			targetUserId = target.UserId,
			itemUid = itemUid,
		})
	end

	local deliveredItem = transferredItem or item
	self:_fireNotification(target, {
		giftType = "Item",
		fromUserId = sender.UserId,
		fromName = sender.Name,
		itemUid = itemUid,
		itemName = deliveredItem and deliveredItem.name or nil,
	})

	return self:_fireSuccess(sender, "Item", "Gift sent successfully.", {
		status = "Completed",
		targetUserId = target.UserId,
		itemUid = itemUid,
	})
end

function Main:RequestProductGift(sender: Player, targetUserId: number, productId: number): (boolean, string?)
	self:_clearExpiredPendingForPlayer(sender)

	local target, targetErr = self:_validateTarget(sender, targetUserId, "Product")
	if not target then
		return self:_fireFailure(sender, "Product", targetErr or "Target player was not found.", {
			targetUserId = targetUserId,
			productId = productId,
		})
	end

	local validProduct, productErr = self:_validateProductGift(productId)
	if not validProduct then
		return self:_fireFailure(sender, "Product", productErr or "That product cannot be gifted.", {
			targetUserId = target.UserId,
			productId = productId,
		})
	end

	if self._pendingProductGifts[sender.UserId] then
		return self:_fireFailure(sender, "Product", "You already have an active gift request.", {
			targetUserId = target.UserId,
			productId = productId,
		})
	end

	self:_markRequestStarted(sender, "Product")
	self._pendingProductGifts[sender.UserId] = {
		targetUserId = target.UserId,
		productId = math.floor(productId),
		createdAt = os.clock(),
	}

	local prompted, promptErr = pcall(function()
		MarketplaceService:PromptProductPurchase(sender, math.floor(productId))
	end)

	if not prompted then
		self._pendingProductGifts[sender.UserId] = nil
		self:_markRequestFinished(sender, "Product", false)
		warn("[GiftsService] Product gift prompt failed:", productId, promptErr)
		return self:_fireFailure(sender, "Product", "Gift purchase could not be started.", {
			status = "Failed",
			targetUserId = target.UserId,
			productId = math.floor(productId),
		})
	end

	return self:_fireSuccess(sender, "Product", "Gift purchase started.", {
		status = "PromptStarted",
		targetUserId = target.UserId,
		productId = math.floor(productId),
	})
end

function Main:RequestGamepassGift(sender: Player, targetUserId: number, gamepassId: number): (boolean, string?)
	self:_clearExpiredPendingForPlayer(sender)

	local target, targetErr = self:_validateTarget(sender, targetUserId, "Gamepass")
	if not target then
		return self:_fireFailure(sender, "Gamepass", targetErr or "Target player was not found.", {
			targetUserId = targetUserId,
			gamepassId = gamepassId,
		})
	end

	local validGamepass, gamepassErr, giftable = self:_validateGamepassGift(gamepassId)
	if not validGamepass then
		return self:_fireFailure(sender, "Gamepass", gamepassErr or "That gamepass cannot be gifted.", {
			targetUserId = target.UserId,
			gamepassId = gamepassId,
		})
	end

	if self:PlayerHasGiftedGamepass(target, gamepassId) then
		return self:_fireFailure(sender, "Gamepass", "Target already has this gifted gamepass.", {
			targetUserId = target.UserId,
			gamepassId = gamepassId,
		})
	end

	if self._pendingGamepassGifts[sender.UserId] then
		return self:_fireFailure(sender, "Gamepass", "You already have an active gift request.", {
			targetUserId = target.UserId,
			gamepassId = gamepassId,
		})
	end

	self:_markRequestStarted(sender, "Gamepass")
	self._pendingGamepassGifts[sender.UserId] = {
		targetUserId = target.UserId,
		gamepassId = math.floor(gamepassId),
		giftProductId = math.floor(giftable.giftProductId),
		createdAt = os.clock(),
	}

	local prompted, promptErr = pcall(function()
		MarketplaceService:PromptProductPurchase(sender, math.floor(giftable.giftProductId))
	end)

	if not prompted then
		self._pendingGamepassGifts[sender.UserId] = nil
		self:_markRequestFinished(sender, "Gamepass", false)
		warn("[GiftsService] Gamepass gift prompt failed:", gamepassId, promptErr)
		return self:_fireFailure(sender, "Gamepass", "Gift purchase could not be started.", {
			status = "Failed",
			targetUserId = target.UserId,
			gamepassId = math.floor(gamepassId),
			productId = math.floor(giftable.giftProductId),
		})
	end

	return self:_fireSuccess(sender, "Gamepass", "Gift purchase started.", {
		status = "PromptStarted",
		targetUserId = target.UserId,
		gamepassId = math.floor(gamepassId),
		productId = math.floor(giftable.giftProductId),
	})
end

function Main:ConsumePendingProductGift(purchaser: Player, productId: number): PendingProductGift?
	local pending = self._pendingProductGifts[purchaser.UserId]
	if not pending then
		return nil
	end

	if pending.productId ~= productId then
		return nil
	end

	if not self:_pendingIsFresh(pending.createdAt) then
		self._pendingProductGifts[purchaser.UserId] = nil
		self:_markRequestFinished(purchaser, "Product", false)
		return nil
	end

	self._pendingProductGifts[purchaser.UserId] = nil
	self:_markRequestFinished(purchaser, "Product")
	return pending
end

function Main:ConsumePendingGamepassGift(purchaser: Player, gamepassId: number): PendingGamepassGift?
	local pending = self._pendingGamepassGifts[purchaser.UserId]
	if not pending then
		return nil
	end

	if pending.gamepassId ~= gamepassId then
		return nil
	end

	if not self:_pendingIsFresh(pending.createdAt) then
		self._pendingGamepassGifts[purchaser.UserId] = nil
		self:_markRequestFinished(purchaser, "Gamepass", false)
		return nil
	end

	self._pendingGamepassGifts[purchaser.UserId] = nil
	self:_markRequestFinished(purchaser, "Gamepass")
	return pending
end

function Main:GrantGiftedGamepass(target: Player, gamepassId: number): (boolean, string?)
	local valid, err = Utils:ValidatePlayer(target)
	if not valid then
		return false, err
	end

	local attr = StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID[gamepassId]
	if typeof(attr) ~= "string" then
		return false, "gamepass_not_giftable"
	end

	target:SetAttribute(attr, true)

	local ownedAttr = OWNED_ATTR_BY_GAMEPASS_ID[gamepassId]
	if ownedAttr then
		target:SetAttribute(ownedAttr, true)
	end

	if gamepassId == StoreConfig.GAMEPASS.VIP then
		target:SetAttribute(StoreConfig.ATTR.VIP_LUCK_MULT, StoreConfig.VIP_LUCK_MULTIPLIER)
		local current = target:GetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT)
		local count = if typeof(current) == "number" then current else 0
		if count < StoreConfig.VIP_FREE_STEALS then
			target:SetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT, StoreConfig.VIP_FREE_STEALS)
		end
	end

	PlayerDataService.waitUntilLoaded(target)
	PlayerDataService.savePlayerData(target)

	return true, nil
end

function Main:PlayerHasGiftedGamepass(player: Player, gamepassId: number): boolean
	local attr = StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID[gamepassId]
	return typeof(attr) == "string" and player:GetAttribute(attr) == true
end

return Main :: Controller
