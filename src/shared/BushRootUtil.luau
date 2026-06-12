-- [ACTIVE] BushRootUtil
--[[
	Resolves the logical bush root (direct child of BushSCRIPT / BushSCRIPTs folder) and its visual center.

	Important fix:
	Generated helper parts like _BushPromptAnchor must NEVER be treated as the bush root.
	If the server/client thinks that hidden anchor is the bush, cooldown attributes are applied to the
	anchor instead of the real bush model, so the real bush stays searchable and no timer appears.
]]

local M = {}

M.FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }
M.DEFAULT_LIFT_SCALE = 0.66

local PROMPT_ANCHOR_NAME = "_BushPromptAnchor"
local PROMPT_ATTACHMENT_NAME = "_BushPromptCenter"
local EMPTY_MESSAGE_ANCHOR_NAME = "_BushEmptyMessageAnchor"

function M.isBushFolderName(name: string): boolean
	for _, folderName in M.FOLDER_NAMES do
		if name == folderName then
			return true
		end
	end
	return false
end

function M.isBushContainer(inst: Instance?): boolean
	return inst ~= nil and inst:IsA("Folder") and M.isBushFolderName(inst.Name)
end

function M.isGeneratedPromptHelper(inst: Instance?): boolean
	if not inst then
		return false
	end

	if
		inst.Name == PROMPT_ANCHOR_NAME
		or inst.Name == PROMPT_ATTACHMENT_NAME
		or inst.Name == EMPTY_MESSAGE_ANCHOR_NAME
	then
		return true
	end

	local node: Instance? = inst.Parent
	while node do
		if
			node.Name == PROMPT_ANCHOR_NAME
			or node.Name == PROMPT_ATTACHMENT_NAME
			or node.Name == EMPTY_MESSAGE_ANCHOR_NAME
		then
			return true
		end
		node = node.Parent
	end

	return false
end

-- Returns the actual bush root only: the nearest Model/BasePart whose parent is a BushSCRIPT/BushSCRIPTs Folder.
-- It intentionally never returns Attachments, child leaf parts inside a bush, or generated prompt helper parts.
function M.resolveBushRoot(inst: Instance?): Instance?
	local node: Instance? = inst
	while node do
		if (node:IsA("Model") or node:IsA("BasePart")) and not M.isGeneratedPromptHelper(node) then
			local parent = node.Parent
			if M.isBushContainer(parent) then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

function M.resolveBushRootFromPrompt(prompt: ProximityPrompt): Instance?
	return M.resolveBushRoot(prompt.Parent)
end

-- Direct child of BushSCRIPT / BushSCRIPTs folder, not a nested part/model inside a bush.
function M.isDirectBushRoot(inst: Instance?): boolean
	if not inst then
		return false
	end
	if not inst:IsA("Model") and not inst:IsA("BasePart") then
		return false
	end
	if M.isGeneratedPromptHelper(inst) then
		return false
	end
	return M.isBushContainer(inst.Parent)
end

-- Grouped bushes: pivot the logical root plus any child Models so the whole cluster moves.
function M.getShakeTargets(root: Instance): { Instance }
	local targets: { Instance } = { root }
	if root:IsA("Model") then
		for _, child in root:GetChildren() do
			if child:IsA("Model") and not M.isGeneratedPromptHelper(child) then
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

	local existing = root:FindFirstChild(PROMPT_ANCHOR_NAME, true)
	if existing and existing:IsA("BasePart") then
		-- Reposition from the real bush visuals only. Do not let generated helpers affect the focus.
		local focus = M.focusWorldPosition(root)
		if focus then
			(existing :: BasePart).CFrame = CFrame.new(focus)
		end

		local att = existing:FindFirstChild(PROMPT_ATTACHMENT_NAME)
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
	anchor.Name = PROMPT_ANCHOR_NAME
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

	local function includePart(part: BasePart)
		if M.isGeneratedPromptHelper(part) then
			return
		end
		if part.Transparency >= 1 then
			return
		end

		foundPart = true
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

	if root:IsA("BasePart") then
		includePart(root :: BasePart)
	end

	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			includePart(desc :: BasePart)
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
