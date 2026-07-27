-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Enable Workspace streaming early so clients don't hold the entire map in RAM.
	Tight radii so only nearby content stays loaded (not 4–5 full lands at once).
]]

local Workspace = game:GetService("Workspace")

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	Workspace.StreamingMinRadius = 48
	Workspace.StreamingTargetRadius = 112
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)
