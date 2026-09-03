-- [ACTIVE] TutorialConfig
--[[
	First-join tutorial step copy, assets, and timing.
]]

local M = {}

M.EXCLAIM_IMAGE = "rbxassetid://82174402168294"
M.WORLD_ARROW_IMAGE = "rbxassetid://74385491860116"
M.UI_CLICK_IMAGE = "rbxassetid://80727309150135"

M.VOICE_PITCH_MIN = 1.15
M.VOICE_PITCH_MAX = 1.5
M.OBJECTIVE_TYPE_DELAY = 0.048
M.WORLD_ARROW_ROTATION = 180
M.WORLD_ARROW_HEIGHT = 16
M.WORLD_ARROW_SIZE = 56
M.WORLD_ARROW_SIZE_MOBILE = 88
M.PANEL_TOP_PAD = 18
M.PANEL_RIGHT_PAD = 14
M.PANEL_HEIGHT = 72
M.PANEL_MIN_WIDTH = 380
M.PANEL_MAX_WIDTH = 520
M.PANEL_MAX_WIDTH_FRAC = 0.52
M.PANEL_MOBILE_MIN_WIDTH = 240
M.PANEL_MOBILE_MAX_WIDTH = 340
M.PANEL_MOBILE_MAX_WIDTH_FRAC = 0.88
M.PANEL_MOBILE_SCALE = 0.94
M.PANEL_MOBILE_GAP_ABOVE_RIGHT = 10
M.PANEL_PC_SCALE = 1.08
M.SKIP_BTN_GAP = 6
M.SKIP_BTN_HEIGHT = 28
M.SKIP_BTN_MIN_WIDTH = 118
M.STARTER_CASH = 0
M.STARTER_LUCKY_BLOCK = "Starter Lucky Block"
M.WORKOUT_GOAL_POWER = 100
M.GO_TO_BASE_DIST = 48
-- Large finite max — some mobile clients treat 0 oddly for BillboardGui.
M.WORLD_ARROW_MAX_DISTANCE = 2500
M.SURFACE_CLICK_MAX_DISTANCE = 2500
-- Body → objective guide line (up-arrow tiles along the path).
M.GUIDE_BEAM_TEXTURE = "rbxassetid://74385491860116"
M.GUIDE_BEAM_WIDTH0 = 2.2
M.GUIDE_BEAM_WIDTH1 = 2.2
M.GUIDE_BEAM_TEXTURE_LENGTH = 3.15
M.GUIDE_BEAM_TEXTURE_SPEED = -2.15
M.GUIDE_BEAM_COLOR = Color3.fromRGB(255, 255, 255)
M.GUIDE_BEAM_HIDE_DIST = 14
M.UI_CLICK_SIZE = 34
M.UI_CLICK_SIZE_SURFACE = 30
M.UI_CLICK_SIZE_SURFACE_MOBILE = 28
M.UI_CLICK_SIZE_CLAIM = 26
M.UI_CLICK_SIZE_UPGRADE_UI = 30

export type StepId =
	"swingLand1"
	| "searchBush"
	| "claimBrainrot"
	| "goToBase"
	| "placeOnPlot"
	| "visitUpgrade"
	| "buyPower"
	| "useWorkout"

export type StepDef = {
	id: StepId,
	text: string,
	speak: string?,
	retryText: string?,
	controllerText: string?,
	controllerSpeak: string?,
	controllerRetryText: string?,
}

M.STEPS = {
	{
		id = "swingLand1",
		text = "Look at the middle vine, then jump to swing over!",
		speak = "SWING THE MIDDLE VINE TO THE JUNGLE!!",
		retryText = "Jump again to let go, then land!",
		controllerText = "Aim at the middle vine, then press A / ✕ to swing!",
		controllerSpeak = "AIM AT THE MIDDLE VINE AND PRESS A TO SWING!!",
		controllerRetryText = "Press A / ✕ again to let go, then land!",
	},
	{
		id = "searchBush",
		text = "Search a bush for a brainrot",
		speak = "OPEN A BUSH AND FIND A BRAINROT!!",
		controllerText = "Hold X / □ near a bush to search",
		controllerSpeak = "HOLD X NEAR A BUSH TO SEARCH!!",
	},
	{
		id = "claimBrainrot",
		text = "Accept your brainrot",
		speak = "HIT ACCEPT TO CLAIM IT!!",
		controllerText = "Press A / ✕ to Accept, or B / ○ to Decline",
		controllerSpeak = "PRESS A TO ACCEPT!!",
	},
	{
		id = "goToBase",
		text = "Swing back to your base",
		speak = "HEAD HOME TO YOUR BASE!!",
		retryText = "Jump near a vine to swing back!",
		controllerRetryText = "Press A / ✕ near a vine to swing back!",
	},
	{
		id = "placeOnPlot",
		text = "Place the brainrot on a stand",
		speak = "PUT IT DOWN ON A STAND!!",
		controllerText = "Stand near a plot and press X / □ to place",
		controllerSpeak = "PRESS X TO PLACE ON A STAND!!",
	},
	{
		id = "visitUpgrade",
		text = "Go to the Weights shop",
		speak = "HEAD TO THE WEIGHTS SHOP!!",
	},
	{
		id = "buyPower",
		text = "Grab your free Tree Branch",
		speak = "TAP FREE ON TREE BRANCH!!",
		controllerText = "Select Free on Tree Branch, then press A / ✕",
		controllerSpeak = "SELECT FREE ON TREE BRANCH!!",
	},
	{
		id = "useWorkout",
		text = "Work out until you hit 100 Power!",
		speak = "KEEP WORKING OUT TO 100 POWER!!",
		controllerText = "Work out until you hit 100 Power!",
		controllerSpeak = "KEEP WORKING OUT TO 100 POWER!!",
	},
}

function M.stepText(step: StepDef, forController: boolean): string
	if forController and typeof(step.controllerText) == "string" and step.controllerText ~= "" then
		return step.controllerText
	end
	return step.text
end

function M.stepSpeak(step: StepDef, forController: boolean): string?
	if forController and typeof(step.controllerSpeak) == "string" and step.controllerSpeak ~= "" then
		return step.controllerSpeak
	end
	return step.speak
end

function M.stepRetryText(step: StepDef, forController: boolean): string?
	if forController and typeof(step.controllerRetryText) == "string" and step.controllerRetryText ~= "" then
		return step.controllerRetryText
	end
	return step.retryText
end

return M
