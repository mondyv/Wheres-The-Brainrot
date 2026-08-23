-- [ACTIVE] WaveWebChaseConfig
--[[
	After accepting a bush brainrot: ! then Wave Web rises behind the player
	and charges in one direction toward safezone. Speed scales with land.
	Keep this light — heavy ScaleTo / particle bursts crash clients.
]]

local M = {}

M.ENABLED = true

M.WAVE_WEB_PATH = { "EssentialAssets", "Wave Web" }
M.SPIDER_TEMPLATE_PATH = { "EssentialAssets", "Spider" }
M.SPIDER_VFX_FOLDER_PATH = { "EssentialAssets", "SpiderVFX" }
M.SPIDER_SPIDEY_SENSES_NAME = "Spidey senses"
M.SPIDER_SPIDEY_SENSES_HUMAN_NAME = "Spidey senses human"
M.SPIDER_SHOOTING_WEB_NAME = "Shooting Web"

M.EXCLAMATION_IMAGE = "rbxassetid://109532578234890"

M.DELAY_AFTER_ACCEPT_SEC = 1.0

M.SPIDER_ANIM = {
	RAGE = "96475299364690",
}

M.SPIDER_DROP_HEIGHT = 18
M.SPIDER_YAW_OFFSET = math.pi
M.SPIDER_MIN_PLAYER_DISTANCE = 14
M.SPIDER_MAX_PLAYER_DISTANCE = 32
M.LAND_EDGE_MARGIN = 14
M.SPIDER_PRELOAD_SEC = 0
M.SPIDER_RAGE_PLAY_SPEED = 1
M.SPIDER_RAGE_WAIT_SEC = 1.55
M.SPIDER_CHARGE_SEC = 0.55
M.SPIDER_CHARGE_STUDS = 34

-- Authored Wave Web pose. Always Orientation 0, 90, 0 — never lookAt-rotate.
M.WAVE_SPAWN_POS = Vector3.new(1448.013, 92.301, 205.634)
M.WAVE_SPAWN_ORIENTATION_DEG = Vector3.new(0, 90, 0)
M.WAVE_SPAWN_YAW_DEG = 90
M.WAVE_CRUISE_Y = 92.301
M.WAVE_BEHIND_STUDS = 54
M.WAVE_RISE_STUDS = 34
M.WAVE_RISE_SEC = 0.38
M.WAVE_KILL_DISTANCE = 5
M.WAVE_KILL_GRACE_SEC = 3.4
-- Never ScaleTo the Wave Web mesh — it freezes/crashes Studio & clients.
M.WAVE_SCALE = 1

-- Land 1 is jog-away pace; land 10 is pressure, not a teleport.
M.WAVE_SPEED_LAND1 = 24
M.WAVE_SPEED_LAND10 = 39

-- Billboard names on the cobweb (BrainrotHeaderStyle rarity gradients).
M.WEB_TITLES = {
	{ minLand = 1, name = "Slow Web", rarity = "common" },
	{ minLand = 2, name = "Sticky Web", rarity = "uncommon" },
	{ minLand = 4, name = "Trap Web", rarity = "rare" },
	{ minLand = 6, name = "Tangled Web", rarity = "epic" },
	{ minLand = 8, name = "Silk Wave", rarity = "mythic" },
	{ minLand = 10, name = "Godly Web", rarity = "legendary" },
}

M.SAFEZONE_CONFIRM_SEC = 0.22
M.EXCLAMATION_SEC = 1.05
M.INTRO_REVEAL_SEC = 0.7

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

function M.speedForLand(land: number): number
	local t = (math.clamp(land, 1, 10) - 1) / 9
	-- Ease in so mid lands aren't a sudden jump.
	t = t * t * (3 - 2 * t)
	return M.WAVE_SPEED_LAND1 + (M.WAVE_SPEED_LAND10 - M.WAVE_SPEED_LAND1) * t
end

function M.titleForLand(land: number): { name: string, rarity: string }
	local picked = M.WEB_TITLES[1]
	for _, entry in M.WEB_TITLES do
		if land >= entry.minLand then
			picked = entry
		end
	end
	return picked
end

return M
