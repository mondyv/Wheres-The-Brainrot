-- [ACTIVE] SpiderEncounterConfig
--[[
	Bush brainrot-accept spider ambush — animation asset IDs and timing.
	Spider rig: ReplicatedStorage.EssentialAssets.Spider (Studio).
]]

local M = {}

M.ENABLED = true
M.TRIGGER_CHANCE = 1

M.SPIDER_TEMPLATE_PATH = { "EssentialAssets", "Spider" }

M.ANIM = {
	CLIMB = "82610198667230",
	RAGE = "96475299364690",
	JUMP = "105668035268975",
	WEB = "136236258564046",
}

M.DROP_HEIGHT = 18
M.SPIDER_MIN_PLAYER_DISTANCE = 22
M.SPIDER_MAX_PLAYER_DISTANCE = 52
M.LAND_EDGE_MARGIN = 8
M.WEB_ANIM_WINDUP = 0.55
M.WEB_SHOOT_AT = 0.72
M.WEB_ANIM_FALLBACK_SEC = 1.15
M.RAGE_FALLBACK_SEC = 1.85
M.RAGE_CAMERA_ZOOM_FOV = 18
M.WEB_PROJECTILE_SIZE = Vector3.new(2.4, 2.4, 2.4)
M.WEB_TRAVEL_TIME = 2.6
M.WEB_SLOW_TIME_SCALE = 0.22

-- Rhythm dodge: outer ring shrinks onto the fixed target circle (Ring 170px → TargetRing 108px).
M.RING_OUTER_PX = 170
M.RING_TARGET_PX = 108
M.RING_START_SCALE = 1.42
M.RING_CLOSED_SCALE = M.RING_TARGET_PX / M.RING_OUTER_PX
M.SPIDER_YAW_OFFSET = math.pi
M.QTE_CLOSE_MIN = 0.86
M.QTE_CLOSE_MAX = 1.06
M.TIMING_LETTERS = {
	{ label = "E", key = Enum.KeyCode.E },
	{ label = "Q", key = Enum.KeyCode.Q },
	{ label = "R", key = Enum.KeyCode.R },
	{ label = "F", key = Enum.KeyCode.F },
	{ label = "G", key = Enum.KeyCode.G },
	{ label = "C", key = Enum.KeyCode.C },
	{ label = "X", key = Enum.KeyCode.X },
	{ label = "Z", key = Enum.KeyCode.Z },
}

M.BGM_SLOW_SPEED = 0.42
M.BGM_SLOW_FADE = 0.55
M.BGM_RESTORE_FADE = 0.7

return M
