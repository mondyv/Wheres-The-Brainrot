-- [ACTIVE] WaveWebChaseConfig
--[[
	After accepting a bush brainrot: spider intro → the map-placed Wave Web
	(mid-map tsunami) rolls toward the safezone. Never clone EssentialAssets["Wave Web"].
	Keep this light — heavy ScaleTo / particle bursts crash clients.
]]

local M = {}

M.ENABLED = true

-- Workspace/Map instance names (already in the place). Do not clone RS Wave Web.
M.MAP_WAVE_WEB_NAMES = { "Wave Web", "WaveWeb" }
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
