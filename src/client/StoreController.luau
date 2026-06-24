-- [ACTIVE] StoreController
--[[
	StoreController
	Wires every Store panel buy button with the standard hover / click animation
	and SFX, routes purchases through PurchasePrompt (which handles the rainbow +
	confetti + purchase SFX automatically), and keeps dynamic labels fresh:
	• Cash bundle reward amounts (server-authoritative, refreshed on open).
	• Booster pack "N/2 available" counters.
	• Exclusive Brainrot / Free Brainrot disabled states.
	• Server Luck store-panel "current → next" text.
	(Chat tags live in ChatTagsController.)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local HUDController = require(script.Parent.HUDController)
local UpgradesController = require(script.Parent.UpgradesController)
local MainGradientButtons = require(script.Parent.MainGradientButtons)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local STAND_TAG = "BrainrotStand"
local SECONDS_PER_DAY = 86400

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

type BuyButtonState = {
	enabled: boolean,
}

type OwnedBuyEntry = {
	buy: GuiObject,
	state: BuyButtonState,
	ownedAttr: string,
}

local ownedBuyByGamePassId: { [number]: OwnedBuyEntry } = {}
local ownedBuyByProductId: { [number]: OwnedBuyEntry } = {}

local StoreController = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

-- Returns a clickable GuiButton covering `host` (creating a transparent overlay if needed).
local function ensureClickButton(host: GuiObject): GuiButton
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local existing = host:FindFirstChild("_StoreClick")
	if existing and existing:IsA("GuiButton") then
		return existing :: GuiButton
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_StoreClick"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 50
	btn.Active = true
	btn.AutoButtonColor = false
	btn.Parent = host
	return btn
end

local function highlightOn(host: GuiObject): GuiObject?
	local decor = host:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local on = highlight and highlight:FindFirstChild("On")
	if on and on:IsA("GuiObject") then
		return on :: GuiObject
	end
	return nil
end

-- Wires standard hover/click anim + SFX onto a buy-button host. Returns a state table
-- so callers can enable/disable the button (e.g. owned / sold out).
local function wireBuyButton(host: GuiObject, onClick: () -> ()): BuyButtonState
	local scale = getOrAddUIScale(host)
	local on = highlightOn(host)
	if on then
		on.Visible = false
	end
	local state: BuyButtonState = { enabled = true }
	local btn = ensureClickButton(host)

	btn.MouseEnter:Connect(function()
		if not state.enabled then
			return
		end
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		if on then
			on.Visible = true
		end
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		if on then
			on.Visible = false
		end
	end)
	btn.MouseButton1Down:Connect(function()
		if not state.enabled then
			return
		end
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = if state.enabled then 1.06 else 1 }):Play()
	end)
	local function activated()
		if not state.enabled then
			GameSoundEffects.playErrorNotif()
			return
		end
		onClick()
	end
	btn.Activated:Connect(activated)
	return state
end

local function setButtonEnabled(host: GuiObject, state: BuyButtonState, enabled: boolean)
	state.enabled = enabled
	local overlay = host:FindFirstChild("_StoreDisabled")
	if not enabled then
		if not overlay then
			local f = Instance.new("Frame")
			f.Name = "_StoreDisabled"
			f.BackgroundColor3 = Color3.new(0, 0, 0)
			f.BackgroundTransparency = 0.55
			f.BorderSizePixel = 0
			f.Size = UDim2.fromScale(1, 1)
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.ZIndex = 40
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 12)
			corner.Parent = f
			f.Parent = host
		end
	elseif overlay then
		overlay:Destroy()
	end
end

local function removeStoreDisabledOverlay(host: GuiObject)
	local overlay = host:FindFirstChild("_StoreDisabled")
	if overlay then
		overlay:Destroy()
	end
end

local function setButtonEnabledNoOverlay(host: GuiObject, state: BuyButtonState, enabled: boolean)
	state.enabled = enabled
	removeStoreDisabledOverlay(host)
end

local function applyPackPurchasedRed(buy: GuiObject)
	MainGradientButtons.applyPurchased(buy)
	removeStoreDisabledOverlay(buy)
end

local function applyPackAvailableDefault(buy: GuiObject)
	MainGradientButtons.applyDefault(buy)
	removeStoreDisabledOverlay(buy)
end

local function findBuy(panel: Instance?): GuiObject?
	if not panel then
		return nil
	end
	local buyButtons = panel:FindFirstChild("BuyButtons")
	local one = buyButtons and buyButtons:FindFirstChild("1")
	if one and one:IsA("GuiObject") then
		return one :: GuiObject
	end
	return nil
end

local function refreshOwnedBuy(entry: OwnedBuyEntry)
	local owned = player:GetAttribute(entry.ownedAttr) == true

	if owned then
		MainGradientButtons.applyPurchased(entry.buy)
		setButtonEnabledNoOverlay(entry.buy, entry.state, false)
	else
		MainGradientButtons.applyDefault(entry.buy)
		setButtonEnabled(entry.buy, entry.state, true)
	end
end

local function applyOptimisticPurchase(entry: OwnedBuyEntry)
	MainGradientButtons.applyPurchased(entry.buy)
	setButtonEnabledNoOverlay(entry.buy, entry.state, false)
end

-- ── Wiring ──────────────────────────────────────────────────────────────────────

-- Gamepass panels are split across two sibling containers ("Gamepasses" and
-- "Gamepasses2"), so search every provided container for the panel.
local function findGamePassPanel(containers: { Instance? }, panelName: string): Instance?
	for _, c in containers do
		if c then
			local panel = c:FindFirstChild(panelName)
			if panel then
				return panel
			end
		end
	end
	return nil
end

local function wireGamePass(containers: { Instance? }, panelName: string, gamePassId: number, ownedAttr: string?)
	local panel = findGamePassPanel(containers, panelName)
	if not panel then
		warn("[StoreController] gamepass panel not found:", panelName)
		return
	end
	local buy = findBuy(panel)
	if not buy then
		warn("[StoreController] buy button not found for gamepass panel:", panelName)
		return
	end
	local state = wireBuyButton(buy, function()
		warn("[StoreController]", panelName, "buy clicked → prompting gamepass", gamePassId)
		PurchasePrompt.promptGamePass(gamePassId)
	end)
	-- Register for owned/optimistic refresh; without this, PromptGamePassPurchaseFinished
	-- finds no entry in ownedBuyByGamePassId and the button never shows as purchased.
	if ownedAttr then
		local entry: OwnedBuyEntry = {
			buy = buy,
			state = state,
			ownedAttr = ownedAttr,
		}
		ownedBuyByGamePassId[gamePassId] = entry
		player:GetAttributeChangedSignal(ownedAttr):Connect(function()
			refreshOwnedBuy(entry)
		end)
		refreshOwnedBuy(entry)
	end
end

local function wireProduct(panel: Instance?, productId: number)
	local buy = findBuy(panel)
	if not buy then
		return
	end
	wireBuyButton(buy, function()
		PurchasePrompt.promptProduct(productId)
	end)
end

local function findExclusivePanel(container: Instance): Instance?
	local brainrot1 = container:FindFirstChild("Brainrot1")
	if brainrot1 then
		return brainrot1
	end
	return container:FindFirstChild("Exclusive(Ignore)")
end

local function wireExclusive(container: Instance)
	local panel = findExclusivePanel(container)
	local buy = findBuy(panel)
	if not buy then
		warn("[StoreController] exclusive buy button not found (panel:", panel ~= nil, ")")
		return
	end
	local nameLabel = panel and panel:FindFirstChild("Name")
	if nameLabel and (nameLabel:IsA("TextLabel") or nameLabel:IsA("TextButton")) then
		(nameLabel :: TextLabel).Text = StoreConfig.EXCLUSIVE_BRAINROT_NAME
	end
	local infoFrame = panel and panel:FindFirstChild("InfoFrame")
	local info = infoFrame and infoFrame:FindFirstChild("Info")
	if info and (info:IsA("TextLabel") or info:IsA("TextButton")) then
		(info :: TextLabel).Text = "Exclusive brainrot"
	end
	local state = wireBuyButton(buy, function()
		if player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
			GameSoundEffects.playErrorNotif()
			return
		end
		PurchasePrompt.promptProduct(StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT)
	end)
	local entry: OwnedBuyEntry = {
		buy = buy,
		state = state,
		ownedAttr = StoreConfig.ATTR.EXCLUSIVE_OWNED,
	}
	local function refresh()
		refreshOwnedBuy(entry)
	end
	player:GetAttributeChangedSignal(StoreConfig.ATTR.EXCLUSIVE_OWNED):Connect(refresh)
	ownedBuyByProductId[StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT] = entry
	refresh()
end

local function wirePacks(container: Instance)
	for _, pack in StoreConfig.PACKS do
		local panel = container:FindFirstChild(pack.frameName)
		local buy = findBuy(panel)
		if buy and panel then
			local state = wireBuyButton(buy, function()
				PurchasePrompt.promptProduct(pack.productId)
			end)
			local availableLabel = panel:FindFirstChild("Available")
			local entry: OwnedBuyEntry = {
				buy = buy,
				state = state,
				ownedAttr = pack.boughtAttr,
			}
			local function refresh()
				local bought = player:GetAttribute(pack.boughtAttr)
				local count = if typeof(bought) == "number" then bought else 0
				local remaining = math.max(0, StoreConfig.PACK_PURCHASE_LIMIT - count)
				if availableLabel and (availableLabel:IsA("TextLabel") or availableLabel:IsA("TextButton")) then
					(availableLabel :: TextLabel).Text =
						string.format("%d/%d available", remaining, StoreConfig.PACK_PURCHASE_LIMIT)
				end
				local soldOut = remaining <= 0
				if soldOut then
					if availableLabel and (availableLabel:IsA("TextLabel") or availableLabel:IsA("TextButton")) then
						(availableLabel :: TextLabel).Text = "Purchased"
					end

					applyPackPurchasedRed(buy)
					setButtonEnabledNoOverlay(buy, state, false)
				else
					applyPackAvailableDefault(buy)
					setButtonEnabledNoOverlay(buy, state, true)
				end
			end
			player:GetAttributeChangedSignal(pack.boughtAttr):Connect(refresh)
			ownedBuyByProductId[pack.productId] = entry
			refresh()
		end
	end
end

local cashBundlePanels: { { panel: Instance, productId: number } } = {}

local function collectCashBundlePanels(container: Instance)
	local cash = container:FindFirstChild("Cash")
	if not cash then
		return
	end
	-- Ordered: column1[1], column1[2], column2[1], column2[2], column3[1] → bundles 1..5.
	local order = {
		{ "column1", "1", StoreConfig.PRODUCT.CASH_BUNDLE_1 },
		{ "column1", "2", StoreConfig.PRODUCT.CASH_BUNDLE_2 },
		{ "column2", "1", StoreConfig.PRODUCT.CASH_BUNDLE_3 },
		{ "column2", "2", StoreConfig.PRODUCT.CASH_BUNDLE_4 },
		{ "column3", "1", StoreConfig.PRODUCT.CASH_BUNDLE_5 },
	}
	for _, entry in order do
		local column = cash:FindFirstChild(entry[1])
		local panel = column and column:FindFirstChild(entry[2])
		if panel then
			table.insert(cashBundlePanels, { panel = panel, productId = entry[3] })
			local buy = findBuy(panel)
			if buy then
				wireBuyButton(buy, function()
					if UpgradesController.markCashBundlePurchasePending then
						UpgradesController.markCashBundlePurchasePending()
					end
					PurchasePrompt.promptProduct(entry[3])
				end)
			end
		end
	end
end

local function setCashBundleLabel(panel: Instance, productId: number, reward: number)
	local info = panel:FindFirstChild("Info")
	local amount = info and info:FindFirstChild("Amount")
	if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
		(amount :: TextLabel).Text = BrainrotEconomy.formatCashShort(reward)
	end
end

local function localPlacedIncomePerSecond(): number
	local total = 0
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		if stand:GetAttribute("StandOwnerUserId") == player.UserId then
			local name = stand:GetAttribute("BrainrotName")
			local rarity = stand:GetAttribute("BrainrotRarity")
			if typeof(name) == "string" and typeof(rarity) == "string" then
				local level = stand:GetAttribute("BrainrotLevel")
				local mutation = stand:GetAttribute("BrainrotMutation")
				local baseIncome = stand:GetAttribute("BrainrotBaseIncome")
				total += BrainrotEconomy.incomePerSecond({
					name = name,
					rarity = rarity,
					mutation = if typeof(mutation) == "string" then mutation else "normal",
					level = if typeof(level) == "number" then level else 1,
					baseIncome = if typeof(baseIncome) == "number" then baseIncome else 0,
				})
			end
		end
	end
	return total
end

local function effectiveOffline24hCash(): number
	local offline24h = localPlacedIncomePerSecond() * SECONDS_PER_DAY
	return math.max(offline24h, StoreConfig.MIN_OFFLINE_24H_CASH)
end

local function applyCashBundleLabelsFromEffective(effective: number)
	for _, entry in cashBundlePanels do
		local multiplier = StoreConfig.CASH_BUNDLE_MULTIPLIERS[entry.productId]
		if multiplier then
			local reward = math.floor(effective * multiplier)
			setCashBundleLabel(entry.panel, entry.productId, reward)
		end
	end
end

-- Remote tables stringify numeric keys, so check both number and string forms.
local function lookupCashBundleReward(rewards: { [any]: any }, productId: number): number?
	local reward = rewards[productId]
	if typeof(reward) == "number" then
		return reward
	end
	reward = rewards[tostring(productId)]
	if typeof(reward) == "number" then
		return reward
	end
	return nil
end

local function refreshCashBundles()
	if #cashBundlePanels == 0 then
		return
	end
	applyCashBundleLabelsFromEffective(effectiveOffline24hCash())
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("StoreRemotes", 15)
		local rf = folder and folder:WaitForChild("GetCashBundleRewards", 15)
		if not rf or not rf:IsA("RemoteFunction") then
			return
		end
		local ok, rewards = pcall(function()
			return rf:InvokeServer()
		end)
		if not ok then
			warn("[StoreController] GetCashBundleRewards failed:", rewards)
			return
		end
		if typeof(rewards) ~= "table" then
			return
		end
		for _, entry in cashBundlePanels do
			local reward = lookupCashBundleReward(rewards, entry.productId)
			if reward then
				setCashBundleLabel(entry.panel, entry.productId, reward)
			end
		end
	end)
end

local function wireServerLuck(container: Instance)
	local panel = container:FindFirstChild("ServerLuck")
	wireProduct(panel, StoreConfig.PRODUCT.SERVER_LUCK)

	-- "current → next" label, e.g. "1x > 2x" inactive, "2x > 4x" while a 2x boost is live.
	local label = panel and (panel:FindFirstChild("CurrentLuck") or panel:FindFirstChild("TextLabel"))
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		local function refresh()
			local mult = ReplicatedStorage:GetAttribute(StoreConfig.SERVER_LUCK_MULT_ATTR)
			local current = if typeof(mult) == "number" and mult > 1 then mult else 1
			local nextMult = current * 2
			(label :: TextLabel).Text = string.format("%dx > %dx", current, nextMult)
		end
		ReplicatedStorage:GetAttributeChangedSignal(StoreConfig.SERVER_LUCK_MULT_ATTR):Connect(refresh)
		refresh()
	end
end

local function wireFreeBrainrot(storeFrame: Instance)
	local quick = storeFrame:FindFirstChild("QuickButtons")
	local free = quick and quick:FindFirstChild("Free1")
	if not free or not free:IsA("GuiObject") then
		warn("[StoreController] Free1 quick button not found")
		return function() end
	end
	local freeGui = free :: GuiObject
	local remotesFolder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	local claimRE = remotesFolder and remotesFolder:FindFirstChild("ClaimFreeBrainrot")

	local freeCelebrated = false

	local function celebrateFreeClaim()
		if freeCelebrated then
			return
		end
		freeCelebrated = true
		GameSoundEffects.playPurchase()
		GameSoundEffects.playPurchaseShake()
		pcall(function()
			require(ReplicatedStorage.EssentialsShared.EffectsController).celebratePurchase(player)
		end)
	end

	local state = wireBuyButton(freeGui, function()
		if player:GetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED) == true then
			GameSoundEffects.playErrorNotif()
			return
		end
		local scale = getOrAddUIScale(freeGui)
		local pulse = TweenService:Create(scale, CLICK_TWEEN, { Scale = 1.12 })
		pulse.Completed:Once(function()
			TweenService:Create(scale, POP_TWEEN, { Scale = 1 }):Play()
		end)
		pulse:Play()

		local re = claimRE
			or (
				ReplicatedStorage:FindFirstChild("StoreRemotes")
				and ReplicatedStorage.StoreRemotes:FindFirstChild("ClaimFreeBrainrot")
			)
		if re and re:IsA("RemoteEvent") then
			re:FireServer()
		end
	end)

	local function refresh()
		local claimed = player:GetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED) == true
		if claimed then
			celebrateFreeClaim()
		end
		setButtonEnabled(freeGui, state, not claimed)
		-- Once claimed the whole QuickButtons strip is hidden.
		if quick and quick:IsA("GuiObject") then
			(quick :: GuiObject).Visible = not claimed
		end
	end
	player:GetAttributeChangedSignal(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED):Connect(refresh)
	refresh()
	return refresh
end

-- ── Init ──────────────────────────────────────────────────────────────────────────

local function init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[StoreController] Main ScreenGui missing")
		return
	end
	local frames = main:WaitForChild("Frames")
	local storeFrame = frames:WaitForChild("Store")
	local container = storeFrame:WaitForChild("StoreFrame"):WaitForChild("Container")

	-- Gamepass panels live across "Gamepasses" and "Gamepasses2".
	local gamepassContainers = { container:FindFirstChild("Gamepasses"), container:FindFirstChild("Gamepasses2") }
	wireGamePass(gamepassContainers, "2xCash", StoreConfig.GAMEPASS.DOUBLE_CASH, StoreConfig.ATTR.DOUBLE_CASH_OWNED)
	wireGamePass(
		gamepassContainers,
		"2xUpgrades",
		StoreConfig.GAMEPASS.DOUBLE_UPGRADES,
		StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED
	)
	wireGamePass(gamepassContainers, "SuperLuck", StoreConfig.GAMEPASS.SUPER_LUCK, StoreConfig.ATTR.SUPER_LUCK_OWNED)
	wireGamePass(gamepassContainers, "MEGALuck", StoreConfig.GAMEPASS.MEGA_LUCK, StoreConfig.ATTR.MEGA_LUCK_OWNED)
	wireGamePass(gamepassContainers, "XrayVision", StoreConfig.GAMEPASS.XRAY, StoreConfig.ATTR.XRAY_OWNED)

	-- VIP panel sits directly under Container.
	do
		local vipBuy = findBuy(container:FindFirstChild("VIP"))
		if vipBuy then
			local vipState = wireBuyButton(vipBuy, function()
				PurchasePrompt.promptGamePass(StoreConfig.GAMEPASS.VIP)
			end)
			local vipEntry: OwnedBuyEntry = {
				buy = vipBuy,
				state = vipState,
				ownedAttr = StoreConfig.ATTR.VIP_OWNED,
			}
			ownedBuyByGamePassId[StoreConfig.GAMEPASS.VIP] = vipEntry
			player:GetAttributeChangedSignal(StoreConfig.ATTR.VIP_OWNED):Connect(function()
				refreshOwnedBuy(vipEntry)
			end)
			refreshOwnedBuy(vipEntry)
		end
	end

	wireProduct(container.RandomBrainrot, 3604806744)

	local randomBrainrotPanel = container:FindFirstChild("RandomBrainrot")
	if randomBrainrotPanel then
		local chancesHost = randomBrainrotPanel:FindFirstChild("Chances", true)
		if chancesHost and chancesHost:IsA("GuiObject") then
			local chancesBtn: GuiButton

			if chancesHost:IsA("GuiButton") then
				chancesBtn = chancesHost :: GuiButton
			else
				chancesBtn = ensureClickButton(chancesHost :: GuiObject)
			end

			HUDController.applyHoverAndClick(chancesBtn, function()
				HUDController.openFrameByName("Chances")
			end)
		else
			warn("[StoreController] Chances button not found inside RandomBrainrot")
		end
	else
		warn("[StoreController] RandomBrainrot panel not found")
	end

	wireExclusive(container)
	wireServerLuck(container)
	wirePacks(container)

	collectCashBundlePanels(container)
	applyCashBundleLabelsFromEffective(effectiveOffline24hCash())

	local refreshFreeBrainrot = wireFreeBrainrot(storeFrame)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if plr ~= player or not wasPurchased then
			return
		end
		local entry = ownedBuyByGamePassId[gamePassId]
		if entry then
			applyOptimisticPurchase(entry)
		end
		task.defer(function()
			local deferredEntry = ownedBuyByGamePassId[gamePassId]
			if deferredEntry then
				refreshOwnedBuy(deferredEntry)
			end
		end)
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		local entry = ownedBuyByProductId[productId]
		if not entry then
			return
		end
		if entry.ownedAttr == StoreConfig.ATTR.EXCLUSIVE_OWNED then
			applyOptimisticPurchase(entry)
			task.defer(function()
				refreshOwnedBuy(entry)
			end)
			return
		end
		task.defer(function()
			local bought = player:GetAttribute(entry.ownedAttr)
			local count = if typeof(bought) == "number" then bought else 0
			local remaining = math.max(0, StoreConfig.PACK_PURCHASE_LIMIT - count)
			if remaining <= 0 then
				applyPackPurchasedRed(entry.buy)
				setButtonEnabledNoOverlay(entry.buy, entry.state, false)
			else
				applyPackAvailableDefault(entry.buy)
				setButtonEnabledNoOverlay(entry.buy, entry.state, true)
			end
		end)
	end)

	task.spawn(function()
		local storeRemotes = ReplicatedStorage:WaitForChild("StoreRemotes", 30)
		local closeRE = storeRemotes and storeRemotes:WaitForChild("CloseStore", 30)
		if closeRE and closeRE:IsA("RemoteEvent") then
			closeRE.OnClientEvent:Connect(function()
				HUDController.closeFrameByName("Store")
			end)
		end
	end)

	-- Refresh dynamic labels when the store opens and periodically while open.
	local function onStoreVisibility()
		if storeFrame.Visible then
			refreshCashBundles()
			refreshFreeBrainrot()
		end
	end
	storeFrame:GetPropertyChangedSignal("Visible"):Connect(onStoreVisibility)
	onStoreVisibility()

	task.spawn(function()
		while true do
			task.wait(4)
			if storeFrame.Visible then
				refreshCashBundles()
			end
		end
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[StoreController]", err)
	end
end

StoreController.init = boot
return StoreController
