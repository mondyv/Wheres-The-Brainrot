-- [ACTIVE] 0_PlayerCollision.server
--[[
	Players should not physically collide with each other (still collide with the world).
--]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local PLAYER_GROUP = "PlayerCharacters"

local function ensureGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, false)
end

local function applyToPart(part: BasePart)
	part.CollisionGroup = PLAYER_GROUP
end

local function wireCharacter(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			applyToPart(d)
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			applyToPart(d)
		end
	end)
end

ensureGroups()

local charConns: { [Player]: RBXScriptConnection } = {}

local function bindPlayer(player: Player)
	if charConns[player] then
		return
	end
	charConns[player] = player.CharacterAdded:Connect(wireCharacter)
	if player.Character then
		wireCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(bindPlayer)

Players.PlayerRemoving:Connect(function(player)
	local conn = charConns[player]
	if conn then
		conn:Disconnect()
		charConns[player] = nil
	end
end)

for _, player in Players:GetPlayers() do
	bindPlayer(player)
end
