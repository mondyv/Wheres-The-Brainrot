-- [ACTIVE] GearConfig
-- Workout gear catalog (Upgrades panel + tools + Robux products).
local M = {}

export type GearDef = {
	id: number,
	name: string,
	rarity: string, -- common | uncommon | rare | epic | mythic | legendary | godly
	weightLbs: number,
	powerGain: number, -- Power added per workout second
	cashPrice: number,
	robuxProductId: number?, -- nil = cash only
	assetName: string, -- ReplicatedStorage.EssentialAssets.Gears["Gear N"]
}

-- Cash prices: Gear 1 affordable with tutorial $500; rest scale with power gain.
local GEARS: { GearDef } = {
	{
		id = 1,
		name = "Tree Branch",
		rarity = "common",
		weightLbs = 5,
		powerGain = 2,
		cashPrice = 100,
		robuxProductId = nil,
		assetName = "Gear 1",
	},
	{
		id = 2,
		name = "Stone Dumbbell",
		rarity = "common",
		weightLbs = 10,
		powerGain = 5,
		cashPrice = 500,
		robuxProductId = 3696509712,
		assetName = "Gear 2",
	},
	{
		id = 3,
		name = "Ancient Dumbbell",
		rarity = "common",
		weightLbs = 45,
		powerGain = 10,
		cashPrice = 2_500,
		robuxProductId = 3696515436,
		assetName = "Gear 3",
	},
	{
		id = 4,
		name = "Star Dumbbell",
		rarity = "uncommon",
		weightLbs = 135,
		powerGain = 50,
		cashPrice = 12_500,
		robuxProductId = 3696519931,
		assetName = "Gear 4",
	},
	{
		id = 5,
		name = "Plate",
		rarity = "uncommon",
		weightLbs = 225,
		powerGain = 150,
		cashPrice = 50_000,
		robuxProductId = 3696524705,
		assetName = "Gear 5",
	},
	{
		id = 6,
		name = "Rainbow Dumbbell",
		rarity = "rare",
		weightLbs = 450,
		powerGain = 400,
		cashPrice = 250_000,
		robuxProductId = 3696529600,
		assetName = "Gear 6",
	},
	{
		id = 7,
		name = "Galaxy Dumbbell",
		rarity = "rare",
		weightLbs = 900,
		powerGain = 1000,
		cashPrice = 1_250_000,
		robuxProductId = 3696533697,
		assetName = "Gear 7",
	},
	{
		id = 8,
		name = "Purple Orb Dumbbell",
		rarity = "rare",
		weightLbs = 1800,
		powerGain = 2500,
		cashPrice = 6_000_000,
		robuxProductId = 3696552109,
		assetName = "Gear 8",
	},
	{
		id = 9,
		name = "Red Orb Dumbbell",
		rarity = "epic",
		weightLbs = 4500,
		powerGain = 6250,
		cashPrice = 30_000_000,
		robuxProductId = 3696556426,
		assetName = "Gear 9",
	},
	{
		id = 10,
		name = "Black Holes Dumbbell",
		rarity = "epic",
		weightLbs = 9000,
		powerGain = 15000,
		cashPrice = 150_000_000,
		robuxProductId = 3696577307,
		assetName = "Gear 10",
	},
	{
		id = 11,
		name = "Lava Planets Dumbbell",
		rarity = "mythic",
		weightLbs = 22500,
		powerGain = 40000,
		cashPrice = 750_000_000,
		robuxProductId = 3696561899,
		assetName = "Gear 11",
	},
	{
		id = 12,
		name = "Moon",
		rarity = "legendary",
		weightLbs = 99999,
		powerGain = 100000,
		cashPrice = 4_000_000_000,
		robuxProductId = 3696581519,
		assetName = "Gear 12",
	},
	{
		id = 13,
		name = "Jupiter",
		rarity = "godly",
		weightLbs = 425000,
		powerGain = 300000,
		cashPrice = 20_000_000_000,
		robuxProductId = 3696584468,
		assetName = "Gear 13",
	},
}

M.GEARS = GEARS
M.WORKOUT_IMAGE = "rbxassetid://73088512205933"
M.WORKOUT_ANIMATION_ID = "rbxassetid://118202501576957"
M.GEAR_TOOL_ATTR = "WorkoutGearTool"
M.GEAR_ID_ATTR = "WorkoutGearId"
M.OWNED_GEARS_ATTR = "OwnedGears" -- comma-separated ids e.g. "1,3,5"
M.EQUIPPED_GEAR_ATTR = "EquippedGearId"
M.POWER_ATTR = "Power"
M.POWER_EDITED_ATTR = "PowerEdited"
M.WORKOUT_ACTIVE_ATTR = "WorkoutActive"

local byId: { [number]: GearDef } = {}
local byProduct: { [number]: GearDef } = {}
for _, g in M.GEARS do
	byId[g.id] = g
	if g.robuxProductId then
		byProduct[g.robuxProductId] = g
	end
end

function M.get(id: number): GearDef?
	return byId[id]
end

function M.getByProductId(productId: number): GearDef?
	return byProduct[productId]
end

function M.allProductIds(): { number }
	local out: { number } = {}
	for _, g in M.GEARS do
		if g.robuxProductId then
			table.insert(out, g.robuxProductId)
		end
	end
	return out
end

function M.parseOwned(raw: any): { [number]: boolean }
	local set: { [number]: boolean } = {}
	if typeof(raw) ~= "string" or raw == "" then
		return set
	end
	for token in string.gmatch(raw, "[^,%s]+") do
		local n = tonumber(token)
		if n and byId[n] then
			set[n] = true
		end
	end
	return set
end

function M.encodeOwned(set: { [number]: boolean }): string
	local ids: { number } = {}
	for id in set do
		if byId[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, tostring(id))
	end
	return table.concat(parts, ",")
end

function M.isUnlocked(gearId: number, owned: { [number]: boolean }): boolean
	if gearId <= 1 then
		return true
	end
	return owned[gearId - 1] == true
end

function M.rarityDisplay(rarity: string): string
	local r = string.lower(rarity)
	if r == "mythic" then
		return "Mythical"
	end
	return string.upper(string.sub(r, 1, 1)) .. string.lower(string.sub(r, 2))
end

return M
