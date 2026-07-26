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
M.PANEL_TOP_PAD = 78
M.PANEL_RIGHT_PAD = 14
M.PANEL_HEIGHT = 56
M.PANEL_MIN_WIDTH = 220
M.PANEL_MAX_WIDTH_FRAC = 0.78
M.STARTER_CASH = 500

export type StepId =
	"grantCash"
	| "visitUpgrade"
	| "buyPower"
	| "swingLand1"
	| "searchBush"
	| "claimBrainrot"
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
		text = "Swing on a vine to Land 1",
		speak = "GRAB A VINE AND SWING TO LAND ONE!!",
	},
	{
		id = "searchBush",
		text = "Search a bush for a brainrot",
		speak = "SEARCH A BUSH AND FIND A BRAINROT!!",
	},
	{
		id = "claimBrainrot",
		text = "Accept your brainrot",
		speak = "HIT ACCEPT TO CLAIM IT!!",
	},
	{
		id = "placeOnPlot",
		text = "Place the brainrot on your plot",
		speak = "BRING IT HOME AND PLACE IT ON YOUR PLOT!!",
	},
	{
		id = "upgradeBrainrot",
		text = "Upgrade your brainrot",
		speak = "TAP UPGRADE ON YOUR BRAINROT!!",
	},
}

return M
