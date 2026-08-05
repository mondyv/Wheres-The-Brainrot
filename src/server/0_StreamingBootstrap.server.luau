-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming must stay enabled. Radii are set here on purpose (server-authoritative)
	so the live place cannot silently run Studio's huge 256/512 and keep half the
	map + grass resident (high tris).

	112 / 280 ≈ current land + neighbors without pinning 5 lands of decor.
]]

local Workspace = game:GetService("Workspace")

local STREAM_MIN_RADIUS = 112
local STREAM_TARGET_RADIUS = 280

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	Workspace.StreamingMinRadius = STREAM_MIN_RADIUS
	Workspace.StreamingTargetRadius = STREAM_TARGET_RADIUS
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)
