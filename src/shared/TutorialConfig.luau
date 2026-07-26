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
M.OBJECTIVE_TYPE_DELAY = 0.028

export type StepId =
	"visitUpgrade"
	| "buyPower"
	| "swingLand1"
	| "searchBush"
	| "claimBrainrot"
	| "placeOnPlot"

export type StepDef = {
	id: StepId,
	text: string,
	speak: string?,
}

M.STEPS: { StepDef } = {
	{
		id = "visitUpgrade",
		text = "Go to the Upgrade Stand",
		speak = "HEAD TO THE UPGRADE STAND!!",
	},
	{
		id = "buyPower",
		text = "Buy your first Power upgrade",
		speak = "TAP BUY AND GRAB MORE POWER!!",
	},
	{
		id = "swingLand1",
		text = "Swing over to Land 1",
		speak = "SWING OVER TO LAND ONE!!",
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
}

return M
