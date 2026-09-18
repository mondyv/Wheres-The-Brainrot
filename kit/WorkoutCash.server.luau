-- Paste into ServerScriptService on the SELLABLE baseplate only.
-- Live game already grants Cash via tutorial / PlayerDataService.
local Players = game:GetService("Players")

local STARTING_CASH = 1_000_000
print("[WorkoutCash] starting cash =", STARTING_CASH)

local function setup(player: Player)
	player:SetAttribute("WorkoutKit", true)
	if player:GetAttribute("Cash") == nil then
		player:SetAttribute("Cash", STARTING_CASH)
	end
end

Players.PlayerAdded:Connect(setup)
for _, p in Players:GetPlayers() do
	setup(p)
end
