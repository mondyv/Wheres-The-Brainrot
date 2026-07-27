-- [ACTIVE] 0_LandMeterStreaming.server
--[[
	Keep land luck hitboxes (1xHitbox, 10xHitbox, …) persistent under streaming
	so CurrentArea / meters still resolve on far lands like Land 9.
	Also bumps Workspace streaming radii enough for a full land's props without
	preloading the whole map from spawn.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local HITBOX_PATTERN = "^(%d+)xHitbox$"
local PERSIST_TAG = "LandLuckHitboxPersistent"

if not Workspace.StreamingEnabled then
	Workspace.StreamingEnabled = true
end

pcall(function()
	-- Wide enough for land meters when you're on that land; not the whole map from spawn.
	Workspace.StreamingMinRadius = 72
	Workspace.StreamingTargetRadius = 200
	Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
end)

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
