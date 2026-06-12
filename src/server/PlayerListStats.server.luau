-- [ACTIVE] PlayerListStats.server
-- Sync Cash + Rebirth into leaderstats so the default Roblox Tab player list shows them.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))

local CASH_ATTR = "Cash"
local REBIRTH_ATTR = RebirthConfig.REBIRTH_COUNT_ATTR

local function ensureLeaderstats(player: Player): (StringValue, StringValue)
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end

	local cashVal = folder:FindFirstChild("Cash")
	if not cashVal or not cashVal:IsA("StringValue") then
		if cashVal then
			cashVal:Destroy()
		end
		cashVal = Instance.new("StringValue")
		cashVal.Name = "Cash"
		cashVal.Parent = folder
	end

	local rebirthVal = folder:FindFirstChild("Rebirth")
	if not rebirthVal or not rebirthVal:IsA("StringValue") then
		if rebirthVal then
			rebirthVal:Destroy()
		end
		rebirthVal = Instance.new("StringValue")
		rebirthVal.Name = "Rebirth"
		rebirthVal.Parent = folder
	end

	return cashVal :: StringValue, rebirthVal :: StringValue
end

local function syncPlayer(player: Player)
	local cashVal, rebirthVal = ensureLeaderstats(player)

	local cash = player:GetAttribute(CASH_ATTR)
	cashVal.Value = BrainrotEconomy.formatCashShort(if typeof(cash) == "number" then cash else 0)

	local rebirth = player:GetAttribute(REBIRTH_ATTR)
	rebirthVal.Value = BrainrotEconomy.formatNumberShort(if typeof(rebirth) == "number" then math.max(0, math.floor(rebirth)) else 0)
end

local statConns: { [Player]: { RBXScriptConnection } } = {}

local function bindPlayer(player: Player)
	if statConns[player] then
		return
	end
	syncPlayer(player)
	statConns[player] = {
		player:GetAttributeChangedSignal(CASH_ATTR):Connect(function()
			syncPlayer(player)
		end),
		player:GetAttributeChangedSignal(REBIRTH_ATTR):Connect(function()
			syncPlayer(player)
		end),
	}
end

Players.PlayerAdded:Connect(bindPlayer)

Players.PlayerRemoving:Connect(function(player)
	local conns = statConns[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		statConns[player] = nil
	end
end)

for _, player in Players:GetPlayers() do
	bindPlayer(player)
end
