-- [ACTIVE] VegetationSwayController
--[[
	Local-only Pokémon-style bend when walking through grass and bushes.
	Indexes Map.Lands/*/grass/grassland(+grasspart) and */BushSCRIPTs children by distance
	(overlap fails when CanQuery is off). Hard-caps simultaneous sways.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local BushShiver = require(script.Parent.BushShiver)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local M = {}

local MAX_ACTIVE = 32
local SCAN_INTERVAL_SEC = 0.035
local MOVE_DIR_MIN = 0.1
local GRASS_RADIUS = 5.25
local BUSH_RADIUS = 6.5
local GRASS_TILT_RAD = math.rad(42)
local BUSH_TILT_RAD = math.rad(32)
local GRASS_PUSH = 0.45
local BUSH_PUSH = 0.85
local SWAY_DURATION_SEC = 0.7
local COOLDOWN_SEC = 0.16
local INDEX_REFRESH_SEC = 2.5
local STEP_NAME = "VegetationSwayStep"

type SwayKind = "grass" | "bush"

type VegEntry = {
	root: Instance,
	kind: SwayKind,
	landFolder: Instance,
}

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

local landsFolder: Instance? = nil
local vegEntries: { VegEntry } = {}
local indexedRoots: { [Instance]: boolean } = {}
local indexConns: { RBXScriptConnection } = {}
local lastIndexAt = 0

local active: { [Instance]: ActiveSway } = {}
local activeCount = 0
local cooldownUntil: { [Instance]: number } = {}
local stepBound = false
local scanAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}

local function disconnectList(list: { RBXScriptConnection })
	for _, conn in list do
		conn:Disconnect()
	end
	table.clear(list)
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

local function getWorldPos(inst: Instance): Vector3?
	local pivot = getTargetPivot(inst)
	if pivot then
		return pivot.Position
	end
	local part = if inst:IsA("BasePart") then inst else inst:FindFirstChildWhichIsA("BasePart", true)
	return if part and part:IsA("BasePart") then part.Position else nil
end

local function approxHalfY(target: Instance): number
	if target:IsA("BasePart") then
		return math.max((target :: BasePart).Size.Y * 0.5, 0.4)
	end
	if target:IsA("Model") then
		local ok, size = pcall(function()
			return (target :: Model):GetExtentsSize()
		end)
		if ok and typeof(size) == "Vector3" then
			return math.clamp((size :: Vector3).Y * 0.5, 0.55, 5)
		end
	end
	return 1.4
end

-- Fast punch, hold a clear peak, then recover.
local function swayEnvelope(t: number): number
	if t <= 0 or t >= 1 then
		return 0
	end
	if t < 0.12 then
		local u = t / 0.12
		return u * u
	end
	if t < 0.48 then
		return 1
	end
	local u = (t - 0.48) / 0.52
	return (1 - u) * (1 - u)
end

local function bendOffset(halfY: number, axis: Vector3, angle: number, push: number, pushDir: Vector3): CFrame
	local pushCf = CFrame.new(pushDir * push)
	if angle == 0 or axis.Magnitude < 1e-4 then
		return pushCf
	end
	return pushCf
		* CFrame.new(0, -halfY, 0)
		* CFrame.fromAxisAngle(axis.Unit, angle)
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

local function isGrassPartName(name: string): boolean
	return string.lower(name) == "grasspart"
end

local function isGrasslandName(name: string): boolean
	return string.lower(name) == "grassland"
end

local function collectGrassRootsFromGrassland(grassland: Instance): { Instance }
	local roots: { Instance } = {}

	for _, desc in grassland:GetDescendants() do
		if isGrassPartName(desc.Name) and (desc:IsA("BasePart") or desc:IsA("Model")) then
			table.insert(roots, desc)
		end
	end
	if #roots > 0 then
		return roots
	end

	-- No grasspart: sway direct BasePart children.
	for _, child in grassland:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(roots, child)
		end
	end
	if #roots > 0 then
		return roots
	end

	-- Nested meshes under grassland (cap so one patch can't flood the global budget).
	local fallbackCap = 14
	for _, desc in grassland:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(roots, desc)
			if #roots >= fallbackCap then
				break
			end
		end
	end
	if #roots > 0 then
		return roots
	end

	if grassland:IsA("BasePart") or grassland:IsA("Model") then
		table.insert(roots, grassland)
	end
	return roots
end

local function addVeg(root: Instance, kind: SwayKind, landFolder: Instance)
	if indexedRoots[root] then
		return
	end
	if not root:IsA("Model") and not root:IsA("BasePart") then
		return
	end
	indexedRoots[root] = true
	table.insert(vegEntries, {
		root = root,
		kind = kind,
		landFolder = landFolder,
	})
end

local function indexLandFolder(landFolder: Instance)
	local grassFolder = landFolder:FindFirstChild("grass")
	if grassFolder then
		local function considerGrassland(node: Instance)
			if not isGrasslandName(node.Name) then
				return
			end
			for _, grassRoot in collectGrassRootsFromGrassland(node) do
				addVeg(grassRoot, "grass", landFolder)
			end
		end

		if isGrasslandName(grassFolder.Name) then
			considerGrassland(grassFolder)
		end
		for _, child in grassFolder:GetChildren() do
			considerGrassland(child)
			-- Nested grassland folders/models.
			if child:IsA("Folder") or child:IsA("Model") then
				for _, nested in child:GetChildren() do
					considerGrassland(nested)
				end
			end
		end
	end

	for _, folderName in BushRootUtil.FOLDER_NAMES do
		local bushFolder = landFolder:FindFirstChild(folderName)
		if bushFolder and bushFolder:IsA("Folder") then
			for _, child in bushFolder:GetChildren() do
				if BushRootUtil.isDirectBushRoot(child) then
					addVeg(child, "bush", landFolder)
				elseif child:IsA("Model") or child:IsA("BasePart") then
					-- Named BushSCRIPT etc. even if util edge-case fails.
					addVeg(child, "bush", landFolder)
				end
			end
		end
	end
end

local function clearIndex()
	disconnectList(indexConns)
	table.clear(vegEntries)
	table.clear(indexedRoots)
end

local function rebuildIndex()
	clearIndex()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local lands = map:FindFirstChild("Lands")
	if not lands then
		return
	end
	landsFolder = lands

	for _, landFolder in lands:GetChildren() do
		if landFolder:IsA("Folder") or landFolder:IsA("Model") then
			if string.match(landFolder.Name, "^Land%d+$") then
				indexLandFolder(landFolder)
			end
		end
	end

	table.insert(
		indexConns,
		lands.ChildAdded:Connect(function(child)
			if string.match(child.Name, "^Land%d+$") then
				task.defer(function()
					indexLandFolder(child)
				end)
			end
		end)
	)

	lastIndexAt = os.clock()
end

local function ensureIndex()
	local now = os.clock()
	if #vegEntries == 0 or now - lastIndexAt >= INDEX_REFRESH_SEC then
		rebuildIndex()
	end
end

local function capturePieces(root: Instance, kind: SwayKind): { TargetBase }?
	local pieces: { TargetBase } = {}
	local targets: { Instance }
	if kind == "bush" then
		targets = BushRootUtil.getShakeTargets(root)
		-- Also nudge every BasePart under the bush if Model pivot alone is subtle.
		if root:IsA("Model") then
			local extra: { Instance } = {}
			for _, desc in root:GetDescendants() do
				if desc:IsA("BasePart") and not BushRootUtil.isGeneratedPromptHelper(desc) then
					local already = false
					for _, t in targets do
						if t == desc then
							already = true
							break
						end
					end
					if not already then
						-- Prefer model-level pivot only when the bush has no child Models;
						-- for single-mesh bushes, pivoting BaseParts is more visible.
						table.insert(extra, desc)
					end
				end
			end
			-- If root is a Model with only BasePart children (no nested Models), animate parts.
			local hasChildModel = false
			for _, child in root:GetChildren() do
				if child:IsA("Model") and not BushRootUtil.isGeneratedPromptHelper(child) then
					hasChildModel = true
					break
				end
			end
			if not hasChildModel and #extra > 0 then
				targets = extra
			end
		end
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
	local speedFactor = math.clamp(vel / walk, 0.8, 1.7)
	return 0.95 + moveMag * 0.2 + (speedFactor - 1) * 0.45
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

local function scanAroundCharacter(_character: Model, humanoid: Humanoid, hrp: BasePart)
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

	ensureIndex()
	if #vegEntries == 0 then
		return
	end

	local pos = hrp.Position
	local flatPos = Vector3.new(pos.X, 0, pos.Z)
	local ampScale = speedAmpScale(humanoid, hrp)

	type Cand = { root: Instance, kind: SwayKind, dist: number }
	local bushes: { Cand } = {}
	local grasses: { Cand } = {}

	for _, entry in vegEntries do
		if not entry.root.Parent then
			continue
		end

		local rootPos = getWorldPos(entry.root)
		if not rootPos then
			continue
		end
		-- Cheap reject on Y so distant lands above/below don't matter much.
		if math.abs(rootPos.Y - pos.Y) > 12 then
			continue
		end
		local dist = (Vector3.new(rootPos.X, 0, rootPos.Z) - flatPos).Magnitude
		local radius = if entry.kind == "bush" then BUSH_RADIUS else GRASS_RADIUS
		if dist > radius then
			continue
		end

		local cand = { root = entry.root, kind = entry.kind, dist = dist }
		if entry.kind == "bush" then
			table.insert(bushes, cand)
		else
			table.insert(grasses, cand)
		end
	end

	local function byDist(a: Cand, b: Cand): boolean
		return a.dist < b.dist
	end
	table.sort(bushes, byDist)
	table.sort(grasses, byDist)

	for _, cand in bushes do
		if activeCount >= MAX_ACTIVE then
			break
		end
		startSway(cand.root, "bush", move, ampScale)
	end
	for _, cand in grasses do
		if activeCount >= MAX_ACTIVE then
			break
		end
		startSway(cand.root, "grass", move, ampScale)
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
	disconnectList(charConns)
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
				disconnectList(charConns)
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

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 60)
		if map then
			map:WaitForChild("Lands", 30)
		end
		rebuildIndex()
	end)

	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

	localPlayer.CharacterAdded:Connect(function(character)
		task.spawn(bindCharacter, character)
	end)
	if localPlayer.Character then
		task.spawn(bindCharacter, localPlayer.Character)
	end

	localPlayer.CharacterRemoving:Connect(function()
		disconnectList(charConns)
		clearAllSways()
	end)
end

return M
