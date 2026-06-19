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
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local StoreAccess = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreAccess"))

local function requireServerModule(moduleName: string)
	local localModule = script.Parent:FindFirstChild(moduleName)
	if localModule and localModule:IsA("ModuleScript") then
		return require(localModule)
	end

	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local modulesFolder = serverFolder and serverFolder:FindFirstChild("Modules")
	local sharedModule = modulesFolder and modulesFolder:FindFirstChild(moduleName)
	if sharedModule and sharedModule:IsA("ModuleScript") then
		return require(sharedModule)
	end

	error(`[ProductHandler] Missing server module: {moduleName}`)
end

local ItemService = requireServerModule("ItemService")

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
local receiptInterceptors = {}

local RANDOM_BRAINROT_PRODUCT_ID = StoreConfig.PRODUCT.RANDOM_BRAINROT
local BrainrotsFolder = ServerStorage:FindFirstChild("Brainrots")

local DEFAULT_VARIANT = "Normal"

local VARIANT_TO_MUTATION = {
	Normal = "normal",
	Golden = "gold",
	Gold = "gold",
	Diamond = "diamond",
	Lava = "lava",
	Galaxy = "galaxy",
	Rainbow = "rainbow",
}

local function getAllBrainrotsSorted()
	if typeof(BrainrotsConfig.GetAllSorted) == "function" then
		return BrainrotsConfig:GetAllSorted()
	end

	local list = {}

	for brainrotName, data in pairs(BrainrotsConfig) do
		if typeof(brainrotName) ~= "string" then
			continue
		end

		if typeof(data) ~= "table" then
			continue
		end

		if typeof(data.rarity) ~= "string" or typeof(data.baseIncome) ~= "number" then
			continue
		end

		table.insert(list, {
			name = brainrotName,
			rarity = data.rarity,
			baseIncome = data.baseIncome,
			icons = if typeof(data.icons) == "table" then data.icons else {},
		})
	end

	table.sort(list, function(a, b)
		if a.baseIncome ~= b.baseIncome then
			return a.baseIncome < b.baseIncome
		end

		return a.name < b.name
	end)

	return list
end

local function pickRandomBrainrot()
	local brainrots = getAllBrainrotsSorted()

	if #brainrots <= 0 then
		return nil
	end

	return brainrots[math.random(1, #brainrots)]
end

local function pickRandomVariant(icons: { [string]: string }): string
	local variants = {}

	for variantName, icon in pairs(icons) do
		if typeof(variantName) == "string" and typeof(icon) == "string" and icon ~= "" then
			table.insert(variants, variantName)
		end
	end

	if #variants <= 0 then
		return DEFAULT_VARIANT
	end

	table.sort(variants)

	return variants[math.random(1, #variants)]
end

local function findBrainrotTemplate(brainrotName: string, variantName: string): Model?
	if not BrainrotsFolder then
		return nil
	end

	local brainrotFolder = BrainrotsFolder:FindFirstChild(brainrotName)

	if not brainrotFolder or not brainrotFolder:IsA("Folder") then
		return nil
	end

	local variant = brainrotFolder:FindFirstChild(variantName)

	if variant and variant:IsA("Model") then
		return variant
	end

	local normal = brainrotFolder:FindFirstChild(DEFAULT_VARIANT)

	if normal and normal:IsA("Model") then
		return normal
	end

	for _, child in ipairs(brainrotFolder:GetChildren()) do
		if child:IsA("Model") then
			return child
		end
	end

	return nil
end

local function getMainPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local part = model:FindFirstChildWhichIsA("BasePart", true)

	if part then
		model.PrimaryPart = part
	end

	return part
end

local function cleanClone(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end
end

local function setupToolPhysics(model: Model, handle: BasePart)
	local parts = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)

			descendant.Anchored = false
			descendant.Massless = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end

	for _, part in ipairs(parts) do
		if part ~= handle then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = handle
			weld.Part1 = part
			weld.Parent = handle
		end
	end
end

local function buildBrainrotTool(brainrotData: any, variantName: string): Tool?
	local template = findBrainrotTemplate(brainrotData.name, variantName)

	if not template then
		warn(`[ProductHandler] No template found for {brainrotData.name}/{variantName}`)
		return nil
	end

	local clone = template:Clone()
	cleanClone(clone)

	local handle = getMainPart(clone)

	if not handle then
		clone:Destroy()
		warn(`[ProductHandler] No BasePart found inside {brainrotData.name}/{variantName}`)
		return nil
	end

	local icon = ""

	if typeof(brainrotData.icons) == "table" then
		icon = brainrotData.icons[variantName] or brainrotData.icons.Normal or ""
	end

	local mutation = VARIANT_TO_MUTATION[variantName] or string.lower(variantName)

	local tool = Instance.new("Tool")
	tool.Name = brainrotData.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true

	tool:SetAttribute("BrainrotTool", true)
	tool:SetAttribute("BrainrotName", brainrotData.name)
	tool:SetAttribute("BrainrotRarity", brainrotData.rarity)
	tool:SetAttribute("BrainrotMutation", mutation)
	tool:SetAttribute("BrainrotLevel", 1)
	tool:SetAttribute("BrainrotBaseIncome", brainrotData.baseIncome)
	tool:SetAttribute("BrainrotSourcePath", brainrotData.name .. "/" .. variantName)

	if icon ~= "" then
		tool:SetAttribute("ToolbarIcon", icon)

		pcall(function()
			tool.TextureId = icon
		end)
	end

	setupToolPhysics(clone, handle)

	handle.Name = "Handle"
	handle.Parent = tool

	clone.Name = "Visual"
	clone.Parent = tool

	return tool
end

local RANDOM_BRAINROT_GRANT_TIMEOUT = 15

local function snapshotInventoryByUid(player: Player): { [string]: boolean }
	local byUid: { [string]: boolean } = {}
	local inventory, invErr = ItemService:GetInventory(player, RANDOM_BRAINROT_GRANT_TIMEOUT)

	if invErr then
		warn(`[ProductHandler] Could not snapshot inventory before random brainrot grant for {player.Name}: {invErr}`)
		return byUid
	end

	for _, entry in ipairs(inventory) do
		if typeof(entry.uid) == "string" and entry.uid ~= "" then
			byUid[entry.uid] = true
		end
	end

	return byUid
end

local function applyLastCollectedAttributes(player: Player, beforeByUid: { [string]: boolean })
	local inventory, invErr = ItemService:GetInventory(player, RANDOM_BRAINROT_GRANT_TIMEOUT)

	if invErr then
		warn(`[ProductHandler] Random brainrot granted, but inventory refresh failed for {player.Name}: {invErr}`)
		return
	end

	local grantedEntry: any = nil

	for _, entry in ipairs(inventory) do
		local uid = entry.uid
		if typeof(uid) == "string" and uid ~= "" and beforeByUid[uid] ~= true then
			grantedEntry = entry
			break
		end
	end

	grantedEntry = grantedEntry or inventory[#inventory]

	if not grantedEntry then
		return
	end

	player:SetAttribute("LastCollectedBrainrot", grantedEntry.name)

	if typeof(grantedEntry.uid) == "string" then
		player:SetAttribute("LastCollectedBrainrotUid", grantedEntry.uid)
	end

	if typeof(grantedEntry.rarity) == "string" then
		player:SetAttribute("LastCollectedBrainrotRarity", grantedEntry.rarity)
	end

	if typeof(grantedEntry.mutation) == "string" then
		player:SetAttribute("LastCollectedBrainrotMutation", grantedEntry.mutation)
	end
end

local function grantRandomBrainrot(player: Player): boolean
	local beforeByUid = snapshotInventoryByUid(player)

	local success, err = ItemService:GiveRandomBrainrot(player, nil, {
		equip = false,
		save = true,
		waitForData = true,
		timeout = RANDOM_BRAINROT_GRANT_TIMEOUT,
	})

	if not success then
		warn(`[ProductHandler] ItemService random brainrot grant failed for {player.Name}: {err or "unknown_error"}`)
		return false
	end

	if err then
		warn(`[ProductHandler] Random brainrot granted for {player.Name}, but ItemService returned: {err}`)
	end

	applyLastCollectedAttributes(player, beforeByUid)

	return true
end

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
	self:registerRandomBrainrotProduct()
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

	local onPurchaseRemote = eventsFolder:FindFirstChild("OnPurchase")
	if not onPurchaseRemote then
		onPurchaseRemote = Instance.new("RemoteEvent")
		onPurchaseRemote.Name = "OnPurchase"
		onPurchaseRemote.Parent = eventsFolder
	end

	self._onPurchaseRemote = onPurchaseRemote

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

function ProductHandlerServer.registerRandomBrainrotProduct(self: ProductHandlerServer)
	ProductHandlerServer.registerProductReceipt(RANDOM_BRAINROT_PRODUCT_ID, function(player: Player, _receiptInfo: any)
		local success = grantRandomBrainrot(player)

		if not success then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
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
		if StoreAccess.hasGiftedGamePass(player, entry.id) then
			ownsPass = true
		elseif StoreAccess.shouldTrustMarketplaceOwnership(player) then
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

function ProductHandlerServer.registerReceiptInterceptor(
	handler: (Player, any) -> Enum.ProductPurchaseDecision?
): () -> ()
	table.insert(receiptInterceptors, handler)

	return function()
		for i = #receiptInterceptors, 1, -1 do
			if receiptInterceptors[i] == handler then
				table.remove(receiptInterceptors, i)
				return
			end
		end
	end
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

		for _, interceptor in ipairs(receiptInterceptors) do
			local interceptorPlayer = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if not interceptorPlayer then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			local ok, decision = pcall(interceptor, interceptorPlayer, receiptInfo)
			if not ok then
				warn("[ProductHandler] Receipt interceptor failed for", receiptInfo.ProductId, decision)
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end

			if decision == Enum.ProductPurchaseDecision.PurchaseGranted then
				self._confettiRemote:FireClient(interceptorPlayer)

				if self._onPurchaseRemote then
					self._onPurchaseRemote:FireClient(interceptorPlayer, receiptInfo.ProductId)
				end
			end

			if decision ~= nil then
				return decision
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

				if self._onPurchaseRemote then
					self._onPurchaseRemote:FireClient(customPlayer, receiptInfo.ProductId)
				end
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
	registerReceiptInterceptor: (handler: (Player, any) -> Enum.ProductPurchaseDecision?) -> () -> (),
	_purchaseRemote: RemoteEvent,
	_confettiRemote: RemoteEvent,
	_effectRemote: RemoteEvent,
	_onPurchaseRemote: RemoteEvent,
}

return ProductHandlerServer
