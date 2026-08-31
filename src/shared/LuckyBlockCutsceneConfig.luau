-- [ACTIVE] LuckyBlockCutsceneConfig
--[[
	Shared timing for the lucky-block open cutscene (server grant sync + client anim).
]]

local M = {}

-- Drop from hand → land on ground.
M.DROP_SEC = 0.55
-- SoundService.SoundEffects["Luckyblock sfx"]["Block Open"] (~4s clip; shake is timed separately).
M.BLOCK_OPEN_SFX_SEC = 4
-- Short ground shake, then the block unlocks.
M.GROUND_SHAKE_SEC = 1
-- Burst VFX + hide block before brainrot appears.
M.BURST_HOLD_SEC = 0.22
-- Brainrot rises / settles into hover.
M.EMERGE_SEC = 0.85
-- Hover like bush float offer (short — then hop to head).
M.HOVER_SEC = 0.75
-- Reveal pose (was a hop onto the head).
M.HOP_SEC = 1.05
-- Shrink in place after the pose.
M.SHRINK_SEC = 0.55
-- Camera restore after shrink.
M.CAM_RESTORE_SEC = 0.45

function M.burstAtSec(): number
	return M.DROP_SEC + M.GROUND_SHAKE_SEC
end

function M.revealSpawnAtSec(): number
	return M.burstAtSec() + M.BURST_HOLD_SEC
end

function M.grantAtSec(): number
	return M.revealSpawnAtSec()
		+ M.EMERGE_SEC
		+ M.HOVER_SEC
		+ M.HOP_SEC
		+ M.SHRINK_SEC
end

function M.totalDurationSec(): number
	-- Small buffer so client shrink finishes before server destroys the reveal + grants.
	return M.grantAtSec() + 0.35
end

M.REVEAL_FOLDER_NAME = "LuckyBlockReveals"
M.REVEAL_ATTR = "LuckyBlockReveal"
M.OWNER_ATTR = "OwnerUserId"

return M
