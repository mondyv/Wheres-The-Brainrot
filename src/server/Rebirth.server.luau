--[[
	Rebirth authority: requirements, rewards, skip dev product, upgrade reset.
--]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local IndexService = require(script.Parent:WaitForChild("Modules"):WaitForChild("IndexService"))

local MAX_FLOOR = 4

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local folder = getRemotesFolder()
	local rf = folder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = folder
	end
	return rf :: RemoteFunction
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local getStateRF = ensureRemoteFunction("GetRebirthState")
local performRF = ensureRemoteFunction("PerformRebirth")
local updatedRE = ensureRemoteEvent("RebirthUpdated")

local function isBrainrotDiscovered(player: Player, name: string): boolean
	return IndexService.hasDiscoveredBrainrot(player, name)
end

local function enrichSnapshot(snapshot: RebirthConfig.RebirthSnapshot): RebirthConfig.RebirthSnapshot
	for _, req in snapshot.brainrotReqs do
		if typeof(req.icon) ~= "string" or req.icon == "" then
			req.icon = IndexService.getIconFor(req.name, "normal")
		end
	end
	return snapshot
end

local function syncPlayerRebirthAttrs(player: Player, snapshot: RebirthConfig.RebirthSnapshot)
	player:SetAttribute(RebirthConfig.CAN_REBIRTH_ATTR, snapshot.canRebirth)
	player:SetAttribute(RebirthConfig.FLOOR_REWARD_ATTR, snapshot.isFloorRebirth)
	player:SetAttribute(RebirthConfig.MONEY_MULT_ATTR, snapshot.moneyMultiplier)
end

local function pushState(player: Player)
	local snapshot = enrichSnapshot(RebirthConfig.buildSnapshot(player, isBrainrotDiscovered))
	syncPlayerRebirthAttrs(player, snapshot)
	updatedRE:FireClient(player, snapshot)
	return snapshot
end

local function resetSwingUpgrades(player: Player)
	SwingUpgrades.resetLevels(player)
end

local function grantFloorRebirth(player: Player): boolean
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return false
	end
	local level = plot:GetAttribute("BaseFloorLevel")
	local cur = if typeof(level) == "number" then math.floor(level) else 1
	if cur >= MAX_FLOOR then
		return false
	end
	plot:SetAttribute("BaseFloorLevel", cur + 1)
	return true
end

local function performRebirth(player: Player, opts: { skipRequirements: boolean?, keepUpgrades: boolean? }?): (boolean, string?)
	opts = opts or {}
	local snapshot = RebirthConfig.buildSnapshot(player, isBrainrotDiscovered)
	if not opts.skipRequirements and not snapshot.canRebirth then
		return false, "requirements"
	end

	local newCount = snapshot.rebirthCount + 1
	player:SetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR, newCount)
	player:SetAttribute(RebirthConfig.MONEY_MULT_ATTR, RebirthConfig.moneyMultiplierForCount(newCount))

	if RebirthConfig.isFloorRebirth(newCount) then
		grantFloorRebirth(player)
	end

	if not opts.keepUpgrades then
		resetSwingUpgrades(player)
	end

	pushState(player)
	return true, nil
end

local function initPlayer(player: Player)
	if player:GetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR) == nil then
		player:SetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR, 0)
	end
	if player:GetAttribute(RebirthConfig.MONEY_MULT_ATTR) == nil then
		player:SetAttribute(
			RebirthConfig.MONEY_MULT_ATTR,
			RebirthConfig.moneyMultiplierForCount(0)
		)
	end
	pushState(player)
	player:GetAttributeChangedSignal("Cash"):Connect(function()
		pushState(player)
	end)
end

task.spawn(function()
	local internal = ServerStorage:WaitForChild("BrainrotInternal", 120)
	if not internal then
		return
	end
	local refresh = internal:FindFirstChild("RefreshRebirthState")
	if not refresh then
		refresh = Instance.new("BindableFunction")
		refresh.Name = "RefreshRebirthState"
		refresh.Parent = internal
	end
	(refresh :: BindableFunction).OnInvoke = function(plr: any)
		if typeof(plr) == "Instance" and (plr :: Instance):IsA("Player") then
			pushState(plr :: Player)
		end
	end
end)

getStateRF.OnServerInvoke = function(player: Player)
	return pushState(player)
end

performRF.OnServerInvoke = function(player: Player)
	local ok, err = performRebirth(player, { skipRequirements = false, keepUpgrades = false })
	return ok, err
end

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if receiptInfo.ProductId == RebirthConfig.SKIP_DEV_PRODUCT_ID then
		local ok = performRebirth(player, { skipRequirements = true, keepUpgrades = true })
		if ok then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	elseif receiptInfo.ProductId == SwingUpgrades.SKIP_UPGRADE_DEV_PRODUCT_ID then
		local internal = ServerStorage:FindFirstChild("GameInternal")
		local fulfill = internal and internal:FindFirstChild("FulfillRobuxUpgrade")
		if fulfill and fulfill:IsA("BindableFunction") then
			local ok = (fulfill :: BindableFunction):Invoke(player)
			if ok then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

Players.PlayerAdded:Connect(initPlayer)
for _, plr in Players:GetPlayers() do
	task.defer(function()
		initPlayer(plr)
	end)
end

return {
	performRebirth = performRebirth,
	pushState = pushState,
}
