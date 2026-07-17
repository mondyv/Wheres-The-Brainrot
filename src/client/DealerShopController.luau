-- [ACTIVE] DealerShopController
--[[
	Wires Main.Frames.Shop (Brainrot Dealer panel):
	• Populates Container["1"].."[7]" from DealerRemotes.GetState.
	• Cash buy / Robux buy / Locked (rebirth gate) / Out of stock states.
	• Stock is per-player remaining (optimistic tick on cash buy).
	• Cash price = incomePerSecond × DealerConfig.CASH_PRICE_MULTIPLIER (10×).
	• Sold-out shows Studio OutOfStock (+ its existing UIGradient); row stays visible.
	• Header.Buttons.Restock -> personal restock dev product.
	• Restock countdown label + live refresh on DealerRemotes.StateChanged.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DealerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DealerConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local PanelSlideIn = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PanelSlideIn"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local MainGradientButtons = require(script.Parent.MainGradientButtons)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local TopNotifController = require(script.Parent.TopNotifController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer

type SlotData = {
	index: number,
	name: string,
	displayName: string,
	rarity: string,
	icon: string,
	cashPrice: number,
	-- Player's remaining buyable stock for this slot (personal, not global).
	stock: number?,
	stockPersonal: number?,
	stockStart: number?,
	stockGlobal: number?, -- legacy; ignored (always treat as 0)
	robuxBought: number,
	robuxMax: number,
	rebirthsNeeded: number,
	locked: boolean,
}

type DealerStatePayload = {
	nextRestockAt: number,
	slots: { SlotData },
}

local getStateRF: RemoteFunction? = nil
local buyCashRF: RemoteFunction? = nil
local buyRobuxRF: RemoteFunction? = nil
local stateChangedRE: RemoteEvent? = nil
local restockNotifyRE: RemoteEvent? = nil

local nextRestockAt = 0
local lastState: DealerStatePayload? = nil
local rowByIndex: { [number]: Instance } = {}
local buyInFlight: { [number]: boolean } = {}
local wiredBuyHosts: { [GuiObject]: boolean } = {}
local shopFrame: Frame? = nil
local comingSoonLabel: Instance? = nil

-- Forward declaration: tryBuyCash applies optimistic stock then reconciles a
-- lightweight { index, stock } delta from BuyCash (no full GetState re-fetch).
local refreshFromServer: () -> ()
local applyState: (DealerStatePayload) -> ()

-- Roblox injects a Robux glyph at this private-use codepoint for every TextLabel
-- font, regardless of Font/FontFace — same trick used by the in-game Marketplace UI.
local ROBUX_ICON = utf8.char(0xE002)

local ERROR_MESSAGE_BY_REASON: { [string]: string } = {
	locked = "Rebirth more to unlock this Brainrot!",
	empty_slot = "That listing is empty right now.",
	unknown_brainrot = "That listing is empty right now.",
	sold_out = "Sold out — wait for the next restock.",
	out_of_stock = "Sold out — wait for the next restock.",
	grant_failed = "Something went wrong. Try again.",
	internal_error = "Something went wrong. Try again.",
	bad_slot = "Something went wrong. Try again.",
	busy = "Hang on — still processing your last purchase.",
}

local function waitRemotes()
	if getStateRF then
		return
	end
	local folder = ReplicatedStorage:WaitForChild("DealerRemotes", 30)
	if not folder then
		warn("[DealerShopController] ReplicatedStorage.DealerRemotes missing")
		return
	end
	getStateRF = folder:WaitForChild("GetState", 30) :: RemoteFunction?
	buyCashRF = folder:WaitForChild("BuyCash", 30) :: RemoteFunction?
	buyRobuxRF = folder:WaitForChild("BuyRobuxPrompt", 30) :: RemoteFunction?
	stateChangedRE = folder:WaitForChild("StateChanged", 30) :: RemoteEvent?
	restockNotifyRE = folder:WaitForChild("RestockNotify", 30) :: RemoteEvent?
end

local function formatCash(n: number): string
	return BrainrotEconomy.formatCashShort(n)
end

-- ── Generic clickable-button lookup (mirrors UpgradesController.resolveBuyButton) ──

local function isUnderDecor(inst: Instance, root: Instance): boolean
	local p: Instance? = inst.Parent
	while p and p ~= root do
		if p.Name == "Decor" then
			return true
		end
		p = p.Parent
	end
	return false
end

local function findClickableButton(host: Instance): GuiButton?
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local best: GuiButton? = nil
	local bestScore = -1
	for _, d in host:GetDescendants() do
		if not d:IsA("GuiButton") or isUnderDecor(d, host) then
			continue
		end
		local guiObj = d :: GuiButton
		local area = guiObj.AbsoluteSize.X * guiObj.AbsoluteSize.Y
		if area > bestScore then
			bestScore = area
			best = guiObj
		end
	end
	if not best then
		best = host:FindFirstChildWhichIsA("GuiButton", true)
	end
	return best
end

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

-- Full-coverage transparent click-catcher on the Buy/Out / BuyRobux host.
-- Descendants are forced Active=false so Labels/Frames cannot eat input
-- (same pattern as RebirthController / StoreController).
local function ensureOverlayClickButton(host: GuiObject): GuiButton
	for _, d in host:GetDescendants() do
		if d.Name == "_DealerClick" then
			continue
		end
		if d:IsA("GuiObject") then
			(d :: GuiObject).Active = false
		end
	end
	if host:IsA("GuiButton") then
		(host :: GuiButton).Active = true
	elseif host:IsA("GuiObject") then
		host.Active = false
	end

	local existing = host:FindFirstChild("_DealerClick")
	if existing and existing:IsA("GuiButton") then
		local btn = existing :: GuiButton
		btn.Active = true
		btn.ZIndex = 1000
		btn.Size = UDim2.fromScale(1, 1)
		btn.Position = UDim2.fromScale(0.5, 0.5)
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		return btn
	end
	if existing then
		existing:Destroy()
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_DealerClick"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.TextTransparency = 1
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 1000
	btn.Active = true
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Parent = host
	return btn
end

-- Scale + glisten/sweep on the visible host; click fires from the overlay.
-- UIScale must live on the host — putting it on the invisible overlay made
-- hover look broken and shrinking the overlay cancelled Activated.
local function wireDealerHostButton(host: GuiObject, onClick: () -> (), withPolish: boolean)
	if wiredBuyHosts[host] then
		ensureOverlayClickButton(host)
		return
	end
	wiredBuyHosts[host] = true

	local scale = getOrAddUIScale(host)
	local btn = ensureOverlayClickButton(host)
	local hovering = false
	local lastFire = 0

	local function fireClick()
		local now = os.clock()
		if now - lastFire < 0.12 then
			return
		end
		lastFire = now
		onClick()
	end

	btn.MouseEnter:Connect(function()
		hovering = true
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		if withPolish then
			UIButtonEffects.playBorderGlisten(host)
			UIButtonEffects.playDiagonalSweep(host)
		end
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		-- Fire on Down: scaling the host shrinks _DealerClick and cancels Activated.
		fireClick()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = if hovering then 1.06 else 1 }):Play()
	end)
end

-- ── Row visuals ──────────────────────────────────────────────────────────────────

local function findOutOfStockLabel(stockFrame: Instance): Instance?
	local direct = stockFrame:FindFirstChild("OutOfStock")
	if direct and not direct:IsA("UIGradient") then
		return direct
	end
	for _, d in stockFrame:GetDescendants() do
		if d.Name == "OutOfStock" and (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("ImageLabel")) then
			return d
		end
	end
	if direct then
		return direct
	end
	return stockFrame:FindFirstChild("OutOfStock", true)
end

local function setStockLabels(row: Instance, effectiveStock: number)
	local info = row:FindFirstChild("Info")
	local stockFrame = info and info:FindFirstChild("Stock")
	if not stockFrame then
		return
	end
	if stockFrame:IsA("GuiObject") then
		(stockFrame :: GuiObject).Visible = true
	end
	local inStock = effectiveStock > 0
	local stockText = string.format("Stock: %dx", effectiveStock)

	local stockLabel = stockFrame:FindFirstChild("Stock")
	local outLabel = findOutOfStockLabel(stockFrame)

	-- Toggle Studio-authored OutOfStock (+ every existing UIGradient). Never create gradients.
	local function setGradientsEnabled(root: Instance?, enabled: boolean)
		if not root then
			return
		end
		if root:IsA("UIGradient") then
			(root :: UIGradient).Enabled = enabled
		end
		for _, d in root:GetDescendants() do
			if d:IsA("UIGradient") then
				(d :: UIGradient).Enabled = enabled
			end
		end
		local own = root:FindFirstChildOfClass("UIGradient")
		if own and own:IsA("UIGradient") then
			own.Enabled = enabled
		end
	end

	local function applyOutOfStockVisual(oos: Instance?, showOos: boolean)
		if not oos then
			return
		end
		if oos:IsA("UIGradient") then
			(oos :: UIGradient).Enabled = showOos
			return
		end
		if oos:IsA("GuiObject") then
			(oos :: GuiObject).Visible = showOos
		end
		if showOos and (oos:IsA("TextLabel") or oos:IsA("TextButton")) then
			local text = (oos :: any).Text
			if typeof(text) ~= "string" or text == "" then
				(oos :: any).Text = "OUT OF STOCK"
			end
		end
		setGradientsEnabled(oos, showOos)
	end

	local function applyStockFrameOosGradients(showOos: boolean)
		for _, d in stockFrame:GetChildren() do
			if d:IsA("UIGradient") then
				local n = string.lower(d.Name)
				if n == "outofstock" or n == "out of stock" or n == "oos" or string.find(n, "outofstock", 1, true) then
					(d :: UIGradient).Enabled = showOos
				end
			end
		end
	end

	if inStock then
		applyOutOfStockVisual(outLabel, false)
		applyStockFrameOosGradients(false)
		if stockLabel and stockLabel:IsA("GuiObject") then
			if stockFrame:IsA("TextLabel") or stockFrame:IsA("TextButton") then
				(stockFrame :: any).Text = ""
			end
			stockLabel.Visible = true
			if stockLabel:IsA("TextLabel") or stockLabel:IsA("TextButton") then
				(stockLabel :: any).Text = stockText
			end
			setGradientsEnabled(stockLabel, true)
		elseif stockFrame:IsA("TextLabel") or stockFrame:IsA("TextButton") then
			(stockFrame :: any).Text = stockText
		end
	else
		if stockLabel and stockLabel:IsA("GuiObject") then
			stockLabel.Visible = false
			setGradientsEnabled(stockLabel, false)
		end
		if stockFrame:IsA("TextLabel") or stockFrame:IsA("TextButton") then
			(stockFrame :: any).Text = ""
		end
		applyOutOfStockVisual(outLabel, true)
		applyStockFrameOosGradients(true)
		if outLabel and outLabel:IsA("GuiObject") then
			for _, d in outLabel:GetDescendants() do
				if d:IsA("UIGradient") then
					(d :: UIGradient).Enabled = true
				end
			end
			local directGrad = outLabel:FindFirstChildOfClass("UIGradient")
			if directGrad then
				directGrad.Enabled = true
			end
		end
	end
end

-- Toggles one named Buy/Out-Locked visual variant. The variant node itself may
-- be a UIGradient (the common case for Buy/Out.Buy & Buy/Out["Out/Locked"]), a
-- Frame, or an ImageLabel — so we must switch the RIGHT property on the variant
-- node AND on every nested UIGradient. Previously a variant that WAS a
-- UIGradient never had its Enabled set (GetDescendants excludes the node
-- itself, and a UIGradient isn't a GuiObject), so the green "Buy" gradient was
-- never enabled and every cash button stayed gray.
local function setVariantNodeActive(node: Instance, active: boolean)
	if node:IsA("UIGradient") then
		node.Enabled = active
	elseif node:IsA("GuiObject") then
		node.Visible = active
	end
	-- Hiding a Frame/ImageLabel variant already hides its subtree, but a nested
	-- UIGradient's Enabled is independent of ancestor Visible, so flip those too.
	for _, d in node:GetDescendants() do
		if d:IsA("UIGradient") then
			d.Enabled = active
		end
	end
end

local function setButtonVariantActive(container: Instance?, variantName: string, active: boolean)
	local variant = container and container:FindFirstChild(variantName)
	if not variant then
		return
	end
	setVariantNodeActive(variant, active)
end

local function applyCashButtonVisual(cashHost: Instance, canBuy: boolean, price: number)
	if not cashHost:IsA("GuiObject") then
		return
	end
	-- Price stays visible in every state; the Stock label owns the "sold out"
	-- messaging, so we never overwrite the cost with "OUT".
	local costLabel = cashHost:FindFirstChild("Cost", true)
	if costLabel and (costLabel:IsA("TextLabel") or costLabel:IsA("TextButton")) then
		(costLabel :: any).Text = formatCash(price)
	end
	local amountLabel = cashHost:FindFirstChild("Amount", true)
	if amountLabel and amountLabel:IsA("TextLabel") then
		amountLabel.Text = "1x"
	end

	setButtonVariantActive(cashHost, "Buy", canBuy)
	setButtonVariantActive(cashHost, "Out/Locked", not canBuy)

	local decor = cashHost:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	if stud then
		setButtonVariantActive(stud, "Buy", canBuy)
		setButtonVariantActive(stud, "Out/Locked", not canBuy)
	end
end

local function applyRobuxButtonVisual(robuxHost: Instance, soldOut: boolean)
	if not robuxHost:IsA("GuiObject") then
		return
	end
	local priceLabel = robuxHost:FindFirstChild("Price", true)
	if priceLabel and priceLabel:IsA("TextLabel") then
		priceLabel.Text = ROBUX_ICON .. tostring(DealerConfig.ROBUX_BUY_PRICE_DISPLAY)
	end
	local amountLabel = robuxHost:FindFirstChild("Amount", true)
	if amountLabel and amountLabel:IsA("TextLabel") then
		amountLabel.Text = "1x"
	end
	if soldOut then
		MainGradientButtons.applyPurchased(robuxHost :: GuiObject, "OUT")
	else
		MainGradientButtons.applyDefault(robuxHost :: GuiObject)
	end
end

local function applyRarityBadges(row: Instance, rarity: string)
	local iconFrame = row:FindFirstChild("IconFrame")
	local iconRarity = iconFrame and iconFrame:FindFirstChild("Rarity")
	if iconRarity then
		BrainrotHeaderStyle.applyRarityLabel(iconRarity, rarity)
	end
	local info = row:FindFirstChild("Info")
	local infoRarity = info and info:FindFirstChild("Rarity")
	if infoRarity then
		BrainrotHeaderStyle.applyRarityLabel(infoRarity, rarity)
	end
	local stroke = row:FindFirstChildOfClass("UIStroke")
	if stroke then
		BrainrotHeaderStyle.applyRarityStroke(stroke, rarity)
	end
end

local function refreshRow(row: Instance, slot: SlotData)
	-- Only hide truly empty catalog holes. Sold-out listings (stock==0) MUST
	-- stay visible with the gray Buy / "Sold out" stock label.
	if slot.name == "" then
		row.Visible = false
		return
	end
	row.Visible = true

	local iconFrame = row:FindFirstChild("IconFrame")
	local icon = iconFrame and iconFrame:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.ScaleType = Enum.ScaleType.Fit
		if slot.icon ~= "" then
			icon.Image = slot.icon
		end
	end

	local info = row:FindFirstChild("Info")
	local nameLabel = info and info:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = slot.displayName
	end

	applyRarityBadges(row, slot.rarity)

	-- Personal remaining stock only — cash buys never share a global pool.
	local effectiveStock = math.max(0, slot.stock or slot.stockPersonal or 0)
	-- Buy is green whenever it's unlocked by rebirth and in stock. Affordability
	-- is NOT part of the green gate — the server rejects an unaffordable press
	-- with "cant_afford" and we surface that as a toast, matching the requested
	-- behaviour (green = in stock & unlocked, gray = sold out or rebirth-locked).
	local canBuyCash = (not slot.locked) and effectiveStock > 0
	setStockLabels(row, effectiveStock)

	local buyButtons = row:FindFirstChild("BuyButtons")
	local locked = row:FindFirstChild("Locked")

	if locked then
		locked.Visible = slot.locked
		if locked:IsA("GuiObject") then
			-- Active=false while hidden so a leftover Locked frame can never
			-- eat clicks meant for the Buy/Out button underneath it.
			(locked :: GuiObject).Active = slot.locked
		end
		local amountNeeded = locked:FindFirstChild("AmountNeeded")
		if amountNeeded and amountNeeded:IsA("TextLabel") then
			amountNeeded.Text = string.format("You Need %d Rebirths", slot.rebirthsNeeded)
		end
	end
	if buyButtons and buyButtons:IsA("GuiObject") then
		buyButtons.Visible = not slot.locked
	end

	if buyButtons then
		local cashHost = buyButtons:FindFirstChild("Buy/Out")
		if cashHost then
			applyCashButtonVisual(cashHost, canBuyCash, slot.cashPrice)
			-- Re-assert overlay + Active=false on visual children after variant toggles.
			if cashHost:IsA("GuiObject") then
				ensureOverlayClickButton(cashHost :: GuiObject)
			end
		end
		local robuxHost = buyButtons:FindFirstChild("BuyRobux")
		if robuxHost then
			applyRobuxButtonVisual(robuxHost, slot.robuxBought >= slot.robuxMax)
			if robuxHost:IsA("GuiObject") then
				ensureOverlayClickButton(robuxHost :: GuiObject)
			end
		end
	end
end

-- ── Purchase actions ─────────────────────────────────────────────────────────────

local function showReasonError(reason: string?)
	if reason == "cant_afford" then
		TopNotifController.showCantAfford()
		return
	end
	TopNotifController.showError(if reason then (ERROR_MESSAGE_BY_REASON[reason] or "Something went wrong. Try again.") else "Something went wrong. Try again.")
end

local function currentEffectiveStock(index: number): number
	if not lastState then
		return -1
	end
	for _, slot in lastState.slots do
		if slot.index == index then
			return math.max(0, slot.stock or slot.stockPersonal or 0)
		end
	end
	return -1
end

local function applyOptimisticStockDecrement(index: number)
	if not lastState then
		return
	end
	local slots = table.clone(lastState.slots)
	for i, slot in slots do
		if slot.index == index then
			local nextSlot = table.clone(slot)
			local remaining = math.max(0, (slot.stock or slot.stockPersonal or 0) - 1)
			nextSlot.stock = remaining
			nextSlot.stockPersonal = remaining
			slots[i] = nextSlot
			break
		end
	end
	applyState({
		nextRestockAt = lastState.nextRestockAt,
		slots = slots,
	})
end

local function applyStockAt(index: number, remaining: number)
	if not lastState then
		return
	end
	local stock = math.max(0, math.floor(remaining))
	local slots = table.clone(lastState.slots)
	for i, slot in slots do
		if slot.index == index then
			local nextSlot = table.clone(slot)
			nextSlot.stock = stock
			nextSlot.stockPersonal = stock
			slots[i] = nextSlot
			break
		end
	end
	applyState({
		nextRestockAt = lastState.nextRestockAt,
		slots = slots,
	})
end

local function tryBuyCash(index: number)
	if buyInFlight[index] or not buyCashRF then
		return
	end
	local prevStock = currentEffectiveStock(index)
	if prevStock <= 0 then
		showReasonError("out_of_stock")
		return
	end
	buyInFlight[index] = true
	-- Optimistic UI first — stock tick + gray Buy — before any server round-trip.
	applyOptimisticStockDecrement(index)

	task.spawn(function()
		local ok, granted, reason, delta = pcall(function()
			return (buyCashRF :: RemoteFunction):InvokeServer(index)
		end)
		buyInFlight[index] = nil
		if not ok then
			warn("[DealerShopController] BuyCash invoke failed:", granted)
			applyStockAt(index, prevStock)
			refreshFromServer()
			return
		end
		-- Prefer lightweight { index, stock } delta — never re-fetch full GetState after a buy.
		if typeof(delta) == "table" then
			local d = delta :: any
			if typeof(d.stock) == "number" and (typeof(d.index) == "number" or d.index == nil) then
				applyStockAt(if typeof(d.index) == "number" then d.index else index, d.stock)
			elseif typeof(d.slots) == "table" then
				applyState(d :: DealerStatePayload)
			end
		end
		if not granted then
			if typeof(delta) ~= "table" or typeof((delta :: any).stock) ~= "number" then
				applyStockAt(index, prevStock)
			end
			showReasonError(reason)
		end
	end)
end

local function tryBuyRobux(index: number)
	if buyInFlight[index] or not buyRobuxRF then
		return
	end
	buyInFlight[index] = true
	local ok, approved, reason = pcall(function()
		return (buyRobuxRF :: RemoteFunction):InvokeServer(index)
	end)
	buyInFlight[index] = nil
	if not ok then
		warn("[DealerShopController] BuyRobuxPrompt invoke failed:", approved)
		return
	end
	if not approved then
		showReasonError(reason)
		return
	end
	local promptOk, promptErr = pcall(function()
		PurchasePrompt.promptProduct(DealerConfig.PRODUCT.ROBUX_BUY_1X)
	end)
	if not promptOk then
		warn("[DealerShopController] Robux buy prompt failed:", promptErr)
	end
end

-- Stamps the stable server slot id onto the row itself (not just captured in
-- a closure) so Buy always targets the original offering, never the visual
-- LayoutOrder/row position sortedByUnlockedFirst assigns for display.
local function wireRowButtons(row: Instance, index: number)
	row:SetAttribute("SlotId", index)
	local buyButtons = row:FindFirstChild("BuyButtons")
	if not buyButtons then
		return
	end
	local cashHost = buyButtons:FindFirstChild("Buy/Out")
	if cashHost and cashHost:IsA("GuiObject") then
		wireDealerHostButton(cashHost :: GuiObject, function()
			tryBuyCash((row:GetAttribute("SlotId") :: number?) or index)
		end, true)
	end
	local robuxHost = buyButtons:FindFirstChild("BuyRobux")
	if robuxHost and robuxHost:IsA("GuiObject") then
		wireDealerHostButton(robuxHost :: GuiObject, function()
			tryBuyRobux((row:GetAttribute("SlotId") :: number?) or index)
		end, true)
	end
end

-- ── State fetch / refresh ────────────────────────────────────────────────────────

-- Order: rebirth-locked listings sink to the bottom; within each group
-- (unlocked, then locked) sort by ascending rarity rank so Common comes before
-- Uncommon before Rare, etc.; ties fall back to stable slot index so rows don't
-- jitter between refreshes.
local function sortedByUnlockedFirst(slots: { SlotData }): { SlotData }
	local ordered = table.clone(slots)
	table.sort(ordered, function(a, b)
		if a.locked ~= b.locked then
			return not a.locked
		end
		local aRank = DealerConfig.rarityRank(a.rarity)
		local bRank = DealerConfig.rarityRank(b.rarity)
		if aRank ~= bRank then
			return aRank < bRank
		end
		return a.index < b.index
	end)
	return ordered
end

function applyState(state: DealerStatePayload)
	lastState = state
	nextRestockAt = state.nextRestockAt

	local anyOffering = false
	local ordered = sortedByUnlockedFirst(state.slots)
	for order, slot in ordered do
		if slot.name ~= "" then
			anyOffering = true
		end
		local row = rowByIndex[slot.index]
		if row then
			if row:IsA("GuiObject") then
				row.LayoutOrder = order
			end
			refreshRow(row, slot)
		end
	end

	if comingSoonLabel and comingSoonLabel:IsA("GuiObject") then
		comingSoonLabel.Visible = not anyOffering
	end
end

function refreshFromServer()
	waitRemotes()
	if not getStateRF then
		return
	end
	local ok, state = pcall(function()
		return (getStateRF :: RemoteFunction):InvokeServer()
	end)
	if not ok then
		warn("[DealerShopController] GetState invoke failed:", state)
		return
	end
	if typeof(state) == "table" then
		applyState(state :: any)
	end
end

local function playShopOpenSlide()
	if not shopFrame then
		return
	end
	local container = shopFrame:FindFirstChild("Container")
	local rows: { GuiObject } = {}
	for i = 1, DealerConfig.SLOT_COUNT do
		local row = rowByIndex[i]
		if row and row:IsA("GuiObject") and row.Visible then
			table.insert(rows, row)
		end
	end
	if #rows == 0 and container then
		rows = PanelSlideIn.collectVisibleGuiChildren(container, {
			["Coming Soon text"] = true,
			UIListLayout = true,
			UIPadding = true,
			UICorner = true,
		})
	end
	if #rows > 0 then
		PanelSlideIn.slideInSequence(rows, {
			from = "Left",
			stagger = 0.05,
			distance = 64,
		})
	end
end

local function formatCountdown(secondsLeft: number): string
	local s = math.max(0, math.floor(secondsLeft))
	local m = s // 60
	local r = s % 60
	return string.format("%d:%02d", m, r)
end

-- ── Init ──────────────────────────────────────────────────────────────────────

local function init()
	local main = PlayerGuiMain.ensure(player)
	MainGradientButtons.init(main)

	local frames = main:WaitForChild("Frames")
	local shop = frames:WaitForChild("Shop") :: Frame
	shopFrame = shop

	local header = shop:WaitForChild("Header")
	local container = shop:WaitForChild("Container")

	comingSoonLabel = container:FindFirstChild("Coming Soon text")

	local containerLayout = container:FindFirstChildOfClass("UIListLayout")
	if containerLayout then
		containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	for i = 1, DealerConfig.SLOT_COUNT do
		local row = container:FindFirstChild(tostring(i))
		if row then
			rowByIndex[i] = row
			wireRowButtons(row, i)
		else
			warn("[DealerShopController] Container row missing:", i)
		end
	end

	local headerButtons = header:FindFirstChild("Buttons")
	local closeBtn = headerButtons and headerButtons:FindFirstChild("Close")
	if closeBtn and closeBtn:IsA("GuiButton") then
		UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
			local HUDController = require(script.Parent.HUDController)
			HUDController.closeCurrentFrame()
		end)
	end

	local restockBtnHost = headerButtons and headerButtons:FindFirstChild("Restock")
	if restockBtnHost then
		local restockBtn = findClickableButton(restockBtnHost)
		if restockBtn then
			UIButtonEffects.wireAccentButton(restockBtn, function()
				local promptOk, promptErr = pcall(function()
					PurchasePrompt.promptProduct(DealerConfig.PRODUCT.PERSONAL_RESTOCK)
				end)
				if not promptOk then
					warn("[DealerShopController] personal restock prompt failed:", promptErr)
				end
			end)
		end
	end

	-- Direct child of the Shop frame (distinct from Header.Buttons.Restock).
	local timerLabel = shop:FindFirstChild("Restock")
	if timerLabel then
		task.spawn(function()
			while shop.Parent do
				if shop.Visible then
					local text = timerLabel :: any
					local textNode = if text:IsA("TextLabel") then text else text:FindFirstChildWhichIsA("TextLabel")
					if textNode then
						textNode.Text = "Restocks in " .. formatCountdown(nextRestockAt - os.time())
					end
				end
				task.wait(1)
			end
		end)
	end

	shop:GetPropertyChangedSignal("Visible"):Connect(function()
		if shop.Visible then
			refreshFromServer()
			playShopOpenSlide()
		else
			PanelSlideIn.cancel()
		end
	end)

	waitRemotes()
	if stateChangedRE then
		stateChangedRE.OnClientEvent:Connect(function()
			refreshFromServer()
		end)
	end
	if restockNotifyRE then
		restockNotifyRE.OnClientEvent:Connect(function()
			refreshFromServer()
		end)
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, wasPurchased: boolean)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if productId == DealerConfig.PRODUCT.PERSONAL_RESTOCK or productId == DealerConfig.PRODUCT.ROBUX_BUY_1X then
			task.delay(0.3, refreshFromServer)
		end
	end)

	-- Cash accrues every second from idle income; re-render the already-fetched
	-- state locally (no server round trip) so a Buy button that was greyed out
	-- for affordability flips green the instant the player can cover it, and
	-- vice versa if their balance just dropped from another purchase.
	player:GetAttributeChangedSignal("Cash"):Connect(function()
		if lastState then
			applyState(lastState)
		end
	end)

	refreshFromServer()

	-- Safety-net refresh in case a StateChanged/RestockNotify event is ever missed.
	task.spawn(function()
		while true do
			task.wait(15)
			if shop.Parent and shop.Visible then
				refreshFromServer()
			end
		end
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[DealerShopController] Main.Frames.Shop not ready or missing:", err)
	end
end

return {
	init = boot,
}
