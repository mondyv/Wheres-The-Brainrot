-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Enable Workspace streaming early so clients don't hold the entire map in RAM.
	Without this, Client Memory can climb past multi-GB even in the safezone.
]]

local Workspace = game:GetService("Workspace")

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

-- Keep radii modest — safezone stays loaded; lands stream in on approach.
pcall(function()
	Workspace.StreamingMinRadius = 64
	Workspace.StreamingTargetRadius = 256
end)
