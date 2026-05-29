--[[
	Brief shiver on bushes assigned a hidden brainrot (70% outcome, decided before search).
	Server fires BushBrainrotShiver; this module also watches HasHiddenBrainrot as fallback.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local M = {}

local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local SHIVER_REMOTE_NAME = "BushBrainrotShiver"

local SHIVER_DURATION = 2
local SHIVER_FREQ = 9
local SHIVER_POS_AMP = 0.14
local SHIVER_ROT_AMP = math.rad(3.2)

local activeByBush: { [Instance]: boolean } = {}
local hookedByBush: { [Instance]: boolean } = {}

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

local function tryShiverFromAttribute(bush: Instance)
	if bush.Parent and bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		M.shiverBush(bush)
	end
end

function M.trackBush(bush: Instance)
	if hookedByBush[bush] then
		return
	end
	hookedByBush[bush] = true

	if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		task.defer(tryShiverFromAttribute, bush)
	end

	bush:GetAttributeChangedSignal(HAS_BRAINROT_ATTR):Connect(function()
		if bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
			M.shiverBush(bush)
		end
	end)

	bush.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			activeByBush[bush] = nil
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

local function resolveBushFromPath(bush: Instance?, path: string?): Instance?
	if typeof(bush) == "Instance" and bush.Parent then
		return bush
	end
	if typeof(path) ~= "string" or path == "" then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local suffix = string.match(path, "^Workspace%.Map%.(.+)$") or string.match(path, "^Map%.(.+)$")
	if not suffix then
		return nil
	end
	local node: Instance = map
	for segment in string.split(suffix, ".") do
		if segment == "" then
			continue
		end
		local child = node:FindFirstChild(segment)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function connectShiverRemote()
	local folder = ReplicatedStorage:WaitForChild("BushRemotes", 120)
	if not folder then
		return
	end
	local ev = folder:WaitForChild(SHIVER_REMOTE_NAME, 60)
	if not ev or not ev:IsA("RemoteEvent") then
		return
	end
	ev.OnClientEvent:Connect(function(bush: Instance?, path: string?)
		local resolved = resolveBushFromPath(bush, path)
		if resolved then
			M.trackBush(resolved)
			M.shiverBush(resolved)
		end
	end)
end

task.spawn(connectShiverRemote)

return M
