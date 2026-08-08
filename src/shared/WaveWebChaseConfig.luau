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
M.SPIDER_PRELOAD_SEC = 0.45

-- Far enough to feel like a tsunami rolling in.
M.WAVE_SPAWN_DISTANCE = 175
-- Kill when the wave center gets this close (studs, XZ).
M.WAVE_KILL_DISTANCE = 16
-- Extra yaw if the Wave Web mesh faces the wrong axis (radians).
-- 0 = LookVector = travel direction; tweak ±90/180 if the mesh forward differs.
M.WAVE_FACE_YAW_OFFSET = 0

-- Land-scaled chase speed (studs/sec). Land 1 is leisurely; Land 10 is the threat.
M.WAVE_SPEED_LAND1 = 18
M.WAVE_SPEED_LAND10 = 42

M.SAFEZONE_CONFIRM_SEC = 0.22
M.EXCLAMATION_SEC = 1.25

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

function M.speedForLand(land: number): number
	local t = (math.clamp(land, 1, 10) - 1) / 9
	return M.WAVE_SPEED_LAND1 + (M.WAVE_SPEED_LAND10 - M.WAVE_SPEED_LAND1) * t
end

return M
