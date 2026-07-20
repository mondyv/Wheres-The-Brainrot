-- [ACTIVE] VegetationSwayController
--[[
	Local-only Pokémon-style bend when walking through grassparts and bushes.
	Uses spatial overlap (grass CanCollide is off). Hard-caps simultaneous sways.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local BushShiver = require(script.Parent.BushShiver)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local M = {}

local MAX_ACTIVE = 10
local SCAN_INTERVAL_SEC = 0.04
local MOVE_DIR_MIN = 0.12
local OVERLAP_SIZE = Vector3.new(5.5, 6.5, 5.5)
local GRASS_TILT_RAD = math.rad(26)
local BUSH_TILT_RAD = math.rad(18)
local GRASS_PUSH = 0.22
local BUSH_PUSH = 0.38
local SWAY_DURATION_SEC = 0.62
local COOLDOWN_SEC = 0.22
local STEP_NAME = "VegetationSwayStep"

type SwayKind = "grass" | "bush"

type TargetBase = {
	target: Instance,
	base: CFrame,
	halfY: number,
}

type ActiveSway = {
	kind: SwayKind,
	pieces: { TargetBase },
	axis: Vector3,
	amp: number,
	push: number,
	pushDir: Vector3,
	startedAt: number,
	duration: number,
}

local localPlayer = Players.LocalPlayer
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 72

local landsFolder: Instance? = nil
local active: { [Instance]: ActiveSway } = {}
local activeCount = 0
local cooldownUntil: { [Instance]: number } = {}
local stepBound = false
local scanAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}

local function disconnectCharConns()
	for _, conn in charConns do
		conn:Disconnect()
	end
	table.clear(charConns)
end

local function applyTargetCFrame(target: Instance, cf: CFrame)
	if target:IsA("Model") then
		(target :: Model):PivotTo(cf)
	elseif target:IsA("BasePart") then
		(target :: BasePart).CFrame = cf
	end
end

local function getTargetPivot(target: Instance): CFrame?
	if target:IsA("Model") then
		local ok, pivot = pcall(function()
			return (target :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot
		end
		return nil
	end
	if target:IsA("BasePart") then
		return (target :: BasePart).CFrame
	end
	return nil
end

local function approxHalfY(target: Instance): number
	if target:IsA("BasePart") then
		return math.max((target :: BasePart).Size.Y * 0.5, 0.35)
	end
	if target:IsA("Model") then
		local ok, size = pcall(function()
			return (target :: Model):GetExtentsSize()
		end)
		if ok and typeof(size) == "Vector3" then
			return math.clamp((size :: Vector3).Y * 0.5, 0.5, 4)
		end
	end
	return 1.2
end

-- Fast punch to peak, hold readable bend, then recover.
local function swayEnvelope(t: number): number
	if t <= 0 then
		return 0
	end
	if t >= 1 then
		return 0
	end
	if t < 0.14 then
		local u = t / 0.14
		return u * u
	end
	if t < 0.42 then
		return 1
	end
	local u = (t - 0.42) / 0.58
	return (1 - u) * (1 - u)
end

local function bendOffset(halfY: number, axis: Vector3, angle: number, push: number, pushDir: Vector3): CFrame
	if angle == 0 or axis.Magnitude < 1e-4 then
		return CFrame.new(pushDir * push)
	end
	local unit = axis.Unit
	return CFrame.new(pushDir * push)
		* CFrame.new(0, -halfY, 0)
		* CFrame.fromAxisAngle(unit, angle)
		* CFrame.new(0, halfY, 0)
end

local function unbindStep()
	if stepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(STEP_NAME)
		end)
		stepBound = false
	end
end

local function restoreAndClear(root: Instance)
	local entry = active[root]
	if not entry then
		return
	end
	for _, piece in entry.pieces do
		if piece.target.Parent then
			applyTargetCFrame(piece.target, piece.base)
		end
	end
	active[root] = nil
	activeCount = math.max(0, activeCount - 1)
	if activeCount == 0 then
		unbindStep()
	end
end

local function stepSways(_dt: number)
	local now = os.clock()
	local toClear: { Instance } = {}

	for root, entry in active do
		local alive = false
		for _, piece in entry.pieces do
			if piece.target.Parent then
				alive = true
				break
			end
		end
		if not alive then
			table.insert(toClear, root)
			continue
		end

		local t = (now - entry.startedAt) / entry.duration
		if t >= 1 then
			table.insert(toClear, root)
			continue
		end

		local envelope = swayEnvelope(t)
		local angle = entry.amp * envelope
		local push = entry.push * envelope
		for _, piece in entry.pieces do
			if piece.target.Parent then
				applyTargetCFrame(
					piece.target,
					piece.base * bendOffset(piece.halfY, entry.axis, angle, push, entry.pushDir)
				)
			end
		end
	end

	for _, root in toClear do
		restoreAndClear(root)
	end
end

local function bindStep()
	if stepBound then
		return
	end
	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value, stepSways)
	stepBound = true
end

local function isGrassPart(inst: Instance): boolean
	local name = string.lower(inst.Name)
	if name ~= "grasspart" then
		return false
	end
	return inst:IsA("BasePart") or inst:IsA("Model")
end

local function resolveSwayTarget(hit: Instance): (Instance?, SwayKind?)
	if BushRootUtil.isGeneratedPromptHelper(hit) then
		return nil, nil
	end

	local bush = BushRootUtil.resolveBushRoot(hit)
	if bush then
		return bush, "bush"
	end

	if isGrassPart(hit) then
		return hit, "grass"
	end

	-- Climb a few parents in case overlap hit a nested mesh under grasspart.
	local node: Instance? = hit.Parent
	for _ = 1, 3 do
		if not node then
			break
		end
		if isGrassPart(node) then
			return node, "grass"
		end
		node = node.Parent
	end

	return nil, nil
end

local function capturePieces(root: Instance, kind: SwayKind): { TargetBase }?
	local pieces: { TargetBase } = {}
	local targets: { Instance }
	if kind == "bush" then
		targets = BushRootUtil.getShakeTargets(root)
	else
		targets = { root }
	end

	for _, target in targets do
		local base = getTargetPivot(target)
		if base then
			table.insert(pieces, {
				target = target,
				base = base,
				halfY = approxHalfY(target),
			})
		end
	end

	if #pieces == 0 then
		return nil
	end
	return pieces
end

local function canStart(target: Instance, kind: SwayKind): boolean
	if active[target] then
		return false
	end
	if activeCount >= MAX_ACTIVE then
		return false
	end
	local untilT = cooldownUntil[target]
	if untilT and os.clock() < untilT then
		return false
	end
	if kind == "bush" then
		if ProximityPromptEffects.isBushSearchActive() then
			return false
		end
		if BushShiver.isAnimating(target) then
			return false
		end
	end
	return true
end

local function speedAmpScale(humanoid: Humanoid, hrp: BasePart): number
	local moveMag = humanoid.MoveDirection.Magnitude
	local vel = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z).Magnitude
	local walk = math.max(humanoid.WalkSpeed, 1)
	local speedFactor = math.clamp(vel / walk, 0.75, 1.55)
	return 0.85 + moveMag * 0.25 + (speedFactor - 1) * 0.55
end

local function startSway(target: Instance, kind: SwayKind, moveDir: Vector3, ampScale: number)
	if not canStart(target, kind) then
		return
	end

	local pieces = capturePieces(target, kind)
	if not pieces then
		return
	end

	local flat = Vector3.new(moveDir.X, 0, moveDir.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	flat = flat.Unit
	local axis = Vector3.yAxis:Cross(flat)
	if axis.Magnitude < 1e-3 then
		axis = Vector3.xAxis
	else
		axis = axis.Unit
	end

	local baseAmp = if kind == "grass" then GRASS_TILT_RAD else BUSH_TILT_RAD
	local basePush = if kind == "grass" then GRASS_PUSH else BUSH_PUSH

	active[target] = {
		kind = kind,
		pieces = pieces,
		axis = axis,
		amp = baseAmp * ampScale,
		push = basePush * ampScale,
		pushDir = flat,
		startedAt = os.clock(),
		duration = SWAY_DURATION_SEC,
	}
	activeCount += 1
	cooldownUntil[target] = os.clock() + COOLDOWN_SEC
	bindStep()
end

local function ensureLandsFolder(): Instance?
	if landsFolder and landsFolder.Parent then
		return landsFolder
	end
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local lands = map:FindFirstChild("Lands")
	if lands then
		landsFolder = lands
	end
	return landsFolder
end

local function isUnderLands(inst: Instance): boolean
	local lands = ensureLandsFolder()
	if not lands then
		return false
	end
	return inst:IsDescendantOf(lands)
end

local function scanAroundCharacter(character: Model, humanoid: Humanoid, hrp: BasePart)
	local move = humanoid.MoveDirection
	if move.Magnitude < MOVE_DIR_MIN then
		return
	end

	local state = humanoid:GetState()
	if
		state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Dead
	then
		return
	end

	if not ensureLandsFolder() then
		return
	end

	overlapParams.FilterDescendantsInstances = { character }
	local parts = Workspace:GetPartBoundsInBox(hrp.CFrame, OVERLAP_SIZE, overlapParams)
	if #parts == 0 then
		return
	end

	table.sort(parts, function(a, b)
		return (a.Position - hrp.Position).Magnitude < (b.Position - hrp.Position).Magnitude
	end)

	local ampScale = speedAmpScale(humanoid, hrp)
	local seen: { [Instance]: boolean } = {}
	local bushQueue: { Instance } = {}
	local grassQueue: { Instance } = {}

	for _, part in parts do
		if not isUnderLands(part) then
			continue
		end
		local target, kind = resolveSwayTarget(part)
		if not target or not kind or seen[target] then
			continue
		end
		seen[target] = true
		if kind == "bush" then
			table.insert(bushQueue, target)
		else
			table.insert(grassQueue, target)
		end
	end

	-- Bushes first so dense grass can't starve them under the hard cap.
	for _, target in bushQueue do
		if activeCount >= MAX_ACTIVE then
			break
		end
		startSway(target, "bush", move, ampScale)
	end
	for _, target in grassQueue do
		if activeCount >= MAX_ACTIVE then
			break
		end
		startSway(target, "grass", move, ampScale)
	end
end

local function clearAllSways()
	local targets: { Instance } = {}
	for target in active do
		table.insert(targets, target)
	end
	for _, target in targets do
		restoreAndClear(target)
	end
	unbindStep()
end

local function bindCharacter(character: Model)
	disconnectCharConns()
	clearAllSways()

	local humanoid = character:WaitForChild("Humanoid", 10)
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	table.insert(
		charConns,
		character.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				disconnectCharConns()
				clearAllSways()
			end
		end)
	)
end

local function onHeartbeat(dt: number)
	scanAccum += dt
	if scanAccum < SCAN_INTERVAL_SEC then
		return
	end
	scanAccum = 0

	local character = localPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp or not hrp:IsA("BasePart") then
		return
	end

	local ok, err = pcall(scanAroundCharacter, character, humanoid, hrp :: BasePart)
	if not ok then
		warn("[VegetationSwayController] error:", err)
	end
end

function M.init()
	if heartbeatConn then
		return
	end

	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

	localPlayer.CharacterAdded:Connect(function(character)
		task.spawn(bindCharacter, character)
	end)
	if localPlayer.Character then
		task.spawn(bindCharacter, localPlayer.Character)
	end

	localPlayer.CharacterRemoving:Connect(function()
		disconnectCharConns()
		clearAllSways()
	end)
end

return M
