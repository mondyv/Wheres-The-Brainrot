-- [ACTIVE] IndexService
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local IndexConfig = require(ReplicatedStorage.Shared.IndexConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))

local M = {}

type UnlockMap = { [string]: boolean }

local unlockedByPlayer: { [Player]: UnlockMap } = {}
local goldenNamesByPlayer: { [Player]: { [string]: boolean } } = {}

local brainrotsFolder: Folder? = nil

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
	for _, d in model:GetDescendants() do
		if d:IsA("ImageLabel") and d.Image ~= "" then
			return d.Image
		end
	end
	return ""
end

function M.getIconFor(brainrotName: string, mutationId: string): string
	local template = findVariantTemplate(brainrotName, mutationId)
	if template then
		local icon = pickIconFromModel(template)
		if icon ~= "" then
			return icon
		end
	end
	local fallback = findVariantTemplate(brainrotName, "normal")
	if fallback then
		return pickIconFromModel(fallback)
	end
	return ""
end

local function ensureMaps(player: Player)
	if not unlockedByPlayer[player] then
		unlockedByPlayer[player] = {}
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

function M.importUnlocks(player: Player, unlockKeys: { string }, goldenNames: { string })
	ensureMaps(player)
	local map: UnlockMap = {}
	for _, key in unlockKeys do
		if typeof(key) == "string" and key ~= "" then
			map[key] = true
		end
	end
	unlockedByPlayer[player] = map

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

function M.packStateForClient(
	player: Player,
	mutationId: string
): {
	unlocked: { [string]: boolean },
	goldenCount: number,
	questComplete: boolean,
	catalog: { { name: string, rarity: string, baseIncome: number, icon: string } },
}
	local unlockMap = M.getUnlockMap(player)
	local unlocked: { [string]: boolean } = {}
	for k, v in unlockMap do
		if v then
			unlocked[k] = true
		end
	end
	local catalog = {}
	for _, def in M.buildCatalog() do
		table.insert(catalog, {
			name = def.name,
			rarity = def.rarity,
			baseIncome = def.baseIncome,
			icon = M.getIconFor(def.name, mutationId),
		})
	end
	return {
		unlocked = unlocked,
		goldenCount = M.getGoldenCount(player),
		questComplete = player:GetAttribute("IndexGoldenQuestComplete") == true,
		catalog = catalog,
	}
end

return M
