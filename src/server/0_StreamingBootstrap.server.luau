-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming must stay enabled. Radii and stream-out are set here on purpose
	so the live place cannot silently run Studio's 256/512 + LowMemory.

	Live always applies gameplay radii (2048 / 4096), LowMemory stream-out,
	Grass park/restore is gated by StreamingSettings.CUSTOM_CULL_ENABLED (off).
	Studio play-solo does not override Workspace.
	Also publishes LandStreamCenters so clients can stream lands that are not in yet.
	Does not Persistent-pin the whole forest — that queued every tree mesh at
	join, so they only popped in after a long load. Each Huge trees child is
	Atomic; clients RequestStreamAroundAsync published tree focuses on join.
	Vines stay Persistent (swing targets). Never pins Land 2–10 or Land Locks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local StreamingSettings = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StreamingSettings"))

StreamingSettings.apply(Workspace)

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

publishLandCenters()
task.spawn(function()
	local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 60)
	if not map then
		return
	end
	if not map:FindFirstChild("Lands") then
		map:WaitForChild("Lands", 30)
	end
	publishLandCenters()
end)

-- Folders cannot be Persistent. Pin each vine child (swing targets).
-- Huge trees stay Atomic + join stream-requests — persist-all delayed every tree.
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

local function markForestAtomic(container: Instance)
	local wraps: { Model } = {}
	for _, child in container:GetChildren() do
		if child:IsA("Model") and child.Name == "_SceneryPersist" then
			table.insert(wraps, child)
		end
	end
	for _, wrap in wraps do
		for _, inner in wrap:GetChildren() do
			inner.Parent = container
		end
		wrap:Destroy()
	end
	local function apply(child: Instance)
		if child:IsA("Model") then
			pcall(function()
				child.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
			end)
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
			markForestAtomic(child)
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
			markForestAtomic(child)
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

-- Pin trees before the first player replicates, not after a deferred wait.
if not RunService:IsStudio() then
	local mapNow = Workspace:FindFirstChild("Map")
	if mapNow then
		hookMapSceneryOnce(mapNow)
	else
		task.spawn(function()
			local map = Workspace:WaitForChild("Map", 120)
			if map then
				hookMapSceneryOnce(map)
			else
				warn("[StreamingBootstrap] Workspace.Map missing — Huge trees / Vine persist skipped")
			end
		end)
	end
end

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
