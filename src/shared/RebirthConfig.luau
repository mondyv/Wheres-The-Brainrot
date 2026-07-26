-- [ACTIVE] RebirthConfig
--[[
	Rebirth tiers — explicit requirements per rebirth (shared client + server).
	• Every 3rd rebirth (3, 6, 9 …) also grants +1 base floor.
	• Income multiplier comes from the tier table (1.10x, 1.25x, …).
	• UI cash % shows cumulative total: 5%, 7%, 9% … (+2% per rebirth tier).
--]]

local M = {}

M.FLOOR_EVERY = 3
M.MONEY_PERCENT_BASE = 5
M.MONEY_PERCENT_STEP = 2
M.MAX_TIER = 20
M.SKIP_DEV_PRODUCT_ID = 3598815788

M.REBIRTH_COUNT_ATTR = "RebirthCount"
M.MONEY_MULT_ATTR = "RebirthMoneyMult"
M.CAN_REBIRTH_ATTR = "RebirthCanRebirth"
M.FLOOR_REWARD_ATTR = "RebirthNextIsFloor"

export type BrainrotReq = {
	itemIndex: number,
	name: string,
	rarity: string,
}

export type BrainrotReqState = {
	itemIndex: number,
	name: string,
	rarity: string,
	icon: string?,
	met: boolean,
}

export type TierDef = {
	cashCost: number,
	incomeMultiplier: number,
	brainrot1: BrainrotReq,
	brainrot2: BrainrotReq,
}

export type RebirthSnapshot = {
	rebirthCount: number,
	nextTier: number,
	isMaxRebirth: boolean,
	isFloorRebirth: boolean,
	cashRequired: number,
	cashMet: boolean,
	canRebirth: boolean,
	moneyMultiplier: number,
	nextMoneyMultiplier: number,
	moneyPercentDisplay: number,
	brainrotReqs: { BrainrotReqState },
}

local function br(itemIndex: number, name: string, rarity: string): BrainrotReq
	return { itemIndex = itemIndex, name = name, rarity = rarity }
end

local TIER_DEFINITIONS: { TierDef } = {
	{
		cashCost = 5_000,
		incomeMultiplier = 1.10,
		brainrot1 = br(2, "NoobiniPizzanini", "common"),
		brainrot2 = br(3, "LiriliLarila", "common"),
	},
	{
		cashCost = 25_000,
		incomeMultiplier = 1.25,
		brainrot1 = br(2, "TalpaDiFero", "common"),
		brainrot2 = br(3, "PipiKiwi", "common"),
	},
	{
		cashCost = 150_000,
		incomeMultiplier = 1.45,
		brainrot1 = br(2, "AvocadiniAntilopini", "uncommon"),
		brainrot2 = br(3, "TrulimeroTrulicina", "uncommon"),
	},
	{
		cashCost = 500_000,
		incomeMultiplier = 1.70,
		brainrot1 = br(2, "BambiniCrostini", "uncommon"),
		brainrot2 = br(3, "BananitoDelfinito", "uncommon"),
	},
	{
		cashCost = 2_000_000,
		incomeMultiplier = 2.00,
		brainrot1 = br(2, "FrigoCamelo", "uncommon"),
		brainrot2 = br(3, "BombardinoCrocodilo", "rare"),
	},
	{
		cashCost = 8_000_000,
		incomeMultiplier = 2.35,
		brainrot1 = br(2, "GiraffaCelestre", "rare"),
		brainrot2 = br(3, "Alessio", "rare"),
	},
	{
		cashCost = 25_000_000,
		incomeMultiplier = 2.75,
		brainrot1 = br(2, "Pakrahmatmamat", "rare"),
		brainrot2 = br(3, "Ben", "epic"),
	},
	{
		cashCost = 100_000_000,
		incomeMultiplier = 3.25,
		brainrot1 = br(2, "PipiPotato", "epic"),
		brainrot2 = br(3, "PotHotspot", "epic"),
	},
	{
		cashCost = 400_000_000,
		incomeMultiplier = 3.85,
		brainrot1 = br(2, "NyanCat", "epic"),
		brainrot2 = br(3, "ChillinChili", "mythic"),
	},
	{
		cashCost = 1_500_000_000,
		incomeMultiplier = 4.50,
		brainrot1 = br(2, "Garamarama", "mythic"),
		brainrot2 = br(3, "BlueberrinniOctopusini", "mythic"),
	},
	{
		cashCost = 6_000_000_000,
		incomeMultiplier = 5.30,
		brainrot1 = br(2, "BombombiniGusini", "mythic"),
		brainrot2 = br(3, "CavalloVirtuoso", "mythic"),
	},
	{
		cashCost = 20_000_000_000,
		incomeMultiplier = 6.25,
		brainrot1 = br(2, "DragonCannelloni", "mythic"),
		brainrot2 = br(3, "GorilloWatermelondrillo", "mythic"),
	},
	{
		cashCost = 80_000_000_000,
		incomeMultiplier = 7.40,
		brainrot1 = br(2, "GraipusMedussi", "legendary"),
		brainrot2 = br(3, "LioneloCactuseli", "legendary"),
	},
	{
		cashCost = 250_000_000_000,
		incomeMultiplier = 8.75,
		brainrot1 = br(2, "TralaleroTralala", "legendary"),
		brainrot2 = br(3, "TriplitoTralaleritos", "legendary"),
	},
	{
		cashCost = 750_000_000_000,
		incomeMultiplier = 10.50,
		brainrot1 = br(2, "NuclearoDinosauro", "legendary"),
		brainrot2 = br(3, "EspressoSignora", "legendary"),
	},
	{
		cashCost = 2_500_000_000_000,
		incomeMultiplier = 12.50,
		brainrot1 = br(2, "LaGrandeCombination", "brainrot god"),
		brainrot2 = br(3, "Illuminati", "brainrot god"),
	},
	{
		cashCost = 8_000_000_000_000,
		incomeMultiplier = 15.00,
		brainrot1 = br(2, "SkibidiToilet", "brainrot god"),
		brainrot2 = br(3, "Meowl", "brainrot god"),
	},
	{
		cashCost = 30_000_000_000_000,
		incomeMultiplier = 18.00,
		brainrot1 = br(2, "LaVaccaSaturnoSaturnita", "brainrot god"),
		brainrot2 = br(3, "KarkerkarKurkur", "secret"),
	},
	{
		cashCost = 120_000_000_000_000,
		incomeMultiplier = 22.00,
		brainrot1 = br(2, "67", "secret"),
		brainrot2 = br(3, "69", "secret"),
	},
	{
		cashCost = 500_000_000_000_000,
		incomeMultiplier = 27.50,
		brainrot1 = br(2, "StrawberrelliFlamingelli", "secret"),
		brainrot2 = br(3, "LosTralalelitos", "secret"),
	},
}

function M.normalizeRarity(rarity: string): string
	return string.lower((string.gsub(rarity, "^%s*(.-)%s*$", "%1")))
end

function M.normalizeName(name: string): string
	return string.lower((string.gsub(name, "[^%a%d]", "")))
end

function M.formatBrainrotDisplayName(name: string): string
	return string.gsub(name, "(%l)(%u)", "%1 %2")
end

function M.getTierDef(tier: number): TierDef?
	local t = math.floor(tier)
	if t < 1 or t > M.MAX_TIER then
		return nil
	end
	return TIER_DEFINITIONS[t]
end

function M.getRebirthCount(player: Player): number
	local v = player:GetAttribute(M.REBIRTH_COUNT_ATTR)
	return if typeof(v) == "number" then math.max(0, math.floor(v)) else 0
end

function M.nextRebirthTier(player: Player): number
	return math.min(M.getRebirthCount(player) + 1, M.MAX_TIER)
end

function M.isMaxRebirthCount(rebirthCount: number): boolean
	return math.floor(rebirthCount) >= M.MAX_TIER
end

function M.isMaxRebirth(player: Player): boolean
	return M.isMaxRebirthCount(M.getRebirthCount(player))
end

function M.isFloorRebirth(tier: number): boolean
	return tier > 0 and (tier % M.FLOOR_EVERY) == 0
end

-- Cash floor unlock: floor 2 needs rebirth 3, floor 3 needs 6, floor 4 needs 9, etc.
function M.requiredRebirthCountForFloor(floorLevel: number): number
	local floor = math.floor(floorLevel)
	if floor <= 1 then
		return 0
	end
	return (floor - 1) * M.FLOOR_EVERY
end

function M.playerCanCashUnlockFloor(player: Player, targetFloor: number): boolean
	return M.getRebirthCount(player) >= M.requiredRebirthCountForFloor(targetFloor)
end

function M.moneyPercentDisplayForTier(tier: number): number
	local t = math.max(1, math.floor(tier))
	return M.MONEY_PERCENT_BASE + (t - 1) * M.MONEY_PERCENT_STEP
end

function M.moneyRewardTextForTier(tier: number): string
	return string.format("+%d%%", M.moneyPercentDisplayForTier(tier))
end

function M.moneyMultiplierForCount(rebirthCount: number): number
	if rebirthCount <= 0 then
		return 1
	end
	local def = M.getTierDef(rebirthCount)
	return if def then def.incomeMultiplier else TIER_DEFINITIONS[M.MAX_TIER].incomeMultiplier
end

function M.getMoneyMultiplier(player: Player): number
	local v = player:GetAttribute(M.MONEY_MULT_ATTR)
	if typeof(v) == "number" and v > 0 then
		return v
	end
	return M.moneyMultiplierForCount(M.getRebirthCount(player))
end

function M.cashRequirement(tier: number): number
	local def = M.getTierDef(tier)
	return if def then def.cashCost else 0
end

function M.brainrotRequirements(tier: number): { BrainrotReq }
	local def = M.getTierDef(tier)
	if not def then
		return {}
	end
	return { def.brainrot1, def.brainrot2 }
end

-- isDiscovered must reflect Index unlocks (IndexService.hasDiscoveredBrainrot), not inventory.
function M.evaluateBrainrotReqs(isDiscovered: (name: string) -> boolean, reqs: { BrainrotReq }): { BrainrotReqState }
	local out: { BrainrotReqState } = {}
	for _, req in reqs do
		local met = isDiscovered(req.name)
		table.insert(out, {
			itemIndex = req.itemIndex,
			name = req.name,
			rarity = req.rarity,
			icon = nil,
			met = met,
		})
	end
	return out
end

function M.buildSnapshot(player: Player, isDiscovered: (name: string) -> boolean): RebirthSnapshot
	local count = M.getRebirthCount(player)
	if M.isMaxRebirthCount(count) then
		local tierDef = M.getTierDef(count)
		local maxMult = if tierDef then tierDef.incomeMultiplier else M.moneyMultiplierForCount(count)
		return {
			rebirthCount = count,
			nextTier = count,
			isMaxRebirth = true,
			isFloorRebirth = false,
			cashRequired = 0,
			cashMet = true,
			canRebirth = false,
			moneyMultiplier = M.getMoneyMultiplier(player),
			nextMoneyMultiplier = maxMult,
			moneyPercentDisplay = M.moneyPercentDisplayForTier(count),
			brainrotReqs = {},
		}
	end

	local tier = count + 1
	local tierDef = M.getTierDef(tier)
	local cashRequired = if tierDef then tierDef.cashCost else 0
	local cash = player:GetAttribute("Cash")
	local cashVal = if typeof(cash) == "number" then cash else 0
	local cashMet = tierDef ~= nil and cashVal >= cashRequired
	local brainrotReqs = if tierDef then M.evaluateBrainrotReqs(isDiscovered, M.brainrotRequirements(tier)) else {}
	local brainrotsMet = tierDef ~= nil
	for _, req in brainrotReqs do
		if not req.met then
			brainrotsMet = false
			break
		end
	end
	local canRebirth = tierDef ~= nil and cashMet and brainrotsMet
	local nextMult = if tierDef then tierDef.incomeMultiplier else M.moneyMultiplierForCount(count)
	return {
		rebirthCount = count,
		nextTier = tier,
		isMaxRebirth = false,
		isFloorRebirth = M.isFloorRebirth(tier),
		cashRequired = cashRequired,
		cashMet = cashMet,
		canRebirth = canRebirth,
		moneyMultiplier = M.getMoneyMultiplier(player),
		nextMoneyMultiplier = nextMult,
		moneyPercentDisplay = if tierDef then M.moneyPercentDisplayForTier(tier) else 0,
		brainrotReqs = brainrotReqs,
	}
end

return M
