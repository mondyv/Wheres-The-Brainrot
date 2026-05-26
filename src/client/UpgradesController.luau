-- Wires Main.Frames.Upgrades rows + SideUI cash counter; purchase via server RemoteFunction
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local SwingUpgrades = require(ReplicatedStorage.Shared.SwingUpgrades)
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local player = Players.LocalPlayer

local purchaseFn = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PurchaseSwingUpgrade") :: RemoteFunction
local prepareRobuxRE = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PrepareRobuxUpgrade") :: RemoteEvent

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function purchaseCount(upgradeId: string): number
	local v = player:GetAttribute(SwingUpgrades.buysAttributeName(upgradeId))
	return if typeof(v) == "number" then math.floor(v) else 0
end

local function priceForUpgrade(upgradeId: string): number
	local def = (SwingUpgrades :: any)[upgradeId]
	if not def then
		return 0
	end
	return SwingUpgrades.priceAtTier(def, purchaseCount(upgradeId))
end

local function labelBonus(def: any): number
	return SwingUpgrades.displayBonus(def)
end

local function displayStatForAttr(attr: string): number
	return SwingUpgrades.displayStatTotal(attr, purchaseCount)
end

local function formatCash(n: number): string
	return BrainrotEconomy.formatCashShort(n)
end

local function waitMain(): ScreenGui
	-- Match other controllers: PlayerGui often mirrors StarterGui after character exists
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	return player:WaitForChild("PlayerGui"):WaitForChild("Main", 120) :: ScreenGui
end

local function findLabelUnder(parent: Instance, names: { string }): TextLabel?
	for _, n in names do
		local inst = parent:FindFirstChild(n, true)
		if inst and inst:IsA("TextLabel") then
			return inst
		end
	end
	return nil
end

-- Prefer the real purchase control: not inside Decor, largest hit target; avoid decorative GuiButtons
local function resolveBuyButton(buyButtons: Instance): (GuiObject?, GuiButton?)
	local holder = buyButtons:FindFirstChild("Buy")
	if not holder then
		return nil, nil
	end

	if holder:IsA("GuiButton") then
		return holder, holder
	end

	local best: GuiButton? = nil
	local bestScore = -1

	for _, d in holder:GetDescendants() do
		if not d:IsA("GuiButton") then
			continue
		end
		local underDecor = false
		local p: Instance? = d.Parent
		while p and p ~= holder do
			if p.Name == "Decor" then
				underDecor = true
				break
			end
			p = p.Parent
		end
		if underDecor then
			continue
		end
		local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
		local score = area + (if d:IsA("ImageButton") or d:IsA("TextButton") then 1e6 else 0)
		if score > bestScore then
			bestScore = score
			best = d
		end
	end

	-- Some layouts put the only clickable under Decor; pick largest if nothing found above
	if not best then
		bestScore = -1
		for _, d in holder:GetDescendants() do
			if d:IsA("GuiButton") then
				local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
				local score = area + (if d:IsA("ImageButton") or d:IsA("TextButton") then 1e6 else 0)
				if score > bestScore then
					bestScore = score
					best = d
				end
			end
		end
	end

	-- Direct-child ImageButton / TextButton on holder (common layout)
	if not best then
		for _, name in { "ImageButton", "TextButton" } do
			local ch = holder:FindFirstChild(name)
			if ch and ch:IsA("GuiButton") then
				return holder, ch
			end
		end
	end

	if not best then
		best = holder:FindFirstChildWhichIsA("GuiButton", true)
	end

	if best and holder:IsA("GuiObject") then
		-- Frame "Buy" often sits on top of the real button and steals clicks — don't absorb hits
		if not holder:IsA("GuiButton") then
			holder.Active = false
		end
		-- Any GuiObject above the button (Decor chain) must not eat inputs
		local p: Instance? = best.Parent
		while p and p ~= holder do
			if p:IsA("GuiObject") then
				p.Active = false
			end
			p = p.Parent
		end
		-- Decorative layers should not block the purchase button
		for _, d in holder:GetDescendants() do
			if d:IsA("GuiObject") and d ~= best and not best:IsDescendantOf(d) and not d:IsAncestorOf(best) then
				if d:IsA("ImageLabel") or d:IsA("TextLabel") or d:IsA("Frame") then
					d.Active = false
				end
			end
		end
	end

	return holder, best
end

local function styleAffordButton(btn: GuiButton?, canAfford: boolean)
	if not btn then
		return
	end
	btn.Active = true
	btn.Selectable = true
	btn.AutoButtonColor = canAfford
	if canAfford then
		btn.BackgroundTransparency = 0
	else
		btn.BackgroundTransparency = 0.45
	end
end

local function setCostLabel(row: Instance, upgradeId: string)
	local def = (SwingUpgrades :: any)[upgradeId]
	if not def then
		return
	end
	local buyButtons = row:FindFirstChild("BuyButtons")
	if not buyButtons then
		return
	end
	local _, cashBtn = resolveBuyButton(buyButtons)
	local holder = buyButtons:FindFirstChild("Buy")
	local costInst = holder and (holder:FindFirstChild("Cost") or holder:FindFirstChild("cost", true))
	local price = priceForUpgrade(upgradeId)
	if costInst and costInst:IsA("TextLabel") then
		costInst.Text = formatCash(price)
	end
	if cashBtn then
		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		styleAffordButton(cashBtn, c >= price)
	end
end

local function refreshUpgradeRow(row: Instance, upgradeId: string)
	local def = (SwingUpgrades :: any)[upgradeId]
	if not def then
		return
	end
	-- Before→after counters use front-end display totals (+25 → 1 + 25), not backend attribute steps.
	local cur = displayStatForAttr(def.attr)
	local nxt = cur + labelBonus(def)

	if upgradeId == "Carry1" then
		local curL = findLabelUnder(row, { "CurrentCarry" })
		local nextL = findLabelUnder(row, { "NextCarry" })
		if curL then
			curL.Text = ("%d Carry"):format(math.floor(cur))
		end
		if nextL then
			nextL.Text = ("%d Carry"):format(math.floor(nxt))
		end
	elseif string.find(upgradeId, "Power") then
		local curL = findLabelUnder(row, { "CurrentPower" })
		local nextL = findLabelUnder(row, { "NextPower" })
		if curL then
			curL.Text = ("%d Power"):format(math.floor(cur))
		end
		if nextL then
			nextL.Text = ("%d Power"):format(math.floor(nxt))
		end
	elseif string.find(upgradeId, "Reach") then
		local curL = findLabelUnder(row, { "CurrentReach" })
		local nextL = findLabelUnder(row, { "NextReach" })
		if curL then
			curL.Text = ("%d Reach"):format(math.floor(cur))
		end
		if nextL then
			nextL.Text = ("%d Reach"):format(math.floor(nxt))
		end
	end

	-- Studio layout: separate labels — Amount = "+10", Type = "Power" (backend still uses small `def.add`)
	local bonus = labelBonus(def)
	local amt = row:FindFirstChild("Amount")
	if amt and amt:IsA("TextLabel") then
		amt.Text = ("+%d"):format(bonus)
	end
	local typ = row:FindFirstChild("Type")
	if typ and typ:IsA("TextLabel") then
		if upgradeId == "Carry1" then
			typ.Text = "Carry"
		elseif string.find(upgradeId, "Power") then
			typ.Text = "Power"
		elseif string.find(upgradeId, "Reach") then
			typ.Text = "Reach"
		end
	end
	local iconFrame = row:FindFirstChild("IconFrame")
	if iconFrame then
		local iconAmt = iconFrame:FindFirstChild("Amount")
		if iconAmt and iconAmt:IsA("TextLabel") then
			iconAmt.Text = ("+%d"):format(bonus)
		end
	end

	local buy = row:FindFirstChild("BuyButtons", true)
	if buy then
		local _, cashBtn = resolveBuyButton(buy)
		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		local price = priceForUpgrade(upgradeId)
		styleAffordButton(cashBtn, c >= price)
	end
end

local lastShownCash = 0
local cashTween: Tween? = nil
local amountBaseColor: Color3? = nil

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

local function playSpendFeedback(amountLabel: TextLabel, spent: boolean)
	if spent then
		if not amountBaseColor then
			amountBaseColor = amountLabel.TextColor3
		end
		local base = amountBaseColor :: Color3
		local punch = getOrAddUIScale(amountLabel)
		TweenService:Create(punch, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.92 }):Play()
		task.delay(0.06, function()
			TweenService:Create(punch, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
		local hit = Color3.fromRGB(255, 82, 82)
		amountLabel.TextColor3 = hit
		TweenService:Create(amountLabel, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextColor3 = base }):Play()
	end
end

local function tweenCashLabel(amountLabel: TextLabel, target: number)
	local start = lastShownCash
	local spent = target < start - 0.5

	if cashTween then
		cashTween:Cancel()
		cashTween = nil
	end

	local ti = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local proxy = Instance.new("NumberValue")
	proxy.Value = start
	cashTween = TweenService:Create(proxy, ti, { Value = target })
	proxy:GetPropertyChangedSignal("Value"):Connect(function()
		amountLabel.Text = formatCash(proxy.Value)
	end)
	cashTween.Completed:Connect(function()
		lastShownCash = target
		amountLabel.Text = formatCash(target)
		proxy:Destroy()
		cashTween = nil
	end)
	cashTween:Play()
	playSpendFeedback(amountLabel, spent)
end

local ROW_IDS = { "Power10", "Power25", "Reach10", "Reach25", "Carry1" }

local function wirePurchase(upgradeId: string, buyButtons: Instance, refreshAllRows: () -> ())
	local def = (SwingUpgrades :: any)[upgradeId]
	if not def then
		return
	end

	local _, cashBtn = resolveBuyButton(buyButtons)
	if not cashBtn then
		warn("[UpgradesController] No usable GuiButton under BuyButtons.Buy for " .. upgradeId)
		return
	end

	local busy = false

	local function tryBuy()
		if busy then
			return
		end
		busy = true
		task.delay(0.05, function()
			busy = false
		end)

		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		local price = priceForUpgrade(upgradeId)
		if c < price then
			GameSoundEffects.playErrorNotif()
			prepareRobuxRE:FireServer(upgradeId)
			pcall(function()
				MarketplaceService:PromptProductPurchase(player, SwingUpgrades.SKIP_UPGRADE_DEV_PRODUCT_ID)
			end)
			return
		end

		local ok, err = purchaseFn:InvokeServer(upgradeId)
		if ok then
			refreshAllRows()
		elseif err then
			GameSoundEffects.playErrorNotif()
			warn("[UpgradesController] Purchase failed:", err)
		end
	end

	cashBtn.Activated:Connect(tryBuy)
	cashBtn.MouseButton1Click:Connect(tryBuy)

	local scale = getOrAddUIScale(cashBtn)
	cashBtn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
	cashBtn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.0 }):Play()
	end)
	cashBtn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
	end)
	cashBtn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
end

local function init()
	local main = waitMain()
	local upgrades = main:WaitForChild("Frames"):WaitForChild("Upgrades")
	local container = upgrades:WaitForChild("Container")

	-- One frame so AbsoluteSize / layout exist before we pick which GuiButton is the real buy control
	task.wait()

	local cashFrame = main:WaitForChild("SideUI"):WaitForChild("Counters"):WaitForChild("Cash")
	local amountLabel = cashFrame:WaitForChild("Amount") :: TextLabel
	amountBaseColor = amountLabel.TextColor3

	local cash0 = player:GetAttribute("Cash")
	lastShownCash = if typeof(cash0) == "number" then cash0 else 0
	amountLabel.Text = formatCash(lastShownCash)

	local function refreshAllRows()
		for _, id in ROW_IDS do
			local row = container:FindFirstChild(id)
			if row and row:FindFirstChild("BuyButtons") then
				refreshUpgradeRow(row, id)
			end
		end
	end

	for _, id in ROW_IDS do
		local row = container:FindFirstChild(id)
		if row and row:FindFirstChild("BuyButtons") then
			setCostLabel(row, id)
		end
	end

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		local v = player:GetAttribute("Cash")
		if typeof(v) == "number" then
			tweenCashLabel(amountLabel, v)
			refreshAllRows()
		end
	end)

	for _, attr in { "SwingForce", "SwingRange", "Carry" } do
		player:GetAttributeChangedSignal(attr):Connect(refreshAllRows)
	end

	for _, id in ROW_IDS do
		player:GetAttributeChangedSignal(SwingUpgrades.buysAttributeName(id)):Connect(refreshAllRows)
	end

	refreshAllRows()

	for _, id in ROW_IDS do
		local row = container:FindFirstChild(id)
		if row then
			local buyButtons = row:FindFirstChild("BuyButtons")
			if buyButtons then
				wirePurchase(id, buyButtons, refreshAllRows)
			end
		end
	end

	local header = upgrades:FindFirstChild("Header")
	if header then
		local btns = header:FindFirstChild("Buttons")
		local close = btns and btns:FindFirstChild("Close")
		if close and close:IsA("GuiButton") then
			local sc = getOrAddUIScale(close)
			close.MouseEnter:Connect(function()
				UIInteractionSounds.playHover()
				TweenService:Create(sc, HOVER_TWEEN, { Scale = 1.08 }):Play()
			end)
			close.MouseLeave:Connect(function()
				TweenService:Create(sc, HOVER_TWEEN, { Scale = 1 }):Play()
			end)
			close.MouseButton1Down:Connect(function()
				UIInteractionSounds.playClick()
				TweenService:Create(sc, CLICK_TWEEN, { Scale = 0.92 }):Play()
			end)
			close.MouseButton1Up:Connect(function()
				TweenService:Create(sc, HOVER_TWEEN, { Scale = 1.08 }):Play()
			end)
			close.MouseButton1Click:Connect(function()
				local HUDController = require(script.Parent.HUDController)
				HUDController.closeCurrentFrame()
			end)
		end
	end
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[UpgradesController] Main UI not ready or missing:", err)
	end
end

return { init = boot }
