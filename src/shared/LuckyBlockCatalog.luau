-- [ACTIVE] LuckyBlockCatalog
--[[
	Single source of truth for lucky-block kinds:
	  • folder name under ReplicatedStorage["Lucky Blocks"]["lucky blocks"]
	  • default visual variant Model
	  • brainrot rarity roll weights when opened
	  • Index icon paths under ["Lucky Block Icons"].Normal / .Rainbow

	Rarity ids match Brainrots / StoreConfig steal tables.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type BlockDef = {
	id: string, -- folder / LuckyBlockKind
	variant: string?, -- child Model name (nil = first Model child)
	displayName: string,
	tier: number, -- 1 = weakest … higher = better (bush progression)
	drops: { [string]: number }, -- rarity → weight
	-- ReplicatedStorage["Lucky Blocks"]["Lucky Block Icons"].Normal[iconFolder]
	iconFolder: string?,
	-- Preferred child under that folder (base / non-mutation icon)
	iconChild: string?,
}

-- Ordered weak → strong. Each block has a clear main pool + a small jackpot
-- (usually ~3–8%) at the next rarity so opens stay rewarding without feeling identical.
local BLOCKS: { BlockDef } = {
	{
		id = "Starter Lucky Block",
		variant = "basic",
		displayName = "Starter Lucky Block",
		tier = 1,
		drops = { uncommon = 62, rare = 33, epic = 5 },
		iconFolder = "Starter Lucky Block",
		iconChild = "Basic Lucky Block",
	},
	{
		id = "troll",
		variant = "troll",
		displayName = "Troll Lucky Block",
		tier = 2,
		drops = { uncommon = 50, rare = 35, epic = 12, mythic = 3 },
		iconFolder = "Troll Lucky Block",
		iconChild = "Troll Lucky Block",
	},
	{
		id = "neon",
		variant = "neon",
		displayName = "Neon Lucky Block",
		tier = 3,
		drops = { rare = 58, epic = 37, mythic = 5 },
		iconFolder = "Neon Lucky Block",
		iconChild = "Neon Lucky Block",
	},
	{
		id = "1",
		variant = "1",
		displayName = "One Lucky Block",
		tier = 4,
		drops = { rare = 28, epic = 62, mythic = 8, legendary = 2 },
		iconFolder = "1 Lucky Block",
		iconChild = "1 Lucky Block",
	},
	{
		id = "Mythic Lucky Block",
		variant = "67",
		displayName = "Mythic Lucky Block",
		tier = 5,
		drops = { rare = 22, epic = 68, mythic = 10 },
		iconFolder = "Mythic Lucky Block",
		iconChild = "67 Lucky Block",
	},
	{
		id = "purple",
		variant = "purple",
		displayName = "Purple Lucky Block",
		tier = 6,
		drops = { epic = 58, mythic = 36, legendary = 6 },
		iconFolder = "Purple Lucky Block",
		iconChild = "Purple Lucky Block",
	},
	{
		id = "yellow",
		variant = "Yellow",
		displayName = "Yellow Lucky Block",
		tier = 7,
		drops = { epic = 30, mythic = 60, legendary = 10 },
		iconFolder = "Yellow Lucky Block",
		iconChild = "Yellow Lucky Block",
	},
	{
		id = "Godly Luckyblock",
		variant = "blue",
		displayName = "Godly Lucky Block",
		tier = 8,
		drops = { epic = 18, mythic = 70, legendary = 12 },
		iconFolder = "Godly Lucky Block",
		iconChild = "Blue Lucky Block",
	},
	{
		id = "heart",
		variant = "Heart",
		displayName = "Heart Lucky Block",
		tier = 9,
		drops = { mythic = 42, legendary = 48, ["brainrot god"] = 7, epic = 3 },
		iconFolder = "Heart Lucky Block",
		iconChild = "Heart Lucky Block",
	},
	{
		id = "chamber",
		variant = "chamber",
		displayName = "Chamber Lucky Block",
		tier = 10,
		drops = { mythic = 32, legendary = 50, ["brainrot god"] = 14, secret = 4 },
		iconFolder = "Latern Lucky Block",
		iconChild = "Latern Lucky Block",
	},
	{
		id = "rainbow",
		variant = "rainbow",
		displayName = "Rainbow Lucky Block",
		tier = 11,
		drops = { mythic = 18, legendary = 52, ["brainrot god"] = 24, secret = 6 },
		iconFolder = "Rainbow Lucky Block",
		iconChild = "Rainbow Lucky Block",
	},
	{
		id = "Secret Lucky Block",
		variant = "transparent",
		displayName = "Secret Lucky Block",
		tier = 12,
		drops = { legendary = 40, ["brainrot god"] = 35, secret = 18, mythic = 7 },
		iconFolder = "Secret Lucky Block",
		iconChild = "Transparent Lucky Block",
	},
	{
		id = "star",
		variant = "star rainbow",
		displayName = "Star Lucky Block",
		tier = 13,
		drops = { legendary = 22, ["brainrot god"] = 48, secret = 30 },
		iconFolder = "Star Lucky Block",
		iconChild = "Star Lucky Block",
	},
	{
		id = "ruby",
		variant = "red ruby",
		displayName = "Ruby Lucky Block",
		tier = 14,
		drops = { legendary = 15, ["brainrot god"] = 35, secret = 50 },
		iconFolder = "Lucky Block",
		iconChild = "Red Lucky Block",
	},
	{
		id = "1 opposite",
		variant = "1 opposite",
		displayName = "Opposite Lucky Block",
		tier = 15,
		drops = { ["brainrot god"] = 38, secret = 62 },
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

-- Highest-weight drop rarity — used for Index row accent styling.
function M.primaryDropRarity(id: string): string
	local def = byId[id]
	if not def then
		return "common"
	end
	local rows = sortedDropRows(def)
	if #rows == 0 then
		return "common"
	end
	return rows[1].name
end

local function readImageAsset(node: Instance?): string
	if not node then
		return ""
	end
	if node:IsA("ImageLabel") and node.Image ~= "" then
		return node.Image
	end
	if node:IsA("ImageButton") and node.Image ~= "" then
		return node.Image
	end
	local direct = node:FindFirstChildWhichIsA("ImageLabel") or node:FindFirstChildWhichIsA("ImageButton")
	if direct and (direct :: any).Image ~= "" then
		return (direct :: any).Image
	end
	for _, d in node:GetDescendants() do
		if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image ~= "" then
			return d.Image
		end
	end
	return ""
end

local function isMutationIconName(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "diamond", 1, true) == 1
		or string.find(lower, "galaxy", 1, true) == 1
		or string.find(lower, "golden", 1, true) == 1
end

local function resolveFromIconGroup(group: Instance, preferredNames: { string }): string
	for _, name in preferredNames do
		if name ~= "" then
			local child = group:FindFirstChild(name)
			if child then
				local tex = readImageAsset(child)
				if tex ~= "" then
					return tex
				end
			end
		end
	end
	-- Prefer any non-mutation child.
	for _, child in group:GetChildren() do
		if not isMutationIconName(child.Name) then
			local tex = readImageAsset(child)
			if tex ~= "" then
				return tex
			end
		end
	end
	-- Last resort: any image under the group (may be Golden/Diamond).
	return readImageAsset(group)
end

-- Resolves rbxassetid from Lucky Block Icons (Normal first, then Rainbow).
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
	if def and typeof(def.variant) == "string" then
		table.insert(preferred, def.variant .. " Lucky Block")
		table.insert(preferred, def.variant)
	end

	-- Rainbow folder often uses variant names (Basic / 67 / Blue / Transparent).
	local rainbowFolderAliases: { string } = { folderName }
	if def and def.iconChild then
		table.insert(rainbowFolderAliases, 1, def.iconChild)
	end
	if blockId == "Starter Lucky Block" then
		table.insert(rainbowFolderAliases, 1, "Basic Lucky Block")
	elseif blockId == "Mythic Lucky Block" then
		table.insert(rainbowFolderAliases, 1, "67 Lucky Block")
	elseif blockId == "Godly Luckyblock" then
		table.insert(rainbowFolderAliases, 1, "Blue Lucky Block")
	elseif blockId == "Secret Lucky Block" then
		table.insert(rainbowFolderAliases, 1, "Transparent Lucky Block")
	end

	for _, styleName in { "Normal", "Rainbow" } do
		local style = icons:FindFirstChild(styleName)
		if not style then
			continue
		end
		local aliases = if styleName == "Rainbow" then rainbowFolderAliases else { folderName }
		for _, alias in aliases do
			local group = style:FindFirstChild(alias)
			if group then
				local tex = resolveFromIconGroup(group, preferred)
				if tex ~= "" then
					return tex
				end
			end
		end
	end

	return ""
end

return M
