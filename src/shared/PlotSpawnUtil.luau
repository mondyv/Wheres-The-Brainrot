-- [ACTIVE] PlotSpawnUtil
--[[
	Resolves plot spawn CFrames and teleports characters onto the assigned plot.
	Shared by PlotPlayerSpawn and ReturnTeleport.
--]]

local PlotPaths = require(script.Parent.PlotPaths)
local Workspace = game:GetService("Workspace")

local PlotSpawnUtil = {}

local SPAWN_CLEARANCE = 3.25
local STREAM_RETRIES = 20
local STREAM_RETRY_INTERVAL = 0.25
local STREAM_RADIUS_SEC = 10

local function expandPartBounds(cf: CFrame, size: Vector3, minV: Vector3, maxV: Vector3): (Vector3, Vector3)
	local hs = size * 0.5
	local newMin = minV
	local newMax = maxV
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local world = cf:PointToWorldSpace(Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz))
				newMin = Vector3.new(math.min(newMin.X, world.X), math.min(newMin.Y, world.Y), math.min(newMin.Z, world.Z))
				newMax = Vector3.new(math.max(newMax.X, world.X), math.max(newMax.Y, world.Y), math.max(newMax.Z, world.Z))
			end
		end
	end
	return newMin, newMax
end

local function boundingBoxOf(root: Instance): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	-- Include the root itself when it's a BasePart (Floor may be a single tile part).
	if root:IsA("BasePart") then
		any = true
		minV, maxV = expandPartBounds(root.CFrame, root.Size, minV, maxV)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			any = true
			minV, maxV = expandPartBounds(d.CFrame, d.Size, minV, maxV)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

-- Ground-plane pad under story 1 (all flat / low parts), not just one Floor tile.
local function groundPadBoundsOfStory(story1: Instance): (Vector3?, Vector3?)
	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	if floor then
		local floorMin, floorMax = boundingBoxOf(floor)
		if floorMin and floorMax then
			local spanX = floorMax.X - floorMin.X
			local spanZ = floorMax.Z - floorMin.Z
			-- Full pad already — don't pull in walls/stands.
			if spanX >= 24 and spanZ >= 24 then
				return floorMin, floorMax
			end
		end
	end

	local candidates: { BasePart } = {}
	local minBottom = math.huge
	local function consider(part: BasePart)
		table.insert(candidates, part)
		local bottom = part.Position.Y - part.Size.Y * 0.5
		if bottom < minBottom then
			minBottom = bottom
		end
	end

	if floor then
		if floor:IsA("BasePart") then
			consider(floor)
		end
		for _, d in ipairs(floor:GetDescendants()) do
			if d:IsA("BasePart") then
				consider(d)
			end
		end
	end

	-- Floor is only a corner tile — expand with other low flat parts on story 1.
	for _, d in ipairs(story1:GetDescendants()) do
		if d:IsA("BasePart") and d.Size.Y <= 4 then
			local n = string.lower(d.Name)
			local looksFloor = string.find(n, "floor", 1, true)
				or string.find(n, "pad", 1, true)
				or string.find(n, "ground", 1, true)
				or string.find(n, "tile", 1, true)
			if looksFloor or d.Size.Y <= 1.75 then
				consider(d)
			end
		end
	end

	if #candidates == 0 then
		return nil, nil
	end

	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	local yCutoff = minBottom + 6
	for _, part in ipairs(candidates) do
		local top = part.Position.Y + part.Size.Y * 0.5
		if top <= yCutoff then
			any = true
			minV, maxV = expandPartBounds(part.CFrame, part.Size, minV, maxV)
		end
	end
	if not any then
		return nil, nil
	end
	return minV, maxV
end

local function unionBounds(aMin: Vector3?, aMax: Vector3?, bMin: Vector3?, bMax: Vector3?): (Vector3?, Vector3?)
	if not aMin or not aMax then
		return bMin, bMax
	end
	if not bMin or not bMax then
		return aMin, aMax
	end
	return Vector3.new(
		math.min(aMin.X, bMin.X),
		math.min(aMin.Y, bMin.Y),
		math.min(aMin.Z, bMin.Z)
	), Vector3.new(
		math.max(aMax.X, bMax.X),
		math.max(aMax.Y, bMax.Y),
		math.max(aMax.Z, bMax.Z)
	)
end

local function anchorBoundsForPlot(plot: Instance): (Vector3?, Vector3?)
	local slotId = plot:GetAttribute("PlotSlotId")
	local posFolder = PlotPaths.findSpawnAndBasesFolder()
	if not posFolder or typeof(slotId) ~= "number" then
		return nil, nil
	end
	local anchor = posFolder:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
	if not anchor or not anchor:IsA("BasePart") then
		return nil, nil
	end
	local a = anchor :: BasePart
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	return expandPartBounds(a.CFrame, a.Size, minV, maxV)
end

local function cfOnTopOfBounds(minV: Vector3, maxV: Vector3, face: Vector3): CFrame
	local center = (minV + maxV) * 0.5
	local topY = maxV.Y + SPAWN_CLEARANCE
	local pos = Vector3.new(center.X, topY, center.Z)
	local flat = Vector3.new(face.X, 0, face.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

local function flatLookFromPart(part: BasePart): Vector3
	local look = part.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

-- Prefer the dedicated Spawn pad under story 1 (never a stand Spawn).
function PlotSpawnUtil.findPlotSpawnAnchor(plot: Instance): BasePart?
	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil
	end

	local spawnNode = story1:FindFirstChild("Spawn") or story1:FindFirstChild("spawn")
	if not spawnNode then
		for _, d in ipairs(story1:GetChildren()) do
			if string.lower(d.Name) == "spawn" then
				spawnNode = d
				break
			end
		end
	end
	if not spawnNode then
		return nil
	end

	if spawnNode:IsA("BasePart") then
		return spawnNode
	end
	-- Prefer a child literally named Spawn / a large pad part.
	local named = spawnNode:FindFirstChild("Spawn") or spawnNode:FindFirstChild("spawn")
	if named and named:IsA("BasePart") then
		return named
	end
	local best: BasePart? = nil
	local bestArea = -1
	for _, d in ipairs(spawnNode:GetDescendants()) do
		if d:IsA("BasePart") then
			local area = d.Size.X * d.Size.Z
			if area > bestArea then
				bestArea = area
				best = d
			end
		end
	end
	return best
end

local function cframeOnSpawnAnchor(anchor: BasePart, plot: Instance): CFrame
	-- World-space top of the pad (respects part rotation), then a small lift for HRP.
	local top = (anchor.CFrame * CFrame.new(0, anchor.Size.Y * 0.5, 0)).Position
	local face = flatLookFromPart(anchor)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }
	params.IgnoreWater = true

	local origin = top + Vector3.new(0, 12, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -48, 0), params)
	local standY = top.Y + SPAWN_CLEARANCE
	if hit and hit.Position.Y <= top.Y + 6 then
		standY = hit.Position.Y + SPAWN_CLEARANCE
	end

	local pos = Vector3.new(top.X, standY, top.Z)
	return CFrame.lookAt(pos, pos + face)
end

function PlotSpawnUtil.findFirstFloorSpawnCFrame(plot: Instance): CFrame?
	local anchor = PlotSpawnUtil.findPlotSpawnAnchor(plot)
	if anchor then
		return cframeOnSpawnAnchor(anchor, plot)
	end

	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil
	end

	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	local bboxRoot: Instance = if floor then floor else story1
	local minV, maxV = boundingBoxOf(bboxRoot)
	if not minV or not maxV then
		return nil
	end

	local face = Vector3.new(0, 0, -1)
	local posPart = PlotPaths.findSpawnAndBasesFolder()
	local slotId = plot:GetAttribute("PlotSlotId")
	if posPart and typeof(slotId) == "number" then
		local basePos = posPart:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
		if basePos and basePos:IsA("BasePart") then
			face = flatLookFromPart(basePos)
		end
	end

	return cfOnTopOfBounds(minV, maxV, face)
end

-- True when the plot has the real Spawn pad (full base), not just a stub floor.
function PlotSpawnUtil.plotHasSpawnPad(plot: Instance): boolean
	return PlotSpawnUtil.findPlotSpawnAnchor(plot) ~= nil
end

function PlotSpawnUtil.getPlotFloorBounds(plot: Instance): (Vector3?, Vector3?)
	local story1 = PlotPaths.firstStoryFolder(plot)
	if not story1 then
		return nil, nil
	end
	local padMin, padMax = groundPadBoundsOfStory(story1)
	if padMin and padMax then
		return padMin, padMax
	end
	local floor = story1:FindFirstChild("Floor") or story1:FindFirstChild("floor")
	local bboxRoot: Instance = if floor then floor else story1
	return boundingBoxOf(bboxRoot)
end

-- Full story-1 footprint for outlines (pavilion pillars, pad, etc.) — not just inner floor tiles.
function PlotSpawnUtil.getPlotOutlineBounds(plot: Instance): (Vector3?, Vector3?)
	local story1 = PlotPaths.firstStoryFolder(plot)
	local minV, maxV = anchorBoundsForPlot(plot)
	if story1 then
		local storyMin, storyMax = boundingBoxOf(story1)
		minV, maxV = unionBounds(minV, maxV, storyMin, storyMax)
		local padMin, padMax = groundPadBoundsOfStory(story1)
		minV, maxV = unionBounds(minV, maxV, padMin, padMax)
	end
	if minV and maxV then
		return minV, maxV
	end
	return PlotSpawnUtil.getPlotFloorBounds(plot)
end

-- Oriented box covering the whole story-1 base footprint (for SelectionBox outlines).
function PlotSpawnUtil.getPlotFloorOutlineCFrameSize(plot: Instance): (CFrame?, Vector3?)
	local minV, maxV = PlotSpawnUtil.getPlotOutlineBounds(plot)
	if not minV or not maxV then
		return nil, nil
	end
	local size = maxV - minV
	-- Tall enough that the perimeter reads as a 3D frame, not a flat ground decal.
	local height = math.clamp(math.max(size.Y, 12), 12, 20)
	local pad = 1.5
	local center = Vector3.new((minV.X + maxV.X) * 0.5, minV.Y + height * 0.5, (minV.Z + maxV.Z) * 0.5)

	local yaw = CFrame.new(center)
	local outX = math.max(size.X, 6) + pad * 2
	local outZ = math.max(size.Z, 6) + pad * 2
	local slotId = plot:GetAttribute("PlotSlotId")
	local posFolder = PlotPaths.findSpawnAndBasesFolder()
	if posFolder and typeof(slotId) == "number" then
		local anchor = posFolder:FindFirstChild("BasePOSPart" .. tostring(math.floor(slotId)))
		if anchor and anchor:IsA("BasePart") then
			local a = anchor :: BasePart
			outX = math.max(outX, a.Size.X + pad * 2)
			outZ = math.max(outZ, a.Size.Z + pad * 2)
			local flat = Vector3.new(a.CFrame.LookVector.X, 0, a.CFrame.LookVector.Z)
			if flat.Magnitude >= 0.08 then
				yaw = CFrame.lookAt(center, center + flat.Unit)
			else
				yaw = CFrame.new(center) * (a.CFrame - a.CFrame.Position)
			end
		end
	end

	return yaw, Vector3.new(outX, height, outZ)
end

local OUTLINE_PROXY_MAX_PARTS = 120

-- Gameplay / UI / brainrot content — never wrap these.
local OUTLINE_EXCLUDE_FOLDERS: { [string]: boolean } = {
	stands = true,
	["autocollect thing"] = true,
	plotusername = true,
	["upgrade/add"] = true,
	spawn = true,
	button = true,
	levelpanel = true,
	cash = true,
	gamepasshitbox = true,
	gamepasstext = true,
}

local function isUnderExcludedOutlineFolder(part: BasePart, plot: Instance): boolean
	local anc: Instance? = part
	while anc and anc ~= plot do
		if anc:IsA("Model") and anc:GetAttribute("BrainrotStandDisplay") == true then
			return true
		end
		local n = string.lower(anc.Name)
		if OUTLINE_EXCLUDE_FOLDERS[n] then
			return true
		end
		anc = anc.Parent
	end
	return false
end

local function shouldMirrorOutlinePart(part: BasePart, plot: Instance): boolean
	if part.Transparency >= 0.98 then
		return false
	end
	local vol = part.Size.X * part.Size.Y * part.Size.Z
	if vol < 0.05 then
		return false
	end
	local n = string.lower(part.Name)
	if string.find(n, "humanoid", 1, true) or n == "handle" or n == "rootpart" then
		return false
	end
	if isUnderExcludedOutlineFolder(part, plot) then
		return false
	end
	-- Whole story-1 pavilion (pillars/roof/floor), excluding stands/UI above.
	local story1 = PlotPaths.firstStoryFolder(plot)
	if story1 and part:IsDescendantOf(story1) then
		return true
	end
	local anc: Instance? = part.Parent
	while anc and anc ~= plot do
		local ln = string.lower(anc.Name)
		if string.find(ln, "story", 1, true) or ln == "floor" or ln == "other" or ln == "ladder" then
			return true
		end
		anc = anc.Parent
	end
	return false
end

-- Box proxies (not MeshPart clones): Highlight skips Transparency=1 and is flaky on meshes.
local function mirrorOutlinePartInto(model: Model, src: BasePart)
	local clone = Instance.new("Part")
	clone.Name = "OutlineProxy"
	clone.Shape = Enum.PartType.Block
	clone.Size = src.Size
	clone.CFrame = src.CFrame
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Massless = true
	clone.Material = Enum.Material.SmoothPlastic
	clone.Color = Color3.new(1, 1, 1)
	-- Near-invisible but Highlight still outlines (Transparency=1 is skipped by the engine).
	clone.Transparency = 0.99
	clone.Parent = model
end

local function appendFootprintFallback(model: Model, plot: Instance)
	local cf, size = PlotSpawnUtil.getPlotFloorOutlineCFrameSize(plot)
	if not cf or not size then
		return
	end
	local shell = Instance.new("Part")
	shell.Name = "OutlineFootprint"
	shell.Shape = Enum.PartType.Block
	shell.Size = size
	shell.CFrame = cf
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Massless = true
	shell.Material = Enum.Material.SmoothPlastic
	shell.Color = Color3.new(1, 1, 1)
	shell.Transparency = 0.99
	shell.Parent = model
end

local function outlineProxyFolder(): Folder
	local existing = Workspace:FindFirstChild("PlotOutlineProxies")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "PlotOutlineProxies"
	folder.Parent = Workspace
	return folder
end

-- Invisible structural proxies for Highlight adorn (does not wash live textures).
-- Parent under Workspace (never CurrentCamera — camera swaps destroy children).
function PlotSpawnUtil.buildInvisibleOutlineProxy(plot: Instance, parent: Instance?): Model?
	local model = Instance.new("Model")
	model.Name = "PlotOutlineHighlightProxy"

	local scored: { { part: BasePart, vol: number } } = {}
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and shouldMirrorOutlinePart(d, plot) then
			local p = d :: BasePart
			local vol = p.Size.X * p.Size.Y * p.Size.Z
			table.insert(scored, { part = p, vol = vol })
		end
	end
	table.sort(scored, function(a, b)
		return a.vol > b.vol
	end)

	local n = math.min(#scored, OUTLINE_PROXY_MAX_PARTS)
	for i = 1, n do
		mirrorOutlinePartInto(model, scored[i].part)
	end
	-- Always include the full footprint shell so something outlines even if story parts mismatch.
	appendFootprintFallback(model, plot)

	if #model:GetChildren() == 0 then
		model:Destroy()
		return nil
	end

	model.Parent = parent or outlineProxyFolder()
	return model
end

-- Random floor point on a plot, facing toward targetPos, at least minDist studs away (flat XZ).
function PlotSpawnUtil.pickRandomAmbushPositionOnPlot(
	plot: Instance,
	targetPos: Vector3,
	minDist: number,
	maxDist: number?,
	edgeMargin: number
): Vector3?
	local minV, maxV = PlotSpawnUtil.getPlotFloorBounds(plot)
	if not minV or not maxV then
		return nil
	end

	local spanX = maxV.X - minV.X - edgeMargin * 2
	local spanZ = maxV.Z - minV.Z - edgeMargin * 2
	if spanX < 4 or spanZ < 4 then
		return nil
	end

	local topY = maxV.Y + 2
	local targetFlat = Vector3.new(targetPos.X, topY, targetPos.Z)

	for _ = 1, 32 do
		local x = minV.X + edgeMargin + math.random() * spanX
		local z = minV.Z + edgeMargin + math.random() * spanZ
		local pos = Vector3.new(x, topY, z)
		local flatDist = (targetFlat - pos).Magnitude
		if flatDist >= minDist and (not maxDist or flatDist <= maxDist) then
			return pos
		end
	end

	local center = (minV + maxV) * 0.5
	local centerFlat = Vector3.new(center.X, topY, center.Z)
	local away = centerFlat - targetFlat
	if away.Magnitude < 0.1 then
		away = Vector3.new(1, 0, 0)
	else
		away = away.Unit * minDist
	end
	local fallback = targetFlat + away
	return Vector3.new(
		math.clamp(fallback.X, minV.X + edgeMargin, maxV.X - edgeMargin),
		topY,
		math.clamp(fallback.Z, minV.Z + edgeMargin, maxV.Z - edgeMargin)
	)
end

function PlotSpawnUtil.getAssignedPlotSpawnCFrame(player: Player): CFrame?
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot or not plot.Parent then
		return nil
	end
	return PlotSpawnUtil.findFirstFloorSpawnCFrame(plot)
end

function PlotSpawnUtil.teleportCharacterToCFrame(character: Model, spawnCf: CFrame)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = character:WaitForChild("HumanoidRootPart", 8) :: BasePart?
	end
	if not hrp then
		return false
	end

	-- Move via HRP so welded head-carries stay in the character assembly.
	-- Model:PivotTo can desync nested carry models after a long-distance teleport.
	hrp.CFrame = spawnCf
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	return true
end

-- Stream the destination, teleport, then re-apply for a short window so the
-- character doesn't fall through an unstreamed plot floor (tight client radii /
-- console streaming).
function PlotSpawnUtil.streamAndTeleportWithRetries(player: Player, character: Model, spawnCf: CFrame)
	if Workspace.StreamingEnabled then
		local ok, err = pcall(function()
			player:RequestStreamAroundAsync(spawnCf.Position, STREAM_RADIUS_SEC)
		end)
		if not ok then
			warn("[PlotSpawnUtil] RequestStreamAroundAsync failed:", err)
		end
	end

	PlotSpawnUtil.teleportCharacterToCFrame(character, spawnCf)

	task.spawn(function()
		for _ = 1, STREAM_RETRIES do
			task.wait(STREAM_RETRY_INTERVAL)
			if not player.Parent then
				return
			end
			local char = player.Character
			if not char or char ~= character or not char.Parent then
				return
			end
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				return
			end
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				local drift = (hrp.Position - spawnCf.Position).Magnitude
				local sunk = hrp.Position.Y < spawnCf.Position.Y - 6
				-- Still falling / slid far from spawn pad — snap again.
				if drift > 8 or sunk then
					if Workspace.StreamingEnabled and (drift > 20 or sunk) then
						pcall(function()
							player:RequestStreamAroundAsync(spawnCf.Position, STREAM_RADIUS_SEC)
						end)
					end
					PlotSpawnUtil.teleportCharacterToCFrame(char, spawnCf)
				elseif drift <= 8 then
					-- Settled near spawn; one final zero-velocity settle then stop.
					hrp.AssemblyLinearVelocity = Vector3.zero
					hrp.AssemblyAngularVelocity = Vector3.zero
					return
				end
			else
				PlotSpawnUtil.teleportCharacterToCFrame(char, spawnCf)
			end
		end
	end)
end

return PlotSpawnUtil
