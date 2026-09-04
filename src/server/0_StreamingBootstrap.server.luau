-- [ACTIVE] 0_StreamingBootstrap.server
--[[
	Streaming must stay enabled. Radii and stream-out are set here on purpose
	so the live place cannot silently run Studio's 256/512 + LowMemory.

	Live always applies gameplay radii (192 / 512, mobile 128 / 400), opportunistic
	stream-out, predictive fill, and Integrity Disabled so swings are not empty.
	Grass park/restore is gated by StreamingSettings.CUSTOM_CULL_ENABLED (off).
	Studio play-solo does not override Workspace.
	Also publishes LandStreamCenters so clients can stream lands that are not in yet.
	Pins Map["Huge trees"] / Map.Vine (and borders) Persistent so swinging does not
	unload the forest. Never pins Map or Map.Lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

-- Map.Lands grass stays Default (too heavy to pin). The forest and vines sit
-- beside Lands — Map["Huge trees"], Map.Vine — so the land bubble never kept them.
local PERSIST_MAP_CHILD_KEYS: { [string]: boolean } = {
	hugetrees = true,
	vine = true,
	invisibleborders = true,
	landborders = true,
	landlocks = true,
	eventbillboard = true,
	spawntimers = true,
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

local function hookMapScenery(map: Instance)
	for _, child in map:GetChildren() do
		if PERSIST_MAP_CHILD_KEYS[persistKey(child.Name)] then
			persistContainer(child)
		end
	end
	map.ChildAdded:Connect(function(child)
		if PERSIST_MAP_CHILD_KEYS[persistKey(child.Name)] then
			persistContainer(child)
		end
	end)
end

task.spawn(function()
	local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 120)
	if not map then
		warn("[StreamingBootstrap] Workspace.Map missing — Huge trees / Vine persist skipped")
		return
	end
	hookMapScenery(map)
end)

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
