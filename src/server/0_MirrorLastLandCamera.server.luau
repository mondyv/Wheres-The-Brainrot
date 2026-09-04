-- [ACTIVE] 0_MirrorLastLandCamera.server
--[[
	Copies ServerStorage["Last Land Camera"] → ReplicatedStorage so the
	tutorial showcase can play the Moon Animator track on the client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SRC_NAME = "Last Land Camera"

local function syncLastLandCamera()
	local src = ServerStorage:FindFirstChild(SRC_NAME)
	if not src then
		return
	end
	local existing = ReplicatedStorage:FindFirstChild(SRC_NAME)
	if existing then
		existing:Destroy()
	end
	local clone = src:Clone()
	clone.Name = SRC_NAME
	clone.Parent = ReplicatedStorage
end

task.defer(syncLastLandCamera)

ServerStorage.ChildAdded:Connect(function(ch)
	if ch.Name == SRC_NAME then
		task.defer(syncLastLandCamera)
	end
end)
