-- [ACTIVE] PlotPlayerSpawn.server
--[[
	Join / death CharacterAdded → same teleport as Return / safezone "Base".
	Single owner: PlotSpawnUtil.teleportPlayerHome (waits for real Spawn pad).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local function clearReviveSpawnAttrs(player: Player)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, nil)
	player:SetAttribute(ReviveConfig.WAVE_WEB_DEATH_ATTR, nil)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		local hrp = character:FindFirstChild("HumanoidRootPart")
			or character:WaitForChild("HumanoidRootPart", 8)
		if not hrp or not character.Parent or not player.Parent then
			return
		end
		-- Soft-respawn pins are ignored — always the Base / Return pad.
		clearReviveSpawnAttrs(player)
		PlotSpawnUtil.teleportPlayerHome(player, character)
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
						-- Plot finished promoting — snap home if still waiting / misplaced.
						PlotSpawnUtil.teleportPlayerHome(player, char, 20)
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
