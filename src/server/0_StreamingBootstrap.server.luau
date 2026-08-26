-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming must stay enabled. Radii are set here on purpose (server-authoritative)
	so the live place cannot silently run Studio's huge 256/512 and keep half the
	map + grass resident (high tris).

	140 / 360 ≈ current land + neighbors, with enough lead when swinging.
]]

local Workspace = game:GetService("Workspace")

local STREAM_MIN_RADIUS = 140
local STREAM_TARGET_RADIUS = 360

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	Workspace.StreamingMinRadius = STREAM_MIN_RADIUS
	Workspace.StreamingTargetRadius = STREAM_TARGET_RADIUS
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)
