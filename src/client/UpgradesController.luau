-- Wires Main.Frames.Upgrades rows + SideUI cash counter; purchase via server RemoteFunction
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIButtonEffects = require(script.Parent.UIButtonEffects)

local SwingUpgrades = require(ReplicatedStorage.Shared.SwingUpgrades)
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local player = Players.LocalPlayer

local purchaseFn = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PurchaseSwingUpgrade") :: RemoteFunction
local prepareRobuxRE = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PrepareRobuxUpgrade") :: RemoteEvent

local SUCCESS_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

local LEVEL_ATTRS = {
	SwingUpgrades.POWER_LEVEL_ATTR,
	SwingUpgrades.ROPE_LEVEL_ATTR,
	SwingUpgrades.CARRY_LEVEL_ATTR,
}

local function readLevels(): SwingUpgrades.UpgradeLevels
	return SwingUpgrades.readLevels(function(name: string)
		return player:GetAttribute(name)
	end)
end

local function priceForUpgrade(upgradeId: string): number
	return SwingUpgrades.priceForUpgradeId(upgradeId, readLevels())
end

local function formatCash(n: number): string
	return BrainrotEconomy.formatCashShort(n)
end

local function waitMain(): ScreenGui
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
		if not holder:IsA("GuiButton") then
			holder.Active = false
		end
		local p: Instance? = best.Parent
		while p and p ~= holder do
			if p:IsA("GuiObject") then
				p.Active = false
			end
			p = p.Parent
		end
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
	local levels = readLevels()
	local maxed = SwingUpgrades.isUpgradeMaxed(upgradeId, levels)
	local price = priceForUpgrade(upgradeId)
	if costInst and costInst:IsA("TextLabel") then
		costInst.Text = if maxed then "MAX" else formatCash(price)
	end
	if cashBtn then
		if maxed then
			styleAffordButton(cashBtn, false)
		else
			local cash = player:GetAttribute("Cash")
			local c = if typeof(cash) == "number" then cash else 0
			styleAffordButton(cashBtn, c >= price)
		end
	end
end

local function refreshUpgradeRow(row: Instance, upgradeId: string)
	local def = (SwingUpgrades :: any)[upgradeId]
	if not def then
		return
	end

	local levels = readLevels()
	local currentLevel = SwingUpgrades.levelForUpgradeId(upgradeId, levels)
	local cur = SwingUpgrades.displayStatForLevel(currentLevel, def.levelAttr)
	local nxt = SwingUpgrades.displayStatAfterPurchase(currentLevel, def.units, def.levelAttr)

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

	local bonus = SwingUpgrades.displayBonus(def)
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
		local maxed = SwingUpgrades.isUpgradeMaxed(upgradeId, levels)
		if maxed then
			styleAffordButton(cashBtn, false)
		else
			local cash = player:GetAttribute("Cash")
			local c = if typeof(cash) == "number" then cash else 0
			local price = priceForUpgrade(upgradeId)
			styleAffordButton(cashBtn, c >= price)
		end
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

local function playRowPurchasePulse(row: Instance)
	local changes = row:FindFirstChild("Changes")
	local pulseTarget = changes or row
	local sc = getOrAddUIScale(pulseTarget :: GuiObject)
	sc.Scale = 0.94
	TweenService:Create(sc, SUCCESS_TWEEN, { Scale = 1 }):Play()
	local arrow = changes and changes:FindFirstChild("Arrow")
	if arrow and arrow:IsA("GuiObject") then
		local asc = getOrAddUIScale(arrow)
		asc.Scale = 1.2
		TweenService:Create(asc, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
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

local function wirePurchase(upgradeId: string, row: Instance, buyButtons: Instance, refreshAllRows: () -> ())
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
		task.delay(0.35, function()
			busy = false
		end)

		if SwingUpgrades.isUpgradeMaxed(upgradeId, readLevels()) then
			GameSoundEffects.playErrorNotif()
			return
		end

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
			setCostLabel(row, upgradeId)
			refreshAllRows()
			playRowPurchasePulse(row)
		elseif err then
			GameSoundEffects.playErrorNotif()
			warn("[UpgradesController] Purchase failed:", err)
		end
	end

	UIButtonEffects.wireScaleButtonAnim(cashBtn, tryBuy)

	local robuxHolder = buyButtons:FindFirstChild("BuyRobux")
	if robuxHolder then
		local robuxBtn: GuiButton? = nil
		if robuxHolder:IsA("GuiButton") then
			robuxBtn = robuxHolder
		else
			robuxBtn = robuxHolder:FindFirstChildWhichIsA("GuiButton", true)
		end
		if robuxBtn then
			UIButtonEffects.wireAccentButton(robuxBtn, function()
				prepareRobuxRE:FireServer(upgradeId)
				pcall(function()
					MarketplaceService:PromptProductPurchase(player, SwingUpgrades.SKIP_UPGRADE_DEV_PRODUCT_ID)
				end)
			end)
		end
	end
end

local function init()
	local main = waitMain()
	local upgrades = main:WaitForChild("Frames"):WaitForChild("Upgrades")
	local container = upgrades:WaitForChild("Container")

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
				setCostLabel(row, id)
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

	for _, levelAttr in LEVEL_ATTRS do
		player:GetAttributeChangedSignal(levelAttr):Connect(refreshAllRows)
	end

	refreshAllRows()

	for _, id in ROW_IDS do
		local row = container:FindFirstChild(id)
		if row then
			local buyButtons = row:FindFirstChild("BuyButtons")
			if buyButtons then
				wirePurchase(id, row, buyButtons, refreshAllRows)
			end
		end
	end

	local header = upgrades:FindFirstChild("Header")
	if header then
		local btns = header:FindFirstChild("Buttons")
		local close = btns and btns:FindFirstChild("Close")
		if close and close:IsA("GuiButton") then
			UIButtonEffects.wireGlistenCloseButton(close, function()
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
