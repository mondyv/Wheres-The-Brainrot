-- [ACTIVE] TagBrainrotDeposits.server
-- Tags deposit BaseParts so BushHarvest can listen for touches.
-- Matches parts named RedWall / RedPart, or any BasePart with Attribute BrainrotDeposit = true.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TAG = "BrainrotDeposit"
local SCAN_YIELD_EVERY = 400

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

local function scanRootChunked(root: Instance)
	task.spawn(function()
		local stack = { root }
		local processed = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			tryTag(inst)
			for _, child in inst:GetChildren() do
				table.insert(stack, child)
			end
			processed += 1
			if processed % SCAN_YIELD_EVERY == 0 then
				task.wait()
			end
		end
	end)
	root.DescendantAdded:Connect(function(inst)
		task.defer(tryTag, inst)
	end)
end

local map = Workspace:WaitForChild("Map", 120)
if map then
	scanRootChunked(map)
else
	scanRootChunked(Workspace)
end
