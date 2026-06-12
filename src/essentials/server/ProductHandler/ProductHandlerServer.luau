-- [ACTIVE] ProductHandlerServer
--[[
	Central product/gamepass handler.

	- For each config entry with a "part" field, hooks into it:
	  ProximityPrompt = Triggered, BasePart = Touched (3s cooldown).
	- Products without a "part" can still be triggered from client UI buttons.
	- Owns MarketplaceService.ProcessReceipt and routes limited-stock receipts
	  to LimitedStockServer when applicable.
	- For gamepasses, checks ownership before prompting so already-owned passes
	  are skipped.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local StoreAccess = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreAccess"))

local GAMEPASS_OWNED_ATTR_BY_ID: { [number]: string } = {
	[StoreConfig.GAMEPASS.VIP] = StoreConfig.ATTR.VIP_OWNED,
	[StoreConfig.GAMEPASS.XRAY] = StoreConfig.ATTR.XRAY_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = StoreConfig.ATTR.DOUBLE_CASH_OWNED,
	[StoreConfig.GAMEPASS.SUPER_LUCK] = StoreConfig.ATTR.SUPER_LUCK_OWNED,
	[StoreConfig.GAMEPASS.MEGA_LUCK] = StoreConfig.ATTR.MEGA_LUCK_OWNED,
}

local ProductHandlerServer = {}

local initialized = false
local productHandlerConfig = nil
local customReceiptHandlers = {}

local function getProductHandlerConfig()
	if productHandlerConfig then
		return productHandlerConfig
	end

	local folder = ReplicatedStorage:FindFirstChild("EssentialsShared")
		and ReplicatedStorage.EssentialsShared:FindFirstChild("ProductHandler")
	if not folder then
		warn("[ProductHandler] EssentialsShared.ProductHandler folder missing")
		productHandlerConfig = {}
		return productHandlerConfig
	end

	local configModule = folder:FindFirstChild("ProductHandlerConfig")
	if not configModule then
		warn("[ProductHandler] ProductHandlerConfig missing — add ProductHandlerConfig ModuleScript")
		productHandlerConfig = {}
		return productHandlerConfig
	end

	local ok, loaded = pcall(require, configModule)
	if not ok or type(loaded) ~= "table" then
		warn("[ProductHandler] ProductHandlerConfig failed to load:", loaded)
		productHandlerConfig = {}
		return productHandlerConfig
	end

	productHandlerConfig = loaded
	return productHandlerConfig
end

local function getAssetsFolder()
	local assetsFolder = ReplicatedStorage:FindFirstChild("EssentialAssets")
	if not assetsFolder then
		assetsFolder = Instance.new("Folder")
		assetsFolder.Name = "EssentialAssets"
		assetsFolder.Parent = ReplicatedStorage
	end
	return assetsFolder
end

function ProductHandlerServer.init(self: ProductHandlerServer)
	if initialized then
		return
	end

	initialized = true

	self._grantCallbacks = {}
	self._limitedStockServer = nil
	self:createRemotes()
	self:discoverParts()
	self:setupProcessReceipt()
end

function ProductHandlerServer.createRemotes(self: ProductHandlerServer)
	local assetsFolder = getAssetsFolder()

	local eventsFolder = assetsFolder:FindFirstChild("Events")
	if not eventsFolder then
		eventsFolder = Instance.new("Folder")
		eventsFolder.Name = "Events"
		eventsFolder.Parent = assetsFolder
	end

	local remote = eventsFolder:FindFirstChild("ProductHandlerPurchase")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "ProductHandlerPurchase"
		remote.Parent = eventsFolder
	end
	self._purchaseRemote = remote

	local confettiRemote = eventsFolder:FindFirstChild("ProductHandlerConfetti")
	if not confettiRemote then
		confettiRemote = Instance.new("RemoteEvent")
		confettiRemote.Name = "ProductHandlerConfetti"
		confettiRemote.Parent = eventsFolder
	end

	self._confettiRemote = confettiRemote

	local effectRemote = eventsFolder:FindFirstChild("PurchaseEffectShow")
	if not effectRemote then
		effectRemote = Instance.new("RemoteEvent")
		effectRemote.Name = "PurchaseEffectShow"
		effectRemote.Parent = eventsFolder
	end

	self._effectRemote = effectRemote

	self._purchaseRemote.OnServerEvent:Connect(function(player, productName)
		if typeof(productName) ~= "string" then
			return
		end

		local entry = getProductHandlerConfig()[productName]
		if not entry then
			warn("[ProductHandler] Client requested unknown product:", productName)
			return
		end

		self:promptPurchase(player, productName, entry)
	end)
end

function ProductHandlerServer.discoverParts(self: ProductHandlerServer)
	local touchCooldowns: { [number]: { [string]: boolean } } = {}

	for name, entry in getProductHandlerConfig() do
		local target = entry.part
		if not target then
			continue
		end

		if target:IsA("ProximityPrompt") then
			target.Triggered:Connect(function(player: Player)
				self:promptPurchase(player, name, entry)
			end)
		elseif target:IsA("BasePart") then
			target.Touched:Connect(function(hit: BasePart)
				local player = Players:GetPlayerFromCharacter(hit.Parent)
				if not player then
					return
				end

				if not touchCooldowns[player.UserId] then
					touchCooldowns[player.UserId] = {}
				end
				if touchCooldowns[player.UserId][name] then
					return
				end
				touchCooldowns[player.UserId][name] = true

				self:promptPurchase(player, name, entry)

				task.delay(3, function()
					if touchCooldowns[player.UserId] then
						touchCooldowns[player.UserId][name] = nil
					end
				end)
			end)
		else
			warn("[ProductHandler]", name, "part must be a ProximityPrompt or BasePart")
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		touchCooldowns[player.UserId] = nil
	end)
end

function ProductHandlerServer.promptPurchase(self: ProductHandlerServer, player: Player, name: string, entry: any)
	if entry.type == "gamepass" then
		local ownsPass = false
		if StoreAccess.shouldTrustMarketplaceOwnership(player) then
			local success, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, entry.id)
			end)
			if success then
				ownsPass = result == true
			else
				warn("[ProductHandlerServer] UserOwnsGamePassAsync failed for", entry.id, ":", result)
			end
		else
			local attr = GAMEPASS_OWNED_ATTR_BY_ID[entry.id]
			if attr then
				ownsPass = player:GetAttribute(attr) == true
			end
		end

		if ownsPass then
			return
		end

		self._effectRemote:FireClient(player)
		MarketplaceService:PromptGamePassPurchase(player, entry.id)
	elseif entry.type == "devproduct" then
		self._effectRemote:FireClient(player)
		MarketplaceService:PromptProductPurchase(player, entry.id)
	else
		warn("[ProductHandler] Unknown product type for", name)
	end
end

function ProductHandlerServer.registerProductReceipt(
	productId: number,
	handler: (Player, any) -> Enum.ProductPurchaseDecision?
)
	customReceiptHandlers[productId] = handler
end

function ProductHandlerServer.setupProcessReceipt(self: ProductHandlerServer)
	local ReviveService = nil
	do
		local serverFolder = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local modules = serverFolder and serverFolder:FindFirstChild("Modules")
		local reviveModule = modules and modules:FindFirstChild("ReviveService")
		if reviveModule then
			local ok, loaded = pcall(require, reviveModule)
			if ok and loaded then
				ReviveService = loaded
			end
		end
	end

	local productIdToName: { [number]: string } = {}
	for name, entry in getProductHandlerConfig() do
		if entry.type == "devproduct" then
			productIdToName[entry.id] = name
		end
	end

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		if ReviveService and typeof(ReviveService.processReceipt) == "function" then
			local reviveDecision = ReviveService.processReceipt(receiptInfo)
			if reviveDecision ~= nil then
				return reviveDecision
			end
		end

		local customHandler = customReceiptHandlers[receiptInfo.ProductId]
		if customHandler then
			local customPlayer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if not customPlayer then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local ok, decision = pcall(customHandler, customPlayer, receiptInfo)
			if not ok then
				warn("[ProductHandler] Custom receipt handler failed for", receiptInfo.ProductId, decision)
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
				self._confettiRemote:FireClient(customPlayer)
			end
			if decision ~= nil then
				return decision
			end
		end

		if self._limitedStockServer and self._limitedStockServer:ownsProductId(receiptInfo.ProductId) then
			local decision = self._limitedStockServer:processReceipt(receiptInfo)
			if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
				local limitedPlayer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
				if limitedPlayer then
					self._confettiRemote:FireClient(limitedPlayer)
				end
			end
			return decision
		end

		local name = productIdToName[receiptInfo.ProductId]
		if not name then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local callback = self._grantCallbacks[name]
		if callback then
			local success, err = pcall(callback, player)
			if not success then
				warn("[ProductHandler] Grant callback failed for", name, err)
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
		end

		self._confettiRemote:FireClient(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

function ProductHandlerServer.setGrantCallback(self: ProductHandlerServer, name: string, callback: (Player) -> ())
	self._grantCallbacks[name] = callback
end

function ProductHandlerServer.setLimitedStockServer(self: ProductHandlerServer, limitedStockServer: any)
	self._limitedStockServer = limitedStockServer
end

export type ProductHandlerServer = typeof(ProductHandlerServer) & {
	_grantCallbacks: { [string]: (Player) -> () },
	_limitedStockServer: any,
	_purchaseRemote: RemoteEvent,
	_confettiRemote: RemoteEvent,
	_effectRemote: RemoteEvent,
}

return ProductHandlerServer
