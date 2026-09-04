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

export type BootConfig = {
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
	BrainrotEconomy: any,
	assignEntryToLowestFreeHotbarSlot: (
		Player,
		{ BrainrotInvEntry },
		{ [number]: boolean },
		number
	) -> number?,
	playerInInventoryZone: (Player) -> boolean,
	SafezoneUtil: any,
	destroyAllBrainrotToolsForPlayer: (Player) -> (),
	shiftParkedMapAfterListRemove: ({ [number]: boolean }, number) -> (),
	getBushRemotesFolder: () -> Folder,
	ensureEquipBrainrotRemote: () -> RemoteEvent,
	offerFloatingBrainrot: ((any, any) -> boolean)?,
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
			local plr = playerArg :: Player
			if not config.brainrotInventories[plr] then
				config.brainrotInventories[plr] = {}
			end
			if not config.brainrotParkedInExpandedBackpack[plr] then
				config.brainrotParkedInExpandedBackpack[plr] = {}
			end

			local skipSync = typeof(opts) == "table" and opts.skipSync == true
			local syncOnly = typeof(opts) == "table" and opts.syncOnly == true
			if syncOnly then
				-- Gift batches leave leftover 3D tools in Backpack; wipe those so
				-- the toolbar can select the new rows. Keep whatever is in-hand.
				local bp = plr:FindFirstChildOfClass("Backpack")
				if bp then
					for _, c in ipairs(bp:GetChildren()) do
						if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
							c:Destroy()
						end
					end
				end
				config.notifyClientInventorySync(plr, nil)
				return true
			end

			if typeof(entryArg) ~= "table" then
				return false
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

			-- Folder mesh lookup is expensive; catalog + index icon is enough to stash
			-- the row. The tool clone happens later when the player actually equips.
			if not skipSync then
				local brainrotsFolder = config.Brainrots.getBrainrotsFolder()
				if brainrotsFolder and brainrotsFolder:IsA("Folder") then
					config.enrichEntryFromBrainrotsFolder(brainrotsFolder :: Folder, entry)
				end
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
			if skipSync then
				return true
			end
			if forceEquip then
				local equippedIdx = config.equipBrainrotSlotForPlayer(plr, newSlot, true)
				if typeof(equippedIdx) == "number" then
					config.notifyClientInventorySync(plr, equippedIdx, false)
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
					config.notifyClientInventorySync(plr, newSlot, false)
				end
			else
				-- Do not pass a slot: notifyClientInventorySync auto-equips in spawn
				-- and would clone a 3D tool per gift (lag + unselectable duplicates).
				config.notifyClientInventorySync(plr, nil)
			end
			return true
		end
	end
end

function M.boot(config: BootConfig)
	local function inventoryEntryIncome(entry: BrainrotInvEntry): number
		config.enrichEntryFromCatalog(entry)
		return config.BrainrotEconomy.incomePerSecond({
			name = entry.name,
			rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
			mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
			level = if typeof(entry.level) == "number" then entry.level else 1,
			baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
		})
	end

	local function equipBestBrainrotForPlayer(plr: Player): boolean
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local canUse = config.playerInInventoryZone(plr)
			or config.SafezoneUtil.isCharacterInSafezone(char)
			or config.SafezoneUtil.isCharacterInToolbarZone(char)
			or (hrp and hrp:IsA("BasePart") and config.SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position))
		if not canUse then
			return false
		end
		local list = config.brainrotInventories[plr]
		if not list or #list == 0 then
			return false
		end
		local map = config.brainrotParkedInExpandedBackpack[plr]
		if not map then
			map = {}
			config.brainrotParkedInExpandedBackpack[plr] = map
		end

		local bestIdx: number? = nil
		local bestIncome = -math.huge
		for i, entry in ipairs(list) do
			local inc = inventoryEntryIncome(entry)
			if inc > bestIncome then
				bestIncome = inc
				bestIdx = i
			end
		end
		if not bestIdx then
			return false
		end

		-- Already holding the best brainrot — no sync, reshuffle, or re-equip.
		local equippedTool = char and char:FindFirstChildOfClass("Tool")
		if equippedTool and equippedTool:GetAttribute("BrainrotTool") == true then
			local equippedIdx = equippedTool:GetAttribute("BrainrotInvIndex")
			if typeof(equippedIdx) == "number" and math.floor(equippedIdx) == bestIdx then
				return false
			end
		end

		-- Move parked / overflow best entry onto a free hotbar cell, but always sync/equip
		-- by inventory index (assignEntry returns a hotbar cell, not a list index).
		if bestIdx > config.HOTBAR_UI_SLOTS or map[bestIdx] == true then
			if not config.assignEntryToLowestFreeHotbarSlot(plr, list, map, bestIdx) then
				return false
			end
		end

		config.notifyClientInventorySync(plr, bestIdx, true)
		return true
	end

	local function ensureEquipBestBrainrotRemote(): RemoteEvent
		local folder = config.getBushRemotesFolder()
		local ev = folder:FindFirstChild("EquipBestBrainrot")
		if not ev then
			ev = Instance.new("RemoteEvent")
			ev.Name = "EquipBestBrainrot"
			ev.Parent = folder
		end
		return ev :: RemoteEvent
	end

	local function consumeInventoryEntry(plr: Player, idx: number): BrainrotInvEntry?
		local list = config.brainrotInventories[plr]
		if not list then
			return nil
		end
		local i = math.floor(idx)
		if i < 1 or i > #list then
			return nil
		end
		local entry = list[i]
		if not entry then
			return nil
		end
		config.enrichEntryFromCatalog(entry)

		local char = plr.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			local equipped = char:FindFirstChildOfClass("Tool")
			if equipped and equipped:GetAttribute("BrainrotTool") == true then
				local a = equipped:GetAttribute("BrainrotInvIndex")
				if typeof(a) == "number" and math.floor(a) == i and hum then
					hum:UnequipTools()
				end
			end
		end
		config.destroyAllBrainrotToolsForPlayer(plr)

		local map = config.brainrotParkedInExpandedBackpack[plr]
		if map then
			config.shiftParkedMapAfterListRemove(map, i)
		end
		table.remove(list, i)
		plr:SetAttribute("BrainrotCount", #list)

		local sync = config.ensureInventoryRemotes()
		sync:FireClient(plr, config.packInventoryForClient(plr, list))
		return entry
	end

	M.install({
		consumeInventoryEntry = consumeInventoryEntry,
		pushBrainrotInventory = config.pushBrainrotInventory,
		brainrotInventories = config.brainrotInventories,
		brainrotParkedInExpandedBackpack = config.brainrotParkedInExpandedBackpack,
		brainrotHotbarSlots = config.brainrotHotbarSlots,
		enrichEntryFromCatalog = config.enrichEntryFromCatalog,
		enrichEntryFromBrainrotsFolder = config.enrichEntryFromBrainrotsFolder,
		Brainrots = config.Brainrots,
		IndexService = config.IndexService,
		packInventoryForClient = config.packInventoryForClient,
		hotbarSlotsPayloadForPlayer = config.hotbarSlotsPayloadForPlayer,
		syncBrainrotCarryCountAttr = config.syncBrainrotCarryCountAttr,
		ensureInventoryRemotes = config.ensureInventoryRemotes,
		equipBrainrotSlotForPlayer = config.equipBrainrotSlotForPlayer,
		notifyClientInventorySync = config.notifyClientInventorySync,
		notifyIndexDeposited = config.notifyIndexDeposited,
		HOTBAR_UI_SLOTS = config.HOTBAR_UI_SLOTS,
	})

	if typeof(config.offerFloatingBrainrot) == "function" then
		local offerBF = ensureBindable("OfferFloatingBrainrot")
		offerBF.OnInvoke = function(playerArg: any, payloadArg: any): boolean
			return config.offerFloatingBrainrot(playerArg, payloadArg)
		end
	end

	ensureEquipBestBrainrotRemote().OnServerEvent:Connect(function(player: Player)
		equipBestBrainrotForPlayer(player)
	end)

	config.ensureEquipBrainrotRemote().OnServerEvent:Connect(function(player: Player, slot: any, forceArg: any)
		if typeof(slot) ~= "number" then
			return
		end
		local forceEquip = forceArg == true
		local equippedIdx = config.equipBrainrotSlotForPlayer(player, slot :: number, forceEquip)
		if equippedIdx then
			-- Sync inventory only. Passing the slot re-ran auto-equip and made the
			-- client steal the backpack outline / put the tool back after unequip.
			config.notifyClientInventorySync(player, nil)
		end
	end)
end

return M
