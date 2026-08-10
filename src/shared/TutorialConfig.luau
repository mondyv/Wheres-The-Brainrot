-- [ACTIVE] TutorialConfig
--[[
	First-join tutorial step copy, assets, and timing.
]]

local M = {}

M.EXCLAIM_IMAGE = "rbxassetid://82174402168294"
M.WORLD_ARROW_IMAGE = "rbxassetid://83718910748441"
M.UI_CLICK_IMAGE = "rbxassetid://80727309150135"

M.VOICE_PITCH_MIN = 1.15
M.VOICE_PITCH_MAX = 1.5
M.OBJECTIVE_TYPE_DELAY = 0.048
M.WORLD_ARROW_ROTATION = 180
M.WORLD_ARROW_HEIGHT = 16
M.WORLD_ARROW_SIZE = 56
M.WORLD_ARROW_SIZE_MOBILE = 88
M.PANEL_TOP_PAD = 72
M.PANEL_RIGHT_PAD = 14
M.PANEL_HEIGHT = 64
M.PANEL_MIN_WIDTH = 340
M.PANEL_MAX_WIDTH = 460
M.PANEL_MAX_WIDTH_FRAC = 0.42
M.PANEL_MOBILE_MIN_WIDTH = 200
M.PANEL_MOBILE_MAX_WIDTH = 280
M.PANEL_MOBILE_MAX_WIDTH_FRAC = 0.78
M.PANEL_MOBILE_SCALE = 0.94
M.PANEL_MOBILE_GAP_ABOVE_RIGHT = 10
M.PANEL_PC_SCALE = 1.08
M.SKIP_BTN_GAP = 6
M.SKIP_BTN_HEIGHT = 28
M.SKIP_BTN_MIN_WIDTH = 118
M.STARTER_CASH = 500
M.STARTER_LUCKY_BLOCK = "Starter Lucky Block"
M.GO_TO_BASE_DIST = 48
-- Large finite max — some mobile clients treat 0 oddly for BillboardGui.
M.WORLD_ARROW_MAX_DISTANCE = 2500
M.SURFACE_CLICK_MAX_DISTANCE = 2500
-- Body → objective guide beam (flowing chevrons).
M.GUIDE_BEAM_TEXTURE = "rbxassetid://446111271"
M.GUIDE_BEAM_WIDTH0 = 0.85
M.GUIDE_BEAM_WIDTH1 = 0.45
M.GUIDE_BEAM_COLOR = Color3.fromRGB(255, 214, 74)
M.GUIDE_BEAM_HIDE_DIST = 14
M.UI_CLICK_SIZE = 34
M.UI_CLICK_SIZE_SURFACE = 30
M.UI_CLICK_SIZE_SURFACE_MOBILE = 28
M.UI_CLICK_SIZE_CLAIM = 26
M.UI_CLICK_SIZE_UPGRADE_UI = 30

export type StepId =
	"grantCash"
	| "visitUpgrade"
	| "buyPower"
	| "equipGear"
	| "useWorkout"
	| "swingLand1"
	| "searchBush"
	| "claimBrainrot"
	| "goToBase"
	| "placeOnPlot"
	| "upgradeBrainrot"

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
		id = "grantCash",
		text = "Here's $500!",
		speak = nil,
	},
	{
		id = "visitUpgrade",
		text = "Go to the Upgrade Stand",
		speak = "HEAD TO THE UPGRADE STAND!!",
	},
	{
		id = "buyPower",
		text = "Buy your first workout gear",
		speak = "TAP BUY ON TREE BRANCH!!",
		controllerText = "Select Buy on Tree Branch with the cursor, then press A / ✕",
		controllerSpeak = "SELECT BUY ON TREE BRANCH!!",
	},
	{
		id = "equipGear",
		text = "Equip your Tree Branch",
		speak = "TAP EQUIP ON TREE BRANCH!!",
		controllerText = "Select Equip on Tree Branch, then press A / ✕",
		controllerSpeak = "SELECT EQUIP!!",
	},
	{
		id = "useWorkout",
		text = "Equip your gear to work out!",
		speak = "EQUIP YOUR GEAR TO WORK OUT!!",
		controllerText = "Select your gear in the hotbar to equip and work out",
		controllerSpeak = "EQUIP YOUR GEAR TO WORK OUT!!",
	},
	{
		id = "swingLand1",
		text = "Look at a vine, then press jump to swing over!",
		speak = "LOOK AT A VINE AND PRESS JUMP TO SWING OVER!!",
		retryText = "Press jump again to let go, then land on the next land!",
		controllerText = "Aim at a vine, then press A / ✕ to swing!",
		controllerSpeak = "AIM AT A VINE AND PRESS A TO SWING!!",
		controllerRetryText = "Press A / ✕ again to let go, then land on the next land!",
	},
	{
		id = "searchBush",
		text = "Open a bush for a brainrot",
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
		text = "Go back to your base",
		speak = "HEAD HOME TO YOUR BASE!!",
		retryText = "Press jump near a vine to swing back!",
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
		id = "upgradeBrainrot",
		text = "Upgrade your brainrot",
		speak = "TAP UPGRADE ON YOUR BRAINROT!!",
		controllerText = "Select Upgrade on your brainrot, then press A / ✕",
		controllerSpeak = "SELECT UPGRADE ON YOUR BRAINROT!!",
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
