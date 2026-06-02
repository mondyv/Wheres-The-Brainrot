-- Server-side swing attach validation (client physics stay local; hook must be allowed here).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafezoneUtil = require(ReplicatedStorage.Shared.SafezoneUtil)
local SwingConfig = require(ReplicatedStorage.Shared.SwingConfig)
local SwingDetection = require(ReplicatedStorage.Shared.SwingDetection)
local SwingProgression = require(ReplicatedStorage.Shared.SwingProgression)
local SwingUpgrades = require(ReplicatedStorage.Shared.SwingUpgrades)

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local attachFn = remotesFolder:FindFirstChild("RequestSwingAttach") :: RemoteFunction?
if not attachFn then
	attachFn = Instance.new("RemoteFunction")
	attachFn.Name = "RequestSwingAttach"
	attachFn.Parent = remotesFolder
end

local partCache: { BasePart } = {}
local cacheStamp = 0
local CACHE_TTL = 1.0

local function rebuildCache()
	table.clear(partCache)
	local seen: { [BasePart]: boolean } = {}

	for _, obj in CollectionService:GetTagged(SwingConfig.SWING_TARGET_TAG) do
		if obj:IsA("BasePart") and obj.Parent then
			seen[obj] = true
			table.insert(partCache, obj)
		end
	end

	local map = workspace:FindFirstChild("Map")
	local vine = map and map:FindFirstChild("Vine")
	if vine then
		for _, d in vine:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "SwingTarget" and not seen[d] then
				table.insert(partCache, d)
			end
		end
	end
	cacheStamp = os.clock()
end

local function getPartCache(): { BasePart }
	if os.clock() - cacheStamp > CACHE_TTL then
		rebuildCache()
	end
	return partCache
end

local function attachRangeForPlayer(player: Player): number
	local ropeLevel = player:GetAttribute(SwingUpgrades.ROPE_LEVEL_ATTR)
	if typeof(ropeLevel) ~= "number" then
		ropeLevel = 0
	end
	local ropePts = player:GetAttribute("RopeLength")
	local ropeAttrPts = if typeof(ropePts) == "number" then ropePts else 0
	local rs = SwingProgression.ropeStats(ropeLevel)
	return math.max(rs.reachStuds + ropeAttrPts * 2, 8)
end

local function isAirborneHumanoid(humanoid: Humanoid, lastSwingEndClock: number, now: number): boolean
	local st = humanoid:GetState()
	if st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.FallingDown then
		return true
	end
	return now - lastSwingEndClock < SwingConfig.REATTACH_AIR_GRACE
end

local function validateAttach(player: Player, target: Instance?): boolean
	if typeof(target) ~= "Instance" or not SwingDetection.isValidSwingTarget(target) then
		return false
	end
	local part = target :: BasePart

	local character = player.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not humanoid then
		return false
	end
	if humanoid.Health <= 0 then
		return false
	end

	local inSafezone = SafezoneUtil.isCharacterInSafezone(character)
	if inSafezone then
		return false
	end

	local now = os.clock()
	local lastEnd = if typeof(player:GetAttribute("LastSwingEndClock")) == "number"
		then player:GetAttribute("LastSwingEndClock")
		else -1e9

	local attachWorld = SwingDetection.closestAttachWorldOnPart(part, hrp.Position)
	local dist = (hrp.Position - attachWorld).Magnitude
	local limit = SwingDetection.attachRangeLimit(attachRangeForPlayer(player))
	if dist < SwingConfig.MIN_ATTACH_DIST or dist > limit then
		return false
	end

	local query: SwingDetection.SwingQuery = {
		hrpPosition = hrp.Position,
		humanoid = humanoid,
		isAirborne = isAirborneHumanoid(humanoid, lastEnd, now),
		isSwinging = false,
		isDead = false,
		inSafezone = inSafezone,
		lastSwingEndClock = lastEnd,
		attachRangeStuds = attachRangeForPlayer(player),
		cameraLook = nil,
		partCache = { part },
		now = now,
	}

	if not SwingDetection.mayAttachFromState(query, dist) then
		return false
	end

	-- Server picks nearest without camera; client must send a target that is in range.
	local best, _, bestDist = SwingDetection.findBestTarget({
		hrpPosition = hrp.Position,
		humanoid = humanoid,
		isAirborne = query.isAirborne,
		isSwinging = false,
		isDead = false,
		inSafezone = false,
		lastSwingEndClock = lastEnd,
		attachRangeStuds = query.attachRangeStuds,
		cameraLook = nil,
		partCache = getPartCache(),
		now = now,
	})

	if not best then
		return false
	end

	-- Allow the requested part if it is the server best, or equally close within slack.
	if best ~= part and math.abs(bestDist - dist) > 2.5 then
		return false
	end

	return true
end

attachFn.OnServerInvoke = function(player: Player, target: Instance?)
	return validateAttach(player, target)
end
