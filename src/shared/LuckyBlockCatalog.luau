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
-- Each pool keeps its main tiers, plus a small jackpot chance (~3–8%) one step up.
M.BLOCKS: { BlockDef } = {
	{
		id = "Starter Lucky Block",
		variant = "basic",
		displayName = "Starter Lucky Block",
		tier = 1,
		drops = { uncommon = 57, rare = 38, epic = 5 },
	},
	{
		id = "troll",
		variant = "troll",
		displayName = "Troll Lucky Block",
		tier = 2,
		drops = { uncommon = 42, rare = 42, epic = 12, mythic = 4 },
	},
	{
		id = "neon",
		variant = "neon",
		displayName = "Neon Lucky Block",
		tier = 3,
		drops = { rare = 52, epic = 42, mythic = 6 },
	},
	{
		id = "1",
		variant = "1",
		displayName = "One Lucky Block",
		tier = 4,
		drops = { rare = 42, epic = 52, mythic = 6 },
	},
	{
		id = "Mythic Lucky Block",
		variant = "67",
		displayName = "Mythic Lucky Block",
		tier = 5,
		drops = { rare = 32, epic = 60, mythic = 8 },
	},
	{
		id = "purple",
		variant = "purple",
		displayName = "Purple Lucky Block",
		tier = 6,
		drops = { epic = 52, mythic = 42, legendary = 6 },
	},
	{
		id = "yellow",
		variant = "Yellow",
		displayName = "Yellow Lucky Block",
		tier = 7,
		drops = { epic = 42, mythic = 52, legendary = 6 },
	},
	{
		id = "Godly Luckyblock",
		variant = "blue",
		displayName = "Godly Lucky Block",
		tier = 8,
		drops = { epic = 32, mythic = 60, legendary = 8 },
	},
	{
		id = "heart",
		variant = "Heart",
		displayName = "Heart Lucky Block",
		tier = 9,
		drops = { epic = 18, mythic = 48, legendary = 28, ["brainrot god"] = 6 },
	},
	{
		id = "chamber",
		variant = "chamber",
		displayName = "Chamber Lucky Block",
		tier = 10,
		drops = { mythic = 38, legendary = 42, ["brainrot god"] = 15, secret = 5 },
	},
	{
		id = "rainbow",
		variant = "rainbow",
		displayName = "Rainbow Lucky Block",
		tier = 11,
		drops = { mythic = 28, legendary = 47, ["brainrot god"] = 20, secret = 5 },
	},
	{
		id = "Secret Lucky Block",
		variant = "transparent",
		displayName = "Secret Lucky Block",
		tier = 12,
		drops = { mythic = 22, legendary = 42, ["brainrot god"] = 22, secret = 14 },
	},
	{
		id = "star",
		variant = "star rainbow",
		displayName = "Star Lucky Block",
		tier = 13,
		drops = { legendary = 32, ["brainrot god"] = 38, secret = 30 },
	},
	{
		id = "ruby",
		variant = "red ruby",
		displayName = "Ruby Lucky Block",
		tier = 14,
		drops = { legendary = 22, ["brainrot god"] = 40, secret = 38 },
	},
	{
		id = "1 opposite",
		variant = "1 opposite",
		displayName = "Opposite Lucky Block",
		tier = 15,
		drops = { ["brainrot god"] = 42, secret = 58 },
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
