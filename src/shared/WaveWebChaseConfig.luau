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
M.WAVE_BEHIND_STUDS = 40
M.WAVE_RISE_STUDS = 52
M.WAVE_RISE_SEC = 1.2
M.WAVE_KILL_DISTANCE = 6
M.WAVE_KILL_GRACE_SEC = 1.8
-- Never ScaleTo the Wave Web mesh — it freezes/crashes Studio & clients.
M.WAVE_SCALE = 1

-- Per-land charge speed (studs/s). Starts a hair under a sprint, then ramps
-- past the player. Also scales with actual WalkSpeed so upgrades can't stroll away.
M.WAVE_SPEED_START_BY_LAND = {
	20, -- 1 baby
	24, -- 2 normal
	28, -- 3 speed
	34, -- 4 gigantic
	40, -- 5 titan
	46, -- 6 colossal
	52, -- 7 cosmic
	58, -- 8 infinitum
	64, -- 9 omega
	72, -- 10 transcendent
}

M.WAVE_SPEED_MAX_BY_LAND = {
	32, -- 1
	40, -- 2
	48, -- 3
	56, -- 4
	64, -- 5
	72, -- 6
	80, -- 7
	88, -- 8
	96, -- 9
	108, -- 10
}

-- Always this much faster than the player's along-path speed (studs/s).
-- Runners and swingers cannot outpace it; they have to make safezone.
M.WAVE_CATCHUP_BY_LAND = {
	4,
	5,
	6,
	8,
	10,
	12,
	14,
	16,
	18,
	22,
}

M.WAVE_SPEED_CAP = 160

M.WAVE_SPEED_START_WALK_MULT = {
	0.9,
	0.95,
	1.0,
	1.05,
	1.1,
	1.15,
	1.2,
	1.25,
	1.3,
	1.35,
}

M.WAVE_SPEED_MAX_WALK_MULT = {
	1.2,
	1.3,
	1.4,
	1.5,
	1.6,
	1.7,
	1.8,
	1.9,
	2.0,
	2.1,
}

-- Seconds from start speed to max.
M.WAVE_SPEED_RAMP_SEC = 3.2

function M.speedForLand(land: number, elapsedSec: number?, walkSpeed: number?): number
	local i = math.clamp(math.floor(land), 1, #M.WAVE_SPEED_MAX_BY_LAND)
	local walk = 18
	if typeof(walkSpeed) == "number" and walkSpeed > 8 then
		walk = math.clamp(walkSpeed, 14, 90)
	end
	local start = math.max(M.WAVE_SPEED_START_BY_LAND[i], walk * M.WAVE_SPEED_START_WALK_MULT[i])
	local maxSpeed = math.max(M.WAVE_SPEED_MAX_BY_LAND[i], walk * M.WAVE_SPEED_MAX_WALK_MULT[i])
	local elapsed = if typeof(elapsedSec) == "number" then math.max(0, elapsedSec) else M.WAVE_SPEED_RAMP_SEC
	local t = math.clamp(elapsed / math.max(M.WAVE_SPEED_RAMP_SEC, 0.1), 0, 1)
	-- Mild ease-in so the first second still feels like a head start.
	local eased = t ^ 1.25
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
