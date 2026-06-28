-- [ACTIVE] BrainrotStandConfig
--[[
	Stand brainrot upgrade dev products + level gains (client + server).
]]

local M = {}

M.NORMAL_LEVEL_GAIN = 1
M.PLUS_25_LEVEL_GAIN = 25

-- Robux: +25 levels per upgrade (2× Upgrades gamepass tier).
M.PLUS_25_DEV_PRODUCT_ID = 3602369225
-- Robux: complete one cash upgrade when the player cannot afford it.
M.CANT_AFFORD_DEV_PRODUCT_ID = 3602369815

return M
