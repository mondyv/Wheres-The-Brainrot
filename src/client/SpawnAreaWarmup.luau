-- [ACTIVE] SpawnAreaWarmup
--[[
	Pre-stream ONLY the spawn/safezone during loading.

	Do NOT stream Lands / bushes / wilderness here — that forced the whole map
	into client memory (~2.5GB) and caused constant lag even in the lobby.
	Lands stream in naturally as the player approaches.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

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
	-- Keep tight — just enough for base + red wall approach.
	local radii = { 50, 90 }
	for _, radius in radii do
		for step = 0, 5 do
			local angle = (step / 6) * math.pi * 2
			streamAround(center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
		end
		task.wait()
	end
end

local function streamRedWallEdges(spawnCenter: Vector3)
	local wallPoints = SafezoneUtil.getRedWallSamplePositions()
	if #wallPoints == 0 then
		return
	end
	for _, wallPos in wallPoints do
		streamAround(wallPos)
		local away = wallPos - spawnCenter
		if away.Magnitude > 4 then
			streamAround(wallPos + away.Unit * 40)
		end
		task.wait()
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
			if i % 3 == 0 then
				task.wait()
			end
		end
	end

	SafezoneUtil.awaitCacheReady(5)
	SafezoneUtil.warmCacheAsync()
	task.wait(0.1)
	streamRedWallEdges(center)
end

return SpawnAreaWarmup
