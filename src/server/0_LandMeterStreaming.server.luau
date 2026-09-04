-- [ACTIVE] 0_LandMeterStreaming.server
--[[
	Keep land luck hitboxes (1xHitbox, 10xHitbox, …) available under streaming
	so CurrentArea / meters still resolve on far lands like Land 9.

	CRITICAL: never mark Land2–Land10 / Island / Map ancestors Persistent — that
	pinned entire lands (including grass) in memory and blew triangle counts.
	Land 1 is allowed Persistent (safezone neighbor). Only a tiny dedicated
	wrapper model around each luck hitbox is Persistent.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local HITBOX_PATTERN = "^(%d+)xHitbox$"
local PERSIST_TAG = "LandLuckHitboxPersistent"
local WRAPPER_NAME = "_LandLuckHitboxPersist"

local function isUnsafePersistName(name: string): boolean
	local landNum = tonumber(string.match(name, "^Land(%d+)$"))
	if landNum then
		return landNum ~= 1
	end
	local ak = string.gsub(string.lower(name), "[^a-z0-9]", "")
	return ak == "island"
		or ak == "ground"
		or ak == "terrain"
		or ak == "lands"
		or ak == "map"
		or ak == "grass"
		or string.find(ak, "grass", 1, true) ~= nil
end

local function ensureHitboxPersistModel(part: BasePart): Model?
	local parent = part.Parent
	if parent and parent:IsA("Model") and parent.Name == WRAPPER_NAME then
		return parent
	end
	if not parent then
		return nil
	end
	-- Keep wrapper under the same land folder so LandResolver ancestry still works.
	local wrap = Instance.new("Model")
	wrap.Name = WRAPPER_NAME
	wrap.Parent = parent
	part.Parent = wrap
	return wrap
end

local function markPersistent(part: BasePart)
	local wrap = ensureHitboxPersistModel(part)
	if not wrap or isUnsafePersistName(wrap.Name) then
		return
	end
	-- Clear Persistent on any accidental land/island ancestor from older builds.
	local ancestor = wrap.Parent
	while ancestor and ancestor ~= Workspace do
		if ancestor:IsA("Model") and isUnsafePersistName(ancestor.Name) then
			pcall(function()
				(ancestor :: Model).ModelStreamingMode = Enum.ModelStreamingMode.Default
			end)
		end
		ancestor = ancestor.Parent
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
