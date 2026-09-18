-- Paste into ServerScriptService on the SELLABLE baseplate only.
-- Live game already grants Cash via tutorial / PlayerDataService.
local Players = game:GetService("Players")

local STARTING_CASH = 1_000_000

local function setup(player: Player)
	if player:GetAttribute("Cash") == nil then
		player:SetAttribute("Cash", STARTING_CASH)
	end
end

Players.PlayerAdded:Connect(setup)
for _, p in Players:GetPlayers() do
	setup(p)
end
