-- [ACTIVE] LuckyBlockCatalog
--[[
	Single source of truth for lucky-block kinds:
	  • folder name under ReplicatedStorage["Lucky Blocks"]["lucky blocks"]
	  • default visual variant Model
	  • brainrot rarity roll weights when opened
	  • Index rarity accent (indexRarity) — matches block identity / color, not
	    necessarily the single highest drop weight
	  • Index icon paths under ["Lucky Block Icons"].Normal only
	    (do not use .Rainbow or Golden/Galaxy/Diamond variants for the base icon)

	Rarity ids match Brainrots / StoreConfig steal tables.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type BlockDef = {
	id: string, -- folder / LuckyBlockKind
	variant: string?, -- child Model name (nil = first Model child)
	displayName: string,
	tier: number, -- 1 = weakest … higher = better (bush progression)
	-- Index / UI rarity color (must match BrainrotHeaderStyle keys).
	indexRarity: string,
	drops: { [string]: number }, -- rarity → weight
	-- ReplicatedStorage["Lucky Blocks"]["Lucky Block Icons"].Normal[iconFolder]
	iconFolder: string?,
	-- Preferred child under that folder (base / non-mutation icon).
	-- Nil when Studio has no base child (only Golden/Galaxy/Diamond variants).
	iconChild: string?,
}

-- Ordered weak → strong. Visuals / indexRarity align with rarity colors:
-- uncommon → starter/troll, rare → neon, epic → purple/1, mythic → 67,
-- legendary → yellow/heart, godly → blue, secret → transparent/star/ruby…
local BLOCKS: { BlockDef } = {
	{
		id = "Starter Lucky Block",
		variant = "basic",
		displayName = "Starter Lucky Block",
		tier = 1,
		indexRarity = "uncommon",
		drops = { uncommon = 62, rare = 33, epic = 5 },
		iconFolder = "Starter Lucky Block",
		-- Studio only has Golden/Galaxy/Diamond Basic children — use folder image / model fallback.
		iconChild = nil,
	},
	{
		id = "troll",
		variant = "troll",
		displayName = "Troll Lucky Block",
		tier = 2,
		indexRarity = "uncommon",
		drops = { uncommon = 50, rare = 35, epic = 12, mythic = 3 },
		iconFolder = "Troll Lucky Block",
		iconChild = "Troll Lucky Block",
	},
	{
		id = "neon",
		variant = "neon",
		displayName = "Neon Lucky Block",
		tier = 3,
		indexRarity = "rare",
		drops = { rare = 58, epic = 37, mythic = 5 },
		iconFolder = "Neon Lucky Block",
		iconChild = "Neon Lucky Block",
	},
	{
		id = "1",
		variant = "1",
		displayName = "One Lucky Block",
		tier = 4,
		indexRarity = "epic",
		drops = { rare = 22, epic = 62, mythic = 14, legendary = 2 },
		iconFolder = "1 Lucky Block",
		iconChild = "1 Lucky Block",
	},
	{
		id = "Mythic Lucky Block",
		variant = "67",
		displayName = "Mythic Lucky Block",
		tier = 5,
		indexRarity = "mythic",
		-- Named mythic → mythic-primary pool (was epic-heavy before).
		drops = { epic = 18, mythic = 70, legendary = 12 },
		iconFolder = "Mythic Lucky Block",
		-- Studio: Golden/Galaxy/Diamond 67 only (no base "67 Lucky Block").
		iconChild = nil,
	},
	{
		id = "purple",
		variant = "purple",
		displayName = "Purple Lucky Block",
		tier = 6,
		indexRarity = "epic",
		drops = { epic = 58, mythic = 36, legendary = 6 },
		iconFolder = "Purple Lucky Block",
		iconChild = "Purple Lucky Block",
	},
	{
		id = "yellow",
		variant = "Yellow",
		displayName = "Yellow Lucky Block",
		tier = 7,
		indexRarity = "legendary",
		drops = { epic = 18, mythic = 42, legendary = 40 },
		iconFolder = "Yellow Lucky Block",
		iconChild = "Yellow Lucky Block",
	},
	{
		-- Blue cube = godly tier (not uncommon).
		id = "Godly Luckyblock",
		variant = "blue",
		displayName = "Godly Lucky Block",
		tier = 8,
		indexRarity = "brainrot god",
		drops = { mythic = 22, legendary = 33, ["brainrot god"] = 45 },
		iconFolder = "Godly Lucky Block",
		-- Studio: Golden/Galaxy/Diamond Blue only (no base "Blue Lucky Block").
		iconChild = nil,
	},
	{
		id = "heart",
		variant = "Heart",
		displayName = "Heart Lucky Block",
		tier = 9,
		indexRarity = "legendary",
		drops = { mythic = 35, legendary = 52, ["brainrot god"] = 10, epic = 3 },
		iconFolder = "Heart Lucky Block",
		iconChild = "Heart Lucky Block",
	},
	{
		id = "chamber",
		variant = "chamber",
		displayName = "Chamber Lucky Block",
		tier = 10,
		indexRarity = "brainrot god",
		drops = { mythic = 28, legendary = 42, ["brainrot god"] = 24, secret = 6 },
		iconFolder = "Latern Lucky Block",
		iconChild = "Latern Lucky Block",
	},
	{
		id = "rainbow",
		variant = "rainbow",
		displayName = "Rainbow Lucky Block",
		tier = 11,
		indexRarity = "brainrot god",
		drops = { mythic = 16, legendary = 40, ["brainrot god"] = 36, secret = 8 },
		iconFolder = "Rainbow Lucky Block",
		iconChild = "Rainbow Lucky Block",
	},
	{
		id = "Secret Lucky Block",
		variant = "transparent",
		displayName = "Secret Lucky Block",
		tier = 12,
		indexRarity = "secret",
		drops = { legendary = 28, ["brainrot god"] = 32, secret = 40 },
		iconFolder = "Secret Lucky Block",
		iconChild = "Transparent Lucky Block",
	},
	{
		id = "star",
		variant = "star",
		displayName = "Star Lucky Block",
		tier = 13,
		indexRarity = "secret",
		drops = { legendary = 18, ["brainrot god"] = 42, secret = 40 },
		iconFolder = "Star Lucky Block",
		iconChild = "Star Lucky Block",
	},
	{
		id = "ruby",
		variant = "red ruby",
		displayName = "Ruby Lucky Block",
		tier = 14,
		indexRarity = "secret",
		drops = { legendary = 12, ["brainrot god"] = 33, secret = 55 },
		iconFolder = "Lucky Block",
		iconChild = "Red Lucky Block",
	},
	{
		id = "1 opposite",
		variant = "1 opposite",
		displayName = "Opposite Lucky Block",
		tier = 15,
		indexRarity = "secret",
		drops = { ["brainrot god"] = 35, secret = 65 },
		iconFolder = "Opposite Lucky Block",
		iconChild = "Opposite Lucky Block",
	},
}

M.BLOCKS = BLOCKS

local byId: { [string]: BlockDef } = {}
for _, def in M.BLOCKS do
	byId[def.id] = def
end

function M.get(id: string): BlockDef?
	return byId[id]
end

function M.allIds(): { string }
	local out: { string } = {}
	for _, def in M.BLOCKS do
		table.insert(out, def.id)
	end
	return out
end

function M.rarityWeightsById(): { [string]: { [string]: number } }
	local out: { [string]: { [string]: number } } = {}
	for _, def in M.BLOCKS do
		out[def.id] = def.drops
	end
	-- Legacy alias used by older grant paths / star rainbow tool.
	out["star rainbow"] = byId["star"] and byId["star"].drops or { legendary = 50, ["brainrot god"] = 50 }
	return out
end

function M.defaultVariant(id: string): string?
	local def = byId[id]
	return if def then def.variant else nil
end

function M.displayName(id: string): string
	local def = byId[id]
	return if def then def.displayName else id
end

local function sortedDropRows(def: BlockDef): { { name: string, w: number, pct: number } }
	local total = 0
	for _, w in def.drops do
		total += w
	end
	local rows: { { name: string, w: number, pct: number } } = {}
	if total <= 0 then
		return rows
	end
	for name, w in def.drops do
		table.insert(rows, {
			name = name,
			w = w,
			pct = math.floor((w / total) * 100 + 0.5),
		})
	end
	table.sort(rows, function(a, b)
		if a.w ~= b.w then
			return a.w > b.w
		end
		return a.name < b.name
	end)
	return rows
end

function M.formatDropsSummary(id: string): string
	local def = byId[id]
	if not def then
		return "?"
	end
	local parts: { string } = {}
	for _, row in sortedDropRows(def) do
		table.insert(parts, string.format("%s %d%%", row.name, row.pct))
	end
	if #parts == 0 then
		return "?"
	end
	return table.concat(parts, ", ")
end

function M.formatDropsMultiline(id: string): string
	local def = byId[id]
	if not def then
		return "?"
	end
	local parts: { string } = { "Drops:" }
	for _, row in sortedDropRows(def) do
		table.insert(parts, string.format("• %s  %d%%", row.name, row.pct))
	end
	if #parts == 1 then
		return "?"
	end
	return table.concat(parts, "\n")
end

-- Index / UI rarity accent for this block (explicit), falling back to top drop weight.
function M.primaryDropRarity(id: string): string
	local def = byId[id]
	if not def then
		return "common"
	end
	if typeof(def.indexRarity) == "string" and def.indexRarity ~= "" then
		return def.indexRarity
	end
	local rows = sortedDropRows(def)
	if #rows == 0 then
		return "common"
	end
	return rows[1].name
end

local GENERIC_IMAGE_NAMES: { [string]: boolean } = {
	imagelabel = true,
	imagebutton = true,
	image = true,
}

local function isMutationIconName(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "diamond", 1, true) ~= nil
		or string.find(lower, "galaxy", 1, true) ~= nil
		or string.find(lower, "golden", 1, true) ~= nil
end

local function isGenericImageName(name: string): boolean
	return GENERIC_IMAGE_NAMES[string.lower(name)] == true
end

local function findChildIgnoreCase(parent: Instance, name: string): Instance?
	local exact = parent:FindFirstChild(name)
	if exact then
		return exact
	end
	local want = string.lower(name)
	for _, child in parent:GetChildren() do
		if string.lower(child.Name) == want then
			return child
		end
	end
	return nil
end

local PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

local function isUsableImage(img: string?): boolean
	if typeof(img) ~= "string" or img == "" then
		return false
	end
	if img == PLACEHOLDER_IMAGE or img == "rbxassetid://0" then
		return false
	end
	return true
end

local function textureFromNode(node: Instance): string
	if node:IsA("ImageLabel") or node:IsA("ImageButton") then
		local img = (node :: ImageLabel).Image
		if isUsableImage(img) then
			return img
		end
	elseif node:IsA("Decal") or node:IsA("Texture") then
		local tex = (node :: Decal).Texture
		if isUsableImage(tex) then
			return tex
		end
	elseif node:IsA("MeshPart") then
		local tex = (node :: MeshPart).TextureID
		if isUsableImage(tex) then
			return tex
		end
	end
	return ""
end

-- Named node, then non-mutation descendants (Studio often nests ImageLabel → Mesh).
local function readNamedIcon(node: Instance?): string
	if not node then
		return ""
	end
	local direct = textureFromNode(node)
	if direct ~= "" then
		return direct
	end
	for _, child in node:GetChildren() do
		if isMutationIconName(child.Name) then
			continue
		end
		local tex = textureFromNode(child)
		if tex ~= "" then
			return tex
		end
		for _, desc in child:GetDescendants() do
			if isMutationIconName(desc.Name) then
				continue
			end
			tex = textureFromNode(desc)
			if tex ~= "" then
				return tex
			end
		end
	end
	for _, desc in node:GetDescendants() do
		if isMutationIconName(desc.Name) then
			continue
		end
		local tex = textureFromNode(desc)
		if tex ~= "" then
			return tex
		end
	end
	return ""
end

local function resolveFromIconGroup(group: Instance, preferredNames: { string }): string
	for _, name in preferredNames do
		if name ~= "" then
			local child = findChildIgnoreCase(group, name)
			if child then
				local tex = readNamedIcon(child)
				if tex ~= "" then
					return tex
				end
			end
		end
	end

	-- Many folders ARE the base ImageLabel, with Golden/Galaxy/Diamond as extra children.
	local selfTex = readNamedIcon(group)
	if selfTex ~= "" and (group:IsA("ImageLabel") or group:IsA("ImageButton")) then
		return selfTex
	end

	for _, child in group:GetChildren() do
		if isGenericImageName(child.Name) or isMutationIconName(child.Name) then
			continue
		end
		local tex = readNamedIcon(child)
		if tex ~= "" then
			return tex
		end
	end
	return ""
end

-- Resolves rbxassetid from Lucky Block Icons.Normal only (Studio source of truth).
function M.resolveIconAssetId(blockId: string): string
	local def = byId[blockId]
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	local icons = root and root:FindFirstChild("Lucky Block Icons")
	if not icons then
		return ""
	end

	local folderName = if def and def.iconFolder then def.iconFolder elseif def then def.displayName else blockId
	local preferred: { string } = {}
	if def and def.iconChild then
		table.insert(preferred, def.iconChild)
	end
	if def and def.displayName then
		table.insert(preferred, def.displayName)
	end
	table.insert(preferred, folderName)

	local style = findChildIgnoreCase(icons, "Normal")
	if not style then
		return ""
	end
	local group = findChildIgnoreCase(style, folderName)
	if not group then
		return ""
	end
	return resolveFromIconGroup(group, preferred)
end

return M
