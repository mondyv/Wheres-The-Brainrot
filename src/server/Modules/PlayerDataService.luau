-- [ACTIVE] PlayerDataService
--[[
	Single owner of live player persistence (Production_#003 / Development_#003).
	Never rename the store without a migration reader — that orphans all saves.
	Failed loads never mark the session as savable (prevents wiping good data with defaults).
	Legacy PlayerData_v1 is read once and copied forward on miss.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local CashBoostUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CashBoostUtil"))
local DailyConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DailyConfig"))
local LiveDataStores = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LiveDataStores"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))

local IndexService = require(script.Parent:WaitForChild("IndexService"))

local M = {}

local ENVIRONMENT = RunService:IsStudio() and "Development" or "Production"
-- LOCKED name. Bumping this orphans every live profile — migrate instead.
local DATA_STORE_NAME = ENVIRONMENT .. "_#003"
local BACKUP_STORE_NAME = DATA_STORE_NAME .. "_Backups"
-- Older store names to recover from if the current key is empty.
local LEGACY_STORE_NAMES = if RunService:IsStudio()
	then { "PlayerData_v1", "Development_#001", "Development_#002" }
	else { "PlayerData_v1", "Production_#001", "Production_#002" }

local AUTOSAVE_INTERVAL_SEC = 180
-- Starter cash is granted by the tutorial (GrantTutorialCash), not on load.
local DEFAULT_CASH = 0
local LOADED_ATTR = PlayerDataSchema.LOADED_ATTR
local LOAD_FAILED_ATTR = PlayerDataSchema.LOAD_FAILED_ATTR
local PLAY_TIME_ATTR = PlayerDataSchema.TOTAL_PLAY_TIME_ATTR

local persistenceEnabled = LiveDataStores.isEnabled()
local playerStore = if persistenceEnabled then DataStoreService:GetDataStore(DATA_STORE_NAME) else nil
local backupStore = if persistenceEnabled then DataStoreService:GetDataStore(BACKUP_STORE_NAME) else nil

local sessionJoinAt: { [Player]: number } = {}
local sessionPlayBase: { [Player]: number } = {}
local saveInFlight: { [Player]: boolean } = {}
-- false = DataStore error; do NOT overwrite the key with empty defaults.
local sessionCanSave: { [Player]: boolean } = {}
-- Last successful payload this session — used to refuse accidental empty overwrites.
local lastGoodPayload: { [number]: PlayerDataSchema.PlayerSaveData } = {}
-- Sticky stand snapshot: only cleared on intentional reset or confirmed empty autosave.
-- Prevents Roblox Restart-all-servers leave races from persisting empty stands.
local lastGoodStands: { [number]: { PlayerDataSchema.StandSaveEntry } } = {}
-- Set true only for intentional wipe (resetdata / admin reset).
local allowEmptyOverwrite: { [Player]: boolean } = {}
-- Roblox Creator "Restart / shut down all servers" — BindToClose + mass leaves.
local serverClosing = false
local SAVE_ATTEMPTS = 5
local SAVE_RETRY_WAIT = 0.75
local BIND_TO_CLOSE_BUDGET_SEC = 25
local BACKUP_RETRY_ATTEMPTS = 3
-- Autosave every 180s — don't double API load with a backup each time.
local BACKUP_THROTTLE_SEC = 120

local lastBackupAt: { [number]: number } = {}

local function isTransientDatastoreError(err: any): boolean
	local msg = if typeof(err) == "string" then err else tostring(err)
	local lower = string.lower(msg)
	return string.find(lower, "http 500", 1, true) ~= nil
		or string.find(lower, "http 502", 1, true) ~= nil
		or string.find(lower, "http 503", 1, true) ~= nil
		or string.find(lower, "http 429", 1, true) ~= nil
		or string.find(lower, "throttl", 1, true) ~= nil
		or string.find(lower, "service unavailable", 1, true) ~= nil
		or string.find(lower, "internal server", 1, true) ~= nil
end

local function saveRetryDelay(attempt: number, err: any): number
	if isTransientDatastoreError(err) then
		return 1.25 + attempt * 1.1
	end
	return SAVE_RETRY_WAIT * attempt
end

local function getInternalFolder(): Folder
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "BrainrotInternal"
	created.Parent = ServerStorage
	return created
end

local function invokeInternal(name: string, ...: any): any
	local bf = getInternalFolder():FindFirstChild(name)
	if bf and bf:IsA("BindableFunction") then
		return (bf :: BindableFunction):Invoke(...)
	end
	return nil
end

function M.isPersistenceEnabled(): boolean
	return persistenceEnabled
end

function M.waitUntilLoaded(player: Player): boolean
	if not persistenceEnabled then
		return true
	end
	while player.Parent and player:GetAttribute(LOADED_ATTR) ~= true do
		player:GetAttributeChangedSignal(LOADED_ATTR):Wait()
	end
	return player.Parent ~= nil and player:GetAttribute(LOADED_ATTR) == true
end

local function floorNum(n: any, default: number): number
	if typeof(n) ~= "number" then
		return default
	end
	return math.max(0, math.floor(n))
end

local function readStringArray(raw: any): { string }
	local out: { string } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for _, v in raw do
		if typeof(v) == "string" and v ~= "" then
			table.insert(out, v)
		end
	end
	return out
end

local function readBool(raw: any, default: boolean): boolean
	if typeof(raw) == "boolean" then
		return raw
	end
	return default
end

local function getPackLimit(): number
	local limit = StoreConfig.PACK_PURCHASE_LIMIT
	if typeof(limit) == "number" then
		return math.max(0, math.floor(limit))
	end
	return 1
end

local function clampPackCount(raw: any): number
	return math.clamp(floorNum(raw, 0), 0, getPackLimit())
end

local function getPackSaveKey(pack: any): string
	if typeof(pack.key) == "string" and pack.key ~= "" then
		return pack.key
	end

	if typeof(pack.productId) == "number" then
		return tostring(pack.productId)
	end

	if typeof(pack.boughtAttr) == "string" and pack.boughtAttr ~= "" then
		return pack.boughtAttr
	end

	return "UnknownPack"
end

local function collectStorePurchases(player: Player): { [string]: any }
	local A = StoreConfig.ATTR

	local packPurchases: { [string]: number } = {}

	for _, pack in StoreConfig.PACKS do
		if typeof(pack.boughtAttr) == "string" then
			packPurchases[getPackSaveKey(pack)] = clampPackCount(player:GetAttribute(pack.boughtAttr))
		end
	end

	return {
		exclusiveOwned = player:GetAttribute(A.EXCLUSIVE_OWNED) == true,
		freeUncommonClaimed = player:GetAttribute(A.FREE_UNCOMMON_CLAIMED) == true,
		groupRewardClaimed = player:GetAttribute(A.GROUP_REWARD_CLAIMED) == true,
		freeStealCount = floorNum(player:GetAttribute(A.FREE_STEAL_COUNT), 0),
		packPurchases = packPurchases,
	}
end

local function normalizeStorePurchases(raw: any): { [string]: any }
	local out = {
		exclusiveOwned = false,
		freeUncommonClaimed = false,
		groupRewardClaimed = false,
		freeStealCount = 0,
		packPurchases = {},
	}

	if typeof(raw) ~= "table" then
		return out
	end

	out.exclusiveOwned = readBool(raw.exclusiveOwned, false)
	out.freeUncommonClaimed = readBool(raw.freeUncommonClaimed, false)
	out.groupRewardClaimed = readBool(raw.groupRewardClaimed, false)
	out.freeStealCount = floorNum(raw.freeStealCount, 0)

	local rawPacks = raw.packPurchases
	if typeof(rawPacks) == "table" then
		for _, pack in StoreConfig.PACKS do
			local key = getPackSaveKey(pack)
			out.packPurchases[key] = clampPackCount(rawPacks[key])
		end
	end

	return out
end

local function applyStorePurchases(player: Player, raw: any)
	local data = normalizeStorePurchases(raw)
	local A = StoreConfig.ATTR

	player:SetAttribute(A.EXCLUSIVE_OWNED, data.exclusiveOwned == true)
	player:SetAttribute(A.FREE_UNCOMMON_CLAIMED, data.freeUncommonClaimed == true)
	player:SetAttribute(A.GROUP_REWARD_CLAIMED, data.groupRewardClaimed == true)
	player:SetAttribute(A.FREE_STEAL_COUNT, floorNum(data.freeStealCount, 0))

	for _, pack in StoreConfig.PACKS do
		if typeof(pack.boughtAttr) == "string" then
			local key = getPackSaveKey(pack)
			player:SetAttribute(pack.boughtAttr, clampPackCount(data.packPurchases[key]))
		end
	end
end

local function normalizeGiftedGamepasses(raw: any): PlayerDataSchema.GiftedGamepassesSaveData
	local out: PlayerDataSchema.GiftedGamepassesSaveData = {}
	if typeof(raw) ~= "table" then
		return out
	end

	for gamePassId in StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID do
		local key = tostring(gamePassId)
		if raw[key] == true or raw[gamePassId] == true then
			out[key] = true
		end
	end

	return out
end

local function normalizePurchasedGamepasses(raw: any): PlayerDataSchema.PurchasedGamepassesSaveData
	local out: PlayerDataSchema.PurchasedGamepassesSaveData = {}
	if typeof(raw) ~= "table" then
		return out
	end

	for gamePassId in StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID do
		local key = tostring(gamePassId)
		if raw[key] == true or raw[gamePassId] == true then
			out[key] = true
		end
	end

	return out
end

local function collectGiftedGamepasses(player: Player): PlayerDataSchema.GiftedGamepassesSaveData
	local out: PlayerDataSchema.GiftedGamepassesSaveData = {}
	for gamePassId, attr in StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID do
		if typeof(attr) == "string" and player:GetAttribute(attr) == true then
			out[tostring(gamePassId)] = true
		end
	end
	return out
end

local function collectPurchasedGamepasses(player: Player): PlayerDataSchema.PurchasedGamepassesSaveData
	local out: PlayerDataSchema.PurchasedGamepassesSaveData = {}
	for gamePassId, attr in StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID do
		if typeof(attr) == "string" and player:GetAttribute(attr) == true then
			out[tostring(gamePassId)] = true
		end
	end
	return out
end

local function applyGiftedGamepasses(player: Player, raw: any)
	local gifted = normalizeGiftedGamepasses(raw)
	for gamePassId, attr in StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID do
		if typeof(attr) == "string" then
			player:SetAttribute(attr, gifted[tostring(gamePassId)] == true)
		end
	end
end

local function applyPurchasedGamepasses(player: Player, raw: any)
	local purchased = normalizePurchasedGamepasses(raw)
	for gamePassId, attr in StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID do
		if typeof(attr) == "string" then
			player:SetAttribute(attr, purchased[tostring(gamePassId)] == true)
		end
	end
end

local function collectInventory(player: Player): ({ PlayerDataSchema.BrainrotInvSaveEntry }, { number }, number?)
	local packed = invokeInternal("ExportInventoryForSave", player)
	if typeof(packed) ~= "table" then
		return {}, {}, nil
	end
	local entries = if typeof(packed.entries) == "table" then packed.entries else {}
	local parked = if typeof(packed.parkedSlots) == "table" then packed.parkedSlots else {}
	local equipSlot = if typeof(packed.equipSlot) == "number" then packed.equipSlot else nil
	return entries, parked, equipSlot
end

local function collectStands(player: Player): { PlayerDataSchema.StandSaveEntry }
	local raw = invokeInternal("ExportStandsForSave", player)
	if typeof(raw) ~= "table" then
		return {}
	end
	return raw
end

local function clamp01(n: any, fallback: number): number
	if typeof(n) ~= "number" then
		return fallback
	end
	return math.clamp(n, 0, 1)
end

local function normalizeSettings(raw: any): PlayerDataSchema.PlayerSettingsSaveData
	local d = PlayerDataSchema.DEFAULT_SETTINGS
	if typeof(raw) ~= "table" then
		return {
			musicVolume = d.musicVolume,
			sfxVolume = d.sfxVolume,
			uiSoundsEnabled = d.uiSoundsEnabled,
			slowWalkEnabled = d.slowWalkEnabled,
			showOtherBrainrots = d.showOtherBrainrots,
			brainrotVfxEnabled = d.brainrotVfxEnabled,
			globalMessagesEnabled = d.globalMessagesEnabled,
			spiderCutsceneEnabled = d.spiderCutsceneEnabled,
			shopCutsceneEnabled = d.shopCutsceneEnabled,
			lowGraphicsEnabled = d.lowGraphicsEnabled,
			holdToSwingEnabled = d.holdToSwingEnabled,
		}
	end
	-- Migrate legacy skipSpiderCutscene → spiderCutsceneEnabled (both old values map to ON / short cutscene).
	local spiderCutscene = d.spiderCutsceneEnabled
	if raw.spiderCutsceneEnabled ~= nil then
		spiderCutscene = readBool(raw.spiderCutsceneEnabled, d.spiderCutsceneEnabled)
	elseif raw.skipSpiderCutscene ~= nil then
		spiderCutscene = true
	end
	return {
		musicVolume = clamp01(raw.musicVolume, d.musicVolume),
		sfxVolume = clamp01(raw.sfxVolume, d.sfxVolume),
		uiSoundsEnabled = readBool(raw.uiSoundsEnabled, d.uiSoundsEnabled),
		slowWalkEnabled = readBool(raw.slowWalkEnabled, d.slowWalkEnabled),
		showOtherBrainrots = readBool(raw.showOtherBrainrots, d.showOtherBrainrots),
		brainrotVfxEnabled = readBool(raw.brainrotVfxEnabled, d.brainrotVfxEnabled),
		globalMessagesEnabled = readBool(raw.globalMessagesEnabled, d.globalMessagesEnabled),
		spiderCutsceneEnabled = spiderCutscene,
		shopCutsceneEnabled = readBool(raw.shopCutsceneEnabled, d.shopCutsceneEnabled),
		lowGraphicsEnabled = readBool(raw.lowGraphicsEnabled, d.lowGraphicsEnabled),
		holdToSwingEnabled = readBool(raw.holdToSwingEnabled, d.holdToSwingEnabled),
	}
end

local function applySettings(player: Player, raw: any)
	local settings = normalizeSettings(raw)
	player:SetAttribute(PlayerDataSchema.SETTINGS_MUSIC_VOLUME_ATTR, settings.musicVolume)
	player:SetAttribute(PlayerDataSchema.SETTINGS_SFX_VOLUME_ATTR, settings.sfxVolume)
	player:SetAttribute(PlayerDataSchema.SETTINGS_UI_SOUNDS_ATTR, settings.uiSoundsEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_SLOW_WALK_ATTR, settings.slowWalkEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_SHOW_OTHERS_ATTR, settings.showOtherBrainrots)
	player:SetAttribute(PlayerDataSchema.SETTINGS_BRAINROT_VFX_ATTR, settings.brainrotVfxEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_GLOBAL_MESSAGES_ATTR, settings.globalMessagesEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_SPIDER_CUTSCENE_ATTR, settings.spiderCutsceneEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_SHOP_CUTSCENE_ATTR, settings.shopCutsceneEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_LOW_GRAPHICS_ATTR, settings.lowGraphicsEnabled)
	player:SetAttribute(PlayerDataSchema.SETTINGS_HOLD_TO_SWING_ATTR, settings.holdToSwingEnabled)
	player:SetAttribute("SlowWalkEnabled", settings.slowWalkEnabled)
	player:SetAttribute("ShowOtherBrainrots", settings.showOtherBrainrots)
	player:SetAttribute("BrainrotVFXEnabled", settings.brainrotVfxEnabled)
	player:SetAttribute("SpiderCutsceneEnabled", settings.spiderCutsceneEnabled)
	player:SetAttribute("ShopCutsceneEnabled", settings.shopCutsceneEnabled)
	player:SetAttribute("LowGraphicsEnabled", settings.lowGraphicsEnabled)
	player:SetAttribute("HoldToSwingEnabled", settings.holdToSwingEnabled)
end

local function collectSettings(player: Player): PlayerDataSchema.PlayerSettingsSaveData
	return normalizeSettings({
		musicVolume = player:GetAttribute(PlayerDataSchema.SETTINGS_MUSIC_VOLUME_ATTR),
		sfxVolume = player:GetAttribute(PlayerDataSchema.SETTINGS_SFX_VOLUME_ATTR),
		uiSoundsEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_UI_SOUNDS_ATTR),
		slowWalkEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_SLOW_WALK_ATTR),
		showOtherBrainrots = player:GetAttribute(PlayerDataSchema.SETTINGS_SHOW_OTHERS_ATTR),
		brainrotVfxEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_BRAINROT_VFX_ATTR),
		globalMessagesEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_GLOBAL_MESSAGES_ATTR),
		spiderCutsceneEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_SPIDER_CUTSCENE_ATTR),
		shopCutsceneEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_SHOP_CUTSCENE_ATTR),
		lowGraphicsEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_LOW_GRAPHICS_ATTR),
		holdToSwingEnabled = player:GetAttribute(PlayerDataSchema.SETTINGS_HOLD_TO_SWING_ATTR),
	})
end

function M.collectSaveData(player: Player): PlayerDataSchema.PlayerSaveData
	local unlockKeys: { string } = {}
	for key, unlocked in IndexService.getUnlockMap(player) do
		if unlocked then
			table.insert(unlockKeys, key)
		end
	end
	table.sort(unlockKeys)

	local goldenNames = IndexService.exportGoldenNames(player)
	table.sort(goldenNames)

	local inventory, parkedSlots, equipSlot = collectInventory(player)
	local stands = collectStands(player)

	local plot = PlotPaths.findPlotForAssignedSlot(player)
	local floorLevel = 1
	if plot then
		local fl = plot:GetAttribute("BaseFloorLevel")
		if typeof(fl) == "number" then
			floorLevel = math.clamp(math.floor(fl), 1, 4)
		end
	end

	local cash = player:GetAttribute("Cash")
	local rebirth = player:GetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR)
	local dailyBoost = player:GetAttribute(CashBoostUtil.DAILY_BOOST_ATTR)
	local storePurchases = collectStorePurchases(player)
	local giftedGamepasses = collectGiftedGamepasses(player)
	local purchasedGamepasses = collectPurchasedGamepasses(player)

	return {
		version = PlayerDataSchema.VERSION,
		cash = if typeof(cash) == "number" then math.max(0, cash) else 0,
		rebirthCount = floorNum(rebirth, 0),
		powerLevel = floorNum(player:GetAttribute(SwingUpgrades.POWER_LEVEL_ATTR), 0),
		ropeLevel = floorNum(player:GetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR), 0),
		carryLevel = floorNum(player:GetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR), 0),
		totalPlayTimeSeconds = M.getTotalPlayTimeSeconds(player),
		baseFloorLevel = floorLevel,
		dailyDayClaimed = floorNum(player:GetAttribute(DailyConfig.DAY_ATTR), 0),
		dailyClaimedMask = floorNum(player:GetAttribute(DailyConfig.CLAIMED_MASK_ATTR), 0),
		dailyNextAt = floorNum(player:GetAttribute(DailyConfig.NEXT_AT_ATTR), os.time()),
		dailySkipAllOwned = player:GetAttribute(DailyConfig.SKIP_ALL_ATTR) == true,
		dailyCashBoostPercent = if typeof(dailyBoost) == "number" then math.max(0, dailyBoost) else 0,
		storePurchases = storePurchases,
		giftedGamepasses = giftedGamepasses,
		purchasedGamepasses = purchasedGamepasses,
		indexUnlocks = unlockKeys,
		goldenNames = goldenNames,
		inventory = inventory,
		parkedSlots = parkedSlots,
		equipSlot = equipSlot,
		stands = stands,
		lastSavedAt = os.time(),
		settings = collectSettings(player),
		tutorialCompleted = player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true,
		tutorialCashGranted = player:GetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR) == true,
		tutorialFirstBushClaimed = player:GetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR) == true,
		timCheeseIntroDone = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true,
		timCheeseQuestIndex = math.max(0, math.floor(if typeof(player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)) == "number" then player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR) :: number else 0)),
		timCheeseQuestProgress = math.max(0, math.floor(if typeof(player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)) == "number" then player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR) :: number else 0)),
		timCheeseCompletedCount = math.max(0, math.floor(if typeof(player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)) == "number" then player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR) :: number else 0)),
		timCheeseHarvestProgress = math.max(0, math.floor(if typeof(player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR)) == "number" then player:GetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR) :: number else 0)),
	}
end

function M.getTotalPlayTimeSeconds(player: Player): number
	local saved = player:GetAttribute(PLAY_TIME_ATTR)
	local base = if typeof(saved) == "number" then math.max(0, math.floor(saved)) else 0
	local joined = sessionJoinAt[player]
	if not joined then
		return base
	end
	return base + math.max(0, math.floor(os.clock() - joined))
end

function M.savePlayerSettings(player: Player, patch: any)
	if typeof(patch) ~= "table" then
		return
	end
	local current = collectSettings(player)
	local merged = normalizeSettings({
		musicVolume = if patch.musicVolume ~= nil then patch.musicVolume else current.musicVolume,
		sfxVolume = if patch.sfxVolume ~= nil then patch.sfxVolume else current.sfxVolume,
		uiSoundsEnabled = if patch.uiSoundsEnabled ~= nil then patch.uiSoundsEnabled else current.uiSoundsEnabled,
		slowWalkEnabled = if patch.slowWalkEnabled ~= nil then patch.slowWalkEnabled else current.slowWalkEnabled,
		showOtherBrainrots = if patch.showOtherBrainrots ~= nil then patch.showOtherBrainrots else current.showOtherBrainrots,
		brainrotVfxEnabled = if patch.brainrotVfxEnabled ~= nil then patch.brainrotVfxEnabled else current.brainrotVfxEnabled,
		globalMessagesEnabled = if patch.globalMessagesEnabled ~= nil then patch.globalMessagesEnabled else current.globalMessagesEnabled,
		spiderCutsceneEnabled = if patch.spiderCutsceneEnabled ~= nil then patch.spiderCutsceneEnabled else current.spiderCutsceneEnabled,
		shopCutsceneEnabled = if patch.shopCutsceneEnabled ~= nil then patch.shopCutsceneEnabled else current.shopCutsceneEnabled,
		lowGraphicsEnabled = if patch.lowGraphicsEnabled ~= nil then patch.lowGraphicsEnabled else current.lowGraphicsEnabled,
		holdToSwingEnabled = if patch.holdToSwingEnabled ~= nil then patch.holdToSwingEnabled else current.holdToSwingEnabled,
	})
	applySettings(player, merged)
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

--- Persist a real Robux gamepass purchase so ownership survives rejoin (including for creators/testers).
function M.markGamePassPurchased(player: Player, gamePassId: number)
	if typeof(gamePassId) ~= "number" then
		return
	end
	local purchasedAttr = StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID[gamePassId]
	if typeof(purchasedAttr) ~= "string" then
		return
	end
	if player:GetAttribute(purchasedAttr) == true then
		return
	end
	player:SetAttribute(purchasedAttr, true)
	local ownedAttr = StoreConfig.OWNED_GAMEPASS_ATTR_BY_ID[gamePassId]
	if typeof(ownedAttr) == "string" then
		player:SetAttribute(ownedAttr, true)
	end
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

local function applyAttributes(player: Player, data: PlayerDataSchema.PlayerSaveData)
	player:SetAttribute("Cash", data.cash)
	player:SetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR, data.rebirthCount)
	player:SetAttribute(RebirthConfig.MONEY_MULT_ATTR, RebirthConfig.moneyMultiplierForCount(data.rebirthCount))
	player:SetAttribute(SwingUpgrades.POWER_LEVEL_ATTR, data.powerLevel)
	player:SetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR, data.ropeLevel)
	player:SetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR, data.carryLevel)
	player:SetAttribute(PLAY_TIME_ATTR, data.totalPlayTimeSeconds)
	player:SetAttribute(DailyConfig.DAY_ATTR, data.dailyDayClaimed)
	player:SetAttribute(DailyConfig.CLAIMED_MASK_ATTR, data.dailyClaimedMask)
	player:SetAttribute(DailyConfig.NEXT_AT_ATTR, data.dailyNextAt)
	player:SetAttribute(DailyConfig.SKIP_ALL_ATTR, data.dailySkipAllOwned)
	player:SetAttribute(CashBoostUtil.DAILY_BOOST_ATTR, data.dailyCashBoostPercent)

	applyStorePurchases(player, (data :: any).storePurchases)
	applyGiftedGamepasses(player, (data :: any).giftedGamepasses)
	applyPurchasedGamepasses(player, (data :: any).purchasedGamepasses)
	applySettings(player, (data :: any).settings)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, data.tutorialCompleted == true)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR, data.tutorialCashGranted == true)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR, data.tutorialFirstBushClaimed == true)
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR, data.timCheeseIntroDone == true)
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR, math.max(0, math.floor(data.timCheeseQuestIndex or 0)))
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR, math.max(0, math.floor(data.timCheeseQuestProgress or 0)))
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR, math.max(0, math.floor(data.timCheeseCompletedCount or 0)))
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR, math.max(0, math.floor(data.timCheeseHarvestProgress or 0)))
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR, false)

	SwingUpgrades.syncGameplayStatsFromLevels(player, {
		power = data.powerLevel,
		rope = data.ropeLevel,
		carry = data.carryLevel,
	})

	sessionPlayBase[player] = data.totalPlayTimeSeconds
	sessionJoinAt[player] = os.clock()
end

local function applyPlotFloor(player: Player, floorLevel: number)
	task.spawn(function()
		local deadline = os.clock() + 45
		while os.clock() < deadline do
			if not player.Parent then
				return
			end
			local plot = PlotPaths.findPlotForAssignedSlot(player)
			if plot then
				plot:SetAttribute("BaseFloorLevel", math.clamp(floorLevel, 1, 4))
				return
			end
			task.wait(0.25)
		end
	end)
end

local function applyInventory(player: Player, data: PlayerDataSchema.PlayerSaveData)
	invokeInternal("ImportInventoryFromSave", player, {
		entries = data.inventory,
		parkedSlots = data.parkedSlots,
		equipSlot = data.equipSlot,
	})
end

local function applyStands(player: Player, data: PlayerDataSchema.PlayerSaveData)
	if #data.stands == 0 then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + 60
		while os.clock() < deadline do
			if not player.Parent then
				return
			end
			if typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
				invokeInternal("RequestStandRescan")
				local standCount = invokeInternal("CountPlayerPlotStands", player)
				if typeof(standCount) == "number" and standCount > 0 then
					break
				end
			end
			task.wait(0.25)
		end
		invokeInternal("RequestStandRescan")
		task.wait(0.5)
		invokeInternal("ImportStandsFromSave", player, data.stands)
		if persistenceEnabled and data.lastSavedAt > 0 then
			invokeInternal("ApplyStandOfflineEarnings", player, data.lastSavedAt)
		end
	end)
end

local function normalizeLoadedData(raw: any): PlayerDataSchema.PlayerSaveData?
	if typeof(raw) ~= "table" then
		return nil
	end
	local version = floorNum(raw.version, 0)
	if version < 1 then
		return nil
	end

	local inventory: { PlayerDataSchema.BrainrotInvSaveEntry } = {}
	if typeof(raw.inventory) == "table" then
		for _, entry in raw.inventory do
			if typeof(entry) == "table" and typeof(entry.name) == "string" and entry.name ~= "" then
				table.insert(inventory, {
					name = entry.name,
					icon = if typeof(entry.icon) == "string" then entry.icon else "",
					sourcePath = if typeof(entry.sourcePath) == "string" then entry.sourcePath else "",
					rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
					mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
					level = math.max(1, floorNum(entry.level, 1)),
					baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
				})
			end
		end
	end

	local stands: { PlayerDataSchema.StandSaveEntry } = {}
	if typeof(raw.stands) == "table" then
		for _, entry in raw.stands do
			if
				typeof(entry) == "table"
				and typeof(entry.standName) == "string"
				and typeof(entry.brainrotName) == "string"
			then
				table.insert(stands, {
					standName = entry.standName,
					storyName = if typeof(entry.storyName) == "string" then entry.storyName else nil,
					brainrotName = entry.brainrotName,
					rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
					mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
					level = math.max(1, floorNum(entry.level, 1)),
					baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
					sourcePath = if typeof(entry.sourcePath) == "string" then entry.sourcePath else "",
					accumulated = math.max(0, if typeof(entry.accumulated) == "number" then entry.accumulated else 0),
				})
			end
		end
	end

	return {
		version = PlayerDataSchema.VERSION,
		cash = math.max(0, if typeof(raw.cash) == "number" then raw.cash else 0),
		rebirthCount = floorNum(raw.rebirthCount, 0),
		powerLevel = floorNum(raw.powerLevel, 0),
		ropeLevel = floorNum(raw.ropeLevel, 0),
		carryLevel = floorNum(raw.carryLevel, 0),
		totalPlayTimeSeconds = floorNum(raw.totalPlayTimeSeconds, 0),
		baseFloorLevel = math.clamp(floorNum(raw.baseFloorLevel, 1), 1, 4),
		dailyDayClaimed = floorNum(raw.dailyDayClaimed, 0),
		dailyClaimedMask = floorNum(raw.dailyClaimedMask, 0),
		dailyNextAt = floorNum(raw.dailyNextAt, os.time()),
		dailySkipAllOwned = raw.dailySkipAllOwned == true,
		dailyCashBoostPercent = math.max(
			0,
			if typeof(raw.dailyCashBoostPercent) == "number" then raw.dailyCashBoostPercent else 0
		),
		storePurchases = normalizeStorePurchases(raw.storePurchases),
		giftedGamepasses = normalizeGiftedGamepasses(raw.giftedGamepasses),
		purchasedGamepasses = normalizePurchasedGamepasses(raw.purchasedGamepasses),
		indexUnlocks = readStringArray(raw.indexUnlocks),
		goldenNames = readStringArray(raw.goldenNames),
		inventory = inventory,
		parkedSlots = {},
		equipSlot = if typeof(raw.equipSlot) == "number" then raw.equipSlot else nil,
		stands = stands,
		lastSavedAt = floorNum(raw.lastSavedAt, 0),
		settings = normalizeSettings(raw.settings),
		-- Missing tutorialCompleted: only skip for profiles that already have real
		-- progress (pre-tutorial ship). Do NOT infer from cash alone — starter
		-- tutorial cash would otherwise skip first-join tutorials.
		tutorialCompleted = if typeof(raw.tutorialCompleted) == "boolean"
			then raw.tutorialCompleted
			else (
				floorNum(raw.rebirthCount, 0) > 0
					or floorNum(raw.totalPlayTimeSeconds, 0) > 120
					or (typeof(raw.inventory) == "table" and next(raw.inventory) ~= nil)
					or (typeof(raw.stands) == "table" and next(raw.stands) ~= nil)
			),
		-- Missing: if they already have cash (legacy starter), don't double-grant.
		tutorialCashGranted = if typeof(raw.tutorialCashGranted) == "boolean"
			then raw.tutorialCashGranted
			else (math.max(0, if typeof(raw.cash) == "number" then raw.cash else 0) > 0),
		tutorialFirstBushClaimed = if typeof(raw.tutorialFirstBushClaimed) == "boolean"
			then raw.tutorialFirstBushClaimed
			else (
				(typeof(raw.inventory) == "table" and next(raw.inventory) ~= nil)
					or (typeof(raw.stands) == "table" and next(raw.stands) ~= nil)
			),
		timCheeseIntroDone = raw.timCheeseIntroDone == true,
		timCheeseQuestIndex = math.max(0, floorNum(raw.timCheeseQuestIndex, 0)),
		timCheeseQuestProgress = math.max(0, floorNum(raw.timCheeseQuestProgress, 0)),
		timCheeseCompletedCount = math.max(0, floorNum(raw.timCheeseCompletedCount, 0)),
		timCheeseHarvestProgress = math.max(0, floorNum(raw.timCheeseHarvestProgress, 0)),
	}
end

local function fixParkedSlots(data: PlayerDataSchema.PlayerSaveData, raw: any)
	local parked: { number } = {}
	if typeof(raw) == "table" and typeof(raw.parkedSlots) == "table" then
		for _, v in raw.parkedSlots do
			if typeof(v) == "number" then
				table.insert(parked, math.floor(v))
			end
		end
	end
	data.parkedSlots = parked
end

local function getAsyncFromStore(store: any, key: string): (boolean, any)
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)
	return ok, result
end

local function tryMigrateFromLegacy(key: string): PlayerDataSchema.PlayerSaveData?
	for _, storeName in LEGACY_STORE_NAMES do
		if storeName == DATA_STORE_NAME then
			continue
		end
		local okGet, legacyStore = pcall(function()
			return DataStoreService:GetDataStore(storeName)
		end)
		if not okGet or not legacyStore then
			continue
		end
		local ok, raw = getAsyncFromStore(legacyStore, key)
		if not ok then
			warn("[PlayerDataService] legacy load error from", storeName, raw)
			continue
		end
		if raw == nil then
			continue
		end
		local normalized = normalizeLoadedData(raw)
		if not normalized then
			continue
		end
		fixParkedSlots(normalized, raw)
		warn("[PlayerDataService] recovered", key, "from legacy store", storeName)
		-- Copy forward into the current store immediately.
		if playerStore then
			local okSave, errSave = pcall(function()
				playerStore:SetAsync(key, normalized)
			end)
			if not okSave then
				warn("[PlayerDataService] failed copying legacy save forward:", errSave)
			end
		end
		return normalized
	end
	return nil
end

export type LoadResult = {
	data: PlayerDataSchema.PlayerSaveData?,
	-- "loaded" | "new" | "failed"
	status: string,
}

function M.loadPlayerDataResult(player: Player): LoadResult
	if not persistenceEnabled or not playerStore then
		return { data = nil, status = "new" }
	end
	local key = tostring(player.UserId)
	local lastErr: any = nil
	for attempt = 1, 4 do
		local ok, result = getAsyncFromStore(playerStore, key)
		if ok then
			if result == nil then
				local migrated = tryMigrateFromLegacy(key)
				if migrated then
					return { data = migrated, status = "loaded" }
				end
				return { data = nil, status = "new" }
			end
			local normalized = normalizeLoadedData(result)
			if normalized then
				fixParkedSlots(normalized, result)
				return { data = normalized, status = "loaded" }
			end
			warn("[PlayerDataService] normalize rejected payload for", player.Name, "- keeping as failed (will not overwrite)")
			return { data = nil, status = "failed" }
		end
		lastErr = result
		warn("[PlayerDataService] load failed attempt", attempt, player.Name, result)
		task.wait(0.8 + attempt * 0.6)
	end
	warn("[PlayerDataService] load FAILED after retries for", player.Name, lastErr)
	return { data = nil, status = "failed" }
end

function M.loadPlayerData(player: Player): PlayerDataSchema.PlayerSaveData?
	local result = M.loadPlayerDataResult(player)
	return result.data
end

local function writeBackup(player: Player, payload: PlayerDataSchema.PlayerSaveData, force: boolean?)
	if not backupStore then
		return
	end
	local userId = player.UserId
	local now = os.clock()
	if not force and (now - (lastBackupAt[userId] or 0)) < BACKUP_THROTTLE_SEC then
		return
	end
	lastBackupAt[userId] = now

	task.spawn(function()
		local key = tostring(userId) .. "_" .. tostring(os.time())
		local lastErr: any = nil
		for attempt = 1, BACKUP_RETRY_ATTEMPTS do
			local ok, err = pcall(function()
				backupStore:SetAsync(key, payload)
			end)
			if ok then
				return
			end
			lastErr = err
			if attempt < BACKUP_RETRY_ATTEMPTS and isTransientDatastoreError(err) then
				task.wait(saveRetryDelay(attempt, err))
			else
				break
			end
		end
		local hint = if isTransientDatastoreError(lastErr) then " (Roblox API blip — main save still retried)" else ""
		warn("[PlayerDataService] backup write failed:", player.Name, lastErr, hint)
	end)
end

local function shallowCopyEntries(list: { any }): { any }
	local out = table.create(#list)
	for i, entry in list do
		out[i] = entry
	end
	return out
end

local function rememberGoodStands(userId: number, standsList: { PlayerDataSchema.StandSaveEntry })
	if #standsList > 0 then
		lastGoodStands[userId] = shallowCopyEntries(standsList) :: any
	end
end

local function stickyStandsFor(userId: number): { PlayerDataSchema.StandSaveEntry }?
	local sticky = lastGoodStands[userId]
	if sticky and #sticky > 0 then
		return sticky
	end
	local prev = lastGoodPayload[userId]
	if prev and #prev.stands > 0 then
		return prev.stands
	end
	return nil
end

type MergeOpts = {
	forceEmpty: boolean,
	restoreEmptyInventory: boolean,
	restoreEmptyStands: boolean,
}

-- Merge a live snapshot against a prior good profile (session or DataStore).
-- Protects against leave/BindToClose races after inventory/plot teardown yields.
local function mergeAgainstPrior(
	payload: PlayerDataSchema.PlayerSaveData,
	prior: PlayerDataSchema.PlayerSaveData,
	opts: MergeOpts
): PlayerDataSchema.PlayerSaveData
	if opts.forceEmpty then
		return payload
	end

	local restoredInv = false
	local restoredStands = false

	if opts.restoreEmptyInventory and #payload.inventory == 0 and #prior.inventory > 0 then
		warn("[PlayerDataService] refusing inventory wipe - keeping prior inventory")
		payload.inventory = shallowCopyEntries(prior.inventory) :: any
		payload.parkedSlots = shallowCopyEntries(prior.parkedSlots) :: any
		payload.equipSlot = prior.equipSlot
		restoredInv = true
	end

	if opts.restoreEmptyStands and #payload.stands == 0 and #prior.stands > 0 then
		warn("[PlayerDataService] refusing stands wipe - keeping prior stands")
		payload.stands = shallowCopyEntries(prior.stands) :: any
		restoredStands = true
	end

	if payload.rebirthCount < prior.rebirthCount then
		warn("[PlayerDataService] refusing rebirth downgrade", payload.rebirthCount, "<", prior.rebirthCount)
		payload.rebirthCount = prior.rebirthCount
	end
	if payload.baseFloorLevel < prior.baseFloorLevel then
		warn("[PlayerDataService] refusing floor downgrade", payload.baseFloorLevel, "<", prior.baseFloorLevel)
		payload.baseFloorLevel = prior.baseFloorLevel
	end
	if payload.powerLevel < prior.powerLevel then
		payload.powerLevel = prior.powerLevel
	end
	if payload.ropeLevel < prior.ropeLevel then
		payload.ropeLevel = prior.ropeLevel
	end
	if payload.carryLevel < prior.carryLevel then
		payload.carryLevel = prior.carryLevel
	end
	if payload.totalPlayTimeSeconds < prior.totalPlayTimeSeconds then
		payload.totalPlayTimeSeconds = prior.totalPlayTimeSeconds
	end

	-- Cash → 0 while restoring wiped inventory/stands is almost always a shutdown race.
	if payload.cash <= 0 and prior.cash > 0 and (restoredInv or restoredStands or serverClosing) then
		warn("[PlayerDataService] refusing cash wipe during restore/shutdown", prior.cash)
		payload.cash = prior.cash
	end

	if typeof(prior.giftedGamepasses) == "table" then
		if typeof(payload.giftedGamepasses) ~= "table" then
			payload.giftedGamepasses = {}
		end
		for id, owned in prior.giftedGamepasses do
			if owned == true then
				payload.giftedGamepasses[id] = true
			end
		end
	end
	if typeof(prior.purchasedGamepasses) == "table" then
		if typeof(payload.purchasedGamepasses) ~= "table" then
			payload.purchasedGamepasses = {}
		end
		for id, owned in prior.purchasedGamepasses do
			if owned == true then
				payload.purchasedGamepasses[id] = true
			end
		end
	end
	if typeof(prior.storePurchases) == "table" then
		if typeof(payload.storePurchases) ~= "table" then
			payload.storePurchases = {}
		end
		for id, count in prior.storePurchases do
			local cur = payload.storePurchases[id]
			local priorN = if typeof(count) == "number" then count else 0
			local curN = if typeof(cur) == "number" then cur else 0
			if priorN > curN then
				payload.storePurchases[id] = priorN
			end
		end
	end
	if #payload.indexUnlocks < #prior.indexUnlocks then
		local seen: { [string]: boolean } = {}
		for _, key in payload.indexUnlocks do
			seen[key] = true
		end
		for _, key in prior.indexUnlocks do
			if not seen[key] then
				table.insert(payload.indexUnlocks, key)
				seen[key] = true
			end
		end
		table.sort(payload.indexUnlocks)
	end
	if prior.tutorialCompleted and not payload.tutorialCompleted then
		payload.tutorialCompleted = true
	end
	if prior.tutorialCashGranted and not payload.tutorialCashGranted then
		payload.tutorialCashGranted = true
	end
	if prior.tutorialFirstBushClaimed and not payload.tutorialFirstBushClaimed then
		payload.tutorialFirstBushClaimed = true
	end
	-- Do NOT sticky-restore timCheeseIntroDone — intentional resets / fresh tutorials must re-trigger Tim.
	if (prior.timCheeseCompletedCount or 0) > (payload.timCheeseCompletedCount or 0) then
		payload.timCheeseCompletedCount = prior.timCheeseCompletedCount
	end

	return payload
end

function M.savePlayerData(player: Player, precollected: PlayerDataSchema.PlayerSaveData?): boolean
	if not persistenceEnabled or not playerStore then
		return false
	end
	if sessionCanSave[player] == false then
		warn("[PlayerDataService] skip save — session load failed for", player.Name)
		return false
	end

	-- Snapshot BEFORE waiting: unbind/BindToClose often yield, and deferred leave
	-- teardown (inventory wipe / plot destroy) runs in that gap.
	local payload = precollected or M.collectSaveData(player)
	local isLeaveOrClose = precollected ~= nil or serverClosing
	if #payload.stands > 0 then
		rememberGoodStands(player.UserId, payload.stands)
	end

	local waitDeadline = os.clock() + 12
	while saveInFlight[player] and os.clock() < waitDeadline do
		task.wait(0.1)
	end
	if saveInFlight[player] then
		warn("[PlayerDataService] save still in flight for", player.Name, "- forcing attempt anyway")
	end

	saveInFlight[player] = true
	local key = tostring(player.UserId)
	local userId = player.UserId
	local prev = lastGoodPayload[userId]
	local forceEmpty = allowEmptyOverwrite[player] == true
	local sticky = stickyStandsFor(userId)

	-- Prefer sticky/session stands over an empty export (classic restart wipe).
	if not forceEmpty and #payload.stands == 0 and sticky then
		warn("[PlayerDataService] empty stand export for", player.Name, "- restoring sticky stands", #sticky)
		payload.stands = shallowCopyEntries(sticky) :: any
	end

	local brainrotCount = player:GetAttribute("BrainrotCount")
	local carryCount = player:GetAttribute("BrainrotCarryCount")
	local stillHasItems = (typeof(brainrotCount) == "number" and brainrotCount > 0)
		or (typeof(carryCount) == "number" and carryCount > 0)
	local hasPlot = typeof(player:GetAttribute("AssignedPlotSlot")) == "number"
	local restoreEmptyInventory = forceEmpty == false and (serverClosing or isLeaveOrClose or stillHasItems)
	local restoreEmptyStands = forceEmpty == false
		and (
			isLeaveOrClose
			or hasPlot
			or (sticky ~= nil and #sticky > 0)
		)
	if
		not forceEmpty
		and prev
		and #payload.inventory == 0
		and #payload.stands == 0
		and (#prev.inventory > 0 or #prev.stands > 0)
	then
		restoreEmptyInventory = true
		restoreEmptyStands = true
	end

	local mergeOpts: MergeOpts = {
		forceEmpty = forceEmpty,
		restoreEmptyInventory = restoreEmptyInventory,
		restoreEmptyStands = restoreEmptyStands,
	}

	if not forceEmpty and prev then
		payload = mergeAgainstPrior(payload, prev, mergeOpts)
	end

	-- Final stand guard after merges.
	if not forceEmpty and #payload.stands == 0 then
		local again = stickyStandsFor(userId)
		if again then
			payload.stands = shallowCopyEntries(again) :: any
		end
	end

	writeBackup(player, payload, isLeaveOrClose or serverClosing)

	local ok = false
	local err: any = nil
	local written: PlayerDataSchema.PlayerSaveData? = nil
	for attempt = 1, SAVE_ATTEMPTS do
		ok, err = pcall(function()
			playerStore:UpdateAsync(key, function(old)
				if forceEmpty then
					written = payload
					return payload
				end
				local oldNorm = if typeof(old) == "table" then normalizeLoadedData(old) else nil
				local toWrite = payload
				if oldNorm then
					local dsOpts: MergeOpts = {
						forceEmpty = false,
						restoreEmptyInventory = serverClosing or isLeaveOrClose or restoreEmptyInventory,
						-- Never let a restart leave wipe stands that still exist in DataStore
						-- while this session still remembers them (or is shutting down).
						restoreEmptyStands = isLeaveOrClose
							or serverClosing
							or (sticky ~= nil and #sticky > 0)
							or restoreEmptyStands,
					}
					toWrite = mergeAgainstPrior(payload, oldNorm, dsOpts)

					-- Hard refuse: empty stands over non-empty store during leave/shutdown.
					if
						#toWrite.stands == 0
						and #oldNorm.stands > 0
						and (isLeaveOrClose or serverClosing or (sticky ~= nil and #sticky > 0))
					then
						warn("[PlayerDataService] UpdateAsync keeping DataStore stands for", player.Name)
						toWrite.stands = shallowCopyEntries(oldNorm.stands) :: any
					end

					if
						#toWrite.inventory == 0
						and #oldNorm.inventory > 0
						and #toWrite.stands == 0
						and #oldNorm.stands > 0
						and toWrite.rebirthCount <= oldNorm.rebirthCount
						and toWrite.cash < oldNorm.cash
						and oldNorm.cash > 0
					then
						warn("[PlayerDataService] UpdateAsync abort destructive overwrite for", player.Name)
						written = nil
						return nil
					end
				end
				written = toWrite
				return toWrite
			end)
		end)
		if ok then
			break
		end
		local transient = isTransientDatastoreError(err)
		warn(
			"[PlayerDataService] save attempt",
			attempt,
			"failed for",
			player.Name,
			err,
			if transient then "(transient — retrying)" else ""
		)
		if attempt < SAVE_ATTEMPTS then
			task.wait(saveRetryDelay(attempt, err))
		end
	end

	saveInFlight[player] = nil
	allowEmptyOverwrite[player] = nil

	if not ok then
		local hint = if isTransientDatastoreError(err)
			then " — Roblox DataStore HTTP 500/503 blip; rejoin or wait a minute"
			else ""
		warn("[PlayerDataService] save FAILED after retries:", player.Name, err, hint)
		return false
	end

	if written == nil then
		return true
	end

	-- Never let a bad empty-stand write poison the sticky snapshot.
	if not forceEmpty and #written.stands == 0 then
		local keep = stickyStandsFor(userId)
		if keep then
			written.stands = shallowCopyEntries(keep) :: any
		end
	elseif forceEmpty then
		lastGoodStands[userId] = {}
	end

	if #written.stands > 0 then
		rememberGoodStands(userId, written.stands)
	elseif not forceEmpty and not isLeaveOrClose and hasPlot then
		-- Autosave confirmed empty plot (export empty while assigned) — allow sticky clear.
		local liveCount = invokeInternal("CountPlayerPlotStands", player)
		if typeof(liveCount) == "number" and liveCount == 0 then
			lastGoodStands[userId] = {}
		end
	end

	lastGoodPayload[userId] = written
	if player.Parent then
		player:SetAttribute(PLAY_TIME_ATTR, written.totalPlayTimeSeconds)
		sessionPlayBase[player] = written.totalPlayTimeSeconds
		sessionJoinAt[player] = os.clock()
	end
	return true
end

function M.saveAllOnlinePlayers(): number
	serverClosing = true
	pcall(function()
		game:SetAttribute("ServerClosing", true)
	end)

	-- Collect every snapshot synchronously first (no yields) so mass kicks / deferred
	-- teardowns cannot empty exports mid-loop.
	local snapshots: { [Player]: PlayerDataSchema.PlayerSaveData } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(LOADED_ATTR) == true and sessionCanSave[player] ~= false then
			local snap = M.collectSaveData(player)
			-- Prefer sticky stands if live export is already empty at shutdown.
			if #snap.stands == 0 then
				local sticky = stickyStandsFor(player.UserId)
				if sticky then
					snap.stands = shallowCopyEntries(sticky) :: any
				end
			else
				rememberGoodStands(player.UserId, snap.stands)
			end
			snapshots[player] = snap
		end
	end

	local saved = 0
	local pending = 0
	for player, snapshot in snapshots do
		pending += 1
		task.spawn(function()
			if M.savePlayerData(player, snapshot) then
				saved += 1
			end
			pending -= 1
		end)
	end

	local deadline = os.clock() + BIND_TO_CLOSE_BUDGET_SEC
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	if pending > 0 then
		warn("[PlayerDataService] BindToClose timed out with", pending, "saves still pending")
	end
	return saved
end

function M.makeDefaultSaveData(_player: Player): PlayerDataSchema.PlayerSaveData
	return {
		version = PlayerDataSchema.VERSION,
		cash = DEFAULT_CASH,
		rebirthCount = 0,
		powerLevel = 0,
		ropeLevel = 0,
		carryLevel = 0,
		totalPlayTimeSeconds = 0,
		baseFloorLevel = 1,
		dailyDayClaimed = 0,
		dailyClaimedMask = 0,
		dailyNextAt = os.time(),
		dailySkipAllOwned = false,
		dailyCashBoostPercent = 0,
		storePurchases = normalizeStorePurchases(nil),
		giftedGamepasses = normalizeGiftedGamepasses(nil),
		purchasedGamepasses = normalizePurchasedGamepasses(nil),
		indexUnlocks = {},
		goldenNames = {},
		inventory = {},
		parkedSlots = {},
		equipSlot = nil,
		stands = {},
		lastSavedAt = os.time(),
		settings = PlayerDataSchema.DEFAULT_SETTINGS,
		tutorialCompleted = false,
		tutorialCashGranted = false,
		tutorialFirstBushClaimed = false,
		timCheeseIntroDone = false,
		timCheeseQuestIndex = 0,
		timCheeseQuestProgress = 0,
		timCheeseCompletedCount = 0,
		timCheeseHarvestProgress = 0,
	}
end

local function clearStandsForPlayer(player: Player)
	task.spawn(function()
		local deadline = os.clock() + 60
		while os.clock() < deadline do
			if not player.Parent then
				return
			end
			if typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
				invokeInternal("RequestStandRescan")
				local standCount = invokeInternal("CountPlayerPlotStands", player)
				if typeof(standCount) == "number" and standCount > 0 then
					break
				end
			end
			task.wait(0.25)
		end
		invokeInternal("RequestStandRescan")
		invokeInternal("ImportStandsFromSave", player, {})
	end)
end

function M.resetPlayerData(player: Player): (boolean, string?)
	if not player.Parent then
		return false, "player_left"
	end

	M.waitUntilLoaded(player)
	sessionCanSave[player] = true
	allowEmptyOverwrite[player] = true
	lastGoodStands[player.UserId] = {}
	lastGoodPayload[player.UserId] = nil
	player:SetAttribute(LOAD_FAILED_ATTR, false)
	local fresh = M.makeDefaultSaveData(player)

	IndexService.importUnlocks(player, {}, {})
	applyAttributes(player, fresh)
	SwingUpgrades.resetLevels(player)
	player:SetAttribute("BrainrotCarryCount", 0)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, false)
	applyPlotFloor(player, fresh.baseFloorLevel)

	invokeInternal("ImportInventoryFromSave", player, {
		entries = {},
		parkedSlots = {},
		equipSlot = nil,
	})
	clearStandsForPlayer(player)

	task.defer(function()
		if not player.Parent then
			return
		end
		local refresh = getInternalFolder():FindFirstChild("RefreshRebirthState")
		if refresh and refresh:IsA("BindableFunction") then
			local okRefresh, errRefresh = pcall(function()
				(refresh :: BindableFunction):Invoke(player)
			end)
			if not okRefresh then
				warn("[PlayerDataService] RefreshRebirthState invoke failed:", errRefresh)
			end
		end
	end)

	M.savePlayerData(player)
	return true, nil
end

function M.applyLoadedData(player: Player, data: PlayerDataSchema.PlayerSaveData)
	IndexService.importUnlocks(player, data.indexUnlocks, data.goldenNames)
	applyAttributes(player, data)
	applyPlotFloor(player, data.baseFloorLevel)
	applyInventory(player, data)
	applyStands(player, data)
	task.defer(function()
		local refresh = getInternalFolder():FindFirstChild("RefreshRebirthState")
		if refresh and refresh:IsA("BindableFunction") and player.Parent then
			local okRefresh, errRefresh = pcall(function()
				(refresh :: BindableFunction):Invoke(player)
			end)
			if not okRefresh then
				warn("[PlayerDataService] RefreshRebirthState invoke failed:", errRefresh)
			end
		end
	end)
end

function M.markLoaded(player: Player)
	player:SetAttribute(LOADED_ATTR, true)
end

function M.setTutorialCompleted(player: Player, completed: boolean)
	if not player.Parent then
		return
	end
	player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, completed == true)
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

function M.setTutorialCashGranted(player: Player, granted: boolean)
	if not player.Parent then
		return
	end
	player:SetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR, granted == true)
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

function M.setTimCheeseIntroDone(player: Player, done: boolean)
	if not player.Parent then
		return
	end
	player:SetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR, done == true)
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

function M.setTimCheeseQuestState(
	player: Player,
	patch: {
		questIndex: number?,
		questProgress: number?,
		completedCount: number?,
		harvestProgress: number?,
		questReady: boolean?,
	}
)
	if not player.Parent then
		return
	end
	if typeof(patch.questIndex) == "number" then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR, math.max(0, math.floor(patch.questIndex)))
	end
	if typeof(patch.questProgress) == "number" then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR, math.max(0, math.floor(patch.questProgress)))
	end
	if typeof(patch.completedCount) == "number" then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR, math.max(0, math.floor(patch.completedCount)))
	end
	if typeof(patch.harvestProgress) == "number" then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_HARVEST_ATTR, math.max(0, math.floor(patch.harvestProgress)))
	end
	if typeof(patch.questReady) == "boolean" then
		player:SetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR, patch.questReady)
	end
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

-- Admin/tools: set swing upgrade levels (allows downgrade; updates lastGood so save merge won't revert).
function M.setSwingUpgradeLevels(
	player: Player,
	patch: { power: number?, rope: number?, carry: number? }
): SwingUpgrades.UpgradeLevels
	local levels = SwingUpgrades.readLevels(function(name: string)
		return player:GetAttribute(name)
	end)
	if typeof(patch.power) == "number" then
		levels.power = math.max(0, math.floor(patch.power))
	end
	if typeof(patch.rope) == "number" then
		levels.rope = math.max(0, math.floor(patch.rope))
	end
	if typeof(patch.carry) == "number" then
		levels.carry = math.clamp(math.floor(patch.carry), 0, SwingUpgrades.MAX_CARRY_UPGRADE_LEVEL)
	end

	player:SetAttribute(SwingUpgrades.POWER_LEVEL_ATTR, levels.power)
	player:SetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR, levels.rope)
	player:SetAttribute(SwingUpgrades.CARRY_LEVEL_ATTR, levels.carry)
	SwingUpgrades.syncGameplayStatsFromLevels(player, levels)

	local prev = lastGoodPayload[player.UserId]
	if prev then
		prev.powerLevel = levels.power
		prev.ropeLevel = levels.rope
		prev.carryLevel = levels.carry
	end
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
	return levels
end

function M.replayTutorial(player: Player)
	if not player.Parent then
		return
	end
	player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, false)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR, false)
	local nonce = player:GetAttribute(PlayerDataSchema.TUTORIAL_REPLAY_ATTR)
	local nextNonce = if typeof(nonce) == "number" then nonce + 1 else 1
	player:SetAttribute(PlayerDataSchema.TUTORIAL_REPLAY_ATTR, nextNonce)
	if player:GetAttribute(LOADED_ATTR) == true then
		M.savePlayerData(player)
	end
end

function M.bindPlayer(player: Player)
	sessionJoinAt[player] = os.clock()
	sessionPlayBase[player] = floorNum(player:GetAttribute(PLAY_TIME_ATTR), 0)
	player:SetAttribute(LOAD_FAILED_ATTR, false)

	if not persistenceEnabled then
		sessionCanSave[player] = false
		local fresh = M.makeDefaultSaveData(player)
		M.applyLoadedData(player, fresh)
		M.markLoaded(player)
		return
	end

	local result = M.loadPlayerDataResult(player)
	if result.status == "failed" then
		sessionCanSave[player] = false
		player:SetAttribute(LOAD_FAILED_ATTR, true)
		-- Soft defaults for this session only — NEVER persist over a failed load.
		applySettings(player, PlayerDataSchema.DEFAULT_SETTINGS)
		M.markLoaded(player)
		warn("[PlayerDataService] playing without save for", player.Name, "(load failed — data preserved in DataStore)")
		return
	end

	sessionCanSave[player] = true
	if result.status == "loaded" and result.data then
		M.applyLoadedData(player, result.data)
		lastGoodPayload[player.UserId] = result.data
		rememberGoodStands(player.UserId, result.data.stands)
	else
		-- Confirmed new player (key missing after legacy migration attempt).
		local fresh = M.makeDefaultSaveData(player)
		M.applyLoadedData(player, fresh)
		lastGoodPayload[player.UserId] = fresh
		lastGoodStands[player.UserId] = {}
	end
	M.markLoaded(player)
end

function M.unbindPlayer(player: Player)
	-- Collect BEFORE any yield so deferred BushHarvest/plot teardown cannot empty exports.
	local snapshot: PlayerDataSchema.PlayerSaveData? = nil
	if sessionCanSave[player] ~= false and persistenceEnabled and playerStore then
		snapshot = M.collectSaveData(player)
		if #snapshot.stands > 0 then
			rememberGoodStands(player.UserId, snapshot.stands)
		else
			local stickyLeave = stickyStandsFor(player.UserId)
			if stickyLeave then
				snapshot.stands = shallowCopyEntries(stickyLeave) :: any
			end
		end
	end

	local deadline = os.clock() + 12
	while saveInFlight[player] and os.clock() < deadline do
		task.wait(0.1)
	end
	if snapshot then
		M.savePlayerData(player, snapshot)
	end
	sessionJoinAt[player] = nil
	sessionPlayBase[player] = nil
	saveInFlight[player] = nil
	sessionCanSave[player] = nil
	allowEmptyOverwrite[player] = nil
end

local function waitForSaveBindables()
	local internal = ServerStorage:WaitForChild("BrainrotInternal", 120)
	if not internal then
		warn("[PlayerDataService] BrainrotInternal missing — save hooks unavailable")
		return
	end
	local names = { "ExportInventoryForSave", "ImportInventoryFromSave", "ExportStandsForSave", "ImportStandsFromSave" }
	for _, name in names do
		local bf = internal:WaitForChild(name, 120)
		if not bf then
			warn("[PlayerDataService] Missing save bindable:", name)
		end
	end
end

function M.start()
	if not persistenceEnabled then
		warn("[PlayerDataService] Persistence disabled — session-only data (enable Studio API access to test saves)")
	end

	waitForSaveBindables()

	for _, player in Players:GetPlayers() do
		task.spawn(M.bindPlayer, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(M.bindPlayer, player)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL_SEC)
			for _, player in Players:GetPlayers() do
				if player:GetAttribute(LOADED_ATTR) == true and sessionCanSave[player] ~= false then
					task.spawn(M.savePlayerData, player)
				end
			end
		end
	end)
end

-- Register before other scripts connect PlayerRemoving (BushHarvest clears inventory on leave).
Players.PlayerRemoving:Connect(function(player)
	M.unbindPlayer(player)
end)

game:BindToClose(function()
	-- Roblox Creator "Restart / shut down all servers" invokes BindToClose on each
	-- instance. Snapshot+save everyone before the process is killed (~30s budget).
	M.saveAllOnlinePlayers()
end)

return M
