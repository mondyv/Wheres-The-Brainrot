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
-- Pop out and fly up into a high hover.
M.EMERGE_SEC = 0.85
-- Hold the float so you can read the drop.
M.HOVER_SEC = 0.7
-- Jump arc onto the head, then snap into the hands.
M.HOP_SEC = 0.48
-- Kept at 0 — landing on the head instantly becomes the held tool.
M.SHRINK_SEC = 0
-- Camera restore after the hop.
M.CAM_RESTORE_SEC = 0.45

function M.burstAtSec(): number
	return M.DROP_SEC + M.GROUND_SHAKE_SEC
end

function M.revealSpawnAtSec(): number
	return M.burstAtSec() + M.BURST_HOLD_SEC
end

function M.grantAtSec(): number
	-- Grant as the hop lands so the tool is in-hand the instant the head pose ends.
	return M.revealSpawnAtSec() + M.EMERGE_SEC + M.HOVER_SEC + M.HOP_SEC
end

function M.totalDurationSec(): number
	return M.grantAtSec()
end

M.REVEAL_FOLDER_NAME = "LuckyBlockReveals"
M.REVEAL_ATTR = "LuckyBlockReveal"
M.OWNER_ATTR = "OwnerUserId"

return M
