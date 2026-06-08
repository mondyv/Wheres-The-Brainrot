-- [ACTIVE] LiveDataStores
--[[
	Whether DataStore / OrderedDataStore APIs should run.
	Live published servers always use them; Studio only when API access is enabled.
--]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local M = {}

local cachedEnabled: boolean? = nil

function M.isEnabled(): boolean
	if cachedEnabled ~= nil then
		return cachedEnabled
	end
	if not RunService:IsStudio() then
		cachedEnabled = true
		return true
	end
	local ok = pcall(function()
		DataStoreService:GetDataStore("__BrainrotDataProbe_v1"):GetAsync("__probe")
	end)
	cachedEnabled = ok
	return ok
end

return M
