--[[
	Brief shiver on bushes that were assigned a hidden brainrot (70% outcome).
	Runs once per assignment (~2s), then restores original CFrames.
]]

local RunService = game:GetService("RunService")

local M = {}

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"

local SHIVER_DURATION = 2
local SHIVER_FREQ = 8.5
local SHIVER_POS_AMP = 0.07
local SHIVER_ROT_AMP = math.rad(1.8)

local activeByBush: { [Instance]: boolean } = {}
local hookedByBush: { [Instance]: boolean } = {}

local function collectShiverParts(bush: Instance): { { part: BasePart, base: CFrame } }
	local out: { { part: BasePart, base: CFrame } } = {}
	if bush:IsA("BasePart") then
		table.insert(out, { part = bush, base = bush.CFrame })
		return out
	end
	if bush:IsA("Model") then
		for _, desc in bush:GetDescendants() do
			if desc:IsA("BasePart") and desc.Anchored then
				table.insert(out, { part = desc, base = desc.CFrame })
			end
		end
		if #out == 0 then
			local m = bush :: Model
			local p = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
			if p then
				table.insert(out, { part = p, base = p.CFrame })
			end
		end
	end
	return out
end

function M.shiverBush(bush: Instance)
	if not bush.Parent or activeByBush[bush] then
		return
	end
	local parts = collectShiverParts(bush)
	if #parts == 0 then
		return
	end

	activeByBush[bush] = true
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
			for _, entry in parts do
				if entry.part.Parent then
					entry.part.CFrame = entry.base
				end
			end
			conn:Disconnect()
			activeByBush[bush] = nil
			return
		end

		local fade = 1 - (elapsed / SHIVER_DURATION)
		local wobble = math.sin(elapsed * SHIVER_FREQ) * SHIVER_POS_AMP * fade
		local wobbleZ = math.sin(elapsed * SHIVER_FREQ * 1.17 + 0.6) * SHIVER_POS_AMP * 0.35 * fade
		local tilt = math.sin(elapsed * SHIVER_FREQ * 0.93 + 1.1) * SHIVER_ROT_AMP * fade

		for _, entry in parts do
			if entry.part.Parent then
				entry.part.CFrame = entry.base
					* CFrame.new(wobble, 0, wobbleZ)
					* CFrame.Angles(0, tilt, tilt * 0.45)
			end
		end
	end)
end

local function onHasBrainrotChanged(bush: Instance)
	if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		M.shiverBush(bush)
	end
end

function M.trackBush(bush: Instance)
	if hookedByBush[bush] then
		return
	end
	hookedByBush[bush] = true

	if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		-- Stagger so hundreds of bushes do not shiver on the same frame at map load.
		task.delay(math.random() * 1.25, function()
			if bush.Parent and bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
				M.shiverBush(bush)
			end
		end)
	end

	bush:GetAttributeChangedSignal(HAS_BRAINROT_ATTR):Connect(function()
		onHasBrainrotChanged(bush)
	end)

	bush.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			activeByBush[bush] = nil
			hookedByBush[bush] = nil
		end
	end)
end

return M
