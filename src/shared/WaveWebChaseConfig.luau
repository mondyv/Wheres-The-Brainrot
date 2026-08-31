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

-- Per-land charge speed (studs/s). Starts slower so you get a head start,
-- then eases up. Farther lands are faster, but never instant-catch.
-- Walk ~16–18; sprint ~24–32.
M.WAVE_SPEED_START_BY_LAND = {
	12, -- 1 baby
	14, -- 2 normal
	16, -- 3 speed
	17, -- 4 gigantic
	18, -- 5 titan
	20, -- 6 colossal
	21, -- 7 cosmic
	22, -- 8 infinitum
	23, -- 9 omega
	24, -- 10 transcendent
}

M.WAVE_SPEED_MAX_BY_LAND = {
	20, -- 1
	23, -- 2
	26, -- 3
	28, -- 4
	31, -- 5
	33, -- 6
	35, -- 7
	38, -- 8
	40, -- 9
	42, -- 10
}

-- Seconds from start speed to max (ease-in — stays slow at first).
M.WAVE_SPEED_RAMP_SEC = 6

function M.speedForLand(land: number, elapsedSec: number?): number
	local i = math.clamp(math.floor(land), 1, #M.WAVE_SPEED_MAX_BY_LAND)
	local start = M.WAVE_SPEED_START_BY_LAND[i]
	local maxSpeed = M.WAVE_SPEED_MAX_BY_LAND[i]
	local elapsed = if typeof(elapsedSec) == "number" then math.max(0, elapsedSec) else M.WAVE_SPEED_RAMP_SEC
	local t = math.clamp(elapsed / math.max(M.WAVE_SPEED_RAMP_SEC, 0.1), 0, 1)
	local eased = t * t
	return start + (maxSpeed - start) * eased
end

-- Billboard names + StarterGui.Gradients child names + mesh tint.
M.WEB_TITLES = {
	{ name = "👶 baby web 👶", gradient = "Basic/Common", tint = Color3.fromRGB(255, 228, 186) },
	{ name = "🕸️ normal web 🕸️", gradient = "Green", tint = Color3.fromRGB(214, 214, 220) },
	{ name = "⚡ speed web ⚡", gradient = "Yellow/Gold", tint = Color3.fromRGB(255, 214, 48) },
	{ name = "🕷️ gigantic web 🕷️", gradient = "Rare", tint = Color3.fromRGB(72, 68, 82) },
	{ name = "🔥 titan web 🔥", gradient = "Red", tint = Color3.fromRGB(255, 78, 32) },
	{ name = "🏔️ colossal web 🏔️", gradient = "Epic", tint = Color3.fromRGB(168, 148, 122) },
	{ name = "🪐 cosmic web 🪐", gradient = "Diamond", tint = Color3.fromRGB(96, 176, 255) },
	{ name = "🌌 infinitum web 🌌", gradient = "Rainbow", tint = Color3.fromRGB(176, 96, 255) },
	{ name = "☄️ omega web ☄️", gradient = "Mythical", tint = Color3.fromRGB(64, 220, 255) },
	{ name = "♾️ transcendent web ♾️", gradient = "BrainrotGod", tint = Color3.fromRGB(255, 72, 210) },
}

M.SAFEZONE_CONFIRM_SEC = 0.22
M.WAVE_ESCAPE_SEC = 1.15
M.EXCLAMATION_SEC = 1.05
M.INTRO_REVEAL_SEC = 0.7

M.BGM_CHASE_SPEED = 0.72
M.BGM_RESTORE_FADE = 0.65

function M.titleForLand(land: number): { name: string, gradient: string, tint: Color3 }
	local i = math.clamp(math.floor(land), 1, #M.WEB_TITLES)
	return M.WEB_TITLES[i]
end

return M
