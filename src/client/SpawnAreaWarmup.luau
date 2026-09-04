-- [ACTIVE] SpawnAreaWarmup
--[[
	Safezone cache only. Does not RequestStreamAroundAsync or change radii.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local SpawnAreaWarmup = {}

function SpawnAreaWarmup.runAsync()
	SafezoneUtil.warmCacheAsync()
end

return SpawnAreaWarmup
