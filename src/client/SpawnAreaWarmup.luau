-- [ACTIVE] SpawnAreaWarmup
--[[
	Pre-stream ONLY a tight spawn radius during loading.

	Do NOT stream Lands / bushes / wilderness / red-wall rings here — that
	forced huge chunks of the map into client memory and caused lobby lag.
	Lands stream in naturally as the player approaches (requires StreamingEnabled).
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

	-- Only the player's assigned plot — not every plot / red wall sample.
	local folder = PlotPaths.waitForSpawnAndBasesFolder(45)
	if folder then
		local okPivot, folderPivot = pcall(function()
			return folder:GetPivot()
		end)
		if okPivot and typeof(folderPivot) == "CFrame" then
			streamAround((folderPivot :: CFrame).Position)
		end

		local userId = player.UserId
		for _, plot in folder:GetChildren() do
			if plot:GetAttribute("OwnerUserId") == userId or plot:GetAttribute("AssignedUserId") == userId then
				local ok, pivot = pcall(function()
					return plot:GetPivot()
				end)
				if ok and typeof(pivot) == "CFrame" then
					streamAround((pivot :: CFrame).Position)
				end
				break
			end
		end
	end
end

return SpawnAreaWarmup
