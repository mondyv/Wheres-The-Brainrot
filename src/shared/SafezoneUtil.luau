-- [ACTIVE] SafezoneUtil
--[[
	OBB point tests for plot zones under workspace.Map["Spawn And Bases"].
	• SafeZoneHitbox / SafezoneHitbox / Reddie / Raddie — spawn safe zone (toolbar / backpack).
	• Reddie / Raddie — legacy toolbar zone names (kept for older maps).
	• RedWall / RedPart — brainrot deposit (touch). Formerly named Reddie on some maps;
	  does NOT block toolbar while the player is also inside SafeZoneHitbox.
	• isCharacterInInventoryZone — safe zone minus RedWall-only (return equip / server sync).

	Never calls Instance:GetDescendants() — that API builds the full list synchronously and
	causes multi-second hitches when Spawn And Bases streams in near the red wall.
--]]

local CollectionService = game:GetService("CollectionService")

local SafezoneUtil = {}

local TOOLBAR_ZONE_NAMES = { Reddie = true, Raddie = true }
local INVENTORY_ZONE_NAMES = {
	SafeZoneHitbox = true,
	SafezoneHitbox = true,
	Reddie = true,
	Raddie = true,
}
local RED_WALL_NAMES = { RedWall = true, RedPart = true }
local DEPOSIT_TAG = "BrainrotDeposit"

local cachedReddieParts: { BasePart }? = nil
local cachedInventoryParts: { BasePart }? = nil
local cachedRedWallParts: { BasePart }? = nil
local reddieSet: { [BasePart]: boolean } = {}
local inventorySet: { [BasePart]: boolean } = {}
local redWallSet: { [BasePart]: boolean } = {}
local cachesBuilt = false
local rebuildInProgress = false
local depositHookConnected = false
local spawnBasesHookConnected = false
local mapHookConnected = false
local SCAN_YIELD_EVERY = 400

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	return math.abs(localPt.X) <= half.X
		and math.abs(localPt.Y) <= half.Y
		and math.abs(localPt.Z) <= half.Z
end

-- Safezone volumes are flat pads. Falling through an unstreamed floor (or slight
-- Y drift) must still count as "in base" — otherwise Return / land strip flash on.
local function isPointInsideSafezonePart(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	local xzPad = 5
	local ySlack = math.max(half.Y + 64, 120)
	return math.abs(localPt.X) <= half.X + xzPad
		and math.abs(localPt.Z) <= half.Z + xzPad
		and math.abs(localPt.Y) <= ySlack
end

local function getSpawnBasesFolder(): Instance?
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	return map:FindFirstChild("Spawn And Bases")
end

local function ensureListTables()
	if cachedReddieParts == nil then
		cachedReddieParts = {}
		cachedInventoryParts = {}
		cachedRedWallParts = {}
	end
end

local function removePartFromList(list: { BasePart }?, set: { [BasePart]: boolean }, part: BasePart)
	if not set[part] then
		return
	end
	set[part] = nil
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i] == part then
			table.remove(list, i)
			break
		end
	end
end

local function tryAddPart(list: { BasePart }, set: { [BasePart]: boolean }, part: BasePart)
	if set[part] then
		return
	end
	set[part] = true
	table.insert(list, part)
	part.Destroying:Connect(function()
		removePartFromList(cachedReddieParts, reddieSet, part)
		removePartFromList(cachedInventoryParts, inventorySet, part)
		removePartFromList(cachedRedWallParts, redWallSet, part)
	end)
end

local function isZonePartName(name: string): boolean
	return TOOLBAR_ZONE_NAMES[name] == true
		or INVENTORY_ZONE_NAMES[name] == true
		or RED_WALL_NAMES[name] == true
end

function SafezoneUtil.isZonePartName(name: string): boolean
	return isZonePartName(name)
end

function SafezoneUtil.registerZonePart(part: BasePart)
	if not part.Parent then
		return
	end
	ensureListTables()
	local name = part.Name
	if TOOLBAR_ZONE_NAMES[name] then
		tryAddPart(cachedReddieParts :: { BasePart }, reddieSet, part)
	end
	if INVENTORY_ZONE_NAMES[name] then
		tryAddPart(cachedInventoryParts :: { BasePart }, inventorySet, part)
	end
	if RED_WALL_NAMES[name] then
		tryAddPart(cachedRedWallParts :: { BasePart }, redWallSet, part)
	end
end

local function registerDepositPartsFromTags()
	for _, inst in CollectionService:GetTagged(DEPOSIT_TAG) do
		if inst:IsA("BasePart") then
			SafezoneUtil.registerZonePart(inst)
		end
	end
end

local function connectDepositTagListener()
	if depositHookConnected then
		return
	end
	depositHookConnected = true
	CollectionService:GetInstanceAddedSignal(DEPOSIT_TAG):Connect(function(inst)
		if inst:IsA("BasePart") then
			SafezoneUtil.registerZonePart(inst)
		end
	end)
end

local function hookSpawnBasesFolder(folder: Instance)
	if spawnBasesHookConnected then
		return
	end
	spawnBasesHookConnected = true
	folder.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") and isZonePartName(desc.Name) then
			SafezoneUtil.registerZonePart(desc)
		end
	end)
end

local function scanTreeForZoneParts(root: Instance)
	local stack = { root }
	local processed = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst:IsA("BasePart") and isZonePartName(inst.Name) then
			SafezoneUtil.registerZonePart(inst)
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		processed += 1
		if processed % SCAN_YIELD_EVERY == 0 then
			task.wait()
		end
	end
end

local function connectMapStreamingListener()
	if mapHookConnected then
		return
	end
	mapHookConnected = true

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 120)
		if not map then
			return
		end

		local existing = map:FindFirstChild("Spawn And Bases")
		if existing then
			hookSpawnBasesFolder(existing)
		end

		map.ChildAdded:Connect(function(ch)
			if ch.Name == "Spawn And Bases" then
				hookSpawnBasesFolder(ch)
				task.spawn(function()
					scanTreeForZoneParts(ch)
				end)
			end
		end)
	end)
end

local function startBackgroundScan()
	if rebuildInProgress or cachesBuilt then
		return
	end
	rebuildInProgress = true

	task.spawn(function()
		ensureListTables()
		registerDepositPartsFromTags()
		connectDepositTagListener()
		connectMapStreamingListener()

		local spawnBases = getSpawnBasesFolder()
		if spawnBases then
			hookSpawnBasesFolder(spawnBases)
			scanTreeForZoneParts(spawnBases)
		end

		cachesBuilt = true
		rebuildInProgress = false
	end)
end

local function ensureCaches()
	ensureListTables()
	connectDepositTagListener()
	connectMapStreamingListener()
	if not cachesBuilt and not rebuildInProgress then
		startBackgroundScan()
	end
end

function SafezoneUtil.warmCacheAsync()
	ensureListTables()
	connectDepositTagListener()
	connectMapStreamingListener()
	registerDepositPartsFromTags()

	local spawnBases = getSpawnBasesFolder()
	if spawnBases then
		hookSpawnBasesFolder(spawnBases)
	end

	if cachesBuilt or rebuildInProgress then
		return
	end
	startBackgroundScan()
end

function SafezoneUtil.invalidateCache()
	cachedReddieParts = nil
	cachedInventoryParts = nil
	cachedRedWallParts = nil
	reddieSet = {}
	inventorySet = {}
	redWallSet = {}
	cachesBuilt = false
	rebuildInProgress = false
	spawnBasesHookConnected = false
	startBackgroundScan()
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

local function isWorldPointInsideSafezoneParts(worldPoint: Vector3, parts: { BasePart }?): boolean
	if not parts or #parts == 0 then
		return false
	end
	for _, part in parts do
		if part.Parent and isPointInsideSafezonePart(worldPoint, part) then
			return true
		end
	end
	return false
end

function SafezoneUtil.awaitCacheReady(timeoutSec: number): boolean
	local deadline = os.clock() + math.max(timeoutSec, 0)
	ensureCaches()
	while os.clock() < deadline do
		if cachesBuilt then
			return true
		end
		task.wait(0.05)
	end
	return cachesBuilt == true
end

function SafezoneUtil.isCacheReady(): boolean
	return cachesBuilt == true
end

function SafezoneUtil.isWorldPointInReddie(worldPoint: Vector3): boolean
	ensureCaches()
	return isWorldPointInsideParts(worldPoint, cachedReddieParts)
end

function SafezoneUtil.isWorldPointInToolbarZone(worldPoint: Vector3): boolean
	return SafezoneUtil.isWorldPointInReddie(worldPoint)
end

function SafezoneUtil.isWorldPointInSafezone(worldPoint: Vector3): boolean
	ensureCaches()
	return isWorldPointInsideSafezoneParts(worldPoint, cachedInventoryParts)
end

-- Lighting: standing on the pad only. Do not keep "day" while falling or
-- walking the jungle just because Y slack is huge for HUD/Return.
local function isPointInsideSafezonePad(worldPoint: Vector3, part: BasePart): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5
	local xzPad = 5
	local ySlack = math.max(half.Y + 16, 28)
	return math.abs(localPt.X) <= half.X + xzPad
		and math.abs(localPt.Z) <= half.Z + xzPad
		and math.abs(localPt.Y) <= ySlack
end

function SafezoneUtil.isWorldPointInSafezonePad(worldPoint: Vector3): boolean
	ensureCaches()
	local parts = cachedInventoryParts
	if not parts or #parts == 0 then
		return false
	end
	for _, part in parts do
		if part.Parent and isPointInsideSafezonePad(worldPoint, part) then
			return true
		end
	end
	return false
end

function SafezoneUtil.isCharacterInSafezonePad(character: Model?): boolean
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return SafezoneUtil.isWorldPointInSafezonePad((hrp :: BasePart).Position)
end

function SafezoneUtil.isWorldPointInRedWall(worldPoint: Vector3): boolean
	ensureCaches()
	return isWorldPointInsideParts(worldPoint, cachedRedWallParts)
end

function SafezoneUtil.getRedWallSamplePositions(): { Vector3 }
	ensureCaches()
	local out: { Vector3 } = {}
	if cachedRedWallParts then
		for _, part in cachedRedWallParts do
			if part.Parent then
				table.insert(out, part.Position)
			end
		end
	end
	return out
end

local function horizontalDistanceToPartOBB(worldPoint: Vector3, part: BasePart): number
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local halfX = part.Size.X * 0.5
	local halfZ = part.Size.Z * 0.5
	local px, pz = localPt.X, localPt.Z
	local clampedX = math.clamp(px, -halfX, halfX)
	local clampedZ = math.clamp(pz, -halfZ, halfZ)
	local dx = px - clampedX
	local dz = pz - clampedZ
	return math.sqrt(dx * dx + dz * dz)
end

-- World center of the spawn safe zone (average of SafeZoneHitbox / inventory zone parts).
function SafezoneUtil.getSafezoneCenter(): Vector3?
	ensureCaches()
	local parts = cachedInventoryParts
	if not parts or #parts == 0 then
		return nil
	end
	local sum = Vector3.zero
	local n = 0
	for _, part in parts do
		if part.Parent then
			sum += part.Position
			n += 1
		end
	end
	if n == 0 then
		return nil
	end
	return sum / n
end

--- Horizontal studs from the nearest safezone edge (0 when inside any inventory zone part).
function SafezoneUtil.getHorizontalDistanceFromSafezone(worldPoint: Vector3): number?
	ensureCaches()
	local parts = cachedInventoryParts
	if not parts or #parts == 0 then
		return nil
	end
	if SafezoneUtil.isWorldPointInSafezone(worldPoint) then
		return 0
	end
	local best = math.huge
	for _, part in parts do
		if part.Parent then
			local d = horizontalDistanceToPartOBB(worldPoint, part)
			if d < best then
				best = d
			end
		end
	end
	if best == math.huge then
		return nil
	end
	return best
end

function SafezoneUtil.isWorldPointInInventoryZone(worldPoint: Vector3): boolean
	if not SafezoneUtil.isWorldPointInSafezone(worldPoint) then
		return false
	end
	return not SafezoneUtil.isWorldPointInRedWall(worldPoint)
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
