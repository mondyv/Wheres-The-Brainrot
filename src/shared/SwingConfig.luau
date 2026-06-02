-- Shared swing tuning (client UI/physics + server attach validation).
local M = {}

-- Hook detection: same max distance for UI and attach (plus slack).
M.ATTACH_RANGE_SLACK = 0.35
M.NEAR_ATTACH_STUDS = 14
M.MIN_GRAPPLE_LOOK_DOT = 0.18
M.REATTACH_AIR_GRACE = 1.2
M.GRAPPLE_INPUT_COOLDOWN = 0.52
M.MIN_ATTACH_DIST = 0.08

-- Active swing: max travel from hook before rope tension pulls back.
M.MAX_ROPE_DISTANCE = 30
M.ROPE_SOFT_START = 0.92
M.ROPE_OVERSTRETCH_TENSION = 155
M.SPRING_STIFFNESS = 88
M.SPRING_DAMPING = 24

-- Pendulum / input (fraction of Power steering stat used for WASD along arc).
M.INPUT_STEER_FORCE_MULT = 0.2
M.ATTACH_ZIP_MULT = 0.28

M.SWING_TARGET_TAG = "SwingTarget"

return M
