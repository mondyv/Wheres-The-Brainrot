-- Authoritative cash + swing upgrade purchases (attributes replicate to client + SwingSystem)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwingUpgrades = require(ReplicatedStorage.Shared.SwingUpgrades)

local STARTING_CASH = 500_000_000 -- default wallet for new joins (500M)

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local purchaseFn = remotesFolder:FindFirstChild("PurchaseSwingUpgrade") :: RemoteFunction?
if not purchaseFn then
	purchaseFn = Instance.new("RemoteFunction")
	purchaseFn.Name = "PurchaseSwingUpgrade"
	purchaseFn.Parent = remotesFolder
end

local function initPlayer(player: Player)
	-- Cash only if never set (avoid wiping wallet on respawn / duplicate init)
	if player:GetAttribute("Cash") == nil then
		player:SetAttribute("Cash", STARTING_CASH)
	end
	if player:GetAttribute("SwingForce") == nil then
		player:SetAttribute("SwingForce", 1)
	end
	if player:GetAttribute("SwingRange") == nil then
		player:SetAttribute("SwingRange", 1)
	end
	if player:GetAttribute("Carry") == nil then
		player:SetAttribute("Carry", 1)
	end
	if player:GetAttribute("BrainrotCarryCount") == nil then
		player:SetAttribute("BrainrotCarryCount", 0)
	end
	if player:GetAttribute("RopeLength") == nil then
		player:SetAttribute("RopeLength", 0)
	end
end

Players.PlayerAdded:Connect(initPlayer)
for _, p in Players:GetPlayers() do
	initPlayer(p)
end

local function getBuys(player: Player, upgradeId: string): number
	local v = player:GetAttribute(SwingUpgrades.buysAttributeName(upgradeId))
	return if typeof(v) == "number" then math.floor(v) else 0
end

purchaseFn.OnServerInvoke = function(player: Player, upgradeId: any): (boolean, string?)
	if typeof(upgradeId) ~= "string" then
		return false, "Invalid"
	end
	local id = upgradeId :: string
	local def = SwingUpgrades[id]
	if not def then
		return false, "Unknown upgrade"
	end
	local cash = player:GetAttribute("Cash")
	if typeof(cash) ~= "number" then
		return false, "No cash"
	end
	local buys = getBuys(player, id)
	local price = SwingUpgrades.priceAtTier(def, buys)
	if cash < price then
		return false, "Not enough cash"
	end
	player:SetAttribute("Cash", cash - price)
	player:SetAttribute(SwingUpgrades.buysAttributeName(id), buys + 1)
	local cur = player:GetAttribute(def.attr)
	local base = if typeof(cur) == "number" then cur else 0
	player:SetAttribute(def.attr, base + def.add)
	return true, nil
end
