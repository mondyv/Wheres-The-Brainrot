-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming must stay enabled. Radii are set here on purpose (server-authoritative)
	so the live place cannot silently run Studio's huge 256/512 and keep half the
	map + grass resident (high tris).

	Live: 112 / 280 ≈ current land + neighbors without pinning 5 lands of decor.
	Studio play-solo: 80 / 180 so the in-process client+server does not keep the map.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local STREAM_MIN_RADIUS = if RunService:IsStudio() then 80 else 112
local STREAM_TARGET_RADIUS = if RunService:IsStudio() then 180 else 280

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	Workspace.StreamingMinRadius = STREAM_MIN_RADIUS
	Workspace.StreamingTargetRadius = STREAM_TARGET_RADIUS
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)

-- Legacy place files kept the whole Brainrots mesh catalog in ReplicatedStorage.
-- Every client (and Studio play-solo) then holds a second copy of every model.
-- Templates are server-only; move/destroy the replicated duplicate immediately.
local function folderHasMeshCatalog(folder: Instance): boolean
	return folder:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function unreplicateBrainrotsCatalog()
	local rs = ReplicatedStorage:FindFirstChild("Brainrots")
	if not rs or not rs:IsA("Folder") then
		return
	end
	local ss = ServerStorage:FindFirstChild("Brainrots")
	-- Rojo can ship an empty ServerStorage.Brainrots. Never destroy the live
	-- ReplicatedStorage catalog unless ServerStorage already has the meshes.
	if ss and ss:IsA("Folder") and folderHasMeshCatalog(ss) then
		rs:Destroy()
	end
end

unreplicateBrainrotsCatalog()
task.defer(unreplicateBrainrotsCatalog)
