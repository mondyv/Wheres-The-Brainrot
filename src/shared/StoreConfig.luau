-- [ACTIVE] StoreConfig
--[[
	StoreConfig
	Single source of truth (client + server) for every Store item:
	gamepass ids, developer product ids, booster pack definitions,
	cash bundle reward multipliers, steal rarity → product mapping, and the
	player-attribute names used to track ownership / one-time grants.

	IMPORTANT: this module must stay require-safe from BOTH the client and the
	server. It contains data only — no service side effects.
--]]

local StoreConfig = {}

-- ── Gamepass ids ──────────────────────────────────────────────────────────────
StoreConfig.GAMEPASS = {
	VIP = 1862643274,
	XRAY = 1865098421,
	DOUBLE_UPGRADES = 1862818467,
	DOUBLE_CASH = 1866666344,
	SUPER_LUCK = 1863082382,
	MEGA_LUCK = 1866440312,
	AUTOCOLLECT = 1892789728,
}

-- ── Developer product ids ───────────────────────────────────────────────────────
StoreConfig.PRODUCT = {
	EXCLUSIVE_BRAINROT = 3601996606,
	RANDOM_BRAINROT = 3604806744,
	SERVER_LUCK = 3601997089,

	CASH_BUNDLE_1 = 3602163836,
	CASH_BUNDLE_2 = 3602164595,
	CASH_BUNDLE_3 = 3602164776,
	CASH_BUNDLE_4 = 3602164890,
	CASH_BUNDLE_5 = 3602165053,

	STAND_UPGRADE_PLUS_25 = 3602369225,
	STAND_UPGRADE_CANT_AFFORD = 3602369815,

	STARTER_PACK = 3602172485,
	MYTHIC_PACK = 3602172591,
	GODLY_PACK = 3602172812,
	SECRET_PACK = 3602172984,
}

-- ── Player attribute names ──────────────────────────────────────────────────────
StoreConfig.ATTR = {
	-- Gamepass ownership flags / values
	VIP_OWNED = "VIPOwned",
	VIP_LUCK_MULT = "VIPLuckMultiplier",
	DOUBLE_CASH_OWNED = "DoubleCashOwned",
	DOUBLE_UPGRADES_OWNED = "DoubleUpgradesOwned",
	SUPER_LUCK_OWNED = "SuperLuckOwned",
	MEGA_LUCK_OWNED = "MegaLuckOwned",
	XRAY_OWNED = "XrayVisionOwned",
	AUTOCOLLECT_OWNED = "AutoCollectOwned",

	-- Custom saved entitlements granted by the gifting system.
	GIFTED_VIP = "GiftedVIP",
	GIFTED_DOUBLE_CASH = "GiftedDoubleCash",
	GIFTED_DOUBLE_UPGRADES = "GiftedDoubleUpgrades",
	GIFTED_SUPER_LUCK = "GiftedSuperLuck",
	GIFTED_MEGA_LUCK = "GiftedMegaLuck",
	GIFTED_XRAY = "GiftedXray",
	GIFTED_AUTOCOLLECT = "GiftedAutoCollect",

	-- Durable purchase record (survives rejoin for owners/testers where marketplace ownership is untrusted).
	PURCHASED_VIP = "PurchasedVIP",
	PURCHASED_DOUBLE_CASH = "PurchasedDoubleCash",
	PURCHASED_DOUBLE_UPGRADES = "PurchasedDoubleUpgrades",
	PURCHASED_SUPER_LUCK = "PurchasedSuperLuck",
	PURCHASED_MEGA_LUCK = "PurchasedMegaLuck",
	PURCHASED_XRAY = "PurchasedXray",
	PURCHASED_AUTOCOLLECT = "PurchasedAutoCollect",

	-- One-time / counter grants
	EXCLUSIVE_OWNED = "ExclusiveBrainrotOwned",
	FREE_STEAL_COUNT = "FreeStealCount",
	FREE_UNCOMMON_CLAIMED = "FreeUncommonClaimed",
	GROUP_REWARD_CLAIMED = "GroupRewardClaimed",

	-- Booster pack purchase counters (capped at 2)
	STARTER_PACK_BOUGHT = "StarterPackBought",
	MYTHIC_PACK_BOUGHT = "MythicPackBought",
	GODLY_PACK_BOUGHT = "GodlyPackBought",
	SECRET_PACK_BOUGHT = "SecretPackBought",
}

-- UV Unwrapped community — Group Stand join reward.
StoreConfig.GROUP_ID = 34716703
StoreConfig.GROUP_STAND_NAME = "Group Stand"

-- Replicated (ReplicatedStorage) attributes for server-wide luck.
StoreConfig.SERVER_LUCK_MULT_ATTR = "ServerLuckMultiplier"
StoreConfig.SERVER_LUCK_ENDS_ATTR = "ServerLuckEndsAt"
StoreConfig.SERVER_LUCK_DURATION = 600 -- 10 minutes added per purchase

-- ── Luck multiplier values ──────────────────────────────────────────────────────
StoreConfig.VIP_LUCK_MULTIPLIER = 4
StoreConfig.SUPER_LUCK_MULTIPLIER = 2 -- +100%
StoreConfig.MEGA_LUCK_MULTIPLIER = 3.5 -- +250%
StoreConfig.VIP_FREE_STEALS = 2
StoreConfig.VIP_CASH_MULTIPLIER = 1.5
StoreConfig.DOUBLE_CASH_MULTIPLIER = 2

-- ── Booster packs ───────────────────────────────────────────────────────────────
-- luckyBlock        = container name under ReplicatedStorage["Lucky Blocks"]["lucky blocks"].
-- luckyBlockVariant = the specific child Model (the actual tool model) inside that
--                     container. These containers group several visual variants, so we
--                     must point at one; if it can't be found the grant falls back to
--                     the container's first child Model.
StoreConfig.PACKS = {
	{
		key = "StarterPack",
		productId = StoreConfig.PRODUCT.STARTER_PACK,
		boughtAttr = StoreConfig.ATTR.STARTER_PACK_BOUGHT,
		luckyBlock = "Starter Lucky Block",
		luckyBlockVariant = "basic",
		cash = 250000,
		brainrot = "Ben",
		frameName = "StarterPack",
	},
	{
		key = "MythicPack",
		productId = StoreConfig.PRODUCT.MYTHIC_PACK,
		boughtAttr = StoreConfig.ATTR.MYTHIC_PACK_BOUGHT,
		luckyBlock = "Mythic Lucky Block",
		luckyBlockVariant = "67",
		cash = 167000000,
		brainrot = "EsokSekolah",
		frameName = "MythicPack",
	},
	{
		key = "GodlyPack",
		productId = StoreConfig.PRODUCT.GODLY_PACK,
		boughtAttr = StoreConfig.ATTR.GODLY_PACK_BOUGHT,
		luckyBlock = "Godly Luckyblock",
		luckyBlockVariant = "blue",
		cash = 1500000000,
		brainrot = "CachorritoMelonito",
		frameName = "GodlyPack",
	},
	{
		key = "SecretPack",
		productId = StoreConfig.PRODUCT.SECRET_PACK,
		boughtAttr = StoreConfig.ATTR.SECRET_PACK_BOUGHT,
		luckyBlock = "Secret Lucky Block",
		luckyBlockVariant = "transparent",
		cash = 150000000000,
		brainrot = "NuclearoDinosauro",
		frameName = "SecretPack",
	},
}

StoreConfig.PACK_PURCHASE_LIMIT = 2

-- Developer products that may be purchased for another player through GiftsService.
StoreConfig.GIFTABLE_PRODUCTS = {
	[StoreConfig.PRODUCT.RANDOM_BRAINROT] = {
		displayName = "Random Brainrot",
		rewardKind = "randomBrainrot",
	},
}

StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID = {
	[StoreConfig.GAMEPASS.VIP] = StoreConfig.ATTR.GIFTED_VIP,
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = StoreConfig.ATTR.GIFTED_DOUBLE_CASH,
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = StoreConfig.ATTR.GIFTED_DOUBLE_UPGRADES,
	[StoreConfig.GAMEPASS.SUPER_LUCK] = StoreConfig.ATTR.GIFTED_SUPER_LUCK,
	[StoreConfig.GAMEPASS.MEGA_LUCK] = StoreConfig.ATTR.GIFTED_MEGA_LUCK,
	[StoreConfig.GAMEPASS.XRAY] = StoreConfig.ATTR.GIFTED_XRAY,
	[StoreConfig.GAMEPASS.AUTOCOLLECT] = StoreConfig.ATTR.GIFTED_AUTOCOLLECT,
}

StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID = {
	[StoreConfig.GAMEPASS.VIP] = StoreConfig.ATTR.PURCHASED_VIP,
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = StoreConfig.ATTR.PURCHASED_DOUBLE_CASH,
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = StoreConfig.ATTR.PURCHASED_DOUBLE_UPGRADES,
	[StoreConfig.GAMEPASS.SUPER_LUCK] = StoreConfig.ATTR.PURCHASED_SUPER_LUCK,
	[StoreConfig.GAMEPASS.MEGA_LUCK] = StoreConfig.ATTR.PURCHASED_MEGA_LUCK,
	[StoreConfig.GAMEPASS.XRAY] = StoreConfig.ATTR.PURCHASED_XRAY,
	[StoreConfig.GAMEPASS.AUTOCOLLECT] = StoreConfig.ATTR.PURCHASED_AUTOCOLLECT,
}

StoreConfig.OWNED_GAMEPASS_ATTR_BY_ID = {
	[StoreConfig.GAMEPASS.VIP] = StoreConfig.ATTR.VIP_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = StoreConfig.ATTR.DOUBLE_CASH_OWNED,
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED,
	[StoreConfig.GAMEPASS.SUPER_LUCK] = StoreConfig.ATTR.SUPER_LUCK_OWNED,
	[StoreConfig.GAMEPASS.MEGA_LUCK] = StoreConfig.ATTR.MEGA_LUCK_OWNED,
	[StoreConfig.GAMEPASS.XRAY] = StoreConfig.ATTR.XRAY_OWNED,
	[StoreConfig.GAMEPASS.AUTOCOLLECT] = StoreConfig.ATTR.AUTOCOLLECT_OWNED,
}

-- Store gift-panel picker: developer products whose grant is redirected to the
-- Store's selected recipient instead of the buyer. See StoreHandler.server for
-- the redirect logic (pending gift → receipt interceptor → grant to recipient).
StoreConfig.GIFTABLE_STORE_PRODUCT_IDS = {
	[StoreConfig.PRODUCT.RANDOM_BRAINROT] = true,
	[StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT] = true,
	[StoreConfig.PRODUCT.CASH_BUNDLE_1] = true,
	[StoreConfig.PRODUCT.CASH_BUNDLE_2] = true,
	[StoreConfig.PRODUCT.CASH_BUNDLE_3] = true,
	[StoreConfig.PRODUCT.CASH_BUNDLE_4] = true,
	[StoreConfig.PRODUCT.CASH_BUNDLE_5] = true,
	[StoreConfig.PRODUCT.STARTER_PACK] = true,
	[StoreConfig.PRODUCT.MYTHIC_PACK] = true,
	[StoreConfig.PRODUCT.GODLY_PACK] = true,
	[StoreConfig.PRODUCT.SECRET_PACK] = true,
}

function StoreConfig.isStoreProductGiftable(productId: number): boolean
	return StoreConfig.GIFTABLE_STORE_PRODUCT_IDS[productId] == true
end

-- Fill `giftProductId` with a developer product id for each giftable pass when
-- the products exist in Roblox. Gamepass ownership itself is not transferred.
-- Roblox always grants PromptGamePassPurchase to the purchaser, so a gamepass
-- can only be gifted through a *separate* gift-only developer product — create
-- one per pass in Studio and paste its id below (StoreConfig.getGiftGamepassProductId
-- reads it). Until filled in, the Store's gift flow rejects that pass with a
-- clear "not available yet" message instead of charging anyone.
StoreConfig.GIFTABLE_GAMEPASSES = {
	[StoreConfig.GAMEPASS.VIP] = {
		displayName = "VIP",
		entitlementKey = StoreConfig.ATTR.GIFTED_VIP,
		giftProductId = 3604960196,
	},
	[StoreConfig.GAMEPASS.DOUBLE_CASH] = {
		displayName = "2x Cash",
		entitlementKey = StoreConfig.ATTR.GIFTED_DOUBLE_CASH,
		giftProductId = 3604960744,
	},
	[StoreConfig.GAMEPASS.DOUBLE_UPGRADES] = {
		displayName = "2x Upgrades",
		entitlementKey = StoreConfig.ATTR.GIFTED_DOUBLE_UPGRADES,
		giftProductId = 3604960551,
	},
	[StoreConfig.GAMEPASS.SUPER_LUCK] = {
		displayName = "Super Luck",
		entitlementKey = StoreConfig.ATTR.GIFTED_SUPER_LUCK,
		giftProductId = 3604960821,
	},
	[StoreConfig.GAMEPASS.MEGA_LUCK] = {
		displayName = "Mega Luck",
		entitlementKey = StoreConfig.ATTR.GIFTED_MEGA_LUCK,
		giftProductId = 3604960886,
	},
	[StoreConfig.GAMEPASS.XRAY] = {
		displayName = "X-Ray",
		entitlementKey = StoreConfig.ATTR.GIFTED_XRAY,
		giftProductId = 3604960365,
	},
	[StoreConfig.GAMEPASS.AUTOCOLLECT] = {
		displayName = "Collect All Cash",
		entitlementKey = StoreConfig.ATTR.GIFTED_AUTOCOLLECT,
		giftProductId = 3611827706,
	},
}

-- Returns the gift-only developer product id for a gamepass, or nil if the
-- pass isn't giftable yet (see GIFTABLE_GAMEPASSES comment above).
function StoreConfig.getGiftGamepassProductId(gamepassId: number): number?
	local entry = StoreConfig.GIFTABLE_GAMEPASSES[gamepassId]
	if entry and typeof(entry.giftProductId) == "number" and entry.giftProductId > 0 then
		return entry.giftProductId
	end
	return nil
end

-- Per-lucky-block rarity roll pools (rarity ids match Brainrots.RarityId).
-- Source of truth: Shared.LuckyBlockCatalog (keeps bush / store / admin in sync).
local LuckyBlockCatalog = require(script.Parent:WaitForChild("LuckyBlockCatalog"))
StoreConfig.LUCKY_BLOCK_RARITY_WEIGHTS = LuckyBlockCatalog.rarityWeightsById()

StoreConfig.EXCLUSIVE_BRAINROT_NAME = "StrawberryElephant"
StoreConfig.EXCLUSIVE_BRAINROT_SOURCE_PATH = "StrawberryElephant/Normal"

-- ── Cash bundles ────────────────────────────────────────────────────────────────
StoreConfig.MIN_OFFLINE_24H_CASH = 172800
StoreConfig.CASH_BUNDLE_MULTIPLIERS = {
	[StoreConfig.PRODUCT.CASH_BUNDLE_1] = 1 / 28.8,
	[StoreConfig.PRODUCT.CASH_BUNDLE_2] = 0.15625,
	[StoreConfig.PRODUCT.CASH_BUNDLE_3] = 5 / 6,
	[StoreConfig.PRODUCT.CASH_BUNDLE_4] = 10 / 3,
	[StoreConfig.PRODUCT.CASH_BUNDLE_5] = 10,
}

-- ── Steal system ────────────────────────────────────────────────────────────────
-- Product IDs must match Creator Dashboard names exactly (shifted IDs break grants).
StoreConfig.STEAL_PRODUCT_BY_RARITY = {
	common = 3602198445, -- Steal a common brainrot
	uncommon = 3602198480, -- Steal an uncommon brainrot
	rare = 3602198510, -- Steal a rare brainrot
	epic = 3602198541, -- Steal an epic brainrot
	mythic = 3602198574, -- Steal a mythic brainrot
	legendary = 3602198619, -- Steal a Legendary Brainrot
	["brainrot god"] = 3602198661, -- Steal a Brainrot God
	secret = 3602198691, -- Steal Secret Brainrot
}

-- Robux prices (display only) for the steal products above.
StoreConfig.STEAL_PRICE_BY_RARITY = {
	common = 49,
	uncommon = 79,
	rare = 149,
	epic = 249,
	mythic = 399,
	legendary = 699,
	["brainrot god"] = 999,
	secret = 1299,
}

local STEAL_RARITY_ALIASES: { [string]: string } = {
	mythical = "mythic",
	godly = "brainrot god",
	god = "brainrot god",
	brainrotgod = "brainrot god",
	["brain rot god"] = "brainrot god",
	secrets = "secret",
}

function StoreConfig.normalizeStealRarity(rarity: string): string
	local key = string.lower((string.gsub(rarity, "^%s*(.-)%s*$", "%1")))
	key = string.gsub(key, "[_%-]+", " ")
	key = string.gsub(key, "%s+", " ")
	local compact = string.gsub(key, "%s+", "")
	return STEAL_RARITY_ALIASES[key] or STEAL_RARITY_ALIASES[compact] or key
end

function StoreConfig.getStealProductId(rarity: string): number?
	local key = StoreConfig.normalizeStealRarity(rarity)
	local id = StoreConfig.STEAL_PRODUCT_BY_RARITY[key]
	return if typeof(id) == "number" then id else nil
end

function StoreConfig.getStealPriceRobux(rarity: string): number?
	local key = StoreConfig.normalizeStealRarity(rarity)
	local price = StoreConfig.STEAL_PRICE_BY_RARITY[key]
	return if typeof(price) == "number" then price else nil
end

return StoreConfig
