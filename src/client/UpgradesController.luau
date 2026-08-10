-- [ACTIVE] UpgradesController
-- Wires Main.Frames.Upgrades gear rows + SideUI cash/power counters + edit-power bar.
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local MainGradientButtons = require(script.Parent.MainGradientButtons)
local TopNotifController = require(script.Parent.TopNotifController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local GearViewportIcon = require(script.Parent.GearViewportIcon)

local player = Players.LocalPlayer

-- Same private-use Robux glyph the dealer / store UI uses ().
local ROBUX_ICON = utf8.char(0xE002)

local purchaseFn: RemoteFunction? = nil
local equipFn: RemoteFunction? = nil
local setPowerFn: RemoteFunction? = nil
local prepareRobuxGearRE: RemoteEvent? = nil

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	if not remotes then
		warn("[UpgradesController] Remotes folder missing")
		return
	end
	purchaseFn = remotes:WaitForChild("PurchaseGear", 30) :: RemoteFunction?
	equipFn = remotes:WaitForChild("EquipGear", 30) :: RemoteFunction?
	setPowerFn = remotes:WaitForChild("SetEditedPower", 30) :: RemoteFunction?
	prepareRobuxGearRE = remotes:WaitForChild("PrepareRobuxGear", 30) :: RemoteEvent?
end)

local SUCCESS_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local BUY_HOST_NAME = "Buy/Equip/Equipped/Locked"
local COST_LABEL_NAME = "Cost/Equip/Equipped/Locked"

local lastShownCash = 0
local cashTween: Tween? = nil
local amountBaseColor: Color3? = nil
local cashAmountLabel: TextLabel? = nil
local bundleAnimConn: RBXScriptConnection? = nil
local bundleAnimUntil = 0
local pendingCashBundlePurchase = false

local powerAmountLabel: TextLabel? = nil
local lastShownPower = 0
local powerTween: Tween? = nil
local powerProxy: NumberValue? = nil
local powerBaseColor: Color3? = nil
local editBarGui: Frame? = nil
local editBarDragging = false

local function formatCash(n: number): string
	return BrainrotEconomy.formatCashShort(n)
end

local function formatPower(n: number): string
	return BrainrotEconomy.formatNumberShort(math.max(0, math.floor(n)))
end

local function waitMain(): ScreenGui
	return PlayerGuiMain.ensure(player)
end

local function ownedSet(): { [number]: boolean }
	return GearConfig.parseOwned(player:GetAttribute(GearConfig.OWNED_GEARS_ATTR))
end

local function equippedId(): number
	local v = player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR)
	return if typeof(v) == "number" then math.floor(v) else 0
end

local function findBuyHost(buyButtons: Instance): GuiObject?
	local host = buyButtons:FindFirstChild(BUY_HOST_NAME)
	if host and host:IsA("GuiObject") then
		return host
	end
	local legacy = buyButtons:FindFirstChild("Buy")
	if legacy and legacy:IsA("GuiObject") then
		return legacy
	end
	return nil
end

local function resolveClickButton(host: GuiObject): GuiButton?
	if host:IsA("GuiButton") then
		return host
	end
	local best: GuiButton? = nil
	local bestScore = -1
	for _, d in host:GetDescendants() do
		if not d:IsA("GuiButton") then
			continue
		end
		local underDecor = false
		local p: Instance? = d.Parent
		while p and p ~= host do
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
	return best or host:FindFirstChildWhichIsA("GuiButton", true)
end

local function findCostLabel(host: GuiObject): TextLabel?
	local cost = host:FindFirstChild(COST_LABEL_NAME) or host:FindFirstChild("Cost") or host:FindFirstChild("Price", true)
	if cost and (cost:IsA("TextLabel") or cost:IsA("TextButton")) then
		return cost :: TextLabel
	end
	return nil
end

local function setStateGradients(host: GuiObject, state: "buy" | "equip" | "equipped" | "locked")
	local buyGrad = host:FindFirstChild("Buy/Equip", true)
	local equippedGrad = host:FindFirstChild("Equipped/Locked", true)
	local showBuy = state == "buy" or state == "equip"
	local showOwned = state == "equipped" or state == "locked"
	local function setVis(node: Instance?, visible: boolean)
		if not node then
			return
		end
		if node:IsA("UIGradient") then
			(node :: UIGradient).Enabled = visible
		elseif node:IsA("GuiObject") then
			(node :: GuiObject).Visible = visible
		end
	end
	setVis(buyGrad, showBuy)
	setVis(equippedGrad, showOwned)
	local decor = host:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	if stud then
		setVis(stud:FindFirstChild("Buy/Equip"), showBuy)
		setVis(stud:FindFirstChild("Equipped/Locked"), showOwned)
	end
end

local function applyRarityGradients(row: Instance, rarity: string)
	local info = row:FindFirstChild("Info")
	local rarityLabel = info and info:FindFirstChild("Rarity")
	if rarityLabel then
		pcall(function()
			BrainrotHeaderStyle.applyRarityLabel(rarityLabel, rarity)
		end)
		local textNode = BrainrotHeaderStyle.resolveTextLabel(rarityLabel) or rarityLabel
		if textNode:IsA("TextLabel") or textNode:IsA("TextButton") then
			(textNode :: TextLabel).Text = GearConfig.rarityDisplay(rarity)
		end
	end
	local iconFrame = row:FindFirstChild("IconFrame")
	local iconRarity = iconFrame and iconFrame:FindFirstChild("Rarity")
	if iconRarity then
		pcall(function()
			BrainrotHeaderStyle.applyRarityLabel(iconRarity, rarity)
		end)
	end
end

local function ensureGearRows(container: Instance)
	local template: Instance? = nil
	for i = 1, 13 do
		local existing = container:FindFirstChild(tostring(i))
		if existing then
			template = existing
			break
		end
	end
	if not template then
		warn("[UpgradesController] No gear row template under Container")
		return
	end
	for i = 1, #GearConfig.GEARS do
		local name = tostring(i)
		local row = container:FindFirstChild(name)
		if not row then
			row = template:Clone()
			row.Name = name
			row.Parent = container
		end
		if row:IsA("GuiObject") then
			local gui = row :: GuiObject
			gui.LayoutOrder = i
			gui.Visible = true
		end
	end
	-- Hide leftover non-gear upgrade rows from old place files.
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			local asNum = tonumber(child.Name)
			if asNum and (asNum < 1 or asNum > #GearConfig.GEARS) then
				child.Visible = false
			elseif
				child.Name == "Power10"
				or child.Name == "Power25"
				or child.Name == "Reach10"
				or child.Name == "Reach25"
				or child.Name == "Carry1"
				or child.Name == "SPACE"
			then
				-- keep SPACE spacers; hide legacy upgrade ids
				if child.Name ~= "SPACE" then
					child.Visible = false
				end
			end
		end
	end
end

local function refreshGearRow(row: Instance, def: GearConfig.GearDef)
	local owned = ownedSet()
	local isOwned = owned[def.id] == true
	local isEquipped = equippedId() == def.id
	local cash = player:GetAttribute("Cash")
	local balance = if typeof(cash) == "number" then cash else 0

	local info = row:FindFirstChild("Info")
	local nameLabel = info and info:FindFirstChild("Name")
	if nameLabel and (nameLabel:IsA("TextLabel") or nameLabel:IsA("TextButton")) then
		(nameLabel :: TextLabel).Text = def.name
	end
	applyRarityGradients(row, def.rarity)

	local iconFrame = row:FindFirstChild("IconFrame")
	if iconFrame and iconFrame:IsA("GuiObject") then
		GearViewportIcon.mount(iconFrame, def.id, { rotate = true })
	end

	local powerFrame = row:FindFirstChild("Power")
	local powerText = powerFrame and (powerFrame:FindFirstChild("Power") or powerFrame:FindFirstChildWhichIsA("TextLabel"))
	if powerText and powerText:IsA("TextLabel") then
		powerText.Text = formatPower(def.powerGain)
	end

	local weightFrame = row:FindFirstChild("WeightFrame")
	local weightText = weightFrame and (weightFrame:FindFirstChild("Power") or weightFrame:FindFirstChildWhichIsA("TextLabel"))
	if weightText and weightText:IsA("TextLabel") then
		weightText.Text = formatPower(def.weightLbs) .. " lbs"
	end

	local locked = row:FindFirstChild("Locked")
	if locked and locked:IsA("GuiObject") then
		locked.Visible = false
	end

	local buyButtons = row:FindFirstChild("BuyButtons")
	if not buyButtons then
		return
	end

	local robux = buyButtons:FindFirstChild("BuyRobux")
	if robux and robux:IsA("GuiObject") then
		robux.Visible = (not isOwned) and def.robuxProductId ~= nil
		if def.robuxPrice then
			MainGradientButtons.applyDefault(robux)
			local priceLabel = robux:FindFirstChild("Price", true) or robux:FindFirstChildWhichIsA("TextLabel", true)
			if priceLabel and (priceLabel:IsA("TextLabel") or priceLabel:IsA("TextButton")) then
				(priceLabel :: TextLabel).Text = ROBUX_ICON .. tostring(def.robuxPrice)
			end
		end
	end

	local host = findBuyHost(buyButtons)
	if not host then
		return
	end

	local costLabel = findCostLabel(host)
	local state: "buy" | "equip" | "equipped" | "locked"
	if isEquipped then
		state = "equipped"
		if costLabel then
			costLabel.Text = "Equipped"
		end
		MainGradientButtons.applyPurchased(host, "Equipped")
	elseif isOwned then
		state = "equip"
		MainGradientButtons.applyDefault(host)
		if costLabel then
			costLabel.Text = "Equip"
		end
	else
		state = "buy"
		-- Keep green buy chrome even when cash is short (don't gray out prices).
		MainGradientButtons.applyDefault(host)
		if costLabel then
			costLabel.Text = formatCash(def.cashPrice)
		end
	end
	setStateGradients(host, state)
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

local function playRowPurchasePulse(row: Instance)
	local sc = getOrAddUIScale(row :: GuiObject)
	sc.Scale = 0.94
	TweenService:Create(sc, SUCCESS_TWEEN, { Scale = 1 }):Play()
end

local function wireGearRow(row: Instance, def: GearConfig.GearDef, refreshAll: () -> ())
	local buyButtons = row:FindFirstChild("BuyButtons")
	if not buyButtons then
		return
	end
	local host = findBuyHost(buyButtons)
	if not host then
		return
	end
	local btn = resolveClickButton(host)
	if not btn then
		warn("[UpgradesController] No click button for gear", def.id)
		return
	end

	local inFlight = false
	UIButtonEffects.wireScaleButtonAnim(btn, function()
		if inFlight then
			return
		end
		local owned = ownedSet()
		if owned[def.id] then
			if equippedId() == def.id then
				-- Already equipped — no buy/upgrade SFX.
				return
			end
			if not equipFn then
				return
			end
			inFlight = true
			local ok, err = equipFn:InvokeServer(def.id)
			inFlight = false
			if ok then
				-- Soft confirm only — never play purchase/upgrade buy SFX on equip.
				GameSoundEffects.playNotification1()
				refreshAll()
			else
				GameSoundEffects.playErrorNotif()
				if err then
					warn("[UpgradesController] Equip failed:", err)
				end
			end
			return
		end

		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		if c < def.cashPrice then
			TopNotifController.showCantAfford()
			if def.robuxProductId and prepareRobuxGearRE then
				prepareRobuxGearRE:FireServer(def.id)
				pcall(function()
					PurchasePrompt.promptProduct(def.robuxProductId :: number)
				end)
			end
			return
		end
		if not purchaseFn then
			warn("[UpgradesController] PurchaseGear remote not ready")
			GameSoundEffects.playErrorNotif()
			return
		end
		inFlight = true
		local ok, err = purchaseFn:InvokeServer(def.id)
		inFlight = false
		if ok then
			-- SFX + pulse immediately, then refresh rows (viewport remount can lag).
			GameSoundEffects.playPurchase()
			playRowPurchasePulse(row)
			refreshAll()
		else
			GameSoundEffects.playErrorNotif()
			if err then
				warn("[UpgradesController] Purchase failed:", err)
			end
		end
	end)

	local robuxHolder = buyButtons:FindFirstChild("BuyRobux")
	if robuxHolder and def.robuxProductId then
		local robuxBtn: GuiButton? = if robuxHolder:IsA("GuiButton")
			then robuxHolder
			else robuxHolder:FindFirstChildWhichIsA("GuiButton", true)
		if robuxBtn then
			UIButtonEffects.wireScaleButtonAnim(robuxBtn, function()
				if prepareRobuxGearRE then
					prepareRobuxGearRE:FireServer(def.id)
				end
				pcall(function()
					PurchasePrompt.promptProduct(def.robuxProductId :: number)
				end)
			end)
		end
	end
end

local function playSpendFeedback(amountLabel: TextLabel, spent: boolean)
	if spent then
		if not amountBaseColor then
			amountBaseColor = amountLabel.TextColor3
		end
		local base = amountBaseColor :: Color3
		local punch = getOrAddUIScale(amountLabel)
		TweenService
			:Create(punch, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.92 })
			:Play()
		task.delay(0.06, function()
			TweenService
				:Create(punch, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
				:Play()
		end)
		local hit = Color3.fromRGB(255, 82, 82)
		amountLabel.TextColor3 = hit
		TweenService:Create(
			amountLabel,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = base }
		):Play()
	end
end

local function tweenCashLabel(amountLabel: TextLabel, target: number)
	local start = lastShownCash
	local spent = target < start - 0.5
	if bundleAnimConn then
		bundleAnimConn:Disconnect()
		bundleAnimConn = nil
	end
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

local function tweenCashBundleGrant(amountLabel: TextLabel, target: number, duration: number)
	if bundleAnimConn then
		bundleAnimConn:Disconnect()
		bundleAnimConn = nil
	end
	if cashTween then
		cashTween:Cancel()
		cashTween = nil
	end
	local start = lastShownCash
	local startTime = os.clock()
	bundleAnimUntil = startTime + duration + 0.25
	bundleAnimConn = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - startTime
		local t = math.clamp(elapsed / duration, 0, 1)
		local eased = 1 - (1 - t) * (1 - t)
		local value = start + (target - start) * eased
		amountLabel.Text = formatCash(math.floor(value + 0.5))
		if t >= 1 then
			if bundleAnimConn then
				bundleAnimConn:Disconnect()
				bundleAnimConn = nil
			end
			lastShownCash = target
			amountLabel.Text = formatCash(target)
		end
	end)
end

local function isCashBundleProduct(productId: number): boolean
	return StoreConfig.CASH_BUNDLE_MULTIPLIERS[productId] ~= nil
end

local POWER_FLASH_GOLD = Color3.fromRGB(255, 214, 90)
local POWER_FLASH_WHITE = Color3.fromRGB(255, 252, 235)

local function resolveMuscleIcon(powerFrame: Instance): ImageLabel?
	local cluster = powerFrame:FindFirstChild("PowerPulseCluster")
	if cluster then
		local nested = cluster:FindFirstChild("ImageLabel") or cluster:FindFirstChild("Icon")
		if nested and nested:IsA("ImageLabel") then
			return nested
		end
		local any = cluster:FindFirstChildWhichIsA("ImageLabel")
		if any then
			return any
		end
	end
	local direct = powerFrame:FindFirstChild("ImageLabel")
	if direct and direct:IsA("ImageLabel") then
		return direct
	end
	local named = powerFrame:FindFirstChild("Icon")
	if named and named:IsA("ImageLabel") then
		return named
	end
	for _, child in powerFrame:GetChildren() do
		if child:IsA("ImageLabel") then
			return child
		end
	end
	return nil
end

-- Lock Amount TextSize BEFORE reparenting into AutomaticSize cluster.
-- TextScaled labels collapse to tiny text when their parent shrinks.
local function lockPowerAmountTextSize(amount: TextLabel)
	if amount:GetAttribute("PowerAmtSizeLocked") == true then
		return
	end
	amount:SetAttribute("PowerAmtSizeLocked", true)

	local ts: number? = nil
	local counters = amount:FindFirstAncestor("Counters")
	local cash = counters and counters:FindFirstChild("Cash")
	local cashAmt = cash and cash:FindFirstChild("Amount", true)
	if cashAmt and cashAmt:IsA("TextLabel") then
		if not cashAmt.TextScaled and cashAmt.TextSize >= 14 then
			ts = cashAmt.TextSize
		elseif cashAmt.AbsoluteSize.Y > 8 then
			ts = math.floor(cashAmt.AbsoluteSize.Y * 0.72)
		end
	end
	if not ts then
		if amount.TextScaled and amount.AbsoluteSize.Y > 8 then
			ts = math.floor(amount.AbsoluteSize.Y * 0.72)
		elseif amount.TextSize >= 14 then
			ts = amount.TextSize
		else
			ts = 28
		end
	end
	amount.TextScaled = false
	amount.TextSize = math.clamp(ts :: number, 18, 48)
	amount.AutomaticSize = Enum.AutomaticSize.XY
	amount.Size = UDim2.fromOffset(0, 0)
end

-- Scale Amount + muscle only (not Edit / whole SideUI chip) so hits land in the right place.
local function ensurePulseCluster(powerFrame: GuiObject): Frame
	local existing = powerFrame:FindFirstChild("PowerPulseCluster")
	local amount = powerFrame:FindFirstChild("Amount")
		or (existing and existing:FindFirstChild("Amount"))
	local muscle = resolveMuscleIcon(powerFrame)
	if existing and existing:IsA("Frame") then
		if amount and amount:IsA("GuiObject") and amount.Parent ~= existing then
			amount.Parent = existing
		end
		if muscle and muscle.Parent ~= existing then
			muscle.Parent = existing
		end
	else
		existing = Instance.new("Frame")
		existing.Name = "PowerPulseCluster"
		existing.BackgroundTransparency = 1
		existing.BorderSizePixel = 0
		existing.AutomaticSize = Enum.AutomaticSize.XY
		existing.Size = UDim2.fromOffset(0, 0)
		existing.AnchorPoint = Vector2.new(0.5, 0.5)
		local order = 0
		if muscle then
			order = muscle.LayoutOrder
		elseif amount and amount:IsA("GuiObject") then
			order = amount.LayoutOrder
		end
		existing.LayoutOrder = order
		existing.ZIndex = powerFrame.ZIndex

		local layout = Instance.new("UIListLayout")
		layout.Name = "PulseLayout"
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 8)
		layout.Parent = existing

		existing.Parent = powerFrame
	end

	local cluster = existing :: Frame
	local layout = cluster:FindFirstChild("PulseLayout")
	if layout and layout:IsA("UIListLayout") then
		layout.Padding = UDim.new(0, 8)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	end

	-- Icon LEFT, number RIGHT — restore original counter text size.
	if amount and amount:IsA("TextLabel") and amount.Parent ~= cluster then
		lockPowerAmountTextSize(amount)
	elseif amount and amount:IsA("TextLabel") then
		lockPowerAmountTextSize(amount)
	end
	if muscle then
		muscle.LayoutOrder = 1
		if muscle.AbsoluteSize.X < 8 or muscle.AbsoluteSize.Y < 8 then
			muscle.Size = UDim2.fromOffset(42, 42)
		end
		muscle.ScaleType = Enum.ScaleType.Fit
		muscle.BackgroundTransparency = 1
		muscle.Image = GearConfig.WORKOUT_IMAGE
		muscle.ImageTransparency = 0
		muscle.Visible = true
		muscle.ZIndex = math.max(muscle.ZIndex, (amount and amount:IsA("GuiObject") and amount.ZIndex or 1) + 1)
		muscle.Parent = cluster
	end
	if amount and amount:IsA("TextLabel") then
		amount.LayoutOrder = 2
		amount.TextXAlignment = Enum.TextXAlignment.Left
		amount.TextYAlignment = Enum.TextYAlignment.Center
		amount.TextTransparency = 0
		amount.ClipsDescendants = false
		local sc = amount:FindFirstChildOfClass("UIScale")
		if sc and sc.Name ~= "PowerChipScale" then
			sc.Scale = 1
		end
		amount.Parent = cluster
	elseif amount and amount:IsA("GuiObject") then
		amount.LayoutOrder = 2
		amount.Parent = cluster
	end

	return cluster
end

local function playPowerGainFlash(amountLabel: TextLabel)
	if not powerBaseColor then
		powerBaseColor = amountLabel.TextColor3
	end
	local base = powerBaseColor :: Color3
	amountLabel.TextTransparency = 0
	local leftover = amountLabel:FindFirstChild("PowerHitScale")
	if leftover then
		leftover:Destroy()
	end

	local cluster = amountLabel.Parent
	if not (cluster and cluster:IsA("GuiObject") and cluster.Name == "PowerPulseCluster") then
		local powerFrame = amountLabel:FindFirstAncestor("Power")
		if powerFrame and powerFrame:IsA("GuiObject") then
			cluster = ensurePulseCluster(powerFrame)
		end
	end

	local recentlyPulsed = cluster
		and cluster:IsA("GuiObject")
		and (os.clock() - ((cluster:GetAttribute("PowerPulseAt") :: number?) or 0)) < 0.22

	amountLabel.TextColor3 = POWER_FLASH_WHITE
	TweenService:Create(
		amountLabel,
		TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextColor3 = POWER_FLASH_GOLD }
	):Play()
	task.delay(0.12, function()
		if amountLabel.Parent then
			TweenService:Create(
				amountLabel,
				TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextColor3 = base }
			):Play()
		end
	end)

	if recentlyPulsed or not cluster or not cluster:IsA("GuiObject") then
		return
	end

	local sc = cluster:FindFirstChild("PowerChipScale")
	if not sc or not sc:IsA("UIScale") then
		sc = Instance.new("UIScale")
		sc.Name = "PowerChipScale"
		sc.Scale = 1
		sc.Parent = cluster
	end
	local token = ((cluster:GetAttribute("PowerPulseToken") :: number?) or 0) + 1
	cluster:SetAttribute("PowerPulseToken", token)
	cluster:SetAttribute("PowerPulseAt", os.clock())
	sc.Scale = 0.88
	TweenService
		:Create(sc, TweenInfo.new(0.07, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.28 })
		:Play()
	task.delay(0.07, function()
		if sc.Parent and cluster:GetAttribute("PowerPulseToken") == token then
			TweenService
				:Create(sc, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
				:Play()
		end
	end)
end

local function updatePowerLabel()
	if not powerAmountLabel then
		return
	end
	local power = WorkoutPower.readPower(player)
	local edited = WorkoutPower.isEdited(player)
	local target = power

	local function applyText(n: number)
		local text = formatPower(n)
		if edited then
			text ..= " (Edited)"
		end
		powerAmountLabel.Text = text
	end

	if powerTween then
		powerTween:Cancel()
		powerTween = nil
	end
	if powerProxy then
		powerProxy:Destroy()
		powerProxy = nil
	end

	local gained = target > lastShownPower + 0.5
	local dropped = target < lastShownPower - 0.5
	if not gained and not dropped then
		lastShownPower = target
		applyText(target)
		return
	end

	if gained then
		playPowerGainFlash(powerAmountLabel)
	end

	local start = lastShownPower
	local proxy = Instance.new("NumberValue")
	proxy.Value = start
	powerProxy = proxy
	-- Snappy count-up — long tweens feel laggy next to the floater hit.
	local ti = TweenInfo.new(if gained then 0.06 else 0.08, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	powerTween = TweenService:Create(proxy, ti, { Value = target })
	proxy:GetPropertyChangedSignal("Value"):Connect(function()
		applyText(proxy.Value)
	end)
	powerTween.Completed:Connect(function()
		lastShownPower = target
		applyText(target)
		if powerProxy == proxy then
			powerProxy = nil
		end
		proxy:Destroy()
		powerTween = nil
	end)
	powerTween:Play()
end

local function ensurePowerCounter(counters: Instance): TextLabel?
	local powerFrame = counters:FindFirstChild("Power")
	local cash = counters:FindFirstChild("Cash")
	if not powerFrame then
		if cash and cash:IsA("GuiObject") then
			powerFrame = cash:Clone()
			powerFrame.Name = "Power"
			local cashGui = cash :: GuiObject
			local pf = powerFrame :: GuiObject
			pf.Size = cashGui.Size
			pf.AutomaticSize = Enum.AutomaticSize.None
			powerFrame.Parent = counters
			local layout = counters:FindFirstChildOfClass("UIListLayout")
			if layout then
				pf.LayoutOrder = cashGui.LayoutOrder + 1
			end
			local muscle = resolveMuscleIcon(powerFrame)
			if muscle then
				muscle.Image = GearConfig.WORKOUT_IMAGE
			end
		end
	end
	if not powerFrame or not powerFrame:IsA("GuiObject") then
		return nil
	end

	-- Studio Power already has Edit + ImageLabel — never crush it to Cash size.
	local muscle = resolveMuscleIcon(powerFrame)
	if muscle then
		muscle.Image = GearConfig.WORKOUT_IMAGE
		muscle.ImageTransparency = 0
		muscle.Visible = true
	end

	ensurePulseCluster(powerFrame)

	local amount = powerFrame:FindFirstChild("Amount", true)
	if amount and amount:IsA("TextLabel") then
		amount.TextTransparency = 0
		local hitScale = amount:FindFirstChild("PowerHitScale")
		if hitScale then
			hitScale:Destroy()
		end
		local frameScale = powerFrame:FindFirstChild("PowerChipScale") or powerFrame:FindFirstChild("PowerHitScale")
		if frameScale and frameScale:IsA("UIScale") then
			frameScale.Scale = 1
		end
		return amount
	end
	return powerFrame:FindFirstChildWhichIsA("TextLabel", true)
end

local function ensureEditButton(powerFrame: Instance): GuiButton?
	local existing = powerFrame:FindFirstChild("Edit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	local btn = Instance.new("TextButton")
	btn.Name = "Edit"
	btn.Size = UDim2.fromOffset(44, 22)
	btn.Position = UDim2.new(1, -4, 0.5, 0)
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
	btn.BorderSizePixel = 0
	btn.Text = "Edit"
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.Font = Enum.Font.GothamBold
	btn.ZIndex = 5
	btn.Parent = powerFrame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = btn
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	pcall(function()
		UiFonts.applyButtonLabel(btn)
	end)
	return btn
end

local function closeEditBar()
	editBarDragging = false
	if editBarGui then
		editBarGui.Visible = false
	end
	local ok, main = pcall(function()
		return PlayerGuiMain.ensure(player)
	end)
	if ok and main then
		local dim = main:FindFirstChild("PowerEditDim")
		if dim and dim:IsA("GuiObject") then
			dim.Visible = false
		end
	end
end

local function openEditBar(main: ScreenGui)
	local dim = main:FindFirstChild("PowerEditDim")
	if not dim then
		dim = Instance.new("TextButton")
		dim.Name = "PowerEditDim"
		dim.Size = UDim2.fromScale(1, 1)
		dim.BackgroundColor3 = Color3.new(0, 0, 0)
		dim.BackgroundTransparency = 0.45
		dim.BorderSizePixel = 0
		dim.Text = ""
		dim.AutoButtonColor = false
		dim.ZIndex = 48
		dim.Visible = false
		dim.Parent = main
		;(dim :: TextButton).MouseButton1Click:Connect(function()
			-- Dragging the slider often releases over the dim — don't close mid-edit.
			if editBarDragging then
				return
			end
			closeEditBar()
		end)
	end
	;(dim :: GuiObject).Visible = true

	if not editBarGui then
		local frame = Instance.new("Frame")
		frame.Name = "PowerEditBar"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.52)
		frame.Size = UDim2.fromOffset(380, 168)
		frame.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
		frame.BackgroundTransparency = 0.12
		frame.BorderSizePixel = 0
		frame.ZIndex = 50
		frame.Parent = main
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 14)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.72
		stroke.Parent = frame
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 12)
		pad.PaddingBottom = UDim.new(0, 12)
		pad.PaddingLeft = UDim.new(0, 14)
		pad.PaddingRight = UDim.new(0, 14)
		pad.Parent = frame

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0, 26)
		title.Text = "Edit Power"
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextScaled = false
		title.ZIndex = 51
		title.Parent = frame
		UiFonts.applyBodyLabel(title, 20, 14)
		local titleStroke = Instance.new("UIStroke")
		titleStroke.Thickness = 2
		titleStroke.Parent = title

		local hint = Instance.new("TextLabel")
		hint.Name = "Hint"
		hint.BackgroundTransparency = 1
		hint.Size = UDim2.new(1, 0, 0, 16)
		hint.Position = UDim2.fromOffset(0, 28)
		hint.Text = "Slide to set active Power — max grows when you work out"
		hint.TextColor3 = Color3.fromRGB(200, 205, 220)
		hint.TextTransparency = 0.15
		hint.ZIndex = 51
		hint.Parent = frame
		UiFonts.applyBodyLabel(hint, 12, 9)

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Name = "Value"
		valueLabel.BackgroundTransparency = 1
		valueLabel.Size = UDim2.new(1, 0, 0, 28)
		valueLabel.Position = UDim2.fromOffset(0, 48)
		valueLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
		valueLabel.ZIndex = 51
		valueLabel.Parent = frame
		UiFonts.applyBodyLabel(valueLabel, 24, 16)
		local valueStroke = Instance.new("UIStroke")
		valueStroke.Thickness = 2
		valueStroke.Parent = valueLabel

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Size = UDim2.new(1, -8, 0, 16)
		track.Position = UDim2.new(0, 4, 0, 88)
		track.BackgroundColor3 = Color3.fromRGB(40, 44, 58)
		track.BackgroundTransparency = 0.2
		track.BorderSizePixel = 0
		track.ZIndex = 51
		track.Parent = frame
		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(1, 0)
		trackCorner.Parent = track
		local trackStroke = Instance.new("UIStroke")
		trackStroke.Thickness = 1.5
		trackStroke.Transparency = 0.55
		trackStroke.Parent = track

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = Color3.fromRGB(85, 220, 130)
		fill.BackgroundTransparency = 0.08
		fill.BorderSizePixel = 0
		fill.ZIndex = 52
		fill.Parent = track
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(1, 0)
		fillCorner.Parent = fill
		local fillGrad = Instance.new("UIGradient")
		fillGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(70, 190, 110)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 255, 180)),
		})
		fillGrad.Parent = fill

		local knob = Instance.new("Frame")
		knob.Name = "Knob"
		knob.Size = UDim2.fromOffset(24, 24)
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Position = UDim2.fromScale(1, 0.5)
		knob.BackgroundColor3 = Color3.new(1, 1, 1)
		knob.BackgroundTransparency = 0.05
		knob.BorderSizePixel = 0
		knob.ZIndex = 53
		knob.Parent = track
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob
		local knobStroke = Instance.new("UIStroke")
		knobStroke.Thickness = 2
		knobStroke.Color = Color3.fromRGB(30, 30, 36)
		knobStroke.Parent = knob

		local okBtn = Instance.new("TextButton")
		okBtn.Name = "Ok"
		okBtn.Size = UDim2.fromOffset(110, 30)
		okBtn.Position = UDim2.new(0.5, -118, 1, -34)
		okBtn.BackgroundColor3 = Color3.fromRGB(70, 190, 100)
		okBtn.BackgroundTransparency = 0.08
		okBtn.Text = "Okay"
		okBtn.TextColor3 = Color3.new(1, 1, 1)
		okBtn.ZIndex = 51
		okBtn.Parent = frame
		UiFonts.applyButtonLabel(okBtn, 16, 12)
		local okStroke = Instance.new("UIStroke")
		okStroke.Thickness = 2
		okStroke.Parent = okBtn
		local okCorner = Instance.new("UICorner")
		okCorner.CornerRadius = UDim.new(0, 8)
		okCorner.Parent = okBtn

		local cancelBtn = Instance.new("TextButton")
		cancelBtn.Name = "Cancel"
		cancelBtn.Size = UDim2.fromOffset(110, 30)
		cancelBtn.Position = UDim2.new(0.5, 8, 1, -34)
		cancelBtn.BackgroundColor3 = Color3.fromRGB(160, 70, 80)
		cancelBtn.BackgroundTransparency = 0.12
		cancelBtn.Text = "Cancel"
		cancelBtn.TextColor3 = Color3.new(1, 1, 1)
		cancelBtn.ZIndex = 51
		cancelBtn.Parent = frame
		UiFonts.applyButtonLabel(cancelBtn, 16, 12)
		local cancelStroke = Instance.new("UIStroke")
		cancelStroke.Thickness = 2
		cancelStroke.Parent = cancelBtn
		local cancelCorner = Instance.new("UICorner")
		cancelCorner.CornerRadius = UDim.new(0, 8)
		cancelCorner.Parent = cancelBtn

		local dragging = false
		local movedConn: RBXScriptConnection? = nil
		local endedConn: RBXScriptConnection? = nil
		local function stopDrag()
			dragging = false
			editBarDragging = false
			if movedConn then
				movedConn:Disconnect()
				movedConn = nil
			end
			if endedConn then
				endedConn:Disconnect()
				endedConn = nil
			end
		end

		frame:SetAttribute("MaxPower", 0)

		local function currentMax(): number
			local m = frame:GetAttribute("MaxPower")
			return if typeof(m) == "number" then math.max(0, m) else 0
		end

		local function applyAlpha(a: number)
			a = math.clamp(a, 0, 1)
			frame:SetAttribute("Alpha", a)
			fill.Size = UDim2.fromScale(a, 1)
			knob.Position = UDim2.new(a, 0, 0.5, 0)
			valueLabel.Text = formatPower(math.floor(a * currentMax() + 0.5))
		end

		local function alphaFromInput(x: number): number
			local absPos = track.AbsolutePosition.X
			local absSize = track.AbsoluteSize.X
			if absSize <= 0 then
				local cur = frame:GetAttribute("Alpha")
				return if typeof(cur) == "number" then cur else 1
			end
			return math.clamp((x - absPos) / absSize, 0, 1)
		end

		local function beginDrag(inputX: number)
			dragging = true
			editBarDragging = true
			applyAlpha(alphaFromInput(inputX))
			if movedConn then
				movedConn:Disconnect()
			end
			if endedConn then
				endedConn:Disconnect()
			end
			movedConn = UserInputService.InputChanged:Connect(function(chg)
				if not dragging then
					return
				end
				if
					chg.UserInputType == Enum.UserInputType.MouseMovement
					or chg.UserInputType == Enum.UserInputType.Touch
				then
					applyAlpha(alphaFromInput(chg.Position.X))
				end
			end)
			endedConn = UserInputService.InputEnded:Connect(function(ended)
				if
					ended.UserInputType == Enum.UserInputType.MouseButton1
					or ended.UserInputType == Enum.UserInputType.Touch
				then
					-- Defer clear so dim's click (same release) sees editBarDragging=true.
					task.defer(stopDrag)
				end
			end)
		end

		knob.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				beginDrag(input.Position.X)
			end
		end)

		track.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				beginDrag(input.Position.X)
			end
		end)

		UIButtonEffects.wireScaleButtonAnim(okBtn, function()
			local a = frame:GetAttribute("Alpha")
			local alphaVal = if typeof(a) == "number" then a else 1
			local maxP = currentMax()
			local amount = math.floor(alphaVal * maxP + 0.5)
			amount = math.clamp(amount, 0, math.floor(maxP))
			-- Full slider = restore true max (clear Edited). Lower = keep nerf.
			local markEdited = amount < maxP
			if setPowerFn then
				local ok = setPowerFn:InvokeServer(amount, markEdited)
				if ok then
					GameSoundEffects.playUpgrade()
					updatePowerLabel()
				else
					GameSoundEffects.playErrorNotif()
				end
			end
			closeEditBar()
		end)
		UIButtonEffects.wireScaleButtonAnim(cancelBtn, function()
			closeEditBar()
		end)

		editBarGui = frame
	end

	local frame = editBarGui :: Frame
	frame.Visible = true
	local valueLabel = frame:FindFirstChild("Value") :: TextLabel
	local track = frame:FindFirstChild("Track") :: Frame
	local fill = track:FindFirstChild("Fill") :: Frame
	local knob = track:FindFirstChild("Knob") :: Frame

	-- Cap = true PowerMax (workouts raise this). Active Power can go up or down within it.
	local maxPower = math.max(0, math.floor(WorkoutPower.readPowerMax(player)))
	local activePower = math.max(0, math.floor(WorkoutPower.readPower(player)))
	local alpha = if maxPower > 0 then math.clamp(activePower / maxPower, 0, 1) else 1
	frame:SetAttribute("MaxPower", maxPower)
	frame:SetAttribute("Alpha", alpha)
	fill.Size = UDim2.fromScale(alpha, 1)
	knob.Position = UDim2.new(alpha, 0, 0.5, 0)
	valueLabel.Text = formatPower(math.floor(alpha * maxPower + 0.5))

	local hint = frame:FindFirstChild("Hint")
	if hint and hint:IsA("TextLabel") then
		hint.Text = "Max "
			.. formatPower(maxPower)
			.. " — slide up to restore, or down to nerf"
	end

	local sc = frame:FindFirstChildOfClass("UIScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Parent = frame
	end
	sc.Scale = 0.92
	TweenService:Create(sc, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local function init()
	local main = waitMain()
	MainGradientButtons.init(main)
	local upgrades = main:WaitForChild("Frames"):WaitForChild("Upgrades")
	local container = upgrades:WaitForChild("Container")
	task.wait()
	ensureGearRows(container)

	local counters = main:WaitForChild("SideUI"):WaitForChild("Counters")
	local cashFrame = counters:WaitForChild("Cash")
	local amountLabel = cashFrame:WaitForChild("Amount") :: TextLabel
	cashAmountLabel = amountLabel
	amountBaseColor = amountLabel.TextColor3

	local cash0 = player:GetAttribute("Cash")
	lastShownCash = if typeof(cash0) == "number" then cash0 else 0
	amountLabel.Text = formatCash(lastShownCash)

	powerAmountLabel = ensurePowerCounter(counters)
	updatePowerLabel()
	local powerFrame = counters:FindFirstChild("Power")
	if powerFrame then
		local editBtn = ensureEditButton(powerFrame)
		if editBtn then
			UIButtonEffects.wireScaleButtonAnim(editBtn, function()
				openEditBar(main)
			end)
		end
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, wasPurchased: boolean)
			if userId ~= player.UserId then
				return
			end
			if wasPurchased and GearConfig.getByProductId(productId) then
				task.delay(0.35, function()
					-- rows refresh via OwnedGears attr
				end)
			end
			if not isCashBundleProduct(productId) then
				return
			end
			pendingCashBundlePurchase = false
			if not wasPurchased or not cashAmountLabel then
				return
			end
			local label = cashAmountLabel
			local startCash = lastShownCash
			task.spawn(function()
				for _ = 1, 25 do
					local newTotal = player:GetAttribute("Cash")
					if typeof(newTotal) == "number" and newTotal > startCash + 0.5 then
						GameSoundEffects.playCashGrab()
						tweenCashBundleGrant(label, newTotal, 1.5)
						return
					end
					task.wait(0.1)
				end
			end)
		end
	)

	local function refreshAllRows()
		for _, def in GearConfig.GEARS do
			local row = container:FindFirstChild(tostring(def.id))
			if row then
				refreshGearRow(row, def)
			end
		end
	end

	local rowRefreshScheduled = false
	local function queueRefreshAllRows()
		if rowRefreshScheduled then
			return
		end
		rowRefreshScheduled = true
		task.delay(0.1, function()
			rowRefreshScheduled = false
			refreshAllRows()
		end)
	end

	for _, def in GearConfig.GEARS do
		local row = container:FindFirstChild(tostring(def.id))
		if row then
			wireGearRow(row, def, refreshAllRows)
		end
	end

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		local v = player:GetAttribute("Cash")
		if typeof(v) == "number" then
			if pendingCashBundlePurchase or os.clock() < bundleAnimUntil then
				return
			end
			tweenCashLabel(amountLabel, v)
			if upgrades.Visible then
				queueRefreshAllRows()
			end
		end
	end)

	for _, attr in {
		GearConfig.OWNED_GEARS_ATTR,
		GearConfig.EQUIPPED_GEAR_ATTR,
		GearConfig.POWER_ATTR,
		GearConfig.POWER_EDITED_ATTR,
	} do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if attr == GearConfig.POWER_ATTR or attr == GearConfig.POWER_EDITED_ATTR then
				updatePowerLabel()
			end
			if upgrades.Visible then
				queueRefreshAllRows()
			end
		end)
	end

	upgrades:GetPropertyChangedSignal("Visible"):Connect(function()
		if upgrades.Visible then
			refreshAllRows()
		end
	end)

	refreshAllRows()

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

return {
	init = boot,
	markCashBundlePurchasePending = function()
		pendingCashBundlePurchase = true
	end,
}
