-- Authoritative cash + swing upgrade purchases (attributes replicate to client + SwingSystem)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SwingUpgrades = require(ReplicatedStorage.Shared.SwingUpgrades)

local STARTING_CASH = 55 -- default wallet for new joins

local pendingRobuxUpgrade: { [Player]: string } = {}

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

local prepareRobuxRE = remotesFolder:FindFirstChild("PrepareRobuxUpgrade") :: RemoteEvent?
if not prepareRobuxRE then
	prepareRobuxRE = Instance.new("RemoteEvent")
	prepareRobuxRE.Name = "PrepareRobuxUpgrade"
	prepareRobuxRE.Parent = remotesFolder
end

local function readLevels(player: Player): SwingUpgrades.UpgradeLevels
	return SwingUpgrades.readLevels(function(name: string)
		return player:GetAttribute(name)
	end)
end

local function initPlayer(player: Player)
	SwingUpgrades.initLevelAttributes(player)

	if player:GetAttribute("Cash") == nil then
		player:SetAttribute("Cash", STARTING_CASH)
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

Players.PlayerRemoving:Connect(function(player: Player)
	pendingRobuxUpgrade[player] = nil
end)

local function isValidUpgradeId(upgradeId: string): boolean
	return (SwingUpgrades :: any)[upgradeId] ~= nil
end

purchaseFn.OnServerInvoke = function(player: Player, upgradeId: any): (boolean, string?)
	if typeof(upgradeId) ~= "string" then
		return false, "Invalid"
	end
	local id = upgradeId :: string
	if not isValidUpgradeId(id) then
		return false, "Unknown upgrade"
	end

	local levels = readLevels(player)
	if SwingUpgrades.isUpgradeMaxed(id, levels) then
		return false, "Max level"
	end

	local cash = player:GetAttribute("Cash")
	if typeof(cash) ~= "number" then
		return false, "No cash"
	end

	local price = SwingUpgrades.priceForUpgradeId(id, levels)
	if cash < price then
		return false, "Not enough cash"
	end

	player:SetAttribute("Cash", cash - price)
	if not SwingUpgrades.grantUpgrade(player, id) then
		return false, "Grant failed"
	end
	return true, nil
end

prepareRobuxRE.OnServerEvent:Connect(function(player: Player, upgradeId: any)
	if typeof(upgradeId) ~= "string" or not isValidUpgradeId(upgradeId) then
		return
	end
	pendingRobuxUpgrade[player] = upgradeId
end)

local function fulfillRobuxUpgradeReceipt(player: Player): boolean
	local upgradeId = pendingRobuxUpgrade[player]
	if not upgradeId or not isValidUpgradeId(upgradeId) then
		return false
	end
	pendingRobuxUpgrade[player] = nil
	return SwingUpgrades.grantUpgrade(player, upgradeId)
end

local function ensureInternalFolder(): Folder
	local existing = ServerStorage:FindFirstChild("GameInternal")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "GameInternal"
	folder.Parent = ServerStorage
	return folder
end

local fulfillBF = ensureInternalFolder():FindFirstChild("FulfillRobuxUpgrade")
if not fulfillBF then
	fulfillBF = Instance.new("BindableFunction")
	fulfillBF.Name = "FulfillRobuxUpgrade"
	fulfillBF.Parent = ensureInternalFolder()
end
(fulfillBF :: BindableFunction).OnInvoke = function(playerArg: any): any
	if typeof(playerArg) ~= "Instance" or not (playerArg :: Instance):IsA("Player") then
		return false
	end
	return fulfillRobuxUpgradeReceipt(playerArg :: Player)
end
