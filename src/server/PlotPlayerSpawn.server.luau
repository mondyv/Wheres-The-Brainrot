-- [ACTIVE] PlotPlayerSpawn.server
--[[
	PlotPlayerSpawn (server)
	Join / respawn → same plot Spawn pad as the safezone "Base" button.
	When FAST_RESPAWN_ALL_DEATHS is on, always use Base (ignore QuestHitbox soft pins
	that fight PlotPlayerSpawn vs ReviveService).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local ASSIGN_WAIT_SEC = 60

local function clearReviveSpawnAttrs(player: Player)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, nil)
	player:SetAttribute(ReviveConfig.WAVE_WEB_DEATH_ATTR, nil)
end

local function readReviveCFrame(player: Player): CFrame?
	local posAttr = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR)
	local lookAttr = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR)
	local legacyCf = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR)

	if typeof(posAttr) == "Vector3" then
		local look = if typeof(lookAttr) == "Vector3" then lookAttr else Vector3.new(0, 0, -1)
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.08 then
			flat = Vector3.new(0, 0, -1)
		else
			flat = flat.Unit
		end
		return CFrame.lookAt(posAttr, posAttr + flat)
	end
	if typeof(legacyCf) == "CFrame" then
		return legacyCf
	end
	return nil
end

-- Same destination the Base top-button uses — prefer an immediate pad CF.
local function waitForBaseSpawnCFrame(player: Player, character: Model): CFrame?
	-- Fast path: already have the same CF Return / Base button use.
	local ready = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
	if ready then
		return ready
	end

	local deadline = os.clock() + ASSIGN_WAIT_SEC
	while os.clock() < deadline do
		if not character.Parent or not player.Parent then
			return nil
		end
		if typeof(player:GetAttribute("AssignedPlotSlot")) ~= "number" then
			task.wait(0.15)
			continue
		end
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot and plot.Parent then
			local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
			if spawnCf then
				return spawnCf
			end
		end
		task.wait(0.15)
	end
	return PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
end

local function teleportToPlotSpawn(player: Player, character: Model)
	local baseCf = waitForBaseSpawnCFrame(player, character)

	-- Fast soft-respawn mode: always Base button pad (one owner for join/death spawn).
	if ReviveConfig.FAST_RESPAWN_ALL_DEATHS then
		clearReviveSpawnAttrs(player)
		if not baseCf then
			warn(
				"[PlotPlayerSpawn] No Base spawn for",
				player.Name,
				"(AssignedPlotSlot=",
				player:GetAttribute("AssignedPlotSlot"),
				")"
			)
			return
		end
		PlotSpawnUtil.streamAndTeleportWithRetries(player, character, baseCf, true)
		return
	end

	local reviveCf = readReviveCFrame(player)

	-- Soft-respawn pin — only if it isn't clearly under the plot pad.
	if reviveCf and baseCf then
		if reviveCf.Position.Y < baseCf.Position.Y - 10 then
			clearReviveSpawnAttrs(player)
			reviveCf = nil
		end
	elseif reviveCf and not baseCf then
		if reviveCf.Position.Y < 1 then
			clearReviveSpawnAttrs(player)
			reviveCf = nil
		end
	end

	if reviveCf then
		local targetPos = reviveCf.Position
		PlotSpawnUtil.streamAndTeleportWithRetries(player, character, reviveCf)
		task.delay(6, function()
			if not player.Parent then
				return
			end
			local stillPos = player:GetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR)
			if typeof(stillPos) == "Vector3" and (stillPos - targetPos).Magnitude < 1 then
				clearReviveSpawnAttrs(player)
			end
		end)
		return
	end

	if not baseCf then
		warn(
			"[PlotPlayerSpawn] No Base spawn for",
			player.Name,
			"(AssignedPlotSlot=",
			player:GetAttribute("AssignedPlotSlot"),
			")"
		)
		return
	end

	-- Identical path to SafezoneQuickNav "Base".
	PlotSpawnUtil.streamAndTeleportWithRetries(player, character, baseCf, true)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		local hrp = character:FindFirstChild("HumanoidRootPart")
			or character:WaitForChild("HumanoidRootPart", 8)
		if not hrp or not character.Parent or not player.Parent then
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
			if char and typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
				task.defer(function()
					if char.Parent and player.Parent then
						teleportToPlotSpawn(player, char)
					end
				end)
			end
		end),
	}
	if player.Character then
		onCharacter(player, player.Character)
	end
end

Players.PlayerAdded:Connect(hookPlayer)
for _, plr in Players:GetPlayers() do
	hookPlayer(plr)
end

Players.PlayerRemoving:Connect(function(player)
	local conns = playerConns[player]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		playerConns[player] = nil
	end
end)
