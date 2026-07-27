-- [ACTIVE] BushHarvest.server
--[[
	Harvest: spawn brainrot → short pop → float ~4s above bush → weld above player → touch deposit (or stand inside RedWall) to redeem into inventory.
	Stack count is capped by the Carry upgrade (player attribute Carry, default 1); extras cannot be harvested until redeemed or dropped.
	Templates: ServerStorage.Brainrots/<Name>/<MutationVariant> (Studio). Deposits: CollectionService tag BrainrotDeposit.
	Inventory: BrainrotCount matches list size; sync payload includes tuckedSlots (indices 1–9 UI-moved into backpack panel),
	plus per-entry rarity/mutation/level/baseIncome so the UI + stand placement keep the same brainrot identity.
	Keep MAX_HARVEST_RANGE in sync with src/client/BushHoldInteraction.luau.

	Spawn flow: plot-of-player → rarity weight → mutation weight → pick template (mutation variant, fallback Normal).
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))
local BushHarvestBrainrotEquip = require(Modules:WaitForChild("BushHarvestBrainrotEquip"))
local IndexService = require(Modules:WaitForChild("IndexService"))
local PlayerDataService = require(Modules:WaitForChild("PlayerDataService"))
local BrainrotHeader = require(Modules:WaitForChild("BrainrotHeader"))
local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck
local LuckBoost = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckBoost"))

type BrainrotInvEntry = {
	name: string,
	icon: string,
	sourcePath: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

local MAX_HARVEST_RANGE = 14
local RANGE_SLACK = 5
-- Per bush: 50/50 hidden brainrot vs empty (rolled when bush becomes available or after cooldown).
local BUSH_BRAINROT_CHANCE = 0.5
local BUSH_SEARCH_DEBOUNCE_SEC = 0.4
local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local BUSH_HIDDEN_NAME_ATTR = "HiddenBrainrotName"
local BUSH_HIDDEN_MUTATION_ATTR = "HiddenBrainrotMutation"
local BUSH_HIDDEN_LEVEL_ATTR = "HiddenBrainrotLevel"
local BUSH_HIDDEN_BASE_INCOME_ATTR = "HiddenBrainrotBaseIncome"
local BUSH_ON_COOLDOWN_ATTR = "BushOnCooldown"
local BUSH_LOOT_PHASE_ATTR = "BushLootPhase"
local BUSH_COOLDOWN_ENDS_ATTR = "BushCooldownEndsAt"
local BUSH_LOOT_PHASE_READY = "ready"
local BUSH_LOOT_PHASE_COOLDOWN = "cooldown"
local BUSH_LOOT_RESPAWN_MIN = 10
local BUSH_LOOT_RESPAWN_MAX = 15
local bushLootRespawnToken: { [Instance]: number } = {}
local releaseBushAfterFloatingTimeout: (string) -> ()
local POP_DURATION = 1.55
local BUSH_FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }
local BUSH_EMPTY_MESSAGE_ANCHOR_NAME = "_BushEmptyMessageAnchor"
local DEPOSIT_TAG = "BrainrotDeposit"
local MAX_BACKPACK_BRAINROT_SLOTS = 19
-- Total brainrot inventory capacity (UI "All Items [used/max]"); distinct from the 19 backpack grid rows.
local MAX_BRAINROT_INVENTORY_CAPACITY = 100
-- Fallback when Head / UpperTorso missing (e.g. custom rigs).
local _HRP_CARRY_OFFSET = CFrame.new(0, 3.4, 0.2) * CFrame.Angles(0, math.rad(180), 0)

-- Multiple brainrots per player while swinging: capacity = max(1, floor(Carry upgrade attribute)).
local pendingFloats: { [Player]: { Model } } = {}
local activeCarries: { [Player]: { Model } } = {}
local floatConnByClone: { [Model]: RBXScriptConnection } = {}
local attachCarriedBrainrot: (Player, Model) -> ()
-- Safe-zone SFX: once per carry model instance (avoids RedWall touch spam).
local safeZoneSfxPlayedForCarry: { [Model]: boolean } = {}
local brainrotInventories: { [Player]: { BrainrotInvEntry } } = {}
-- Indices 1–9 only: brainrot shown in expanded backpack grid instead of custom hotbar (client drag).
local brainrotParkedInExpandedBackpack: { [Player]: { [number]: boolean } } = {}
-- Optional exact hotbar placement for normal brainrots.
-- Key = dense inventory index, value = visible hotbar slot (1..9). This lets
-- a player put 3 brainrots in slots like 1, 5, and 9 without padding the
-- inventory list with fake/blank entries.
local brainrotHotbarSlots: { [Player]: { [number]: number } } = {}

local function carryCapacityForPlayer(plr: Player): number
	local v = plr:GetAttribute("Carry")
	if typeof(v) ~= "number" then
		return 1
	end
	return math.max(1, math.floor(v))
end

local function syncBrainrotCarryCountAttr(plr: Player)
	local a = #(activeCarries[plr] or {})
	local p = #(pendingFloats[plr] or {})
	plr:SetAttribute("BrainrotCarryCount", a + p)
end

local function removePendingFloat(player: Player, clone: Model)
	local t = pendingFloats[player]
	if not t then
		return
	end
	for i = #t, 1, -1 do
		if t[i] == clone then
			table.remove(t, i)
			break
		end
	end
	syncBrainrotCarryCountAttr(player)
end

local function getBushRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BushRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("HarvestBrainrot")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "HarvestBrainrot"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function ensureHarvestFunction(): RemoteFunction
	local folder = getBushRemotesFolder()
	local fn = folder:FindFirstChild("HarvestBush")
	if not fn then
		fn = Instance.new("RemoteFunction")
		fn.Name = "HarvestBush"
		fn.Parent = folder
	end
	return fn :: RemoteFunction
end

local inventorySyncRE: RemoteEvent? = nil
local getInventoryRF: RemoteFunction? = nil

local function ensureInventoryRemotes(): (RemoteEvent, RemoteFunction)
	if inventorySyncRE and getInventoryRF then
		return inventorySyncRE, getInventoryRF
	end
	local folder = getBushRemotesFolder()
	local sync = folder:FindFirstChild("BrainrotInventorySync")
	if not sync then
		sync = Instance.new("RemoteEvent")
		sync.Name = "BrainrotInventorySync"
		sync.Parent = folder
	end
	local getFn = folder:FindFirstChild("GetBrainrotInventory")
	if not getFn then
		getFn = Instance.new("RemoteFunction")
		getFn.Name = "GetBrainrotInventory"
		getFn.Parent = folder
	end
	inventorySyncRE = sync :: RemoteEvent
	getInventoryRF = getFn :: RemoteFunction
	return inventorySyncRE, getInventoryRF
end

local playBrainrotSFXRE: RemoteEvent? = nil
local playHarvestDropFXRE: RemoteEvent? = nil
local safeZoneFlashRE: RemoteEvent? = nil

local function ensurePlayBrainrotSFXRemote(): RemoteEvent
	if playBrainrotSFXRE and playBrainrotSFXRE.Parent then
		return playBrainrotSFXRE
	end
	local ev = ReplicatedStorage:FindFirstChild("PlayBrainrotSFX")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "PlayBrainrotSFX"
		ev.Parent = ReplicatedStorage
	end
	playBrainrotSFXRE = ev :: RemoteEvent
	return playBrainrotSFXRE
end

local function ensureSafeZoneFlashRemote(): RemoteEvent
	if safeZoneFlashRE and safeZoneFlashRE.Parent then
		return safeZoneFlashRE
	end
	local ev = ReplicatedStorage:FindFirstChild("SafeZoneFlash")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "SafeZoneFlash"
		ev.Parent = ReplicatedStorage
	end
	safeZoneFlashRE = ev :: RemoteEvent
	return safeZoneFlashRE
end

local function ensurePlayHarvestDropFXRemote(): RemoteEvent
	if playHarvestDropFXRE and playHarvestDropFXRE.Parent then
		return playHarvestDropFXRE
	end
	local ev = ReplicatedStorage:FindFirstChild("PlayHarvestDropFX")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "PlayHarvestDropFX"
		ev.Parent = ReplicatedStorage
	end
	playHarvestDropFXRE = ev :: RemoteEvent
	return playHarvestDropFXRE
end

local function firePlayBrainrotSFX(player: Player, brainrotName: string)
	if typeof(brainrotName) ~= "string" or brainrotName == "" then
		return
	end
	ensurePlayBrainrotSFXRemote():FireClient(player, brainrotName)
end

local function fireHarvestDropFX(player: Player, rarity: string)
	if typeof(rarity) ~= "string" or rarity == "" then
		return
	end
	ensurePlayHarvestDropFXRemote():FireClient(player, rarity)
end

local function fireSafeZoneFlash(player: Player)
	ensureSafeZoneFlashRemote():FireClient(player)
end

local function brainrotNameFromTemplateModel(template: Model): string?
	local variantFolder = template.Parent
	if not variantFolder or not variantFolder:IsA("Folder") then
		return nil
	end
	local nameFolder = variantFolder.Parent
	if not nameFolder or not nameFolder:IsA("Folder") then
		return nil
	end
	return nameFolder.Name
end

local function getCarryBrainrotName(carry: Model): string?
	local attr = carry:GetAttribute("BrainrotName")
	if typeof(attr) == "string" and attr ~= "" then
		return attr
	end
	local srcAttr = carry:GetAttribute("BrainrotSourcePath")
	if typeof(srcAttr) == "string" and srcAttr ~= "" then
		local brainrotName = string.match(srcAttr, "^([^/]+)")
		if brainrotName and brainrotName ~= "" then
			return brainrotName
		end
	end
	if carry.Name ~= "" then
		return carry.Name
	end
	return nil
end

local DEPOSIT_DEBUG = false
local function depositDebug(...: any)
	if not DEPOSIT_DEBUG then
		return
	end
	local parts = { "[BushHarvest][RedWall]" }
	for i = 1, select("#", ...) do
		table.insert(parts, tostring(select(i, ...)))
	end
	warn(table.concat(parts, " "))
end

local function tryPlaySafeZoneSFXForCarry(player: Player, carry: Model)
	if not carry or not carry.Parent then
		return
	end
	if safeZoneSfxPlayedForCarry[carry] then
		return
	end
	local name = getCarryBrainrotName(carry)
	if not name then
		warn("[BushHarvest] Safe zone SFX: could not resolve brainrot name for carry " .. carry:GetFullName())
		return
	end
	safeZoneSfxPlayedForCarry[carry] = true
	firePlayBrainrotSFX(player, name)
	fireSafeZoneFlash(player)
end

local function tryPlaySafeZoneSFXForAllCarries(player: Player)
	local list = activeCarries[player]
	if not list then
		return
	end
	for _, carry in ipairs(list) do
		tryPlaySafeZoneSFXForCarry(player, carry)
	end
end

local function enrichEntryFromCatalog(entry: BrainrotInvEntry)
	local def = Brainrots.getByName(entry.name)
	if not def then
		if typeof(entry.rarity) == "string" then
			entry.rarity = Brainrots.normalizeRarityId(entry.rarity)
		end
		return
	end
	if (entry.baseIncome or 0) <= 0 then
		entry.baseIncome = def.baseIncome
	end
	-- Catalog is source of truth for rarity (stops secret stands sticking as "common").
	entry.rarity = Brainrots.normalizeRarityId(def.rarity)
end

local function copyInventoryList(list: { BrainrotInvEntry }): { BrainrotInvEntry }
	local out: { BrainrotInvEntry } = {}
	for i, e in ipairs(list) do
		local copy: BrainrotInvEntry = {
			name = e.name,
			icon = e.icon,
			sourcePath = e.sourcePath,
			rarity = e.rarity,
			mutation = e.mutation,
			level = e.level,
			baseIncome = e.baseIncome,
		}
		enrichEntryFromCatalog(copy)
		if copy.icon == "" then
			local mutationId = if copy.mutation ~= "" then copy.mutation else "normal"
			copy.icon = IndexService.getIconFor(copy.name, mutationId)
		end
		out[i] = copy
	end
	return out
end

local function tuckedSlotsArrayForPlayer(plr: Player): { number }
	local m = brainrotParkedInExpandedBackpack[plr]
	if not m then
		return {}
	end
	local out: { number } = {}
	for k = 1, 9 do
		if m[k] then
			table.insert(out, k)
		end
	end
	return out
end

local function hotbarSlotsPayloadForPlayer(plr: Player, list: { BrainrotInvEntry }): { [number]: number }
	local m = brainrotHotbarSlots[plr]
	if not m then
		return {}
	end
	local out: { [number]: number } = {}
	local usedSlots: { [number]: boolean } = {}
	for rawIdx, rawSlot in pairs(m) do
		if typeof(rawIdx) == "number" and typeof(rawSlot) == "number" then
			local idx = math.floor(rawIdx)
			local slot = math.floor(rawSlot)
			if idx >= 1 and list[idx] ~= nil and slot >= 1 and slot <= 9 and not usedSlots[slot] then
				out[idx] = slot
				usedSlots[slot] = true
			else
				m[rawIdx] = nil
			end
		else
			m[rawIdx] = nil
		end
	end
	return out
end

local function packInventoryForClient(
	plr: Player,
	list: { BrainrotInvEntry },
	equipSlot: number?
): {
	entries: { BrainrotInvEntry },
	used: number,
	max: number,
	tuckedSlots: { number },
	equipSlot: number?,
}
	local payload: any = {
		entries = copyInventoryList(list),
		used = #list,
		max = MAX_BRAINROT_INVENTORY_CAPACITY,
		tuckedSlots = tuckedSlotsArrayForPlayer(plr),
		hotbarSlots = hotbarSlotsPayloadForPlayer(plr, list),
	}
	if typeof(equipSlot) == "number" then
		payload.equipSlot = math.clamp(math.floor(equipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
	end
	return payload
end

local function notifyIndexDeposited(player: Player, entry: BrainrotInvEntry)
	task.spawn(function()
		local deadline = os.clock() + 30
		while os.clock() < deadline do
			local indexInternal = ServerStorage:FindFirstChild("IndexInternal")
			local indexBF = indexInternal and indexInternal:FindFirstChild("OnBrainrotDeposited")
			if indexBF and indexBF:IsA("BindableFunction") then
				local okInvoke, errInvoke = pcall(function()
					(indexBF :: BindableFunction):Invoke(player, entry)
				end)
				if not okInvoke then
					warn("[BushHarvest] OnBrainrotDeposited invoke failed:", errInvoke)
				end
				return
			end
			task.wait(0.25)
		end
	end)
end

local function pushBrainrotInventory(player: Player, entry: BrainrotInvEntry, skipSync: boolean?): boolean
	local list = brainrotInventories[player]
	if not list then
		list = {}
		brainrotInventories[player] = list
	end
	if #list >= MAX_BRAINROT_INVENTORY_CAPACITY then
		return false
	end
	table.insert(list, entry)
	player:SetAttribute("BrainrotCount", #list)
	if not skipSync then
		local sync = ensureInventoryRemotes()
		sync:FireClient(player, packInventoryForClient(player, list))
	end
	return true
end

local function getIconFromCarryModel(model: Model): string
	for _, d in model:GetDescendants() do
		if d:IsA("ImageLabel") and d.Image ~= "" then
			return d.Image
		end
		if d:IsA("ImageButton") and d.Image ~= "" then
			return d.Image
		end
		if d:IsA("Decal") and d.Texture ~= "" then
			return d.Texture
		end
		if d:IsA("Texture") and d.Texture ~= "" then
			return d.Texture
		end
		if d:IsA("MeshPart") and d.TextureID ~= "" and d.TextureID ~= "rbxassetid://0" then
			return d.TextureID
		end
	end
	return "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

local function findTemplateBySourcePath(root: Folder, path: string): Model?
	local cat, mname = string.match(path, "^([^/]+)/(.+)$")
	if not cat or not mname then
		return nil
	end
	local f = root:FindFirstChild(cat)
	if not f or not f:IsA("Folder") then
		return nil
	end
	local m = f:FindFirstChild(mname)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

local function normalizeBrainrotLookupName(name: string): string
	return string.lower((name:gsub("[%s_%-]", "")))
end

local function findFirstTemplateByModelName(root: Folder, modelName: string): Model?
	if Brainrots.isRetiredBrainrotName(modelName) then
		return nil
	end
	local nameFolder = Brainrots.findBrainrotStorageFolder(root, modelName)
	if nameFolder and nameFolder:IsA("Folder") and not Brainrots.isRetiredBrainrotInstance(nameFolder) then
		local normal = nameFolder:FindFirstChild("Normal")
		if normal and normal:IsA("Model") and not Brainrots.isRetiredBrainrotInstance(normal) then
			return normal :: Model
		end
		for _, c in nameFolder:GetChildren() do
			if c:IsA("Model") and not Brainrots.isRetiredBrainrotInstance(c) then
				return c :: Model
			end
		end
	end
	local want = normalizeBrainrotLookupName(modelName)
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d.Parent and d.Parent:IsA("Folder") then
			if Brainrots.isRetiredBrainrotInstance(d) then
				continue
			end
			if normalizeBrainrotLookupName(d.Name) == want then
				return d
			end
			local parent = d.Parent
			if parent.Parent == root and normalizeBrainrotLookupName(parent.Name) == want then
				return d
			end
			local disp = d:GetAttribute("DisplayName")
			if typeof(disp) == "string" and disp ~= "" and normalizeBrainrotLookupName(disp) == want then
				return d
			end
		end
	end
	return nil
end

local function pickIconFromTemplateModel(model: Model): string
	local named = model:FindFirstChild("Icon", true)
	if named and named:IsA("ImageLabel") and named.Image ~= "" then
		return named.Image
	end
	for _, d in model:GetDescendants() do
		if d:IsA("ImageLabel") and d.Name == "Icon" and d.Image ~= "" then
			return d.Image
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("ImageLabel") and d.Image ~= "" then
			return d.Image
		end
	end
	return ""
end

local function displayNameForTemplateModel(model: Model): string
	local disp = model:GetAttribute("DisplayName")
	if typeof(disp) == "string" and disp ~= "" then
		return disp
	end
	return model.Name
end

local function sourcePathForTemplate(root: Folder, template: Model): string
	local parent = template.Parent
	if parent and parent:IsA("Folder") and parent.Parent == root then
		return parent.Name .. "/" .. template.Name
	end
	return ""
end

-- Match variant Models stored as Brainrots/<Name>/<Variant>; if matched we treat parent folder name as the brainrot name.
local VARIANT_FOLDER_NAMES = { Normal = true, Gold = true, Diamond = true, Lava = true, Galaxy = true, Rainbow = true }

local function enrichEntryFromBrainrotsFolder(root: Folder?, entry: BrainrotInvEntry)
	if not root then
		return
	end
	local template: Model? = nil
	if entry.sourcePath ~= "" then
		template = findTemplateBySourcePath(root, entry.sourcePath)
	end
	if not template then
		template = findFirstTemplateByModelName(root, entry.name)
	end
	if not template then
		if entry.icon == "" then
			local mutationId = if entry.mutation ~= "" then entry.mutation else "normal"
			entry.icon = IndexService.getIconFor(entry.name, mutationId)
		end
		if entry.icon == "" then
			entry.icon = BrainrotsConfig:GetNormalIcon(entry.name)
		end
		return
	end
	if entry.sourcePath == "" then
		entry.sourcePath = sourcePathForTemplate(root, template)
	end
	local icon = pickIconFromTemplateModel(template)
	if icon ~= "" then
		entry.icon = icon
	end
	if entry.icon == "" then
		local mutationId = if entry.mutation ~= "" then entry.mutation else "normal"
		entry.icon = IndexService.getIconFor(entry.name, mutationId)
	end
	if entry.icon == "" then
		entry.icon = BrainrotsConfig:GetNormalIcon(entry.name)
	end
	local parent = template.Parent
	local templateName = template.Name
	local nameAlreadyOk = entry.name ~= "" and not VARIANT_FOLDER_NAMES[entry.name]
	if VARIANT_FOLDER_NAMES[templateName] and parent and parent:IsA("Folder") and parent.Parent == root then
		-- Use parent folder name (e.g. "NoobiniPizzanini") as the brainrot name.
		if not nameAlreadyOk then
			entry.name = parent.Name
		end
	elseif not nameAlreadyOk then
		entry.name = displayNameForTemplateModel(template)
	end
end

local function carryModelToInventoryEntry(carry: Model): BrainrotInvEntry
	local srcAttr = carry:GetAttribute("BrainrotSourcePath")
	local sourcePath = if typeof(srcAttr) == "string" and srcAttr ~= "" then srcAttr else ""
	local rarityAttr = carry:GetAttribute("BrainrotRarity")
	local mutationAttr = carry:GetAttribute("BrainrotMutation")
	local levelAttr = carry:GetAttribute("BrainrotLevel")
	local baseIncomeAttr = carry:GetAttribute("BrainrotBaseIncome")
	local displayName = getCarryBrainrotName(carry) or carry.Name
	local entry: BrainrotInvEntry = {
		name = displayName,
		icon = getIconFromCarryModel(carry),
		sourcePath = sourcePath,
		rarity = if typeof(rarityAttr) == "string" then rarityAttr else "common",
		mutation = if typeof(mutationAttr) == "string" then mutationAttr else "normal",
		level = if typeof(levelAttr) == "number" then math.max(1, math.floor(levelAttr)) else 1,
		baseIncome = if typeof(baseIncomeAttr) == "number" then baseIncomeAttr else 0,
	}
	local brainrotsFolder = Brainrots.getBrainrotsFolder()
	if brainrotsFolder and brainrotsFolder:IsA("Folder") then
		enrichEntryFromBrainrotsFolder(brainrotsFolder :: Folder, entry)
	end
	enrichEntryFromCatalog(entry)
	return entry
end

-- Returns the new inventory list index on success (used to auto-equip the brainrot just deposited).
local function redeemSingleCarryModel(player: Player, carry: Model): number?
	if not carry or not carry.Parent then
		depositDebug("redeem abort: carry missing parent", player.Name)
		return nil
	end
	if carry:GetAttribute("OwnerUserId") ~= player.UserId then
		depositDebug("redeem abort: owner mismatch", player.Name, carry:GetFullName())
		return nil
	end

	local brainrotName = getCarryBrainrotName(carry) or carry.Name
	depositDebug("redeem add inventory", player.Name, brainrotName)

	player:SetAttribute("LastCollectedBrainrot", brainrotName)
	local entry = carryModelToInventoryEntry(carry)
	if not pushBrainrotInventory(player, entry, true) then
		depositDebug("redeem FAIL: inventory full or push failed", player.Name, brainrotName)
		return nil
	end

	local list = brainrotInventories[player]
	local newSlot = if list then #list else nil
	depositDebug("redeem inventory OK slot", player.Name, tostring(newSlot), brainrotName)

	notifyIndexDeposited(player, entry)

	safeZoneSfxPlayedForCarry[carry] = nil
	carry:Destroy()
	depositDebug("redeem destroyed carry model", player.Name, brainrotName)
	return newSlot
end

-- Gaps between stacked carry centers on the head.
local STACK_GAP = 0.012

local function stackHalfHeight(model: Model): number
	if not model.Parent then
		return 0.5
	end
	local _, bbSize = model:GetBoundingBox()
	local pp = model.PrimaryPart
	if pp then
		local tight = pp.Size.Y * 1.0 + 0.04
		return math.clamp(math.min(bbSize.Y, tight), 0.45, 3.8) * 0.5
	end
	return math.clamp(bbSize.Y, 0.45, 3.8) * 0.5
end

local function stackLiftFromExistingCarries(plr: Player): number
	local list = activeCarries[plr]
	if not list or #list == 0 then
		return 0
	end
	local lift = 0
	for _, m in ipairs(list) do
		if m.Parent then
			lift += stackHalfHeight(m)
		end
	end
	if #list >= 1 then
		lift += STACK_GAP * #list
	end
	return lift
end

local function getCarryAttachmentWorldCFrame(
	character: Model,
	mainPart: BasePart,
	stackLiftY: number
): (BasePart?, CFrame?)
	return BrainrotCarryVisual.getHeadCarryWorldCFrame(character, mainPart, stackLiftY)
end

local function modelHasSpawnableGeometry(model: Model): boolean
	return model:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function collectTemplateModels(root: Folder): { Model }
	local list: { Model } = {}
	for _, desc in root:GetDescendants() do
		if not desc:IsA("Model") then
			continue
		end
		if Brainrots.isRetiredBrainrotInstance(desc) then
			continue
		end
		local templateName = brainrotNameFromTemplateModel(desc)
		if templateName and not Brainrots.isPlayableBrainrotName(templateName) then
			continue
		end
		local parent = desc.Parent
		if not parent or not parent:IsA("Folder") then
			continue
		end
		if not modelHasSpawnableGeometry(desc) then
			continue
		end
		table.insert(list, desc)
	end
	return list
end

-- ServerStorage.Brainrots/<BrainrotName>/<MutationVariant> (e.g. Brainrots/67/Normal).
-- Fallback chain: requested mutation → Normal → first available child Model.
local function findBrainrotModelByNameAndMutation(root: Folder, brainrotName: string, mutationId: string): Model?
	if Brainrots.isRetiredBrainrotName(brainrotName) or not Brainrots.isPlayableBrainrotName(brainrotName) then
		return nil
	end
	local nameFolder = Brainrots.findBrainrotStorageFolder(root, brainrotName)
	if not nameFolder or Brainrots.isRetiredBrainrotInstance(nameFolder) then
		return nil
	end
	local variantFolderName = (Brainrots :: any).MUTATION_TEMPLATE_FOLDER[mutationId]
	if typeof(variantFolderName) == "string" then
		local exact = nameFolder:FindFirstChild(variantFolderName)
		if
			exact
			and exact:IsA("Model")
			and not Brainrots.isRetiredBrainrotInstance(exact)
			and modelHasSpawnableGeometry(exact :: Model)
		then
			return exact :: Model
		end
	end
	local fallback = nameFolder:FindFirstChild("Normal")
	if
		fallback
		and fallback:IsA("Model")
		and not Brainrots.isRetiredBrainrotInstance(fallback)
		and modelHasSpawnableGeometry(fallback :: Model)
	then
		return fallback :: Model
	end
	for _, c in ipairs(nameFolder:GetChildren()) do
		if c:IsA("Model") and not Brainrots.isRetiredBrainrotInstance(c) and modelHasSpawnableGeometry(c :: Model) then
			return c :: Model
		end
	end
	return nil
end

local function brainrotHasTemplate(root: Folder, brainrotName: string): boolean
	local nameFolder = Brainrots.findBrainrotStorageFolder(root, brainrotName)
	if not nameFolder then
		return false
	end
	for _, c in ipairs(nameFolder:GetChildren()) do
		if c:IsA("Model") and modelHasSpawnableGeometry(c :: Model) then
			return true
		end
	end
	return false
end

-- Plot resolution: prefer a `Plot` attribute on the bush root model / a Land<N> ancestor;
-- otherwise pick the nearest Land<N> in workspace.Map.Lands (new layout) or
-- workspace.Map directly (legacy) by spatial proximity.
local PLOT_NAME_PATTERN = "^Land(%d+)$"

local function collectLandCandidates(): { Instance }
	local map = workspace:FindFirstChild("Map")
	if not map then
		return {}
	end
	local result: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	local function consider(child: Instance)
		if seen[child] then
			return
		end
		if tonumber((string.match(child.Name, PLOT_NAME_PATTERN))) then
			seen[child] = true
			table.insert(result, child)
		end
	end

	local lands = map:FindFirstChild("Lands")
	if lands then
		for _, c in ipairs(lands:GetChildren()) do
			consider(c)
		end
	end
	for _, c in ipairs(map:GetChildren()) do
		consider(c)
	end
	return result
end

local function resolvePlotForBushPos(bushPos: Vector3): number
	local best = 1
	local bestDist = math.huge
	for _, child in ipairs(collectLandCandidates()) do
		local n = tonumber((string.match(child.Name, PLOT_NAME_PATTERN))) or 1
		local plotAttr = child:GetAttribute("Plot")
		if typeof(plotAttr) == "number" then
			n = math.floor(plotAttr)
		end
		local centerPos: Vector3? = nil
		if child:IsA("Model") then
			centerPos = (child :: Model):GetBoundingBox().Position
		elseif child:IsA("BasePart") then
			centerPos = (child :: BasePart).Position
		elseif child:IsA("Folder") then
			local sum = Vector3.zero
			local count = 0
			for _, d in ipairs((child :: Folder):GetDescendants()) do
				if d:IsA("BasePart") then
					sum += d.Position
					count += 1
					if count >= 60 then
						break
					end
				end
			end
			if count > 0 then
				centerPos = sum / count
			end
		end
		if centerPos then
			local dist = (centerPos - bushPos).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = math.clamp(n, 1, Brainrots.MAX_PLOT)
			end
		else
			-- No spatial info; remember it as a candidate but keep looking.
			if bestDist == math.huge then
				best = math.clamp(n, 1, Brainrots.MAX_PLOT)
			end
		end
	end
	return best
end

type LuckHitbox = { part: BasePart, displayLuck: number }
local luckHitboxes: { LuckHitbox } = {}
local registeredLuckParts: { [BasePart]: boolean } = {}

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

-- RedWall / RedPart deposit zones (CollectionService tag BrainrotDeposit).
local depositPartSet: { [BasePart]: boolean } = {}
local depositParts: { BasePart } = {}
local depositTouchHooked: { [BasePart]: boolean } = {}

local function registerDepositPart(part: BasePart)
	if depositPartSet[part] then
		return
	end
	depositPartSet[part] = true
	table.insert(depositParts, part)
end

local function unregisterDepositPart(part: BasePart)
	if not depositPartSet[part] then
		return
	end
	depositPartSet[part] = nil
	for i = #depositParts, 1, -1 do
		if depositParts[i] == part then
			table.remove(depositParts, i)
			break
		end
	end
end

local function isInsideAnyDeposit(worldPoint: Vector3): boolean
	for _, part in ipairs(depositParts) do
		if part.Parent and isPointInsidePartOBB(worldPoint, part) then
			return true
		end
	end
	return false
end

local function isPlayerInsideDeposit(player: Player): boolean
	local char = player.Character
	if not char then
		return false
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return isInsideAnyDeposit((hrp :: BasePart).Position)
end

local equipBrainrotSlotForPlayer: (Player, number, boolean?) -> number?
local findLowestFreeHotbarSlot: (plr: Player, list: { BrainrotInvEntry }, map: { [number]: boolean }) -> number?
local assignEntryToLowestFreeHotbarSlot: (plr: Player, list: { BrainrotInvEntry }, map: { [number]: boolean }, srcIdx: number) -> number?

local function playerInInventoryZone(player: Player): boolean
	return SafezoneUtil.isCharacterInInventoryZone(player.Character)
end

local function notifyClientInventorySync(player: Player, autoEquipSlot: number?, forceEquip: boolean?)
	local invList = brainrotInventories[player]
	local slot: number? = nil
	if typeof(autoEquipSlot) == "number" then
		slot = math.clamp(math.floor(autoEquipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
	end
	-- Always sync inventory after RedWall delivery; auto-equip is never gated on Reddie toolbar access.
	if slot and invList and invList[slot] then
		if forceEquip then
			local equippedIdx = equipBrainrotSlotForPlayer(player, slot :: number, true)
			if equippedIdx then
				slot = equippedIdx
			end
			depositDebug("auto-equip", player.Name, "slot", slot, if equippedIdx then "OK" else "FAIL")
		else
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local inSpawnSafe = SafezoneUtil.isCharacterInSafezone(char)
				or (hrp and hrp:IsA("BasePart") and SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position))
				or playerInInventoryZone(player)
			if inSpawnSafe then
				local equippedIdx = equipBrainrotSlotForPlayer(player, slot :: number, true)
				if equippedIdx then
					slot = equippedIdx
				end
			end
		end
	end
	local sync = ensureInventoryRemotes()
	sync:FireClient(player, packInventoryForClient(player, invList or {}, slot))
	depositDebug("client sync", player.Name, "entries", invList and #invList or 0, "equipSlot", slot)
end

local function registerLuckHitbox(part: BasePart)
	if registeredLuckParts[part] then
		return
	end
	local displayLuck = PlotLuck.parseHitboxDisplayLuck(part.Name)
	if not displayLuck then
		return
	end
	registeredLuckParts[part] = true
	table.insert(luckHitboxes, { part = part, displayLuck = displayLuck })
	part.Destroying:Connect(function()
		if not registeredLuckParts[part] then
			return
		end
		registeredLuckParts[part] = nil
		for i = #luckHitboxes, 1, -1 do
			if luckHitboxes[i].part == part then
				table.remove(luckHitboxes, i)
				break
			end
		end
	end)
end

local function collectLuckHitboxes(root: Instance)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("BasePart") then
			registerLuckHitbox(desc)
		end
	end
end

local luckDiscoveryHooked = false

local function hookLandsForLuckServer(lands: Instance)
	collectLuckHitboxes(lands)
	lands.DescendantAdded:Connect(function(ch)
		if ch:IsA("BasePart") then
			registerLuckHitbox(ch)
		end
	end)
	lands.ChildAdded:Connect(function()
		task.defer(function()
			collectLuckHitboxes(lands)
		end)
	end)
end

local function refreshLuckHitboxes()
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end

	local function scanAll()
		local lands = map:FindFirstChild("Lands")
		if lands then
			collectLuckHitboxes(lands)
		end
		local spawnBases = map:FindFirstChild("Spawn And Bases")
		if spawnBases then
			collectLuckHitboxes(spawnBases)
		end
	end

	scanAll()

	if not luckDiscoveryHooked then
		luckDiscoveryHooked = true
		local lands = map:FindFirstChild("Lands")
		if lands then
			hookLandsForLuckServer(lands)
		end
		map.ChildAdded:Connect(function(child)
			task.defer(function()
				if child.Name == "Lands" then
					hookLandsForLuckServer(child)
				end
				scanAll()
			end)
		end)
	end
end

local function resolveDisplayLuckForPos(worldPos: Vector3): number
	local best = 1
	for _, entry in ipairs(luckHitboxes) do
		if entry.part.Parent and isPointInsidePartOBB(worldPos, entry.part) and entry.displayLuck > best then
			best = entry.displayLuck
		end
	end
	return best
end

local function resolveHarvestPlot(worldPos: Vector3, luckMultiplier: number?): (number, number, number)
	local basePlot = resolvePlotForBushPos(worldPos)
	local displayLuck = resolveDisplayLuckForPos(worldPos)
	-- Gamepass / server-wide luck scales the effective plot luck (VIP, Super/Mega, Server Luck).
	local mult = if typeof(luckMultiplier) == "number" and luckMultiplier > 1 then luckMultiplier else 1
	local effectiveDisplayLuck = math.max(displayLuck, displayLuck * mult)
	local plot = PlotLuck.effectivePlot(basePlot, effectiveDisplayLuck, Brainrots.MAX_PLOT)
	return plot, basePlot, displayLuck
end

local function bushTopWorldY(bush: Model?, fallbackY: number): number
	if not bush or not bush.Parent then
		return fallbackY
	end
	local maxY = -math.huge
	local found = false
	for _, desc in bush:GetDescendants() do
		if
			desc:IsA("BasePart")
			and desc.Name ~= BUSH_EMPTY_MESSAGE_ANCHOR_NAME
			and desc.Name ~= "_BushPromptAnchor"
		then
			found = true
			local cf = desc.CFrame
			local h = desc.Size * 0.5
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						maxY = math.max(maxY, wp.Y)
					end
				end
			end
		end
	end
	if found then
		return maxY
	end
	return fallbackY
end

local function findNearestBushModel(worldPos: Vector3, maxRange: number): Model?
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local best: Model? = nil
	local bestDist = maxRange
	for _, desc in map:GetDescendants() do
		if desc:IsA("Folder") then
			local isBushFolder = false
			for _, name in BUSH_FOLDER_NAMES do
				if desc.Name == name then
					isBushFolder = true
					break
				end
			end
			if isBushFolder then
				for _, child in desc:GetChildren() do
					if child:IsA("Model") then
						local bush = child :: Model
						local ok, cf = pcall(function()
							return bush:GetBoundingBox()
						end)
						if ok and typeof(cf) == "CFrame" then
							local dist = (cf.Position - worldPos).Magnitude
							if dist < bestDist then
								bestDist = dist
								best = bush
							end
						end
					end
				end
			end
		end
	end
	return best
end

local function spawnBrainrotAboveBush(clone: Model, worldPosition: Vector3, harvestLevel: number, faceToward: Vector3?): (CFrame, number)
	local bush = findNearestBushModel(worldPosition, MAX_HARVEST_RANGE + RANGE_SLACK)
	local surfaceTopY = bushTopWorldY(bush, worldPosition.Y)
	BrainrotCarryVisual.applyScaleForLevel(clone, harvestLevel)

	local yaw: number
	if faceToward then
		local flat = Vector3.new(faceToward.X - worldPosition.X, 0, faceToward.Z - worldPosition.Z)
		if flat.Magnitude < 0.05 then
			yaw = 0
		else
			-- Face the player (+Z toward them via lookAt yaw — no π flip).
			local look = CFrame.lookAt(Vector3.zero, flat.Unit)
			local _, lookYaw, _ = look:ToEulerAnglesYXZ()
			yaw = lookYaw
		end
	else
		yaw = math.random() * math.pi * 2
	end

	local spawnCf =
		BrainrotCarryVisual.spawnCFrameAboveSurface(clone, worldPosition.X, surfaceTopY, worldPosition.Z, nil, yaw)
	return spawnCf, yaw
end

local function placeModelAtWorld(model: Model, worldCFrame: CFrame)
	if model.PrimaryPart then
		model:SetPrimaryPartCFrame(worldCFrame)
	else
		model:PivotTo(worldCFrame)
	end
end

local function getMainPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local p = model:FindFirstChildWhichIsA("BasePart", true)
	if p and not model.PrimaryPart then
		model.PrimaryPart = p
	end
	return p
end

local function setAllPartsPhysics(model: Model, anchored: boolean, massless: boolean)
	BrainrotCarryVisual.applyNonColliding(model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = anchored
			d.Massless = massless
		end
	end
end

local function popSpawnEffect(model: Model, onDone: (() -> ())?)
	local pivot = model:GetPivot()
	local _, baseYaw, _ = pivot:ToEulerAnglesYXZ()
	local duration = POP_DURATION
	local t0 = os.clock()

	local baseScales: { [BasePart]: Vector3 } = {}
	local baseTrans: { [BasePart]: number } = {}
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			baseScales[desc] = desc.Size
			baseTrans[desc] = desc.Transparency
			desc.Size = desc.Size * 0.04
			desc.Transparency = math.min(0.98, math.max(desc.Transparency, 0.9))
		end
	end

	local function easeOutCubic(x: number): number
		return 1 - (1 - x) ^ 3
	end

	local function easeOutQuint(x: number): number
		return 1 - (1 - x) ^ 5
	end

	local function easeOutBack(x: number): number
		local c1 = 1.35
		local c3 = c1 + 1
		return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
	end

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			conn:Disconnect()
			return
		end
		local t = math.clamp((os.clock() - t0) / duration, 0, 1)
		if t >= 1 then
			conn:Disconnect()
			for part, size in baseScales do
				if part.Parent then
					part.Size = size
					part.Transparency = baseTrans[part] or 0
				end
			end
			-- End on float-ready pose (continuous handoff, no hard snap).
			model:PivotTo(CFrame.new(pivot.Position + Vector3.new(0, 0.22, 0)) * CFrame.Angles(0, baseYaw, 0))
			if onDone then
				onDone()
			end
			return
		end

		-- Modern Pokémon-style release: seed → expand → rise → settle.
		local formT = easeOutBack(math.clamp(t / 0.42, 0, 1))
		local scaleMul
		if t < 0.42 then
			scaleMul = math.clamp(0.04 + formT * 1.02, 0.04, 1.06)
		else
			local settle = easeOutCubic(math.clamp((t - 0.42) / 0.2, 0, 1))
			scaleMul = 1.06 - settle * 0.06
		end

		local fadeT = easeOutQuint(math.clamp(t / 0.32, 0, 1))
		local rise = easeOutCubic(math.clamp(t / 0.55, 0, 1)) * 1.15
		local settleDown = easeOutCubic(math.clamp((t - 0.55) / 0.45, 0, 1)) * 0.93
		local lift = math.max(0.18, rise - settleDown)

		-- Start facing the player, then spin during the pop, settle facing them again.
		local spinAmt = math.sin(easeOutCubic(t) * math.pi) * math.pi * 0.85
		local yaw = baseYaw + spinAmt
		local tip = math.sin(easeOutCubic(t) * math.pi) * 0.1 * (1 - t)

		for part, size in baseScales do
			if part.Parent then
				part.Size = size * scaleMul
				local baseT = baseTrans[part] or 0
				part.Transparency = baseT + (1 - fadeT) * (0.98 - baseT)
			end
		end

		model:PivotTo(
			CFrame.new(pivot.Position + Vector3.new(0, lift, 0))
				* CFrame.Angles(tip * 0.35, yaw, -tip * 0.2)
		)
	end)
end

local function clearPlayerHarvestState(player: Player)
	local floatingClones = table.clone(pendingFloats[player] or {})
	require(Modules:WaitForChild("BushHarvestFloating")).cleanupAllForPlayer({
		pendingFloats = pendingFloats,
		floatConnByClone = floatConnByClone,
		removePendingFloat = removePendingFloat,
		syncBrainrotCarryCountAttr = syncBrainrotCarryCountAttr,
		attachCarriedBrainrot = attachCarriedBrainrot,
		getMainPart = getMainPart,
		setAllPartsPhysics = setAllPartsPhysics,
		releaseBushAfterFloatingTimeout = releaseBushAfterFloatingTimeout,
	}, player, floatingClones)
	for _, m in activeCarries[player] or {} do
		safeZoneSfxPlayedForCarry[m] = nil
		if m.Parent then
			m:Destroy()
		end
	end
	activeCarries[player] = nil
	syncBrainrotCarryCountAttr(player)
end

local function applyCarryScaleForModel(model: Model)
	local lvAttr = model:GetAttribute("BrainrotLevel")
	local lv = if typeof(lvAttr) == "number" then lvAttr else 1
	BrainrotCarryVisual.applyScaleForLevel(model, lv)
end

attachCarriedBrainrot = function(player: Player, clone: Model)
	local char = player.Character
	if not char then
		return
	end
	local main = getMainPart(clone)
	if not main then
		return
	end

	-- First accepted bush during tutorial → later bushes use normal level rolls.
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		player:SetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR, true)
	end

	-- Already inside RedWall deposit: skip head carry (Touched won't fire if they never left the box).
	if isPlayerInsideDeposit(player) then
		tryPlaySafeZoneSFXForCarry(player, clone)
		local newSlot = redeemSingleCarryModel(player, clone)
		if newSlot then
			local map = brainrotParkedInExpandedBackpack[player]
			if not map then
				map = {}
				brainrotParkedInExpandedBackpack[player] = map
			end
			local invList = brainrotInventories[player]
			-- Place on hotbar, but auto-equip must use the inventory index (newSlot),
			-- not the visual hotbar cell — those no longer mirror 1:1.
			if invList then
				assignEntryToLowestFreeHotbarSlot(player, invList, map, newSlot)
			end
			local carryList = activeCarries[player]
			if carryList then
				for i = #carryList, 1, -1 do
					if carryList[i] == clone then
						table.remove(carryList, i)
					end
				end
			end
			syncBrainrotCarryCountAttr(player)
			notifyClientInventorySync(player, newSlot, true)
		end
		return
	end

	applyCarryScaleForModel(clone)

	local stackLift = stackLiftFromExistingCarries(player)
	local anchorPart, desiredWorld = getCarryAttachmentWorldCFrame(char, main, stackLift)
	if not anchorPart or not desiredWorld then
		return
	end

	setAllPartsPhysics(clone, false, true)

	for _, d in ipairs(main:GetChildren()) do
		if d.Name == "BrainrotCarryMotor" or d.Name == "BrainrotCarryWeld" then
			d:Destroy()
		end
	end

	clone.Parent = char
	clone:PivotTo(desiredWorld)

	local weld = Instance.new("WeldConstraint")
	weld.Name = "BrainrotCarryWeld"
	weld.Part0 = anchorPart
	weld.Part1 = main
	weld.Parent = main

	BrainrotHeader.remove(clone)

	clone:SetAttribute("BrainrotCarryPhase", "Carried")
	local list = activeCarries[player]
	if not list then
		list = {}
		activeCarries[player] = list
	end
	table.insert(list, clone)
	syncBrainrotCarryCountAttr(player)
end

local function startFloatingClaimOffer(player: Player, char: Model, clone: Model, anchorPos: Vector3, baseYaw: number)
	require(Modules:WaitForChild("BushHarvestFloating")).startOffer({
		pendingFloats = pendingFloats,
		floatConnByClone = floatConnByClone,
		removePendingFloat = removePendingFloat,
		syncBrainrotCarryCountAttr = syncBrainrotCarryCountAttr,
		attachCarriedBrainrot = attachCarriedBrainrot,
		getMainPart = getMainPart,
		setAllPartsPhysics = setAllPartsPhysics,
		releaseBushAfterFloatingTimeout = releaseBushAfterFloatingTimeout,
	}, player, char, clone, anchorPos, baseYaw)
end

local function isLootableBush(inst: Instance): boolean
	if not inst:IsA("Model") and not inst:IsA("BasePart") then
		return false
	end
	if BushRootUtil.isGeneratedPromptHelper and BushRootUtil.isGeneratedPromptHelper(inst) then
		return false
	end
	return BushRootUtil.isBushContainer(inst.Parent)
end

local function rollBushHasBrainrot(): boolean
	return math.random() < BUSH_BRAINROT_CHANCE
end

local function isValidBushRef(bushRef: Instance?): boolean
	if not bushRef or not bushRef.Parent then
		return false
	end
	if not bushRef:IsA("Model") and not bushRef:IsA("BasePart") then
		return false
	end
	if BushRootUtil.isGeneratedPromptHelper and BushRootUtil.isGeneratedPromptHelper(bushRef) then
		return false
	end
	if not BushRootUtil.isDirectBushRoot(bushRef) then
		return false
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return false
	end
	return bushRef:IsDescendantOf(map)
end

local function clearHiddenBrainrotLoot(bush: Instance)
	bush:SetAttribute(BUSH_HIDDEN_RARITY_ATTR, nil)
	bush:SetAttribute(BUSH_HIDDEN_NAME_ATTR, nil)
	bush:SetAttribute(BUSH_HIDDEN_MUTATION_ATTR, nil)
	bush:SetAttribute(BUSH_HIDDEN_LEVEL_ATTR, nil)
	bush:SetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR, nil)
end

local function rollHiddenBrainrotLoot(bush: Instance)
	clearHiddenBrainrotLoot(bush)
	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots then
		return
	end
	local pos = if bush:IsA("BasePart") then bush.Position else (bush :: Model):GetPivot().Position
	local plot = resolveHarvestPlot(pos, LuckBoost.serverLuckMultiplier())
	local function brainrotIsAvailable(def)
		return Brainrots.isPlayableBrainrotName(def.name) and brainrotHasTemplate(brainrots :: Folder, def.name)
	end
	local pick, mutationId = Brainrots.pickRandomBrainrotForPlot(plot, brainrotIsAvailable)
	if not pick then
		return
	end
	bush:SetAttribute(BUSH_HIDDEN_RARITY_ATTR, pick.rarity)
	bush:SetAttribute(BUSH_HIDDEN_NAME_ATTR, pick.name)
	bush:SetAttribute(BUSH_HIDDEN_MUTATION_ATTR, mutationId)
	bush:SetAttribute(BUSH_HIDDEN_LEVEL_ATTR, Brainrots.rollBushHarvestLevel())
	bush:SetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR, pick.baseIncome)
end

--[[
	RollBushState — fresh 50/50 dice. Only call when a bush becomes searchable (init or post-cooldown).
]]
local function RollBushState(bush: Instance): boolean
	if not isValidBushRef(bush) then
		return false
	end
	if bush:GetAttribute("GlobalRaritySpawn") == true then
		return bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true
	end
	local hasBrainrot = rollBushHasBrainrot()
	bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, hasBrainrot)
	bush:SetAttribute(BUSH_ON_COOLDOWN_ATTR, false)
	bush:SetAttribute(BUSH_LOOT_PHASE_ATTR, BUSH_LOOT_PHASE_READY)
	bush:SetAttribute(BUSH_COOLDOWN_ENDS_ATTR, nil)
	if hasBrainrot then
		rollHiddenBrainrotLoot(bush)
	else
		clearHiddenBrainrotLoot(bush)
	end
	return hasBrainrot
end

local function beginBushSearchCooldown(bush: Instance, cooldownSec: number): number
	local endsAt = workspace:GetServerTimeNow() + cooldownSec
	bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, false)
	clearHiddenBrainrotLoot(bush)
	bush:SetAttribute(BUSH_ON_COOLDOWN_ATTR, true)
	bush:SetAttribute(BUSH_LOOT_PHASE_ATTR, BUSH_LOOT_PHASE_COOLDOWN)
	bush:SetAttribute(BUSH_COOLDOWN_ENDS_ATTR, endsAt)
	return endsAt
end

local function scheduleRollAfterCooldown(bush: Instance, cooldownSec: number)
	local token = (bushLootRespawnToken[bush] or 0) + 1
	bushLootRespawnToken[bush] = token
	task.delay(cooldownSec, function()
		if token ~= bushLootRespawnToken[bush] then
			return
		end
		if not bush.Parent or not isValidBushRef(bush) then
			return
		end
		RollBushState(bush)
	end)
end

local function bushHarvestKeyForInstance(bush: Instance): string
	local pos = if bush:IsA("BasePart") then bush.Position else bush:GetPivot().Position
	return string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z)
end

local function findBushByHarvestKey(key: string): Instance?
	if key == "" then
		return nil
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	for _, desc in map:GetDescendants() do
		if isLootableBush(desc) and bushHarvestKeyForInstance(desc) == key then
			return desc
		end
	end
	return nil
end

releaseBushAfterFloatingTimeout = function(bushKey: string)
	local bush = findBushByHarvestKey(bushKey)
	if not bush or not isValidBushRef(bush) then
		return
	end
	bushLootRespawnToken[bush] = (bushLootRespawnToken[bush] or 0) + 1
	bush:SetAttribute(BUSH_ON_COOLDOWN_ATTR, false)
	bush:SetAttribute(BUSH_COOLDOWN_ENDS_ATTR, nil)
	RollBushState(bush)
end

local function initBushLootIfNeeded(bush: Instance)
	if not isValidBushRef(bush) then
		return
	end
	local phase = bush:GetAttribute(BUSH_LOOT_PHASE_ATTR)
	if phase == BUSH_LOOT_PHASE_READY or phase == BUSH_LOOT_PHASE_COOLDOWN then
		return
	end
	RollBushState(bush)
end

local function resumeBushCooldownIfNeeded(bush: Instance)
	if not isValidBushRef(bush) then
		return
	end
	if bush:GetAttribute(BUSH_LOOT_PHASE_ATTR) ~= BUSH_LOOT_PHASE_COOLDOWN then
		return
	end
	local endsAt = bush:GetAttribute(BUSH_COOLDOWN_ENDS_ATTR)
	if typeof(endsAt) ~= "number" then
		RollBushState(bush)
		return
	end
	local remaining = endsAt - workspace:GetServerTimeNow()
	if remaining <= 0 then
		RollBushState(bush)
		return
	end
	scheduleRollAfterCooldown(bush, remaining)
end

local function registerBushLootState(bush: Instance)
	initBushLootIfNeeded(bush)
	resumeBushCooldownIfNeeded(bush)
end

local function assignLootUnder(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("Folder") and BushRootUtil.isBushFolderName(desc.Name) then
			for _, child in desc:GetChildren() do
				if isLootableBush(child) then
					registerBushLootState(child)
				end
			end
		end
	end
end

local function bushSearchPosition(bushRef: Instance?, worldPosition: Vector3): Vector3
	if bushRef and bushRef.Parent then
		if bushRef:IsA("BasePart") then
			return bushRef.Position
		end
		if bushRef:IsA("Model") then
			return (bushRef :: Model):GetPivot().Position
		end
	end
	return worldPosition
end

-- Scoped block: empty-bush billboard/flash helpers (keeps module locals under Luau's 200-register limit).
local FlashBushColor: (Instance, Color3, number?) -> ()
local clearEmptyBushMessageState: (Instance) -> ()
local showEmptyBushMessage: (Instance) -> ()

do
	local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
	local EMPTY_BUSH_MESSAGE = "No brainrots hiding!"
	local EMPTY_BUSH_MESSAGE_LIFETIME = 4
	local EMPTY_BUSH_FADE_DURATION = 1
	local EMPTY_BUSH_HOLD_DURATION = EMPTY_BUSH_MESSAGE_LIFETIME - EMPTY_BUSH_FADE_DURATION
	local EMPTY_BUSH_BILLBOARD_NAME = "BushEmptyMessage"
	local BUSH_PROMPT_LIFT_SCALE = 0.66
	local BUSH_MESSAGE_FLOAT_ABOVE_PROMPT = 2.75
	local BUSH_FLASH_RED = Color3.fromRGB(225, 48, 48)
	local BUSH_FLASH_RESTORE_DURATION = 1.0
	local BUSH_ERROR_SHAKE_DURATION = 0.5
	local emptyBushMessageHideToken: { [Instance]: number } = {}
	local bushFlashToken: { [Instance]: number } = {}
	local bushFlashTweens: { [Instance]: { Tween } } = {}
	local bushFlashOriginalColors: { [Instance]: { [BasePart]: Color3 } } = {}
	local bushErrorShakeToken: { [Instance]: number } = {}

	local function findBushPromptCenterWorld(bush: Instance): Vector3?
		for _, desc in bush:GetDescendants() do
			if desc:IsA("Attachment") and desc.Name == "_BushPromptCenter" then
				return desc.WorldPosition
			end
		end
		return nil
	end

	local function bushAlertFloatWorldPosition(bush: Instance): Vector3?
		local promptCenter = findBushPromptCenterWorld(bush)
		if promptCenter then
			local topY = bushWorldTopY(bush, promptCenter.Y)
			return Vector3.new(
				promptCenter.X,
				math.max(promptCenter.Y + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, topY + 3.5),
				promptCenter.Z
			)
		end

		if bush:IsA("Model") then
			local minV, maxV = BrainrotCarryVisual.getWorldAabb(bush :: Model)
			if minV and maxV then
				local center = (minV + maxV) * 0.5
				local height = math.max(0.5, maxV.Y - minV.Y)
				local promptY = center.Y + height * BUSH_PROMPT_LIFT_SCALE
				return Vector3.new(
					center.X,
					math.max(promptY + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, maxV.Y + 3.5),
					center.Z
				)
			end
		elseif bush:IsA("BasePart") then
			local part = bush :: BasePart
			local topY = part.Position.Y + part.Size.Y * 0.5
			local promptY = part.Position.Y + part.Size.Y * BUSH_PROMPT_LIFT_SCALE + 1
			return Vector3.new(
				part.Position.X,
				math.max(promptY + BUSH_MESSAGE_FLOAT_ABOVE_PROMPT, topY + 3.5),
				part.Position.Z
			)
		end

		return nil
	end

	local function ensureEmptyBushBillboardAnchor(bush: Instance): BasePart?
		local worldPos = bushAlertFloatWorldPosition(bush)
		if not worldPos then
			if bush:IsA("BasePart") then
				return bush
			end
			if bush:IsA("Model") then
				local model = bush :: Model
				if model.PrimaryPart then
					return model.PrimaryPart
				end
				return model:FindFirstChildWhichIsA("BasePart", true)
			end
			return nil
		end

		local existing = bush:FindFirstChild(BUSH_EMPTY_MESSAGE_ANCHOR_NAME)
		if existing and existing:IsA("BasePart") then
			existing.CFrame = CFrame.new(worldPos)
			return existing
		end

		local anchor = Instance.new("Part")
		anchor.Name = BUSH_EMPTY_MESSAGE_ANCHOR_NAME
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.15, 0.15, 0.15)
		anchor.CFrame = CFrame.new(worldPos)
		anchor.Parent = bush
		return anchor
	end

	local function isVisibleBushPart(part: BasePart): boolean
		if part.Name == BUSH_EMPTY_MESSAGE_ANCHOR_NAME or part.Name == "_BushPromptAnchor" then
			return false
		end
		if part.Transparency >= 1 then
			return false
		end
		local lowerName = string.lower(part.Name)
		if string.find(lowerName, "hitbox", 1, true) or string.find(lowerName, "collision", 1, true) then
			return false
		end
		return true
	end

	local function collectVisibleBushParts(bush: Instance): { BasePart }
		local parts: { BasePart } = {}
		if bush:IsA("BasePart") and isVisibleBushPart(bush) then
			table.insert(parts, bush)
		end
		for _, desc in bush:GetDescendants() do
			if desc:IsA("BasePart") and isVisibleBushPart(desc) then
				table.insert(parts, desc)
			end
		end
		return parts
	end

	local function cancelBushFlashTweens(bush: Instance)
		local tweens = bushFlashTweens[bush]
		if not tweens then
			return
		end
		for _, tween in tweens do
			tween:Cancel()
		end
		bushFlashTweens[bush] = nil
	end

	local function captureBushTransform(bush: Instance): CFrame?
		if bush:IsA("Model") then
			return bush:GetPivot()
		end
		if bush:IsA("BasePart") then
			return bush.CFrame
		end
		return nil
	end

	local function applyBushTransform(bush: Instance, cf: CFrame)
		if bush:IsA("Model") then
			bush:PivotTo(cf)
		elseif bush:IsA("BasePart") then
			bush.CFrame = cf
		end
	end

	local function flashBushColor(bush: Instance, flashColor: Color3, restoreDuration: number?)
		local duration = restoreDuration or BUSH_FLASH_RESTORE_DURATION
		local token = (bushFlashToken[bush] or 0) + 1
		bushFlashToken[bush] = token
		cancelBushFlashTweens(bush)

		local parts = collectVisibleBushParts(bush)
		if #parts == 0 then
			return
		end

		local originals = bushFlashOriginalColors[bush]
		if not originals then
			originals = {}
			bushFlashOriginalColors[bush] = originals
		end

		for _, part in parts do
			if not originals[part] then
				originals[part] = part.Color
			end
			part.Color = flashColor
		end

		local tweens: { Tween } = {}
		bushFlashTweens[bush] = tweens
		local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for _, part in parts do
			local originalColor = originals[part]
			if originalColor then
				local tween = TweenService:Create(part, tweenInfo, { Color = originalColor })
				tween:Play()
				table.insert(tweens, tween)
			end
		end
	end

	local function ErrorShakeBush(bush: Instance, duration: number?)
		local shakeDuration = duration or BUSH_ERROR_SHAKE_DURATION
		local token = (bushErrorShakeToken[bush] or 0) + 1
		bushErrorShakeToken[bush] = token

		task.spawn(function()
			local base = captureBushTransform(bush)
			if not base then
				return
			end

			local start = os.clock()
			local endAt = start + shakeDuration
			local step = 1 / 40
			local posAmp = 0.035
			local rotAmp = math.rad(2.2)

			while bush.Parent and token == bushErrorShakeToken[bush] and os.clock() < endAt do
				local elapsed = os.clock() - start
				local fade = 1 - math.clamp(elapsed / shakeDuration, 0, 1)
				local side = if math.floor(elapsed * 16) % 2 == 0 then 1 else -1
				local offset = CFrame.new(side * posAmp * fade, 0, 0) * CFrame.Angles(0, 0, side * rotAmp * fade)
				applyBushTransform(bush, base * offset)
				task.wait(step)
			end

			if token == bushErrorShakeToken[bush] and bush.Parent then
				applyBushTransform(bush, base)
			end
		end)
	end

	local function _getBushAdornee(bush: Instance): BasePart?
		if bush:IsA("BasePart") then
			return bush
		end
		if bush:IsA("Model") then
			local model = bush :: Model
			if model.PrimaryPart then
				return model.PrimaryPart
			end
			return model:FindFirstChildWhichIsA("BasePart", true)
		end
		return nil
	end

	local function _bushWorldTopY(bush: Instance, fallbackY: number): number
		if bush:IsA("Model") then
			return bushTopWorldY(bush :: Model, fallbackY)
		end
		if bush:IsA("BasePart") then
			local part = bush :: BasePart
			return part.Position.Y + part.Size.Y * 0.5
		end
		return fallbackY
	end

	local function resetEmptyBushMessageVisuals(billboard: BillboardGui)
		local label = billboard:FindFirstChild("Text")
		if not label or not label:IsA("TextLabel") then
			return
		end
		label.TextTransparency = 0
		local textStroke = label:FindFirstChildOfClass("UIStroke")
		if textStroke then
			textStroke.Transparency = 0
		end
	end

	local function createEmptyBushBillboard(bush: Instance, anchor: BasePart): BillboardGui
		local billboard = Instance.new("BillboardGui")
		billboard.Name = EMPTY_BUSH_BILLBOARD_NAME
		billboard.Adornee = anchor
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.Size = UDim2.fromOffset(300, 44)
		billboard.StudsOffset = Vector3.zero
		billboard.MaxDistance = 80
		billboard.Parent = bush

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = EMPTY_BUSH_MESSAGE
		label.TextWrapped = true
		label.TextColor3 = Color3.fromRGB(240, 255, 244)
		UiFonts.applyBodyLabel(label, 20, 14)
		label.Parent = billboard

		local textStroke = Instance.new("UIStroke")
		textStroke.Color = Color3.fromRGB(0, 0, 0)
		textStroke.Thickness = 2
		textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		textStroke.Transparency = 0
		textStroke.Parent = label

		return billboard
	end

	local function destroyEmptyBushMessageArtifacts(bush: Instance)
		local billboard = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
		if billboard and billboard:IsA("BillboardGui") then
			billboard:Destroy()
		end
		local anchor = bush:FindFirstChild(BUSH_EMPTY_MESSAGE_ANCHOR_NAME)
		if anchor and anchor:IsA("BasePart") then
			anchor:Destroy()
		end
	end

	local function clearEmptyBushMessageStateImpl(bush: Instance)
		emptyBushMessageHideToken[bush] = (emptyBushMessageHideToken[bush] or 0) + 1
		destroyEmptyBushMessageArtifacts(bush)
	end

	local function fadeOutAndDestroyEmptyBushMessage(bush: Instance, token: number)
		task.delay(EMPTY_BUSH_HOLD_DURATION, function()
			if not bush.Parent or emptyBushMessageHideToken[bush] ~= token then
				return
			end

			local billboard = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
			if not billboard or not billboard:IsA("BillboardGui") then
				emptyBushMessageHideToken[bush] = nil
				return
			end

			local fadeInfo = TweenInfo.new(EMPTY_BUSH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local label = billboard:FindFirstChild("Text")
			if label and label:IsA("TextLabel") then
				TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
				local textStroke = label:FindFirstChildOfClass("UIStroke")
				if textStroke then
					TweenService:Create(textStroke, fadeInfo, { Transparency = 1 }):Play()
				end
			end

			task.delay(EMPTY_BUSH_FADE_DURATION, function()
				if not bush.Parent or emptyBushMessageHideToken[bush] ~= token then
					return
				end
				destroyEmptyBushMessageArtifacts(bush)
				emptyBushMessageHideToken[bush] = nil
			end)
		end)
	end

	local function showEmptyBushMessageImpl(bush: Instance)
		flashBushColor(bush, BUSH_FLASH_RED, BUSH_FLASH_RESTORE_DURATION)
		ErrorShakeBush(bush, BUSH_ERROR_SHAKE_DURATION)

		local anchor = ensureEmptyBushBillboardAnchor(bush)
		if not anchor then
			return
		end

		local token = (emptyBushMessageHideToken[bush] or 0) + 1
		emptyBushMessageHideToken[bush] = token

		local existing = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
		if existing and existing:IsA("BillboardGui") then
			existing.Adornee = anchor
			existing.StudsOffset = Vector3.zero
			resetEmptyBushMessageVisuals(existing)
		else
			createEmptyBushBillboard(bush, anchor)
		end

		fadeOutAndDestroyEmptyBushMessage(bush, token)
	end

	FlashBushColor = flashBushColor
	clearEmptyBushMessageState = clearEmptyBushMessageStateImpl
	showEmptyBushMessage = showEmptyBushMessageImpl
end

local function canAttemptHarvest(player: Player, worldPosition: Vector3, bushRef: Instance?): boolean
	local char = player.Character
	if not char then
		return false
	end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end
	local checkPos = bushSearchPosition(bushRef, worldPosition)
	if (checkPos - hrp.Position).Magnitude > MAX_HARVEST_RANGE + RANGE_SLACK then
		return false
	end
	local cap = carryCapacityForPlayer(player)
	local held = #(activeCarries[player] or {}) + #(pendingFloats[player] or {})
	if held >= cap then
		return false
	end
	return true
end

local function resolveHiddenBrainrotPick(
	bushRef: Instance?,
	brainrots: Folder,
	brainrotIsAvailable: (def: { name: string }) -> boolean
): ({ name: string, rarity: string, baseIncome: number }?, string?)
	if not bushRef or bushRef:GetAttribute(BUSH_HAS_BRAINROT_ATTR) ~= true then
		return nil, nil
	end
	local hiddenName = bushRef:GetAttribute(BUSH_HIDDEN_NAME_ATTR)
	local hiddenMutation = bushRef:GetAttribute(BUSH_HIDDEN_MUTATION_ATTR)
	if typeof(hiddenName) ~= "string" or hiddenName == "" then
		return nil, nil
	end
	local def = Brainrots.getByName(hiddenName)
	if not def or not brainrotIsAvailable(def) then
		return nil, nil
	end
	local mutationId = if typeof(hiddenMutation) == "string" and hiddenMutation ~= "" then hiddenMutation else "normal"
	return def, mutationId
end

local function resolveHiddenHarvestLevel(bushRef: Instance?): number
	if bushRef then
		local stored = bushRef:GetAttribute(BUSH_HIDDEN_LEVEL_ATTR)
		if typeof(stored) == "number" and stored >= 1 then
			return math.clamp(math.floor(stored), 1, Brainrots.MAX_LEVEL)
		end
	end
	return Brainrots.rollBushHarvestLevel()
end

-- Tutorial: first bush brainrot must be level 1 so the upgrade step is affordable.
-- Keeps forcing until they accept a claim (or already own one); later bushes roll normally.
local function playerNeedsTutorialBushLevel1(player: Player): boolean
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
		return false
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR) == true then
		return false
	end
	local inv = brainrotInventories[player]
	if inv and #inv > 0 then
		return false
	end
	if #(activeCarries[player] or {}) > 0 then
		return false
	end
	if #(pendingFloats[player] or {}) > 0 then
		return false
	end
	return true
end

local function resolveHarvestLevelForPlayer(player: Player, bushRef: Instance?): number
	if playerNeedsTutorialBushLevel1(player) then
		return 1
	end
	return resolveHiddenHarvestLevel(bushRef)
end

local function beginHarvestOutcome(player: Player, worldPosition: Vector3, bushRef: Instance?)
	if not canAttemptHarvest(player, worldPosition, bushRef) then
		return
	end
	local char = player.Character :: Model

	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots then
		warn("[BushHarvest] ServerStorage.Brainrots folder missing — add Models under Brainrots in Studio")
		return
	end

	local luckMultiplier = LuckBoost.totalLuckMultiplier(player)
	if luckMultiplier > 1 then
		warn(
			string.format(
				"[BushLuck] %s rolling with playerLuck=%.2f serverLuck=%.2f totalMult=%.2f",
				player.Name,
				LuckBoost.playerLuckMultiplier(player),
				LuckBoost.serverLuckMultiplier(),
				luckMultiplier
			)
		)
	end
	local plot, _basePlot, displayLuck = resolveHarvestPlot(worldPosition, luckMultiplier)

	local function brainrotIsAvailable(def)
		return Brainrots.isPlayableBrainrotName(def.name) and brainrotHasTemplate(brainrots :: Folder, def.name)
	end
	local pick, mutationId = resolveHiddenBrainrotPick(bushRef, brainrots :: Folder, brainrotIsAvailable)
	if not pick then
		pick, mutationId = Brainrots.pickRandomBrainrotForPlot(plot, brainrotIsAvailable)
	end
	if not pick then
		-- Last-resort: pick any template under Brainrots/ with a child Model.
		local templates = collectTemplateModels(brainrots :: Folder)
		if #templates == 0 then
			warn("[BushHarvest] No usable brainrot Models for plot " .. tostring(plot))
			return
		end
		local fallback = templates[math.random(1, #templates)]
		local fallbackName = brainrotNameFromTemplateModel(fallback) or fallback.Name
		local fallbackDef = Brainrots.getByName(fallbackName)
		firePlayBrainrotSFX(player, fallbackName)
		fireHarvestDropFX(player, if fallbackDef then fallbackDef.rarity else "common")
		local harvestLevel = resolveHarvestLevelForPlayer(player, bushRef)
		local clone = fallback:Clone()
		clone.Name = fallbackName
		clone:SetAttribute("OwnerUserId", player.UserId)
		clone:SetAttribute("BrainrotCarryPhase", "Pop")
		clone:SetAttribute("BrainrotName", fallbackName)
		clone:SetAttribute("BrainrotSourcePath", fallback.Parent.Name .. "/" .. fallback.Name)
		clone:SetAttribute("BrainrotMutation", "normal")
		clone:SetAttribute("BrainrotLevel", harvestLevel)
		if bushRef and isValidBushRef(bushRef) then
			local pos = if bushRef:IsA("BasePart") then bushRef.Position else bushRef:GetPivot().Position
			clone:SetAttribute(
				"BrainrotHarvestBushKey",
				string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z)
			)
		end
		for _, d in clone:GetDescendants() do
			if d:IsA("ProximityPrompt") then
				d:Destroy()
			end
		end
		clone.Parent = workspace
		local facePos = char:GetPivot().Position
		local spawnCf, baseYaw = spawnBrainrotAboveBush(clone, worldPosition, harvestLevel, facePos)
		placeModelAtWorld(clone, spawnCf)
		setAllPartsPhysics(clone, true, true)
		local anchorPos = spawnCf.Position
		popSpawnEffect(clone, function()
			if not clone.Parent or player.Character ~= char then
				if clone.Parent then
					clone:Destroy()
				end
				return
			end
			clone:SetAttribute("BrainrotCarryPhase", "Floating")
			setAllPartsPhysics(clone, true, true)
			startFloatingClaimOffer(player, char, clone, anchorPos, baseYaw)
		end)
		return
	end

	local template = findBrainrotModelByNameAndMutation(brainrots :: Folder, pick.name, mutationId)
	if not template then
		warn(string.format("[BushHarvest] Template missing for %s (%s)", pick.name, mutationId))
		return
	end
	-- Track which variant we actually use (we may have fallen back to Normal).
	local variantFolderName = template.Name
	local actualMutation = mutationId
	for mId, folderName in (Brainrots :: any).MUTATION_TEMPLATE_FOLDER do
		if folderName == variantFolderName then
			actualMutation = mId
			break
		end
	end

	firePlayBrainrotSFX(player, pick.name)
	fireHarvestDropFX(player, pick.rarity)

	local harvestLevel = resolveHarvestLevelForPlayer(player, bushRef)
	local clone = template:Clone()
	clone.Name = pick.name
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:SetAttribute("BrainrotCarryPhase", "Pop")
	clone:SetAttribute("BrainrotSourcePath", template.Parent.Name .. "/" .. template.Name)
	clone:SetAttribute("BrainrotName", pick.name)
	clone:SetAttribute("BrainrotRarity", pick.rarity)
	clone:SetAttribute("BrainrotMutation", actualMutation)
	clone:SetAttribute("BrainrotBaseIncome", pick.baseIncome)
	clone:SetAttribute("BrainrotLevel", harvestLevel)
	clone:SetAttribute("BrainrotPlot", plot)
	clone:SetAttribute("BrainrotDisplayLuck", displayLuck)
	if bushRef and isValidBushRef(bushRef) then
		local pos = if bushRef:IsA("BasePart") then bushRef.Position else bushRef:GetPivot().Position
		clone:SetAttribute("BrainrotHarvestBushKey", string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z))
	end

	for _, d in clone:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end

	clone.Parent = workspace
	local facePos = char:GetPivot().Position
	local spawnCf, baseYaw = spawnBrainrotAboveBush(clone, worldPosition, harvestLevel, facePos)
	placeModelAtWorld(clone, spawnCf)
	setAllPartsPhysics(clone, true, true)

	-- Show BrainrotHeader billboard while the brainrot pops out / floats.
	local harvestIncome = Brainrots.incomePerSecond(pick, harvestLevel, actualMutation)
	BrainrotHeader.attach(clone, {
		name = pick.name,
		rarity = pick.rarity,
		mutation = actualMutation,
		level = harvestLevel,
		incomePerSecond = harvestIncome,
	})

	local anchorPos = spawnCf.Position

	popSpawnEffect(clone, function()
		if not clone.Parent or player.Character ~= char then
			if clone.Parent then
				clone:Destroy()
			end
			return
		end
		clone:SetAttribute("BrainrotCarryPhase", "Floating")
		setAllPartsPhysics(clone, true, true)
		startFloatingClaimOffer(player, char, clone, anchorPos, baseYaw)
	end)
end

local lastBushSearchAt: { [Player]: number } = {}

--[[
	processBushSearch — reads current HasHiddenBrainrot; RollBushState runs only after cooldown ends.
]]
local function processBushSearch(player: Player, worldPosition: Vector3, bushRef: Instance?): any
	if typeof(worldPosition) ~= "Vector3" then
		return { ok = false, reason = "badWorldPosition" }
	end

	local bush: Instance? = if typeof(bushRef) == "Instance" then bushRef else nil
	if bush then
		-- The client prompt lives inside a generated _BushPromptAnchor part.
		-- Always sanitize to the real bush root so cooldown/timer attributes are applied to the bush itself.
		bush = BushRootUtil.resolveBushRoot(bush) or bush
	end
	if bush and not isValidBushRef(bush) then
		bush = nil
	end

	local now = os.clock()
	if (lastBushSearchAt[player] or 0) + BUSH_SEARCH_DEBOUNCE_SEC > now then
		local endsAt = bush and bush:GetAttribute(BUSH_COOLDOWN_ENDS_ATTR) or nil
		return {
			ok = false,
			reason = "debounce",
			cooldownEndsAt = if typeof(endsAt) == "number" then endsAt else nil,
		}
	end
	lastBushSearchAt[player] = now

	if not bush or not isValidBushRef(bush) then
		return { ok = false, reason = "invalidBush" }
	end

	if not canAttemptHarvest(player, worldPosition, bush) then
		local endsAt = bush:GetAttribute(BUSH_COOLDOWN_ENDS_ATTR)
		return {
			ok = false,
			reason = "cannotAttempt",
			cooldownEndsAt = if typeof(endsAt) == "number" then endsAt else nil,
		}
	end

	initBushLootIfNeeded(bush)

	if
		bush:GetAttribute(BUSH_LOOT_PHASE_ATTR) == BUSH_LOOT_PHASE_COOLDOWN
		or bush:GetAttribute(BUSH_ON_COOLDOWN_ATTR) == true
	then
		local endsAt = bush:GetAttribute(BUSH_COOLDOWN_ENDS_ATTR)
		return {
			ok = false,
			reason = "cooldown",
			cooldownEndsAt = if typeof(endsAt) == "number" then endsAt else nil,
		}
	end

	local hasBrainrot = bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true

	-- Harvest while hidden-loot attributes are still set. beginBushSearchCooldown clears them.
	if hasBrainrot then
		clearEmptyBushMessageState(bush)
		FlashBushColor(bush, Color3.fromRGB(52, 215, 88))
		if bush:GetAttribute("GlobalRaritySpawn") == true then
			local internal = ServerStorage:FindFirstChild("GameInternal")
			local bf = internal and internal:FindFirstChild("GlobalRaritySpawnClaimed")
			if bf and bf:IsA("BindableFunction") then
				local ok, err = pcall(function()
					(bf :: BindableFunction):Invoke(bush)
				end)
				if not ok then
					warn("[BushHarvest] GlobalRaritySpawnClaimed failed:", err)
				end
			end
		end
		beginHarvestOutcome(player, worldPosition, bush)
	else
		showEmptyBushMessage(bush)
	end

	local cooldownSec = math.random(BUSH_LOOT_RESPAWN_MIN, BUSH_LOOT_RESPAWN_MAX)
	local cooldownEndsAt = beginBushSearchCooldown(bush, cooldownSec)
	scheduleRollAfterCooldown(bush, cooldownSec)

	do
		local timEvt = ServerStorage:FindFirstChild("TimCheeseBushSearched")
		if timEvt and timEvt:IsA("BindableEvent") then
			timEvt:Fire(player)
		end
	end

	if hasBrainrot then
		return {
			ok = true,
			found = true,
			cooldownSec = cooldownSec,
			cooldownEndsAt = cooldownEndsAt,
		}
	end

	return {
		ok = true,
		found = false,
		message = "No brainrots hiding!",
		cooldownSec = cooldownSec,
		cooldownEndsAt = cooldownEndsAt,
	}
end

local carryRedeemDebounce: { [Player]: number } = {}
local pendingRedeemDebounce: { [Player]: number } = {}
local REDEEM_DEBOUNCE = 0.45

local function removeCarryFromActiveList(player: Player, carry: Model)
	local list = activeCarries[player]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i] == carry then
			table.remove(list, i)
		end
	end
end

local function collectCarriedBrainrotsForPlayer(plr: Player): { Model }
	local out: { Model } = {}
	local seen: { [Model]: boolean } = {}
	local function tryAdd(m: Model)
		if seen[m] or not m.Parent then
			return
		end
		local phase = m:GetAttribute("BrainrotCarryPhase")
		-- Include Floating/Pop so paid return still finds hauls mid-animation.
		if phase ~= "Carried" and phase ~= "Floating" and phase ~= "Pop" then
			return
		end
		if m:GetAttribute("OwnerUserId") ~= plr.UserId then
			return
		end
		seen[m] = true
		table.insert(out, m)
	end
	for _, m in ipairs(activeCarries[plr] or {}) do
		tryAdd(m)
	end
	local char = plr.Character
	if char then
		for _, d in char:GetDescendants() do
			if d:IsA("Model") then
				tryAdd(d :: Model)
			end
		end
	end
	return out
end

-- Redeem every carried brainrot for this player in one RedWall touch (until inventory is full).
local function tryRedeemAllAtDeposit(player: Player, depositPart: BasePart?)
	local now = os.clock()
	if (carryRedeemDebounce[player] or 0) + REDEEM_DEBOUNCE > now then
		depositDebug("carry redeem debounced", player.Name)
		return
	end

	local carries = collectCarriedBrainrotsForPlayer(player)
	if #carries == 0 then
		depositDebug("carry redeem: none on character", player.Name)
		return
	end

	carryRedeemDebounce[player] = now
	depositDebug(
		"RedWall touched",
		player.Name,
		depositPart and depositPart:GetFullName() or "deposit",
		"carries",
		#carries
	)

	local map = brainrotParkedInExpandedBackpack[player]
	if not map then
		map = {}
		brainrotParkedInExpandedBackpack[player] = map
	end

	local lastEquipSlot: number? = nil
	local addedAny = false

	for _, carry in ipairs(carries) do
		local brainrotName = getCarryBrainrotName(carry) or carry.Name
		local newSlot = redeemSingleCarryModel(player, carry)
		if not newSlot then
			depositDebug("carry redeem stopped (inventory full?)", player.Name, brainrotName)
			break
		end
		removeCarryFromActiveList(player, carry)
		addedAny = true
		local invList = brainrotInventories[player]
		if invList then
			assignEntryToLowestFreeHotbarSlot(player, invList, map, newSlot)
			-- Always auto-equip by inventory index of the deposited carry.
			lastEquipSlot = newSlot
			depositDebug("hotbar assign", player.Name, brainrotName, "list", newSlot, "equip", lastEquipSlot)
		else
			lastEquipSlot = newSlot
		end
	end

	syncBrainrotCarryCountAttr(player)

	if addedAny and lastEquipSlot then
		-- Server-equip first so plot-return has a Tool even if the client sync races.
		if equipBrainrotSlotForPlayer then
			local equippedIdx = equipBrainrotSlotForPlayer(player, lastEquipSlot, true)
			if equippedIdx then
				lastEquipSlot = equippedIdx
			end
		end
		notifyClientInventorySync(player, lastEquipSlot, true)
	end
end

-- Re-weld head carries after plot return (teleport can leave them offset / stuck).
local function reseatAllCarriedBrainrots(player: Player)
	local char = player.Character
	if not char then
		return
	end
	local carries = collectCarriedBrainrotsForPlayer(player)
	if #carries == 0 then
		return
	end

	for _, carry in ipairs(carries) do
		local main = getMainPart(carry)
		if not main then
			continue
		end
		for _, d in ipairs(main:GetChildren()) do
			if d.Name == "BrainrotCarryMotor" or d.Name == "BrainrotCarryWeld" then
				d:Destroy()
			end
		end
	end

	local lift = 0
	for _, carry in ipairs(carries) do
		local main = getMainPart(carry)
		if not main or not carry.Parent then
			continue
		end
		applyCarryScaleForModel(carry)
		setAllPartsPhysics(carry, false, true)
		local anchorPart, desiredWorld = getCarryAttachmentWorldCFrame(char, main, lift)
		if not anchorPart or not desiredWorld then
			continue
		end
		carry.Parent = char
		carry:PivotTo(desiredWorld)
		local weld = Instance.new("WeldConstraint")
		weld.Name = "BrainrotCarryWeld"
		weld.Part0 = anchorPart
		weld.Part1 = main
		weld.Parent = main
		carry:SetAttribute("BrainrotCarryPhase", "Carried")
		lift += stackHalfHeight(carry) + STACK_GAP
	end
	syncBrainrotCarryCountAttr(player)
end

-- Paid return lands on the plot; if already inside RedWall, Touched never fires.
local function handleAfterPlotReturn(player: Player)
	carryRedeemDebounce[player] = nil

	local function recoverAndDeliver()
		if not player.Parent then
			return
		end
		reseatAllCarriedBrainrots(player)
		local carries = collectCarriedBrainrotsForPlayer(player)
		if #carries == 0 then
			return false
		end
		if isPlayerInsideDeposit(player) then
			tryRedeemAllAtDeposit(player, nil)
			-- If redeem failed (full inventory), keep them reseated on the head.
			reseatAllCarriedBrainrots(player)
		end
		return #collectCarriedBrainrotsForPlayer(player) > 0
			or player:GetAttribute("BrainrotCarryCount") == 0
	end

	-- Immediate + short retries — teleport can leave carries unwelded for a frame.
	recoverAndDeliver()
	task.defer(function()
		recoverAndDeliver()
	end)
	task.delay(0.15, function()
		recoverAndDeliver()
	end)
	task.delay(0.45, function()
		recoverAndDeliver()
	end)
end

do
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BrainrotInternal"
		folder.Parent = ServerStorage
	end
	local existing = folder:FindFirstChild("AfterPlotReturn")
	local bf: BindableFunction
	if existing and existing:IsA("BindableFunction") then
		bf = existing
	else
		if existing then
			existing:Destroy()
		end
		bf = Instance.new("BindableFunction")
		bf.Name = "AfterPlotReturn"
		bf.Parent = folder
	end
	bf.OnInvoke = function(playerArg: any): any
		if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
			return false
		end
		handleAfterPlotReturn(playerArg :: Player)
		return true
	end
end

-- Award spinning (pending float) brainrots when the player touches the safezone wall.
local function tryRedeemPendingFloatsAtDeposit(player: Player)
	local pending = pendingFloats[player]
	if not pending or #pending == 0 then
		return
	end

	local now = os.clock()
	if (pendingRedeemDebounce[player] or 0) + REDEEM_DEBOUNCE > now then
		return
	end

	local map = brainrotParkedInExpandedBackpack[player]
	if not map then
		map = {}
		brainrotParkedInExpandedBackpack[player] = map
	end
	local list = brainrotInventories[player]
	if not list or findLowestFreeHotbarSlot(player, list, map) == nil then
		return
	end

	local toRedeem: { Model } = {}
	for _, clone in ipairs(pending) do
		if clone.Parent and clone:GetAttribute("OwnerUserId") == player.UserId then
			table.insert(toRedeem, clone)
		end
	end
	if #toRedeem == 0 then
		return
	end

	pendingRedeemDebounce[player] = now

	local lastEquipInvIdx: number? = nil
	local addedAny = false

	for _, clone in ipairs(toRedeem) do
		tryPlaySafeZoneSFXForCarry(player, clone)
		local conn = floatConnByClone[clone]
		if conn then
			conn:Disconnect()
			floatConnByClone[clone] = nil
		end
		removePendingFloat(player, clone)

		if not clone.Parent then
			continue
		end

		list = brainrotInventories[player]
		map = brainrotParkedInExpandedBackpack[player] or map
		if not list or findLowestFreeHotbarSlot(player, list, map) == nil then
			break
		end

		local newSlot = redeemSingleCarryModel(player, clone)
		if not newSlot then
			break
		end

		list = brainrotInventories[player]
		if not list then
			break
		end

		assignEntryToLowestFreeHotbarSlot(player, list, map, newSlot)
		lastEquipInvIdx = newSlot
		addedAny = true
	end

	syncBrainrotCarryCountAttr(player)

	if addedAny then
		notifyClientInventorySync(player, lastEquipInvIdx, true)
	end
end

local function touchedPartToOwnerPlayer(other: BasePart): Player?
	local ancestor = other:FindFirstAncestorWhichIsA("Model")
	if not ancestor then
		return nil
	end
	local plr = Players:GetPlayerFromCharacter(ancestor)
	if plr then
		return plr
	end
	if ancestor:GetAttribute("BrainrotCarryPhase") == "Carried" then
		local uid = ancestor:GetAttribute("OwnerUserId")
		if typeof(uid) == "number" then
			return Players:GetPlayerByUserId(uid)
		end
	end
	return nil
end

local function _carriedBrainrotFromTouch(other: BasePart, plr: Player): Model?
	local w: Instance? = other
	while w do
		if w:IsA("Model") and w:GetAttribute("BrainrotCarryPhase") == "Carried" then
			local uid = w:GetAttribute("OwnerUserId")
			if typeof(uid) == "number" and uid == plr.UserId then
				local list = activeCarries[plr]
				if list and table.find(list, w) then
					return w :: Model
				end
			end
		end
		w = w.Parent
	end
	return nil
end

local function hookDepositPart(part: BasePart)
	registerDepositPart(part)
	if depositTouchHooked[part] then
		return
	end
	depositTouchHooked[part] = true
	part.Destroying:Connect(function()
		unregisterDepositPart(part)
		depositTouchHooked[part] = nil
	end)
	part.Touched:Connect(function(other: BasePart)
		if not other:IsA("BasePart") then
			return
		end
		local plr = touchedPartToOwnerPlayer(other)
		if not plr then
			return
		end
		local char = plr.Character
		local isCharacterTouch = char ~= nil and other:IsDescendantOf(char)
		local hasCarry = #collectCarriedBrainrotsForPlayer(plr) > 0

		if not isCharacterTouch and not hasCarry then
			return
		end

		depositDebug("Touched event", plr.Name, part:GetFullName(), "from", other:GetFullName())

		if isCharacterTouch or hasCarry then
			tryPlaySafeZoneSFXForAllCarries(plr)
		end

		-- Carried brainrots first (separate debounce from pending floats).
		if hasCarry then
			tryRedeemAllAtDeposit(plr, part)
		end

		if isCharacterTouch then
			tryRedeemPendingFloatsAtDeposit(plr)
		end
	end)
	depositDebug("hooked deposit part", part:GetFullName())
end

local function ensureSpawnRedWallDepositHooks(root: Instance)
	task.spawn(function()
		local stack = { root }
		local processed = 0
		while #stack > 0 do
			local d = table.remove(stack)
			if d:IsA("BasePart") and (d.Name == "RedWall" or d.Name == "RedPart") then
				if not CollectionService:HasTag(d, DEPOSIT_TAG) then
					CollectionService:AddTag(d, DEPOSIT_TAG)
				end
				hookDepositPart(d)
			end
			for _, child in d:GetChildren() do
				table.insert(stack, child)
			end
			processed += 1
			if processed % 400 == 0 then
				task.wait()
			end
		end
	end)
end

for _, inst in CollectionService:GetTagged(DEPOSIT_TAG) do
	if inst:IsA("BasePart") then
		registerDepositPart(inst)
		hookDepositPart(inst)
	end
end

CollectionService:GetInstanceAddedSignal(DEPOSIT_TAG):Connect(function(inst)
	if inst:IsA("BasePart") then
		registerDepositPart(inst)
		hookDepositPart(inst)
	end
end)

CollectionService:GetInstanceRemovedSignal(DEPOSIT_TAG):Connect(function(inst)
	if inst:IsA("BasePart") then
		unregisterDepositPart(inst)
	end
end)

local charRemovingConns: { [Player]: RBXScriptConnection } = {}

local function hookCharacterRemoving(p: Player)
	if charRemovingConns[p] then
		return
	end
	charRemovingConns[p] = p.CharacterRemoving:Connect(function()
		clearPlayerHarvestState(p)
	end)
end

Players.PlayerAdded:Connect(function(p)
	PlayerDataService.waitUntilLoaded(p)
	if not brainrotInventories[p] then
		brainrotInventories[p] = {}
	end
	if not brainrotParkedInExpandedBackpack[p] then
		brainrotParkedInExpandedBackpack[p] = {}
	end
	if typeof(p:GetAttribute("BrainrotCount")) ~= "number" then
		p:SetAttribute("BrainrotCount", #brainrotInventories[p])
	end
	syncBrainrotCarryCountAttr(p)
	hookCharacterRemoving(p)
end)

Players.PlayerRemoving:Connect(function(p)
	for _, clone in pendingFloats[p] or {} do
		local c = floatConnByClone[clone]
		if c then
			c:Disconnect()
			floatConnByClone[clone] = nil
		end
		if clone.Parent then
			clone:Destroy()
		end
	end
	for _, m in activeCarries[p] or {} do
		if m.Parent then
			m:Destroy()
		end
	end
	pendingFloats[p] = nil
	activeCarries[p] = nil
	local charConn = charRemovingConns[p]
	if charConn then
		charConn:Disconnect()
		charRemovingConns[p] = nil
	end
	-- Defer inventory wipe so PlayerDataService can export on PlayerRemoving first.
	-- Skip during Roblox Restart-all-servers so BindToClose can still re-export if needed.
	task.defer(function()
		if game:GetAttribute("ServerClosing") == true then
			return
		end
		brainrotInventories[p] = nil
		brainrotParkedInExpandedBackpack[p] = nil
		brainrotHotbarSlots[p] = nil
	end)
end)

for _, p in Players:GetPlayers() do
	if not brainrotInventories[p] then
		brainrotInventories[p] = {}
	end
	if not brainrotParkedInExpandedBackpack[p] then
		brainrotParkedInExpandedBackpack[p] = {}
	end
	if typeof(p:GetAttribute("BrainrotCount")) ~= "number" then
		p:SetAttribute("BrainrotCount", #brainrotInventories[p])
	end
	syncBrainrotCarryCountAttr(p)
	hookCharacterRemoving(p)
end

ensurePlayBrainrotSFXRemote()
ensurePlayHarvestDropFXRemote()
ensureSafeZoneFlashRemote()

local harvestRemote = ensureRemote()
local harvestBushFn = ensureHarvestFunction()

local legacyNoBrainrotRemote = ReplicatedStorage:FindFirstChild("NoBrainrotFoundEvent")
if legacyNoBrainrotRemote then
	legacyNoBrainrotRemote:Destroy()
end

harvestRemote.OnServerEvent:Connect(function(player: Player, worldPosition: Vector3, bushRef: Instance?)
	processBushSearch(player, worldPosition, bushRef)
end)

harvestBushFn.OnServerInvoke = function(player: Player, worldPosition: Vector3, bushRef: Instance?): any
	return processBushSearch(player, worldPosition, bushRef)
end

local BushHarvestFloating = require(Modules:WaitForChild("BushHarvestFloating"))
BushHarvestFloating.wireDecisionRemote({
	pendingFloats = pendingFloats,
	floatConnByClone = floatConnByClone,
	removePendingFloat = removePendingFloat,
	syncBrainrotCarryCountAttr = syncBrainrotCarryCountAttr,
	attachCarriedBrainrot = attachCarriedBrainrot,
	getMainPart = getMainPart,
	setAllPartsPhysics = setAllPartsPhysics,
	releaseBushAfterFloatingTimeout = releaseBushAfterFloatingTimeout,
})

local _, getInvRF = ensureInventoryRemotes()

getInvRF.OnServerInvoke = function(requesting: Player)
	local list = brainrotInventories[requesting]
	if not list then
		return packInventoryForClient(requesting, {})
	end
	return packInventoryForClient(requesting, list)
end

local destroyAllBrainrotToolsForPlayer = BushHarvestBrainrotEquip.destroyAllBrainrotToolsForPlayer

-- After removing list index `removedIdx`, re-key tucked flags so they still match list positions.
local function shiftParkedMapAfterListRemove(m: { [number]: boolean }, removedIdx: number)
	local prev: { [number]: boolean } = {}
	for k = 1, 9 do
		if m[k] then
			prev[k] = true
		end
	end
	for k = 1, 9 do
		m[k] = nil
	end
	for k = 1, 9 do
		if prev[k] then
			if k < removedIdx then
				m[k] = true
			elseif k > removedIdx then
				m[k - 1] = true
			end
		end
	end
end

local HOTBAR_UI_SLOTS = 9

local function getHotbarSlotMap(plr: Player): { [number]: number }
	local m = brainrotHotbarSlots[plr]
	if not m then
		m = {}
		brainrotHotbarSlots[plr] = m
	end
	return m
end

local function explicitInventoryIndexForHotbarSlot(
	slotMap: { [number]: number },
	slot: number,
	list: { BrainrotInvEntry }
): number?
	for idx, mappedSlot in pairs(slotMap) do
		if typeof(idx) == "number" and typeof(mappedSlot) == "number" then
			local i = math.floor(idx)
			local s = math.floor(mappedSlot)
			if i >= 1 and list[i] ~= nil and s == slot then
				return i
			end
		end
	end
	return nil
end

local function inventoryIndexForHotbarSlot(
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	slot: number
): number?
	if slot < 1 or slot > HOTBAR_UI_SLOTS then
		return nil
	end
	local slotMap = getHotbarSlotMap(plr)
	local explicit = explicitInventoryIndexForHotbarSlot(slotMap, slot, list)
	if explicit then
		return explicit
	end
	-- Default legacy behavior: inventory index 1..9 appears in the matching hotbar
	-- slot unless it was tucked or explicitly moved elsewhere.
	if list[slot] ~= nil and map[slot] ~= true and slotMap[slot] == nil then
		return slot
	end
	return nil
end

local function isHotbarSlotVisuallyFree(
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	slot: number
): boolean
	return inventoryIndexForHotbarSlot(plr, list, map, slot) == nil
end

findLowestFreeHotbarSlot = function(plr: Player, list: { BrainrotInvEntry }, map: { [number]: boolean }): number?
	for i = 1, HOTBAR_UI_SLOTS do
		if isHotbarSlotVisuallyFree(plr, list, map, i) then
			return i
		end
	end
	return nil
end

local function moveInventoryEntryToExactHotbarSlot(
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	srcIdx: number,
	targetSlot: number
): boolean
	if not list[srcIdx] then
		return false
	end

	local target = math.clamp(math.floor(targetSlot), 1, HOTBAR_UI_SLOTS)
	local slotMap = getHotbarSlotMap(plr)
	local oldSlot = slotMap[srcIdx]
	if typeof(oldSlot) ~= "number" and srcIdx >= 1 and srcIdx <= HOTBAR_UI_SLOTS and map[srcIdx] ~= true then
		oldSlot = srcIdx
	end

	local displacedIdx = inventoryIndexForHotbarSlot(plr, list, map, target)
	if displacedIdx and displacedIdx ~= srcIdx then
		-- Swap when the dragged brainrot came from another visible hotbar slot.
		-- Otherwise, push the displaced brainrot into the backpack so drops from the
		-- backpack onto an occupied slot behave like replace/tuck instead of duping.
		if oldSlot and oldSlot >= 1 and oldSlot <= HOTBAR_UI_SLOTS then
			slotMap[displacedIdx] = oldSlot
			map[displacedIdx] = nil
		else
			slotMap[displacedIdx] = nil
			if displacedIdx <= HOTBAR_UI_SLOTS then
				map[displacedIdx] = true
			end
		end
	end

	-- If this item used to rely on its default matching index, make the custom
	-- slot explicit. This is what allows index 3 to live in hotbar slot 8.
	slotMap[srcIdx] = target
	map[srcIdx] = nil
	destroyAllBrainrotToolsForPlayer(plr)
	return true
end

assignEntryToLowestFreeHotbarSlot = function(
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	srcIdx: number
): number?
	if not list[srcIdx] then
		return nil
	end
	local currentSlot = nil
	for s = 1, HOTBAR_UI_SLOTS do
		if inventoryIndexForHotbarSlot(plr, list, map, s) == srcIdx then
			currentSlot = s
			break
		end
	end
	if currentSlot and map[srcIdx] ~= true then
		return currentSlot
	end
	local destSlot = findLowestFreeHotbarSlot(plr, list, map)
	if not destSlot then
		return nil
	end
	if moveInventoryEntryToExactHotbarSlot(plr, list, map, srcIdx, destSlot) then
		return destSlot
	end
	return nil
end

local function ensureBrainrotParkedRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("BrainrotSetParkedSlot")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "BrainrotSetParkedSlot"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

--[[
	BrainrotSetParkedSlot(srcIdx, tuck, targetSlot?, backpackDestIdx?)
	  srcIdx          : 1..MAX_BRAINROT_INVENTORY_CAPACITY — inventory index of the item being dragged.
	  tuck            : true  → remove from hotbar index srcIdx (1..9), shift higher slots down, then insert the row
	                    at backpackDestIdx (1..#list+1 before remove) or append if omitted. Rebuild tools.
	                    false → see targetSlot / backpackDestIdx.
	  targetSlot      : 1..9 hotbar slot when moving/untucking onto the hotbar (tuck=false).
	  backpackDestIdx : optional 1..#list+1 — insert into list at this index (pre-remove coordinates; pushes right).
]]
local function normalizeBrainrotParkedMap(map: { [number]: boolean }, list: { BrainrotInvEntry })
	for slot in pairs(map) do
		if typeof(slot) ~= "number" or slot < 1 or slot > HOTBAR_UI_SLOTS or list[slot] == nil then
			map[slot] = nil
		end
	end
end

local function setBrainrotSlotTucked(
	map: { [number]: boolean },
	list: { BrainrotInvEntry },
	slot: number,
	tucked: boolean
)
	if slot < 1 or slot > HOTBAR_UI_SLOTS then
		return
	end
	if list[slot] == nil then
		map[slot] = nil
		return
	end
	if tucked then
		map[slot] = true
	else
		map[slot] = nil
	end
end

ensureBrainrotParkedRemote().OnServerEvent:Connect(
	function(plr: Player, idx: any, parked: any, targetSlot: any?, backpackDestIdx: any?)
		if typeof(idx) ~= "number" or typeof(parked) ~= "boolean" then
			return
		end
		local i = math.floor(idx)
		if i < 1 or i > MAX_BRAINROT_INVENTORY_CAPACITY then
			return
		end
		local list = brainrotInventories[plr]
		if not list or not list[i] then
			return
		end
		local map = brainrotParkedInExpandedBackpack[plr]
		if not map then
			map = {}
			brainrotParkedInExpandedBackpack[plr] = map
		end

		local changed = false
		if parked then
			-- Hotbar/backpack save path. Tuck by state — do not remove/reindex the list.
			local char = plr.Character
			if char and i <= HOTBAR_UI_SLOTS then
				local hum = char:FindFirstChildOfClass("Humanoid")
				local t = char:FindFirstChildOfClass("Tool")
				if hum and t and t:IsA("Tool") and t:GetAttribute("BrainrotTool") == true then
					local a = t:GetAttribute("BrainrotInvIndex")
					if typeof(a) == "number" and math.floor(a) == i then
						hum:UnequipTools()
					end
				end
			end
			getHotbarSlotMap(plr)[i] = nil
			if i <= HOTBAR_UI_SLOTS then
				setBrainrotSlotTucked(map, list, i, true)
			end
			changed = true
			destroyAllBrainrotToolsForPlayer(plr)
		else
			if typeof(backpackDestIdx) == "number" then
				-- Keep tucked in backpack; no list reindex (register-limit safe inline).
				getHotbarSlotMap(plr)[i] = nil
				if i <= HOTBAR_UI_SLOTS then
					setBrainrotSlotTucked(map, list, i, true)
				end
				changed = true
				destroyAllBrainrotToolsForPlayer(plr)
			elseif typeof(targetSlot) == "number" then
				changed = moveInventoryEntryToExactHotbarSlot(plr, list, map, i, targetSlot :: number)
			else
				-- Backpack → hotbar without exact cell: fill the lowest visually free slot.
				changed = assignEntryToLowestFreeHotbarSlot(plr, list, map, i) ~= nil
			end
		end

		if changed then
			normalizeBrainrotParkedMap(map, list)
			plr:SetAttribute("BrainrotCount", #list)
		end

		local sync = ensureInventoryRemotes()
		sync:FireClient(plr, packInventoryForClient(plr, list))
	end
)

local function ensureEquipBrainrotRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("EquipBrainrotSlot")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "EquipBrainrotSlot"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

equipBrainrotSlotForPlayer = BushHarvestBrainrotEquip.createEquipBrainrotSlotForPlayer({
	Brainrots = Brainrots,
	SafezoneUtil = SafezoneUtil,
	brainrotInventories = brainrotInventories,
	brainrotParkedInExpandedBackpack = brainrotParkedInExpandedBackpack,
	HOTBAR_UI_SLOTS = HOTBAR_UI_SLOTS,
	MAX_BACKPACK_BRAINROT_SLOTS = MAX_BACKPACK_BRAINROT_SLOTS,
	assignEntryToLowestFreeHotbarSlot = assignEntryToLowestFreeHotbarSlot,
	playerInInventoryZone = playerInInventoryZone,
	getMainPart = getMainPart,
	findTemplateBySourcePath = findTemplateBySourcePath,
	findFirstTemplateByModelName = findFirstTemplateByModelName,
})

require(Modules:WaitForChild("BushHarvestInternal")).boot({
	pushBrainrotInventory = pushBrainrotInventory,
	brainrotInventories = brainrotInventories,
	brainrotParkedInExpandedBackpack = brainrotParkedInExpandedBackpack,
	brainrotHotbarSlots = brainrotHotbarSlots,
	enrichEntryFromCatalog = enrichEntryFromCatalog,
	enrichEntryFromBrainrotsFolder = enrichEntryFromBrainrotsFolder,
	Brainrots = Brainrots,
	IndexService = IndexService,
	BrainrotEconomy = BrainrotEconomy,
	packInventoryForClient = packInventoryForClient,
	hotbarSlotsPayloadForPlayer = hotbarSlotsPayloadForPlayer,
	syncBrainrotCarryCountAttr = syncBrainrotCarryCountAttr,
	ensureInventoryRemotes = ensureInventoryRemotes,
	equipBrainrotSlotForPlayer = equipBrainrotSlotForPlayer,
	notifyClientInventorySync = notifyClientInventorySync,
	notifyIndexDeposited = notifyIndexDeposited,
	HOTBAR_UI_SLOTS = HOTBAR_UI_SLOTS,
	assignEntryToLowestFreeHotbarSlot = assignEntryToLowestFreeHotbarSlot,
	playerInInventoryZone = playerInInventoryZone,
	SafezoneUtil = SafezoneUtil,
	destroyAllBrainrotToolsForPlayer = destroyAllBrainrotToolsForPlayer,
	shiftParkedMapAfterListRemove = shiftParkedMapAfterListRemove,
	getBushRemotesFolder = getBushRemotesFolder,
	ensureEquipBrainrotRemote = ensureEquipBrainrotRemote,
})

task.defer(function()
	local map = workspace:WaitForChild("Map", 120)
	if not map then
		return
	end

	local spawnBases = map:WaitForChild("Spawn And Bases", 60)
	if spawnBases then
		ensureSpawnRedWallDepositHooks(spawnBases)
		spawnBases.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") and (desc.Name == "RedWall" or desc.Name == "RedPart") then
				task.defer(function()
					if not CollectionService:HasTag(desc, DEPOSIT_TAG) then
						CollectionService:AddTag(desc, DEPOSIT_TAG)
					end
					hookDepositPart(desc)
				end)
			end
		end)
	end

	assignLootUnder(map)
	map.DescendantAdded:Connect(function(desc)
		if desc:IsA("Folder") and BushRootUtil.isBushFolderName(desc.Name) then
			for _, child in desc:GetChildren() do
				if isLootableBush(child) then
					task.defer(function()
						registerBushLootState(child)
					end)
				end
			end
			return
		end
		if isLootableBush(desc) then
			task.defer(function()
				registerBushLootState(desc)
			end)
		end
	end)

	for _ = 1, 60 do
		refreshLuckHitboxes()
		if #luckHitboxes > 0 then
			break
		end
		task.wait(1)
	end
end)
