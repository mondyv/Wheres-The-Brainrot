-- [ACTIVE] init.server
--[[
	Essentials server entry — boots ProductHandler (purchase prompts + receipt routing).
]]

local ProductHandlerServer = require(script.ProductHandler.ProductHandlerServer)

local ok, err = pcall(function()
	ProductHandlerServer:init()
end)

if not ok then
	warn("[EssentialsServer] ProductHandlerServer did not start:", err)
end
