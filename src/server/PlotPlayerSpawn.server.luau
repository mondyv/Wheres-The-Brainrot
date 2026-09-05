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

local function disableSpawnLocation(inst: Instance)
	if not inst:IsA("SpawnLocation") then
		return
	end
	-- Roblox LoadCharacter picks a random Enabled/Neutral pad. Plot pads must stay
	-- Disabled too — otherwise join dumps you on someone else's base.
	inst.Enabled = false
	inst.Neutral = false
	inst.Duration = 0
end

local function disableDefaultSpawnLocations()
	for _, d in Workspace:GetDescendants() do
		disableSpawnLocation(d)
	end
	Workspace.DescendantAdded:Connect(disableSpawnLocation)
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

local function shouldUseTutorialSpawn(player: Player): boolean
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
		return false
	end
	-- Failed DataStore load: never assume they're new (that dumps veterans at QuestHitbox).
	if player:GetAttribute(PlayerDataSchema.LOAD_FAILED_ATTR) == true then
		return false
	end
	-- Unknown until save data is applied.
	if player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true then
		return false
	end
	return true
end

local function sendToHome(player: Player, character: Model, timeoutSec: number): boolean
	return PlotSpawnUtil.teleportPlayerHome(player, character, timeoutSec)
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
		local loaded = false
		task.spawn(function()
			loaded = PlayerDataService.waitUntilLoaded(player) == true
		end)
		local loadDeadline = os.clock() + 8
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

		local deadline = os.clock() + 12
		local firstTry = true
		while stillThisCharacter(player, character, hrp) and os.clock() < deadline do
			if shouldUseTutorialSpawn(player) then
				if PlotSpawnUtil.teleportTutorialStart(player, character, if firstTry then 12 else 0.4) then
					return
				end
			else
				if sendToHome(player, character, if firstTry then 8 else 0.4) then
					return
				end
			end
			firstTry = false
			task.wait(0.25)
		end
		if not stillThisCharacter(player, character, hrp) then
			return
		end
		-- Last try. If data never arrived, still prefer Base over the tutorial hitbox.
		if shouldUseTutorialSpawn(player) then
			if not PlotSpawnUtil.teleportTutorialStart(player, character, 8) then
				sendToHome(player, character, 8)
			end
		else
			sendToHome(player, character, 8)
		end
		if stillThisCharacter(player, character, hrp) and hrp:IsA("BasePart") and (hrp :: BasePart).Anchored then
			PlotSpawnUtil.releaseCharacterHold(character)
			warn("[PlotPlayerSpawn] spawn pad never ready — released movement hold")
		end
	end)
end

local function tryPlaceNow(player: Player)
	local char = player.Character
	if not (char and char.Parent and player.Parent) then
		return
	end
	if shouldUseTutorialSpawn(player) then
		PlotSpawnUtil.teleportTutorialStart(player, char, 8)
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true
		or player:GetAttribute(PlayerDataSchema.LOAD_FAILED_ATTR) == true
		or typeof(player:GetAttribute("AssignedPlotSlot")) == "number"
	then
		PlotSpawnUtil.teleportPlayerHome(player, char, 20)
	end
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
			if shouldUseTutorialSpawn(player) then
				return
			end
			if typeof(player:GetAttribute("AssignedPlotSlot")) == "number" then
				task.defer(function()
					tryPlaceNow(player)
				end)
			end
		end),
		player:GetAttributeChangedSignal(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR):Connect(function()
			if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
				task.defer(function()
					tryPlaceNow(player)
				end)
			end
		end),
		player:GetAttributeChangedSignal(PlayerDataSchema.LOADED_ATTR):Connect(function()
			task.defer(function()
				tryPlaceNow(player)
			end)
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
