-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Publishes SafezoneBounds so lobby inventory still works if the hitbox
	streams out. Unreplicates a duplicate Brainrots catalog.
	Pins spawn vines so the first swing has latch targets.
	Does not stream, persist, or Atomic Huge trees — Studio radii own that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

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

-- LandStreamCenters always publish so later islands can stream before they exist.
-- Folders cannot be Persistent. Pin nearby vines (swing targets) only.
local PERSIST_NEAR_SPAWN_KEYS: { [string]: boolean } = {
	vine = true,
}

local function persistKey(name: string): string
	return (string.gsub(string.lower(name), "%s+", ""))
end

local function persistModel(model: Model)
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
end

local function defaultModel(model: Model)
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Default
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

-- Pin nearby vines in place. Never Destroy the parent folder.
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

local SPAWN_VINE_RADIUS = 320

local function homePosition(map: Instance): Vector3?
	local sab = map:FindFirstChild("Spawn And Bases")
	if sab then
		for _, name in { "SafeZoneHitbox", "SafezoneHitbox" } do
			local hit = sab:FindFirstChild(name)
			if hit and hit:IsA("BasePart") then
				return hit.Position
			end
		end
		local pos = instanceFocus(sab)
		if pos then
			return pos
		end
	end
	local lands = map:FindFirstChild("Lands")
	if lands then
		local land1 = lands:FindFirstChild("Land1") or lands:FindFirstChild("Land 1")
		if land1 then
			return instanceFocus(land1)
		end
	end
	return nil
end

local function persistNearbyVines(container: Instance, home: Vector3?)
	if not home then
		return
	end
	local function apply(child: Instance)
		if child:IsA("Model") then
			local pos = instanceFocus(child)
			if not pos or (pos - home).Magnitude > SPAWN_VINE_RADIUS then
				return
			end
			persistModel(child)
		elseif child:IsA("BasePart") then
			if (child.Position - home).Magnitude > SPAWN_VINE_RADIUS then
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

-- Undo Persistent/Atomic leftovers from older builds so StreamingMinRadius can fill trees.
local function releaseHugeTrees(container: Instance)
	local wraps: { Model } = {}
	for _, desc in container:GetDescendants() do
		if desc:IsA("Model") and desc.Name == "_SceneryPersist" then
			table.insert(wraps, desc)
		end
	end
	for _, wrap in wraps do
		local parent = wrap.Parent
		if parent then
			for _, inner in wrap:GetChildren() do
				inner.Parent = parent
			end
		end
		wrap:Destroy()
	end
	if container:IsA("Model") then
		defaultModel(container)
	end
	for _, desc in container:GetDescendants() do
		if desc:IsA("Model") then
			defaultModel(desc)
		end
	end
end

local function hookJoinSwingScenery(map: Instance)
	local home = homePosition(map)
	local leftoverFocuses = ReplicatedStorage:FindFirstChild("TreeStreamFocuses")
	if leftoverFocuses then
		leftoverFocuses:Destroy()
	end
	local function apply(child: Instance)
		local key = persistKey(child.Name)
		if PERSIST_NEAR_SPAWN_KEYS[key] then
			persistNearbyVines(child, home)
			return
		end
		if key == "hugetrees" then
			releaseHugeTrees(child)
		end
	end
	for _, child in map:GetChildren() do
		apply(child)
	end
	map.ChildAdded:Connect(apply)
end

local mapSceneryHooked = false
local function hookMapSceneryOnce(map: Instance)
	if mapSceneryHooked then
		return
	end
	mapSceneryHooked = true
	hookJoinSwingScenery(map)
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

task.spawn(function()
	local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 120)
	if not map then
		return
	end
	if not map:FindFirstChild("Spawn And Bases") then
		map:WaitForChild("Spawn And Bases", 30)
	end
	publishLandCenters()
	hookMapSceneryOnce(map)
	map.ChildAdded:Connect(function(child)
		if child.Name == "Lands" then
			publishLandCenters()
		end
	end)
end)
