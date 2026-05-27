--[[
	OBB point test for the plot safe zone (hotbar, deposit, etc.).
	Map layout: workspace.Map["Spawn And Bases"] — hitbox part name is usually "Raddie" (legacy: SafezoneHitbox).
]]

local SafezoneUtil = {}

local SAFEZONE_PART_NAMES = { "Raddie", "SafezoneHitbox" }

local cachedHitbox: BasePart? = nil

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X
		and math.abs(localPt.Y) <= half.Y
		and math.abs(localPt.Z) <= half.Z
end

local function findSafezonePart(root: Instance): BasePart?
	for _, name in SAFEZONE_PART_NAMES do
		local h = root:FindFirstChild(name, true)
		if h and h:IsA("BasePart") then
			return h
		end
	end
	return nil
end

local function refreshHitbox()
	if cachedHitbox and cachedHitbox.Parent then
		return
	end
	cachedHitbox = nil
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local spawnBases = map:FindFirstChild("Spawn And Bases")
	if not spawnBases then
		return
	end
	cachedHitbox = findSafezonePart(spawnBases)
end

function SafezoneUtil.invalidateCache()
	cachedHitbox = nil
end

function SafezoneUtil.isWorldPointInSafezone(worldPoint: Vector3): boolean
	refreshHitbox()
	if not cachedHitbox then
		return false
	end
	return isPointInsidePartOBB(worldPoint, cachedHitbox)
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
