-- [ACTIVE] WaveWebChaseConfig
--[[
	After accepting a bush brainrot: spider intro + Wave Web tsunami chase to safezone.
	Assets: ReplicatedStorage.EssentialAssets["Wave Web"], EssentialAssets.Spider
]]

local M = {}

M.ENABLED = true

M.WAVE_WEB_PATH = { "EssentialAssets", "Wave Web" }
M.SPIDER_TEMPLATE_PATH = { "EssentialAssets", "Spider" }
M.SPIDER_VFX_FOLDER_PATH = { "EssentialAssets", "SpiderVFX" }
M.SPIDER_BLOW_VFX_NAME = "Blow"

M.EXCLAMATION_IMAGE = "rbxassetid://109532578234890"

M.DELAY_AFTER_ACCEPT_SEC = 1.55

M.SPIDER_ANIM = {
	RAGE = "96475299364690",
}

M.SPIDER_DROP_HEIGHT = 18
M.SPIDER_YAW_OFFSET = math.pi
M.SPIDER_MIN_PLAYER_DISTANCE = 22
M.SPIDER_MAX_PLAYER_DISTANCE = 58
M.LAND_EDGE_MARGIN = 14

M.WAVE_SPAWN_DISTANCE = 165
M.WAVE_TRAIL_DISTANCE = 72
M.WAVE_BASE_SPEED = 32
M.WAVE_MAX_SPEED = 56
M.WAVE_SPEED_RAMP_SEC = 22
M.WAVE_CATCH_DISTANCE = 14
M.WAVE_CATCH_PUSH_SPEED = 68

M.SAFEZONE_CONFIRM_SEC = 0.28

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

return M
