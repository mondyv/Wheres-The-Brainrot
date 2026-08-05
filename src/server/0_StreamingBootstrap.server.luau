-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Ensure Workspace streaming is on. Radii are owned by the place file / Studio
	(StreamingMinRadius / StreamingTargetRadius) — do not hardcode them here.
]]

local Workspace = game:GetService("Workspace")

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)
