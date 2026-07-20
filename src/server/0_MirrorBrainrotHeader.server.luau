-- [ACTIVE] 0_MirrorBrainrotHeader.server
--[[
	Copies ServerStorage.Templates.BrainrotHeader → ReplicatedStorage.Templates.BrainrotHeader
	so clients can clone the BillboardGui locally (server-only templates do not show on screen).
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local function syncHeaderTemplate()
	local templates = ServerStorage:FindFirstChild("Templates")
	if not templates then
		warn("[0_MirrorBrainrotHeader] ServerStorage.Templates missing")
		return
	end
	local src = templates:FindFirstChild("BrainrotHeader")
	if not src then
		warn("[0_MirrorBrainrotHeader] ServerStorage.Templates.BrainrotHeader missing")
		return
	end
	local hasBb = src:FindFirstChildWhichIsA("BillboardGui", true) ~= nil
	if not hasBb then
		warn("[0_MirrorBrainrotHeader] BrainrotHeader has no BillboardGui — headers will use client fallback. Place BillboardGui under ServerStorage.Templates.BrainrotHeader in Studio.")
	end
	local rsTemplates = ReplicatedStorage:FindFirstChild("Templates")
	if not rsTemplates then
		rsTemplates = Instance.new("Folder")
		rsTemplates.Name = "Templates"
		rsTemplates.Parent = ReplicatedStorage
	end
	local existing = rsTemplates:FindFirstChild("BrainrotHeader")
	if existing then
		existing:Destroy()
	end
	local clone = src:Clone()
	clone.Name = "BrainrotHeader"
	clone.Parent = rsTemplates
end

task.defer(syncHeaderTemplate)

ServerStorage.ChildAdded:Connect(function(ch)
	if ch.Name == "Templates" then
		task.defer(syncHeaderTemplate)
	end
end)

local templatesFolder = ServerStorage:WaitForChild("Templates", 120)
if templatesFolder then
	templatesFolder.ChildAdded:Connect(function(ch)
		if ch.Name == "BrainrotHeader" then
			task.defer(syncHeaderTemplate)
		end
	end)
end
