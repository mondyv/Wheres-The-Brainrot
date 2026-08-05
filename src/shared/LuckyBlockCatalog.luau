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

-- Ordered weak → strong. Each block has a clear main pool + a small jackpot
-- (usually ~3–8%) at the next rarity so opens stay rewarding without feeling identical.
local BLOCKS: { BlockDef } = {
	{
		id = "Starter Lucky Block",
		variant = "basic",
		displayName = "Starter Lucky Block",
		tier = 1,
		-- Mostly uncommon; rare common; tiny epic jackpot.
		drops = { uncommon = 62, rare = 33, epic = 5 },
	},
	{
		id = "troll",
		variant = "troll",
		displayName = "Troll Lucky Block",
		tier = 2,
		-- Chaotic low pool: uncommon heavy, then rare, small epic, tiny mythic.
		drops = { uncommon = 50, rare = 35, epic = 12, mythic = 3 },
	},
	{
		id = "neon",
		variant = "neon",
		displayName = "Neon Lucky Block",
		tier = 3,
		-- Rare-first opener into epic; tiny mythic.
		drops = { rare = 58, epic = 37, mythic = 5 },
	},
	{
		id = "1",
		variant = "1",
		displayName = "One Lucky Block",
		tier = 4,
		-- Epic-first (flip of Neon); tiny mythic + razor legendary.
		drops = { rare = 28, epic = 62, mythic = 8, legendary = 2 },
	},
	{
		id = "Mythic Lucky Block",
		variant = "67",
		displayName = "Mythic Lucky Block",
		tier = 5,
		-- Epic workhorse with a real mythic tease.
		drops = { rare = 22, epic = 68, mythic = 10 },
	},
	{
		id = "purple",
		variant = "purple",
		displayName = "Purple Lucky Block",
		tier = 6,
		-- Epic → mythic bridge; small legendary.
		drops = { epic = 58, mythic = 36, legendary = 6 },
	},
	{
		id = "yellow",
		variant = "Yellow",
		displayName = "Yellow Lucky Block",
		tier = 7,
		-- Mythic-leaning (unlike Purple); better legendary tease.
		drops = { epic = 30, mythic = 60, legendary = 10 },
	},
	{
		id = "Godly Luckyblock",
		variant = "blue",
		displayName = "Godly Lucky Block",
		tier = 8,
		-- Mythic main; leftover epic; solid legendary jackpot.
		drops = { epic = 18, mythic = 70, legendary = 12 },
	},
	{
		id = "heart",
		variant = "Heart",
		displayName = "Heart Lucky Block",
		tier = 9,
		-- Legendary enters the main pool; tiny brainrot god.
		drops = { mythic = 42, legendary = 48, ["brainrot god"] = 7, epic = 3 },
	},
	{
		id = "chamber",
		variant = "chamber",
		displayName = "Chamber Lucky Block",
		tier = 10,
		-- Legendary + mythic; brainrot god secondary; tiny secret.
		drops = { mythic = 32, legendary = 50, ["brainrot god"] = 14, secret = 4 },
	},
	{
		id = "rainbow",
		variant = "rainbow",
		displayName = "Rainbow Lucky Block",
		tier = 11,
		-- God-leaning vs Chamber; still mostly legendary.
		drops = { mythic = 18, legendary = 52, ["brainrot god"] = 24, secret = 6 },
	},
	{
		id = "Secret Lucky Block",
		variant = "transparent",
		displayName = "Secret Lucky Block",
		tier = 12,
		-- First block where secret is a real outcome (not just a tease).
		drops = { legendary = 40, ["brainrot god"] = 35, secret = 18, mythic = 7 },
	},
	{
		id = "star",
		variant = "star rainbow",
		displayName = "Star Lucky Block",
		tier = 13,
		-- Brainrot god primary; secret strong; less legendary filler.
		drops = { legendary = 22, ["brainrot god"] = 48, secret = 30 },
	},
	{
		id = "ruby",
		variant = "red ruby",
		displayName = "Ruby Lucky Block",
		tier = 14,
		-- Secret hunter (flip of Star's god focus).
		drops = { legendary = 15, ["brainrot god"] = 35, secret = 50 },
	},
	{
		id = "1 opposite",
		variant = "1 opposite",
		displayName = "Opposite Lucky Block",
		tier = 15,
		-- Top end only: secret-heavy with brainrot god.
		drops = { ["brainrot god"] = 38, secret = 62 },
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

return M
