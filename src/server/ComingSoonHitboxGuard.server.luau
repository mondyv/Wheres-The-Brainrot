-- [ACTIVE] ComingSoonHitboxGuard.server
--[[
	Keeps Map.Lands["Last land"].ComingSoonHitbox present and stable.
	Unanchored hitboxes fall through the world and get destroyed at start —
	that is the usual reason ComingSoonZoneController cannot find it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

local SHOWCASE_ATTR = {
	{ attr = "LastLandShowcase_FirstGate", look = "LastLandShowcase_FirstGateLook", names = { "First Gate", "FirstGate" } },
	{ attr = "LastLandShowcase_Elephant", look = "LastLandShowcase_ElephantLook", names = { "Elephand HEad", "Elephand Head", "Elephant Head", "Elephant HEad" } },
	{ attr = "LastLandShowcase_Gate2", look = "LastLandShowcase_Gate2Look", names = { "Gate2", "Gate 2" } },
	{ attr = "LastLandShowcase_Portal", look = "LastLandShowcase_PortalLook", names = { "portal 1", "Portal 1", "Portal1" } },
}

local function nameSet(names: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, n in names do
		set[string.lower(n)] = true
	end
	return set
end

local function publishPivot(attr: string, lookAttr: string, inst: Instance)
	local cf: CFrame? = nil
	if inst:IsA("BasePart") then
		cf = inst.CFrame
	elseif inst:IsA("Model") then
		local ok, pivot = pcall(function()
			return (inst :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			cf = pivot
		end
	else
		local part = inst:FindFirstChildWhichIsA("BasePart", true)
		if part then
			cf = part.CFrame
		end
	end
	if not cf then
		return
	end
	ReplicatedStorage:SetAttribute(attr, cf.Position)
	ReplicatedStorage:SetAttribute(lookAttr, cf.LookVector)
end

local function publishShowcaseFrom(root: Instance)
	for _, def in SHOWCASE_ATTR do
		local want = nameSet(def.names)
		if want[string.lower(root.Name)] then
			publishPivot(def.attr, def.look, root)
		end
		for _, d in root:GetDescendants() do
			if want[string.lower(d.Name)] then
				publishPivot(def.attr, def.look, d)
				break
			end
		end
	end
end

local map = Workspace:WaitForChild("Map", 120)
if not map then
	return
end

local publishPending = false
local function scheduleShowcasePublish(root: Instance)
	if publishPending then
		return
	end
	publishPending = true
	task.delay(0.45, function()
		publishPending = false
		if root.Parent then
			publishShowcaseFrom(root)
		end
	end)
end

local lands = map:WaitForChild("Lands", 60)
if lands then
	scanRoot(lands)
	-- Also watch the whole Map in case the hitbox is parented outside Last land.
	scanRoot(map)
	local lastLand = lands:FindFirstChild("Last land") or lands:FindFirstChild("Last Land")
	if lastLand then
		publishShowcaseFrom(lastLand)
		lastLand.DescendantAdded:Connect(function()
			scheduleShowcasePublish(lastLand)
		end)
	end
	lands.ChildAdded:Connect(function(child)
		local n = string.lower(child.Name)
		if n == "last land" or n == "lastland" then
			scheduleShowcasePublish(child)
			child.DescendantAdded:Connect(function()
				scheduleShowcasePublish(child)
			end)
		end
	end)
else
	scanRoot(map)
end
