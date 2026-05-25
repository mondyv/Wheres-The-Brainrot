-- Tags every BasePart named "SwingTarget" (or "SwingPart") under the map
-- with the CollectionService tag "SwingTarget" so clients can use GetTagged().

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TAG = "SwingTarget"

local function tryTag(inst: Instance)
	if inst:IsA("BasePart") and (inst.Name == "SwingTarget" or inst.Name == "SwingPart") then
		if not CollectionService:HasTag(inst, TAG) then
			CollectionService:AddTag(inst, TAG)
		end
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
