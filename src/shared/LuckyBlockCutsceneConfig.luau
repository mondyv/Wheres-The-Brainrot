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
-- Brainrot rises and eases into hover (same path the hover continues).
M.EMERGE_SEC = 0.72
-- Hold the float long enough to read — bob is the same wave as emerge.
M.HOVER_SEC = 0.58
-- Arc onto the head (C1 from hover, no Back-out overshoot).
M.HOP_SEC = 0.55
-- Rest on the head after the hop.
M.SHRINK_SEC = 0.32
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
