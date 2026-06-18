--// < Made by: MikePlayz163 >

-->> || Services || <<--

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-->> || Types || <<--

export type Controller = {
	ValidatePlayer: (self: Controller, player: any) -> (boolean, string?),
	GetCharacter: (self: Controller, player: Player) -> Model?,
	GetRootPart: (self: Controller, player: Player) -> BasePart?,
	IsAlive: (self: Controller, player: Player) -> boolean,
	IsWithinDistance: (self: Controller, player: Player, player2: Player, maxDistance: number) -> boolean,
}

-->> || Main ~ Utilities || <<--

local Main = {} :: Controller

function Main:ValidatePlayer(player: any): (boolean, string?)
	if not player then
		return false, "Provided player is nil."
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Provided value is not a Player."
	end

	if player.Parent ~= Players then
		return false, "Player is not currently in the game."
	end

	return true, nil
end

function Main:GetCharacter(player: Player): Model?
	local valid = self:ValidatePlayer(player)

	if not valid then
		return nil
	end

	local character = player.Character

	if not character or not character:IsA("Model") then
		return nil
	end

	return character
end

function Main:GetRootPart(player: Player): BasePart?
	local character = self:GetCharacter(player)

	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		return root
	end

	if character.PrimaryPart then
		return character.PrimaryPart
	end

	return nil
end

function Main:IsAlive(player: Player): boolean
	local character = self:GetCharacter(player)

	if not character then
		return false
	end

	if not character:IsDescendantOf(Workspace) then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return false
	end

	return humanoid.Health > 0
end

function Main:IsWithinDistance(player: Player, player2: Player, maxDistance: number): boolean
	if typeof(maxDistance) ~= "number" or maxDistance <= 0 then
		return false
	end

	local rootA = self:GetRootPart(player)
	local rootB = self:GetRootPart(player2)

	if not rootA or not rootB then
		return false
	end

	return (rootA.Position - rootB.Position).Magnitude <= maxDistance
end

return Main
