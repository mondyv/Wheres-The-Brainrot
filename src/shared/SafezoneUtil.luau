--[[
	OBB point test for the plot safe zone (hotbar visible, grapple disabled, etc.).
	Map layout: workspace.Map["Spawn And Bases"].RedWall (Model or Part).
	Fallbacks: Raddie, SafezoneHitbox.
]]

local SafezoneUtil = {}

local FALLBACK_PART_NAMES = { "Raddie", "SafezoneHitbox" }

local cachedParts: { BasePart }? = nil

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X
		and math.abs(localPt.Y) <= half.Y
		and math.abs(localPt.Z) <= half.Z
end

local function collectBasePartsFrom(inst: Instance, out: { BasePart })
	if inst:IsA("BasePart") then
		table.insert(out, inst)
		return
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
end

local function refreshHitboxes()
	if cachedParts then
		for _, p in cachedParts do
			if p.Parent then
				return
			end
		end
	end
	cachedParts = {}

	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local spawnBases = map:FindFirstChild("Spawn And Bases")
	if not spawnBases then
		return
	end

	local parts: { BasePart } = {}
	local redWall = spawnBases:FindFirstChild("RedWall")
	if redWall then
		collectBasePartsFrom(redWall, parts)
	end

	if #parts == 0 then
		for _, name in FALLBACK_PART_NAMES do
			local h = spawnBases:FindFirstChild(name, true)
			if h and h:IsA("BasePart") then
				table.insert(parts, h)
				break
			end
		end
	end

	cachedParts = parts
end

function SafezoneUtil.invalidateCache()
	cachedParts = nil
end

function SafezoneUtil.isWorldPointInSafezone(worldPoint: Vector3): boolean
	refreshHitboxes()
	if not cachedParts or #cachedParts == 0 then
		return false
	end
	for _, part in cachedParts do
		if isPointInsidePartOBB(worldPoint, part) then
			return true
		end
	end
	return false
end

function SafezoneUtil.isCharacterInSafezone(character: Model?): boolean
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return SafezoneUtil.isWorldPointInSafezone((hrp :: BasePart).Position)
end

return SafezoneUtil
