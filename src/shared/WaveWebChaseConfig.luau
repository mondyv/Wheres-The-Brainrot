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

-- Authored Wave Web pose. Always Orientation 0, 90, 0 at the land-lock Position
-- (Studio copy). Slide along Z only toward the safezone.
M.WAVE_SPAWN_POS = Vector3.new(1451.097, 92.301, 699.687)
M.WAVE_SPAWN_ORIENTATION_DEG = Vector3.new(0, 90, 0)
M.WAVE_SPAWN_YAW_DEG = 90
M.WAVE_CRUISE_Y = 92.301
M.WAVE_BEHIND_STUDS = 72
M.WAVE_RISE_STUDS = 52
M.WAVE_RISE_SEC = 1.2
M.WAVE_KILL_DISTANCE = 5
M.WAVE_KILL_GRACE_SEC = 3.4
-- Never ScaleTo the Wave Web mesh — it freezes/crashes Studio & clients.
M.WAVE_SCALE = 1

-- Per-land charge speed (studs/s). Walk is ~18; land 4 should force a real run-home.
M.WAVE_SPEED_BY_LAND = {
	26, -- 1 baby
	30, -- 2 normal
	34, -- 3 speed
	39, -- 4 gigantic
	43, -- 5 titan
	46, -- 6 colossal
	49, -- 7 cosmic
	52, -- 8 infinitum
	54, -- 9 omega
	56, -- 10 transcendent
}

-- Billboard names + StarterGui.Gradients child names.
M.WEB_TITLES = {
	{ name = "👶 baby web 👶", gradient = "Basic/Common" },
	{ name = "🕸️ normal web 🕸️", gradient = "Green" },
	{ name = "⚡ speed web ⚡", gradient = "Yellow/Gold" },
	{ name = "🕷️ gigantic web 🕷️", gradient = "Rare" },
	{ name = "🔥 titan web 🔥", gradient = "Red" },
	{ name = "⛰️ colossal web ⛰️", gradient = "Epic" },
	{ name = "🪐 cosmic web 🪐", gradient = "Diamond" },
	{ name = "🌌 infinitum web 🌌", gradient = "Rainbow" },
	{ name = "☄️ omega web ☄️", gradient = "Mythical" },
	{ name = "♾️ transcendent web ♾️", gradient = "BrainrotGod" },
}

M.SAFEZONE_CONFIRM_SEC = 0.22
M.EXCLAMATION_SEC = 1.05
M.INTRO_REVEAL_SEC = 0.7

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

function M.speedForLand(land: number): number
	local i = math.clamp(math.floor(land), 1, #M.WAVE_SPEED_BY_LAND)
	return M.WAVE_SPEED_BY_LAND[i]
end

function M.titleForLand(land: number): { name: string, gradient: string }
	local i = math.clamp(math.floor(land), 1, #M.WEB_TITLES)
	return M.WEB_TITLES[i]
end

return M
