-- [ACTIVE] AutoCollectManager.server
--[[
	Plot Autocollect gamepass pad (Autocollect Thing under 1 Story).
	• Not owned: touch GamepassHitbox → purchase prompt (99 Robux).
	• Owned: touch ButtonPart → collect all stand cash on the plot at once (StandManager).
	• Cash pad + offline billboard mirror the combined total across occupied stands.
--]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AutoCollectConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AutoCollectConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local StoreAccess = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreAccess"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local COLLECT_TOUCH_CHARACTER_DEBOUNCE = 0.2
local GAMEPASS_TOUCH_DEBOUNCE = 1.25
local COLLECT_ALL_DEBOUNCE = 0.45

local collectAllBF: BindableFunction? = nil
local autoCollectVFXRE: RemoteEvent? = nil

local wiredThings: { [Instance]: boolean } = {}
local touchDebounceByCharacter: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local gamepassTouchAtByPlayer: { [Player]: number } = {}
local collectAllAtByPlayer: { [Player]: number } = {}

local function getCollectAllBF(): BindableFunction?
	if collectAllBF and collectAllBF.Parent then
		return collectAllBF
	end
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local bf = folder and folder:FindFirstChild("CollectAllStandCashForPlayer")
	if bf and bf:IsA("BindableFunction") then
		collectAllBF = bf
		return bf
	end
	return nil
end

local function getAutoCollectVFXRE(): RemoteEvent?
	if autoCollectVFXRE and autoCollectVFXRE.Parent then
		return autoCollectVFXRE
	end
	local folder = ReplicatedStorage:FindFirstChild("StandRemotes")
	local ev = folder and folder:FindFirstChild("AutoCollectCashCollectedFX")
	if ev and ev:IsA("RemoteEvent") then
		autoCollectVFXRE = ev
		return ev
	end
	return nil
end

local function touchAllowedForCharacter(char: Model): boolean
	local now = os.clock()
	local last = touchDebounceByCharacter[char]
	if last and now - last < COLLECT_TOUCH_CHARACTER_DEBOUNCE then
		return false
	end
	touchDebounceByCharacter[char] = now
	return true
end

local function resolvePlotFromThing(thing: Instance): Instance?
	local p: Instance? = thing
	while p do
		if PlotPaths.isPlotRoot(p) then
			return p
		end
		p = p.Parent
	end
	return nil
end

local function plotOwnerUserId(plot: Instance): number?
	local uid = plot:GetAttribute("PlotOwnerUserId")
	if typeof(uid) == "number" then
		return uid
	end
	return nil
end

local function isPlotOwner(player: Player, plot: Instance): boolean
	local uid = plotOwnerUserId(plot)
	return uid ~= nil and uid == player.UserId
end

-- Cached ownership so the touch / display sync paths never do a yielding web call
-- (UserOwnsGamePassAsync inside the per-collect refresh was causing periodic freezes).
local ownsCacheByUserId: { [number]: boolean } = {}
local ownsFetchInFlight: { [number]: boolean } = {}

-- Pure cache/attribute read — NEVER yields. Safe to call from touch handlers / display sync.
local function playerOwnsAutoCollect(player: Player): boolean
	local G = StoreConfig.GAMEPASS
	local A = StoreConfig.ATTR
	if StoreAccess.hasGiftedGamePass(player, G.AUTOCOLLECT) then
		return true
	end
	if player:GetAttribute(A.AUTOCOLLECT_OWNED) == true then
		return true
	end
	return ownsCacheByUserId[player.UserId] == true
end

-- Background web verification; updates the cache + AUTOCOLLECT_OWNED attribute. Yields, so it
-- must only run inside its own task.spawn (never in a touch / refresh path).
local onOwnershipResolved: ((Player) -> ())? = nil

local function refreshOwnershipCache(player: Player)
	local G = StoreConfig.GAMEPASS
	local A = StoreConfig.ATTR
	if StoreAccess.hasGiftedGamePass(player, G.AUTOCOLLECT) or player:GetAttribute(A.AUTOCOLLECT_OWNED) == true then
		ownsCacheByUserId[player.UserId] = true
		if onOwnershipResolved then
			onOwnershipResolved(player)
		end
		return
	end
	if not StoreAccess.shouldTrustMarketplaceOwnership(player) then
		ownsCacheByUserId[player.UserId] = false
		return
	end
	if ownsFetchInFlight[player.UserId] then
		return
	end
	ownsFetchInFlight[player.UserId] = true
	task.spawn(function()
		local ok, owned = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, G.AUTOCOLLECT)
		end)
		ownsFetchInFlight[player.UserId] = nil
		if not ok then
			warn("[AutoCollectManager] UserOwnsGamePassAsync failed:", owned)
			return
		end
		ownsCacheByUserId[player.UserId] = owned == true
		if owned == true then
			player:SetAttribute(A.AUTOCOLLECT_OWNED, true)
		end
		if onOwnershipResolved then
			onOwnershipResolved(player)
		end
	end)
end

local function setLabelText(label: (TextLabel | TextButton)?, text: string)
	if not label then
		return
	end
	if label:IsA("TextLabel") then
		local tl = label :: TextLabel
		tl.AutoLocalize = false
		tl.TextTruncate = Enum.TextTruncate.None
		tl.Text = text
	elseif label:IsA("TextButton") then
		local tb = label :: TextButton
		tb.AutoLocalize = false
		tb.TextTruncate = Enum.TextTruncate.None
		tb.Text = text
	end
end

local function findAutoCollectButton(thing: Instance): Instance?
	return thing:FindFirstChild("Button")
end

local function findAutoCollectTotalLabel(thing: Instance): (TextLabel | TextButton)?
	local btn = findAutoCollectButton(thing)
	if not btn then
		return nil
	end
	local bp = btn:FindFirstChild("ButtonPart")
	if bp then
		local total = bp:FindFirstChild("Total", true)
		if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
			return total
		end
	end
	local cash = btn:FindFirstChild("Cash")
	if cash then
		local total = cash:FindFirstChild("Total", true)
		if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
			return total
		end
	end
	return nil
end

local function findAutoCollectOfflineUi(thing: Instance): (BillboardGui?, GuiObject?, (TextLabel | TextButton)?)
	local btn = findAutoCollectButton(thing)
	if not btn then
		return nil, nil, nil
	end
	local cash = btn:FindFirstChild("Cash")
	if not cash then
		return nil, nil, nil
	end
	local bb = cash:FindFirstChild("BillboardGui")
	if not bb or not bb:IsA("BillboardGui") then
		return nil, nil, nil
	end
	local offline = bb:FindFirstChild("Offline")
	if not offline then
		return bb, nil, nil
	end
	local offlineRoot: GuiObject? = if offline:IsA("GuiObject") then offline else nil
	local purple = offline:FindFirstChild("Purple")
	if purple and (purple:IsA("TextLabel") or purple:IsA("TextButton")) then
		return bb, offlineRoot, purple
	end
	if offline:IsA("TextLabel") or offline:IsA("TextButton") then
		return bb, offlineRoot, offline
	end
	return bb, offlineRoot, nil
end

local function sumPlotStandCash(ownerUserId: number, plot: Instance): (number, number)
	local plr = Players:GetPlayerByUserId(ownerUserId)
	if not plr then
		return 0, 0
	end
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local totalsBF = folder and folder:FindFirstChild("GetPlayerPlotCashTotals")
	if totalsBF and totalsBF:IsA("BindableFunction") then
		local ok, acc, offline = pcall(function()
			return totalsBF:Invoke(plr)
		end)
		if ok and typeof(acc) == "number" and typeof(offline) == "number" then
			return acc, offline
		end
		if not ok then
			warn("[AutoCollectManager] GetPlayerPlotCashTotals failed:", acc)
		end
	end

	local accumulated = 0
	for _, desc in ipairs(plot:GetDescendants()) do
		if not desc:IsA("Model") then
			continue
		end
		if desc:GetAttribute("StandOwnerUserId") ~= ownerUserId then
			continue
		end
		if desc:GetAttribute("BrainrotName") == nil then
			continue
		end
		local acc = desc:GetAttribute("StandAccumulatedCash")
		if typeof(acc) == "number" then
			accumulated += math.max(0, math.floor(acc + 0.5))
		end
	end
	return accumulated, 0
end

local function syncAutoCollectDisplayForThing(thing: Instance, ownerUserId: number)
	local plot = resolvePlotFromThing(thing)
	if not plot then
		return
	end
	local accumulated, offlinePending = sumPlotStandCash(ownerUserId, plot)

	local displayAmount = math.floor(accumulated + 0.5)
	if thing:GetAttribute(AutoCollectConfig.ACCUMULATED_ATTR) ~= displayAmount then
		thing:SetAttribute(AutoCollectConfig.ACCUMULATED_ATTR, displayAmount)
	end
	if thing:GetAttribute(AutoCollectConfig.OFFLINE_ATTR) ~= offlinePending then
		thing:SetAttribute(AutoCollectConfig.OFFLINE_ATTR, offlinePending)
	end

	local text = BrainrotEconomy.formatCashAccumulated(displayAmount)
	local label = findAutoCollectTotalLabel(thing)
	if label and label.Text ~= text then
		setLabelText(label, text)
	end

	local bb, frame, offlineLabel = findAutoCollectOfflineUi(thing)
	local showOffline = offlinePending > 0.5
	if bb then
		bb.Enabled = showOffline
		if showOffline and not bb.Adornee then
			local btn = findAutoCollectButton(thing)
			local cash = if btn then btn:FindFirstChild("Cash") else nil
			if cash and cash:IsA("BasePart") then
				bb.Adornee = cash :: BasePart
			end
		end
	end
	if frame then
		frame.Visible = showOffline
	end
	if offlineLabel then
		if showOffline then
			setLabelText(offlineLabel, "+" .. BrainrotEconomy.formatCashAccumulated(offlinePending) .. " Offline")
			if offlineLabel:IsA("GuiObject") then
				(offlineLabel :: GuiObject).Visible = true
			end
		elseif offlineLabel:IsA("GuiObject") then
			(offlineLabel :: GuiObject).Visible = false
		end
	end
end

local function syncAutoCollectInteraction(thing: Instance, ownerUserId: number?)
	local owned = false
	if typeof(ownerUserId) == "number" then
		local plr = Players:GetPlayerByUserId(ownerUserId)
		if plr then
			owned = playerOwnsAutoCollect(plr)
		end
	end
	local btn = findAutoCollectButton(thing)
	if not btn then
		return
	end
	local hitbox = btn:FindFirstChild("GamepassHitbox")
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.CanTouch = not owned
	end
	local buttonPart = btn:FindFirstChild("ButtonPart")
	if buttonPart and buttonPart:IsA("BasePart") then
		buttonPart.CanTouch = owned
	end
end

local function syncAutoCollectInteractionForPlayer(player: Player)
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return
	end
	local story = PlotPaths.firstStoryFolder(plot)
	if not story then
		return
	end
	local thing = story:FindFirstChild(AutoCollectConfig.MODEL_NAME)
	if thing then
		syncAutoCollectInteraction(thing, player.UserId)
	end
end

local function refreshAutoCollectForOwnerUserId(ownerUserId: number)
	local plr = Players:GetPlayerByUserId(ownerUserId)
	if plr then
		syncAutoCollectInteractionForPlayer(plr)
	end

	local plot: Instance? = nil
	if plr then
		plot = PlotPaths.findPlotForAssignedSlot(plr)
	end
	if not plot then
		local folder = PlotPaths.findSpawnAndBasesFolder()
		if folder then
			for _, ch in folder:GetChildren() do
				if PlotPaths.isPlotRoot(ch) and ch:GetAttribute("PlotOwnerUserId") == ownerUserId then
					plot = ch
					break
				end
			end
		end
	end
	if not plot then
		return
	end
	local story = PlotPaths.firstStoryFolder(plot)
	if not story then
		return
	end
	local thing = story:FindFirstChild(AutoCollectConfig.MODEL_NAME)
	if thing then
		syncAutoCollectDisplayForThing(thing, ownerUserId)
		syncAutoCollectInteraction(thing, ownerUserId)
	end
end

local function promptAutoCollectPurchase(player: Player)
	local now = os.clock()
	local last = gamepassTouchAtByPlayer[player]
	if last and now - last < GAMEPASS_TOUCH_DEBOUNCE then
		return
	end
	gamepassTouchAtByPlayer[player] = now

	if playerOwnsAutoCollect(player) then
		return
	end

	local effectRemote = ReplicatedStorage:FindFirstChild("PurchaseEffectRemote")
	if effectRemote and effectRemote:IsA("RemoteEvent") then
		effectRemote:FireClient(player)
	end
	MarketplaceService:PromptGamePassPurchase(player, StoreConfig.GAMEPASS.AUTOCOLLECT)
end

local function collectAllFromAutoCollect(player: Player, thing: Instance, plot: Instance)
	if not playerOwnsAutoCollect(player) then
		return
	end
	if not isPlotOwner(player, plot) then
		return
	end

	local now = os.clock()
	local last = collectAllAtByPlayer[player]
	if last and now - last < COLLECT_ALL_DEBOUNCE then
		return
	end
	collectAllAtByPlayer[player] = now

	local bf = getCollectAllBF()
	if not bf then
		warn("[AutoCollectManager] CollectAllStandCashForPlayer bindable missing")
		return
	end
	local ok, total = pcall(function()
		return bf:Invoke(player)
	end)
	if not ok then
		warn("[AutoCollectManager] collect all failed:", total)
		return
	end
	local amount = if typeof(total) == "number" then total else 0
	if amount <= 0 then
		return
	end

	syncAutoCollectDisplayForThing(thing, player.UserId)

	local vfx = getAutoCollectVFXRE()
	if vfx then
		task.defer(function()
			if player.Parent and thing.Parent then
				vfx:FireClient(player, thing, amount)
			end
		end)
	end
end

local function wireAutoCollectThing(thing: Instance)
	if wiredThings[thing] then
		return
	end
	wiredThings[thing] = true

	local plot = resolvePlotFromThing(thing)
	local ownerUserId = if plot then plotOwnerUserId(plot) else nil
	if typeof(ownerUserId) == "number" then
		syncAutoCollectDisplayForThing(thing, ownerUserId)
		syncAutoCollectInteraction(thing, ownerUserId)
	end

	local btn = findAutoCollectButton(thing)
	if not btn then
		return
	end

	local hitbox = btn:FindFirstChild("GamepassHitbox")
	if hitbox and hitbox:IsA("BasePart") then
		hitbox.Touched:Connect(function(other: BasePart)
			if not other:IsA("BasePart") then
				return
			end
			local char = other:FindFirstAncestorWhichIsA("Model")
			if not char or not touchAllowedForCharacter(char) then
				return
			end
			local plr = Players:GetPlayerFromCharacter(char)
			if not plr then
				return
			end
			local plotNow = resolvePlotFromThing(thing)
			if not plotNow or not isPlotOwner(plr, plotNow) then
				return
			end
			promptAutoCollectPurchase(plr)
		end)
	end

	local buttonPart = btn:FindFirstChild("ButtonPart")
	if buttonPart and buttonPart:IsA("BasePart") then
		buttonPart.Touched:Connect(function(other: BasePart)
			if not other:IsA("BasePart") then
				return
			end
			local char = other:FindFirstAncestorWhichIsA("Model")
			if not char or not touchAllowedForCharacter(char) then
				return
			end
			local plr = Players:GetPlayerFromCharacter(char)
			if not plr then
				return
			end
			local plotNow = resolvePlotFromThing(thing)
			if not plotNow then
				return
			end
			collectAllFromAutoCollect(plr, thing, plotNow)
		end)
	end

	if plot then
		plot:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(function()
			local uid = plotOwnerUserId(plot)
			if typeof(uid) == "number" then
				syncAutoCollectDisplayForThing(thing, uid)
				syncAutoCollectInteraction(thing, uid)
			else
				syncAutoCollectInteraction(thing, nil)
			end
		end)
	end
end

local function tryWireAutoCollectDescendant(inst: Instance)
	if inst.Name == AutoCollectConfig.MODEL_NAME and (inst:IsA("Model") or inst:IsA("Folder")) then
		wireAutoCollectThing(inst)
	end
end

local function hookPlot(plot: Instance)
	tryWireAutoCollectDescendant(plot)
	for _, desc in ipairs(plot:GetDescendants()) do
		tryWireAutoCollectDescendant(desc)
	end
	plot.DescendantAdded:Connect(function(desc)
		tryWireAutoCollectDescendant(desc)
	end)
end

local function hookSpawnFolder(folder: Instance)
	for _, ch in folder:GetChildren() do
		if PlotPaths.isPlotRoot(ch) then
			hookPlot(ch)
		end
	end
	folder.ChildAdded:Connect(function(ch)
		if PlotPaths.isPlotRoot(ch) then
			hookPlot(ch)
		end
	end)
	folder.DescendantAdded:Connect(function(desc)
		tryWireAutoCollectDescendant(desc)
	end)
end

local function ensureRefreshBindable()
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BrainrotInternal"
		folder.Parent = ServerStorage
	end
	local bf = folder:FindFirstChild("RefreshAutoCollectDisplay")
	if not bf then
		bf = Instance.new("BindableFunction")
		bf.Name = "RefreshAutoCollectDisplay"
		bf.Parent = folder
	end
	if bf:IsA("BindableFunction") then
		(bf :: BindableFunction).OnInvoke = function(ownerUserId: any)
			if typeof(ownerUserId) ~= "number" then
				return false
			end
			refreshAutoCollectForOwnerUserId(ownerUserId)
			return true
		end
	end
end

onOwnershipResolved = function(player: Player)
	if not player.Parent then
		return
	end
	syncAutoCollectInteractionForPlayer(player)
end

local function onPlayerAdded(player: Player)
	player:GetAttributeChangedSignal(StoreConfig.ATTR.AUTOCOLLECT_OWNED):Connect(function()
		syncAutoCollectInteractionForPlayer(player)
	end)
	-- Resolve ownership once in the background; updates CanTouch when it returns.
	task.defer(function()
		refreshOwnershipCache(player)
		syncAutoCollectInteractionForPlayer(player)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, plr in Players:GetPlayers() do
	onPlayerAdded(plr)
end

Players.PlayerRemoving:Connect(function(player: Player)
	gamepassTouchAtByPlayer[player] = nil
	collectAllAtByPlayer[player] = nil
	ownsCacheByUserId[player.UserId] = nil
	ownsFetchInFlight[player.UserId] = nil
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if wasPurchased and gamePassId == StoreConfig.GAMEPASS.AUTOCOLLECT and player and player.Parent then
		ownsCacheByUserId[player.UserId] = true
		player:SetAttribute(StoreConfig.ATTR.AUTOCOLLECT_OWNED, true)
		task.defer(function()
			syncAutoCollectInteractionForPlayer(player)
			refreshAutoCollectForOwnerUserId(player.UserId)
		end)
	end
end)

ensureRefreshBindable()

task.spawn(function()
	local folder = PlotPaths.waitForSpawnAndBasesFolder(45)
	if folder then
		hookSpawnFolder(folder)
	end
end)
