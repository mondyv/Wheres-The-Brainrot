-- [ACTIVE] BushShiver
--[[
	Soft nervous shiver bursts for bushes with HasHiddenBrainrot == true (server 50/50 pre-roll).
	Each bush runs its own randomized schedule so bushes never sync up.
	Grouped bushes shake every child Model in the cluster together.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local M = {}

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local ON_COOLDOWN_ATTR = "BushOnCooldown"
local LOOT_PHASE_ATTR = "BushLootPhase"
local LOOT_PHASE_COOLDOWN = "cooldown"

local SHIVER_BURST_MIN_SEC = 1.5
local SHIVER_BURST_MAX_SEC = 2
local SHIVER_IDLE_MIN_SEC = 7
local SHIVER_IDLE_MAX_SEC = 15
local SHIVER_START_DELAY_MAX_SEC = 12
local SHIVER_TICK_SEC = 1 / 30

local SHIVER_POS_AMP = 0.045
local SHIVER_ROT_AMP = math.rad(1.6)
local SHIVER_FREQ = 12

type ShakeBases = { [Instance]: CFrame }

local baseTransformByBush: { [Instance]: ShakeBases } = {}
local hookedByBush: { [Instance]: boolean } = {}
local schedulerTokenByBush: { [Instance]: number } = {}
local loopRunningByBush: { [Instance]: boolean } = {}

local function shouldShiverBush(bush: Instance): boolean
	if bush:GetAttribute(LOOT_PHASE_ATTR) == LOOT_PHASE_COOLDOWN then
		return false
	end
	if bush:GetAttribute(ON_COOLDOWN_ATTR) == true then
		return false
	end
	return bush:GetAttribute(HAS_BRAINROT_ATTR) == true
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

local function softShiverOffset(elapsed: number, burstSec: number): CFrame
	local envelope = math.sin(math.clamp(elapsed / burstSec, 0, 1) * math.pi)
	local ox = math.sin(elapsed * SHIVER_FREQ) * SHIVER_POS_AMP * envelope
	local oz = math.sin(elapsed * SHIVER_FREQ * 1.11 + 0.7) * SHIVER_POS_AMP * 0.52 * envelope
	local ty = math.sin(elapsed * SHIVER_FREQ * 0.94 + 1.1) * SHIVER_ROT_AMP * envelope
	local tz = math.sin(elapsed * SHIVER_FREQ * 1.06 + 0.35) * SHIVER_ROT_AMP * 0.58 * envelope
	local tx = math.sin(elapsed * SHIVER_FREQ * 1.19) * SHIVER_ROT_AMP * 0.32 * envelope
	return CFrame.new(ox, 0, oz) * CFrame.Angles(tx, ty, tz)
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

local function runSoftBurst(bush: Instance, token: number, burstSec: number)
	local bases = baseTransformByBush[bush]
	if not bases then
		return
	end

	local start = os.clock()
	local endAt = start + burstSec
	GameSoundEffects.playBushRandomShakeAt(bush)
	while bush.Parent and token == schedulerTokenByBush[bush] and shouldShiverBush(bush) and os.clock() < endAt do
		local elapsed = os.clock() - start
		applyShiverOffset(bush, softShiverOffset(elapsed, burstSec))
		task.wait(SHIVER_TICK_SEC)
	end

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

	task.spawn(function()
		local firstCycle = true

		while bush.Parent and token == schedulerTokenByBush[bush] do
			if not shouldShiverBush(bush) then
				restoreBushTransforms(bush)
				break
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

			local bases = captureBaseTransforms(bush)
			if not bases then
				break
			end
			baseTransformByBush[bush] = bases

			runSoftBurst(bush, token, randomBurstSec())
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
	end
end

function M.trackBush(bush: Instance)
	if not BushRootUtil.isDirectBushRoot(bush) then
		return
	end
	if hookedByBush[bush] then
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
		end
	end)
end

function M.scanMapForBrainrotBushes(map: Instance)
	for _, desc in map:GetDescendants() do
		if desc:IsA("Folder") and BushRootUtil.isBushFolderName(desc.Name) then
			for _, child in desc:GetChildren() do
				if BushRootUtil.isDirectBushRoot(child) then
					M.trackBush(child)
				end
			end
		end
	end
end

function M.init()
	-- Reserved for BushHoldInteraction boot; scan runs when Map is ready.
end

return M
