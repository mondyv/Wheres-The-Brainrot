-- [ACTIVE] AdminGiftConfig
--[[
	Admin gift drops (sky-fall + inventory) and reward-poll grants.
]]

local M = {}

M.DROP_REMOTE = "AdminGiftDrop"
M.MESSAGING_TOPIC = "AdminGlobalGift_v1"

M.REASON_ADMIN = "admin"
M.REASON_REWARD_POLL = "rewardPoll"

M.MAX_COUNT = 25
M.GLOBAL_MAX_COUNT = 3
-- Client drop: fall + impact + suck-in. Grant after this so inventory waits for the cutscene.
M.GRANT_DELAY_SEC = 2.05

return M
