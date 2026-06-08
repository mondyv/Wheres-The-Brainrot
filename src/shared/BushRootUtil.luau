-- [ACTIVE] BushRootUtil
--[[
	Resolves the logical bush root (direct child of BushSCRIPT / BushSCRIPTs) and its visual center.
	Grouped bush models use one root so prompts, billboards, and shiver move the whole cluster.
--]]

local M = {}

M.FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }
M.DEFAULT_LIFT_SCALE = 0.66

function M.isBushFolderName(name: string): boolean
	for _, folderName in M.FOLDER_NAMES do
		if name == folderName then
			return true
		end
	end
	return false
end

function M.resolveBushRoot(inst: Instance?): Instance?
	local node: Instance? = inst
	while node do
		local parent = node.Parent
		if parent and M.isBushFolderName(parent.Name) then
			return node
		end
		node = parent
	end
	return nil
end

function M.resolveBushRootFromPrompt(prompt: ProximityPrompt): Instance?
	local node: Instance? = prompt.Parent
	if node and node:IsA("Attachment") then
		node = node.Parent
	end
	return M.resolveBushRoot(node)
end

-- Direct child of BushSCRIPT / BushSCRIPTs (not a nested model inside a grouped bush).
function M.isDirectBushRoot(inst: Instance?): boolean
	if not inst then
		return false
	end
	if not inst:IsA("Model") and not inst:IsA("BasePart") then
		return false
	end
	local parent = inst.Parent
	return parent ~= nil and M.isBushFolderName(parent.Name)
end

-- Grouped bushes: pivot the logical root plus any child Models so the whole cluster moves.
function M.getShakeTargets(root: Instance): { Instance }
	local targets: { Instance } = { root }
	if root:IsA("Model") then
		for _, child in root:GetChildren() do
			if child:IsA("Model") then
				table.insert(targets, child)
			end
		end
	end
	return targets
end

function M.ensurePromptAnchorPart(root: Instance): BasePart?
	if not root.Parent then
		return nil
	end
	local existing = root:FindFirstChild("_BushPromptAnchor", true)
	if existing and existing:IsA("BasePart") then
		local focus = M.focusWorldPosition(root)
		if focus then
			(existing :: BasePart).CFrame = CFrame.new(focus)
		end
		local att = existing:FindFirstChild("_BushPromptCenter")
		if att and att:IsA("Attachment") then
			att.Position = Vector3.zero
		end
		return existing :: BasePart
	end
	local focus = M.focusWorldPosition(root)
	if not focus then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Name = "_BushPromptAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.15, 0.15, 0.15)
	anchor.CFrame = CFrame.new(focus)
	anchor.Parent = root
	return anchor
end

function M.focusWorldPosition(root: Instance, liftScale: number?): Vector3?
	if not root.Parent then
		return nil
	end
	local lift = if typeof(liftScale) == "number" then liftScale else M.DEFAULT_LIFT_SCALE

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local foundPart = false

	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			foundPart = true
			local cf = desc.CFrame
			local h = desc.Size * 0.5
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						minX = math.min(minX, wp.X)
						minY = math.min(minY, wp.Y)
						minZ = math.min(minZ, wp.Z)
						maxX = math.max(maxX, wp.X)
						maxY = math.max(maxY, wp.Y)
						maxZ = math.max(maxZ, wp.Z)
					end
				end
			end
		end
	end

	if root:IsA("BasePart") then
		foundPart = true
		local part = root :: BasePart
		local cf = part.CFrame
		local h = part.Size * 0.5
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
					minX = math.min(minX, wp.X)
					minY = math.min(minY, wp.Y)
					minZ = math.min(minZ, wp.Z)
					maxX = math.max(maxX, wp.X)
					maxY = math.max(maxY, wp.Y)
					maxZ = math.max(maxZ, wp.Z)
				end
			end
		end
	end

	if foundPart then
		local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
		local height = math.max(0.5, maxY - minY)
		return center + Vector3.new(0, height * lift, 0)
	end

	if root:IsA("Model") then
		local ok, cf, size = pcall(function()
			return (root :: Model):GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			return cf.Position + Vector3.new(0, size.Y * lift, 0)
		end
	end

	return nil
end

return M
