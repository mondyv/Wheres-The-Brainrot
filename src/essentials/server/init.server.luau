--[[
	Essentials server entry — boots ProductHandler (purchase prompts + receipt routing).
	Requires ProductHandlerConfig in ReplicatedStorage.EssentialsShared (Studio or Rojo).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductHandlerServer = require(script.ProductHandler.ProductHandlerServer)

local ok, err = pcall(function()
	local shared = ReplicatedStorage:WaitForChild("EssentialsShared", 15)
	local productHandler = shared:WaitForChild("ProductHandler", 15)
	require(productHandler:WaitForChild("ProductHandlerConfig"))
	ProductHandlerServer:init()
end)

if not ok then
	warn("[EssentialsServer] ProductHandlerServer did not start:", err)
end
