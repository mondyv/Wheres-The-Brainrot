-- [ACTIVE] SpawnAreaWarmup
--[[
	Pre-stream ONLY a tight spawn radius during / after loading.

	Do NOT stream Lands / bushes / wilderness / red-wall rings here — that
	forced huge chunks of the map into client memory and caused lobby lag.
	Lands stream in naturally as the player approaches (requires StreamingEnabled).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local SpawnAreaWarmup = {}

local function streamAround(_player: Player, _position: Vector3)
	-- Custom spawn streaming is disabled (test Roblox defaults).
end

local function resolveAssignedPlot(player: Player, folder: Instance): Instance?
	local owned = PlotPaths.findPlotForAssignedSlot(player)
	if owned and owned.Parent then
		return owned
	end

	local userId = player.UserId
	local slot = player:GetAttribute("AssignedPlotSlot")
	if typeof(slot) == "number" then
		local bySlot = folder:FindFirstChild("Plot_" .. tostring(math.floor(slot)))
		if bySlot then
			return bySlot
		end
	end

	for _, plot in folder:GetChildren() do
		if plot:GetAttribute("PlotOwnerUserId") == userId then
			return plot
		end
	end
	return nil
end

function SpawnAreaWarmup.runAsync()
	SafezoneUtil.warmCacheAsync()
	SafezoneUtil.awaitCacheReady(30)

	local player = Players.LocalPlayer
	local char = player.Character or player.CharacterAdded:Wait()
	local hrp = char:WaitForChild("HumanoidRootPart", 15)

	-- Wait briefly for plot assignment so we stream the real destination, not default spawn.
	local deadline = os.clock() + 12
	while os.clock() < deadline do
		if typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
			break
		end
		task.wait(0.15)
	end

	local folder = PlotPaths.waitForSpawnAndBasesFolder(45)
	if folder then
		local plot = resolveAssignedPlot(player, folder)
		if plot then
			local ok, pivot = pcall(function()
				return plot:GetPivot()
			end)
			if ok and typeof(pivot) == "CFrame" then
				streamAround(player, (pivot :: CFrame).Position)
			end
			local story = PlotPaths.firstStoryFolder(plot)
			if story then
				local spawnAnchor = PlotSpawnUtil.findPlotSpawnAnchor(plot)
				if spawnAnchor then
					streamAround(player, spawnAnchor.Position)
				else
					local spawnNode = story:FindFirstChild("Spawn")
					if spawnNode and spawnNode:IsA("BasePart") then
						streamAround(player, spawnNode.Position)
					elseif spawnNode then
						local part = spawnNode:FindFirstChildWhichIsA("BasePart", true)
						if part then
							streamAround(player, part.Position)
						end
					end
				end
			end
			return
		end

		local okPivot, folderPivot = pcall(function()
			return folder:GetPivot()
		end)
		if okPivot and typeof(folderPivot) == "CFrame" then
			streamAround(player, (folderPivot :: CFrame).Position)
		end
	end

	-- Last resort: stream around current HRP (may still be default spawn).
	if hrp and hrp:IsA("BasePart") then
		streamAround(player, (hrp :: BasePart).Position)
	end
end

return SpawnAreaWarmup
