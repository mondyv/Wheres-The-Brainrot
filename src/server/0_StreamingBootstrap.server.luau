-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming custom cull / persist / radius overrides stay off.
	Publishes SafezoneBounds so lobby inventory still works if the hitbox
	streams out. Unreplicates a duplicate Brainrots catalog.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local StreamingSettings = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StreamingSettings"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

StreamingSettings.apply(Workspace)
SafezoneUtil.publishServerBounds()

-- Server has the full map. Clients often cannot find Land 2's center until it
-- streams in — chicken-and-egg. Attributes on ReplicatedStorage always replicate.
local function publishLandCenters()
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return
	end
	local positions: { [number]: Vector3 } = {}
	for _, child in lands:GetChildren() do
		local n = tonumber(string.match(child.Name, "^Land(%d+)$"))
		if n then
			local part: BasePart? = nil
			local island = child:FindFirstChild("Island") or child:FindFirstChild("island")
			if island and island:IsA("BasePart") then
				part = island
			elseif island then
				part = island:FindFirstChildWhichIsA("BasePart", true)
			end
			if not part and child:IsA("Model") then
				part = (child :: Model).PrimaryPart
			end
			if not part then
				part = child:FindFirstChildWhichIsA("BasePart", true)
			end
			if part then
				positions[n] = part.Position
			end
		end
	end
	if not next(positions) then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("LandStreamCenters")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "LandStreamCenters"
		for n, pos in positions do
			folder:SetAttribute("Land" .. tostring(n), pos)
		end
		folder.Parent = ReplicatedStorage
		return
	end
	for n, pos in positions do
		folder:SetAttribute("Land" .. tostring(n), pos)
	end
end

-- LandStreamCenters / tree persist disabled with custom streaming.

-- Folders cannot be Persistent. Pin vines (swing targets) and nearby Huge trees
-- (safezone forest). Far trees stay Default so they do not clog the join queue.
local PERSIST_EACH_CHILD_KEYS: { [string]: boolean } = {
	vine = true,
}
local PERSIST_MAP_CHILD_KEYS: { [string]: boolean } = {
	invisibleborders = true,
	landborders = true,
	eventbillboard = true,
	spawntimers = true,
}
-- Models only — wrapping SafeZoneHitbox / Spawn pads broke names last time.
local PERSIST_MODELS_ONLY_KEYS: { [string]: boolean } = {
	spawnandbases = true,
}

local function persistKey(name: string): string
	return (string.gsub(string.lower(name), "%s+", ""))
end

local function persistModel(model: Model)
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
end

local function persistLoosePart(part: BasePart)
	local parent = part.Parent
	if not parent then
		return
	end
	-- Land lock parts must keep their names as direct children of Land Locks.
	if parent.Name == "Land Locks" or string.match(part.Name, "^Land%s*%d+%s*Lock$") then
		return
	end
	if parent:IsA("Model") and parent.Name == "_SceneryPersist" then
		persistModel(parent)
		return
	end
	local wrap = Instance.new("Model")
	wrap.Name = "_SceneryPersist"
	pcall(function()
		wrap.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	wrap.Parent = parent
	part.Parent = wrap
end

-- Pin each tree/vine in place. Never Destroy the parent. Never Persistent the
-- parent that holds every tree (clients dropped that giant model).
local function instanceFocus(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	end
	if inst:IsA("Model") then
		local ok, pivot = pcall(function()
			return (inst :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot.Position
		end
		local part = (inst :: Model).PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part.Position
		end
	end
	return nil
end

local function publishTreeFocuses(hugeTrees: Instance)
	local points: { Vector3 } = {}
	for _, child in hugeTrees:GetChildren() do
		local pos = instanceFocus(child)
		if pos then
			table.insert(points, pos)
		end
	end
	if #points == 0 then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("TreeStreamFocuses")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TreeStreamFocuses"
	end
	-- Spread samples across the forest so join can RequestStreamAroundAsync
	-- before any Bent_tree instance exists on the client.
	local want = math.min(32, #points)
	local step = math.max(1, math.floor(#points / want))
	local n = 0
	for i = 1, #points, step do
		n += 1
		folder:SetAttribute("P" .. tostring(n), points[i])
		if n >= want then
			break
		end
	end
	folder:SetAttribute("Count", n)
	if folder.Parent ~= ReplicatedStorage then
		folder.Parent = ReplicatedStorage
	end
end

local SPAWN_TREE_RADIUS = 850

local function homePosition(map: Instance): Vector3?
	local lands = map:FindFirstChild("Lands")
	if lands then
		local land1 = lands:FindFirstChild("Land1") or lands:FindFirstChild("Land 1")
		if land1 then
			local pos = instanceFocus(land1)
			if pos then
				return pos
			end
		end
	end
	local sab = map:FindFirstChild("Spawn And Bases")
	if sab then
		return instanceFocus(sab)
	end
	return nil
end

local function persistNearbyTrees(container: Instance, home: Vector3?)
	local function apply(child: Instance)
		if child:IsA("Model") then
			local pos = instanceFocus(child)
			if home and pos and (pos - home).Magnitude > SPAWN_TREE_RADIUS then
				return
			end
			persistModel(child)
		elseif child:IsA("BasePart") then
			if home and (child.Position - home).Magnitude > SPAWN_TREE_RADIUS then
				return
			end
			persistLoosePart(child)
		end
	end
	for _, child in container:GetChildren() do
		apply(child)
	end
	container.ChildAdded:Connect(apply)
end

local function persistEachChild(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Model") then
			persistModel(child)
		elseif child:IsA("BasePart") then
			persistLoosePart(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			persistModel(child)
		elseif child:IsA("BasePart") then
			persistLoosePart(child)
		end
	end)
end

local function persistContainer(container: Instance)
	if container:IsA("Model") then
		persistModel(container)
	end
	for _, child in container:GetChildren() do
		if child:IsA("Model") then
			persistModel(child)
		elseif child:IsA("BasePart") then
			persistLoosePart(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			persistModel(child)
		elseif child:IsA("BasePart") then
			persistLoosePart(child)
		end
	end)
end

local function persistModelsOnly(container: Instance)
	if container:IsA("Model") then
		persistModel(container)
	end
	for _, child in container:GetChildren() do
		if child:IsA("Model") then
			persistModel(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			persistModel(child)
		end
	end)
end

local function landNumberFromName(name: string): number?
	local n = tonumber(string.match(name, "^Land(%d+)$"))
	if n then
		return n
	end
	return tonumber(string.match(name, "^Land%s*(%d+)$"))
end

local function persistLandOne(lands: Instance)
	for _, child in lands:GetChildren() do
		if landNumberFromName(child.Name) == 1 then
			persistModelsOnly(child)
		end
	end
	lands.ChildAdded:Connect(function(child)
		if landNumberFromName(child.Name) == 1 then
			persistModelsOnly(child)
		end
	end)
end

local function hookMapScenery(map: Instance)
	for _, child in map:GetChildren() do
		local key = persistKey(child.Name)
		if key == "hugetrees" then
			persistNearbyTrees(child, homePosition(map))
			publishTreeFocuses(child)
		elseif PERSIST_EACH_CHILD_KEYS[key] then
			persistEachChild(child)
		elseif PERSIST_MAP_CHILD_KEYS[key] then
			persistContainer(child)
		elseif PERSIST_MODELS_ONLY_KEYS[key] then
			persistModelsOnly(child)
		elseif key == "lands" then
			persistLandOne(child)
		end
	end
	map.ChildAdded:Connect(function(child)
		local key = persistKey(child.Name)
		if key == "hugetrees" then
			persistNearbyTrees(child, homePosition(map))
			publishTreeFocuses(child)
		elseif PERSIST_EACH_CHILD_KEYS[key] then
			persistEachChild(child)
		elseif PERSIST_MAP_CHILD_KEYS[key] then
			persistContainer(child)
		elseif PERSIST_MODELS_ONLY_KEYS[key] then
			persistModelsOnly(child)
		elseif key == "lands" then
			persistLandOne(child)
		end
	end)
end

local mapSceneryHooked = false
local function hookMapSceneryOnce(map: Instance)
	if mapSceneryHooked then
		return
	end
	mapSceneryHooked = true
	hookMapScenery(map)
	local locks = map:FindFirstChild("Land Locks")
	if locks then
		for _, child in locks:GetChildren() do
			if child:IsA("Model") and child.Name == "_SceneryPersist" then
				for _, inner in child:GetChildren() do
					inner.Parent = locks
				end
				child:Destroy()
			end
		end
	end
end

-- Custom tree persist / scenery pinning is disabled so Roblox default
-- streaming can be tested without our join-queue or Atomic/Persistent pins.

-- Legacy place files kept the whole Brainrots mesh catalog in ReplicatedStorage.
-- Every client (and Studio play-solo) then holds a second copy of every model.
-- Templates are server-only; move/destroy the replicated duplicate immediately.
local function folderHasMeshCatalog(folder: Instance): boolean
	return folder:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function unreplicateBrainrotsCatalog()
	local rs = ReplicatedStorage:FindFirstChild("Brainrots")
	if not rs or not rs:IsA("Folder") then
		return
	end
	local ss = ServerStorage:FindFirstChild("Brainrots")
	-- Rojo can ship an empty ServerStorage.Brainrots. Never destroy the live
	-- ReplicatedStorage catalog unless ServerStorage already has the meshes.
	if ss and ss:IsA("Folder") and folderHasMeshCatalog(ss) then
		rs:Destroy()
	end
end

unreplicateBrainrotsCatalog()
task.defer(unreplicateBrainrotsCatalog)
