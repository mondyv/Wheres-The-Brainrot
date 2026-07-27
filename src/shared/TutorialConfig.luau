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
M.WORLD_ARROW_SIZE = 48
M.PANEL_TOP_PAD = 72
M.PANEL_RIGHT_PAD = 14
M.PANEL_HEIGHT = 64
M.PANEL_MIN_WIDTH = 340
M.PANEL_MAX_WIDTH = 460
M.PANEL_MAX_WIDTH_FRAC = 0.42
M.PANEL_MOBILE_MIN_WIDTH = 180
M.PANEL_MOBILE_MAX_WIDTH = 260
M.PANEL_MOBILE_MAX_WIDTH_FRAC = 0.72
M.PANEL_MOBILE_SCALE = 0.92
M.PANEL_MOBILE_GAP_ABOVE_RIGHT = 8
M.PANEL_PC_SCALE = 1.08
M.STARTER_CASH = 500
M.GO_TO_BASE_DIST = 48
M.UI_CLICK_SIZE = 34
M.UI_CLICK_SIZE_SURFACE = 30
M.UI_CLICK_SIZE_SURFACE_MOBILE = 28
M.UI_CLICK_SIZE_CLAIM = 26
M.UI_CLICK_SIZE_UPGRADE_UI = 30

export type StepId =
	"grantCash"
	| "visitUpgrade"
	| "buyPower"
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
		text = "Buy your first Power upgrade",
		speak = "TAP BUY ON POWER!!",
	},
		{
		id = "swingLand1",
		text = "Press jump and release to get over to the next land!",
		speak = "PRESS JUMP AND RELEASE TO GET OVER TO THE NEXT LAND!!",
	},
	{
		id = "searchBush",
		text = "Open a bush for a brainrot",
		speak = "OPEN A BUSH AND FIND A BRAINROT!!",
	},
	{
		id = "claimBrainrot",
		text = "Accept your brainrot",
		speak = "HIT ACCEPT TO CLAIM IT!!",
	},
	{
		id = "goToBase",
		text = "Go back to your base",
		speak = "HEAD HOME TO YOUR BASE!!",
	},
	{
		id = "placeOnPlot",
		text = "Place the brainrot on a stand",
		speak = "PUT IT DOWN ON A STAND!!",
	},
	{
		id = "upgradeBrainrot",
		text = "Upgrade your brainrot",
		speak = "TAP UPGRADE ON YOUR BRAINROT!!",
	},
}

return M
