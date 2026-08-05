-- [ACTIVE] 0_LandMeterStreaming.server
--[[
	Keep land luck hitboxes (1xHitbox, 10xHitbox, …) persistent under streaming
	so CurrentArea / meters still resolve on far lands like Land 9.

	Only mark a small hitbox wrapper model Persistent — never Land*/Island ancestors
	(that would pin entire lands + grass in memory).

	Streaming radii / StreamOutBehavior live only in 0_StreamingBootstrap (+ project.json).
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local HITBOX_PATTERN = "^(%d+)xHitbox$"
local PERSIST_TAG = "LandLuckHitboxPersistent"
local WRAPPER_NAME = "_LandLuckHitboxPersist"

local function isLandOrIslandName(name: string): boolean
	local lower = string.lower(name)
	if string.match(name, "^Land%d+$") then
		return true
	end
	local ak = string.gsub(lower, "[^a-z0-9]", "")
	return ak == "island"
		or ak == "ground"
		or ak == "terrain"
		or ak == "lands"
		or ak == "map"
end

local function ensureHitboxPersistModel(part: BasePart): Model
	local parent = part.Parent
	if parent and parent:IsA("Model") and parent.Name == WRAPPER_NAME then
		return parent
	end
	-- Don't reuse Land/Island models — wrap the part in its own tiny persistent model.
	local wrap = Instance.new("Model")
	wrap.Name = WRAPPER_NAME
	if parent then
		wrap.Parent = parent
	else
		wrap.Parent = Workspace
	end
	part.Parent = wrap
	return wrap
end

local function markPersistent(part: BasePart)
	local wrap = ensureHitboxPersistModel(part)
	if isLandOrIslandName(wrap.Name) then
		return
	end
	pcall(function()
		wrap.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	if not CollectionService:HasTag(part, PERSIST_TAG) then
		CollectionService:AddTag(part, PERSIST_TAG)
	end
	if not CollectionService:HasTag(wrap, PERSIST_TAG) then
		CollectionService:AddTag(wrap, PERSIST_TAG)
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
