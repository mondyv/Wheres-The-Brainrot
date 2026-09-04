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
		categories = { common = 78, uncommon = 20, rare = 2, epic = 0, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations = { normal = 82, golden = 14, diamond = 3, lava = 0.8, galaxy = 0.15, rainbow = 0.05 },
	},
	[2] = {
		categories = { common = 52, uncommon = 34, rare = 12, epic = 2, mythic = 0, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations = { normal = 76, golden = 16, diamond = 5, lava = 2, galaxy = 0.7, rainbow = 0.3 },
	},
	[3] = {
		categories = { common = 28, uncommon = 34, rare = 26, epic = 10, mythic = 2, legendary = 0, ["brainrot god"] = 0, secret = 0 },
		mutations = { normal = 70, golden = 18, diamond = 7, lava = 3.2, galaxy = 1.2, rainbow = 0.6 },
	},
	[4] = {
		categories = { common = 12, uncommon = 24, rare = 30, epic = 22, mythic = 11, legendary = 1, ["brainrot god"] = 0, secret = 0 },
		mutations = { normal = 64, golden = 20, diamond = 9, lava = 4.2, galaxy = 1.8, rainbow = 1 },
	},
	[5] = {
		categories = { common = 0, uncommon = 12, rare = 28, epic = 30, mythic = 22, legendary = 8, ["brainrot god"] = 0, secret = 0 },
		mutations = { normal = 58, golden = 22, diamond = 11, lava = 5.2, galaxy = 2.4, rainbow = 1.4 },
	},
	[6] = {
		categories = { common = 0, uncommon = 0, rare = 14, epic = 26, mythic = 32, legendary = 22, ["brainrot god"] = 6, secret = 0 },
		mutations = { normal = 52, golden = 24, diamond = 12, lava = 6.5, galaxy = 3.5, rainbow = 2 },
	},
	[7] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 12, mythic = 28, legendary = 36, ["brainrot god"] = 20, secret = 4 },
		mutations = { normal = 48, golden = 24, diamond = 14, lava = 7.5, galaxy = 4, rainbow = 2.5 },
	},
	[8] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 16, legendary = 38, ["brainrot god"] = 34, secret = 12 },
		mutations = { normal = 44, golden = 25, diamond = 15, lava = 8, galaxy = 5, rainbow = 3 },
	},
	[9] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 32, ["brainrot god"] = 48, secret = 20 },
		mutations = { normal = 42, golden = 26, diamond = 16, lava = 8.5, galaxy = 4.5, rainbow = 3 },
	},
	[10] = {
		categories = { common = 0, uncommon = 0, rare = 0, epic = 0, mythic = 0, legendary = 28, ["brainrot god"] = 52, secret = 20 },
		mutations = { normal = 40, golden = 28, diamond = 16, lava = 8, galaxy = 5, rainbow = 3 },
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

local CATEGORY_ORDER: { RarityId } = { "common", "uncommon", "rare", "epic", "mythic", "legendary", "brainrot god", "secret" }
local MUTATION_ORDER: { MutationId } = { "normal", "golden", "diamond", "lava", "galaxy", "rainbow" }

-- 1x → 0, 10x → ~0.38, 50x → ~0.65, 450x → ~0.94
function M.luckMixT(displayLuck: number): number
	local d = math.max(1, displayLuck)
	if d <= 1.01 then
		return 0
	end
	return math.clamp(math.log10(d) / math.log10(500), 0, 0.94)
end

local function mixNumber(a: number, b: number, t: number): number
	return a * (1 - t) + b * t
end

local function mixWeights(a: { [string]: number }, b: { [string]: number }, t: number, keys: { string }): { [string]: number }
	local out = {}
	for _, k in keys do
		out[k] = mixNumber(a[k] or 0, b[k] or 0, t)
	end
	return out
end

-- Move a slice of each lower rarity/mutation into the next one so last-land luck still matters.
local function shiftTowardEnd(weights: { [string]: number }, keys: { string }, t: number)
	if t <= 0 then
		return
	end
	local moveFrac = 0.22 * math.clamp(t, 0, 1)
	for i = #keys, 2, -1 do
		local prev = keys[i - 1]
		local cur = keys[i]
		local take = (weights[prev] or 0) * moveFrac
		if take > 0 then
			weights[prev] = (weights[prev] or 0) - take
			weights[cur] = (weights[cur] or 0) + take
		end
	end
end

function M.chancesWithLuck(plot: number, displayLuck: number?): PlotChanceDef
	local basePlot = math.clamp(math.floor(plot), 1, M.MAX_PLOT)
	local t = M.luckMixT(if typeof(displayLuck) == "number" then displayLuck else 1)
	local a = M.PLOT_CHANCES[basePlot]
	local nextPlot = math.min(basePlot + 1, M.MAX_PLOT)
	local next2Plot = math.min(basePlot + 2, M.MAX_PLOT)
	local b = M.PLOT_CHANCES[nextPlot]
	local c = M.PLOT_CHANCES[next2Plot]
	local t2 = t * t * 0.35
	local t1 = t * (1 - t2)
	local categories = mixWeights(a.categories, b.categories, t1, CATEGORY_ORDER)
	local mutations = mixWeights(a.mutations, b.mutations, t1, MUTATION_ORDER)
	if t2 > 0.002 then
		categories = mixWeights(categories, c.categories, t2, CATEGORY_ORDER)
		mutations = mixWeights(mutations, c.mutations, t2, MUTATION_ORDER)
	end
	if nextPlot == basePlot then
		shiftTowardEnd(categories, CATEGORY_ORDER, t)
		shiftTowardEnd(mutations, MUTATION_ORDER, t * 0.55)
	end
	return {
		categories = categories :: any,
		mutations = mutations :: any,
	}
end

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

function M.rollMutation(plot: number, displayLuck: number?): MutationId
	local chances = M.chancesWithLuck(plot, displayLuck)
	local pick = weightedPick(chances.mutations)
	if pick then
		return pick :: MutationId
	end
	return "normal"
end

function M.rollRarity(plot: number, displayLuck: number?): RarityId?
	local chances = M.chancesWithLuck(plot, displayLuck)
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

function M.pickRandomBrainrotForPlot(plot: number, available: ((BrainrotDef) -> boolean)?, displayLuck: number?): (BrainrotDef?, MutationId)
	local mutation: MutationId = M.rollMutation(plot, displayLuck)
	local rarity = M.rollRarity(plot, displayLuck)
	if not rarity then
		return nil, mutation
	end
	local pool = M.brainrotsOfRarity(rarity, available)
	if #pool == 0 and available ~= nil then
		pool = M.brainrotsOfRarity(rarity, nil)
	end
	if #pool == 0 then
		-- Fall downward from the rolled rarity — never jump to secret first.
		local startIdx = 1
		for i, def in ipairs(M.RARITIES) do
			if def.id == rarity then
				startIdx = i
				break
			end
		end
		for i = startIdx - 1, 1, -1 do
			local r = M.RARITIES[i].id
			pool = M.brainrotsOfRarity(r, available)
			if #pool > 0 then
				break
			end
		end
	end
	if #pool == 0 then
		return nil, mutation
	end
	return pool[math.random(1, #pool)], mutation
end

local function folderHasMeshCatalog(folder: Instance): boolean
	return folder:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

function M.getBrainrotsFolder(): Folder?
	local ss = ServerStorage:FindFirstChild("Brainrots")
	if ss and ss:IsA("Folder") and folderHasMeshCatalog(ss) then
		return ss
	end
	local rs = ReplicatedStorage:FindFirstChild("Brainrots")
	if rs and rs:IsA("Folder") and folderHasMeshCatalog(rs) then
		return rs
	end
	if ss and ss:IsA("Folder") then
		return ss
	end
	if rs and rs:IsA("Folder") then
		return rs
	end
	return nil
end

function M.getTemplatesFolder(): Folder?
	local f = ServerStorage:FindFirstChild("Templates")
	if f and f:IsA("Folder") then
		return f
	end
	local essential = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local eaTemplates = essential and essential:FindFirstChild("Templates")
	if eaTemplates and eaTemplates:IsA("Folder") then
		return eaTemplates :: Folder
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

local function isUsableBaseTemplate(template: Instance): boolean
	if not (template:IsA("Model") or template:IsA("Folder")) then
		return false
	end
	if template:FindFirstChild("1 Story") or template:FindFirstChild("1st Story") then
		return true
	end
	for _, ch in ipairs(template:GetChildren()) do
		if ch:IsA("Model") or ch:IsA("Folder") then
			return true
		end
	end
	return #template:GetDescendants() > 0
end

function M.getBaseTemplate(): Instance?
	local candidates: { Instance } = {}
	local function push(folder: Instance?)
		if not folder then
			return
		end
		local base = folder:FindFirstChild("Base")
		if base then
			table.insert(candidates, base)
		end
	end
	push(ServerStorage:FindFirstChild("Templates"))
	local essential = ReplicatedStorage:FindFirstChild("EssentialAssets")
	push(essential and essential:FindFirstChild("Templates"))
	push(ReplicatedStorage:FindFirstChild("Templates"))

	local fallback: Instance? = nil
	for _, template in ipairs(candidates) do
		if isUsableBaseTemplate(template) then
			if template:FindFirstChild("1 Story") or template:FindFirstChild("1st Story") then
				return template
			end
			if not fallback then
				fallback = template
			end
		end
	end
	return fallback
end

return M
