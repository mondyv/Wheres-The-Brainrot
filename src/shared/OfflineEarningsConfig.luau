-- [ACTIVE] OfflineEarningsConfig
--[[
	Offline plot earnings + 2× Robux offer (OfflineEarnings2x panel).
]]

local M = {}

-- Must be offline at least this long before any offline income accrues.
M.MIN_OFFLINE_SECONDS = 10 * 60
-- Offline income is this fraction of live stand income (keeps AFK rewards modest).
M.INCOME_MULT = 0.2
-- Cap how long offline income can accrue (same spirit as live pad cap).
M.CAP_SECONDS = 60 * 60 * 8

-- Dev product: grant 2× the pending offline total and clear it from pads.
M.DOUBLE_DEV_PRODUCT_ID = 3610075357

return M
