-- [ACTIVE] BushShiver
--[[
	Soft nervous shiver bursts for bushes with HasHiddenBrainrot == true (server 50/50 pre-roll).
	Each bush runs its own randomized schedule so bushes never sync up.
]]

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

local baseTransformByBush: { [Instance]: CFrame } = {}
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

local function captureBaseTransform(bush: Instance): CFrame?
	if bush:IsA("Model") then
		return bush:GetPivot()
	end
	if bush:IsA("BasePart") then
		return bush.CFrame
	end
	return nil
end

local function applyTransform(bush: Instance, cf: CFrame)
	if bush:IsA("Model") then
		bush:PivotTo(cf)
	elseif bush:IsA("BasePart") then
		bush.CFrame = cf
	end
end

local function restoreBushTransform(bush: Instance)
	local base = baseTransformByBush[bush]
	if base and bush.Parent then
		applyTransform(bush, base)
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
		restoreBushTransform(bush)
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
	local base = baseTransformByBush[bush]
	if not base then
		return
	end

	local start = os.clock()
	local endAt = start + burstSec
	GameSoundEffects.playBushRandomShakeAt(bush)
	while bush.Parent and token == schedulerTokenByBush[bush] and shouldShiverBush(bush) and os.clock() < endAt do
		local elapsed = os.clock() - start
		applyTransform(bush, base * softShiverOffset(elapsed, burstSec))
		task.wait(SHIVER_TICK_SEC)
	end

	if token == schedulerTokenByBush[bush] and bush.Parent then
		restoreBushTransform(bush)
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
				restoreBushTransform(bush)
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

			local base = captureBaseTransform(bush)
			if not base then
				break
			end
			baseTransformByBush[bush] = base

			runSoftBurst(bush, token, randomBurstSec())
		end

		if token == schedulerTokenByBush[bush] then
			loopRunningByBush[bush] = nil
			restoreBushTransform(bush)
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
		if desc.Name == "BushSCRIPT" and (desc:IsA("Model") or desc:IsA("BasePart")) then
			M.trackBush(desc)
		end
	end
end

function M.init()
	-- Reserved for BushHoldInteraction boot; scan runs when Map is ready.
end

return M
