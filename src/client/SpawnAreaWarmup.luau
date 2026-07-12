-- [ACTIVE] SpawnAreaWarmup
--[[
	Pre-stream Spawn And Bases + safezone parts during the loading screen so the first
	red-wall crossing does not hitch on one-time stand / plot / zone setup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Players = game:GetService("Players")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))

local SpawnAreaWarmup = {}

local function streamAround(position: Vector3)
	if not Workspace.StreamingEnabled then
		return
	end
	pcall(function()
		Workspace:RequestStreamAroundAsync(position)
	end)
end

local function streamRing(center: Vector3)
	local radii = { 70, 130, 190 }
	for _, radius in radii do
		for step = 0, 7 do
			local angle = (step / 8) * math.pi * 2
			streamAround(center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
		end
		task.wait()
	end
end

local function streamBeyondRedWalls(spawnCenter: Vector3)
	local wallPoints = SafezoneUtil.getRedWallSamplePositions()
	if #wallPoints == 0 then
		return
	end

	for _, wallPos in wallPoints do
		streamAround(wallPos)
		local away = wallPos - spawnCenter
		if away.Magnitude > 4 then
			local dir = away.Unit
			for _, dist in { 35, 75, 120, 180, 250 } do
				streamAround(wallPos + dir * dist)
			end
		else
			for _, offset in {
				Vector3.new(80, 0, 0),
				Vector3.new(-80, 0, 0),
				Vector3.new(0, 0, 80),
				Vector3.new(0, 0, -80),
			} do
				streamAround(wallPos + offset)
			end
		end
		task.wait()
	end
end

local function streamLandPivots()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local lands = map:FindFirstChild("Lands")
	if not lands then
		return
	end

	for _, child in lands:GetChildren() do
		if child:IsA("Model") or child:IsA("Folder") then
			local ok, pivot = pcall(function()
				return child:GetPivot()
			end)
			if ok and typeof(pivot) == "CFrame" then
				streamAround((pivot :: CFrame).Position)
			end
		end
		task.wait()
	end
end

local function streamNamedMapRoots(map: Instance)
	local names = { "Tycoon", "Lands", "Webs" }
	for _, name in names do
		local root = map:FindFirstChild(name)
		if not root then
			continue
		end
		local ok, pivot = pcall(function()
			return root:GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			local center = (pivot :: CFrame).Position
			streamAround(center)
			for _, dist in { 55, 110, 170, 240 } do
				for step = 0, 5 do
					local angle = (step / 6) * math.pi * 2
					streamAround(center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
				end
				task.wait()
			end
		end
	end
end

-- Walk the map tree with GetChildren only (never GetDescendants) and pre-stream bush folders + land chunks.
local function streamMapWilderness(map: Instance)
	local stack = { map }
	local visited = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		for _, child in inst:GetChildren() do
			if child:IsA("Folder") and BushRootUtil.isBushFolderName(child.Name) then
				local ok, pivot = pcall(function()
					return child:GetPivot()
				end)
				if ok and typeof(pivot) == "CFrame" then
					streamAround((pivot :: CFrame).Position)
				end
				task.wait()
			elseif child:IsA("Folder") or child:IsA("Model") then
				table.insert(stack, child)
			end
			visited += 1
			if visited % 120 == 0 then
				task.wait()
			end
		end
	end
end

function SpawnAreaWarmup.runAsync()
	SafezoneUtil.warmCacheAsync()
	SafezoneUtil.awaitCacheReady(30)

	local player = Players.LocalPlayer
	local char = player.Character or player.CharacterAdded:Wait()
	local hrp = char:WaitForChild("HumanoidRootPart", 15)
	local center = if hrp and hrp:IsA("BasePart") then (hrp :: BasePart).Position else Vector3.zero
	if hrp and hrp:IsA("BasePart") then
		streamAround(center)
	end

	local map = Workspace:WaitForChild("Map", 45)
	if map then
		streamNamedMapRoots(map)
		local lands = map:FindFirstChild("Lands")
		if not lands then
			lands = map:WaitForChild("Lands", 20)
		end
		if lands then
			local ok, pivot = pcall(function()
				return lands:GetPivot()
			end)
			if ok and typeof(pivot) == "CFrame" then
				streamAround((pivot :: CFrame).Position)
			end
		end
	end

	streamRing(center)

	local folder = PlotPaths.waitForSpawnAndBasesFolder(45)
	if folder then
		local okPivot, folderPivot = pcall(function()
			return folder:GetPivot()
		end)
		if okPivot and typeof(folderPivot) == "CFrame" then
			streamAround((folderPivot :: CFrame).Position)
		end

		local children = folder:GetChildren()
		for i, plot in ipairs(children) do
			if plot:IsA("Model") or plot:IsA("BasePart") or plot:IsA("Folder") then
				local ok, pivot = pcall(function()
					return plot:GetPivot()
				end)
				if ok and typeof(pivot) == "CFrame" then
					streamAround((pivot :: CFrame).Position)
				end
			end
			if i % 2 == 0 then
				task.wait()
			end
		end
	end

	SafezoneUtil.awaitCacheReady(5)
	SafezoneUtil.warmCacheAsync()
	task.wait(0.15)
	SafezoneUtil.awaitCacheReady(3)
	streamBeyondRedWalls(center)
	streamLandPivots()
	if map then
		streamMapWilderness(map)
	end
end

return SpawnAreaWarmup
