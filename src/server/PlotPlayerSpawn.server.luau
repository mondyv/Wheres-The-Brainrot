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
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

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

local function stillThisCharacter(player: Player, character: Model, hrp: Instance?): boolean
	return player.Parent ~= nil
		and character.Parent ~= nil
		and player.Character == character
		and (hrp == nil or hrp.Parent ~= nil)
end

local function onCharacter(player: Player, character: Model)
	task.spawn(function()
		local hrp = character:FindFirstChild("HumanoidRootPart")
			or character:WaitForChild("HumanoidRootPart", 8)
		if not hrp or not character.Parent or not player.Parent then
			return
		end
		-- Hold still at the default spawn until we know tutorial vs Base pad.
		-- Never unanchor here — that dumps people on the Roblox baseplate.
		hrp.Anchored = true
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		clearReviveSpawnAttrs(player)

		-- Wait for save data so returning players don't get the tutorial hitbox.
		-- Never unanchor on a failed/slow load — that dumps them on the baseplate.
		local loaded = false
		task.spawn(function()
			loaded = PlayerDataService.waitUntilLoaded(player) == true
		end)
		local loadDeadline = os.clock() + 20
		while os.clock() < loadDeadline do
			if not stillThisCharacter(player, character, hrp) then
				return
			end
			if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) == true or loaded then
				break
			end
			task.wait(0.1)
		end
		if not stillThisCharacter(player, character, hrp) then
			return
		end

		local deadline = os.clock() + 45
		local firstTry = true
		while stillThisCharacter(player, character, hrp) and os.clock() < deadline do
			if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
				if PlotSpawnUtil.teleportTutorialStart(player, character, if firstTry then 12 else 0.4) then
					return
				end
			else
				if PlotSpawnUtil.teleportPlayerHome(player, character, if firstTry then 2 else 0.4) then
					return
				end
			end
			firstTry = false
			task.wait(0.25)
		end
		if not stillThisCharacter(player, character, hrp) then
			return
		end
		-- Last try: tutorial hitbox vs plot. Stay anchored if both fail.
		if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
			PlotSpawnUtil.teleportTutorialStart(player, character, 8)
		else
			PlotSpawnUtil.teleportPlayerHome(player, character, 8)
		end
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
