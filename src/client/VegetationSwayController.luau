-- [ACTIVE] VegetationSwayController
--[[
	Local-only Pokémon-style bend for grassparts under Map.Lands/*/grass.
	Holds bend while standing in range; recovers after leaving.
	Bushes intentionally omitted (nested cluster search was too expensive).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local M = {}

local MAX_ACTIVE = 24
local SCAN_INTERVAL_SEC = 0.05
local GRASS_RADIUS = 3.4
local GRASS_RADIUS_SQ = GRASS_RADIUS * GRASS_RADIUS
local GRASS_TILT_RAD = math.rad(14)
local GRASS_PUSH = 0.12
local PRESS_SEC = 0.1
local RECOVER_SEC = 0.28
local LEAVE_GRACE_SEC = 0.12
local INDEX_REFRESH_SEC = 8
local STEP_NAME = "VegetationSwayStep"

type Phase = "press" | "hold" | "recover"

type GrassEntry = {
	part: BasePart,
	x: number,
	y: number,
	z: number,
}

type ActiveSway = {
	part: BasePart,
	base: CFrame,
	halfY: number,
	axis: Vector3,
	amp: number,
	push: number,
	pushDir: Vector3,
	phase: Phase,
	phaseStartedAt: number,
	lastInRangeAt: number,
}

local localPlayer = Players.LocalPlayer

local grassEntries: { GrassEntry } = {}
local indexedParts: { [BasePart]: boolean } = {}
local indexConns: { RBXScriptConnection } = {}
local lastIndexAt = 0

local active: { [BasePart]: ActiveSway } = {}
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

local function restoreAndClear(part: BasePart)
	local entry = active[part]
	if not entry then
		return
	end
	if part.Parent then
		part.CFrame = entry.base
	end
	active[part] = nil
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
	local u = math.clamp((now - entry.phaseStartedAt) / RECOVER_SEC, 0, 1)
	return (1 - u) * (1 - u)
end

local function stepSways(_dt: number)
	local now = os.clock()
	local toClear: { BasePart } = {}

	for part, entry in active do
		if not part.Parent then
			table.insert(toClear, part)
			continue
		end

		if entry.phase ~= "recover" and (now - entry.lastInRangeAt) > LEAVE_GRACE_SEC then
			entry.phase = "recover"
			entry.phaseStartedAt = now
		end

		if entry.phase == "press" and (now - entry.phaseStartedAt) >= PRESS_SEC then
			entry.phase = "hold"
			entry.phaseStartedAt = now
		end

		if entry.phase == "recover" and (now - entry.phaseStartedAt) >= RECOVER_SEC then
			table.insert(toClear, part)
			continue
		end

		local envelope = phaseEnvelope(entry, now)
		part.CFrame = entry.base
			* bendOffset(entry.halfY, entry.axis, entry.amp * envelope, entry.push * envelope, entry.pushDir)
	end

	for _, part in toClear do
		restoreAndClear(part)
	end
end

local function bindStep()
	if stepBound then
		return
	end
	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value, stepSways)
	stepBound = true
end

local function addGrassPart(part: BasePart)
	if indexedParts[part] then
		return
	end
	indexedParts[part] = true
	local pos = part.Position
	table.insert(grassEntries, {
		part = part,
		x = pos.X,
		y = pos.Y,
		z = pos.Z,
	})
end

local function indexLandFolder(landFolder: Instance)
	local grassFolder = landFolder:FindFirstChild("grass")
	if not grassFolder then
		return
	end

	for _, desc in grassFolder:GetDescendants() do
		if string.lower(desc.Name) ~= "grasspart" then
			continue
		end
		if desc:IsA("BasePart") then
			addGrassPart(desc)
		elseif desc:IsA("Model") then
			-- Prefer the model’s direct BasePart children (one blade unit), not every nested mesh.
			local any = false
			for _, child in desc:GetChildren() do
				if child:IsA("BasePart") then
					addGrassPart(child)
					any = true
				end
			end
			if not any then
				local part = desc:FindFirstChildWhichIsA("BasePart", true)
				if part then
					addGrassPart(part)
				end
			end
		end
	end
end

local function clearIndex()
	disconnectList(indexConns)
	table.clear(grassEntries)
	table.clear(indexedParts)
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
	if #grassEntries == 0 or (os.clock() - lastIndexAt) >= INDEX_REFRESH_SEC then
		rebuildIndex()
	end
end

local function makeAxis(pushDir: Vector3): Vector3
	local axis = Vector3.yAxis:Cross(pushDir)
	if axis.Magnitude < 1e-3 then
		return Vector3.xAxis
	end
	return axis.Unit
end

local function touchGrass(part: BasePart, pushDir: Vector3, now: number)
	local existing = active[part]
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
	if not part.Parent then
		return
	end

	active[part] = {
		part = part,
		base = part.CFrame,
		halfY = math.max(part.Size.Y * 0.5, 0.25),
		axis = makeAxis(pushDir),
		amp = GRASS_TILT_RAD,
		push = GRASS_PUSH,
		pushDir = pushDir,
		phase = "press",
		phaseStartedAt = now,
		lastInRangeAt = now,
	}
	activeCount += 1
	bindStep()
end

local function scanAroundCharacter(_character: Model, humanoid: Humanoid, hrp: BasePart)
	if humanoid:GetState() == Enum.HumanoidStateType.Dead then
		return
	end

	ensureIndex()
	local n = #grassEntries
	if n == 0 then
		return
	end

	local pos = hrp.Position
	local px, py, pz = pos.X, pos.Y, pos.Z
	local move = humanoid.MoveDirection
	local moveFlat = Vector3.new(move.X, 0, move.Z)
	if moveFlat.Magnitude > 0.12 then
		lastMoveFlat = moveFlat.Unit
	end

	local now = os.clock()
	local pushDefault = if moveFlat.Magnitude > 0.12
		then moveFlat.Unit
		elseif lastMoveFlat.Magnitude > 0.1 then lastMoveFlat
		else Vector3.new(0, 0, -1)

	-- Collect nearest hits without sorting the full map — first-pass gather then soft cap.
	type Cand = { part: BasePart, distSq: number, x: number, z: number }
	local cands: { Cand } = {}

	for i = 1, n do
		local entry = grassEntries[i]
		local part = entry.part
		if not part.Parent then
			continue
		end
		if math.abs(entry.y - py) > 12 then
			continue
		end
		local dx = entry.x - px
		local dz = entry.z - pz
		local distSq = dx * dx + dz * dz
		if distSq > GRASS_RADIUS_SQ then
			continue
		end
		table.insert(cands, { part = part, distSq = distSq, x = entry.x, z = entry.z })
	end

	if #cands == 0 then
		return
	end

	table.sort(cands, function(a, b)
		return a.distSq < b.distSq
	end)

	local limit = math.min(#cands, MAX_ACTIVE)
	for i = 1, limit do
		local cand = cands[i]
		local dir = pushDefault
		if moveFlat.Magnitude <= 0.12 then
			local away = Vector3.new(px - cand.x, 0, pz - cand.z)
			if away.Magnitude > 1e-3 then
				dir = away.Unit
			end
		end
		touchGrass(cand.part, dir, now)
	end
end

local function clearAllSways()
	local parts: { BasePart } = {}
	for part in active do
		table.insert(parts, part)
	end
	for _, part in parts do
		restoreAndClear(part)
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
