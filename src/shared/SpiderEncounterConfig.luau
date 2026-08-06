-- [ACTIVE] SpiderEncounterConfig
--[[
	Bush brainrot-accept spider ambush — animation asset IDs and timing.
	Spider rig: ReplicatedStorage.EssentialAssets.Spider (Studio).
]]

local M = {}

M.ENABLED = true
M.TRIGGER_CHANCE = 0.3

M.SPIDER_TEMPLATE_PATH = { "EssentialAssets", "Spider" }
M.SPIDER_VFX_FOLDER_PATH = { "EssentialAssets", "SpiderVFX" }
M.SPIDER_BLOW_VFX_NAME = "Blow"
M.SPIDER_SPIDEY_SENSES_NAME = "Spidey senses"
M.SPIDER_SPIDEY_SENSES_HUMAN_NAME = "Spidey senses human"
M.SPIDER_SHOOTING_WEB_NAME = "Shooting Web"
M.SPIDER_BLOW_VFX_LIFETIME = 1.35

M.ANIM = {
	RAGE = "96475299364690",
	WEB = "136236258564046",
}

M.DROP_HEIGHT = 18
M.SPIDER_MIN_PLAYER_DISTANCE = 24
M.SPIDER_MAX_PLAYER_DISTANCE = 70
-- Keep spider well inside Spawn (not on the rim / ledge).
M.LAND_EDGE_MARGIN = 16
M.WEB_ANIM_WINDUP = 0.55
M.WEB_SHOOT_AT = 0.72
M.WEB_ANIM_FALLBACK_SEC = 1.15
M.RAGE_FALLBACK_SEC = 1.85
M.RAGE_CAMERA_ZOOM_FOV = 26
M.WEB_TRAVEL_TIME = 3.2
M.WEB_FADE_OUT = 0.35
-- Tip axis in model space that should point along flight. nil = use Shooting Web.Point, else longest size.
-- Manual overrides if needed: Vector3.yAxis, -Vector3.zAxis, Vector3.zAxis, etc.
M.WEB_SHOT_TIP_LOCAL = nil :: Vector3?

-- Single closing ring: base size matches key badge; starts larger, closes to 1.
M.RING_OUTER_PX = 78
M.RING_START_SCALE = 1.55
M.RING_CLOSED_SCALE = 1.0
M.SPIDER_YAW_OFFSET = math.pi
M.QTE_CLOSE_MIN = 0.72
M.QTE_CLOSE_MAX = 1.18
-- Keyboard letters for PC. Gamepad always uses ButtonA (Cross on PlayStation).
M.QTE_GAMEPAD_KEY = Enum.KeyCode.ButtonA
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

-- Mild BGM duck (was 0.42); web QTE uses BGM_WEB_SPEED (was ~0.09 stacked crawl).
M.BGM_SLOW_SPEED = 0.78
M.BGM_WEB_SPEED = 0.62
M.BGM_SLOW_FADE = 0.55
M.BGM_RESTORE_FADE = 0.7

return M
