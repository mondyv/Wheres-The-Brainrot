-- [ACTIVE] BushHarvestInternal
--[[
	ServerStorage.BrainrotInternal bindables used by PlayerDataService, StoreHandler,
	StandManager, Daily, LuckyBlock, AdminCommands, etc.
	Kept in a separate module so BushHarvest.server stays under Luau's 200 local register limit.
]]

local ServerStorage = game:GetService("ServerStorage")

local M = {}

export type BrainrotInvEntry = {
	name: string,
	icon: string,
	sourcePath: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

export type InstallConfig = {
	consumeInventoryEntry: (Player, number) -> BrainrotInvEntry?,
	pushBrainrotInventory: (Player, BrainrotInvEntry, boolean?) -> boolean,
	brainrotInventories: { [Player]: { BrainrotInvEntry } },
	brainrotParkedInExpandedBackpack: { [Player]: { [number]: boolean } },
	brainrotHotbarSlots: { [Player]: { [number]: number } },
	enrichEntryFromCatalog: (BrainrotInvEntry) -> (),
	enrichEntryFromBrainrotsFolder: (Folder, BrainrotInvEntry) -> (),
	Brainrots: any,
	IndexService: any,
	packInventoryForClient: (Player, { BrainrotInvEntry }, number?) -> any,
	hotbarSlotsPayloadForPlayer: (Player, { BrainrotInvEntry }) -> { [number]: number },
	syncBrainrotCarryCountAttr: (Player) -> (),
	ensureInventoryRemotes: () -> RemoteEvent,
	equipBrainrotSlotForPlayer: (Player, number, boolean?) -> number?,
	notifyClientInventorySync: (Player, number?, boolean?) -> (),
	notifyIndexDeposited: (Player, BrainrotInvEntry) -> (),
	HOTBAR_UI_SLOTS: number,
}

local function ensureInternalFolder(): Folder
	local existing = ServerStorage:FindFirstChild("BrainrotInternal")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = "BrainrotInternal"
	newFolder.Parent = ServerStorage
	return newFolder
end

local function ensureBindable(name: string): BindableFunction
	local internal = ensureInternalFolder()
	local existing = internal:FindFirstChild(name)
	if existing and existing:IsA("BindableFunction") then
		return existing
	end
	local bf = Instance.new("BindableFunction")
	bf.Name = name
	bf.Parent = internal
	return bf
end

function M.install(config: InstallConfig)
	do
		local consumeBF = ensureBindable("ConsumeInventoryEntry")
		consumeBF.OnInvoke = function(player: any, idx: any): any
			if typeof(player) ~= "Instance" or not (player :: any):IsA("Player") then
				return nil
			end
			if typeof(idx) ~= "number" then
				return nil
			end
			return config.consumeInventoryEntry(player :: Player, idx)
		end
	end

	do
		local returnBF = ensureBindable("ReturnInventoryEntry")
		returnBF.OnInvoke = function(player: any, entryArg: any): any
			if typeof(player) ~= "Instance" or not (player :: any):IsA("Player") then
				return false
			end
			if typeof(entryArg) ~= "table" then
				return false
			end
			local incoming = entryArg :: any
			local name = if typeof(incoming.name) == "string" then incoming.name else nil
			if not name then
				return false
			end
			local icon = if typeof(incoming.icon) == "string" then incoming.icon else ""
			local sourcePath = if typeof(incoming.sourcePath) == "string" then incoming.sourcePath else ""
			local rarity = if typeof(incoming.rarity) == "string" then incoming.rarity else "common"
			local mutation = if typeof(incoming.mutation) == "string" then incoming.mutation else "normal"
			local level = if typeof(incoming.level) == "number" then math.max(1, math.floor(incoming.level)) else 1
			local baseIncome = if typeof(incoming.baseIncome) == "number" then incoming.baseIncome else 0

			local entry: BrainrotInvEntry = {
				name = name,
				icon = icon,
				sourcePath = sourcePath,
				rarity = rarity,
				mutation = mutation,
				level = level,
				baseIncome = baseIncome,
			}
			if entry.icon == "" then
				local brainrotsFolder = config.Brainrots.getBrainrotsFolder()
				if brainrotsFolder and brainrotsFolder:IsA("Folder") then
					config.enrichEntryFromBrainrotsFolder(brainrotsFolder :: Folder, entry)
				end
			end
			config.enrichEntryFromCatalog(entry)
			return config.pushBrainrotInventory(player :: Player, entry)
		end
	end

	do
		local exportSaveBF = ensureBindable("ExportInventoryForSave")
		exportSaveBF.OnInvoke = function(playerArg: any): any
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return { entries = {}, parkedSlots = {}, hotbarSlots = {}, equipSlot = nil }
			end
			local plr = playerArg :: Player
			local list = config.brainrotInventories[plr] or {}
			local entries = {}
			for _, entry in ipairs(list) do
				table.insert(entries, {
					name = entry.name,
					icon = entry.icon,
					sourcePath = entry.sourcePath,
					rarity = entry.rarity,
					mutation = entry.mutation,
					level = entry.level,
					baseIncome = entry.baseIncome,
				})
			end
			local parked: { number } = {}
			local map = config.brainrotParkedInExpandedBackpack[plr] or {}
			for slot in map do
				table.insert(parked, slot)
			end
			table.sort(parked)
			return {
				entries = entries,
				parkedSlots = parked,
				hotbarSlots = config.hotbarSlotsPayloadForPlayer(plr, list),
				equipSlot = plr:GetAttribute("BrainrotEquipSlot"),
			}
		end
	end

	do
		local importSaveBF = ensureBindable("ImportInventoryFromSave")
		importSaveBF.OnInvoke = function(playerArg: any, payloadArg: any): boolean
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return false
			end
			if typeof(payloadArg) ~= "table" then
				return false
			end
			local plr = playerArg :: Player
			local payload = payloadArg :: any
			local rebuilt: { BrainrotInvEntry } = {}
			if typeof(payload.entries) == "table" then
				for _, raw in payload.entries do
					if typeof(raw) == "table" and typeof(raw.name) == "string" and raw.name ~= "" then
						local entry: BrainrotInvEntry = {
							name = raw.name,
							icon = if typeof(raw.icon) == "string" then raw.icon else "",
							sourcePath = if typeof(raw.sourcePath) == "string" then raw.sourcePath else "",
							rarity = if typeof(raw.rarity) == "string" then raw.rarity else "common",
							mutation = if typeof(raw.mutation) == "string" then raw.mutation else "normal",
							level = if typeof(raw.level) == "number" then math.max(1, math.floor(raw.level)) else 1,
							baseIncome = if typeof(raw.baseIncome) == "number" then raw.baseIncome else 0,
						}
						config.enrichEntryFromCatalog(entry)
						table.insert(rebuilt, entry)
					end
				end
			end
			config.brainrotInventories[plr] = rebuilt
			local parked: { [number]: boolean } = {}
			if typeof(payload.parkedSlots) == "table" then
				for _, slot in payload.parkedSlots do
					if typeof(slot) == "number" then
						parked[math.floor(slot)] = true
					end
				end
			end
			config.brainrotParkedInExpandedBackpack[plr] = parked
			local hotbarSlots: { [number]: number } = {}
			if typeof(payload.hotbarSlots) == "table" then
				for rawIdx, rawSlot in pairs(payload.hotbarSlots :: any) do
					local idxNum = if typeof(rawIdx) == "number" then rawIdx else tonumber(rawIdx)
					if typeof(idxNum) == "number" and typeof(rawSlot) == "number" then
						local idx = math.floor(idxNum)
						local slot = math.floor(rawSlot)
						if idx >= 1 and rebuilt[idx] ~= nil and slot >= 1 and slot <= config.HOTBAR_UI_SLOTS then
							hotbarSlots[idx] = slot
						end
					end
				end
			end
			config.brainrotHotbarSlots[plr] = hotbarSlots
			plr:SetAttribute("BrainrotCount", #rebuilt)
			config.syncBrainrotCarryCountAttr(plr)
			local equipSlot = if typeof(payload.equipSlot) == "number" then math.floor(payload.equipSlot) else nil
			if equipSlot then
				plr:SetAttribute("BrainrotEquipSlot", equipSlot)
			end
			local sync = config.ensureInventoryRemotes()
			sync:FireClient(plr, config.packInventoryForClient(plr, rebuilt, equipSlot))
			return true
		end
	end

	do
		local getListBF = ensureBindable("GetInventoryList")
		getListBF.OnInvoke = function(playerArg: any): any
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return {}
			end
			local plr = playerArg :: Player
			local list = config.brainrotInventories[plr] or {}
			local out = {}
			for _, entry in ipairs(list) do
				table.insert(out, {
					name = entry.name,
					rarity = entry.rarity,
					icon = entry.icon,
				})
			end
			return out
		end
	end

	do
		local grantBF = ensureBindable("GrantBrainrotAndEquip")
		grantBF.OnInvoke = function(playerArg: any, entryArg: any, opts: any): boolean
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return false
			end
			if typeof(entryArg) ~= "table" then
				return false
			end
			local plr = playerArg :: Player
			if not config.brainrotInventories[plr] then
				config.brainrotInventories[plr] = {}
			end
			if not config.brainrotParkedInExpandedBackpack[plr] then
				config.brainrotParkedInExpandedBackpack[plr] = {}
			end
			local incoming = entryArg :: any
			local name = if typeof(incoming.name) == "string" then incoming.name else nil
			if not name or name == "" then
				return false
			end

			local rarity = if typeof(incoming.rarity) == "string" then incoming.rarity else "common"
			local mutation = if typeof(incoming.mutation) == "string" then incoming.mutation else "normal"
			local level = if typeof(incoming.level) == "number" then math.max(1, math.floor(incoming.level)) else 1
			local baseIncome = if typeof(incoming.baseIncome) == "number" then incoming.baseIncome else 0
			local icon = if typeof(incoming.icon) == "string" then incoming.icon else ""
			local sourcePath = if typeof(incoming.sourcePath) == "string" then incoming.sourcePath else ""

			local entry: BrainrotInvEntry = {
				name = name,
				icon = icon,
				sourcePath = sourcePath,
				rarity = rarity,
				mutation = mutation,
				level = level,
				baseIncome = baseIncome,
			}

			local brainrotsFolder = config.Brainrots.getBrainrotsFolder()
			if brainrotsFolder and brainrotsFolder:IsA("Folder") then
				config.enrichEntryFromBrainrotsFolder(brainrotsFolder :: Folder, entry)
			end
			config.enrichEntryFromCatalog(entry)
			if entry.icon == "" then
				local mutationId = if entry.mutation ~= "" then entry.mutation else "normal"
				entry.icon = config.IndexService.getIconFor(entry.name, mutationId)
			end

			if not config.pushBrainrotInventory(plr, entry, true) then
				return false
			end

			local list = config.brainrotInventories[plr]
			if not list then
				return true
			end
			local newSlot = #list

			config.notifyIndexDeposited(plr, entry)

			local forceEquip = true
			if typeof(opts) == "table" and opts.equip == false then
				forceEquip = false
			end
			local syncSlot = newSlot
			if forceEquip then
				local equippedIdx = config.equipBrainrotSlotForPlayer(plr, newSlot, true)
				if typeof(equippedIdx) == "number" then
					syncSlot = equippedIdx
				else
					task.spawn(function()
						for _ = 1, 24 do
							local idx = config.equipBrainrotSlotForPlayer(plr, newSlot, true)
							if typeof(idx) == "number" then
								config.notifyClientInventorySync(plr, idx, false)
								return
							end
							task.wait(0.25)
						end
					end)
				end
			end
			config.notifyClientInventorySync(plr, syncSlot, false)
			return true
		end
	end
end

return M
