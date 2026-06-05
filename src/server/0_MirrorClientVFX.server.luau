-- [ACTIVE] 0_MirrorClientVFX.server
--[[
	Copies ServerStorage.VFX → ReplicatedStorage.VFX so client scripts (money collect burst)
	can clone particle templates. Source stays in ServerStorage; only a runtime copy replicates.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local function syncClientVFX()
	local src = ServerStorage:FindFirstChild("VFX")
	if not src then
		return
	end
	local existing = ReplicatedStorage:FindFirstChild("VFX")
	if existing then
		existing:Destroy()
	end
	local clone = src:Clone()
	clone.Name = "VFX"
	clone.Parent = ReplicatedStorage
end

task.defer(syncClientVFX)

ServerStorage.ChildAdded:Connect(function(ch)
	if ch.Name == "VFX" then
		task.defer(syncClientVFX)
	end
end)
