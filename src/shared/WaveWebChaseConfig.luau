-- [ACTIVE] WaveWebChaseConfig
--[[
	After accepting a bush brainrot: spider intro → clone EssentialAssets["Wave Web"]
	at the authored mid-map pose (player X, fixed Y/Z) and roll toward the player.
	Keep this light — heavy ScaleTo / particle bursts crash clients.
]]

local M = {}

M.ENABLED = true

M.WAVE_WEB_PATH = { "EssentialAssets", "Wave Web" }
M.SPIDER_TEMPLATE_PATH = { "EssentialAssets", "Spider" }
M.SPIDER_VFX_FOLDER_PATH = { "EssentialAssets", "SpiderVFX" }
M.SPIDER_BLOW_VFX_NAME = "Blow"
M.SPIDER_SPIDEY_SENSES_NAME = "Spidey senses"
M.SPIDER_SPIDEY_SENSES_HUMAN_NAME = "Spidey senses human"
M.SPIDER_SHOOTING_WEB_NAME = "Shooting Web"

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
M.SPIDER_PRELOAD_SEC = 0.35

-- Authored Wave Web pose (map middle). X follows the player; Y/Z stay put.
M.WAVE_SPAWN_POS = Vector3.new(1448.013, 92.301, 205.634)
M.WAVE_SPAWN_YAW_DEG = 90
M.WAVE_SPAWN_BACK_FROM_CENTER = 40
M.WAVE_KILL_DISTANCE = 16
-- Never ScaleTo the Wave Web mesh — it freezes/crashes Studio & clients.
M.WAVE_SCALE = 1

M.WAVE_SPEED_LAND1 = 30
M.WAVE_SPEED_LAND10 = 52

M.SAFEZONE_CONFIRM_SEC = 0.22
M.EXCLAMATION_SEC = 1.2

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

function M.speedForLand(land: number): number
	local t = (math.clamp(land, 1, 10) - 1) / 9
	return M.WAVE_SPEED_LAND1 + (M.WAVE_SPEED_LAND10 - M.WAVE_SPEED_LAND1) * t
end

return M
