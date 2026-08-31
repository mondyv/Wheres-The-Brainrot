-- [ACTIVE] BushShiver
--[[
	Soft nervous shiver bursts for bushes with HasHiddenBrainrot == true (server 50/50 pre-roll).
	Each bush runs its own randomized schedule so bushes never sync up.
	Grouped bushes shake every child Model in the cluster together.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local M = {}

-- Ambient shiver + rustle for nearby bushes that have a hidden brainrot.
local FEATURE_ENABLED = true

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local ON_COOLDOWN_ATTR = "BushOnCooldown"
local LOOT_PHASE_ATTR = "BushLootPhase"
local LOOT_PHASE_COOLDOWN = "cooldown"

local SHIVER_BURST_MIN_SEC = 1.1
local SHIVER_BURST_MAX_SEC = 1.5
local SHIVER_IDLE_MIN_SEC = 2
local SHIVER_IDLE_MAX_SEC = 4.5
local SHIVER_START_DELAY_MAX_SEC = 2
local SHIVER_ACTIVE_RANGE = 52
local MAX_SIMULTANEOUS_SHIVERS = 2
local GLOBAL_SHIVER_GAP_SEC = 1.15
local PER_BUSH_SHIVER_GAP_SEC = 4.2
local HINT_BLOCKED_WAIT_SEC = 0.6
local GAP_RETRY_WAIT_SEC = 0.2
local SHIVER_SMOOTH_SPEED = 16
local COMPANION_SHIVER_CHANCE = 0.28
local COMPANION_SHIVER_MAX = 1
local runSoftBurst: (Instance, number, number, number) -> ()

local SHIVER_POS_AMP = 0.052
local SHIVER_ROT_AMP = math.rad(1.45)
local SHIVER_SWAY_HZ = 4.2

type ShakeBases = { [Instance]: CFrame }

local baseTransformByBush: { [Instance]: ShakeBases } = {}
local hookedByBush: { [Instance]: boolean } = {}
local schedulerTokenByBush: { [Instance]: number } = {}
local loopRunningByBush: { [Instance]: boolean } = {}
local lastShiverAtByBush: { [Instance]: number } = {}
local activeShiverBursts = 0
local lastGlobalShiverAt = 0
local localPlayer = Players.LocalPlayer
local cachedPlayerLand = 1
local cachedPlayerLandAt = 0
local PLAYER_LAND_REFRESH_SEC = 0.45
local bushLandByBush: { [Instance]: number } = {}

local function shouldShiverBush(bush: Instance): boolean
	if bush:GetAttribute(LOOT_PHASE_ATTR) == LOOT_PHASE_COOLDOWN then
		return false
	end
	if bush:GetAttribute(ON_COOLDOWN_ATTR) == true then
		return false
	end
	return bush:GetAttribute(HAS_BRAINROT_ATTR) == true
end

local function canPlayAmbientShiverHints(): boolean
	if ProximityPromptEffects.isBushSearchActive() then
		return false
	end
	local char = localPlayer.Character
	if not char then
		return false
	end
	return not SafezoneUtil.isCharacterInSafezone(char)
end

local function captureBaseTransforms(bush: Instance): ShakeBases?
	local bases: ShakeBases = {}
	for _, target in BushRootUtil.getShakeTargets(bush) do
		if target:IsA("Model") then
			bases[target] = target:GetPivot()
		elseif target:IsA("BasePart") then
			bases[target] = target.CFrame
		end
	end
	if next(bases) == nil then
		return nil
	end
	return bases
end

local function applyTransform(target: Instance, cf: CFrame)
	if target:IsA("Model") then
		target:PivotTo(cf)
	elseif target:IsA("BasePart") then
		target.CFrame = cf
	end
end

local function restoreBushTransforms(bush: Instance)
	local bases = baseTransformByBush[bush]
	if not bases then
		return
	end
	for target, base in bases do
		if target.Parent then
			applyTransform(target, base)
		end
	end
end

local function applyShiverOffset(bush: Instance, offset: CFrame)
	local bases = baseTransformByBush[bush]
	if not bases then
		return
	end
	for target, base in bases do
		if target.Parent then
			applyTransform(target, base * offset)
		end
	end
end

local function bushApproxPosition(bush: Instance): Vector3?
	if bush:IsA("BasePart") then
		return (bush :: BasePart).Position
	end
	if bush:IsA("Model") then
		local ok, pivot = pcall(function()
			return (bush :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return (pivot :: CFrame).Position
		end
	end
	local part = bush:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function getPlayerLand(): number
	local now = os.clock()
	if now - cachedPlayerLandAt < PLAYER_LAND_REFRESH_SEC then
		return cachedPlayerLand
	end
	cachedPlayerLandAt = now

	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		cachedPlayerLand = 1
		return cachedPlayerLand
	end
	cachedPlayerLand = LandResolver.resolveLandAtPosition((hrp :: BasePart).Position)
	return cachedPlayerLand
end

local function resolveBushLand(bush: Instance): number?
	local cached = bushLandByBush[bush]
	if cached then
		return cached
	end
	local pos = bushApproxPosition(bush)
	if not pos then
		return nil
	end
	local land = LandResolver.resolveLandAtPosition(pos)
	bushLandByBush[bush] = land
	return land
end

local function isBushInPlayerLand(bush: Instance): boolean
	local bushLand = resolveBushLand(bush)
	if not bushLand then
		return false
	end
	return bushLand == getPlayerLand()
end

local function isBushNearPlayer(bush: Instance): boolean
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	local pos = bushApproxPosition(bush)
	if not pos then
		return false
	end
	if not isBushInPlayerLand(bush) then
		return false
	end
	return (pos - (hrp :: BasePart).Position).Magnitude <= SHIVER_ACTIVE_RANGE
end

local function softShiverOffset(elapsed: number, burstSec: number, seed: number): CFrame
	local t = math.clamp(elapsed / burstSec, 0, 1)
	local envelope = math.sin(t * math.pi)
	local attack = math.clamp(t / 0.2, 0, 1)
	envelope *= attack

	local hz = SHIVER_SWAY_HZ + (seed % 5) * 0.22
	local phase = seed * 0.17
	local swayA = math.sin(elapsed * hz * math.pi * 2 + phase)
	local swayB = math.sin(elapsed * hz * math.pi * 2 * 0.86 + phase * 1.4)

	local ox = swayA * SHIVER_POS_AMP * envelope
	local oz = swayB * SHIVER_POS_AMP * 0.62 * envelope
	local ty = swayA * SHIVER_ROT_AMP * 0.55 * envelope
	local tz = swayB * SHIVER_ROT_AMP * 0.38 * envelope

	return CFrame.new(ox, 0, oz) * CFrame.Angles(0, ty, tz)
end

local function stopShiverLoop(bush: Instance)
	schedulerTokenByBush[bush] = (schedulerTokenByBush[bush] or 0) + 1
	loopRunningByBush[bush] = nil
	if bush.Parent then
		restoreBushTransforms(bush)
	end
	baseTransformByBush[bush] = nil
end

local function randomIdleSec(): number
	return SHIVER_IDLE_MIN_SEC + math.random() * (SHIVER_IDLE_MAX_SEC - SHIVER_IDLE_MIN_SEC)
end

local function randomBurstSec(): number
	return SHIVER_BURST_MIN_SEC + math.random() * (SHIVER_BURST_MAX_SEC - SHIVER_BURST_MIN_SEC)
end

local function canStartShiverNow(bush: Instance): boolean
	if not canPlayAmbientShiverHints() then
		return false
	end
	if not isBushNearPlayer(bush) then
		return false
	end
	if activeShiverBursts >= MAX_SIMULTANEOUS_SHIVERS then
		return false
	end
	local now = os.clock()
	if now - lastGlobalShiverAt < GLOBAL_SHIVER_GAP_SEC then
		return false
	end
	if now - (lastShiverAtByBush[bush] or 0) < PER_BUSH_SHIVER_GAP_SEC then
		return false
	end
	return true
end

local function tryCompanionShivers(sourceBush: Instance, token: number, seed: number)
	if math.random() > COMPANION_SHIVER_CHANCE then
		return
	end

	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local candidates: { Instance } = {}
	for bush, loopRunning in loopRunningByBush do
		if bush == sourceBush or not loopRunning or not shouldShiverBush(bush) then
			continue
		end
		if not isBushNearPlayer(bush) then
			continue
		end
		table.insert(candidates, bush)
	end
	if #candidates == 0 then
		return
	end

	for _ = 1, math.min(COMPANION_SHIVER_MAX, #candidates) do
		if activeShiverBursts >= MAX_SIMULTANEOUS_SHIVERS then
			break
		end
		local pick = candidates[math.random(1, #candidates)]
		for i, bush in candidates do
			if bush == pick then
				table.remove(candidates, i)
				break
			end
		end
		local bushToken = schedulerTokenByBush[pick]
		if not bushToken or not loopRunningByBush[pick] then
			continue
		end
		task.defer(function()
			if not canStartShiverNow(pick) then
				return
			end
			local bases = captureBaseTransforms(pick)
			if not bases then
				return
			end
			baseTransformByBush[pick] = bases
			runSoftBurst(pick, bushToken, randomBurstSec(), seed + math.random(1, 500))
		end)
	end
end

runSoftBurst = function(bush: Instance, token: number, burstSec: number, seed: number)
	local bases = baseTransformByBush[bush]
	if not bases then
		return
	end
	if not canStartShiverNow(bush) then
		return
	end

	local now = os.clock()
	lastGlobalShiverAt = now
	lastShiverAtByBush[bush] = now
	tryCompanionShivers(bush, token, seed)

	activeShiverBursts += 1
	local start = os.clock()
	local endAt = start + burstSec
	local displayOffset = CFrame.new()
	GameSoundEffects.playBushRandomShakeAt(bush)

	local burstConn: RBXScriptConnection? = nil
	burstConn = RunService.Heartbeat:Connect(function(dt)
		if not bush.Parent or token ~= schedulerTokenByBush[bush] or not shouldShiverBush(bush) then
			if burstConn then
				burstConn:Disconnect()
			end
			return
		end
		if not isBushNearPlayer(bush) or ProximityPromptEffects.isBushSearchActive() then
			if burstConn then
				burstConn:Disconnect()
			end
			return
		end

		local elapsed = os.clock() - start
		if elapsed >= burstSec then
			if burstConn then
				burstConn:Disconnect()
			end
			return
		end

		local targetOffset = softShiverOffset(elapsed, burstSec, seed)
		local alpha = math.clamp(dt * SHIVER_SMOOTH_SPEED, 0, 1)
		displayOffset = displayOffset:Lerp(targetOffset, alpha)
		applyShiverOffset(bush, displayOffset)
	end)

	while bush.Parent and token == schedulerTokenByBush[bush] and shouldShiverBush(bush) and os.clock() < endAt do
		if not isBushNearPlayer(bush) or ProximityPromptEffects.isBushSearchActive() then
			break
		end
		task.wait(0.05)
	end

	if burstConn then
		burstConn:Disconnect()
	end
	activeShiverBursts = math.max(0, activeShiverBursts - 1)

	if token == schedulerTokenByBush[bush] and bush.Parent then
		restoreBushTransforms(bush)
	end
end

local function startShiverScheduler(bush: Instance)
	if loopRunningByBush[bush] then
		return
	end

	local token = (schedulerTokenByBush[bush] or 0) + 1
	schedulerTokenByBush[bush] = token
	loopRunningByBush[bush] = true
	local shakeSeed = math.random(1, 9999)

	task.spawn(function()
		local firstCycle = true

		while bush.Parent and token == schedulerTokenByBush[bush] do
			if not shouldShiverBush(bush) then
				restoreBushTransforms(bush)
				break
			end

			if not canPlayAmbientShiverHints() then
				task.wait(HINT_BLOCKED_WAIT_SEC)
				continue
			end

			if firstCycle then
				firstCycle = false
				task.wait(math.random() * SHIVER_START_DELAY_MAX_SEC)
			else
				task.wait(randomIdleSec())
			end

			if token ~= schedulerTokenByBush[bush] or not bush.Parent or not shouldShiverBush(bush) then
				break
			end
			if not canStartShiverNow(bush) then
				task.wait(GAP_RETRY_WAIT_SEC)
				continue
			end

			local bases = captureBaseTransforms(bush)
			if not bases then
				break
			end
			baseTransformByBush[bush] = bases

			runSoftBurst(bush, token, randomBurstSec(), shakeSeed)
		end

		if token == schedulerTokenByBush[bush] then
			loopRunningByBush[bush] = nil
			restoreBushTransforms(bush)
			baseTransformByBush[bush] = nil
		end
	end)
end

local function refreshShiverState(bush: Instance)
	if shouldShiverBush(bush) then
		stopShiverLoop(bush)
		startShiverScheduler(bush)
	else
		stopShiverLoop(bush)
		lastShiverAtByBush[bush] = nil
	end
end

function M.isAnimating(bush: Instance): boolean
	return baseTransformByBush[bush] ~= nil
end

function M.trackBush(bush: Instance)
	if not FEATURE_ENABLED then
		return
	end
	if not BushRootUtil.isDirectBushRoot(bush) then
		return
	end
	if hookedByBush[bush] then
		refreshShiverState(bush)
		return
	end
	hookedByBush[bush] = true

	refreshShiverState(bush)

	bush:GetAttributeChangedSignal(HAS_BRAINROT_ATTR):Connect(function()
		refreshShiverState(bush)
	end)
	bush:GetAttributeChangedSignal(ON_COOLDOWN_ATTR):Connect(function()
		refreshShiverState(bush)
	end)
	bush:GetAttributeChangedSignal(LOOT_PHASE_ATTR):Connect(function()
		refreshShiverState(bush)
	end)

	bush.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stopShiverLoop(bush)
			hookedByBush[bush] = nil
			lastShiverAtByBush[bush] = nil
			bushLandByBush[bush] = nil
		end
	end)
end

function M.scanMapForBrainrotBushes(map: Instance)
	if not FEATURE_ENABLED then
		return
	end
	local stack = { map }
	local count = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst:IsA("Folder") and BushRootUtil.isBushFolderName(inst.Name) then
			for _, child in inst:GetChildren() do
				if BushRootUtil.isDirectBushRoot(child) then
					M.trackBush(child)
				end
			end
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		count += 1
		if count % 400 == 0 then
			task.wait(0.1)
		end
	end
end

function M.init()
	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 90)
		if map then
			M.scanMapForBrainrotBushes(map)
			map.DescendantAdded:Connect(function(child)
				if BushRootUtil.isDirectBushRoot(child) then
					M.trackBush(child)
				end
			end)
		end
	end)
end

return M
