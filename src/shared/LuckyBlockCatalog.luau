-- [ACTIVE] LuckyBlockCatalog
--[[
	Single source of truth for lucky-block kinds:
	  • folder name under ReplicatedStorage["Lucky Blocks"]["lucky blocks"]
	  • default visual variant Model
	  • brainrot rarity roll weights when opened

	Rarity ids match Brainrots / StoreConfig steal tables.
]]

local M = {}

export type BlockDef = {
	id: string, -- folder / LuckyBlockKind
	variant: string?, -- child Model name (nil = first Model child)
	displayName: string,
	tier: number, -- 1 = weakest … higher = better (bush progression)
	drops: { [string]: number }, -- rarity → weight
}

-- Ordered weak → strong for docs / admin lists.
M.BLOCKS: { BlockDef } = {
	{
		id = "Starter Lucky Block",
		variant = "basic",
		displayName = "Starter Lucky Block",
		tier = 1,
		drops = { uncommon = 60, rare = 40 },
	},
	{
		id = "troll",
		variant = "troll",
		displayName = "Troll Lucky Block",
		tier = 2,
		drops = { uncommon = 45, rare = 45, epic = 10 },
	},
	{
		id = "neon",
		variant = "neon",
		displayName = "Neon Lucky Block",
		tier = 3,
		drops = { rare = 55, epic = 45 },
	},
	{
		id = "1",
		variant = "1",
		displayName = "One Lucky Block",
		tier = 4,
		drops = { rare = 45, epic = 55 },
	},
	{
		id = "Mythic Lucky Block",
		variant = "67",
		displayName = "Mythic Lucky Block",
		tier = 5,
		drops = { rare = 35, epic = 65 },
	},
	{
		id = "purple",
		variant = "purple",
		displayName = "Purple Lucky Block",
		tier = 6,
		drops = { epic = 55, mythic = 45 },
	},
	{
		id = "yellow",
		variant = "Yellow",
		displayName = "Yellow Lucky Block",
		tier = 7,
		drops = { epic = 45, mythic = 55 },
	},
	{
		id = "Godly Luckyblock",
		variant = "blue",
		displayName = "Godly Lucky Block",
		tier = 8,
		drops = { epic = 35, mythic = 65 },
	},
	{
		id = "heart",
		variant = "Heart",
		displayName = "Heart Lucky Block",
		tier = 9,
		drops = { epic = 20, mythic = 50, legendary = 30 },
	},
	{
		id = "chamber",
		variant = "chamber",
		displayName = "Chamber Lucky Block",
		tier = 10,
		drops = { mythic = 40, legendary = 45, ["brainrot god"] = 15 },
	},
	{
		id = "rainbow",
		variant = "rainbow",
		displayName = "Rainbow Lucky Block",
		tier = 11,
		drops = { mythic = 30, legendary = 50, ["brainrot god"] = 20 },
	},
	{
		id = "Secret Lucky Block",
		variant = "transparent",
		displayName = "Secret Lucky Block",
		tier = 12,
		drops = { mythic = 25, legendary = 45, ["brainrot god"] = 20, secret = 10 },
	},
	{
		id = "star",
		variant = "star rainbow",
		displayName = "Star Lucky Block",
		tier = 13,
		drops = { legendary = 35, ["brainrot god"] = 40, secret = 25 },
	},
	{
		id = "ruby",
		variant = "red ruby",
		displayName = "Ruby Lucky Block",
		tier = 14,
		drops = { legendary = 25, ["brainrot god"] = 40, secret = 35 },
	},
	{
		id = "1 opposite",
		variant = "1 opposite",
		displayName = "Opposite Lucky Block",
		tier = 15,
		drops = { ["brainrot god"] = 45, secret = 55 },
	},
}

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

function M.formatDropsSummary(id: string): string
	local def = byId[id]
	if not def then
		return "?"
	end
	local parts: { string } = {}
	local total = 0
	for _, w in def.drops do
		total += w
	end
	if total <= 0 then
		return "?"
	end
	-- Stable-ish order by weight desc.
	local rows: { { name: string, w: number } } = {}
	for name, w in def.drops do
		table.insert(rows, { name = name, w = w })
	end
	table.sort(rows, function(a, b)
		if a.w ~= b.w then
			return a.w > b.w
		end
		return a.name < b.name
	end)
	for _, row in rows do
		local pct = math.floor((row.w / total) * 100 + 0.5)
		table.insert(parts, string.format("%s %d%%", row.name, pct))
	end
	return table.concat(parts, ", ")
end

return M
