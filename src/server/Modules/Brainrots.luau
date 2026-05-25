--[[
	Brainrots
	Shared master config: all brainrots, rarity / mutation / plot chances, income formula.

	Income formula (per second):
	  Income = BaseIncome * MutationMultiplier * (RarityMaxMultiplier ^ ((Level - 1) / 89))

	Per-level multiplier (R) is RarityMaxMultiplier ^ (1/89); the precomputed
	rarity perLevelGrowth matches the in-game "+X% each level" tuning.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local M = {}

export type RarityId = "common" | "uncommon" | "rare" | "epic" | "mythic" | "legendary" | "brainrot god" | "secret"
export type MutationId = "normal" | "golden" | "diamond" | "lava" | "galaxy" | "rainbow"

export type BrainrotDef = {
	name: string,
	rarity: RarityId,
	baseIncome: number,
}

export type RarityDef = {
	id: RarityId,
	displayName: string,
	maxMultiplier: number, -- at Level 90 (versus baseIncome)
	perLevelGrowth: number, -- e.g. 1.109 = +10.9% / level
}

export type MutationDef = {
	id: MutationId,
	displayName: string,
	multiplier: number,
}

export type PlotChanceDef = {
	categories: { [RarityId]: number },
	mutations: { [MutationId]: number },
}

-- ── Master brainrot list ──────────────────────────────────────────────────────

M.BRAINROTS = {
	{ name = "NoobiniPizzanini",         rarity = "common",       baseIncome = 2 },
	{ name = "LiriliLarila",             rarity = "common",       baseIncome = 3 },
	{ name = "TimCheese",                rarity = "common",       baseIncome = 3 },
	{ name = "FluriFlura",               rarity = "common",       baseIncome = 4 },
	{ name = "TalpaDiFero",              rarity = "common",       baseIncome = 5 },
	{ name = "SvininaBombardino",        rarity = "common",       baseIncome = 6 },
	{ name = "PipiKiwi",                 rarity = "common",       baseIncome = 7 },
	{ name = "TrippiTroppi",             rarity = "common",       baseIncome = 7 },
	{ name = "GangsterFootera",          rarity = "common",       baseIncome = 15 },
	{ name = "BanditoBobrito",           rarity = "common",       baseIncome = 17 },
	{ name = "BonecaAmbalabu",           rarity = "common",       baseIncome = 17 },
	{ name = "CactoHipopotamo",          rarity = "common",       baseIncome = 18 },
	{ name = "CappuccinoAssassino",      rarity = "common",       baseIncome = 19 },
	{ name = "BrrBrrPatapim",            rarity = "common",       baseIncome = 22 },

	{ name = "AvocadiniAntilopini",      rarity = "uncommon",     baseIncome = 22 },
	{ name = "TrulimeroTrulicina",       rarity = "uncommon",     baseIncome = 26 },
	{ name = "BambiniCrostini",          rarity = "uncommon",     baseIncome = 40 },
	{ name = "BananitoDelfinito",        rarity = "uncommon",     baseIncome = 44 },
	{ name = "AvocadiniGuffo",           rarity = "uncommon",     baseIncome = 50 },
	{ name = "BrrBicusDicus",            rarity = "uncommon",     baseIncome = 52 },
	{ name = "BurbalolliLuilolli",       rarity = "uncommon",     baseIncome = 62 },
	{ name = "BalerinaCapucina",         rarity = "uncommon",     baseIncome = 64 },
	{ name = "SalaminoPinguino",         rarity = "uncommon",     baseIncome = 64 },
	{ name = "ChimpanziniBananini",      rarity = "uncommon",     baseIncome = 72 },
	{ name = "TirilikalikaTirilikalako", rarity = "uncommon",     baseIncome = 76 },
	{ name = "FrigoCamelo",              rarity = "uncommon",     baseIncome = 100 },
	{ name = "OrangutiniAnanassini",     rarity = "uncommon",     baseIncome = 130 },
	{ name = "RhinoToasterino",          rarity = "uncommon",     baseIncome = 140 },

	{ name = "BombardinoCrocodilo",      rarity = "rare",         baseIncome = 150 },
	{ name = "GiraffaCelestre",          rarity = "rare",         baseIncome = 160 },
	{ name = "ElefantoCocofanto",        rarity = "rare",         baseIncome = 160 },
	{ name = "OdinDinDinDun",            rarity = "rare",         baseIncome = 170 },
	{ name = "Alessio",                  rarity = "rare",         baseIncome = 210 },
	{ name = "BalerinoLololo",           rarity = "rare",         baseIncome = 230 },
	{ name = "Pakrahmatmamat",           rarity = "rare",         baseIncome = 450 },
	{ name = "TrippiTroppiTroppaTrippa", rarity = "rare",         baseIncome = 500 },
	{ name = "TatatataSahur",            rarity = "rare",         baseIncome = 550 },
	{ name = "TikTakSahur",              rarity = "rare",         baseIncome = 600 },
	{ name = "TungTungSahur",            rarity = "rare",         baseIncome = 650 },
	{ name = "Madung",                   rarity = "rare",         baseIncome = 725 },
	{ name = "Mateo",                    rarity = "rare",         baseIncome = 775 },
	{ name = "Pepe",                     rarity = "rare",         baseIncome = 880 },

	{ name = "Ben",                      rarity = "epic",         baseIncome = 920 },
	{ name = "PipiPotato",               rarity = "epic",         baseIncome = 1800 },
	{ name = "PotHotspot",               rarity = "epic",         baseIncome = 2000 },
	{ name = "QuesadillaCrocodila",      rarity = "epic",         baseIncome = 2100 },
	{ name = "SwagSoda",                 rarity = "epic",         baseIncome = 2300 },
	{ name = "SmurfCat",                 rarity = "epic",         baseIncome = 2400 },
	{ name = "Trollface",                rarity = "epic",         baseIncome = 2600 },
	{ name = "SigmaBoy",                 rarity = "epic",         baseIncome = 2700 },
	{ name = "HappyBananaMeme",          rarity = "epic",         baseIncome = 2900 },
	{ name = "HappyBananaCat",           rarity = "epic",         baseIncome = 3100 },
	{ name = "NyanCat",                  rarity = "epic",         baseIncome = 4700 },
	{ name = "YesMyExamine",             rarity = "epic",         baseIncome = 5000 },
	{ name = "NooMyExamine",             rarity = "epic",         baseIncome = 5300 },
	{ name = "EsokSekolah",              rarity = "epic",         baseIncome = 5800 },

	{ name = "ChillinChili",             rarity = "mythic",       baseIncome = 6200 },
	{ name = "Garamarama",               rarity = "mythic",       baseIncome = 7000 },
	{ name = "KetupatKepat",             rarity = "mythic",       baseIncome = 7700 },
	{ name = "KetchuruAndMusturu",       rarity = "mythic",       baseIncome = 8500 },
	{ name = "Lerulerulerule",           rarity = "mythic",       baseIncome = 9500 },
	{ name = "BlueberrinniOctopusini",   rarity = "mythic",       baseIncome = 10000 },
	{ name = "BombombiniGusini",         rarity = "mythic",       baseIncome = 12500 },
	{ name = "CachorritoMelonito",       rarity = "mythic",       baseIncome = 15000 },
	{ name = "CavalloVirtuoso",          rarity = "mythic",       baseIncome = 16500 },
	{ name = "ChicleteiraBicicleteira",  rarity = "mythic",       baseIncome = 17500 },
	{ name = "ChicleteirinaBicicleteirina", rarity = "mythic",    baseIncome = 18000 },
	{ name = "DragonCannelloni",         rarity = "mythic",       baseIncome = 19500 },
	{ name = "GanganzelliTrulala",       rarity = "mythic",       baseIncome = 20000 },
	{ name = "GorilloWatermelondrillo",  rarity = "mythic",       baseIncome = 22500 },

	{ name = "GraipusMedussi",           rarity = "legendary",    baseIncome = 23000 },
	{ name = "LioneloCactuseli",         rarity = "legendary",    baseIncome = 25000 },
	{ name = "PandacciniBananini",       rarity = "legendary",    baseIncome = 27500 },
	{ name = "TricTracBarabum",          rarity = "legendary",    baseIncome = 27500 },
	{ name = "TralaleroTralala",         rarity = "legendary",    baseIncome = 28000 },
	{ name = "TralalitaTralala",         rarity = "legendary",    baseIncome = 29000 },
	{ name = "Tralaledon",               rarity = "legendary",    baseIncome = 30000 },
	{ name = "TriplitoTralaleritos",     rarity = "legendary",    baseIncome = 32000 },
	{ name = "ZibraZubraZibralini",      rarity = "legendary",    baseIncome = 38000 },
	{ name = "GlorboFruttodrillo",       rarity = "legendary",    baseIncome = 44500 },
	{ name = "TigroligreFrutonni",       rarity = "legendary",    baseIncome = 44500 },
	{ name = "NuclearoDinosauro",        rarity = "legendary",    baseIncome = 49500 },
	{ name = "ChefCrabracadabra",        rarity = "legendary",    baseIncome = 53500 },
	{ name = "EspressoSignora",          rarity = "legendary",    baseIncome = 75000 },

	{ name = "LaGrandeCombination",      rarity = "brainrot god", baseIncome = 120000 },
	{ name = "Illuminati",               rarity = "brainrot god", baseIncome = 125000 },
	{ name = "OrcaleroOrcala",           rarity = "brainrot god", baseIncome = 135000 },
	{ name = "StrawberryElephant",       rarity = "brainrot god", baseIncome = 135000 },
	{ name = "SkibidiToilet",            rarity = "brainrot god", baseIncome = 190000 },
	{ name = "Meowl",                    rarity = "brainrot god", baseIncome = 200000 },
	{ name = "Pakrahmatmatina",          rarity = "brainrot god", baseIncome = 220000 },
	{ name = "AgarriniLaPallini",        rarity = "brainrot god", baseIncome = 225000 },
	{ name = "TorrtuginniDragonfrutini", rarity = "brainrot god", baseIncome = 225000 },
	{ name = "LaVaccaSaturnoSaturnita",  rarity = "brainrot god", baseIncome = 275000 },

	{ name = "KarkerkarKurkur",          rarity = "secret",       baseIncome = 420000 },
	{ name = "JobJobJobSahur",           rarity = "secret",       baseIncome = 475000 },
	{ name = "67",                       rarity = "secret",       baseIncome = 490000 },
	{ name = "69",                       rarity = "secret",       baseIncome = 500000 },
	{ name = "StrawberrelliFlamingelli", rarity = "secret",       baseIncome = 850000 },
	{ name = "LosTralalelitos",          rarity = "secret",       baseIncome = 1000000 },
} :: { BrainrotDef }

-- ── Rarities ──────────────────────────────────────────────────────────────────

M.RARITIES = {
	{ id = "common",       displayName = "COMMON",       maxMultiplier = 10_000,        perLevelGrowth = 1.1090 },
	{ id = "uncommon",     displayName = "UNCOMMON",     maxMultiplier = 50_000,        perLevelGrowth = 1.1293 },
	{ id = "rare",         displayName = "RARE",         maxMultiplier = 250_000,       perLevelGrowth = 1.1499 },
	{ id = "epic",         displayName = "EPIC",         maxMultiplier = 1_000_000,     perLevelGrowth = 1.1679 },
	{ id = "mythic",       displayName = "MYTHIC",       maxMultiplier = 5_000_000,     perLevelGrowth = 1.1892 },
	{ id = "legendary",    displayName = "LEGENDARY",    maxMultiplier = 25_000_000,    perLevelGrowth = 1.2109 },
	{ id = "brainrot god", displayName = "GODLY",        maxMultiplier = 125_000_000,   perLevelGrowth = 1.2330 },
	{ id = "secret",       displayName = "SECRET",       maxMultiplier = 1_000_000_000, perLevelGrowth = 1.2622 },
} :: { RarityDef }

-- Index → rarity def lookup.
M.RARITY_BY_ID = {} :: { [string]: RarityDef }
for _, r in ipairs(M.RARITIES) do
	M.RARITY_BY_ID[r.id] = r
end

-- ── Mutations ─────────────────────────────────────────────────────────────────

M.MUTATIONS = {
	{ id = "normal",  displayName = "Normal",  multiplier = 1 },
	{ id = "golden",  displayName = "Gold",    multiplier = 3 },
	{ id = "diamond", displayName = "Diamond", multiplier = 4 },
	{ id = "lava",    displayName = "Lava",    multiplier = 8 },
	{ id = "galaxy",  displayName = "Galaxy",  multiplier = 12 },
	{ id = "rainbow", displayName = "Rainbow", multiplier = 25 },
} :: { MutationDef }

M.MUTATION_BY_ID = {} :: { [string]: MutationDef }
for _, m in ipairs(M.MUTATIONS) do
	M.MUTATION_BY_ID[m.id] = m
end

-- Studio templates store each mutation variant inside Brainrots/<Name>/<Variant>; map mutation id to variant folder name.
M.MUTATION_TEMPLATE_FOLDER = {
	normal  = "Normal",
	golden  = "Gold",
	diamond = "Diamond",
	lava    = "Lava",
	galaxy  = "Galaxy",
	rainbow = "Rainbow",
} :: { [string]: string }

-- Gradient name inside BrainrotHeader.Info.Type to enable for this mutation (Normal has no gradient).
M.MUTATION_GRADIENT_NAME = {
	normal  = nil,
	golden  = "Gold",
	diamond = "Diamond",
	lava    = "Lava",
	galaxy  = "Galaxy",
	rainbow = "Rainbow",
} :: { [string]: string? }

-- Gradient name inside BrainrotHeader.Info.Rarity to enable for this rarity.
M.RARITY_GRADIENT_NAME = {
	common         = "COMMON",
	uncommon       = "UNCOMMON",
	rare           = "RARE",
	epic           = "EPIC",
	mythic         = "MYTHIC",
	legendary      = "LEGENDARY",
	["brainrot god"] = "GODLY",
	secret         = "GODLY", -- no SECRET gradient in template; reuse GODLY for highest-tier visual.
} :: { [string]: string }

-- Level tier → gradient name inside BrainrotHeader.Info.Level.
local function levelTierName(level: number): string
	if level <= 29 then
		return "1-29"
	elseif level <= 49 then
		return "30-49"
	elseif level <= 69 then
		return "50-69"
	elseif level <= 89 then
		return "70-89"
	else
		return "90-100"
	end
end
M.levelTierName = levelTierName

-- ── Plots ─────────────────────────────────────────────────────────────────────

M.MAX_PLOT = 10

M.PLOT_CHANCES = {
	[1] = {
		categories = { common = 75, uncommon = 25, rare = 0, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 70, golden = 22, diamond = 6, lava = 1.5, galaxy = 0.4, rainbow = 0.1 },
	},
	[2] = {
		categories = { common = 55, uncommon = 35, rare = 10, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 66, golden = 23, diamond = 7.5, lava = 2.4, galaxy = 0.8, rainbow = 0.3 },
	},
	[3] = {
		categories = { common = 35, uncommon = 35, rare = 22, epic = 8, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 62, golden = 24, diamond = 9, lava = 3.2, galaxy = 1.3, rainbow = 0.5 },
	},
	[4] = {
		categories = { common = 25, uncommon = 28, rare = 25, epic = 15, mythic = 7, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 58, golden = 25, diamond = 10.5, lava = 4.2, galaxy = 1.6, rainbow = 0.7 },
	},
	[5] = {
		categories = { common = 0, uncommon = 25, rare = 30, epic = 25, mythic = 20, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 54, golden = 26, diamond = 12, lava = 5.2, galaxy = 2, rainbow = 0.8 },
	},
	[6] = {
		categories = { common = 0, uncommon = 0, rare = 30, epic = 28, mythic = 27, legendary = 15, ["brainrot god"] = 0, secret = 0 },
		mutations  = { normal = 50, golden = 27, diamond = 13.5, lava = 6, galaxy = 2.5, rainbow = 1 },
	},
	[7] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 30, mythic = 30, legendary = 25, ["brainrot god"] = 15, secret = 0 },
		mutations  = { normal = 46, golden = 28, diamond = 15, lava = 7, galaxy = 3, rainbow = 1 },
	},
	[8] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 35, legendary = 30, ["brainrot god"] = 25, secret = 10 },
		mutations  = { normal = 42, golden = 29, diamond = 16, lava = 8, galaxy = 3.5, rainbow = 1.5 },
	},
	[9] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 35, ["brainrot god"] = 40, secret = 25 },
		mutations  = { normal = 38, golden = 30, diamond = 17, lava = 9, galaxy = 4, rainbow = 2 },
	},
	[10] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 55, secret = 45 },
		mutations  = { normal = 35, golden = 30, diamond = 18, lava = 10, galaxy = 5, rainbow = 2 },
	},
} :: { [number]: PlotChanceDef }

-- ── Income helpers ────────────────────────────────────────────────────────────

M.MAX_LEVEL = 90

function M.incomePerSecond(brainrot: BrainrotDef, level: number, mutationId: string): number
	local r = M.RARITY_BY_ID[brainrot.rarity]
	if not r then
		return 0
	end
	local mut = M.MUTATION_BY_ID[mutationId]
	local mm = if mut then mut.multiplier else 1
	local lvl = math.clamp(math.floor(level), 1, M.MAX_LEVEL)
	local factor = r.maxMultiplier ^ ((lvl - 1) / (M.MAX_LEVEL - 1))
	return brainrot.baseIncome * mm * factor
end

-- Cost to go from level → level+1. Returns 0 if already maxed.
-- First upgrade = $/s at level 1; each later upgrade costs 1.25× the previous (e.g. 6 → 7.5 → 9.37…).
local UPGRADE_PRICE_GROWTH = 1.25

function M.upgradeCost(brainrot: BrainrotDef, currentLevel: number, mutationId: string): number
	if currentLevel >= M.MAX_LEVEL then
		return 0
	end
	local baseIncome = M.incomePerSecond(brainrot, 1, mutationId)
	return math.max(1, math.floor(baseIncome * (UPGRADE_PRICE_GROWTH ^ (currentLevel - 1))))
end

-- ── Rolling helpers ───────────────────────────────────────────────────────────

local function weightedPick(weights: { [string]: number }): string?
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local r = math.random() * total
	local acc = 0
	for k, w in weights do
		if w > 0 then
			acc += w
			if r <= acc then
				return k
			end
		end
	end
	return nil
end
M.weightedPick = weightedPick

function M.rollMutation(plot: number): MutationId
	local chances = M.PLOT_CHANCES[plot]
	if not chances then
		return "normal"
	end
	local pick = weightedPick(chances.mutations)
	if pick then
		return pick :: MutationId
	end
	return "normal"
end

function M.rollRarity(plot: number): RarityId?
	local chances = M.PLOT_CHANCES[plot]
	if not chances then
		return nil
	end
	local pick = weightedPick(chances.categories)
	if pick then
		return pick :: RarityId
	end
	return nil
end

-- Brainrots filtered by rarity. Optional `available` predicate lets the caller restrict to brainrots that have templates.
function M.brainrotsOfRarity(rarity: RarityId, available: ((BrainrotDef) -> boolean)?): { BrainrotDef }
	local out: { BrainrotDef } = {}
	for _, b in ipairs(M.BRAINROTS) do
		if b.rarity == rarity then
			if available == nil or available(b) then
				table.insert(out, b)
			end
		end
	end
	return out
end

function M.pickRandomBrainrotForPlot(plot: number, available: ((BrainrotDef) -> boolean)?): (BrainrotDef?, MutationId)
	local mutation: MutationId = M.rollMutation(plot)
	local rarity = M.rollRarity(plot)
	if not rarity then
		return nil, mutation
	end
	local pool = M.brainrotsOfRarity(rarity, available)
	if #pool == 0 and available ~= nil then
		-- Fallback: ignore availability filter for this rarity rather than fail outright.
		pool = M.brainrotsOfRarity(rarity, nil)
	end
	if #pool == 0 then
		-- Cascade down rarity table until we find something playable.
		for i = #M.RARITIES, 1, -1 do
			local r = M.RARITIES[i].id
			pool = M.brainrotsOfRarity(r, available)
			if #pool > 0 then
				rarity = r
				break
			end
		end
	end
	if #pool == 0 then
		return nil, mutation
	end
	return pool[math.random(1, #pool)], mutation
end

function M.getBrainrotsFolder(): Folder?
	local f = ServerStorage:FindFirstChild("Brainrots")
	if f and f:IsA("Folder") then
		return f
	end
	local legacy = ReplicatedStorage:FindFirstChild("Brainrots")
	if legacy and legacy:IsA("Folder") then
		return legacy
	end
	return nil
end

function M.getTemplatesFolder(): Folder?
	local f = ServerStorage:FindFirstChild("Templates")
	if f and f:IsA("Folder") then
		return f
	end
	local legacy = ReplicatedStorage:FindFirstChild("Templates")
	if legacy and legacy:IsA("Folder") then
		return legacy
	end
	return nil
end

function M.waitTemplatesFolder(timeoutSec: number?): Folder?
	local timeout = if typeof(timeoutSec) == "number" then timeoutSec else 60
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		local f = M.getTemplatesFolder()
		if f then
			return f
		end
		task.wait(0.25)
	end
	return M.getTemplatesFolder()
end

function M.getBaseTemplate(): Instance?
	local templates = M.getTemplatesFolder()
	if not templates then
		return nil
	end
	return templates:FindFirstChild("Base")
end

return M
