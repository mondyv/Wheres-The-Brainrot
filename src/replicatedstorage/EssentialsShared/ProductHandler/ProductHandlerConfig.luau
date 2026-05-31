--[[
	Product / gamepass definitions for ProductHandlerServer.
	Replace id values with your Creator Hub product / gamepass IDs.
	Add part = workspace.SomePart when using touch / proximity triggers.
]]

export type ProductEntry = {
	type: "devproduct" | "gamepass",
	id: number,
	part: Instance?,
}

local ProductHandlerConfig: { [string]: ProductEntry } = {
	Garama = {
		type = "devproduct",
		id = 0,
	},
	LaVaccaSaturnoSaturnita2 = {
		type = "devproduct",
		id = 0,
	},
	Cash50k = {
		type = "devproduct",
		id = 0,
	},
}

return ProductHandlerConfig
