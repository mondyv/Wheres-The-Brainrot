-- [ACTIVE] PlotPlayerSpawn.server
--[[
	PlotPlayerSpawn (server)
	Teleports players onto their assigned plot's first floor on join and respawn.
	Streams the destination first and retries briefly so tight Streaming radii
	don't drop the character through an unstreamed floor.
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
			-- Prefer a plot that already has a Story/Spawn so we don't teleport onto air.
			local spawnCf = PlotSpawnUtil.findFirstFloorSpawnCFrame(plot)
			if spawnCf then
				return plot
			end
		end
		task.wait(0.1)
	end
	return PlotPaths.findPlotForAssignedSlot(player)
end

local function teleportToPlotSpawn(player: Player, character: Model)
	local posAttr = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR)
	local lookAttr = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR)
	local legacyCf = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR)

	local reviveCf: CFrame? = nil
	if typeof(posAttr) == "Vector3" then
		local look = if typeof(lookAttr) == "Vector3" then lookAttr else Vector3.new(0, 0, -1)
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.08 then
			flat = Vector3.new(0, 0, -1)
		else
			flat = flat.Unit
		end
		reviveCf = CFrame.lookAt(posAttr, posAttr + flat)
	elseif typeof(legacyCf) == "CFrame" then
		reviveCf = legacyCf
	end

	if reviveCf then
		local targetPos = reviveCf.Position
		-- Keep attrs briefly so late plot hooks don't overwrite the land revive.
		PlotSpawnUtil.streamAndTeleportWithRetries(player, character, reviveCf)
		task.delay(2.5, function()
			if not player.Parent then
				return
			end
			local stillPos = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR)
			if typeof(stillPos) == "Vector3" and (stillPos - targetPos).Magnitude < 1 then
				player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
				player:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, nil)
				player:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, nil)
			end
		end)
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

	PlotSpawnUtil.streamAndTeleportWithRetries(player, character, spawnCf)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		-- Brief yield so HumanoidRootPart exists; streaming retry handles the rest.
		task.wait(0.05)
		if not character.Parent or not player.Parent then
			return
		end
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
