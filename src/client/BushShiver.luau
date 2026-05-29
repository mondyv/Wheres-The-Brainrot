--[[
	Looping rocky shiver for bushes with HasHiddenBrainrot == true (server pre-roll).
	Stops while BushOnCooldown is true or HasHiddenBrainrot is false.
]]

local RunService = game:GetService("RunService")

local M = {}

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local ON_COOLDOWN_ATTR = "BushOnCooldown"

local SHIVER_CYCLE_SEC = 2.4
local SHIVER_PAUSE_SEC = 0.35
local SHIVER_FREQ = 22
local SHIVER_POS_AMP = 0.2
local SHIVER_ROT_AMP = math.rad(5.2)

local loopConnByBush: { [Instance]: RBXScriptConnection } = {}
local baseTransformByBush: { [Instance]: CFrame } = {}
local hookedByBush: { [Instance]: boolean } = {}

local function shouldShiverBush(bush: Instance): boolean
	if bush:GetAttribute(ON_COOLDOWN_ATTR) == true then
		return false
	end
	return bush:GetAttribute(HAS_BRAINROT_ATTR) == true
end

local function restoreBushTransform(bush: Instance)
	local base = baseTransformByBush[bush]
	if not base then
		return
	end
	if bush:IsA("Model") then
		bush:PivotTo(base)
	elseif bush:IsA("BasePart") then
		bush.CFrame = base
	end
end

local function stopShiverLoop(bush: Instance)
	local conn = loopConnByBush[bush]
	if conn then
		conn:Disconnect()
		loopConnByBush[bush] = nil
	end
	if bush.Parent then
		restoreBushTransform(bush)
	end
	baseTransformByBush[bush] = nil
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

local function applyShiverOffset(bush: Instance, base: CFrame, phase: number, envelope: number)
	local wobbleX = math.sin(phase * SHIVER_FREQ) * SHIVER_POS_AMP * envelope
	local wobbleZ = math.sin(phase * SHIVER_FREQ * 1.17 + 0.6) * SHIVER_POS_AMP * 0.55 * envelope
	local tiltY = math.sin(phase * SHIVER_FREQ * 0.93 + 1.1) * SHIVER_ROT_AMP * envelope
	local tiltZ = math.sin(phase * SHIVER_FREQ * 1.08 + 0.3) * SHIVER_ROT_AMP * 0.62 * envelope
	local tiltX = math.sin(phase * SHIVER_FREQ * 1.25) * SHIVER_ROT_AMP * 0.35 * envelope
	local offset = CFrame.new(wobbleX, 0, wobbleZ) * CFrame.Angles(tiltX, tiltY, tiltZ)

	if bush:IsA("Model") then
		bush:PivotTo(base * offset)
	elseif bush:IsA("BasePart") then
		bush.CFrame = base * offset
	end
end

local function startShiverLoop(bush: Instance)
	if loopConnByBush[bush] or not shouldShiverBush(bush) then
		return
	end

	local base = captureBaseTransform(bush)
	if not base then
		return
	end

	baseTransformByBush[bush] = base
	local cycleStart = os.clock()

	loopConnByBush[bush] = RunService.Heartbeat:Connect(function()
		if not bush.Parent or not shouldShiverBush(bush) then
			stopShiverLoop(bush)
			return
		end

		local baseCf = baseTransformByBush[bush]
		if not baseCf then
			stopShiverLoop(bush)
			return
		end

		local elapsed = os.clock() - cycleStart
		local loopLen = SHIVER_CYCLE_SEC + SHIVER_PAUSE_SEC
		local phaseInLoop = elapsed % loopLen

		if phaseInLoop >= SHIVER_CYCLE_SEC then
			restoreBushTransform(bush)
			return
		end

		local envelope = math.sin((phaseInLoop / SHIVER_CYCLE_SEC) * math.pi)
		applyShiverOffset(bush, baseCf, phaseInLoop, envelope)
	end)
end

local function refreshShiverState(bush: Instance)
	if shouldShiverBush(bush) then
		if not loopConnByBush[bush] then
			startShiverLoop(bush)
		end
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
