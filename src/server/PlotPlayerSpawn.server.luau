-- [ACTIVE] PlotPlayerSpawn.server
--[[
	PlotPlayerSpawn (server)
	Teleports players onto their assigned plot's first floor on join and respawn.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local ASSIGN_WAIT_SEC = 20

local function waitForAssignedPlot(player: Player, character: Model): Instance?
	local deadline = os.clock() + ASSIGN_WAIT_SEC
	while os.clock() < deadline do
		if not character.Parent or not player.Parent then
			return nil
		end
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot and plot.Parent then
			return plot
		end
		task.wait(0.1)
	end
	return PlotPaths.findPlotForAssignedSlot(player)
end

local function teleportToPlotSpawn(player: Player, character: Model)
	local reviveCf = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR)
	if typeof(reviveCf) == "CFrame" then
		player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
		PlotSpawnUtil.teleportCharacterToCFrame(character, reviveCf)
		return
	end

	local plot = waitForAssignedPlot(player, character)
	if not plot or not plot.Parent then
		return
	end

	local spawnCf = PlotSpawnUtil.findFirstFloorSpawnCFrame(plot)
	if not spawnCf then
		return
	end

	PlotSpawnUtil.teleportCharacterToCFrame(character, spawnCf)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		task.wait(0.05)
		teleportToPlotSpawn(player, character)
	end)
end

local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function hookPlayer(player: Player)
	if playerConns[player] then
		return
	end
	playerConns[player] = {
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end),
		player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
			local char = player.Character
			if char then
				task.defer(function()
					teleportToPlotSpawn(player, char)
				end)
			end
		end),
	}
	if player.Character then
		onCharacter(player, player.Character)
	end
end

for _, player in Players:GetPlayers() do
	hookPlayer(player)
end
Players.PlayerAdded:Connect(hookPlayer)

Players.PlayerRemoving:Connect(function(player)
	local conns = playerConns[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		playerConns[player] = nil
	end
end)
