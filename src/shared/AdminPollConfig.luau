-- [ACTIVE] AdminPollConfig
--[[
	Shared names and limits for admin polls (composer + live HUD).
]]

local M = {}

M.CREATE_REMOTE = "AdminCreatePoll"
M.START_REMOTE = "AdminPollStart"
M.UPDATE_REMOTE = "AdminPollUpdate"
M.VOTE_REMOTE = "AdminPollVote"
M.MESSAGING_TOPIC = "AdminGlobalPoll_v1"
M.OPEN_SIGNAL = "OPEN_POLL_COMPOSER"

M.MAX_QUESTION = 80
M.MAX_OPTION = 28
M.MIN_OPTIONS = 2
M.MAX_OPTIONS = 4
M.DURATION_SEC = 45
M.END_HOLD_SEC = 4.2
M.GLOBAL_SYNC_SEC = 0.8

return M
