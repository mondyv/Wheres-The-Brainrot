--[[
	OBB point tests for plot zones under workspace.Map["Spawn And Bases"].
	• Reddie — toolbar / backpack access + server equip (Map.Spawn And Bases.Reddie).
	• SafeZoneHitbox / SafezoneHitbox / Raddie — legacy grapple-disable volume (not toolbar).
	• RedWall / RedPart — brainrot deposit only (CollectionService + touch); never hides toolbar.
]]

local SafezoneUtil = {}

local TOOLBAR_ZONE_NAMES = { "Reddie" }
local GRAPPLE_SAFEZONE_NAMES = { "SafeZoneHitbox", "SafezoneHitbox", "Reddie", "Raddie" }
local RED_WALL_NAMES = { "RedWall", "RedPart" }

local cachedReddieParts: { BasePart }? = nil
local cachedGrappleSafezoneParts: { BasePart }? = nil
local cachedRedWallParts: { BasePart }? = nil

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

local function findNamedPartsUnder(root: Instance, names: { string }): { BasePart }
	local parts: { BasePart } = {}
	for _, name in names do
		local inst = root:FindFirstChild(name, true)
		if inst then
			collectBasePartsFrom(inst, parts)
		end
	end
	return parts
end

local function getSpawnBasesFolder(): Instance?
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	return map:FindFirstChild("Spawn And Bases")
end

local function cacheStillValid(cached: { BasePart }?): boolean
	if not cached then
		return false
	end
	for _, p in cached do
		if p.Parent then
			return true
		end
	end
	return false
end

local function refreshReddieHitboxes()
	if cacheStillValid(cachedReddieParts) then
		return
	end
	cachedReddieParts = {}
	local spawnBases = getSpawnBasesFolder()
	if not spawnBases then
		return
	end
	cachedReddieParts = findNamedPartsUnder(spawnBases, TOOLBAR_ZONE_NAMES)
end

local function refreshGrappleSafezoneHitboxes()
	if cacheStillValid(cachedGrappleSafezoneParts) then
		return
	end
	cachedGrappleSafezoneParts = {}
	local spawnBases = getSpawnBasesFolder()
	if not spawnBases then
		return
	end
	cachedGrappleSafezoneParts = findNamedPartsUnder(spawnBases, GRAPPLE_SAFEZONE_NAMES)
end

local function refreshRedWallHitboxes()
	if cacheStillValid(cachedRedWallParts) then
		return
	end
	cachedRedWallParts = {}
	local spawnBases = getSpawnBasesFolder()
	if not spawnBases then
		return
	end
	cachedRedWallParts = findNamedPartsUnder(spawnBases, RED_WALL_NAMES)
end

function SafezoneUtil.invalidateCache()
	cachedReddieParts = nil
	cachedGrappleSafezoneParts = nil
	cachedRedWallParts = nil
end

local function isWorldPointInsideParts(worldPoint: Vector3, parts: { BasePart }?): boolean
	if not parts or #parts == 0 then
		return false
	end
	for _, part in parts do
		if part.Parent and isPointInsidePartOBB(worldPoint, part) then
			return true
		end
	end
	return false
end

function SafezoneUtil.isWorldPointInReddie(worldPoint: Vector3): boolean
	refreshReddieHitboxes()
	return isWorldPointInsideParts(worldPoint, cachedReddieParts)
end

function SafezoneUtil.isWorldPointInToolbarZone(worldPoint: Vector3): boolean
	return SafezoneUtil.isWorldPointInReddie(worldPoint)
end

function SafezoneUtil.isWorldPointInSafezone(worldPoint: Vector3): boolean
	refreshGrappleSafezoneHitboxes()
	return isWorldPointInsideParts(worldPoint, cachedGrappleSafezoneParts)
end

function SafezoneUtil.isWorldPointInRedWall(worldPoint: Vector3): boolean
	refreshRedWallHitboxes()
	return isWorldPointInsideParts(worldPoint, cachedRedWallParts)
end

function SafezoneUtil.isWorldPointInInventoryZone(worldPoint: Vector3): boolean
	return SafezoneUtil.isWorldPointInReddie(worldPoint)
end

function SafezoneUtil.isCharacterInToolbarZone(character: Model?): boolean
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return SafezoneUtil.isWorldPointInReddie((hrp :: BasePart).Position)
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

function SafezoneUtil.isCharacterInInventoryZone(character: Model?): boolean
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return SafezoneUtil.isWorldPointInInventoryZone((hrp :: BasePart).Position)
end

return SafezoneUtil
