-- [ACTIVE] DealerShopService
--[[
	Brainrot Dealer — global catalog, per-player remaining stock.

	• Global (DataStore + MessagingService): which brainrots are offered and
	  their *starting* stock amounts, regenerated every
	  DealerConfig.RESTOCK_INTERVAL_SEC. Restock pings keep every live server
	  on the same catalog.
	• Per player (in-memory): remaining buyable stock for each slot. Cash buys
	  only decrement that player's remaining stock — never the global DataStore
	  stock — so grants are instant (no UpdateAsync on the buy path).
	• Personal restock (dev product) re-rolls that player's remaining stocks.
	• Robux buys work even at 0 personal stock (up to ROBUX_BUY_MAX_PER_SLOT
	  per player per listing) and grant instantly.
]]

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DealerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DealerConfig"))
local LiveDataStores = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveDataStores"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))

local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local ItemService = require(script.Parent:WaitForChild("ItemService"))

local M = {}

export type DealerSlot = {
	name: string,
	rarity: string,
	stock: number, -- starting stock for this catalog cycle (never decremented by cash buys)
	robuxBought: number, -- legacy field kept for DataStore normalize; gating is per-player
}

export type DealerState = {
	version: number,
	generatedAt: number,
	nextRestockAt: number,
	slots: { DealerSlot },
}

type PersonalShop = {
	generatedAt: number,
	remaining: { [number]: number },
	robuxBought: { [number]: number },
}

-- v4: stock in DataStore is starting amount only; personal remaining is in-memory.
local STATE_KEY = "GlobalState_v4"
local STORE_NAME = "DealerShopGlobal_v1"
local MESSAGING_TOPIC = "DealerShopSync_v1"

local dealerStoreEnabled = LiveDataStores.isEnabled()
local dealerStore = if dealerStoreEnabled then DataStoreService:GetDataStore(STORE_NAME) else nil

local currentState: DealerState? = nil
local messagingReady = false
local stateChangedCallback: ((restocked: boolean, targetPlayer: Player?) -> ())? = nil

local personalShop: { [Player]: PersonalShop } = {}
local pendingRobuxBuy: { [Player]: { slotIndex: number, name: string, rarity: string } } = {}
local buyLock: { [Player]: boolean } = {}

-- ── Slot generation ────────────────────────────────────────────────────────────

local function weightedRarityPick(exclude: { [string]: boolean }?): string?
	local weights: { [string]: number } = {}
	for rarityId, w in DealerConfig.RARITY_ROLL_WEIGHTS do
		if not (exclude and exclude[rarityId]) then
			weights[rarityId] = w
		end
	end
	return Brainrots.weightedPick(weights)
end

local function pickDistinctBrainrots(rarity: string, count: number): { string }
	local pool = Brainrots.brainrotsOfRarity(rarity :: any)
	if #pool == 0 then
		return {}
	end
	local names: { string } = {}
	local used: { [string]: boolean } = {}
	local attempts = 0
	while #names < count and #names < #pool and attempts < count * 8 do
		attempts += 1
		local pick = pool[math.random(1, #pool)]
		if not used[pick.name] then
			used[pick.name] = true
			table.insert(names, pick.name)
		end
	end
	while #names < count do
		table.insert(names, pool[math.random(1, #pool)].name)
	end
	return names
end

local function generateSlots(): { DealerSlot }
	local slots: { DealerSlot } = {}
	local usedRarities: { [string]: boolean } = {}

	local function fillGroup(count: number)
		local rarity = weightedRarityPick(usedRarities) or weightedRarityPick(nil)
		if not rarity then
			for _ = 1, count do
				table.insert(slots, { name = "", rarity = "common", stock = 0, robuxBought = 0 })
			end
			return
		end
		usedRarities[rarity] = true
		local names = pickDistinctBrainrots(rarity, count)
		for i = 1, count do
			local name = names[i] or names[1] or ""
			table.insert(slots, {
				name = name,
				rarity = rarity,
				stock = if name ~= "" then DealerConfig.rollStock(rarity) else 0,
				robuxBought = 0,
			})
		end
	end

	fillGroup(2)
	fillGroup(2)
	fillGroup(2)
	fillGroup(1)

	return slots
end

-- ── State normalize / persistence ───────────────────────────────────────────────

local function freshState(): DealerState
	local now = os.time()
	return {
		version = 1,
		generatedAt = now,
		nextRestockAt = now + DealerConfig.RESTOCK_INTERVAL_SEC,
		slots = generateSlots(),
	}
end

local function normalizeSlot(raw: any): DealerSlot
	if typeof(raw) ~= "table" then
		return { name = "", rarity = "common", stock = 0, robuxBought = 0 }
	end
	return {
		name = if typeof(raw.name) == "string" then raw.name else "",
		rarity = if typeof(raw.rarity) == "string" then raw.rarity else "common",
		stock = if typeof(raw.stock) == "number"
			then math.clamp(math.floor(raw.stock), 0, DealerConfig.MAX_STOCK)
			else 0,
		robuxBought = if typeof(raw.robuxBought) == "number" then math.max(0, math.floor(raw.robuxBought)) else 0,
	}
end

local function normalizeState(raw: any): DealerState
	if typeof(raw) ~= "table" or typeof(raw.slots) ~= "table" or typeof(raw.generatedAt) ~= "number" then
		return freshState()
	end
	local slots: { DealerSlot } = {}
	for i = 1, DealerConfig.SLOT_COUNT do
		local rawSlot = raw.slots[i]
		if rawSlot == nil then
			rawSlot = raw.slots[tostring(i)]
		end
		slots[i] = normalizeSlot(rawSlot)
	end
	return {
		version = 1,
		generatedAt = raw.generatedAt,
		nextRestockAt = if typeof(raw.nextRestockAt) == "number"
			then raw.nextRestockAt
			else raw.generatedAt + DealerConfig.RESTOCK_INTERVAL_SEC,
		slots = slots,
	}
end

local function refreshFromDataStore(): DealerState
	if not dealerStoreEnabled or not dealerStore then
		return currentState or freshState()
	end
	local ok, raw = pcall(function()
		return dealerStore:GetAsync(STATE_KEY)
	end)
	if not ok then
		warn("[DealerShopService] GetAsync failed:", raw)
		return currentState or freshState()
	end
	if raw == nil then
		if currentState then
			return currentState
		end
		return freshState()
	end
	return normalizeState(raw)
end

-- Catalog-only writes (restock / ensure persist). Never used on the cash-buy path.
local function mutateState(mutator: (DealerState) -> (DealerState, boolean)): (DealerState, boolean)
	if not dealerStoreEnabled or not dealerStore then
		local base = currentState or freshState()
		local newState, applied = mutator(base)
		if applied then
			currentState = newState
		end
		return currentState :: DealerState, applied
	end

	local appliedFlag = false
	local ok, result = pcall(function()
		return dealerStore:UpdateAsync(STATE_KEY, function(old)
			local state = if old == nil and currentState then currentState else normalizeState(old)
			local newState, applied = mutator(state)
			appliedFlag = applied
			if not applied then
				return nil
			end
			return newState
		end)
	end)
	if not ok then
		warn("[DealerShopService] UpdateAsync failed:", result)
		return currentState or freshState(), false
	end
	if not appliedFlag then
		return currentState or freshState(), false
	end
	if result == nil then
		warn("[DealerShopService] UpdateAsync returned nil after apply — keeping currentState")
		return currentState or freshState(), true
	end
	local normalized = normalizeState(result)
	currentState = normalized
	return normalized, true
end

local function ensureStatePersisted()
	if not dealerStoreEnabled or not dealerStore then
		currentState = currentState or freshState()
		return
	end
	local _, applied = mutateState(function(state)
		return state, true
	end)
	if not applied and not currentState then
		currentState = freshState()
	end
end

local function notifyLocalPlayers(restocked: boolean, targetPlayer: Player?)
	if stateChangedCallback then
		stateChangedCallback(restocked, targetPlayer)
	end
end

local function publishPing(restocked: boolean)
	if not messagingReady then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(MESSAGING_TOPIC, { restocked = restocked, sentAt = os.time() })
		end)
		if not ok then
			warn("[DealerShopService] PublishAsync failed:", err)
		end
	end)
end

local function computePrice(def: Brainrots.BrainrotDef): number
	return math.max(1, math.floor(Brainrots.incomePerSecond(def, 1, "normal") * DealerConfig.CASH_PRICE_MULTIPLIER + 0.5))
end

local function clearAllPersonalShops()
	table.clear(personalShop)
end

-- Re-init personal remaining from the global catalog's starting stocks whenever
-- the catalog cycle (generatedAt) changes.
local function ensurePersonalShop(player: Player): PersonalShop
	local state = currentState or freshState()
	if not currentState then
		currentState = state
	end
	local existing = personalShop[player]
	if existing and existing.generatedAt == state.generatedAt then
		return existing
	end
	local remaining: { [number]: number } = {}
	local robuxBought: { [number]: number } = {}
	for i = 1, DealerConfig.SLOT_COUNT do
		local slot = state.slots[i]
		remaining[i] = if slot and slot.name ~= "" then slot.stock else 0
		robuxBought[i] = 0
	end
	local shop: PersonalShop = {
		generatedAt = state.generatedAt,
		remaining = remaining,
		robuxBought = robuxBought,
	}
	personalShop[player] = shop
	return shop
end

-- ── Restock ──────────────────────────────────────────────────────────────────────

local function tryRestock(): boolean
	local now = os.time()
	local newState, applied = mutateState(function(state)
		if now < state.nextRestockAt then
			return state, false
		end
		return freshState(), true
	end)
	if applied then
		currentState = newState
		clearAllPersonalShops()
		notifyLocalPlayers(true, nil)
		publishPing(true)
	end
	return applied
end

-- ── Public read API ──────────────────────────────────────────────────────────────

function M.getStateForPlayer(player: Player): { [string]: any }
	local state = currentState or freshState()
	if not currentState then
		currentState = state
	end
	local rebirths = RebirthConfig.getRebirthCount(player)
	local personal = ensurePersonalShop(player)
	local slotsOut = {}
	for i = 1, DealerConfig.SLOT_COUNT do
		local slot = state.slots[i]
		local rebirthsNeeded = DealerConfig.rebirthsNeededForRarity(slot.rarity)
		local hasBrainrot = slot.name ~= ""
		local def = hasBrainrot and Brainrots.getByName(slot.name)
		local remaining = personal.remaining[i] or 0
		slotsOut[i] = {
			index = i,
			name = slot.name,
			displayName = if hasBrainrot then RebirthConfig.formatBrainrotDisplayName(slot.name) else "",
			rarity = slot.rarity,
			icon = if hasBrainrot then BrainrotsConfig:GetNormalIcon(slot.name) else "",
			cashPrice = if def then computePrice(def) else 0,
			-- stock / stockPersonal = this player's remaining buys (authoritative for UI + cash buy)
			stock = remaining,
			stockPersonal = remaining,
			-- starting amount from the global catalog (display/debug only — do not add to remaining)
			stockStart = slot.stock,
			stockGlobal = 0,
			robuxBought = personal.robuxBought[i] or 0,
			robuxMax = DealerConfig.ROBUX_BUY_MAX_PER_SLOT,
			rebirthsNeeded = rebirthsNeeded,
			locked = rebirths < rebirthsNeeded,
		}
	end
	return {
		nextRestockAt = state.nextRestockAt,
		slots = slotsOut,
	}
end

-- ── Cash purchase (personal stock only — no DataStore write) ─────────────────────

function M.buyCash(player: Player, slotIndex: number): (boolean, string?, any?)
	if typeof(slotIndex) ~= "number" then
		return false, "bad_slot", nil
	end
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > DealerConfig.SLOT_COUNT then
		return false, "bad_slot", nil
	end
	if buyLock[player] then
		return false, "busy", nil
	end
	buyLock[player] = true

	local state = currentState or freshState()
	if not currentState then
		currentState = state
	end
	local snapshot = state.slots[slotIndex]
	if not snapshot or snapshot.name == "" then
		buyLock[player] = nil
		return false, "empty_slot", nil
	end

	local rebirths = RebirthConfig.getRebirthCount(player)
	if rebirths < DealerConfig.rebirthsNeededForRarity(snapshot.rarity) then
		buyLock[player] = nil
		return false, "locked", nil
	end

	local def = Brainrots.getByName(snapshot.name)
	if not def then
		buyLock[player] = nil
		warn("[DealerShopService] buyCash unknown brainrot", snapshot.name, "slot", slotIndex)
		return false, "unknown_brainrot", nil
	end

	local personal = ensurePersonalShop(player)
	local remaining = personal.remaining[slotIndex] or 0
	if remaining <= 0 then
		buyLock[player] = nil
		return false, "out_of_stock", { index = slotIndex, stock = 0 }
	end

	local price = computePrice(def)
	local cash = player:GetAttribute("Cash")
	local balance = if typeof(cash) == "number" then cash else 0
	if balance < price then
		buyLock[player] = nil
		return false, "cant_afford", nil
	end

	personal.remaining[slotIndex] = remaining - 1
	player:SetAttribute("Cash", balance - price)

	-- Memory grant only — no DataStore save on the buy path (keeps Invoke fast).
	local granted, grantErr = ItemService:GiveBrainrot(player, def.name, {
		equip = false,
		save = false,
		waitForData = false,
		timeout = 5,
	})

	if not granted then
		player:SetAttribute("Cash", balance)
		personal.remaining[slotIndex] = remaining
		buyLock[player] = nil
		warn("[DealerShopService] grant failed for", player.Name, def.name, grantErr)
		-- Personal stock only — return a delta, do not broadcast StateChanged / GetState.
		return false, "grant_failed", { index = slotIndex, stock = remaining }
	end

	buyLock[player] = nil
	-- Do not notifyLocalPlayers / Fire StateChanged — client already applied optimistic stock.
	return true, nil, { index = slotIndex, stock = personal.remaining[slotIndex] or 0 }
end

-- ── Robux purchase (1x, bypasses personal stock, capped per player per listing) ──

function M.requestRobuxBuy(player: Player, slotIndex: number): (boolean, string?)
	if typeof(slotIndex) ~= "number" then
		return false, "bad_slot"
	end
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > DealerConfig.SLOT_COUNT then
		return false, "bad_slot"
	end

	local state = currentState or freshState()
	local snapshot = state.slots[slotIndex]
	if not snapshot or snapshot.name == "" then
		return false, "empty_slot"
	end

	local rebirths = RebirthConfig.getRebirthCount(player)
	if rebirths < DealerConfig.rebirthsNeededForRarity(snapshot.rarity) then
		return false, "locked"
	end

	local personal = ensurePersonalShop(player)
	if (personal.robuxBought[slotIndex] or 0) >= DealerConfig.ROBUX_BUY_MAX_PER_SLOT then
		return false, "sold_out"
	end

	pendingRobuxBuy[player] = { slotIndex = slotIndex, name = snapshot.name, rarity = snapshot.rarity }
	return true, nil
end

function M.grantRobuxBuy(player: Player): boolean
	local pending = pendingRobuxBuy[player]
	pendingRobuxBuy[player] = nil

	local def = pending and Brainrots.getByName(pending.name)
	if not def then
		local pool = Brainrots.brainrotsOfRarity(((pending and pending.rarity) or "common") :: any)
		if #pool == 0 then
			pool = Brainrots.BRAINROTS
		end
		def = pool[math.random(1, #pool)]
	end

	local granted, grantErr = ItemService:GiveBrainrot(player, def.name, {
		equip = false,
		save = true,
		waitForData = false,
		timeout = 5,
	})
	if not granted then
		warn("[DealerShopService] Robux buy grant failed for", player.Name, def.name, grantErr)
		return false
	end

	if pending then
		local personal = ensurePersonalShop(player)
		personal.robuxBought[pending.slotIndex] = (personal.robuxBought[pending.slotIndex] or 0) + 1
		notifyLocalPlayers(false, player)
	end
	return true
end

-- ── Personal restock (dev product, per-player only) ──────────────────────────────

function M.personalRestock(player: Player)
	local state = currentState or freshState()
	local shop = ensurePersonalShop(player)
	-- Restore each sold-out listing to that catalog cycle's original starting stock.
	-- Listings that still have remaining stock are left alone.
	for i = 1, DealerConfig.SLOT_COUNT do
		local slot = state.slots[i]
		if not slot or slot.name == "" then
			shop.remaining[i] = 0
			continue
		end
		local remaining = shop.remaining[i] or 0
		if remaining <= 0 then
			shop.remaining[i] = math.max(1, slot.stock)
		end
	end
	notifyLocalPlayers(false, player)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────────

function M.onStateChanged(callback: (boolean, Player?) -> ())
	stateChangedCallback = callback
end

function M.start()
	currentState = refreshFromDataStore()
	ensureStatePersisted()

	local function anyNamedOffering(state: DealerState): boolean
		for _, slot in state.slots do
			if slot.name ~= "" then
				return true
			end
		end
		return false
	end

	if not anyNamedOffering(currentState :: DealerState) then
		local newState, applied = mutateState(function(_state)
			return freshState(), true
		end)
		if applied then
			currentState = newState
			clearAllPersonalShops()
			notifyLocalPlayers(true, nil)
			publishPing(true)
		end
	elseif (currentState :: DealerState).nextRestockAt <= os.time() then
		tryRestock()
	end

	local slotSummary = {}
	for i, slot in (currentState :: DealerState).slots do
		table.insert(slotSummary, string.format("%d:%s/%d", i, slot.name ~= "" and slot.name or "-", slot.stock))
	end
	warn("[DealerShopService] started", table.concat(slotSummary, ", "), "nextRestock", (currentState :: DealerState).nextRestockAt)

	local subscribeOk, subscribeErr = pcall(function()
		MessagingService:SubscribeAsync(MESSAGING_TOPIC, function(packet)
			if typeof(packet) ~= "table" or typeof(packet.Data) ~= "table" then
				return
			end
			local previousGeneratedAt = currentState and currentState.generatedAt
			local fresh = refreshFromDataStore()
			if fresh and fresh.slots then
				currentState = fresh
			end
			local catalogChanged = currentState ~= nil and currentState.generatedAt ~= previousGeneratedAt
			if catalogChanged then
				clearAllPersonalShops()
			end
			-- Only toast when the catalog actually changed. Own-server PublishAsync echo
			-- arrives after tryRestock already notified — skip the duplicate restock notif.
			if catalogChanged then
				notifyLocalPlayers(true, nil)
			else
				notifyLocalPlayers(false, nil)
			end
		end)
		messagingReady = true
	end)
	if not subscribeOk then
		warn("[DealerShopService] SubscribeAsync failed:", subscribeErr)
	end

	task.spawn(function()
		while true do
			task.wait(5)
			if currentState and os.time() >= currentState.nextRestockAt then
				tryRestock()
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		personalShop[player] = nil
		pendingRobuxBuy[player] = nil
		buyLock[player] = nil
	end)
end

return M
