-- [ACTIVE] UpgradesController
-- Wires Main.Frames.Upgrades gear rows + SideUI cash/power counters + edit-power bar.
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local MainGradientButtons = require(script.Parent.MainGradientButtons)
local TopNotifController = require(script.Parent.TopNotifController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

-- Power Amount keeps the Studio template TextSize / TextScaled / constraint.

-- Same private-use Robux glyph the dealer / store UI uses ().
local ROBUX_ICON = utf8.char(0xE002)

local purchaseFn: RemoteFunction? = nil
local equipFn: RemoteFunction? = nil
local setPowerFn: RemoteFunction? = nil
local prepareRobuxGearRE: RemoteEvent? = nil

local function cacheGearRemote(child: Instance?, asEvent: boolean?): boolean
	if not child then
		return false
	end
	if asEvent then
		if child:IsA("RemoteEvent") then
			prepareRobuxGearRE = child
			return true
		end
		return false
	end
	if not child:IsA("RemoteFunction") then
		return false
	end
	if child.Name == "PurchaseGear" then
		purchaseFn = child
	elseif child.Name == "EquipGear" then
		equipFn = child
	elseif child.Name == "SetEditedPower" then
		setPowerFn = child
	end
	return true
end

local function resolveGearRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return
	end
	cacheGearRemote(remotes:FindFirstChild("PurchaseGear"))
	cacheGearRemote(remotes:FindFirstChild("EquipGear"))
	cacheGearRemote(remotes:FindFirstChild("SetEditedPower"))
	cacheGearRemote(remotes:FindFirstChild("PrepareRobuxGear"), true)
end

local function waitForGearRemote(name: string, asEvent: boolean?): Instance?
	resolveGearRemotes()
	if name == "PurchaseGear" and purchaseFn and purchaseFn.Parent then
		return purchaseFn
	end
	if name == "EquipGear" and equipFn and equipFn.Parent then
		return equipFn
	end
	if name == "SetEditedPower" and setPowerFn and setPowerFn.Parent then
		return setPowerFn
	end
	if name == "PrepareRobuxGear" and prepareRobuxGearRE and prepareRobuxGearRE.Parent then
		return prepareRobuxGearRE
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		or ReplicatedStorage:WaitForChild("Remotes", 8)
	if not remotes then
		return nil
	end
	local child = remotes:FindFirstChild(name) or remotes:WaitForChild(name, 8)
	cacheGearRemote(child, asEvent)
	return child
end

resolveGearRemotes()
task.spawn(function()
	waitForGearRemote("PurchaseGear")
	waitForGearRemote("EquipGear")
	waitForGearRemote("SetEditedPower")
	waitForGearRemote("PrepareRobuxGear", true)
	if not purchaseFn then
		warn("[UpgradesController] PurchaseGear remote missing")
	end
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
local pendingWorkoutPower: number? = nil
local powerTween: Tween? = nil
local powerProxy: NumberValue? = nil
local powerBaseColor: Color3? = nil
local powerAnimToken = 0
local editFrame: Frame? = nil
local editWired = false
local editDragging = false
local editAlpha = 1
local editMaxPower = 0
local editBarGui: Frame? = nil -- legacy name kept unused; Studio frame is editFrame
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
			local rarityLabel = textNode :: TextLabel
			rarityLabel.Text = GearConfig.rarityDisplay(rarity)
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

local function applyShopGearIcon(iconFrame: GuiObject, gearId: number)
	local leftover = iconFrame:FindFirstChild("GearViewport")
	if leftover then
		leftover:Destroy()
	end
	local icon: ImageLabel? = nil
	local named = iconFrame:FindFirstChild("Icon") or iconFrame:FindFirstChild("ImageLabel")
	if named and named:IsA("ImageLabel") then
		icon = named
	else
		local any = iconFrame:FindFirstChildWhichIsA("ImageLabel")
		if any then
			icon = any
		end
	end
	if not icon then
		local created = Instance.new("ImageLabel")
		created.Name = "Icon"
		created.BackgroundTransparency = 1
		created.BorderSizePixel = 0
		created.Size = UDim2.fromScale(1, 1)
		created.Position = UDim2.fromScale(0.5, 0.5)
		created.AnchorPoint = Vector2.new(0.5, 0.5)
		created.ZIndex = iconFrame.ZIndex + 1
		created.Parent = iconFrame
		icon = created
	end
	icon.Visible = true
	icon.BackgroundTransparency = 1
	if not GearConfig.applyIconToGui(icon, gearId) then
		icon.Image = "rbxasset://textures/ui/GuiImagePlaceholder.png"
		icon.ScaleType = Enum.ScaleType.Fit
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
		local gearNameLabel = nameLabel :: TextLabel
		gearNameLabel.Text = def.name
	end
	applyRarityGradients(row, def.rarity)

	local iconFrame = row:FindFirstChild("IconFrame")
	if iconFrame and iconFrame:IsA("GuiObject") then
		applyShopGearIcon(iconFrame, def.id)
	end

	local powerFrame = row:FindFirstChild("Power")
	local powerText = powerFrame and (powerFrame:FindFirstChild("Power") or powerFrame:FindFirstChildWhichIsA("TextLabel"))
	if powerText and powerText:IsA("TextLabel") then
		local shown = def.powerGain
		local rebirthMult = RebirthConfig.getPowerGainMultiplier(player)
		local passMult = if player:GetAttribute(StoreConfig.ATTR.DOUBLE_POWER_OWNED) == true
			then StoreConfig.DOUBLE_POWER_MULTIPLIER
			else 1
		shown = math.max(1, math.floor(shown * rebirthMult * passMult + 1e-6))
		powerText.Text = formatPower(shown)
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
				local priceText = priceLabel :: TextLabel
				priceText.Text = ROBUX_ICON .. tostring(def.robuxPrice)
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
		local canAfford = balance >= def.cashPrice
		if canAfford then
			state = "buy"
			MainGradientButtons.applyDefault(host)
		else
			-- Same gray Equipped/Locked gradient as owned-equipped, so unaffordable isn't confused with buyable.
			state = "locked"
			MainGradientButtons.applyPurchasedGradient(host)
		end
		if costLabel then
			if def.cashPrice <= 0 then
				costLabel.Text = "FREE"
			else
				costLabel.Text = formatCash(def.cashPrice)
			end
		end
	end
	setStateGradients(host, state)
	if row:IsA("GuiObject") then
		setStateGradients(row :: GuiObject, state)
	end
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
			inFlight = true
			if not waitForGearRemote("EquipGear") or not equipFn then
				inFlight = false
				warn("[UpgradesController] EquipGear remote not ready")
				GameSoundEffects.playErrorNotif()
				return
			end
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
		inFlight = true
		if not waitForGearRemote("PurchaseGear") or not purchaseFn then
			inFlight = false
			warn("[UpgradesController] PurchaseGear remote not ready")
			GameSoundEffects.playErrorNotif()
			return
		end
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

local function restoreStudioPowerLayout(powerFrame: GuiObject)
	local cluster = powerFrame:FindFirstChild("PowerPulseCluster")
	if cluster then
		for _, ch in cluster:GetChildren() do
			if ch:IsA("GuiObject") then
				ch.Parent = powerFrame
			end
		end
		cluster:Destroy()
	end
	local amount = powerFrame:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then
		amount.Visible = true
		amount.TextTransparency = 0
		UiFonts.applyBody(amount)
	end
	local muscle = resolveMuscleIcon(powerFrame)
	if muscle then
		muscle.Visible = true
		muscle.ImageTransparency = 0
		muscle.Image = GearConfig.WORKOUT_IMAGE
	end
end

-- Pulse Amount + muscle in the Studio layout. Never reparent (that hid the icon).
local function ensurePulseCluster(powerFrame: GuiObject): GuiObject
	restoreStudioPowerLayout(powerFrame)
	local amount = powerFrame:FindFirstChild("Amount")
	if amount and amount:IsA("GuiObject") then
		return amount
	end
	return powerFrame
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
	if not (cluster and cluster:IsA("GuiObject")) then
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

	-- Scale punch lives on floater impact (WorkoutController). Color-only here
	-- so workout +N doesn't double-animate the counter oversized.
	if recentlyPulsed or not cluster or not cluster:IsA("GuiObject") then
		return
	end
	cluster:SetAttribute("PowerPulseAt", os.clock())
end

local function updatePowerLabel(opts: { target: number?, instant: boolean?, deferWorkout: boolean? }?)
	if not powerAmountLabel then
		return
	end
	local edited = WorkoutPower.isEdited(player)
	local target = if opts and typeof(opts.target) == "number"
		then opts.target :: number
		else WorkoutPower.readPower(player)

	local function applyText(n: number)
		local text = formatPower(n)
		if edited then
			text ..= " ✏"
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

	-- Workout gains wait for the +N floater to land before changing the number.
	if gained and opts and opts.deferWorkout == true then
		pendingWorkoutPower = target
		return
	end

	if gained or (opts and opts.instant == true) then
		playPowerGainFlash(powerAmountLabel)
		lastShownPower = target
		applyText(target)
		pendingWorkoutPower = nil
		return
	end

	local start = lastShownPower
	local proxy = Instance.new("NumberValue")
	proxy.Value = start
	powerProxy = proxy
	powerAnimToken += 1
	local token = powerAnimToken
	local ti = TweenInfo.new(0.08, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	powerTween = TweenService:Create(proxy, ti, { Value = target })
	proxy:GetPropertyChangedSignal("Value"):Connect(function()
		applyText(proxy.Value)
	end)
	powerTween.Completed:Connect(function()
		if token ~= powerAnimToken then
			return
		end
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

-- Pulse only stores the pending value — HUD text commits when the +N floater lands.
local function onWorkoutPowerPulse()
	if not powerAmountLabel then
		return
	end
	local gain = player:GetAttribute("WorkoutLastGain")
	local g = if typeof(gain) == "number" then gain else 0
	local actual = WorkoutPower.readPower(player)
	local predicted = lastShownPower + math.max(0, g)
	local target = math.max(actual, predicted)
	if target > lastShownPower + 0.5 then
		pendingWorkoutPower = target
	end
end

local function commitPowerHudFromFloater()
	local target = pendingWorkoutPower
	if typeof(target) ~= "number" then
		target = WorkoutPower.readPower(player)
	end
	pendingWorkoutPower = nil
	updatePowerLabel({ target = target, instant = true })
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

	-- Studio Power: Amount + ImageLabel + Edit + SPACE + UIListLayout. Do not reparent.
	restoreStudioPowerLayout(powerFrame)
	local muscle = resolveMuscleIcon(powerFrame)
	if muscle then
		muscle.Image = GearConfig.WORKOUT_IMAGE
		muscle.ImageTransparency = 0
		muscle.Visible = true
	end

	local amount = powerFrame:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then
		amount.TextTransparency = 0
		UiFonts.applyBody(amount)
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
	-- Prefer Studio-authored Edit / Set Strength control; never invent a duplicate.
	local names = { "Edit", "EditButton", "Edit Power", "Set Strength", "Strength", "SetPower" }
	for _, name in names do
		local existing = powerFrame:FindFirstChild(name, true)
		if existing then
			if existing:IsA("GuiButton") then
				return existing
			end
			local nested = existing:FindFirstChildWhichIsA("GuiButton", true)
			if nested then
				return nested
			end
		end
	end
	for _, child in powerFrame:GetDescendants() do
		if child:IsA("GuiButton") then
			local lower = string.lower(child.Name)
			if string.find(lower, "edit", 1, true) or string.find(lower, "strength", 1, true) then
				return child
			end
		end
	end
	return nil
end

local function ensureFullClickCover(host: GuiObject): GuiButton
	if host:IsA("GuiButton") then
		local btn = host :: GuiButton
		btn.Active = true
		pcall(function()
			(btn :: any).Interactable = true
		end)
		if btn:IsA("TextButton") then
			local tb = btn :: TextButton
			if string.lower(tb.Text) == "button" then
				tb.Text = ""
				tb.TextTransparency = 1
			end
		end
		return btn
	end
	local existing = host:FindFirstChild("_FullClickCover")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	for _, d in host:GetDescendants() do
		if d:IsA("GuiButton") then
			d.Active = false
			pcall(function()
				(d :: any).Interactable = false
			end)
		end
	end
	local cover = Instance.new("TextButton")
	cover.Name = "_FullClickCover"
	cover.BackgroundTransparency = 1
	cover.Text = ""
	cover.AutoButtonColor = false
	cover.Size = UDim2.fromScale(1, 1)
	cover.Position = UDim2.fromScale(0.5, 0.5)
	cover.AnchorPoint = Vector2.new(0.5, 0.5)
	cover.ZIndex = 80
	cover.Active = true
	cover.Parent = host
	return cover
end

local function ensureEditActionCaption(host: Instance?, title: string)
	if not host then
		return
	end
	local function showLabel(label: TextLabel)
		label.Visible = true
		label.TextTransparency = 0
		if label.Text == "" then
			label.Text = title
		end
	end
	local named = host:FindFirstChild("Name") or host:FindFirstChild("TextLabel")
	if named and (named:IsA("TextLabel") or named:IsA("TextButton")) then
		local label = named :: TextLabel
		if string.lower(label.Name) ~= "button" and string.lower(label.Text) ~= "button" then
			showLabel(label)
			return
		end
	end
	for _, d in host:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local t = string.lower((d :: TextLabel).Text)
			if t == "" or t == "cancel" or t == "okay" or t == "ok" or t == "set" then
				showLabel(d :: TextLabel)
				return
			end
		end
	end
	if host:IsA("TextButton") or host:IsA("ImageButton") then
		local btn = host :: TextButton
		if btn.Text == "" then
			btn.Text = title
		end
		btn.TextTransparency = 0
	end
end

-- Studio Okay/Cancel are image buttons; leftover Text on them looks like faint captions.
local function hideAuthoredButtonCaption(host: Instance?)
	if not host then
		return
	end
	local function hideText(gui: Instance)
		if gui:IsA("TextButton") or gui:IsA("ImageButton") then
			local btn = gui :: TextButton
			if btn:IsA("ImageButton") or (btn:IsA("TextButton") and btn.Text ~= "") then
				local hasArt = btn:IsA("ImageButton") and (btn :: ImageButton).Image ~= ""
				if hasArt or host:FindFirstChild("Decor") or host:FindFirstChild("Icon") or host:FindFirstChild("BG") then
					pcall(function()
						(btn :: any).Text = ""
						(btn :: any).TextTransparency = 1
					end)
				end
			end
		elseif gui:IsA("TextLabel") then
			local t = string.lower((gui :: TextLabel).Text)
			local n = string.lower(gui.Name)
			if t == "okay" or t == "ok" or t == "cancel" or t == "close" or t == "confirm" or t == "button" or n == "button" then
				(gui :: TextLabel).TextTransparency = 1
				(gui :: TextLabel).Visible = false
			end
		end
	end
	hideText(host)
	for _, d in host:GetDescendants() do
		hideText(d)
	end
end

local function setEditPowerLabels(amount: number)
	if not editFrame then
		return
	end
	local buttons = editFrame:FindFirstChild("Buttons")
	local bg = buttons and buttons:FindFirstChild("BG")
	local text = formatPower(amount)
	for _, name in { "PowerNumber", "PowerNumber shadow" } do
		local node = (bg and bg:FindFirstChild(name)) or (buttons and buttons:FindFirstChild(name, true))
		if node and (node:IsA("TextLabel") or node:IsA("TextButton")) then
			local label = node :: TextLabel
			label.Text = text
		end
	end
end

local function captureEditBarFullSize(bar: GuiObject)
	if bar:GetAttribute("EditBarFullCaptured") == true then
		return
	end
	bar:SetAttribute("EditBarFullXScale", bar.Size.X.Scale)
	bar:SetAttribute("EditBarFullXOffset", bar.Size.X.Offset)
	bar:SetAttribute("EditBarFullYScale", bar.Size.Y.Scale)
	bar:SetAttribute("EditBarFullYOffset", bar.Size.Y.Offset)
	bar:SetAttribute("EditBarFullCaptured", true)
end

-- Studio slider sits at the last (100%) position — that pose is the max, not Scale=1.
local function captureEditSliderMax(knob: GuiObject)
	if knob:GetAttribute("EditSliderMaxCaptured") == true then
		return
	end
	knob:SetAttribute("EditSliderMaxXScale", knob.Position.X.Scale)
	knob:SetAttribute("EditSliderMaxXOffset", knob.Position.X.Offset)
	knob:SetAttribute("EditSliderYScale", knob.Position.Y.Scale)
	knob:SetAttribute("EditSliderYOffset", knob.Position.Y.Offset)
	knob:SetAttribute("EditSliderAnchorX", knob.AnchorPoint.X)
	knob:SetAttribute("EditSliderAnchorY", knob.AnchorPoint.Y)
	knob:SetAttribute("EditSliderMaxCaptured", true)
end

local function restoreEditBarFullSize(bar: GuiObject)
	captureEditBarFullSize(bar)
	local xs = (bar:GetAttribute("EditBarFullXScale") :: number?) or 0
	local xo = (bar:GetAttribute("EditBarFullXOffset") :: number?) or 0
	local ys = (bar:GetAttribute("EditBarFullYScale") :: number?) or bar.Size.Y.Scale
	local yo = (bar:GetAttribute("EditBarFullYOffset") :: number?) or bar.Size.Y.Offset
	bar.Size = UDim2.new(xs, xo, ys, yo)
end

local function restoreEditSliderMax(knob: GuiObject)
	captureEditSliderMax(knob)
	local xs = (knob:GetAttribute("EditSliderMaxXScale") :: number?) or knob.Position.X.Scale
	local xo = (knob:GetAttribute("EditSliderMaxXOffset") :: number?) or knob.Position.X.Offset
	local ys = (knob:GetAttribute("EditSliderYScale") :: number?) or knob.Position.Y.Scale
	local yo = (knob:GetAttribute("EditSliderYOffset") :: number?) or knob.Position.Y.Offset
	local ax = (knob:GetAttribute("EditSliderAnchorX") :: number?) or knob.AnchorPoint.X
	local ay = (knob:GetAttribute("EditSliderAnchorY") :: number?) or knob.AnchorPoint.Y
	knob.AnchorPoint = Vector2.new(ax, ay)
	knob.Position = UDim2.new(xs, xo, ys, yo)
end

local function setEditProgressVisual(alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	editAlpha = alpha
	if not editFrame then
		return
	end
	local buttons = editFrame:FindFirstChild("Buttons")
	if not buttons then
		return
	end
	local bar = buttons:FindFirstChild("Progress bar")
	if bar and bar:IsA("GuiObject") then
		captureEditBarFullSize(bar)
		local xs = (bar:GetAttribute("EditBarFullXScale") :: number?) or 0
		local xo = (bar:GetAttribute("EditBarFullXOffset") :: number?) or 0
		local ys = (bar:GetAttribute("EditBarFullYScale") :: number?) or bar.Size.Y.Scale
		local yo = (bar:GetAttribute("EditBarFullYOffset") :: number?) or bar.Size.Y.Offset
		bar.Size = UDim2.new(xs * alpha, xo * alpha, ys, yo)
	end
	local knob = buttons:FindFirstChild("Slider")
	if knob and knob:IsA("GuiObject") then
		captureEditSliderMax(knob)
		local xs = (knob:GetAttribute("EditSliderMaxXScale") :: number?) or 0
		local xo = (knob:GetAttribute("EditSliderMaxXOffset") :: number?) or 0
		local ys = (knob:GetAttribute("EditSliderYScale") :: number?) or knob.Position.Y.Scale
		local yo = (knob:GetAttribute("EditSliderYOffset") :: number?) or knob.Position.Y.Offset
		local ax = (knob:GetAttribute("EditSliderAnchorX") :: number?) or knob.AnchorPoint.X
		local ay = (knob:GetAttribute("EditSliderAnchorY") :: number?) or knob.AnchorPoint.Y
		knob.AnchorPoint = Vector2.new(ax, ay)
		knob.Position = UDim2.new(xs * alpha, xo * alpha, ys, yo)
	end
	setEditPowerLabels(math.floor(alpha * editMaxPower + 0.5))
end

local function closeEditBar()
	editDragging = false
	editBarDragging = false
	local HUDController = require(script.Parent.HUDController)
	HUDController.closeFrameByName("Edit Power")
	if editFrame then
		editFrame.Visible = false
	end
end

local function resolveSetPowerFn(): RemoteFunction?
	if setPowerFn and setPowerFn.Parent then
		return setPowerFn
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild("SetEditedPower")
	if rf and rf:IsA("RemoteFunction") then
		setPowerFn = rf
		return rf
	end
	return nil
end

local function wireEditPowerFrame(frame: Frame)
	if editWired then
		return
	end
	editWired = true
	editFrame = frame

	local buttons = frame:FindFirstChild("Buttons")
	local bar = buttons and buttons:FindFirstChild("Progress bar")
	local knob = buttons and buttons:FindFirstChild("Slider")
	local cancelHost = buttons and buttons:FindFirstChild("CancelButton")
	local okayHost = buttons and buttons:FindFirstChild("OkayButton")
	local header = frame:FindFirstChild("Header")
	local headerButtons = header and header:FindFirstChild("Buttons")
	local closeHost = headerButtons and headerButtons:FindFirstChild("Close")
	hideAuthoredButtonCaption(closeHost)
	hideAuthoredButtonCaption(okayHost)
	hideAuthoredButtonCaption(cancelHost)
	ensureEditActionCaption(okayHost, "Set")
	ensureEditActionCaption(cancelHost, "Cancel")

	if bar and bar:IsA("GuiObject") then
		captureEditBarFullSize(bar)
		bar.Active = true
	end
	if knob and knob:IsA("GuiObject") then
		captureEditSliderMax(knob)
		knob.Active = true
	end

	local leftoverHit = buttons and buttons:FindFirstChild("__EditDragHit")
	if leftoverHit then
		leftoverHit:Destroy()
	end

	local movedConn: RBXScriptConnection? = nil
	local endedConn: RBXScriptConnection? = nil
	local function stopDrag()
		editDragging = false
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

	local function trackRect(): (number, number, number, number)
		-- left, width, top, height of the authored (full) progress track.
		local left = (frame:GetAttribute("EditTrackLeft") :: number?) or 0
		local width = (frame:GetAttribute("EditTrackWidth") :: number?) or 0
		local top = 0
		local height = 24
		if bar and bar:IsA("GuiObject") then
			top = bar.AbsolutePosition.Y
			height = math.max(bar.AbsoluteSize.Y, 24)
			if width <= 8 then
				left = bar.AbsolutePosition.X
				width = math.max(bar.AbsoluteSize.X, 1)
			end
		elseif knob and knob:IsA("GuiObject") then
			top = knob.AbsolutePosition.Y
			height = math.max(knob.AbsoluteSize.Y, 24)
		end
		-- Knob is easier to grab if the hit band is taller.
		if knob and knob:IsA("GuiObject") then
			local ky = knob.AbsolutePosition.Y
			local kh = math.max(knob.AbsoluteSize.Y, 1)
			top = math.min(top, ky) - 8
			height = math.max(height, (ky + kh) - top) + 16
		end
		return left, width, top, height
	end

	local function alphaFromInput(x: number): number
		local left, width = trackRect()
		if width <= 0 then
			return editAlpha
		end
		return math.clamp((x - left) / width, 0, 1)
	end

	local function beginDrag(inputX: number)
		editDragging = true
		editBarDragging = true
		if bar and bar:IsA("GuiObject") then
			-- Re-measure from the captured full size, not the shrunk fill.
			local fullW = frame:GetAttribute("EditTrackWidth")
			local fullL = frame:GetAttribute("EditTrackLeft")
			if typeof(fullW) ~= "number" or fullW <= 8 then
				restoreEditBarFullSize(bar)
				frame:SetAttribute("EditTrackWidth", math.max(bar.AbsoluteSize.X, 1))
				frame:SetAttribute("EditTrackLeft", bar.AbsolutePosition.X)
			elseif typeof(fullL) == "number" then
				-- keep stored
			end
		end
		setEditProgressVisual(alphaFromInput(inputX))
		if movedConn then
			movedConn:Disconnect()
		end
		if endedConn then
			endedConn:Disconnect()
		end
		movedConn = UserInputService.InputChanged:Connect(function(chg)
			if not editDragging then
				return
			end
			if
				chg.UserInputType == Enum.UserInputType.MouseMovement
				or chg.UserInputType == Enum.UserInputType.Touch
			then
				setEditProgressVisual(alphaFromInput(chg.Position.X))
			end
		end)
		endedConn = UserInputService.InputEnded:Connect(function(ended)
			if
				ended.UserInputType == Enum.UserInputType.MouseButton1
				or ended.UserInputType == Enum.UserInputType.Touch
			then
				task.defer(stopDrag)
			end
		end)
	end

	local function pointInTrack(x: number, y: number): boolean
		local left, width, top, height = trackRect()
		return x >= left and x <= left + width and y >= top and y <= top + height
	end

	local function bindDragTarget(node: Instance?)
		if not node or not node:IsA("GuiObject") then
			return
		end
		node.Active = true
		node.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				beginDrag(input.Position.X)
			end
		end)
	end
	bindDragTarget(bar)
	bindDragTarget(knob)

	local lastActionAt = 0
	local function cursorXY(input: InputObject): (number, number)
		if input.UserInputType == Enum.UserInputType.Touch then
			return input.Position.X, input.Position.Y
		end
		local mouse = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()
		return mouse.X - inset.X, mouse.Y - inset.Y
	end

	local function pointInHost(host: Instance?, x: number, y: number): boolean
		if not host or not host:IsA("GuiObject") then
			return false
		end
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if pg then
			local hits = pg:GetGuiObjectsAtPosition(x, y)
			for _, obj in hits do
				if obj == host or obj:IsDescendantOf(host) then
					return true
				end
			end
		end
		local gui = host :: GuiObject
		local p = gui.AbsolutePosition
		local s = gui.AbsoluteSize
		local pad = 12
		return x >= p.X - pad and x <= p.X + s.X + pad and y >= p.Y - pad and y <= p.Y + s.Y + pad
	end

	local function canFireAction(): boolean
		local now = os.clock()
		if now - lastActionAt < 0.35 then
			return false
		end
		lastActionAt = now
		return true
	end

	local function passClicksThrough(host: Instance?)
		if not host then
			return
		end
		if host:IsA("GuiObject") then
			(host :: GuiObject).Active = true
		end
		for _, d in host:GetDescendants() do
			if d:IsA("GuiObject") then
				(d :: GuiObject).Active = false
				if d:IsA("GuiButton") then
					pcall(function()
						(d :: any).Interactable = false
					end)
				end
			end
		end
	end
	passClicksThrough(okayHost)
	passClicksThrough(cancelHost)
	passClicksThrough(closeHost)

	local function onOkay()
		local amount = math.clamp(math.floor(editAlpha * editMaxPower + 0.5), 0, math.floor(editMaxPower))
		local markEdited = amount < editMaxPower
		local rf = resolveSetPowerFn()
		if rf then
			local ok = rf:InvokeServer(amount, markEdited)
			if ok then
				GameSoundEffects.playUpgrade()
				updatePowerLabel()
			else
				GameSoundEffects.playErrorNotif()
			end
		else
			warn("[UpgradesController] SetEditedPower remote missing")
			GameSoundEffects.playErrorNotif()
		end
		closeEditBar()
	end

	local function playPress(host: Instance?)
		if not host or not host:IsA("GuiObject") then
			return
		end
		local gui = host :: GuiObject
		local scale = gui:FindFirstChildOfClass("UIScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Scale = 1
			scale.Parent = gui
		end
		TweenService:Create(scale, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 0.88,
		}):Play()
		task.delay(0.08, function()
			if scale.Parent then
				TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Scale = 1.06,
				}):Play()
			end
		end)
	end

	local function tryOkay()
		if not canFireAction() then
			return
		end
		UIInteractionSounds.playClick()
		playPress(okayHost)
		onOkay()
	end

	local function tryClose()
		if not canFireAction() then
			return
		end
		UIInteractionSounds.playClick()
		closeEditBar()
	end

	local function hoverHost(host: Instance?)
		if not host or not host:IsA("GuiObject") then
			return
		end
		local gui = host :: GuiObject
		local scale = gui:FindFirstChildOfClass("UIScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Scale = 1
			scale.Parent = gui
		end
		gui.MouseEnter:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1.06,
			}):Play()
		end)
		gui.MouseLeave:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end)
	end
	hoverHost(okayHost)
	hoverHost(cancelHost)

	-- Screen-space hit test so Studio overlays / HUD Active flags can't eat the press.
	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if not frame.Visible then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local x, y = cursorXY(input)
		if pointInHost(okayHost, x, y) then
			tryOkay()
			return
		end
		if pointInHost(cancelHost, x, y) then
			playPress(cancelHost)
			tryClose()
			return
		end
		if pointInHost(closeHost, x, y) then
			playPress(closeHost)
			tryClose()
			return
		end
		if pointInTrack(x, y) then
			beginDrag(x)
		end
	end)
end

local function openEditBar(_main: ScreenGui)
	local main = PlayerGuiMain.ensure(player)
	local frames = main:FindFirstChild("Frames")
	local frame = frames and frames:FindFirstChild("Edit Power")
	if not frame or not frame:IsA("Frame") then
		warn("[UpgradesController] Frames['Edit Power'] missing")
		GameSoundEffects.playErrorNotif()
		return
	end
	wireEditPowerFrame(frame)
	editFrame = frame

	editMaxPower = math.max(0, math.floor(WorkoutPower.readPowerMax(player)))
	local activePower = math.max(0, math.floor(WorkoutPower.readPower(player)))
	local alpha = if editMaxPower > 0 then math.clamp(activePower / editMaxPower, 0, 1) else 1

	local HUDController = require(script.Parent.HUDController)
	HUDController.openFrameByName("Edit Power")
	frame.Visible = true

	task.defer(function()
		if not editFrame then
			return
		end
		local buttons = editFrame:FindFirstChild("Buttons")
		local bar = buttons and buttons:FindFirstChild("Progress bar")
		local knob = buttons and buttons:FindFirstChild("Slider")
		if bar and bar:IsA("GuiObject") then
			restoreEditBarFullSize(bar)
			editFrame:SetAttribute("EditTrackWidth", math.max(bar.AbsoluteSize.X, 1))
			editFrame:SetAttribute("EditTrackLeft", bar.AbsolutePosition.X)
		end
		if knob and knob:IsA("GuiObject") then
			restoreEditSliderMax(knob)
		end
		setEditProgressVisual(alpha)
		for _, name in { "OkayButton", "CancelButton" } do
			local host = buttons and buttons:FindFirstChild(name)
			if host then
				if host:IsA("GuiObject") then
					(host :: GuiObject).Active = true
				end
				for _, d in host:GetDescendants() do
					if d:IsA("GuiObject") then
						(d :: GuiObject).Active = false
					end
				end
			end
		end
		local header = editFrame:FindFirstChild("Header")
		local closeHost = header and header:FindFirstChild("Buttons")
		closeHost = closeHost and closeHost:FindFirstChild("Close")
		if closeHost then
			if closeHost:IsA("GuiObject") then
				(closeHost :: GuiObject).Active = true
			end
			for _, d in closeHost:GetDescendants() do
				if d:IsA("GuiObject") then
					(d :: GuiObject).Active = false
				end
			end
		end
	end)
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
		local function openPowerEdit()
			openEditBar(main)
		end
		local editHost = powerFrame:FindFirstChild("Edit")
		if editHost and editHost:IsA("GuiObject") then
			local btn = ensureFullClickCover(editHost)
			local icon = btn:FindFirstChild("Icon", true) or btn:FindFirstChildWhichIsA("ImageLabel", true)
			local tiltTarget: GuiObject = if icon and icon:IsA("GuiObject") then icon else btn
			-- Mobile: press = hover polish; still fires after a short camera drag.
			UIButtonEffects.wireTiltHoverButton(btn, openPowerEdit, btn, tiltTarget, true, true)
		else
			local editBtn = ensureEditButton(powerFrame)
			if editBtn then
				editBtn.Active = true
				pcall(function()
					(editBtn :: any).Interactable = true
				end)
				UIButtonEffects.wireSidebarButton(editBtn, openPowerEdit)
			end
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
		RebirthConfig.POWER_MULT_ATTR,
		StoreConfig.ATTR.DOUBLE_POWER_OWNED,
	} do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if attr == GearConfig.POWER_ATTR or attr == GearConfig.POWER_EDITED_ATTR then
				-- While curling, wait for the +N floater to land before flipping the number.
				if
					attr == GearConfig.POWER_ATTR
					and player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true
				then
					updatePowerLabel({ deferWorkout = true })
				else
					updatePowerLabel({ instant = true })
				end
			end
			if upgrades.Visible then
				queueRefreshAllRows()
			end
		end)
	end

	player:GetAttributeChangedSignal("WorkoutPowerPulse"):Connect(onWorkoutPowerPulse)

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
	snapPowerHud = onWorkoutPowerPulse,
	commitPowerHudFromFloater = commitPowerHudFromFloater,
	markCashBundlePurchasePending = function()
		pendingCashBundlePurchase = true
	end,
}
