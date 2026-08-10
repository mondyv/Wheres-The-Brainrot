-- [ACTIVE] GearConfig
-- Workout gear catalog (Upgrades panel + tools + Robux products).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type GearDef = {
	id: number,
	name: string,
	rarity: string, -- common | uncommon | rare | epic | mythic | legendary | godly
	weightLbs: number,
	powerGain: number, -- Power added per workout second
	cashPrice: number,
	robuxPrice: number?, -- display Robux cost (developer product priced in dashboard)
	robuxProductId: number?, -- nil = cash only
	assetName: string, -- ReplicatedStorage.EssentialAssets.Gears["Gear N"]
}

local GEARS: { GearDef } = {
	{
		id = 1,
		name = "Tree Branch",
		rarity = "common",
		weightLbs = 5,
		powerGain = 2,
		cashPrice = 500,
		robuxPrice = nil,
		robuxProductId = nil,
		assetName = "Gear 1",
	},
	{
		id = 2,
		name = "Stone Dumbbell",
		rarity = "common",
		weightLbs = 10,
		powerGain = 5,
		cashPrice = 45_000,
		robuxPrice = 9,
		robuxProductId = 3696509712,
		assetName = "Gear 2",
	},
	{
		id = 3,
		name = "Ancient Dumbbell",
		rarity = "common",
		weightLbs = 45,
		powerGain = 10,
		cashPrice = 75_000,
		robuxPrice = 19,
		robuxProductId = 3696515436,
		assetName = "Gear 3",
	},
	{
		id = 4,
		name = "Star Dumbbell",
		rarity = "uncommon",
		weightLbs = 135,
		powerGain = 50,
		cashPrice = 1_500_000,
		robuxPrice = 59,
		robuxProductId = 3696519931,
		assetName = "Gear 4",
	},
	{
		id = 5,
		name = "Plate",
		rarity = "uncommon",
		weightLbs = 225,
		powerGain = 150,
		cashPrice = 7_500_000,
		robuxPrice = 79,
		robuxProductId = 3696524705,
		assetName = "Gear 5",
	},
	{
		id = 6,
		name = "Rainbow Dumbbell",
		rarity = "rare",
		weightLbs = 450,
		powerGain = 400,
		cashPrice = 3_000_000_000,
		robuxPrice = 129,
		robuxProductId = 3696529600,
		assetName = "Gear 6",
	},
	{
		id = 7,
		name = "Galaxy Dumbbell",
		rarity = "rare",
		weightLbs = 900,
		powerGain = 1000,
		cashPrice = 7_400_000_000,
		robuxPrice = 199,
		robuxProductId = 3696533697,
		assetName = "Gear 7",
	},
	{
		id = 8,
		name = "Purple Orb Dumbbell",
		rarity = "rare",
		weightLbs = 1800,
		powerGain = 2500,
		cashPrice = 30_000_000_000,
		robuxPrice = 249,
		robuxProductId = 3696552109,
		assetName = "Gear 8",
	},
	{
		id = 9,
		name = "Red Orb Dumbbell",
		rarity = "epic",
		weightLbs = 4500,
		powerGain = 6250,
		cashPrice = 90_000_000_000,
		robuxPrice = 259,
		robuxProductId = 3696556426,
		assetName = "Gear 9",
	},
	{
		id = 10,
		name = "Lava Planets Dumbbell",
		rarity = "epic",
		weightLbs = 9000,
		powerGain = 15000,
		cashPrice = 1_200_000_000_000,
		robuxPrice = 299,
		robuxProductId = 3696577307,
		assetName = "Gear 10",
	},
	{
		id = 11,
		name = "Black Holes Dumbbell",
		rarity = "mythic",
		weightLbs = 22500,
		powerGain = 40000,
		cashPrice = 18_000_000_000_000,
		robuxPrice = 349,
		robuxProductId = 3696561899,
		assetName = "Gear 11",
	},
	{
		id = 12,
		name = "Moon",
		rarity = "legendary",
		weightLbs = 99999,
		powerGain = 100000,
		cashPrice = 500_000_000_000_000,
		robuxPrice = 449,
		robuxProductId = 3696581519,
		assetName = "Gear 12",
	},
	{
		id = 13,
		name = "Jupiter",
		rarity = "godly",
		weightLbs = 425000,
		powerGain = 300000,
		cashPrice = 20_000_000_000_000_000,
		robuxPrice = 549,
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

function M.isUnlocked(_gearId: number, _owned: { [number]: boolean }): boolean
	-- All gears are available to buy; no progression lock.
	return true
end

function M.rarityDisplay(rarity: string): string
	local r = string.lower(rarity)
	if r == "mythic" then
		return "Mythical"
	end
	return string.upper(string.sub(r, 1, 1)) .. string.lower(string.sub(r, 2))
end

local function getGearsFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local folder = assets and assets:FindFirstChild("Gears")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function nameMatchesGear(childName: string, def: GearDef): boolean
	local lower = string.lower(childName)
	local idStr = tostring(def.id)
	if lower == string.lower(def.assetName) or lower == string.lower(def.name) then
		return true
	end
	if lower == "gear" .. idStr or lower == "gear_" .. idStr or lower == "gear " .. idStr then
		return true
	end
	if string.find(lower, "gear%s*" .. idStr, 1) then
		return true
	end
	local skip = {
		dumbbell = true,
		orb = true,
		holes = true,
		planets = true,
		the = true,
	}
	for token in string.gmatch(string.lower(def.name), "%w+") do
		if #token >= 4 and not skip[token] and string.find(lower, token, 1, true) then
			return true
		end
	end
	return false
end

function M.findGearAsset(gearId: number): Instance?
	local def = byId[gearId]
	if not def then
		return nil
	end
	local folder = getGearsFolder()
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(def.assetName)
	if exact then
		return exact
	end
	for _, child in folder:GetChildren() do
		if nameMatchesGear(child.Name, def) then
			return child
		end
	end
	return nil
end

-- Clone Studio gear (Model / Folder / Tool / Part) into a fresh Model for tools/viewports.
function M.cloneGearModel(gearId: number): Model?
	local src = M.findGearAsset(gearId)
	if not src then
		return nil
	end
	if src:IsA("Model") then
		return src:Clone()
	end
	local nested = src:FindFirstChildWhichIsA("Model")
	if nested then
		return nested:Clone()
	end
	local wrapper = Instance.new("Model")
	wrapper.Name = src.Name
	if src:IsA("BasePart") then
		local part = src:Clone()
		part.Parent = wrapper
		wrapper.PrimaryPart = part
		return wrapper
	end
	local bag = src:Clone()
	for _, child in bag:GetChildren() do
		child.Parent = wrapper
	end
	bag:Destroy()
	local primary = wrapper:FindFirstChild("Primary", true)
	if primary and primary:IsA("BasePart") then
		wrapper.PrimaryPart = primary
	else
		local any = wrapper:FindFirstChildWhichIsA("BasePart", true)
		if any then
			wrapper.PrimaryPart = any
		end
	end
	if not wrapper.PrimaryPart then
		wrapper:Destroy()
		return nil
	end
	return wrapper
end

return M
