-- [ACTIVE] EventBillboardConfig
--[[
	Workspace.Map.EventBillboard — countdown + join prompt.
	Event times: Tue Sep 8, 2026 6:00 PM – 9:00 PM (UTC+4).
	EVENT_ID must stay a string (64-bit ids do not fit in a Lua number).
]]

local M = {}

M.EVENT_ID = "6811233161754837626"
M.EVENT_URL = "https://www.roblox.com/events/6811233161754837626"
M.MODEL_NAME = "EventBillboard"
M.WINDOW_LABEL = "Tue, Sep 8 · 6:00 PM – 9:00 PM"
M.PROMPT_ACTION = "Join Event"
M.PROMPT_OBJECT = "Community Event"
M.MAX_DISTANCE = 18

-- 6:00 PM UTC+4 = 14:00 UTC; 9:00 PM UTC+4 = 17:00 UTC.
M.START_UNIX = DateTime.fromUniversalTime(2026, 9, 8, 14, 0, 0).UnixTimestamp
M.END_UNIX = DateTime.fromUniversalTime(2026, 9, 8, 17, 0, 0).UnixTimestamp

return M
