-- Tags deposit BaseParts so BushHarvest can listen for touches.
-- Matches parts named RedWall / RedPart, or any BasePart with Attribute BrainrotDeposit = true.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TAG = "BrainrotDeposit"

local function shouldTag(inst: Instance): boolean
	if not inst:IsA("BasePart") then
		return false
	end
	if inst:GetAttribute("BrainrotDeposit") == true then
		return true
	end
	local n = inst.Name
	return n == "RedWall" or n == "RedPart"
end

local function tryTag(inst: Instance)
	if shouldTag(inst) and not CollectionService:HasTag(inst, TAG) then
		CollectionService:AddTag(inst, TAG)
	end
end

local function scanRoot(root: Instance)
	for _, d in root:GetDescendants() do
		tryTag(d)
	end
	root.DescendantAdded:Connect(function(inst)
		task.defer(tryTag, inst)
	end)
end

local map = Workspace:WaitForChild("Map", 120)
if map then
	scanRoot(map)
else
	scanRoot(Workspace)
end
