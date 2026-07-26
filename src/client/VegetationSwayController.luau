-- [ACTIVE] VegetationSwayController
--[[
	Local-only smooth Pokémon-style bend for grassparts under Map.Lands/*/grass.
	Holds bend while standing in range; recovers after leaving.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local M = {}

local MAX_ACTIVE = 24
local SCAN_INTERVAL_SEC = 0.2
local GRASS_RADIUS = 3.4
local GRASS_RADIUS_SQ = GRASS_RADIUS * GRASS_RADIUS
local GRASS_TILT_RAD = math.rad(13)
local GRASS_PUSH = 0.1
local BLEND_IN = 7.5
local BLEND_OUT = 4.2
local CLEAR_EPS = 0.02
local LEAVE_GRACE_SEC = 0.14
local INDEX_REFRESH_SEC = 14
local STEP_NAME = "VegetationSwayStep"
local DIR_SMOOTH = 6

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
	pushDir: Vector3,
	targetDir: Vector3,
	envelope: number,
	lastInRangeAt: number,
	amp: number,
	push: number,
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

local function makeAxis(pushDir: Vector3): Vector3
	local axis = Vector3.yAxis:Cross(pushDir)
	if axis.Magnitude < 1e-3 then
		return Vector3.xAxis
	end
	return axis.Unit
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

local function stepSways(dt: number)
	local now = os.clock()
	local toClear: { BasePart } = {}
	local safeDt = math.clamp(dt, 0, 0.05)

	for part, entry in active do
		if not part.Parent then
			table.insert(toClear, part)
			continue
		end

		local inRange = (now - entry.lastInRangeAt) <= LEAVE_GRACE_SEC
		local targetEnv = if inRange then 1 else 0
		local blend = if targetEnv > entry.envelope then BLEND_IN else BLEND_OUT
		local alpha = 1 - math.exp(-blend * safeDt)
		entry.envelope += (targetEnv - entry.envelope) * alpha

		-- Soft-follow walk direction so blades don't snap when turning.
		local dirAlpha = 1 - math.exp(-DIR_SMOOTH * safeDt)
		entry.pushDir = entry.pushDir:Lerp(entry.targetDir, dirAlpha)
		if entry.pushDir.Magnitude > 1e-3 then
			entry.pushDir = entry.pushDir.Unit
			entry.axis = makeAxis(entry.pushDir)
		end

		if not inRange and entry.envelope <= CLEAR_EPS then
			table.insert(toClear, part)
			continue
		end

		-- Smoothstep the visible bend so mid-motion feels softer.
		local e = entry.envelope
		local smooth = e * e * (3 - 2 * e)
		part.CFrame = entry.base
			* bendOffset(entry.halfY, entry.axis, entry.amp * smooth, entry.push * smooth, entry.pushDir)
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

	-- Stack walk + yields — never grassFolder:GetDescendants() (sync timeout on big lands).
	local stack: { Instance } = { grassFolder }
	local scanned = 0
	while #stack > 0 do
		local node = table.remove(stack) :: Instance
		for _, desc in node:GetChildren() do
			scanned += 1
			if scanned % 200 == 0 then
				task.wait()
			end
			if string.lower(desc.Name) ~= "grasspart" then
				table.insert(stack, desc)
				continue
			end
			if desc:IsA("BasePart") then
				addGrassPart(desc)
			elseif desc:IsA("Model") then
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
			else
				table.insert(stack, desc)
			end
		end
	end
end

local function clearIndex()
	disconnectList(indexConns)
	table.clear(grassEntries)
	table.clear(indexedParts)
end

local indexBusy = false

local function rebuildIndex()
	if indexBusy then
		return
	end
	indexBusy = true
	clearIndex()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		indexBusy = false
		return
	end
	local lands = map:FindFirstChild("Lands")
	if not lands then
		indexBusy = false
		return
	end

	for _, landFolder in lands:GetChildren() do
		if (landFolder:IsA("Folder") or landFolder:IsA("Model")) and string.match(landFolder.Name, "^Land%d+$") then
			indexLandFolder(landFolder)
			task.wait()
		end
	end

	table.insert(
		indexConns,
		lands.ChildAdded:Connect(function(child)
			if string.match(child.Name, "^Land%d+$") then
				task.spawn(function()
					indexLandFolder(child)
				end)
			end
		end)
	)

	lastIndexAt = os.clock()
	indexBusy = false
end

local function ensureIndex()
	-- Only build when empty. Timed full rebuilds from Heartbeat caused Studio timeouts.
	if #grassEntries == 0 and not indexBusy then
		task.spawn(rebuildIndex)
	end
end

local function touchGrass(part: BasePart, pushDir: Vector3): boolean
	local existing = active[part]
	if existing then
		existing.lastInRangeAt = os.clock()
		if pushDir.Magnitude > 0.2 then
			existing.targetDir = pushDir.Unit
		end
		return false
	end

	if activeCount >= MAX_ACTIVE then
		return false
	end
	if not part.Parent then
		return false
	end

	local dir = if pushDir.Magnitude > 0.2 then pushDir.Unit else lastMoveFlat
	active[part] = {
		part = part,
		base = part.CFrame,
		halfY = math.max(part.Size.Y * 0.5, 0.25),
		axis = makeAxis(dir),
		pushDir = dir,
		targetDir = dir,
		envelope = 0,
		lastInRangeAt = os.clock(),
		amp = GRASS_TILT_RAD,
		push = GRASS_PUSH,
	}
	activeCount += 1
	bindStep()
	return true
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
	local walking = moveFlat.Magnitude > 0.12
	if walking then
		lastMoveFlat = moveFlat.Unit
	end

	local pushDefault = if walking
		then moveFlat.Unit
		elseif lastMoveFlat.Magnitude > 0.1 then lastMoveFlat
		else Vector3.new(0, 0, -1)

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
		if not walking then
			local away = Vector3.new(px - cand.x, 0, pz - cand.z)
			if away.Magnitude > 1e-3 then
				dir = away.Unit
			end
		end
		touchGrass(cand.part, dir)
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
