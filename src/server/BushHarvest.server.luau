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

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))
local BrainrotHeader = require(Modules:WaitForChild("BrainrotHeader"))
local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck

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
-- Per search: 30% empty, 70% spawn a brainrot (rolled each time a player searches a bush).
local BUSH_FIND_CHANCE = 0.7
local BUSH_EMPTY_PERCENT = 30 -- used by shiver hint pre-roll only (assignBushLoot)
local BUSH_SEARCH_DEBOUNCE_SEC = 0.4
local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_LOOT_ASSIGNED_ATTR = "BushLootAssigned"
local BUSH_LOOT_RESPAWN_MIN = 10
local BUSH_LOOT_RESPAWN_MAX = 15
local FLOAT_DURATION = 4
local POP_DURATION = 0.35
local BUSH_FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }
local DEPOSIT_TAG = "BrainrotDeposit"
local MAX_BACKPACK_BRAINROT_SLOTS = 19
-- Total brainrot inventory capacity (UI "All Items [used/max]"); distinct from the 19 backpack grid rows.
local MAX_BRAINROT_INVENTORY_CAPACITY = 100
-- Fallback when Head / UpperTorso missing (e.g. custom rigs).
local HRP_CARRY_OFFSET = CFrame.new(0, 3.4, 0.2) * CFrame.Angles(0, math.rad(180), 0)

-- Multiple brainrots per player while swinging: capacity = max(1, floor(Carry upgrade attribute)).
local pendingFloats: { [Player]: { Model } } = {}
local activeCarries: { [Player]: { Model } } = {}
local floatConnByClone: { [Model]: RBXScriptConnection } = {}
local brainrotInventories: { [Player]: { BrainrotInvEntry } } = {}
-- Indices 1–9 only: brainrot shown in expanded backpack grid instead of custom hotbar (client drag).
local brainrotParkedInExpandedBackpack: { [Player]: { [number]: boolean } } = {}

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

local function enrichEntryFromCatalog(entry: BrainrotInvEntry)
	local def = Brainrots.getByName(entry.name)
	if not def then
		return
	end
	if (entry.baseIncome or 0) <= 0 then
		entry.baseIncome = def.baseIncome
		entry.rarity = def.rarity
	elseif typeof(entry.rarity) ~= "string" or entry.rarity == "" then
		entry.rarity = def.rarity
	end
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

local function packInventoryForClient(plr: Player, list: { BrainrotInvEntry }, equipSlot: number?): { entries: { BrainrotInvEntry }, used: number, max: number, tuckedSlots: { number }, equipSlot: number? }
	local payload: any = {
		entries = copyInventoryList(list),
		used = #list,
		max = MAX_BRAINROT_INVENTORY_CAPACITY,
		tuckedSlots = tuckedSlotsArrayForPlayer(plr),
	}
	if typeof(equipSlot) == "number" then
		payload.equipSlot = math.clamp(math.floor(equipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
	end
	return payload
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
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local refresh = folder and folder:FindFirstChild("RefreshRebirthState")
	if refresh and refresh:IsA("BindableFunction") then
		pcall(function()
			(refresh :: BindableFunction):Invoke(player)
		end)
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

local function findFirstTemplateByModelName(root: Folder, modelName: string): Model?
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d.Name == modelName and d.Parent and d.Parent:IsA("Folder") then
			return d
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
		return
	end
	local icon = pickIconFromTemplateModel(template)
	if icon ~= "" then
		entry.icon = icon
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
	local entry: BrainrotInvEntry = {
		name = carry.Name,
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
		return nil
	end
	if carry:GetAttribute("OwnerUserId") ~= player.UserId then
		return nil
	end

	player:SetAttribute("LastCollectedBrainrot", carry.Name)
	local entry = carryModelToInventoryEntry(carry)
	if not pushBrainrotInventory(player, entry, true) then
		return nil
	end

	local list = brainrotInventories[player]
	local newSlot = if list then #list else nil

	local indexInternal = ServerStorage:FindFirstChild("IndexInternal")
	local indexBF = indexInternal and indexInternal:FindFirstChild("OnBrainrotDeposited")
	if indexBF and indexBF:IsA("BindableFunction") then
		pcall(function()
			indexBF:Invoke(player, entry)
		end)
	end

	carry:Destroy()
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

local function getCarryAttachmentWorldCFrame(character: Model, mainPart: BasePart, stackLiftY: number): (BasePart?, CFrame?)
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
	local nameFolder = root:FindFirstChild(brainrotName)
	if not nameFolder then
		return nil
	end
	local variantFolderName = (Brainrots :: any).MUTATION_TEMPLATE_FOLDER[mutationId]
	if typeof(variantFolderName) == "string" then
		local exact = nameFolder:FindFirstChild(variantFolderName)
		if exact and exact:IsA("Model") and modelHasSpawnableGeometry(exact :: Model) then
			return exact :: Model
		end
	end
	local fallback = nameFolder:FindFirstChild("Normal")
	if fallback and fallback:IsA("Model") and modelHasSpawnableGeometry(fallback :: Model) then
		return fallback :: Model
	end
	for _, c in ipairs(nameFolder:GetChildren()) do
		if c:IsA("Model") and modelHasSpawnableGeometry(c :: Model) then
			return c :: Model
		end
	end
	return nil
end

local function brainrotHasTemplate(root: Folder, brainrotName: string): boolean
	local nameFolder = root:FindFirstChild(brainrotName)
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
		if seen[child] then return end
		if tonumber(string.match(child.Name, PLOT_NAME_PATTERN)) then
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
		local n = tonumber(string.match(child.Name, PLOT_NAME_PATTERN)) or 1
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

local equipBrainrotSlotForPlayer: (Player, number) -> boolean
local findLowestFreeHotbarSlot: (list: { BrainrotInvEntry }, map: { [number]: boolean }) -> number?
local assignEntryToLowestFreeHotbarSlot: (
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	srcIdx: number
) -> number?

local function notifyClientInventorySync(player: Player, autoEquipSlot: number?)
	local invList = brainrotInventories[player]
	local slot: number? = nil
	if typeof(autoEquipSlot) == "number" then
		slot = math.clamp(math.floor(autoEquipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
	end
	if slot and invList and invList[slot] then
		equipBrainrotSlotForPlayer(player, slot :: number)
	end
	local sync = ensureInventoryRemotes()
	sync:FireClient(player, packInventoryForClient(player, invList or {}, slot))
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

local function resolveHarvestPlot(worldPos: Vector3): (number, number, number)
	local basePlot = resolvePlotForBushPos(worldPos)
	local displayLuck = resolveDisplayLuckForPos(worldPos)
	local plot = PlotLuck.effectivePlot(basePlot, displayLuck, Brainrots.MAX_PLOT)
	return plot, basePlot, displayLuck
end

local function bushTopWorldY(bush: Model?, fallbackY: number): number
	if not bush or not bush.Parent then
		return fallbackY
	end
	local _, maxV = BrainrotCarryVisual.getWorldAabb(bush)
	if maxV then
		return maxV.Y
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

local function spawnBrainrotAboveBush(clone: Model, worldPosition: Vector3, harvestLevel: number): (CFrame, number)
	local bush = findNearestBushModel(worldPosition, MAX_HARVEST_RANGE + RANGE_SLACK)
	local surfaceTopY = bushTopWorldY(bush, worldPosition.Y)
	BrainrotCarryVisual.applyScaleForLevel(clone, harvestLevel)
	local yaw = math.random() * math.pi * 2
	local spawnCf = BrainrotCarryVisual.spawnCFrameAboveSurface(
		clone,
		worldPosition.X,
		surfaceTopY,
		worldPosition.Z,
		nil,
		yaw
	)
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
	local duration = POP_DURATION
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		local t = (os.clock() - t0) / duration
		if t >= 1 then
			conn:Disconnect()
			model:PivotTo(pivot)
			if onDone then
				onDone()
			end
			return
		end
		local wobble = (1 - t) * 0.18
		local yaw = math.sin(t * math.pi * 5) * wobble
		local pitch = math.cos(t * math.pi * 4) * wobble * 0.6
		model:PivotTo(pivot * CFrame.Angles(pitch, yaw, -yaw * 0.4))
	end)
end

local function clearPlayerHarvestState(player: Player)
	for _, clone in pendingFloats[player] or {} do
		local c = floatConnByClone[clone]
		if c then
			c:Disconnect()
			floatConnByClone[clone] = nil
		end
		if clone.Parent then
			clone:Destroy()
		end
	end
	pendingFloats[player] = nil
	for _, m in activeCarries[player] or {} do
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

local function attachCarriedBrainrot(player: Player, clone: Model)
	local char = player.Character
	if not char then
		return
	end
	local main = getMainPart(clone)
	if not main then
		return
	end

	-- Already inside RedWall deposit: skip head carry (Touched won't fire if they never left the box).
	if isPlayerInsideDeposit(player) then
		local newSlot = redeemSingleCarryModel(player, clone)
		if newSlot then
			syncBrainrotCarryCountAttr(player)
			notifyClientInventorySync(player, newSlot)
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

local function runFloatThenAttach(player: Player, char: Model, clone: Model, anchorPos: Vector3, baseYaw: number)
	local plist = pendingFloats[player]
	if not plist then
		plist = {}
		pendingFloats[player] = plist
	end
	table.insert(plist, clone)
	syncBrainrotCarryCountAttr(player)

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not clone.Parent then
			conn:Disconnect()
			floatConnByClone[clone] = nil
			removePendingFloat(player, clone)
			return
		end
		if player.Character ~= char then
			conn:Disconnect()
			floatConnByClone[clone] = nil
			clearPlayerHarvestState(player)
			return
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			conn:Disconnect()
			floatConnByClone[clone] = nil
			clearPlayerHarvestState(player)
			return
		end

		local elapsed = os.clock() - t0
		if elapsed >= FLOAT_DURATION then
			conn:Disconnect()
			floatConnByClone[clone] = nil
			removePendingFloat(player, clone)
			if isPlayerInsideDeposit(player) then
				local newSlot = redeemSingleCarryModel(player, clone)
				if newSlot then
					syncBrainrotCarryCountAttr(player)
					notifyClientInventorySync(player, newSlot)
				else
					attachCarriedBrainrot(player, clone)
				end
			else
				attachCarriedBrainrot(player, clone)
			end
			return
		end

		local t = elapsed
		local bob = math.sin(t * 2.4) * 0.32
		local panX = math.sin(t * 0.75) * 0.55
		local panZ = math.cos(t * 0.62) * 0.55
		local yaw = baseYaw + t * 0.42
		local tilt = math.sin(t * 1.9) * 0.07
		-- Keep float path mostly above the anchor (bob can dip slightly but stays high)
		local pos = anchorPos + Vector3.new(panX, math.max(0.15, bob), panZ)
		clone:PivotTo(CFrame.new(pos) * CFrame.Angles(tilt * 0.35, yaw, tilt))
	end)
	floatConnByClone[clone] = conn
end

local function isLootableBush(inst: Instance): boolean
	return inst.Name == "BushSCRIPT" and (inst:IsA("Model") or inst:IsA("BasePart"))
end

local function rollBushHasBrainrot(): boolean
	return math.random(1, 100) > BUSH_EMPTY_PERCENT
end

local function isValidBushRef(bushRef: Instance?): boolean
	if not bushRef or not bushRef.Parent then
		return false
	end
	if bushRef.Name ~= "BushSCRIPT" then
		return false
	end
	if not bushRef:IsA("Model") and not bushRef:IsA("BasePart") then
		return false
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return false
	end
	return bushRef:IsDescendantOf(map)
end

local function assignBushLoot(bush: Instance): boolean
	if not isValidBushRef(bush) then
		return false
	end
	if bush:GetAttribute(BUSH_LOOT_ASSIGNED_ATTR) == true then
		return bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true
	end
	local hasBrainrot = rollBushHasBrainrot()
	bush:SetAttribute(BUSH_LOOT_ASSIGNED_ATTR, true)
	bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, hasBrainrot)
	return hasBrainrot
end

local function scheduleBushLootRespawn(bush: Instance)
	local delaySec = math.random(BUSH_LOOT_RESPAWN_MIN, BUSH_LOOT_RESPAWN_MAX)
	task.delay(delaySec, function()
		if not bush.Parent or not isValidBushRef(bush) then
			return
		end
		bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, rollBushHasBrainrot())
	end)
end

local function assignLootUnder(root: Instance)
	for _, desc in root:GetDescendants() do
		if isLootableBush(desc) then
			assignBushLoot(desc)
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

local EMPTY_BUSH_MESSAGE = "No brainrots hiding!"
local EMPTY_BUSH_MESSAGE_DURATION = 4
local EMPTY_BUSH_BILLBOARD_NAME = "BushEmptyMessage"
local emptyBushMessageHideToken: { [Instance]: number } = {}

local function getBushAdornee(bush: Instance): BasePart?
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

local function bushWorldTopY(bush: Instance, fallbackY: number): number
	if bush:IsA("Model") then
		return bushTopWorldY(bush :: Model, fallbackY)
	end
	if bush:IsA("BasePart") then
		local part = bush :: BasePart
		return part.Position.Y + part.Size.Y * 0.5
	end
	return fallbackY
end

local function scheduleEmptyBushMessageCleanup(bush: Instance, token: number)
	task.delay(EMPTY_BUSH_MESSAGE_DURATION, function()
		if not bush.Parent then
			emptyBushMessageHideToken[bush] = nil
			return
		end
		if emptyBushMessageHideToken[bush] ~= token then
			return
		end
		local billboard = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
		if billboard and billboard:IsA("BillboardGui") then
			billboard:Destroy()
		end
		emptyBushMessageHideToken[bush] = nil
	end)
end

local function showEmptyBushMessage(bush: Instance)
	local adornee = getBushAdornee(bush)
	if not adornee then
		return
	end

	local existing = bush:FindFirstChild(EMPTY_BUSH_BILLBOARD_NAME)
	if existing and existing:IsA("BillboardGui") then
		local token = (emptyBushMessageHideToken[bush] or 0) + 1
		emptyBushMessageHideToken[bush] = token
		scheduleEmptyBushMessageCleanup(bush, token)
		return
	end

	local topY = bushWorldTopY(bush, adornee.Position.Y)
	local offsetY = topY - adornee.Position.Y + 1.25

	local billboard = Instance.new("BillboardGui")
	billboard.Name = EMPTY_BUSH_BILLBOARD_NAME
	billboard.Adornee = adornee
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromOffset(220, 56)
	billboard.StudsOffset = Vector3.new(0, math.max(1.25, offsetY), 0)
	billboard.MaxDistance = 80
	billboard.Parent = bush

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = EMPTY_BUSH_MESSAGE
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 220, 90)
	stroke.Thickness = 2.5
	stroke.Parent = label

	emptyBushMessageHideToken[bush] = 1
	scheduleEmptyBushMessageCleanup(bush, 1)
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

local function beginHarvestOutcome(player: Player, worldPosition: Vector3)
	if not canAttemptHarvest(player, worldPosition, nil) then
		return
	end
	local char = player.Character :: Model

	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots then
		warn("[BushHarvest] ServerStorage.Brainrots folder missing — add Models under Brainrots in Studio")
		return
	end

	local plot, _basePlot, displayLuck = resolveHarvestPlot(worldPosition)

	local function brainrotIsAvailable(def)
		return brainrotHasTemplate(brainrots :: Folder, def.name)
	end
	local pick, mutationId = Brainrots.pickRandomBrainrotForPlot(plot, brainrotIsAvailable)
	if not pick then
		-- Last-resort: pick any template under Brainrots/ with a child Model.
		local templates = collectTemplateModels(brainrots :: Folder)
		if #templates == 0 then
			warn("[BushHarvest] No usable brainrot Models for plot " .. tostring(plot))
			return
		end
		local fallback = templates[math.random(1, #templates)]
		local harvestLevel = Brainrots.rollBushHarvestLevel()
		local clone = fallback:Clone()
		clone.Name = fallback.Name
		clone:SetAttribute("OwnerUserId", player.UserId)
		clone:SetAttribute("BrainrotCarryPhase", "Pop")
		clone:SetAttribute("BrainrotSourcePath", fallback.Parent.Name .. "/" .. fallback.Name)
		clone:SetAttribute("BrainrotMutation", "normal")
		clone:SetAttribute("BrainrotLevel", harvestLevel)
		clone.Parent = workspace
		local spawnCf, baseYaw = spawnBrainrotAboveBush(clone, worldPosition, harvestLevel)
		placeModelAtWorld(clone, spawnCf)
		setAllPartsPhysics(clone, true, true)
		local anchorPos = spawnCf.Position
		popSpawnEffect(clone, function()
			if not clone.Parent or player.Character ~= char then
				if clone.Parent then clone:Destroy() end
				return
			end
			clone:SetAttribute("BrainrotCarryPhase", "Floating")
			setAllPartsPhysics(clone, true, true)
			runFloatThenAttach(player, char, clone, anchorPos, baseYaw)
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

	local harvestLevel = Brainrots.rollBushHarvestLevel()
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

	clone.Parent = workspace
	local spawnCf, baseYaw = spawnBrainrotAboveBush(clone, worldPosition, harvestLevel)
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
		runFloatThenAttach(player, char, clone, anchorPos, baseYaw)
	end)
end

local lastBushSearchAt: { [Player]: number } = {}

--[[
	processBushSearch — each search rolls 70% spawn / 30% empty. Returns true when a brainrot was spawned.
]]
local function processBushSearch(player: Player, worldPosition: Vector3, bushRef: Instance?): boolean
	if typeof(worldPosition) ~= "Vector3" then
		return false
	end
	local bush: Instance? = if typeof(bushRef) == "Instance" then bushRef else nil
	if bush and not isValidBushRef(bush) then
		bush = nil
	end

	local now = os.clock()
	if (lastBushSearchAt[player] or 0) + BUSH_SEARCH_DEBOUNCE_SEC > now then
		return false
	end
	lastBushSearchAt[player] = now

	if not bush or not isValidBushRef(bush) then
		return false
	end

	if not canAttemptHarvest(player, worldPosition, bush) then
		return false
	end

	if math.random() > BUSH_FIND_CHANCE then
		showEmptyBushMessage(bush)
		return false
	end

	beginHarvestOutcome(player, worldPosition)
	return true
end

local redeemDebounce: { [Player]: number } = {}
local REDEEM_DEBOUNCE = 0.45

-- Redeem every carried brainrot for this player in one deposit touch (until inventory is full).
local function tryRedeemAllAtDeposit(player: Player)
	local now = os.clock()
	if (redeemDebounce[player] or 0) + REDEEM_DEBOUNCE > now then
		return
	end
	local list = activeCarries[player]
	if not list or #list == 0 then
		return
	end

	redeemDebounce[player] = now

	local lastAddedIdx = 1
	local addedAny = false

	for i = #list, 1, -1 do
		local carry = list[i]
		if not carry or not carry.Parent then
			table.remove(list, i)
			continue
		end
		if carry:GetAttribute("OwnerUserId") ~= player.UserId then
			continue
		end

		if redeemSingleCarryModel(player, carry) then
			addedAny = true
			local invList = brainrotInventories[player]
			if invList then
				lastAddedIdx = #invList
			end
			table.remove(list, i)
		else
			-- Inventory full — stop; remaining carries stay for another touch.
			break
		end
	end

	syncBrainrotCarryCountAttr(player)

	if addedAny then
		notifyClientInventorySync(player, lastAddedIdx)
	end
end

-- Award spinning (pending float) brainrots when the player touches the safezone wall.
local function tryRedeemPendingFloatsAtDeposit(player: Player)
	local pending = pendingFloats[player]
	if not pending or #pending == 0 then
		return
	end

	local now = os.clock()
	if (redeemDebounce[player] or 0) + REDEEM_DEBOUNCE > now then
		return
	end

	local map = brainrotParkedInExpandedBackpack[player]
	if not map then
		map = {}
		brainrotParkedInExpandedBackpack[player] = map
	end
	local list = brainrotInventories[player]
	if not list or findLowestFreeHotbarSlot(list, map) == nil then
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

	redeemDebounce[player] = now

	local lastHotbarIdx: number? = nil
	local addedAny = false

	for _, clone in ipairs(toRedeem) do
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
		if not list or findLowestFreeHotbarSlot(list, map) == nil then
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

		local hotbarIdx = assignEntryToLowestFreeHotbarSlot(player, list, map, newSlot)
		if not hotbarIdx then
			break
		end
		lastHotbarIdx = hotbarIdx
		addedAny = true
	end

	syncBrainrotCarryCountAttr(player)

	if addedAny then
		notifyClientInventorySync(player, lastHotbarIdx)
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

local function carriedBrainrotFromTouch(other: BasePart, plr: Player): Model?
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
	part.Destroying:Connect(function()
		unregisterDepositPart(part)
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

		if isCharacterTouch then
			tryRedeemPendingFloatsAtDeposit(plr)
		end

		local list = activeCarries[plr]
		local carry = carriedBrainrotFromTouch(other, plr)
		if not carry and list and #list > 0 and isCharacterTouch then
			-- HRP / body touched deposit while carrying (carry mesh might not be the hit part).
			carry = list[#list]
		end
		if not carry or not carry.Parent then
			return
		end
		tryRedeemAllAtDeposit(plr)
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

Players.PlayerAdded:Connect(function(p)
	brainrotInventories[p] = {}
	brainrotParkedInExpandedBackpack[p] = {}
	p:SetAttribute("BrainrotCount", 0)
	syncBrainrotCarryCountAttr(p)
	p.CharacterRemoving:Connect(function()
		clearPlayerHarvestState(p)
	end)
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
	brainrotInventories[p] = nil
	brainrotParkedInExpandedBackpack[p] = nil
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
	p.CharacterRemoving:Connect(function()
		clearPlayerHarvestState(p)
	end)
end

local harvestRemote = ensureRemote()
local harvestBushFn = ensureHarvestFunction()

local legacyNoBrainrotRemote = ReplicatedStorage:FindFirstChild("NoBrainrotFoundEvent")
if legacyNoBrainrotRemote then
	legacyNoBrainrotRemote:Destroy()
end

harvestRemote.OnServerEvent:Connect(function(player: Player, worldPosition: Vector3, bushRef: Instance?)
	processBushSearch(player, worldPosition, bushRef)
end)

harvestBushFn.OnServerInvoke = function(player: Player, worldPosition: Vector3, bushRef: Instance?): boolean
	return processBushSearch(player, worldPosition, bushRef)
end

local _, getInvRF = ensureInventoryRemotes()

getInvRF.OnServerInvoke = function(requesting: Player)
	local list = brainrotInventories[requesting]
	if not list then
		return packInventoryForClient(requesting, {})
	end
	return packInventoryForClient(requesting, list)
end

local function destroyAllBrainrotToolsForPlayer(plr: Player)
	local bp = plr:FindFirstChildOfClass("Backpack")
	local char = plr.Character
	if bp then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				c:Destroy()
			end
		end
	end
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				c:Destroy()
			end
		end
	end
end

-- Retag existing brainrot Tool's BrainrotInvIndex so equipped/held tools stay valid after a swap.
local function swapBrainrotToolIndices(plr: Player, oldA: number, oldB: number)
	local roots: { Instance } = {}
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp then
		table.insert(roots, bp)
	end
	local char = plr.Character
	if char then
		table.insert(roots, char)
	end
	for _, root in ipairs(roots) do
		for _, c in ipairs(root:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				local a = c:GetAttribute("BrainrotInvIndex")
				if typeof(a) == "number" then
					local af = math.floor(a)
					if af == oldA then
						c:SetAttribute("BrainrotInvIndex", oldB)
					elseif af == oldB then
						c:SetAttribute("BrainrotInvIndex", oldA)
					end
				end
			end
		end
	end
end

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

-- After inserting at list index `insertIdx` (1..9), shift tucked flags so they match list positions.
local function mergeMapAfterBackpackInsert(m: { [number]: boolean }, insertIdx: number, insertedTucked: boolean)
	if insertIdx > 9 then
		return
	end
	local prev: { [number]: boolean } = {}
	for j = 1, 9 do
		if m[j] then
			prev[j] = true
		end
	end
	for j = 1, 9 do
		m[j] = nil
	end
	for p = 1, 9 do
		if p < insertIdx then
			if prev[p] then
				m[p] = true
			end
		elseif p == insertIdx then
			if insertedTucked then
				m[p] = true
			end
		else
			if prev[p - 1] then
				m[p] = true
			end
		end
	end
end

local HOTBAR_UI_SLOTS = 9

local function isHotbarSlotVisuallyFree(list: { BrainrotInvEntry }, map: { [number]: boolean }, slot: number): boolean
	if slot < 1 or slot > HOTBAR_UI_SLOTS then
		return false
	end
	if not list[slot] then
		return true
	end
	return map[slot] == true
end

findLowestFreeHotbarSlot = function(list: { BrainrotInvEntry }, map: { [number]: boolean }): number?
	for i = 1, HOTBAR_UI_SLOTS do
		if isHotbarSlotVisuallyFree(list, map, i) then
			return i
		end
	end
	return nil
end

local function relocateInventoryEntryToHotbarSlot(
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	srcIdx: number,
	destSlot: number
): boolean
	if not list[srcIdx] then
		return false
	end
	if srcIdx == destSlot then
		if destSlot <= HOTBAR_UI_SLOTS then
			map[destSlot] = nil
		end
		return true
	end

	shiftParkedMapAfterListRemove(map, srcIdx)
	local row = table.remove(list, srcIdx)
	if not row then
		return false
	end

	local insertK = destSlot
	if srcIdx < destSlot then
		insertK = destSlot - 1
	end
	insertK = math.clamp(insertK, 1, #list + 1)
	table.insert(list, insertK, row)
	if insertK <= HOTBAR_UI_SLOTS then
		mergeMapAfterBackpackInsert(map, insertK, false)
		map[insertK] = nil
	end
	return true
end

assignEntryToLowestFreeHotbarSlot = function(
	plr: Player,
	list: { BrainrotInvEntry },
	map: { [number]: boolean },
	srcIdx: number
): number?
	local destSlot = findLowestFreeHotbarSlot(list, map)
	if not destSlot then
		return nil
	end
	if srcIdx == destSlot then
		if srcIdx <= HOTBAR_UI_SLOTS and map[srcIdx] then
			map[srcIdx] = nil
		end
		return srcIdx
	end
	if not relocateInventoryEntryToHotbarSlot(list, map, srcIdx, destSlot) then
		return nil
	end
	destroyAllBrainrotToolsForPlayer(plr)
	return destSlot
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
ensureBrainrotParkedRemote().OnServerEvent:Connect(function(plr: Player, idx: any, parked: any, targetSlot: any?, backpackDestIdx: any?)
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

	if parked then
		if i > 9 then
			return -- Items at idx > 9 already live in the backpack panel; cannot "tuck" further.
		end
		local char = plr.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			local t = char:FindFirstChildOfClass("Tool")
			if hum and t and t:IsA("Tool") and t:GetAttribute("BrainrotTool") == true then
				local a = t:GetAttribute("BrainrotInvIndex")
				if typeof(a) == "number" and math.floor(a) == i then
					hum:UnequipTools()
				end
			end
		end
		shiftParkedMapAfterListRemove(map, i)
		local row = table.remove(list, i)
		if not row then
			return
		end
		-- Append to backpack list; do not preserve the former hotbar slot index.
		table.insert(list, row)
		local newIdx = #list
		if newIdx <= HOTBAR_UI_SLOTS then
			mergeMapAfterBackpackInsert(map, newIdx, true)
		end
		destroyAllBrainrotToolsForPlayer(plr)
	else
		if typeof(backpackDestIdx) == "number" then
			local destK = math.clamp(math.floor(backpackDestIdx :: number), 1, #list + 1)
			if destK ~= i then
				local srcTucked = (i <= HOTBAR_UI_SLOTS) and (map[i] == true)
				shiftParkedMapAfterListRemove(map, i)
				local row = table.remove(list, i)
				if not row then
					return
				end
				local insertK = destK
				if i < destK then
					insertK = destK - 1
				end
				insertK = math.clamp(insertK, 1, #list + 1)
				table.insert(list, insertK, row)
				mergeMapAfterBackpackInsert(map, insertK, srcTucked)
				destroyAllBrainrotToolsForPlayer(plr)
			end
		elseif typeof(targetSlot) == "number" then
			-- Hotbar → hotbar swap/drag onto a specific slot.
			local j = math.clamp(math.floor(targetSlot :: number), 1, math.min(HOTBAR_UI_SLOTS, #list))
			if j ~= i then
				if list[j] then
					list[i], list[j] = list[j], list[i]
					swapBrainrotToolIndices(plr, i, j)
				else
					local row = table.remove(list, i)
					if row then
						table.insert(list, math.min(j, #list + 1), row)
					end
					destroyAllBrainrotToolsForPlayer(plr)
				end
			end
			if j <= HOTBAR_UI_SLOTS then
				map[j] = nil
			end
		else
			-- Backpack → hotbar (or general untuck): always fill the lowest free slot 1..9.
			assignEntryToLowestFreeHotbarSlot(plr, list, map, i)
		end
	end

	local sync = ensureInventoryRemotes()
	sync:FireClient(plr, packInventoryForClient(plr, list))
end)

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

local function removeBrainrotToolAtInventoryIndex(parent: Instance, invIndex: number)
	for _, c in ipairs(parent:GetChildren()) do
		if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
			local a = c:GetAttribute("BrainrotInvIndex")
			if typeof(a) == "number" and math.floor(a) == invIndex then
				c:Destroy()
			end
		end
	end
end

local function buildBrainrotToolFromTemplate(template: Model, entry: BrainrotInvEntry, invIndex: number): Tool?
	local clone = template:Clone()
	BrainrotCarryVisual.applyScaleForLevel(clone, entry.level)
	for _, d in clone:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	local main = getMainPart(clone)
	if not main then
		clone:Destroy()
		return nil
	end

	local parts: { BasePart } = {}
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	local tool = Instance.new("Tool")
	tool.Name = entry.name
	tool:SetAttribute("BrainrotTool", true)
	tool:SetAttribute("BrainrotInvIndex", invIndex)
	tool:SetAttribute("BrainrotSourcePath", entry.sourcePath)
	tool:SetAttribute("BrainrotName", entry.name)
	tool:SetAttribute("BrainrotRarity", entry.rarity)
	tool:SetAttribute("BrainrotMutation", entry.mutation)
	tool:SetAttribute("BrainrotLevel", math.max(1, math.floor(entry.level)))
	tool:SetAttribute("BrainrotBaseIncome", entry.baseIncome)
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true -- keep E for bush Search while a brainrot is equipped in the hotbar
	if entry.icon ~= "" then
		pcall(function()
			tool.TextureId = entry.icon
		end)
	end

	main.Name = "Handle"
	main.Anchored = false
	main.Massless = true
	main.Parent = tool

	for _, p in parts do
		if p ~= main then
			p.Anchored = false
			p.Massless = true
			p.Parent = tool
			local w = Instance.new("WeldConstraint")
			w.Part0 = main
			w.Part1 = p
			w.Parent = main
		end
	end

	BrainrotCarryVisual.applyNonColliding(tool)

	clone:Destroy()
	tool.Grip = CFrame.new()
	return tool
end

local function equipBrainrotSlotForPlayerImpl(player: Player, slot: number): boolean
	local list = brainrotInventories[player]
	if not list then
		return false
	end
	local map = brainrotParkedInExpandedBackpack[player]
	if not map then
		map = {}
		brainrotParkedInExpandedBackpack[player] = map
	end
	local idx = math.clamp(math.floor(slot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
	if not list[idx] then
		return false
	end
	if idx > HOTBAR_UI_SLOTS or map[idx] then
		local newIdx = assignEntryToLowestFreeHotbarSlot(player, list, map, idx)
		if not newIdx then
			return false
		end
		idx = newIdx
		local sync = ensureInventoryRemotes()
		sync:FireClient(player, packInventoryForClient(player, list))
	end
	local entry = list[idx]
	local char = player.Character
	if not char then
		return false
	end
	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots then
		return false
	end
	local template: Model? = nil
	if entry.sourcePath ~= "" then
		template = findTemplateBySourcePath(brainrots, entry.sourcePath)
	end
	if not template then
		template = findFirstTemplateByModelName(brainrots, entry.name)
	end
	if not template then
		return false
	end
	local tool = buildBrainrotToolFromTemplate(template, entry, idx)
	if not tool then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local bp = player:FindFirstChildOfClass("Backpack")
	if not hum or not bp then
		tool:Destroy()
		return false
	end
	removeBrainrotToolAtInventoryIndex(bp, idx)
	removeBrainrotToolAtInventoryIndex(char, idx)
	tool.Parent = bp
	hum:EquipTool(tool)
	return true
end

equipBrainrotSlotForPlayer = equipBrainrotSlotForPlayerImpl

local function inventoryEntryIncome(entry: BrainrotInvEntry): number
	enrichEntryFromCatalog(entry)
	return BrainrotEconomy.incomePerSecond({
		name = entry.name,
		rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
		mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
		level = if typeof(entry.level) == "number" then entry.level else 1,
		baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
	})
end

local function equipBestBrainrotForPlayer(plr: Player): boolean
	local list = brainrotInventories[plr]
	if not list or #list == 0 then
		return false
	end
	local map = brainrotParkedInExpandedBackpack[plr]
	if not map then
		map = {}
		brainrotParkedInExpandedBackpack[plr] = map
	end

	if findLowestFreeHotbarSlot(list, map) == nil then
		return false
	end

	local bestIdx: number? = nil
	local bestIncome = -math.huge
	for i, entry in ipairs(list) do
		if i > HOTBAR_UI_SLOTS or map[i] == true then
			local inc = inventoryEntryIncome(entry)
			if inc > bestIncome then
				bestIncome = inc
				bestIdx = i
			end
		end
	end

	if not bestIdx then
		return false
	end

	if assignEntryToLowestFreeHotbarSlot(plr, list, map, bestIdx) == nil then
		return false
	end

	local sync = ensureInventoryRemotes()
	sync:FireClient(plr, packInventoryForClient(plr, list))
	return true
end

local function ensureEquipBestBrainrotRemote(): RemoteEvent
	local folder = getBushRemotesFolder()
	local ev = folder:FindFirstChild("EquipBestBrainrot")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "EquipBestBrainrot"
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

ensureEquipBestBrainrotRemote().OnServerEvent:Connect(function(player: Player)
	equipBestBrainrotForPlayer(player)
end)

ensureEquipBrainrotRemote().OnServerEvent:Connect(function(player: Player, slot: any)
	if typeof(slot) ~= "number" then
		return
	end
	equipBrainrotSlotForPlayer(player, slot :: number)
end)

task.defer(function()
	local map = workspace:WaitForChild("Map", 120)
	if not map then
		return
	end

	assignLootUnder(map)
	map.DescendantAdded:Connect(function(desc)
		if isLootableBush(desc) then
			task.defer(function()
				assignBushLoot(desc)
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

-- ── Inter-script API (consumed by StandManager.server) ────────────────────────
-- Removes the inventory entry at `idx`, destroys any equipped/backpack Tool that
-- references it, shifts the parked-slot bitmap, and broadcasts the sync. Returns
-- the removed entry (or nil if invalid).

local function consumeInventoryEntry(plr: Player, idx: number): BrainrotInvEntry?
	local list = brainrotInventories[plr]
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
	enrichEntryFromCatalog(entry)

	-- Unequip / destroy any Tool referencing this inventory index.
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
	destroyAllBrainrotToolsForPlayer(plr)

	local map = brainrotParkedInExpandedBackpack[plr]
	if map then
		shiftParkedMapAfterListRemove(map, i)
	end
	table.remove(list, i)
	plr:SetAttribute("BrainrotCount", #list)

	local sync = ensureInventoryRemotes()
	sync:FireClient(plr, packInventoryForClient(plr, list))
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local refresh = folder and folder:FindFirstChild("RefreshRebirthState")
	if refresh and refresh:IsA("BindableFunction") then
		pcall(function()
			(refresh :: BindableFunction):Invoke(plr)
		end)
	end
	return entry
end

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

local internal = ensureInternalFolder()

local function ensureBindable(name: string): BindableFunction
	local existing = internal:FindFirstChild(name)
	if existing and existing:IsA("BindableFunction") then
		return existing
	end
	local bf = Instance.new("BindableFunction")
	bf.Name = name
	bf.Parent = internal
	return bf
end

local consumeBF = ensureBindable("ConsumeInventoryEntry")
consumeBF.OnInvoke = function(player: any, idx: any): any
	if typeof(player) ~= "Instance" or not (player :: any):IsA("Player") then
		return nil
	end
	if typeof(idx) ~= "number" then
		return nil
	end
	return consumeInventoryEntry(player :: Player, idx)
end

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
	if not name then return false end
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
	-- If icon is empty, try to enrich from template.
	if entry.icon == "" then
		local brainrotsFolder = Brainrots.getBrainrotsFolder()
		if brainrotsFolder and brainrotsFolder:IsA("Folder") then
			enrichEntryFromBrainrotsFolder(brainrotsFolder :: Folder, entry)
		end
	end
	enrichEntryFromCatalog(entry)
	return pushBrainrotInventory(player :: Player, entry)
end

local getListBF = ensureBindable("GetInventoryList")
getListBF.OnInvoke = function(playerArg: any): any
	if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
		return {}
	end
	local plr = playerArg :: Player
	local list = brainrotInventories[plr] or {}
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
