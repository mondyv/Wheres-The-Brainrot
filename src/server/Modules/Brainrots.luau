-- [ACTIVE] Brainrots
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

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

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
	{ name = "BurbalolliLulilolli",       rarity = "uncommon",     baseIncome = 62 },
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

M.BRAINROT_BY_NAME = {} :: { [string]: BrainrotDef }
for _, def in ipairs(M.BRAINROTS) do
	M.BRAINROT_BY_NAME[def.name] = def
end

-- Logical name → ServerStorage.Brainrots folder name when they differ in Studio.
M.STORAGE_FOLDER_ALIASES = {
	Garamarama = "Garama",
	-- Legacy typo (Lui vs Luli) still present in some older saves / Studio copies.
	BurbalolliLuilolli = "BurbalolliLulilolli",
} :: { [string]: string }

function M.resolveStorageFolderName(brainrotName: string): string
	local alias = M.STORAGE_FOLDER_ALIASES[brainrotName]
	if typeof(alias) == "string" and alias ~= "" then
		return alias
	end
	return brainrotName
end

function M.storageFolderCandidates(brainrotName: string): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function push(name: string)
		if name == "" or seen[name] then
			return
		end
		seen[name] = true
		table.insert(out, name)
	end
	push(brainrotName)
	push(M.resolveStorageFolderName(brainrotName))
	for logical, folder in pairs(M.STORAGE_FOLDER_ALIASES) do
		if folder == brainrotName then
			push(logical)
		elseif logical == brainrotName then
			push(folder)
		end
	end
	return out
end

function M.findBrainrotStorageFolder(root: Instance, brainrotName: string): Instance?
	for _, name in ipairs(M.storageFolderCandidates(brainrotName)) do
		local folder = root:FindFirstChild(name)
		if folder then
			return folder
		end
	end
	-- Fuzzy: Studio folders sometimes differ by spaces/hyphens/case (Lui vs Luli already aliased).
	local want = string.lower((brainrotName:gsub("[%s_%-]", "")))
	for _, child in ipairs(root:GetChildren()) do
		local n = string.lower((child.Name:gsub("[%s_%-]", "")))
		if n == want then
			return child
		end
	end
	return nil
end

-- Legacy logical-name aliases (old spelling → current def).
M.BRAINROT_BY_NAME["BurbalolliLuilolli"] = M.BRAINROT_BY_NAME["BurbalolliLulilolli"]

function M.getByName(name: string): BrainrotDef?
	return M.BRAINROT_BY_NAME[name]
end

-- Retired / seasonal brainrots still in Storage should never roll or equip.
function M.isRetiredBrainrotName(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "easter", 1, true) ~= nil
end

function M.isExclusiveBrainrotName(name: string): boolean
	return string.lower(name) == string.lower(StoreConfig.EXCLUSIVE_BRAINROT_NAME)
end

function M.isPlayableBrainrotName(name: string): boolean
	if M.isExclusiveBrainrotName(name) then
		return false
	end
	return not M.isRetiredBrainrotName(name)
end

function M.isRetiredBrainrotInstance(inst: Instance): boolean
	if M.isRetiredBrainrotName(inst.Name) then
		return true
	end
	return M.isRetiredBrainrotName(inst:GetFullName())
end

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
-- Primary names match BrainrotsConfig / Studio ("Golden"); "Gold" kept as alias for older places.
M.MUTATION_TEMPLATE_FOLDER = {
	normal  = "Normal",
	golden  = "Golden",
	diamond = "Diamond",
	lava    = "Lava",
	galaxy  = "Galaxy",
	rainbow = "Rainbow",
} :: { [string]: string }

M.MUTATION_TEMPLATE_ALIASES = {
	normal  = { "Normal" },
	golden  = { "Golden", "Gold" },
	diamond = { "Diamond" },
	lava    = { "Lava" },
	galaxy  = { "Galaxy" },
	rainbow = { "Rainbow" },
} :: { [string]: { string } }

function M.mutationTemplateCandidateNames(mutationId: string): { string }
	local aliases = M.MUTATION_TEMPLATE_ALIASES[mutationId]
	if aliases then
		return aliases
	end
	local primary = M.MUTATION_TEMPLATE_FOLDER[mutationId]
	if typeof(primary) == "string" then
		return { primary }
	end
	return {}
end

function M.mutationIdFromTemplateName(templateName: string): string?
	local lower = string.lower(templateName)
	if lower == "gold" or lower == "golden" then
		return "golden"
	end
	for mId, folderName in pairs(M.MUTATION_TEMPLATE_FOLDER) do
		if folderName == templateName or string.lower(folderName) == lower then
			return mId
		end
	end
	return nil
end

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
	secret         = "SECRET",
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
		mutations  = { normal = 38, golden = 30, diamond = 17, lava = 9, galaxy = 4, rainbow = 2 },
	},
	[8] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 35, legendary = 30, ["brainrot god"] = 25, secret = 10 },
		mutations  = { normal = 32, golden = 31, diamond = 18, lava = 10, galaxy = 5.5, rainbow = 3.5 },
	},
	[9] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 35, ["brainrot god"] = 40, secret = 25 },
		mutations  = { normal = 26, golden = 32, diamond = 20, lava = 11, galaxy = 6.5, rainbow = 4.5 },
	},
	[10] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 55, secret = 45 },
		mutations  = { normal = 20, golden = 32, diamond = 22, lava = 12, galaxy = 8, rainbow = 6 },
	},
} :: { [number]: PlotChanceDef }

-- ── Income helpers ────────────────────────────────────────────────────────────

M.MAX_LEVEL = 90

local RARITY_ALIASES: { [string]: string } = {
	mythical = "mythic",
	god = "brainrot god",
	godly = "brainrot god",
	brainrotgod = "brainrot god",
	["brain rot god"] = "brainrot god",
}

function M.normalizeRarityId(rarity: string): string
	local key = string.lower((string.gsub(rarity, "^%s*(.-)%s*$", "%1")))
	key = string.gsub(key, "[_%-]+", " ")
	key = string.gsub(key, "%s+", " ")
	local compact = string.gsub(key, "%s+", "")
	return RARITY_ALIASES[key] or RARITY_ALIASES[compact] or key
end

function M.incomePerSecond(brainrot: BrainrotDef, level: number, mutationId: string): number
	local rarityId = M.normalizeRarityId(brainrot.rarity)
	local r = M.RARITY_BY_ID[rarityId]
	if not r then
		local catalog = M.getByName(brainrot.name)
		if catalog then
			rarityId = catalog.rarity
			r = M.RARITY_BY_ID[rarityId]
		end
	end
	if not r then
		return 0
	end
	local baseIncome = brainrot.baseIncome
	if typeof(baseIncome) ~= "number" or baseIncome <= 0 then
		local catalog = M.getByName(brainrot.name)
		baseIncome = if catalog then catalog.baseIncome else 0
	end
	if baseIncome <= 0 then
		return 0
	end
	local mut = M.MUTATION_BY_ID[mutationId]
	local mm = if mut then mut.multiplier else 1
	local lvl = math.clamp(math.floor(level), 1, M.MAX_LEVEL)
	local factor = r.maxMultiplier ^ ((lvl - 1) / (M.MAX_LEVEL - 1))
	return baseIncome * mm * factor
end

-- Cost to go from level → level+1. Returns 0 if already maxed.
-- Scales with current income, level exponent, and a per-rarity multiplier (high rarities cost much more).
-- 2× Upgrades gamepass grants +2 levels per purchase but still uses this single-step cost only.
local UPGRADE_LEVEL_EXPONENT = 1.20

local RARITY_UPGRADE_COST_MULT: { [RarityId]: number } = {
	common = 1.0,
	uncommon = 1.05,
	rare = 1.15,
	epic = 1.3,
	mythic = 2.5,
	legendary = 6.0,
	["brainrot god"] = 10.0,
	secret = 16.0,
}

function M.upgradeCost(brainrot: BrainrotDef, currentLevel: number, mutationId: string): number
	if currentLevel >= M.MAX_LEVEL then
		return 0
	end
	local lvl = math.max(1, math.floor(currentLevel))
	local currentIncome = M.incomePerSecond(brainrot, lvl, mutationId)
	local rarityMultiplier = RARITY_UPGRADE_COST_MULT[brainrot.rarity] or 1
	local upgradeCost = currentIncome * (lvl ^ UPGRADE_LEVEL_EXPONENT) * rarityMultiplier
	return math.max(1, math.floor(upgradeCost + 0.5))
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

local function weightedLevelInRange(minLevel: number, maxLevel: number): number
	local total = 0
	local entries: { { level: number, weight: number } } = {}
	for lv = minLevel, maxLevel do
		-- Lower levels within the band are more likely (lv 1 >> lv 10, lv 10 >> lv 20).
		local w = maxLevel + 1 - lv
		total += w
		table.insert(entries, { level = lv, weight = w })
	end
	if total <= 0 then
		return minLevel
	end
	local roll = math.random() * total
	local acc = 0
	for _, e in ipairs(entries) do
		acc += e.weight
		if roll <= acc then
			return e.level
		end
	end
	return maxLevel
end

-- Bush harvest: 70% level 1–10, 30% level 10–20 (cap 20). Lower levels favored in each band.
function M.rollBushHarvestLevel(): number
	if math.random() < 0.7 then
		return weightedLevelInRange(1, 10)
	end
	return weightedLevelInRange(10, 20)
end

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
				if M.isPlayableBrainrotName(b.name) then
					table.insert(out, b)
				end
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
