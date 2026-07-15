-- [ACTIVE] PlayerDataService
--[[
	Single owner of the PlayerData_v1 DataStore key.
	Persistence is disabled in Studio; live servers save cash, upgrades, rebirth, index,
	inventory, stand brainrots, floor level, daily progress, and total play time.
--]]

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
local DATA_STORE_NAME = ENVIRONMENT .. "_#003"

local AUTOSAVE_INTERVAL_SEC = 300
local DEFAULT_CASH = 1_000_000
local LOADED_ATTR = PlayerDataSchema.LOADED_ATTR
local PLAY_TIME_ATTR = PlayerDataSchema.TOTAL_PLAY_TIME_ATTR

local persistenceEnabled = LiveDataStores.isEnabled()
local playerStore = if persistenceEnabled then DataStoreService:GetDataStore(DATA_STORE_NAME) else nil

local sessionJoinAt: { [Player]: number } = {}
local sessionPlayBase: { [Player]: number } = {}
local saveInFlight: { [Player]: boolean } = {}

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

function M.waitUntilLoaded(player: Player)
	if not persistenceEnabled then
		return
	end
	while player.Parent and player:GetAttribute(LOADED_ATTR) ~= true do
		player:GetAttributeChangedSignal(LOADED_ATTR):Wait()
	end
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
		freeStealCount = floorNum(player:GetAttribute(A.FREE_STEAL_COUNT), 0),
		packPurchases = packPurchases,
	}
end

local function normalizeStorePurchases(raw: any): { [string]: any }
	local out = {
		exclusiveOwned = false,
		freeUncommonClaimed = false,
		freeStealCount = 0,
		packPurchases = {},
	}

	if typeof(raw) ~= "table" then
		return out
	end

	out.exclusiveOwned = readBool(raw.exclusiveOwned, false)
	out.freeUncommonClaimed = readBool(raw.freeUncommonClaimed, false)
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

local function collectGiftedGamepasses(player: Player): PlayerDataSchema.GiftedGamepassesSaveData
	local out: PlayerDataSchema.GiftedGamepassesSaveData = {}
	for gamePassId, attr in StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID do
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
		}
	end
	return {
		musicVolume = clamp01(raw.musicVolume, d.musicVolume),
		sfxVolume = clamp01(raw.sfxVolume, d.sfxVolume),
		uiSoundsEnabled = readBool(raw.uiSoundsEnabled, d.uiSoundsEnabled),
		slowWalkEnabled = readBool(raw.slowWalkEnabled, d.slowWalkEnabled),
		showOtherBrainrots = readBool(raw.showOtherBrainrots, d.showOtherBrainrots),
		brainrotVfxEnabled = readBool(raw.brainrotVfxEnabled, d.brainrotVfxEnabled),
		globalMessagesEnabled = readBool(raw.globalMessagesEnabled, d.globalMessagesEnabled),
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
	player:SetAttribute("SlowWalkEnabled", settings.slowWalkEnabled)
	player:SetAttribute("ShowOtherBrainrots", settings.showOtherBrainrots)
	player:SetAttribute("BrainrotVFXEnabled", settings.brainrotVfxEnabled)
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
		indexUnlocks = unlockKeys,
		goldenNames = goldenNames,
		inventory = inventory,
		parkedSlots = parkedSlots,
		equipSlot = equipSlot,
		stands = stands,
		lastSavedAt = os.time(),
		settings = collectSettings(player),
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
	})
	applySettings(player, merged)
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
	applySettings(player, (data :: any).settings)

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
		indexUnlocks = readStringArray(raw.indexUnlocks),
		goldenNames = readStringArray(raw.goldenNames),
		inventory = inventory,
		parkedSlots = {},
		equipSlot = if typeof(raw.equipSlot) == "number" then raw.equipSlot else nil,
		stands = stands,
		lastSavedAt = floorNum(raw.lastSavedAt, 0),
		settings = normalizeSettings(raw.settings),
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

function M.loadPlayerData(player: Player): PlayerDataSchema.PlayerSaveData?
	if not persistenceEnabled or not playerStore then
		return nil
	end
	local key = tostring(player.UserId)
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return playerStore:GetAsync(key)
		end)
		if ok then
			if result == nil then
				return nil
			end
			local normalized = normalizeLoadedData(result)
			if normalized then
				fixParkedSlots(normalized, result)
			end
			return normalized
		end
		warn("[PlayerDataService] load failed attempt", attempt, player.Name, result)
		task.wait(1 + attempt)
	end
	return nil
end

function M.savePlayerData(player: Player): boolean
	if not persistenceEnabled or not playerStore or saveInFlight[player] then
		return false
	end
	saveInFlight[player] = true
	local key = tostring(player.UserId)
	local payload = M.collectSaveData(player)
	local ok, err = pcall(function()
		playerStore:SetAsync(key, payload)
	end)
	saveInFlight[player] = nil
	if not ok then
		warn("[PlayerDataService] save failed:", player.Name, err)
		return false
	end
	player:SetAttribute(PLAY_TIME_ATTR, payload.totalPlayTimeSeconds)
	sessionPlayBase[player] = payload.totalPlayTimeSeconds
	sessionJoinAt[player] = os.clock()
	return true
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
		indexUnlocks = {},
		goldenNames = {},
		inventory = {},
		parkedSlots = {},
		equipSlot = nil,
		stands = {},
		lastSavedAt = os.time(),
		settings = PlayerDataSchema.DEFAULT_SETTINGS,
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
	local fresh = M.makeDefaultSaveData(player)

	IndexService.importUnlocks(player, {}, {})
	applyAttributes(player, fresh)
	SwingUpgrades.resetLevels(player)
	player:SetAttribute("BrainrotCarryCount", 0)
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

function M.bindPlayer(player: Player)
	sessionJoinAt[player] = os.clock()
	sessionPlayBase[player] = floorNum(player:GetAttribute(PLAY_TIME_ATTR), 0)

	if not persistenceEnabled then
		applySettings(player, PlayerDataSchema.DEFAULT_SETTINGS)
		M.markLoaded(player)
		return
	end

	local loaded = M.loadPlayerData(player)
	if loaded then
		M.applyLoadedData(player, loaded)
	else
		applySettings(player, PlayerDataSchema.DEFAULT_SETTINGS)
	end
	M.markLoaded(player)
end

function M.unbindPlayer(player: Player)
	-- If an autosave is mid-flight, wait for it to finish so the final leave-save
	-- isn't silently skipped (savePlayerData returns false while saveInFlight is set).
	local deadline = os.clock() + 10
	while saveInFlight[player] and os.clock() < deadline do
		task.wait(0.1)
	end
	M.savePlayerData(player)
	sessionJoinAt[player] = nil
	sessionPlayBase[player] = nil
	saveInFlight[player] = nil
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
				if player:GetAttribute(LOADED_ATTR) == true then
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
	for _, player in Players:GetPlayers() do
		-- Wait out any in-flight autosave so the shutdown save isn't silently skipped.
		local deadline = os.clock() + 10
		while saveInFlight[player] and os.clock() < deadline do
			task.wait(0.1)
		end
		M.savePlayerData(player)
	end
end)

return M
