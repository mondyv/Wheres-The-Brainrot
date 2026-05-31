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
local ProductHandlerConfig = require(ReplicatedStorage.EssentialsShared.ProductHandler.ProductHandlerConfig)

local ProductHandlerServer = {}

local function getAssetsFolder(): Folder
	local assetsFolder = ReplicatedStorage:FindFirstChild("EssentialsAssets")
	if not assetsFolder then
		assetsFolder = Instance.new("Folder")
		assetsFolder.Name = "EssentialsAssets"
		assetsFolder.Parent = ReplicatedStorage
	end
	return assetsFolder :: Folder
end

function ProductHandlerServer.init(self: ProductHandlerServer)
	self._grantCallbacks = {} :: { [string]: (Player) -> () }
	self._limitedStockServer = nil :: any
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
	self._purchaseRemote = remote :: RemoteEvent

	local confettiRemote = eventsFolder:FindFirstChild("ProductHandlerConfetti")
	if not confettiRemote then
		confettiRemote = Instance.new("RemoteEvent")
		confettiRemote.Name = "ProductHandlerConfetti"
		confettiRemote.Parent = eventsFolder
	end
	self._confettiRemote = confettiRemote :: RemoteEvent

	local effectRemote = eventsFolder:FindFirstChild("PurchaseEffectShow")
	if not effectRemote then
		effectRemote = Instance.new("RemoteEvent")
		effectRemote.Name = "PurchaseEffectShow"
		effectRemote.Parent = eventsFolder
	end
	self._effectRemote = effectRemote :: RemoteEvent

	self._purchaseRemote.OnServerEvent:Connect(function(player: Player, productName: string)
		if typeof(productName) ~= "string" then
			return
		end

		local entry = ProductHandlerConfig[productName]
		if not entry then
			warn("[ProductHandler] Client requested unknown product:", productName)
			return
		end

		self:promptPurchase(player, productName, entry)
	end)
end

function ProductHandlerServer.discoverParts(self: ProductHandlerServer)
	local touchCooldowns: { [number]: { [string]: boolean } } = {}

	for name, entry in ProductHandlerConfig do
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

function ProductHandlerServer.promptPurchase(
	self: ProductHandlerServer,
	player: Player,
	name: string,
	entry: ProductHandlerConfig.ProductEntry
)
	if entry.type == "gamepass" then
		local ownsPass = false
		local success, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, entry.id)
		end)
		if success then
			ownsPass = result
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

function ProductHandlerServer.setupProcessReceipt(self: ProductHandlerServer)
	local productIdToName: { [number]: string } = {}
	for name, entry in ProductHandlerConfig do
		if entry.type == "devproduct" then
			productIdToName[entry.id] = name
		end
	end

	MarketplaceService.ProcessReceipt = function(receiptInfo)
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

return ProductHandlerServer :: ProductHandlerServer
