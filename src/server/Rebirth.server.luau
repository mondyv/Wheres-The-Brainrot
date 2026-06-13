-- [ACTIVE] Rebirth.server
--[[
	Rebirth authority: requirements, rewards, skip dev product, upgrade reset.
	Brainrot requirements are satisfied only by Index unlocks (IndexService), not inventory.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local IndexService = require(script.Parent:WaitForChild("Modules"):WaitForChild("IndexService"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local ProductHandlerServer =
	require(game:GetService("ServerScriptService").EssentialsServer.ProductHandler.ProductHandlerServer)

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

local function makeIndexDiscoveredCheck(player: Player): (name: string) -> boolean
	return function(name: string): boolean
		return IndexService.hasDiscoveredBrainrot(player, name)
	end
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

local lastPushedSnapshot: { [Player]: RebirthConfig.RebirthSnapshot } = {}

local function snapshotNeedsClientPush(
	prev: RebirthConfig.RebirthSnapshot,
	next: RebirthConfig.RebirthSnapshot
): boolean
	if prev.canRebirth ~= next.canRebirth then
		return true
	end
	if prev.cashMet ~= next.cashMet then
		return true
	end
	if prev.isFloorRebirth ~= next.isFloorRebirth then
		return true
	end
	if prev.nextTier ~= next.nextTier then
		return true
	end
	if prev.cashRequired ~= next.cashRequired then
		return true
	end
	if #prev.brainrotReqs ~= #next.brainrotReqs then
		return true
	end
	for i, req in ipairs(prev.brainrotReqs) do
		local other = next.brainrotReqs[i]
		if not other or req.met ~= other.met or req.name ~= other.name then
			return true
		end
	end
	return false
end

local function pushState(player: Player, force: boolean?)
	local snapshot = enrichSnapshot(RebirthConfig.buildSnapshot(player, makeIndexDiscoveredCheck(player)))
	local prev = lastPushedSnapshot[player]
	if not force and prev and not snapshotNeedsClientPush(prev, snapshot) then
		return snapshot
	end
	lastPushedSnapshot[player] = snapshot
	syncPlayerRebirthAttrs(player, snapshot)
	updatedRE:FireClient(player, snapshot)
	return snapshot
end

local function onPlayerCashChanged(player: Player)
	local prev = lastPushedSnapshot[player]
	if not prev then
		pushState(player)
		return
	end
	local cash = player:GetAttribute("Cash")
	local cashVal = if typeof(cash) == "number" then cash else 0
	local cashMet = cashVal >= prev.cashRequired
	if cashMet == prev.cashMet then
		return
	end
	pushState(player)
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
	local snapshot = RebirthConfig.buildSnapshot(player, makeIndexDiscoveredCheck(player))
	if not opts.skipRequirements and not snapshot.canRebirth then
		return false, "requirements"
	end
	if RebirthConfig.isMaxRebirthCount(snapshot.rebirthCount) then
		return false, "max_rebirth"
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

local cashConns: { [Player]: RBXScriptConnection } = {}

local function initPlayer(player: Player)
	PlayerDataService.waitUntilLoaded(player)
	if player.Parent == nil then
		-- Player left while data was loading.
		return
	end
	if player:GetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR) == nil then
		player:SetAttribute(RebirthConfig.REBIRTH_COUNT_ATTR, 0)
	end
	if player:GetAttribute(RebirthConfig.MONEY_MULT_ATTR) == nil then
		player:SetAttribute(
			RebirthConfig.MONEY_MULT_ATTR,
			RebirthConfig.moneyMultiplierForCount(0)
		)
	end
	pushState(player, true)
	if not cashConns[player] then
		cashConns[player] = player:GetAttributeChangedSignal("Cash"):Connect(function()
			onPlayerCashChanged(player)
		end)
	end
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

local function notifyCloseStore(player: Player)
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	local re = folder and folder:FindFirstChild("CloseStore")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player)
	end
end

ProductHandlerServer.registerProductReceipt(RebirthConfig.SKIP_DEV_PRODUCT_ID, function(player: Player)
	local ok = performRebirth(player, { skipRequirements = true, keepUpgrades = true })
	if ok then
		notifyCloseStore(player)
	end
	return if ok
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end)

ProductHandlerServer.registerProductReceipt(SwingUpgrades.SKIP_UPGRADE_DEV_PRODUCT_ID, function(player: Player)
	local internal = ServerStorage:FindFirstChild("GameInternal")
	local fulfill = internal and internal:FindFirstChild("FulfillRobuxUpgrade")
	if fulfill and fulfill:IsA("BindableFunction") then
		local ok = (fulfill :: BindableFunction):Invoke(player)
		if ok then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastPushedSnapshot[player] = nil
	local conn = cashConns[player]
	if conn then
		conn:Disconnect()
		cashConns[player] = nil
	end
end)

Players.PlayerAdded:Connect(initPlayer)
for _, plr in Players:GetPlayers() do
	task.defer(function()
		initPlayer(plr)
	end)
end

-- Expose performRebirth as a BindableFunction so other server systems (e.g. the daily
-- "free rebirth" reward) can trigger it without circular requires.
do
	local internalFolder = ServerStorage:FindFirstChild("RebirthInternal")
	if not internalFolder then
		internalFolder = Instance.new("Folder")
		internalFolder.Name = "RebirthInternal"
		internalFolder.Parent = ServerStorage
	end
	local bindable = internalFolder:FindFirstChild("PerformRebirth")
	if not bindable then
		bindable = Instance.new("BindableFunction")
		bindable.Name = "PerformRebirth"
		bindable.Parent = internalFolder
	end
	(bindable :: BindableFunction).OnInvoke = function(plr: any, opts: any)
		if typeof(plr) ~= "Instance" or not (plr :: Instance):IsA("Player") then
			return false, "invalid_player"
		end
		local options: { skipRequirements: boolean?, keepUpgrades: boolean? } = {}
		if typeof(opts) == "table" then
			options.skipRequirements = opts.skipRequirements == true
			options.keepUpgrades = opts.keepUpgrades == true
		end
		return performRebirth(plr :: Player, options)
	end
end

return {
	performRebirth = performRebirth,
	pushState = pushState,
}
