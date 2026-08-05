-- [ACTIVE] 0_LandMeterStreaming.server
--[[
	Keep land luck hitboxes (1xHitbox, 10xHitbox, …) persistent under streaming
	so CurrentArea / meters still resolve on far lands like Land 9.

	Streaming radii / StreamOutBehavior live only in 0_StreamingBootstrap (+ project.json).
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local HITBOX_PATTERN = "^(%d+)xHitbox$"
local PERSIST_TAG = "LandLuckHitboxPersistent"

local function markPersistent(inst: Instance)
	local model = if inst:IsA("Model") then inst else inst:FindFirstAncestorOfClass("Model")
	if model then
		pcall(function()
			model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		end)
	end
	if not CollectionService:HasTag(inst, PERSIST_TAG) then
		CollectionService:AddTag(inst, PERSIST_TAG)
	end
end

local function tryPersistHitbox(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	if not string.match(inst.Name, HITBOX_PATTERN) then
		return
	end
	markPersistent(inst)
end

local function scanRoot(root: Instance)
	for _, desc in root:GetDescendants() do
		tryPersistHitbox(desc)
	end
end

local function hookLands(lands: Instance)
	scanRoot(lands)
	lands.DescendantAdded:Connect(tryPersistHitbox)
end

local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 120)
if not map then
	warn("[LandMeterStreaming] Workspace.Map missing — land meter persistence skipped")
	return
end

local lands = map:FindFirstChild("Lands")
if lands then
	hookLands(lands)
else
	map.ChildAdded:Connect(function(child)
		if child.Name == "Lands" then
			hookLands(child)
		end
	end)
end
