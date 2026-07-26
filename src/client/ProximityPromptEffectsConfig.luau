-- [ACTIVE] ProximityPromptEffectsConfig
--[[
	Visual / tuning constants for ProximityPromptEffects (keeps main module under Luau register limit).
]]

local TweenService = game:GetService("TweenService")

local M = {}

M.ACCENT = Color3.fromRGB(72, 255, 140)
M.ACCENT_BRIGHT = Color3.fromRGB(130, 255, 175)
M.ACCENT_STROKE = Color3.fromRGB(48, 220, 110)
M.BG_COLOR = Color3.fromRGB(10, 12, 16)
M.BG_TRANSPARENCY = 0.4
M.BADGE_BG = Color3.fromRGB(24, 28, 34)
M.BADGE_BG_TRANSPARENCY = 0.12
M.HOLD_GREEN = Color3.fromRGB(36, 165, 88)
M.HOLD_GREEN_BRIGHT = Color3.fromRGB(95, 255, 145)
-- Neutral hold fill for bush search cards (green outline lives on the bush Highlight, not the prompt).
M.BUSH_HOLD_FILL = Color3.fromRGB(210, 218, 232)
M.BUSH_HOLD_FILL_BRIGHT = Color3.fromRGB(235, 240, 248)
M.BUSH_HOLD_BADGE = Color3.fromRGB(58, 64, 76)
M.PRESS_FLASH = Color3.fromRGB(255, 228, 88)
M.HOLD_COMPLETE_FLASH = Color3.fromRGB(210, 255, 230)
M.TEXT_PRIMARY = Color3.fromRGB(248, 250, 252)
M.TEXT_SECONDARY = Color3.fromRGB(168, 178, 192)
M.KEY_TEXT = M.TEXT_PRIMARY
-- Match panel bg, slightly darker + soft so outlines read without neon green.
M.PANEL_STROKE = Color3.fromRGB(48, 58, 72)
M.PANEL_STROKE_TRANSPARENCY = 0.42
M.KEY_CHIP_STROKE = Color3.fromRGB(8, 10, 14)
M.KEY_CHIP_STROKE_TRANSPARENCY = 0.28
M.HOLD_TRACK_STROKE = Color3.fromRGB(6, 8, 12)
M.HOLD_TRACK_STROKE_TRANSPARENCY = 0.35

M.CARD_H = 58
M.BADGE_SIZE = 44
M.BADGE_HOLD_PAD = 3
M.PAD_LEFT = 8
M.BADGE_TEXT_GAP = 6
M.PAD_RIGHT = 10
M.ACTION_TEXT_SIZE = 17
M.OBJECT_TEXT_SIZE = 14
M.KEY_TEXT_SIZE = 22
M.KEY_TEXT_SIZE_MOBILE = 18
M.MIN_CARD_W = 118
M.MOBILE_MIN_CARD_W = 148
M.MAX_CARD_W = 232

M.OPEN_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
M.CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
M.BADGE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
M.TILT_LEFT = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
M.TILT_RIGHT = TweenInfo.new(0.11, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
M.TILT_CENTER = TweenInfo.new(0.14, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
M.TILT_POP = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
M.STAND_TILT_LEFT = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
M.STAND_TILT_RIGHT = TweenInfo.new(0.28, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
M.STAND_TILT_CENTER = TweenInfo.new(0.34, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
M.STAND_STROKE_GRAD_ROT_SPEED = 42
M.FLASH_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
M.POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

M.SWAY_FREQ = 1.35
M.SWAY_AMP = 2.2
M.STAND_SWAY_FREQ = 1.05
M.STAND_SWAY_AMP = 5.2
M.STAND_BADGE_SWAY_AMP = 7.5
M.WIGGLE_ROT = math.rad(4.5)
M.WIGGLE_SPEED = 13
M.HOLD_COMPLETE_THRESHOLD = 0.98

M.BUSH_CAM_SHAKE_STEP = "BushSearchCameraShake"
M.BUSH_WOBBLE_STEP = "BushSearchModelWobble"
M.BUSH_CAM_SHAKE_POS = 0.14
M.BUSH_CAM_SHAKE_SPEED = 9
M.BUSH_WOBBLE_POS = 0.11
M.BUSH_WOBBLE_ROT = math.rad(3.4)

M.CUSTOM_ATTR = "CustomPromptFX"
M.PLACE_PROMPT_ATTR = "BrainrotPlacePrompt"
M.STEAL_PROMPT_ATTR = "StealPrompt"
M.STAND_NAME_ATTR = "BrainrotName"
M.STAND_LEVEL_ATTR = "BrainrotLevel"
M.STAND_RARITY_ATTR = "BrainrotRarity"

M.RARITY_GRADIENT_UI_NAMES = {
	common = "Common",
	uncommon = "Uncommon",
	rare = "Rare",
	epic = "Epic",
	mythic = "Mythical",
	legendary = "Legendary",
	["brainrot god"] = "Godly",
	secret = "Godly",
}

M.MIN_TOUCH_PX = 44
M.MIN_TOUCH_PX_MOBILE = 52
M.TOUCH_TAP_ICON = "rbxassetid://80727309150135"
M.TOUCH_HOLD_ICON = "rbxassetid://80727309150135"

M.MIN_MOBILE_FACE_DOT = 0.32
M.MOBILE_FACING_REFRESH_INTERVAL = 0.12

M.BUSH_MANAGED_ATTR = "BushManagedPrompt"
M.STAND_TAG = "BrainrotStand"
M.COOLDOWN_BANNER_VIEW_RANGE = 500
M.BUSH_BILLBOARD_LIFT_SCALE = 0.66
M.BUSH_BILLBOARD_MIN_MAX_DISTANCE = 40
M.BUSH_UI_STATIC_OFFSET = Vector3.new(0, 0.35, 0)
M.BUSH_XRAY_UI_OFFSET = Vector3.new(0, 3.05, 0)
M.BUSH_SEARCH_BADGE_BG_TRANSPARENCY = 0.45
M.BUSH_SEARCH_BADGE_STROKE_TRANSPARENCY = 0.5

return M
