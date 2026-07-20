-- [ACTIVE] ReviveConfig
--[[
	Revive dev products — one per land tier (Land 1–10).
	Shared by Revive.server + ReviveController (regional price lookup).
--]]

local M = {}

M.COUNTDOWN_SECONDS = 10
M.BGM_PLAYBACK_SPEED = 0.78
M.BGM_SLOW_FADE_SECONDS = 1.2
M.REVIVE_SPAWN_ATTR = "ReviveSpawnCFrame" -- legacy
M.REVIVE_SPAWN_POS_ATTR = "ReviveSpawnPos"
M.REVIVE_SPAWN_LOOK_ATTR = "ReviveSpawnLook"
M.MAX_LAND = 10

export type ReviveTier = {
	land: number,
	defaultPrice: number,
	productId: number,
}

M.TIERS = {
	{ land = 1, defaultPrice = 9, productId = 3601300199 },
	{ land = 2, defaultPrice = 19, productId = 3601300494 },
	{ land = 3, defaultPrice = 29, productId = 3601300562 },
	{ land = 4, defaultPrice = 39, productId = 3601300762 },
	{ land = 5, defaultPrice = 49, productId = 3601301021 },
	{ land = 6, defaultPrice = 69, productId = 3601301073 },
	{ land = 7, defaultPrice = 89, productId = 3601301164 },
	{ land = 8, defaultPrice = 119, productId = 3601301395 },
	{ land = 9, defaultPrice = 149, productId = 3601301531 },
	{ land = 10, defaultPrice = 199, productId = 3601301622 },
}

local productToLand: { [number]: number } = {}
local landToTier: { [number]: ReviveTier } = {}

for _, tier in M.TIERS do
	productToLand[tier.productId] = tier.land
	landToTier[tier.land] = tier
end

function M.clampLand(land: number): number
	return math.clamp(math.floor(land), 1, M.MAX_LAND)
end

function M.tierForLand(land: number): ReviveTier
	local clamped = M.clampLand(land)
	return landToTier[clamped] or M.TIERS[1]
end

function M.productIdForLand(land: number): number
	return M.tierForLand(land).productId
end

function M.defaultPriceForLand(land: number): number
	return M.tierForLand(land).defaultPrice
end

function M.landForProductId(productId: number): number?
	return productToLand[productId]
end

function M.isReviveProduct(productId: number): boolean
	return productToLand[productId] ~= nil
end

return M
