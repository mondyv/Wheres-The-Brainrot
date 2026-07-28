-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Enable Workspace streaming early so clients don't hold the entire map in RAM.
	Radii sized so the current land (incl. far meters on Land 9) can load, without
	keeping ~5 full lands resident from spawn.
]]

local Workspace = game:GetService("Workspace")

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	-- Larger radii so land meshes arrive with (or before) bushes when swinging in.
	Workspace.StreamingMinRadius = 112
	Workspace.StreamingTargetRadius = 280
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)
