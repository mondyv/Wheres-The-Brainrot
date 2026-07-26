-- [ACTIVE] GlobalRaritySpawnService
--[[
	Per-server rarity spawn timers and active map markers.
	Each server owns its own countdown; globalspawn admin command fans out via MessagingService.
]]

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local GlobalRaritySpawnConfig =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GlobalRaritySpawnConfig"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local IndexService = require(script.Parent:WaitForChild("IndexService"))

local C = GlobalRaritySpawnConfig

local M = {}

export type ActiveSpawn = {
	rarity: string,
	bushKey: string,
	brainrotName: string,
	mutation: string,
	level: number,
	endsAt: number,
}

export type GlobalState = {
	version: number,
	timers: { [string]: number },
	active: ActiveSpawn?,
}

local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local BUSH_HIDDEN_NAME_ATTR = "HiddenBrainrotName"
local BUSH_HIDDEN_MUTATION_ATTR = "HiddenBrainrotMutation"
local BUSH_HIDDEN_LEVEL_ATTR = "HiddenBrainrotLevel"
local BUSH_HIDDEN_BASE_INCOME_ATTR = "HiddenBrainrotBaseIncome"
local BUSH_LOOT_PHASE_ATTR = "BushLootPhase"
local BUSH_ON_COOLDOWN_ATTR = "BushOnCooldown"
local BUSH_LOOT_PHASE_READY = "ready"

local currentState: GlobalState = {
	version = 1,
	timers = {},
	active = nil,
}

local updatedRE: RemoteEvent? = nil
local tickInFlight = false
local messagingReady = false

local function ensureRemotes(): RemoteEvent
	if updatedRE and updatedRE.Parent then
		return updatedRE
	end
	local folder = ReplicatedStorage:FindFirstChild(C.REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = C.REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild(C.UPDATED_REMOTE)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = C.UPDATED_REMOTE
		ev.Parent = folder
	end
	updatedRE = ev :: RemoteEvent
	return updatedRE
end

local function defaultTimers(now: number): { [string]: number }
	local timers: { [string]: number } = {}
	for _, tier in C.TIERS do
		timers[tier.id] = now + tier.intervalSec
	end
	return timers
end

local function normalizeState(raw: any): GlobalState
	local now = os.time()
	local timers = defaultTimers(now)
	if typeof(raw) == "table" and typeof(raw.timers) == "table" then
		for _, tier in C.TIERS do
			local endsAt = raw.timers[tier.id]
			if typeof(endsAt) == "number" and endsAt > now - 60 then
				timers[tier.id] = endsAt
			end
		end
	end
	local active: ActiveSpawn? = nil
	if typeof(raw) == "table" and typeof(raw.active) == "table" then
		local a = raw.active
		if
			typeof(a.rarity) == "string"
			and typeof(a.bushKey) == "string"
			and typeof(a.brainrotName) == "string"
			and typeof(a.endsAt) == "number"
		then
			active = {
				rarity = a.rarity,
				bushKey = a.bushKey,
				brainrotName = a.brainrotName,
				mutation = if typeof(a.mutation) == "string" then a.mutation else "normal",
				level = if typeof(a.level) == "number" then math.max(1, math.floor(a.level)) else 1,
				endsAt = a.endsAt,
			}
			if active.endsAt <= now then
				active = nil
			end
		end
	end
	return {
		version = 1,
		timers = timers,
		active = active,
	}
end

local function bushWorldPos(bush: Instance): Vector3
	if bush:IsA("BasePart") then
		return bush.Position
	end
	return (bush :: Model):GetPivot().Position
end

function M.bushKeyForInstance(bush: Instance): string
	local pos = bushWorldPos(bush)
	return string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z)
end

local function isLootableBush(inst: Instance): boolean
	if not inst:IsA("Model") and not inst:IsA("BasePart") then
		return false
	end
	if BushRootUtil.isGeneratedPromptHelper and BushRootUtil.isGeneratedPromptHelper(inst) then
		return false
	end
	return BushRootUtil.isBushContainer(inst.Parent)
end

local function landWeight(land: number): number
	if land < C.MIN_SPAWN_LAND or land > C.MAX_SPAWN_LAND then
		return 0
	end
	return (C.MAX_SPAWN_LAND - land + 1)
end

local cachedSpawnCandidates: { { bush: Instance, weight: number } } = {}
local spawnCacheBuiltAt = 0
local SPAWN_CACHE_TTL = 30

local function buildSpawnBushList(): { { bush: Instance, weight: number } }
	local out: { { bush: Instance, weight: number } } = {}
	local seen: { [Instance]: boolean } = {}
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return out
	end
	for _, desc in map:GetDescendants() do
		if desc:IsA("Folder") and BushRootUtil.isBushFolderName(desc.Name) then
			for _, child in desc:GetChildren() do
				if isLootableBush(child) and not seen[child] then
					seen[child] = true
					local pos = bushWorldPos(child)
					-- Use land hitboxes (not Spawn pads) so rare spawns can land on real bushes.
					local land = LandResolver.resolveLandAtPosition(pos)
					local w = if typeof(land) == "number" then landWeight(land) else 0
					if w > 0 then
						table.insert(out, { bush = child, weight = w })
					end
				end
			end
		end
	end
	return out
end

local function refreshSpawnBushCache()
	cachedSpawnCandidates = buildSpawnBushList()
	spawnCacheBuiltAt = os.clock()
end

local function collectSpawnBushes(): { { bush: Instance, weight: number } }
	if #cachedSpawnCandidates == 0 or (os.clock() - spawnCacheBuiltAt) > SPAWN_CACHE_TTL then
		refreshSpawnBushCache()
	end
	local out: { { bush: Instance, weight: number } } = {}
	for _, c in cachedSpawnCandidates do
		if c.bush.Parent and isLootableBush(c.bush) then
			table.insert(out, c)
		end
	end
	return out
end

local function pickWeightedBush(candidates: { { bush: Instance, weight: number } }): Instance?
	if #candidates == 0 then
		return nil
	end
	local total = 0
	for _, c in candidates do
		total += c.weight
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	local acc = 0
	for _, c in candidates do
		acc += c.weight
		if roll <= acc then
			return c.bush
		end
	end
	return candidates[#candidates].bush
end

local function clearBushGlobalSpawn(bush: Instance)
	bush:SetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR, nil)
	bush:SetAttribute(C.BUSH_GLOBAL_KEY_ATTR, nil)
	bush:SetAttribute(C.BUSH_GLOBAL_RARITY_ATTR, nil)
end

local function findBushByKey(key: string): Instance?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	for _, desc in map:GetDescendants() do
		if
			isLootableBush(desc)
			and desc:GetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR) == true
			and desc:GetAttribute(C.BUSH_GLOBAL_KEY_ATTR) == key
		then
			return desc
		end
	end
	return nil
end

local function applySpawnToBush(bush: Instance, tierId: string, pick: any, mutationId: string, level: number)
	local key = M.bushKeyForInstance(bush)
	bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, true)
	bush:SetAttribute(BUSH_ON_COOLDOWN_ATTR, false)
	bush:SetAttribute(BUSH_LOOT_PHASE_ATTR, BUSH_LOOT_PHASE_READY)
	bush:SetAttribute(BUSH_HIDDEN_RARITY_ATTR, pick.rarity)
	bush:SetAttribute(BUSH_HIDDEN_NAME_ATTR, pick.name)
	bush:SetAttribute(BUSH_HIDDEN_MUTATION_ATTR, mutationId)
	bush:SetAttribute(BUSH_HIDDEN_LEVEL_ATTR, level)
	bush:SetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR, pick.baseIncome)
	bush:SetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR, true)
	bush:SetAttribute(C.BUSH_GLOBAL_KEY_ATTR, key)
	bush:SetAttribute(C.BUSH_GLOBAL_RARITY_ATTR, tierId)
	return key
end

local function clearActiveSpawnState(state: GlobalState, restoreBush: boolean)
	if state.active and restoreBush then
		local bush = findBushByKey(state.active.bushKey)
		if bush then
			clearBushGlobalSpawn(bush)
			bush:SetAttribute(BUSH_HAS_BRAINROT_ATTR, false)
			bush:SetAttribute(BUSH_HIDDEN_NAME_ATTR, nil)
			bush:SetAttribute(BUSH_HIDDEN_RARITY_ATTR, nil)
			bush:SetAttribute(BUSH_HIDDEN_MUTATION_ATTR, nil)
			bush:SetAttribute(BUSH_HIDDEN_LEVEL_ATTR, nil)
			bush:SetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR, nil)
		end
	end
	state.active = nil
end

local function publishReplication(state: GlobalState, eventKind: string?, tierId: string?)
	for _, tier in C.TIERS do
		ReplicatedStorage:SetAttribute(C.timerAttrForTier(tier.id), state.timers[tier.id] or 0)
	end
	local active = state.active
	if active then
		local ok, icon = pcall(function()
			return IndexService.getIconFor(active.brainrotName, active.mutation)
		end)
		ReplicatedStorage:SetAttribute(C.ACTIVE_RARITY_ATTR, active.rarity)
		ReplicatedStorage:SetAttribute(C.ACTIVE_BUSH_KEY_ATTR, active.bushKey)
		ReplicatedStorage:SetAttribute(C.ACTIVE_ENDS_ATTR, active.endsAt)
		ReplicatedStorage:SetAttribute(C.ACTIVE_NAME_ATTR, active.brainrotName)
		ReplicatedStorage:SetAttribute(C.ACTIVE_MUTATION_ATTR, active.mutation)
		ReplicatedStorage:SetAttribute(C.ACTIVE_ICON_ATTR, if ok and typeof(icon) == "string" then icon else "")
	else
		ReplicatedStorage:SetAttribute(C.ACTIVE_RARITY_ATTR, nil)
		ReplicatedStorage:SetAttribute(C.ACTIVE_BUSH_KEY_ATTR, nil)
		ReplicatedStorage:SetAttribute(C.ACTIVE_ENDS_ATTR, nil)
		ReplicatedStorage:SetAttribute(C.ACTIVE_NAME_ATTR, nil)
		ReplicatedStorage:SetAttribute(C.ACTIVE_MUTATION_ATTR, nil)
		ReplicatedStorage:SetAttribute(C.ACTIVE_ICON_ATTR, nil)
	end

	local ev = ensureRemotes()
	ev:FireAllClients(
		eventKind or "sync",
		tierId,
		active and active.rarity or nil,
		active and active.brainrotName or nil
	)
end

local function broadcastState(state: GlobalState, eventKind: string?, tierId: string?)
	currentState = state
	publishReplication(state, eventKind, tierId)
end

local function brainrotIsAvailable(def: any): boolean
	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots then
		return false
	end
	if not Brainrots.isPlayableBrainrotName(def.name) then
		return false
	end
	for _, desc in brainrots:GetDescendants() do
		if desc:IsA("Model") and desc.Name == def.name then
			return true
		end
	end
	return false
end

local function rollGlobalSpawn(tierId: string): (Instance?, ActiveSpawn?)
	local pool = Brainrots.brainrotsOfRarity(tierId :: any, brainrotIsAvailable)
	if #pool == 0 then
		pool = Brainrots.brainrotsOfRarity(tierId :: any, nil)
	end
	if #pool == 0 then
		return nil, nil
	end
	local pick = pool[math.random(1, #pool)]
	local mutationId = Brainrots.rollMutation(C.MAX_SPAWN_LAND)
	local level = Brainrots.rollBushHarvestLevel()
	local bush = pickWeightedBush(collectSpawnBushes())
	if not bush then
		return nil, nil
	end
	local now = os.time()
	local key = applySpawnToBush(bush, tierId, pick, mutationId, level)
	local active: ActiveSpawn = {
		rarity = tierId,
		bushKey = key,
		brainrotName = pick.name,
		mutation = mutationId,
		level = level,
		endsAt = now + C.MARKER_DURATION_SEC,
	}
	return bush, active
end

local function trySpawnTier(state: GlobalState, tierId: string, force: boolean?): boolean
	if state.active and not force then
		return false
	end
	if state.active and force then
		clearActiveSpawnState(state, true)
	end
	local _, active = rollGlobalSpawn(tierId)
	if not active then
		return false
	end
	state.active = active
	return true
end

function M.getState(): GlobalState
	return currentState
end

function M.onBushClaimed(bush: Instance)
	if bush:GetAttribute(C.BUSH_GLOBAL_SPAWN_ATTR) ~= true then
		return
	end
	local key = bush:GetAttribute(C.BUSH_GLOBAL_KEY_ATTR)
	if typeof(key) ~= "string" then
		return
	end
	clearBushGlobalSpawn(bush)
	if currentState.active and currentState.active.bushKey == key then
		local state = table.clone(currentState)
		state.timers = table.clone(currentState.timers)
		clearActiveSpawnState(state, false)
		broadcastState(state, "claimed", currentState.active.rarity)
	end
end

function M.forceSpawn(tierId: string): (boolean, string?)
	local tier = C.tierById(tierId)
	if not tier then
		return false, "Unknown tier. Use: mythic, legendary, godly, secret"
	end
	local state = {
		version = 1,
		timers = table.clone(currentState.timers),
		active = currentState.active,
	}
	if not trySpawnTier(state, tier.id, true) then
		return false, "Could not place spawn (no bush or brainrot pool empty)."
	end
	broadcastState(state, "spawn", tier.id)
	return true,
		string.format(
			"Spawned %s on this server at bush %s.",
			tier.displayName,
			state.active and state.active.bushKey or "?"
		)
end

function M.broadcastGlobalSpawn(tierId: string): (boolean, string?)
	local tier = C.tierById(tierId)
	if not tier then
		return false, "Unknown tier. Use: mythic, legendary, godly, secret"
	end
	if messagingReady then
		task.spawn(function()
			local ok, err = pcall(function()
				MessagingService:PublishAsync(C.SPAWN_CMD_TOPIC, {
					tierId = tier.id,
					sentAt = os.time(),
				})
			end)
			if not ok then
				warn("[GlobalRaritySpawnService] global spawn publish failed:", err)
			end
		end)
		return true, string.format("Global %s spawn sent to all servers.", tier.displayName)
	end
	return M.forceSpawn(tier.id)
end

local function advanceState(state: GlobalState): (boolean, string?)
	local now = os.time()
	local changed = false
	local spawnTier: string? = nil

	if state.active and now >= state.active.endsAt then
		clearActiveSpawnState(state, true)
		changed = true
	end

	-- Intervals are multiples of mythic (5/10/15/20m), so several tiers often
	-- expire together. Collect due tiers and prefer the rarest; never burn a
	-- full interval just because another marker is already active.
	local dueTiers: { GlobalRaritySpawnConfig.TierDef } = {}
	for _, tier in C.TIERS do
		local endsAt = state.timers[tier.id]
		if typeof(endsAt) == "number" and now >= endsAt then
			table.insert(dueTiers, tier)
		end
	end

	if #dueTiers > 0 then
		if state.active then
			local deferTo = math.max(now + 1, state.active.endsAt + 1)
			for _, tier in dueTiers do
				if state.timers[tier.id] ~= deferTo then
					state.timers[tier.id] = deferTo
					changed = true
				end
			end
		else
			-- Rarest-first: try each due tier until one actually places a bush.
			local spawnedId: string? = nil
			for i = #dueTiers, 1, -1 do
				local tier = dueTiers[i]
				if trySpawnTier(state, tier.id, false) then
					state.timers[tier.id] = now + tier.intervalSec
					changed = true
					spawnedId = tier.id
					local retryAt = (state.active and state.active.endsAt or now) + 1
					for j = 1, #dueTiers do
						if dueTiers[j].id ~= tier.id then
							state.timers[dueTiers[j].id] = retryAt
							changed = true
						end
					end
					break
				end
			end
			if spawnedId then
				spawnTier = spawnedId
			else
				-- Bush/pool not ready — retry soon instead of leaving timers stuck at 0.
				local retryAt = now + 5
				for _, tier in dueTiers do
					state.timers[tier.id] = retryAt
					changed = true
				end
			end
		end
	end

	if changed then
		return true, spawnTier
	end
	return false, nil
end

local function processTick()
	if tickInFlight then
		return
	end
	tickInFlight = true

	local function finish()
		tickInFlight = false
	end

	if #cachedSpawnCandidates == 0 then
		refreshSpawnBushCache()
	end

	local state = {
		version = 1,
		timers = table.clone(currentState.timers),
		active = currentState.active,
	}
	local changed, spawnTier = advanceState(state)
	if changed then
		broadcastState(state, if spawnTier then "spawn" else "sync", spawnTier)
	end
	finish()
end

function M.start()
	ensureRemotes()

	task.spawn(function()
		local deadline = os.clock() + 30
		while os.clock() < deadline do
			refreshSpawnBushCache()
			if #cachedSpawnCandidates > 0 then
				break
			end
			task.wait(2)
		end
	end)

	currentState = normalizeState(nil)
	broadcastState(currentState, "sync", nil)

	pcall(function()
		MessagingService:SubscribeAsync(C.SPAWN_CMD_TOPIC, function(packet)
			if typeof(packet) ~= "table" or typeof(packet.Data) ~= "table" then
				return
			end
			local tierId = packet.Data.tierId
			if typeof(tierId) ~= "string" then
				return
			end
			local ok, err = M.forceSpawn(tierId)
			if not ok then
				warn("[GlobalRaritySpawnService] global spawn invoke failed:", err)
			end
		end)
		messagingReady = true
	end)

	Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			if not updatedRE then
				return
			end
			local active = currentState.active
			updatedRE:FireClient(
				player,
				"sync",
				nil,
				active and active.rarity or nil,
				active and active.brainrotName or nil
			)
		end)
	end)

	task.spawn(function()
		local sinceCacheRefresh = 0
		while true do
			task.wait(1)
			sinceCacheRefresh += 1
			if sinceCacheRefresh >= SPAWN_CACHE_TTL then
				sinceCacheRefresh = 0
				refreshSpawnBushCache()
			end
			processTick()
		end
	end)
end

return M
