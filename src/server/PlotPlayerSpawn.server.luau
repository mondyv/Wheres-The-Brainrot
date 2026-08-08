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

local ASSIGN_WAIT_SEC = 60

local function waitForAssignedPlot(player: Player, character: Model): Instance?
	local deadline = os.clock() + ASSIGN_WAIT_SEC
	local fallback: Instance? = nil
	while os.clock() < deadline do
		if not character.Parent or not player.Parent then
			return nil
		end
		-- Wait until the plot spawner has reserved a slot for this player.
		if typeof(player:GetAttribute("AssignedPlotSlot")) ~= "number" then
			task.wait(0.15)
			continue
		end
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot and plot.Parent then
			fallback = plot
			-- Wait for the real Spawn pad (full base), not a stub floor fallback.
			if PlotPaths.isSpawnReadyPlot(plot) and PlotSpawnUtil.plotHasSpawnPad(plot) then
				return plot
			end
		end
		task.wait(0.15)
	end
	local last = fallback or PlotPaths.findPlotForAssignedSlot(player)
	if last and PlotPaths.isSpawnReadyPlot(last) then
		return last
	end
	return last
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
		-- Keep attrs longer so late AssignedPlotSlot hooks don't yank soft-respawn off QuestHitbox.
		PlotSpawnUtil.streamAndTeleportWithRetries(player, character, reviveCf)
		task.delay(6, function()
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
		warn(
			"[PlotPlayerSpawn] No assigned plot for",
			player.Name,
			"(AssignedPlotSlot=",
			player:GetAttribute("AssignedPlotSlot"),
			")"
		)
		return
	end

	-- Same pad as ReturnTeleport (first-floor plot spawn).
	local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
		or PlotSpawnUtil.findFirstFloorSpawnCFrame(plot)
	if not spawnCf then
		warn("[PlotPlayerSpawn] No Spawn/floor CFrame on plot for", player.Name)
		return
	end

	PlotSpawnUtil.streamAndTeleportWithRetries(player, character, spawnCf)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		-- Wait for HRP so the first teleport isn't dropped.
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
