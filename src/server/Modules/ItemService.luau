--// < Made by: MikePlayz163 >

-->> || Services || <<--

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-->> || Types || <<--

export type GiveBrainrotOptions = {
	uid: string?,
	mutation: string?,
	level: number?,
	equip: boolean?,
	save: boolean?,
	sourcePath: string?,
	rarity: string?,
	baseIncome: number?,
	timeout: number?,
	waitForData: boolean?,
	-- When set, random product rolls scale off this plot $/s (hard income cap).
	plotIncomePerSecond: number?,
}

export type ClearItemOptions = {
	all: boolean?,
	save: boolean?,
	timeout: number?,
	waitForData: boolean?,
}

export type InventoryItem = {
	uid: string,
	name: string,
	rarity: string?,
	icon: string?,
	sourcePath: string?,
	mutation: string?,
	level: number?,
	baseIncome: number?,
	locked: boolean?,
	favorited: boolean?,
}

export type BrainrotGrantEntry = {
	uid: string?,
	name: string,
	icon: string?,
	sourcePath: string?,
	rarity: string?,
	mutation: string?,
	level: number?,
	baseIncome: number?,
}

export type ItemSelector = number | string | Tool | { index: number?, name: string? }

export type Config = {
	DEFAULT_BINDABLE_TIMEOUT: number,
	SAVE_RETRIES: number,
	SAVE_RETRY_DELAY: number,
	DEFAULT_MUTATION: string,
	DEFAULT_LEVEL: number,
	MAX_BRAINROT_INVENTORY_CAPACITY: number,
}

export type Controller = {
	__index: any,
	_CONFIG: Config,

	IsReady: (self: Controller, timeout: number?) -> boolean,
	GetInventory: (self: Controller, player: Player, timeout: number?) -> ({ InventoryItem }, string?),
	FindItem: (self: Controller, player: Player, item: ItemSelector, timeout: number?) -> (number?, InventoryItem?),
	FindItemByUid: (self: Controller, player: Player, itemUid: string, timeout: number?) -> (number?, InventoryItem?),
	HasBrainrot: (self: Controller, player: Player, brainrotName: string, timeout: number?) -> (boolean, number?),
	CanReceiveBrainrot: (self: Controller, player: Player, timeout: number?) -> (boolean, string?),
	GiveBrainrot: (self: Controller, player: Player, brainrotName: string, options: GiveBrainrotOptions?) -> (boolean, string?),
	GiveBrainrotEntry: (self: Controller, player: Player, entry: BrainrotGrantEntry, options: GiveBrainrotOptions?) -> (boolean, string?),
	GiveRandomBrainrot: (self: Controller, player: Player, rarity: string?, options: GiveBrainrotOptions?) -> (boolean, string?),
	ClearInventory: (self: Controller, player: Player, options: ClearItemOptions?) -> (boolean, string?),
	ClearItem: (self: Controller, player: Player, item: ItemSelector, options: ClearItemOptions?) -> (boolean, string?),
	RemoveItemAt: (self: Controller, player: Player, index: number, options: ClearItemOptions?) -> (boolean, string?),
	RemoveItemByUid: (self: Controller, player: Player, itemUid: string, options: ClearItemOptions?) -> (boolean, string?),
	TakeItemByUid: (self: Controller, player: Player, itemUid: string, options: ClearItemOptions?) -> (InventoryItem?, string?),
	TransferBrainrot: (self: Controller, sender: Player, target: Player, itemUid: string, options: GiveBrainrotOptions?) -> (boolean, string?, InventoryItem?),
	SaveInventory: (self: Controller, player: Player, options: { waitForData: boolean? }?) -> (boolean, string?),
}

-->> || Main ~ Utilities || <<--

local Main = {} :: Controller
Main.__index = Main

Main._CONFIG = {
	DEFAULT_BINDABLE_TIMEOUT = 10,
	SAVE_RETRIES = 3,
	SAVE_RETRY_DELAY = 0.35,
	DEFAULT_MUTATION = "normal",
	DEFAULT_LEVEL = 1,
	MAX_BRAINROT_INVENTORY_CAPACITY = 100,
}

local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local RandomBrainrotOdds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RandomBrainrotOdds"))
local Utils = require(script.Parent:WaitForChild("Utils"))

local cachedBindables: { [string]: BindableFunction } = {}
local brainrotByKey: { [string]: Brainrots.BrainrotDef } = {}
local adapterTokensByUserId: { [number]: { [string]: string } } = {}

local function normalizeKey(value: string): string
	return string.lower((string.gsub(value, "[%s_%-%p]", "")))
end

for _, def in ipairs(Brainrots.BRAINROTS) do
	brainrotByKey[normalizeKey(def.name)] = def
end

local function validatePlayer(player: any): (boolean, string?)
	return Utils:ValidatePlayer(player)
end

local function shouldWaitForData(options: any): boolean
	if typeof(options) == "table" and options.waitForData == false then
		return false
	end

	return true
end

local function shouldSave(options: any): boolean
	if typeof(options) == "table" and options.save == false then
		return false
	end

	return true
end

local function timeoutFrom(options: any): number
	if typeof(options) == "table" and typeof(options.timeout) == "number" then
		return math.max(0, options.timeout)
	end

	return Main._CONFIG.DEFAULT_BINDABLE_TIMEOUT
end

local function waitForPlayerData(player: Player, options: any): (boolean, string?)
	if not shouldWaitForData(options) then
		return true, nil
	end

	PlayerDataService.waitUntilLoaded(player)

	if player.Parent ~= Players then
		return false, "player_left"
	end

	if not PlayerDataService.isPersistenceEnabled() then
		return true, nil
	end

	if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true then
		return false, "data_not_loaded"
	end

	return true, nil
end

local function getInternalFolder(): Folder?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if folder and folder:IsA("Folder") then
		return folder
	end

	return nil
end

local function waitForInternalBindable(name: string, timeout: number?): BindableFunction?
	local cached = cachedBindables[name]
	if cached and cached.Parent then
		return cached
	end

	local deadline = os.clock() + (timeout or Main._CONFIG.DEFAULT_BINDABLE_TIMEOUT)

	repeat
		local folder = getInternalFolder()
		local bindable = folder and folder:FindFirstChild(name)

		if bindable and bindable:IsA("BindableFunction") then
			cachedBindables[name] = bindable
			return bindable
		end

		task.wait(0.15)
	until os.clock() >= deadline

	return nil
end

local function resolveBrainrot(brainrotName: string): Brainrots.BrainrotDef?
	local exact = Brainrots.getByName(brainrotName)
	if exact then
		return exact
	end

	return brainrotByKey[normalizeKey(brainrotName)]
end

local function normalizeMutation(mutation: any): (string?, string?)
	if mutation == nil or mutation == "" then
		return Main._CONFIG.DEFAULT_MUTATION, nil
	end

	if typeof(mutation) ~= "string" then
		return nil, "invalid_mutation"
	end

	local key = string.lower(mutation)
	if Brainrots.MUTATION_BY_ID[key] then
		return key, nil
	end

	return nil, "unknown_mutation"
end

local function normalizeLevel(level: any): number
	if typeof(level) ~= "number" then
		return Main._CONFIG.DEFAULT_LEVEL
	end

	return math.clamp(math.floor(level), 1, Brainrots.MAX_LEVEL)
end

local function buildBrainrotEntry(def: Brainrots.BrainrotDef, options: GiveBrainrotOptions?): (BrainrotGrantEntry?, string?)
	local mutation, mutationErr = normalizeMutation(options and options.mutation)
	if not mutation then
		return nil, mutationErr
	end

	local rarity = def.rarity
	if options and typeof(options.rarity) == "string" and options.rarity ~= "" then
		local requestedRarity = string.lower(options.rarity)
		if not Brainrots.RARITY_BY_ID[requestedRarity] then
			return nil, "unknown_rarity"
		end
		rarity = requestedRarity :: any
	end

	local baseIncome = def.baseIncome
	if options and typeof(options.baseIncome) == "number" then
		baseIncome = math.max(0, options.baseIncome)
	end

	return {
		uid = if options and typeof(options.uid) == "string" then options.uid else nil,
		name = def.name,
		rarity = rarity,
		mutation = mutation,
		level = normalizeLevel(options and options.level),
		baseIncome = baseIncome,
		sourcePath = if options and typeof(options.sourcePath) == "string" then options.sourcePath else "",
	}, nil
end

local function cloneInventoryItem(entry: InventoryItem): BrainrotGrantEntry
	return {
		uid = entry.uid,
		name = entry.name,
		icon = entry.icon,
		sourcePath = entry.sourcePath,
		rarity = entry.rarity,
		mutation = entry.mutation,
		level = entry.level,
		baseIncome = entry.baseIncome,
	}
end

local function tokenPart(value: any): string
	if value == nil then
		return ""
	end

	return tostring(value):gsub("|", "%%7C")
end

local function adapterFingerprintFor(index: number, raw: any): string
	return table.concat({
		"slot",
		tostring(index),
		tokenPart(raw.name),
		tokenPart(raw.sourcePath),
		tokenPart(raw.rarity),
		tokenPart(raw.mutation),
		tokenPart(raw.level),
		tokenPart(raw.baseIncome),
	}, "|")
end

local function adapterUidFor(player: Player, index: number, raw: any, seenFingerprints: { [string]: boolean }): string
	local fingerprint = adapterFingerprintFor(index, raw)
	seenFingerprints[fingerprint] = true

	local tokens = adapterTokensByUserId[player.UserId]
	if not tokens then
		tokens = {}
		adapterTokensByUserId[player.UserId] = tokens
	end

	local token = tokens[fingerprint]
	if typeof(token) ~= "string" or token == "" then
		token = "adapter:" .. HttpService:GenerateGUID(false)
		tokens[fingerprint] = token
	end

	return token
end

local function pruneAdapterTokens(player: Player, seenFingerprints: { [string]: boolean })
	local tokens = adapterTokensByUserId[player.UserId]
	if not tokens then
		return
	end

	for fingerprint in tokens do
		if not seenFingerprints[fingerprint] then
			tokens[fingerprint] = nil
		end
	end
end

local function normalizeInventoryItem(
	player: Player,
	index: number,
	raw: any,
	seenFingerprints: { [string]: boolean }
): InventoryItem?
	if typeof(raw) ~= "table" or typeof(raw.name) ~= "string" or raw.name == "" then
		return nil
	end

	return {
		uid = if typeof(raw.uid) == "string" and raw.uid ~= "" then raw.uid else adapterUidFor(player, index, raw, seenFingerprints),
		name = raw.name,
		rarity = if typeof(raw.rarity) == "string" then raw.rarity else nil,
		icon = if typeof(raw.icon) == "string" then raw.icon else nil,
		sourcePath = if typeof(raw.sourcePath) == "string" then raw.sourcePath else nil,
		mutation = if typeof(raw.mutation) == "string" then raw.mutation else nil,
		level = if typeof(raw.level) == "number" then raw.level else nil,
		baseIncome = if typeof(raw.baseIncome) == "number" then raw.baseIncome else nil,
		locked = raw.locked == true,
		favorited = raw.favorited == true,
	}
end

local function packInventoryPayload(player: Player, payload: any): { InventoryItem }
	local out: { InventoryItem } = {}
	if typeof(payload) ~= "table" then
		return out
	end

	local entries = payload.entries
	if typeof(entries) ~= "table" then
		entries = payload
	end

	local seenFingerprints: { [string]: boolean } = {}
	for index, raw in ipairs(entries :: any) do
		local item = normalizeInventoryItem(player, index, raw, seenFingerprints)
		if item then
			table.insert(out, item)
		end
	end

	pruneAdapterTokens(player, seenFingerprints)
	return out
end

local function destroyBrainrotToolsForPlayer(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	local containers = {}

	if backpack then
		table.insert(containers, backpack)
	end

	if character then
		table.insert(containers, character)
	end

	for _, container in containers do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute("BrainrotTool") == true then
				child:Destroy()
			end
		end
	end
end

local function clearEquipSlotIfEmpty(player: Player, inventory: { InventoryItem })
	if #inventory <= 0 then
		player:SetAttribute("BrainrotEquipSlot", nil)
	end
end

local function shiftEquipSlotAfterRemove(player: Player, removedIndex: number, inventory: { InventoryItem })
	local equipSlot = player:GetAttribute("BrainrotEquipSlot")
	if typeof(equipSlot) ~= "number" then
		clearEquipSlotIfEmpty(player, inventory)
		return
	end

	local current = math.floor(equipSlot)
	if #inventory <= 0 or current == removedIndex then
		player:SetAttribute("BrainrotEquipSlot", nil)
	elseif current > removedIndex then
		player:SetAttribute("BrainrotEquipSlot", current - 1)
	end
end

local function invokeBindable(name: string, timeout: number, ...: any): (boolean, any)
	local bindable = waitForInternalBindable(name, timeout)
	if not bindable then
		return false, "bindable_missing"
	end

	local args = { ... }
	local ok, result = pcall(function()
		return bindable:Invoke(table.unpack(args))
	end)

	if not ok then
		warn("[ItemService] " .. name .. " invoke failed:", result)
		return false, "invoke_failed"
	end

	return true, result
end

local function saveAfterMutation(player: Player, options: any): (boolean, string?)
	if not shouldSave(options) then
		return true, nil
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	if not PlayerDataService.isPersistenceEnabled() then
		return true, nil
	end

	for _ = 1, Main._CONFIG.SAVE_RETRIES do
		if PlayerDataService.savePlayerData(player) then
			return true, nil
		end

		task.wait(Main._CONFIG.SAVE_RETRY_DELAY)
	end

	return false, "save_failed"
end

local function inventoryNameMatches(itemName: string, query: string): boolean
	local resolved = resolveBrainrot(query)
	if resolved then
		return itemName == resolved.name
	end

	return normalizeKey(itemName) == normalizeKey(query)
end

local function selectorIndex(item: ItemSelector): number?
	if typeof(item) == "number" then
		return math.floor(item :: number)
	end

	if typeof(item) == "Instance" and (item :: any):IsA("Tool") then
		local index = (item :: Tool):GetAttribute("BrainrotInvIndex")
		if typeof(index) == "number" then
			return math.floor(index)
		end
	end

	if typeof(item) == "table" then
		local rawIndex = (item :: any).index
		if typeof(rawIndex) == "number" then
			return math.floor(rawIndex)
		end
	end

	return nil
end

local function selectorName(item: ItemSelector): string?
	if typeof(item) == "string" then
		return item :: string
	end

	if typeof(item) == "Instance" and (item :: any):IsA("Tool") then
		local nameAttr = (item :: Tool):GetAttribute("BrainrotName")
		if typeof(nameAttr) == "string" and nameAttr ~= "" then
			return nameAttr
		end

		return (item :: Tool).Name
	end

	if typeof(item) == "table" then
		local name = (item :: any).name
		if typeof(name) == "string" then
			return name
		end
	end

	return nil
end

-->> || Private API || <<--

Players.PlayerRemoving:Connect(function(player: Player)
	adapterTokensByUserId[player.UserId] = nil
end)

-->> || Public API || <<--

function Main:IsReady(timeout: number?): boolean
	return waitForInternalBindable("GrantBrainrotAndEquip", timeout) ~= nil
		and waitForInternalBindable("ExportInventoryForSave", timeout) ~= nil
		and waitForInternalBindable("ImportInventoryFromSave", timeout) ~= nil
		and waitForInternalBindable("ConsumeInventoryEntry", timeout) ~= nil
		and waitForInternalBindable("ReturnInventoryEntry", timeout) ~= nil
		and waitForInternalBindable("GetInventoryList", timeout) ~= nil
end

function Main:GetInventory(player: Player, timeout: number?): ({ InventoryItem }, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return {}, err
	end

	local bindableTimeout = timeout or Main._CONFIG.DEFAULT_BINDABLE_TIMEOUT
	local ok, result = invokeBindable("ExportInventoryForSave", bindableTimeout, player)
	if not ok then
		ok, result = invokeBindable("GetInventoryList", bindableTimeout, player)
		if not ok then
			return {}, result
		end
	end

	if typeof(result) ~= "table" then
		return {}, "invalid_inventory_payload"
	end

	return packInventoryPayload(player, result), nil
end

function Main:FindItem(player: Player, item: ItemSelector, timeout: number?): (number?, InventoryItem?)
	local inventory = self:GetInventory(player, timeout)
	local index = selectorIndex(item)

	if index and inventory[index] then
		return index, inventory[index]
	end

	local name = selectorName(item)
	if not name or name == "" then
		return nil, nil
	end

	for i, entry in ipairs(inventory) do
		if typeof(entry.name) == "string" and inventoryNameMatches(entry.name, name) then
			return i, entry
		end
	end

	return nil, nil
end

function Main:FindItemByUid(player: Player, itemUid: string, timeout: number?): (number?, InventoryItem?)
	if typeof(itemUid) ~= "string" or itemUid == "" then
		return nil, nil
	end

	local inventory = self:GetInventory(player, timeout)
	for i, entry in ipairs(inventory) do
		if entry.uid == itemUid then
			return i, entry
		end
	end

	return nil, nil
end

function Main:HasBrainrot(player: Player, brainrotName: string, timeout: number?): (boolean, number?)
	local index = self:FindItem(player, brainrotName, timeout)
	return index ~= nil, index
end

function Main:CanReceiveBrainrot(player: Player, timeout: number?): (boolean, string?)
	local inventory, err = self:GetInventory(player, timeout)
	if err then
		return false, err
	end

	if #inventory >= Main._CONFIG.MAX_BRAINROT_INVENTORY_CAPACITY then
		return false, "target_inventory_full"
	end

	return true, nil
end

function Main:GiveBrainrot(player: Player, brainrotName: string, options: GiveBrainrotOptions?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	if typeof(brainrotName) ~= "string" or brainrotName == "" then
		return false, "invalid_brainrot_name"
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	local def = resolveBrainrot(brainrotName)
	if not def then
		return false, "unknown_brainrot"
	end

	local hasSourcePathOverride = options and typeof(options.sourcePath) == "string" and options.sourcePath ~= ""
	if not Brainrots.isPlayableBrainrotName(def.name) and not hasSourcePathOverride then
		return false, "brainrot_not_playable"
	end

	local entry, entryErr = buildBrainrotEntry(def, options)
	if not entry then
		return false, entryErr
	end

	local equip = if options and options.equip == false then false else true
	local ok, granted = invokeBindable("GrantBrainrotAndEquip", timeoutFrom(options), player, entry, { equip = equip })
	if not ok then
		return false, granted
	end

	if granted ~= true then
		return false, "inventory_full_or_grant_failed"
	end

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Brainrot granted but immediate save failed for", player.Name, saveErr)
		return true, saveErr
	end

	return true, nil
end

function Main:GiveBrainrotEntry(player: Player, entry: BrainrotGrantEntry, options: GiveBrainrotOptions?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	if typeof(entry) ~= "table" or typeof(entry.name) ~= "string" or entry.name == "" then
		return false, "invalid_entry"
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	local canReceive, receiveErr = self:CanReceiveBrainrot(player, timeoutFrom(options))
	if not canReceive then
		return false, receiveErr
	end

	local ok, returned = invokeBindable("ReturnInventoryEntry", timeoutFrom(options), player, entry)
	if not ok then
		return false, returned
	end

	if returned ~= true then
		return false, "inventory_full_or_return_failed"
	end

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Brainrot entry added but immediate save failed for", player.Name, saveErr)
		return true, saveErr
	end

	return true, nil
end

function Main:GiveRandomBrainrot(player: Player, rarity: string?, options: GiveBrainrotOptions?): (boolean, string?)
	local pool

	if typeof(rarity) == "string" and rarity ~= "" then
		local requestedRarity = string.lower(rarity)
		if not Brainrots.RARITY_BY_ID[requestedRarity] then
			return false, "unknown_rarity"
		end

		pool = Brainrots.brainrotsOfRarity(requestedRarity :: any)
		if #pool <= 0 then
			return false, "empty_brainrot_pool"
		end
		local pick = pool[math.random(1, #pool)]
		return self:GiveBrainrot(player, pick.name, options)
	end

	local plotIps = 0
	if options and typeof(options.plotIncomePerSecond) == "number" then
		plotIps = math.max(0, options.plotIncomePerSecond)
	end
	local name = RandomBrainrotOdds.pickName(plotIps)
	if not name then
		return false, "empty_brainrot_pool"
	end
	return self:GiveBrainrot(player, name, options)
end

function Main:ClearInventory(player: Player, options: ClearItemOptions?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	destroyBrainrotToolsForPlayer(player)

	local ok, imported = invokeBindable("ImportInventoryFromSave", timeoutFrom(options), player, {
		entries = {},
		parkedSlots = {},
		hotbarSlots = {},
		equipSlot = nil,
	})

	if not ok then
		return false, imported
	end

	if imported ~= true then
		return false, "clear_failed"
	end

	player:SetAttribute("BrainrotEquipSlot", nil)

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Inventory cleared but immediate save failed for", player.Name, saveErr)
		return true, saveErr
	end

	return true, nil
end

function Main:ClearItem(player: Player, item: ItemSelector, options: ClearItemOptions?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	local removeAll = options and options.all == true
	local index = selectorIndex(item)

	if index and not removeAll then
		return self:RemoveItemAt(player, index, options)
	end

	local name = selectorName(item)
	if not name or name == "" then
		return false, "invalid_item"
	end

	local inventory, invErr = self:GetInventory(player, timeoutFrom(options))
	if invErr then
		return false, invErr
	end

	local matches: { number } = {}
	for i, entry in ipairs(inventory) do
		if typeof(entry.name) == "string" and inventoryNameMatches(entry.name, name) then
			table.insert(matches, i)
			if not removeAll then
				break
			end
		end
	end

	if #matches <= 0 then
		return false, "item_not_found"
	end

	for i = #matches, 1, -1 do
		local removed, removeErr = self:RemoveItemAt(player, matches[i], {
			save = false,
			timeout = timeoutFrom(options),
			waitForData = false,
		})

		if not removed then
			return false, removeErr
		end
	end

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Item removed but immediate save failed for", player.Name, saveErr)
		return true, saveErr
	end

	return true, nil
end

function Main:RemoveItemAt(player: Player, index: number, options: ClearItemOptions?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return false, dataErr
	end

	if typeof(index) ~= "number" or index < 1 then
		return false, "invalid_index"
	end

	local ok, removed = invokeBindable("ConsumeInventoryEntry", timeoutFrom(options), player, math.floor(index))
	if not ok then
		return false, removed
	end

	if typeof(removed) ~= "table" then
		return false, "item_not_found"
	end

	local inventory = self:GetInventory(player, timeoutFrom(options))
	shiftEquipSlotAfterRemove(player, math.floor(index), inventory)

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Item removed but immediate save failed for", player.Name, saveErr)
		return true, saveErr
	end

	return true, nil
end

function Main:TakeItemByUid(player: Player, itemUid: string, options: ClearItemOptions?): (InventoryItem?, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return nil, err
	end

	local dataReady, dataErr = waitForPlayerData(player, options)
	if not dataReady then
		return nil, dataErr
	end

	local index = self:FindItemByUid(player, itemUid, timeoutFrom(options))
	if not index then
		return nil, "item_not_found"
	end

	local ok, removed = invokeBindable("ConsumeInventoryEntry", timeoutFrom(options), player, index)
	if not ok then
		return nil, removed
	end

	if typeof(removed) ~= "table" then
		return nil, "item_not_found"
	end

	local removedEntry = removed :: InventoryItem
	removedEntry.uid = itemUid
	local inventory = self:GetInventory(player, timeoutFrom(options))
	shiftEquipSlotAfterRemove(player, index, inventory)

	local saved, saveErr = saveAfterMutation(player, options)
	if not saved then
		warn("[ItemService] Item taken but immediate save failed for", player.Name, saveErr)
		return removedEntry, saveErr
	end

	return removedEntry, nil
end

function Main:RemoveItemByUid(player: Player, itemUid: string, options: ClearItemOptions?): (boolean, string?)
	local removed, err = self:TakeItemByUid(player, itemUid, options)
	if not removed then
		return false, err
	end

	return true, err
end

function Main:TransferBrainrot(
	sender: Player,
	target: Player,
	itemUid: string,
	options: GiveBrainrotOptions?
): (boolean, string?, InventoryItem?)
	local validSender, senderErr = validatePlayer(sender)
	if not validSender then
		return false, senderErr, nil
	end

	local validTarget, targetErr = validatePlayer(target)
	if not validTarget then
		return false, targetErr, nil
	end

	local canReceive, receiveErr = self:CanReceiveBrainrot(target, timeoutFrom(options))
	if not canReceive then
		return false, receiveErr, nil
	end

	local _, currentItem = self:FindItemByUid(sender, itemUid, timeoutFrom(options))
	if not currentItem then
		return false, "item_not_found", nil
	end

	local preparedRollbackEntry = cloneInventoryItem(currentItem)
	local removed, removeErr = self:TakeItemByUid(sender, itemUid, {
		save = false,
		timeout = timeoutFrom(options),
		waitForData = if options and options.waitForData == false then false else true,
	})

	if not removed then
		return false, removeErr, nil
	end

	local deliveredEntry = cloneInventoryItem(removed)
	local added, addErr = self:GiveBrainrotEntry(target, deliveredEntry, {
		equip = if options and options.equip == true then true else false,
		save = false,
		timeout = timeoutFrom(options),
		waitForData = if options and options.waitForData == false then false else true,
	})

	if not added then
		local rollbackOk = self:GiveBrainrotEntry(sender, preparedRollbackEntry, {
			equip = false,
			save = false,
			timeout = timeoutFrom(options),
			waitForData = false,
		})

		if not rollbackOk then
			warn("[ItemService] Transfer rollback failed for", sender.Name, itemUid)
			return false, "transfer_failed_rollback_failed", removed
		end

		return false, addErr or "target_inventory_full", nil
	end

	local saveSenderOk = self:SaveInventory(sender, { waitForData = false })
	local saveTargetOk = self:SaveInventory(target, { waitForData = false })
	if not saveSenderOk or not saveTargetOk then
		warn("[ItemService] Transfer completed but save failed for", sender.Name, "or", target.Name)
		return true, "save_failed", removed
	end

	return true, nil, removed
end

function Main:SaveInventory(player: Player, options: { waitForData: boolean? }?): (boolean, string?)
	local valid, err = validatePlayer(player)
	if not valid then
		return false, err
	end

	return saveAfterMutation(player, options or {})
end

return Main :: Controller
