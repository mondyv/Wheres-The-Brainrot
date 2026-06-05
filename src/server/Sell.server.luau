-- [ACTIVE] Sell.server
--[[
	Sell brainrots from inventory for cash (10× current $/s via BrainrotEconomy).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local function getBushRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BushRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function getConsumeBF(): BindableFunction?
	local internal = ServerStorage:FindFirstChild("BrainrotInternal")
	if not internal then
		return nil
	end
	local bf = internal:FindFirstChild("ConsumeInventoryEntry")
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

local function payout(player: Player, amount: number)
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + amount)
end

local function sellAtIndex(player: Player, idx: number): (boolean, string?, number?)
	local consumeBF = getConsumeBF()
	if not consumeBF then
		return false, "Inventory not ready", nil
	end
	local ok, entry = pcall(function()
		return consumeBF:Invoke(player, idx)
	end)
	if not ok or typeof(entry) ~= "table" then
		return false, "Invalid item", nil
	end
	local price = BrainrotEconomy.sellPrice(entry :: BrainrotEconomy.InvEntry)
	payout(player, price)
	return true, nil, price
end

local folder = getBushRemotes()

local sellOneRF = folder:FindFirstChild("SellBrainrot") :: RemoteFunction?
if not sellOneRF then
	sellOneRF = Instance.new("RemoteFunction")
	sellOneRF.Name = "SellBrainrot"
	sellOneRF.Parent = folder
end

sellOneRF.OnServerInvoke = function(player: Player, idx: any): (boolean, string?, number?)
	if typeof(idx) ~= "number" then
		return false, "Invalid", nil
	end
	return sellAtIndex(player, math.floor(idx))
end

local sellAllRF = folder:FindFirstChild("SellAllBrainrot") :: RemoteFunction?
if not sellAllRF then
	sellAllRF = Instance.new("RemoteFunction")
	sellAllRF.Name = "SellAllBrainrot"
	sellAllRF.Parent = folder
end

sellAllRF.OnServerInvoke = function(player: Player): (boolean, string?, number?, number?)
	local total = 0
	local sold = 0
	while true do
		local ok, _err, price = sellAtIndex(player, 1)
		if not ok or not price then
			break
		end
		total += price
		sold += 1
	end
	if sold < 1 then
		return false, "Nothing to sell", nil, 0
	end
	return true, nil, total, sold
end
