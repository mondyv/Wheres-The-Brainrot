-- [ACTIVE] VegetationSwayController
--[[
	Local-only Pokémon-style bend for grasspart + bushes under Map.Lands.
	- Indexes only instances named grasspart (never whole grassland groups).
	- Holds bend while the player stands in range; recovers after leaving.
	- Bush proximity uses visual bounds (not Model pivot, which can be wrong).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local M = {}

local MAX_ACTIVE = 28
local SCAN_INTERVAL_SEC = 0.04
local GRASS_RADIUS = 3.4
local BUSH_RADIUS = 5.5
local GRASS_TILT_RAD = math.rad(14)
local BUSH_TILT_RAD = math.rad(11)
local GRASS_PUSH = 0.12
local BUSH_PUSH = 0.28
local PRESS_SEC = 0.1
local RECOVER_SEC = 0.28
local LEAVE_GRACE_SEC = 0.12
local INDEX_REFRESH_SEC = 4
local STEP_NAME = "VegetationSwayStep"

type SwayKind = "grass" | "bush"
type Phase = "press" | "hold" | "recover"

type VegEntry = {
	root: Instance,
	kind: SwayKind,
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
	phase: Phase,
	phaseStartedAt: number,
	lastInRangeAt: number,
}

local localPlayer = Players.LocalPlayer

local vegEntries: { VegEntry } = {}
local indexedRoots: { [Instance]: boolean } = {}
local indexConns: { RBXScriptConnection } = {}
local lastIndexAt = 0

local active: { [Instance]: ActiveSway } = {}
local activeCount = 0
local stepBound = false
local scanAccum = 0
local heartbeatConn: RBXScriptConnection? = nil
local charConns: { RBXScriptConnection } = {}
local lastMoveFlat = Vector3.new(0, 0, -1)

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

local function approxHalfY(target: Instance): number
	if target:IsA("BasePart") then
		return math.max((target :: BasePart).Size.Y * 0.5, 0.25)
	end
	if target:IsA("Model") then
		local ok, size = pcall(function()
			return (target :: Model):GetExtentsSize()
		end)
		if ok and typeof(size) == "Vector3" then
			return math.clamp((size :: Vector3).Y * 0.45, 0.4, 3.5)
		end
	end
	return 1
end

local function grassWorldPos(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	end
	local pivot = getTargetPivot(inst)
	return if pivot then pivot.Position else nil
end

-- Visual center of a bush (ignores bad Model pivots).
local function bushWorldPos(root: Instance): Vector3?
	local focus = BushRootUtil.focusWorldPosition(root, 0)
	if focus then
		return focus
	end
	return grassWorldPos(root)
end

local function entryWorldPos(entry: VegEntry): Vector3?
	if entry.kind == "bush" then
		return bushWorldPos(entry.root)
	end
	return grassWorldPos(entry.root)
end

local function xzDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
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

local function phaseEnvelope(entry: ActiveSway, now: number): number
	if entry.phase == "hold" then
		return 1
	end
	if entry.phase == "press" then
		local u = math.clamp((now - entry.phaseStartedAt) / PRESS_SEC, 0, 1)
		return u * u
	end
	-- recover
	local u = math.clamp((now - entry.phaseStartedAt) / RECOVER_SEC, 0, 1)
	return (1 - u) * (1 - u)
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

		-- Left range → start recover.
		if entry.phase ~= "recover" and (now - entry.lastInRangeAt) > LEAVE_GRACE_SEC then
			entry.phase = "recover"
			entry.phaseStartedAt = now
		end

		if entry.phase == "press" and (now - entry.phaseStartedAt) >= PRESS_SEC then
			entry.phase = "hold"
			entry.phaseStartedAt = now
		end

		if entry.phase == "recover" and (now - entry.phaseStartedAt) >= RECOVER_SEC then
			table.insert(toClear, root)
			continue
		end

		local envelope = phaseEnvelope(entry, now)
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
	return string.lower(inst.Name) == "grasspart" and (inst:IsA("BasePart") or inst:IsA("Model"))
end

local function addVeg(root: Instance, kind: SwayKind)
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
	})
end

local function indexLandFolder(landFolder: Instance)
	local grassFolder = landFolder:FindFirstChild("grass")
	if grassFolder then
		-- Only grasspart — never whole grassland groups.
		for _, desc in grassFolder:GetDescendants() do
			if isGrassPart(desc) then
				if desc:IsA("BasePart") then
					addVeg(desc, "grass")
				elseif desc:IsA("Model") then
					-- Model named grasspart: sway each leaf BasePart, not the group pivot.
					local partCount = 0
					for _, child in desc:GetDescendants() do
						if child:IsA("BasePart") then
							addVeg(child, "grass")
							partCount += 1
						end
					end
					if partCount == 0 then
						addVeg(desc, "grass")
					end
				end
			end
		end
	end

	for _, folderName in BushRootUtil.FOLDER_NAMES do
		local bushFolder = landFolder:FindFirstChild(folderName)
		if not bushFolder then
			continue
		end

		local function indexBushContainer(container: Instance)
			for _, child in container:GetChildren() do
				if BushRootUtil.isGeneratedPromptHelper(child) then
					continue
				end
				if BushRootUtil.isBushContainer(child) then
					-- Nested BushSCRIPT folder under BushSCRIPTs.
					indexBushContainer(child)
				elseif child:IsA("Model") or child:IsA("BasePart") then
					addVeg(child, "bush")
				end
			end
		end

		if bushFolder:IsA("Folder") or bushFolder:IsA("Model") then
			indexBushContainer(bushFolder)
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

	for _, landFolder in lands:GetChildren() do
		if (landFolder:IsA("Folder") or landFolder:IsA("Model")) and string.match(landFolder.Name, "^Land%d+$") then
			indexLandFolder(landFolder)
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
	if #vegEntries == 0 or (os.clock() - lastIndexAt) >= INDEX_REFRESH_SEC then
		rebuildIndex()
	end
end

local function capturePieces(root: Instance, kind: SwayKind): { TargetBase }?
	local pieces: { TargetBase } = {}
	local targets: { Instance }

	if kind == "bush" then
		-- Same targets BushShiver uses — proven to move bush visuals.
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

local function makeAxis(pushDir: Vector3): Vector3
	local axis = Vector3.yAxis:Cross(pushDir)
	if axis.Magnitude < 1e-3 then
		return Vector3.xAxis
	end
	return axis.Unit
end

local function touchVeg(root: Instance, kind: SwayKind, pushDir: Vector3, now: number)
	local existing = active[root]
	if existing then
		existing.lastInRangeAt = now
		if existing.phase == "recover" then
			existing.phase = "press"
			existing.phaseStartedAt = now
		end
		if pushDir.Magnitude > 0.2 then
			existing.pushDir = pushDir
			existing.axis = makeAxis(pushDir)
		end
		return
	end

	if activeCount >= MAX_ACTIVE then
		return
	end
	if kind == "bush" and ProximityPromptEffects.isBushSearchActive() then
		return
	end

	local pieces = capturePieces(root, kind)
	if not pieces then
		return
	end

	local amp = if kind == "grass" then GRASS_TILT_RAD else BUSH_TILT_RAD
	local push = if kind == "grass" then GRASS_PUSH else BUSH_PUSH

	active[root] = {
		kind = kind,
		pieces = pieces,
		axis = makeAxis(pushDir),
		amp = amp,
		push = push,
		pushDir = pushDir,
		phase = "press",
		phaseStartedAt = now,
		lastInRangeAt = now,
	}
	activeCount += 1
	bindStep()
end

local function scanAroundCharacter(_character: Model, humanoid: Humanoid, hrp: BasePart)
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Dead then
		return
	end

	ensureIndex()
	if #vegEntries == 0 then
		return
	end

	local pos = hrp.Position
	local move = humanoid.MoveDirection
	local moveFlat = Vector3.new(move.X, 0, move.Z)
	if moveFlat.Magnitude > 0.12 then
		lastMoveFlat = moveFlat.Unit
	end

	local now = os.clock()

	type Cand = { root: Instance, kind: SwayKind, dist: number }
	local bushes: { Cand } = {}
	local grasses: { Cand } = {}

	for _, entry in vegEntries do
		if not entry.root.Parent then
			continue
		end

		local rootPos = entryWorldPos(entry)
		if not rootPos then
			continue
		end
		if math.abs(rootPos.Y - pos.Y) > 14 then
			continue
		end

		local dist = xzDist(rootPos, pos)
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

	local function pushDirFor(root: Instance, rootPos: Vector3): Vector3
		if moveFlat.Magnitude > 0.12 then
			return moveFlat.Unit
		end
		if lastMoveFlat.Magnitude > 0.1 then
			return lastMoveFlat
		end
		local away = Vector3.new(pos.X - rootPos.X, 0, pos.Z - rootPos.Z)
		if away.Magnitude > 1e-3 then
			return away.Unit
		end
		return Vector3.new(0, 0, -1)
	end

	-- Prefer bushes so they aren't starved by dense grass.
	for _, cand in bushes do
		local rootPos = bushWorldPos(cand.root)
		if rootPos then
			touchVeg(cand.root, "bush", pushDirFor(cand.root, rootPos), now)
		end
	end
	for _, cand in grasses do
		local rootPos = grassWorldPos(cand.root)
		if rootPos then
			touchVeg(cand.root, "grass", pushDirFor(cand.root, rootPos), now)
		end
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
