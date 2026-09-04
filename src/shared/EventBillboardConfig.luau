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
M.WINDOW_LABEL = "Tue, Sep 8 · 6:00 PM – 9:00 PM" -- fallback if local format fails
M.PROMPT_ACTION = "Join Event"
M.PROMPT_OBJECT = "Community Event"
M.MAX_DISTANCE = 18

-- Rest pose (Studio): faces the path. Sway animates around this CFrame.
M.REST_POSITION = Vector3.new(1545.32, 96.794, 921.476)
M.REST_ORIENTATION_DEG = Vector3.new(0, 74.939, -0.002)

M.FLOAT_BOB_STUDS = 0.72
M.FLOAT_BOB_SPEED = 1.08
M.FLOAT_YAW_DEG = 6.2
M.FLOAT_ROLL_DEG = 4.1
M.FLOAT_DRIFT_STUDS = 0.42
M.FLOAT_YAW_SPEED = 0.82
M.FLOAT_ROLL_SPEED = 0.7
M.FLOAT_DRIFT_SPEED = 0.48
M.SWAY_MAX_DISTANCE = 220

M.SHINE_DURATION = 2.85
M.SHINE_PAUSE = 7.2
M.SHINE_ROTATION = 24
M.SHINE_MAX_DISTANCE = 160

-- 6:00 PM UTC+4 = 14:00 UTC; 9:00 PM UTC+4 = 17:00 UTC.
M.START_UNIX = DateTime.fromUniversalTime(2026, 9, 8, 14, 0, 0).UnixTimestamp
M.END_UNIX = DateTime.fromUniversalTime(2026, 9, 8, 17, 0, 0).UnixTimestamp

return M
