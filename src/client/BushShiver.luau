--[[
	Shiver clue for bushes marked HasHiddenBrainrot (cosmetic hint from server pre-roll).
	Uses replicated attributes only — no remote flood. Each bush shivers once at a random time (~2s).
]]

local RunService = game:GetService("RunService")

local M = {}

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"

local SHIVER_DURATION = 2
local SHIVER_FREQ = 9
local SHIVER_POS_AMP = 0.14
local SHIVER_ROT_AMP = math.rad(3.2)
local SHIVER_START_DELAY_MAX = 14

local activeByBush: { [Instance]: boolean } = {}
local hookedByBush: { [Instance]: boolean } = {}
local shiverScheduled: { [Instance]: boolean } = {}

local function shiverModelPivot(bush: Model)
	local basePivot = bush:GetPivot()
	local start = os.clock()

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not bush.Parent then
			conn:Disconnect()
			activeByBush[bush] = nil
			return
		end

		local elapsed = os.clock() - start
		if elapsed >= SHIVER_DURATION then
			bush:PivotTo(basePivot)
			conn:Disconnect()
			activeByBush[bush] = nil
			return
		end

		local fade = 1 - (elapsed / SHIVER_DURATION)
		local wobble = math.sin(elapsed * SHIVER_FREQ) * SHIVER_POS_AMP * fade
		local wobbleZ = math.sin(elapsed * SHIVER_FREQ * 1.2 + 0.5) * SHIVER_POS_AMP * 0.4 * fade
		local tiltY = math.sin(elapsed * SHIVER_FREQ * 0.95 + 1.2) * SHIVER_ROT_AMP * fade
		local tiltZ = math.sin(elapsed * SHIVER_FREQ * 1.08) * SHIVER_ROT_AMP * 0.5 * fade

		bush:PivotTo(basePivot * CFrame.new(wobble, 0, wobbleZ) * CFrame.Angles(0, tiltY, tiltZ))
	end)
end

local function shiverSinglePart(part: BasePart)
	local baseCf = part.CFrame
	local start = os.clock()

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not part.Parent then
			conn:Disconnect()
			activeByBush[part] = nil
			return
		end

		local elapsed = os.clock() - start
		if elapsed >= SHIVER_DURATION then
			part.CFrame = baseCf
			conn:Disconnect()
			activeByBush[part] = nil
			return
		end

		local fade = 1 - (elapsed / SHIVER_DURATION)
		local wobble = math.sin(elapsed * SHIVER_FREQ) * SHIVER_POS_AMP * fade
		local wobbleZ = math.sin(elapsed * SHIVER_FREQ * 1.2 + 0.5) * SHIVER_POS_AMP * 0.4 * fade
		local tilt = math.sin(elapsed * SHIVER_FREQ * 0.95 + 1.2) * SHIVER_ROT_AMP * fade

		part.CFrame = baseCf * CFrame.new(wobble, 0, wobbleZ) * CFrame.Angles(0, tilt, tilt * 0.45)
	end)
end

function M.shiverBush(bush: Instance)
	if not bush or not bush.Parent or activeByBush[bush] then
		return
	end

	activeByBush[bush] = true

	if bush:IsA("Model") then
		shiverModelPivot(bush :: Model)
		return
	end

	if bush:IsA("BasePart") then
		shiverSinglePart(bush :: BasePart)
		return
	end

	activeByBush[bush] = nil
end

local function scheduleRandomShiver(bush: Instance)
	if shiverScheduled[bush] or activeByBush[bush] then
		return
	end
	shiverScheduled[bush] = true

	local delaySec = math.random() * SHIVER_START_DELAY_MAX
	task.delay(delaySec, function()
		shiverScheduled[bush] = nil
		if bush.Parent and bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
			M.shiverBush(bush)
		end
	end)
end

function M.trackBush(bush: Instance)
	if hookedByBush[bush] then
		return
	end
	hookedByBush[bush] = true

	if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		scheduleRandomShiver(bush)
	end

	bush:GetAttributeChangedSignal(HAS_BRAINROT_ATTR):Connect(function()
		if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
			scheduleRandomShiver(bush)
		end
	end)

	bush.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			activeByBush[bush] = nil
			hookedByBush[bush] = nil
			shiverScheduled[bush] = nil
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
