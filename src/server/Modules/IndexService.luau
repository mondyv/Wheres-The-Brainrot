-- [ACTIVE] IndexService
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local IndexConfig = require(ReplicatedStorage.Shared.IndexConfig)
local LuckyBlockCatalog = require(ReplicatedStorage.Shared.LuckyBlockCatalog)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))

local M = {}

type UnlockMap = { [string]: boolean }

local unlockedByPlayer: { [Player]: UnlockMap } = {}
local collectedByPlayer: { [Player]: UnlockMap } = {}
local goldenNamesByPlayer: { [Player]: { [string]: boolean } } = {}

local brainrotsFolder: Folder? = nil
local luckyBlocksListFolder: Folder? = nil
local iconCache: { [string]: { [string]: string } } = {}
local packedCatalogCache: { [string]: { { name: string, rarity: string, baseIncome: number, icon: string } } } = {}

local function getBrainrotsFolder(): Folder?
	if brainrotsFolder and brainrotsFolder.Parent then
		return brainrotsFolder
	end
	local root = ServerStorage:FindFirstChild("Brainrots")
	if root and root:IsA("Folder") then
		brainrotsFolder = root
		return root
	end
	return nil
end

local function findVariantTemplate(brainrotName: string, mutationId: string): Model?
	local root = getBrainrotsFolder()
	if not root then
		return nil
	end
	local brainrotFolder = Brainrots.findBrainrotStorageFolder(root, brainrotName)
	if not brainrotFolder then
		return nil
	end
	for _, variantFolderName in ipairs(Brainrots.mutationTemplateCandidateNames(mutationId)) do
		local variant = brainrotFolder:FindFirstChild(variantFolderName)
		if variant and variant:IsA("Model") then
			return variant
		end
		if variant then
			for _, child in ipairs(variant:GetChildren()) do
				if child:IsA("Model") then
					return child
				end
			end
		end
	end
	return nil
end

local function pickIconFromModel(model: Model): string
	local function readIconNode(node: Instance): string
		if node:IsA("ImageLabel") and node.Image ~= "" and node.Image ~= "rbxasset://textures/ui/GuiImagePlaceholder.png" then
			return node.Image
		end
		if node:IsA("ImageButton") and node.Image ~= "" and node.Image ~= "rbxasset://textures/ui/GuiImagePlaceholder.png" then
			return node.Image
		end
		if node:IsA("Decal") and node.Texture ~= "" and node.Texture ~= "rbxasset://textures/ui/GuiImagePlaceholder.png" then
			return node.Texture
		end
		return ""
	end
	-- Only look at an Icon node. Never walk the whole 3D model (that timed out gold/diamond Index packs).
	local iconNode = model:FindFirstChild("Icon")
	if iconNode then
		local tex = readIconNode(iconNode)
		if tex ~= "" then
			return tex
		end
		for _, d in iconNode:GetChildren() do
			tex = readIconNode(d)
			if tex ~= "" then
				return tex
			end
		end
	end
	for _, child in model:GetChildren() do
		if child.Name == "Icon" then
			local tex = readIconNode(child)
			if tex ~= "" then
				return tex
			end
		end
	end
	return ""
end

function M.getIconFor(brainrotName: string, mutationId: string): string
	local mut = if mutationId ~= "" then mutationId else "normal"
	local byName = iconCache[brainrotName]
	if byName then
		local cached = byName[mut]
		if typeof(cached) == "string" then
			return cached
		end
	end
	local icon = ""
	local template = findVariantTemplate(brainrotName, mut)
	if template then
		icon = pickIconFromModel(template)
	end
	if icon == "" and mut ~= "normal" then
		local fallback = findVariantTemplate(brainrotName, "normal")
		if fallback then
			icon = pickIconFromModel(fallback)
		end
	end
	if not byName then
		byName = {}
		iconCache[brainrotName] = byName
	end
	byName[mut] = icon
	return icon
end

local function getLuckyBlocksList(): Folder?
	if luckyBlocksListFolder and luckyBlocksListFolder.Parent then
		return luckyBlocksListFolder
	end
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	if not root then
		return nil
	end
	local list = root:FindFirstChild("lucky blocks") or root:FindFirstChild("Lucky Blocks")
	if list and list:IsA("Folder") then
		luckyBlocksListFolder = list
		return list
	end
	return nil
end

local function firstModelChild(container: Instance): Model?
	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("Model") then
			return c
		end
	end
	return nil
end

local function findLuckyBlockTemplate(blockId: string, variant: string?): Model?
	local root = getLuckyBlocksList()
	if not root then
		return nil
	end
	local node: Instance? = root:FindFirstChild(blockId)
	if not node then
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == blockId then
				node = d
				break
			end
		end
	end
	if not node then
		return nil
	end
	local childModel = firstModelChild(node)
	if childModel then
		if typeof(variant) == "string" and variant ~= "" then
			local exact = node:FindFirstChild(variant)
			if exact and exact:IsA("Model") then
				return exact
			end
			local lower = string.lower(variant)
			for _, d in ipairs(node:GetDescendants()) do
				if d:IsA("Model") and string.lower(d.Name) == lower then
					return d
				end
			end
		end
		return childModel
	end
	if node:IsA("Model") then
		return node :: Model
	end
	return nil
end

function M.getLuckyBlockIcon(blockId: string): string
	-- Prefer curated UI icons from Lucky Block Icons.
	local fromIcons = LuckyBlockCatalog.resolveIconAssetId(blockId)
	if fromIcons ~= "" then
		return fromIcons
	end
	local def = LuckyBlockCatalog.get(blockId)
	local template = findLuckyBlockTemplate(blockId, if def then def.variant else nil)
	if template then
		local icon = pickIconFromModel(template)
		if icon ~= "" then
			return icon
		end
	end
	return ""
end

local function ensureMaps(player: Player)
	if not unlockedByPlayer[player] then
		unlockedByPlayer[player] = {}
	end
	if not collectedByPlayer[player] then
		collectedByPlayer[player] = {}
	end
	if not goldenNamesByPlayer[player] then
		goldenNamesByPlayer[player] = {}
	end
end

local function syncGoldenAttributes(player: Player)
	local names = goldenNamesByPlayer[player] or {}
	local count = 0
	for _ in names do
		count += 1
	end
	player:SetAttribute("IndexGoldenCount", count)
	if count >= IndexConfig.GOLDEN_QUEST_TARGET then
		player:SetAttribute("IndexGoldenQuestComplete", true)
	else
		if player:GetAttribute("IndexGoldenQuestComplete") ~= true then
			player:SetAttribute("IndexGoldenQuestComplete", false)
		end
	end
end

function M.initPlayer(player: Player)
	ensureMaps(player)
	if player:GetAttribute("IndexGoldenCount") == nil then
		player:SetAttribute("IndexGoldenCount", 0)
	end
	if player:GetAttribute("IndexGoldenQuestComplete") == nil then
		player:SetAttribute("IndexGoldenQuestComplete", false)
	end
	syncGoldenAttributes(player)
end

function M.clearPlayer(player: Player)
	unlockedByPlayer[player] = nil
	collectedByPlayer[player] = nil
	goldenNamesByPlayer[player] = nil
end

function M.isUnlocked(player: Player, name: string, mutationId: string): boolean
	local map = unlockedByPlayer[player]
	if not map then
		return false
	end
	return map[IndexConfig.unlockKey(name, mutationId)] == true
end

local function unlockKeyName(unlockKey: string): string
	local colon = string.find(unlockKey, ":", 1, true)
	if colon then
		return string.sub(unlockKey, 1, colon - 1)
	end
	return unlockKey
end

-- True if the player has unlocked this brainrot in the index (any mutation tab).
-- Rebirth and other systems must use this — not inventory ownership.
function M.hasDiscoveredBrainrot(player: Player, brainrotName: string): boolean
	local map = unlockedByPlayer[player]
	if not map then
		return false
	end
	local want = RebirthConfig.normalizeName(brainrotName)
	for key, unlocked in map do
		if unlocked and RebirthConfig.normalizeName(unlockKeyName(key)) == want then
			return true
		end
	end
	return false
end

function M.getUnlockMap(player: Player): UnlockMap
	ensureMaps(player)
	return unlockedByPlayer[player] :: UnlockMap
end

function M.exportGoldenNames(player: Player): { string }
	local names = goldenNamesByPlayer[player]
	local out: { string } = {}
	if not names then
		return out
	end
	for name in names do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function M.importUnlocks(player: Player, unlockKeys: { string }, goldenNames: { string }, collectedKeys: { string }?)
	ensureMaps(player)
	local map: UnlockMap = {}
	for _, key in unlockKeys do
		if typeof(key) == "string" and key ~= "" then
			map[key] = true
		end
	end
	unlockedByPlayer[player] = map

	local collected: UnlockMap = {}
	if collectedKeys == nil then
		for key in map do
			collected[key] = true
		end
	else
		for _, key in collectedKeys do
			if typeof(key) == "string" and key ~= "" then
				collected[key] = true
			end
		end
	end
	collectedByPlayer[player] = collected

	local golden: { [string]: boolean } = {}
	for _, name in goldenNames do
		if typeof(name) == "string" and name ~= "" then
			golden[name] = true
		end
	end
	goldenNamesByPlayer[player] = golden
	syncGoldenAttributes(player)
end

function M.getGoldenCount(player: Player): number
	local names = goldenNamesByPlayer[player]
	if not names then
		return 0
	end
	local n = 0
	for _ in names do
		n += 1
	end
	return n
end

-- Returns true if this was a newly discovered entry.
function M.recordUnlock(player: Player, name: string, mutationId: string): boolean
	ensureMaps(player)
	local key = IndexConfig.unlockKey(name, mutationId)
	local map = unlockedByPlayer[player] :: UnlockMap
	if map[key] then
		return false
	end
	map[key] = true

	if mutationId == "golden" then
		local golden = goldenNamesByPlayer[player] :: { [string]: boolean }
		if not golden[name] then
			golden[name] = true
			syncGoldenAttributes(player)
		end
	end
	return true
end

function M.exportCollected(player: Player): { string }
	ensureMaps(player)
	local out: { string } = {}
	local map = collectedByPlayer[player]
	if not map then
		return out
	end
	for key, on in map do
		if on then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

function M.isCollected(player: Player, name: string, mutationId: string): boolean
	local map = collectedByPlayer[player]
	if not map then
		return false
	end
	return map[IndexConfig.unlockKey(name, mutationId)] == true
end

local function rarityForEntry(name: string, mutationId: string): string
	if mutationId == IndexConfig.LUCKY_BLOCK_TAB then
		return LuckyBlockCatalog.primaryDropRarity(name)
	end
	for _, def in Brainrots.BRAINROTS do
		if def.name == name then
			return def.rarity
		end
	end
	return "common"
end

-- Returns xp granted, or 0 if rejected.
function M.pendingCollectCount(player: Player): number
	ensureMaps(player)
	local unlocked = unlockedByPlayer[player]
	local collected = collectedByPlayer[player]
	if not unlocked or not collected then
		return 0
	end
	local n = 0
	for key, on in unlocked do
		if on and collected[key] ~= true then
			n += 1
		end
	end
	return n
end

function M.tryCollect(player: Player, name: string, mutationId: string): number
	ensureMaps(player)
	if typeof(name) ~= "string" or name == "" then
		return 0
	end
	if typeof(mutationId) ~= "string" or not IndexConfig.TAB_DISPLAY_NAME[mutationId] then
		return 0
	end
	local key = IndexConfig.unlockKey(name, mutationId)
	local unlocked = unlockedByPlayer[player]
	local collected = collectedByPlayer[player]
	if not unlocked or not collected then
		return 0
	end
	if unlocked[key] ~= true then
		return 0
	end
	if collected[key] == true then
		return 0
	end
	collected[key] = true
	return IndexConfig.collectXpFor(rarityForEntry(name, mutationId), mutationId)
end

local function splitUnlockKey(key: string): (string?, string?)
	local last: number? = nil
	local i = 1
	while true do
		local found = string.find(key, ":", i, true)
		if not found then
			break
		end
		last = found
		i = found + 1
	end
	if not last then
		return nil, nil
	end
	return string.sub(key, 1, last - 1), string.sub(key, last + 1)
end

-- Claim every pending collect; returns total XP and how many entries were claimed.
function M.tryCollectAll(player: Player): (number, number)
	ensureMaps(player)
	local unlocked = unlockedByPlayer[player]
	local collected = collectedByPlayer[player]
	if not unlocked or not collected then
		return 0, 0
	end
	local total = 0
	local claimed = 0
	for key, on in unlocked do
		if on and collected[key] ~= true then
			local name, mutationId = splitUnlockKey(key)
			if typeof(name) == "string" and name ~= "" and typeof(mutationId) == "string" and IndexConfig.TAB_DISPLAY_NAME[mutationId] then
				collected[key] = true
				total += IndexConfig.collectXpFor(rarityForEntry(name, mutationId), mutationId)
				claimed += 1
			end
		end
	end
	return total, claimed
end

function M.collectedMap(player: Player): UnlockMap
	ensureMaps(player)
	local out: UnlockMap = {}
	local map = collectedByPlayer[player]
	if map then
		for k, v in map do
			if v then
				out[k] = true
			end
		end
	end
	return out
end

function M.buildCatalog(): { { name: string, rarity: string, baseIncome: number } }
	local out = {}
	for _, def in Brainrots.BRAINROTS do
		table.insert(out, {
			name = def.name,
			rarity = def.rarity,
			baseIncome = def.baseIncome,
		})
	end
	return out
end

function M.packLuckyBlockStateForClient(player: Player): {
	unlocked: { [string]: boolean },
	goldenCount: number,
	questComplete: boolean,
	catalog: {
		{
			name: string,
			displayName: string,
			rarity: string,
			baseIncome: number,
			icon: string,
			tier: number,
			dropsSummary: string,
			dropsMultiline: string,
			kind: string,
		}
	},
}
	local unlockMap = M.getUnlockMap(player)
	local unlocked: { [string]: boolean } = {}
	for k, v in unlockMap do
		if v then
			unlocked[k] = true
		end
	end
	local catalog = {}
	for _, def in LuckyBlockCatalog.BLOCKS do
		table.insert(catalog, {
			name = def.id,
			displayName = def.displayName,
			rarity = LuckyBlockCatalog.primaryDropRarity(def.id),
			baseIncome = 0,
			icon = M.getLuckyBlockIcon(def.id),
			tier = def.tier,
			dropsSummary = LuckyBlockCatalog.formatDropsSummary(def.id),
			dropsMultiline = LuckyBlockCatalog.formatDropsMultiline(def.id),
			kind = "luckyblock",
		})
	end
	return {
		unlocked = unlocked,
		collected = M.collectedMap(player),
		pendingCollectCount = M.pendingCollectCount(player),
		goldenCount = M.getGoldenCount(player),
		questComplete = player:GetAttribute("IndexGoldenQuestComplete") == true,
		catalog = catalog,
	}
end

function M.packStateForClient(
	player: Player,
	mutationId: string
): {
	unlocked: { [string]: boolean },
	goldenCount: number,
	questComplete: boolean,
	catalog: { { name: string, rarity: string, baseIncome: number, icon: string } },
}
	if mutationId == IndexConfig.LUCKY_BLOCK_TAB then
		return M.packLuckyBlockStateForClient(player)
	end
	local unlockMap = M.getUnlockMap(player)
	local unlocked: { [string]: boolean } = {}
	for k, v in unlockMap do
		if v then
			unlocked[k] = true
		end
	end
	local catalog = packedCatalogCache[mutationId]
	if not catalog then
		catalog = {}
		for _, def in M.buildCatalog() do
			table.insert(catalog, {
				name = def.name,
				rarity = def.rarity,
				baseIncome = def.baseIncome,
				icon = M.getIconFor(def.name, mutationId),
			})
		end
		packedCatalogCache[mutationId] = catalog
	end
	return {
		unlocked = unlocked,
		collected = M.collectedMap(player),
		pendingCollectCount = M.pendingCollectCount(player),
		goldenCount = M.getGoldenCount(player),
		questComplete = player:GetAttribute("IndexGoldenQuestComplete") == true,
		catalog = catalog,
	}
end

return M
