-- [ACTIVE] PlotPlayerSpawn.server
--[[
	Join / death CharacterAdded → same teleport as Return / safezone "Base".
	Single owner: PlotSpawnUtil.teleportPlayerHome (waits for real Spawn pad).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))

local function disableDefaultSpawnLocations()
	local function consider(inst: Instance)
		if not inst:IsA("SpawnLocation") then
			return
		end
		local inPlot = false
		local p: Instance? = inst.Parent
		while p and p ~= Workspace do
			local n = string.lower(p.Name)
			if n == "plots" or string.find(n, "plot", 1, true) then
				inPlot = true
				break
			end
			p = p.Parent
		end
		if not inPlot then
			inst.Enabled = false
			inst.Neutral = false
			inst.Duration = 0
		end
	end
	for _, d in Workspace:GetDescendants() do
		consider(d)
	end
end

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
		clearReviveSpawnAttrs(player)
		if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
			PlotSpawnUtil.teleportTutorialStart(player, character)
			return
		end
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
			if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
				return
			end
			local char = player.Character
			if char and typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
				task.defer(function()
					if char.Parent and player.Parent then
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

disableDefaultSpawnLocations()

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
