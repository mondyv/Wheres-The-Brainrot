-- [ACTIVE] ComingSoonHitboxGuard.server
--[[
	Keeps Map.Lands["Last land"].ComingSoonHitbox present and stable.
	Unanchored hitboxes fall through the world and get destroyed at start —
	that is the usual reason ComingSoonZoneController cannot find it.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TAG = "ComingSoonZone"
local TARGET_NAMES = {
	comingsoonhitbox = true,
	["coming soon hitbox"] = true,
	comingsoon = true,
}

local function nameMatches(name: string): boolean
	return TARGET_NAMES[string.lower(name)] == true
end

local function hardenPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = true
	part.Massless = true
	if part.Transparency < 1 then
		part.Transparency = 1
	end
	part.CastShadow = false
	if not CollectionService:HasTag(part, TAG) then
		CollectionService:AddTag(part, TAG)
	end
end

local function hardenInstance(inst: Instance)
	if inst:IsA("BasePart") then
		hardenPart(inst)
		return
	end
	if inst:IsA("Model") then
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				hardenPart(d)
			end
		end
		if not CollectionService:HasTag(inst, TAG) then
			CollectionService:AddTag(inst, TAG)
		end
	end
end

local function tryClaim(inst: Instance): boolean
	if not nameMatches(inst.Name) then
		return false
	end
	if not (inst:IsA("BasePart") or inst:IsA("Model")) then
		return false
	end
	hardenInstance(inst)
	return true
end

local function scanRoot(root: Instance)
	for _, d in root:GetDescendants() do
		tryClaim(d)
	end
	root.DescendantAdded:Connect(function(inst)
		task.defer(tryClaim, inst)
	end)
end

local map = Workspace:WaitForChild("Map", 120)
if not map then
	return
end

local lands = map:WaitForChild("Lands", 60)
if lands then
	scanRoot(lands)
	-- Also watch the whole Map in case the hitbox is parented outside Last land.
	scanRoot(map)
else
	scanRoot(map)
end
