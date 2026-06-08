-- [ACTIVE] 0_PlayerData.server
--[[
	Bootstraps PlayerDataService before other PlayerAdded handlers rely on saved data.
--]]

local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

PlayerDataService.start()
