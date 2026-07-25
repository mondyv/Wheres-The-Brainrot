-- [ACTIVE] ReturnConfig
--[[
	Return-with-brainrot developer products — one per carry count (1–11).
]]

local M = {}

M.MAX_COUNT = 11

-- count → productId (Return 1 … Return 11)
M.PRODUCT_BY_COUNT = {
	[1] = 3607612712,
	[2] = 3607612778,
	[3] = 3607612851,
	[4] = 3607612919,
	[5] = 3607612956,
	[6] = 3607613008,
	[7] = 3607613062,
	[8] = 3607613102,
	[9] = 3607613184,
	[10] = 3607613210,
	[11] = 3607613257,
}

local productToCount: { [number]: number } = {}
for count, productId in M.PRODUCT_BY_COUNT do
	productToCount[productId] = count
end

function M.clampCount(count: number): number
	return math.clamp(math.floor(count), 1, M.MAX_COUNT)
end

function M.productIdForCount(count: number): number
	local c = M.clampCount(count)
	return M.PRODUCT_BY_COUNT[c] or M.PRODUCT_BY_COUNT[1]
end

function M.countForProductId(productId: number): number?
	return productToCount[productId]
end

function M.isReturnProduct(productId: number): boolean
	return productToCount[productId] ~= nil
end

return M
