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

local player = Players.LocalPlayer

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
local editBarGui: Frame? = nil

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
		if not container:FindFirstChild(name) then
			local clone = template:Clone()
			clone.Name = name
			clone.Parent = container
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
			then
				child.Visible = false
			end
		end
	end
end

local function refreshGearRow(row: Instance, def: GearConfig.GearDef)
	local owned = ownedSet()
	local unlocked = GearConfig.isUnlocked(def.id, owned)
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
		locked.Visible = not unlocked
		local needed = locked:FindFirstChild("AmountNeeded")
		if needed and needed:IsA("TextLabel") then
			local prev = GearConfig.get(def.id - 1)
			needed.Text = if prev then ("Own " .. prev.name) else "Locked"
		end
	end

	local buyButtons = row:FindFirstChild("BuyButtons")
	if not buyButtons then
		return
	end

	local robux = buyButtons:FindFirstChild("BuyRobux")
	if robux and robux:IsA("GuiObject") then
		robux.Visible = (not isOwned) and unlocked and def.robuxProductId ~= nil
		local priceLabel = robux:FindFirstChild("Price", true)
		if priceLabel and priceLabel:IsA("TextLabel") and def.robuxProductId then
			-- Product price text is filled by Studio; leave as-is if present.
		end
	end

	local host = findBuyHost(buyButtons)
	if not host then
		return
	end

	local costLabel = findCostLabel(host)
	local state: "buy" | "equip" | "equipped" | "locked"
	if not unlocked then
		state = "locked"
		if costLabel then
			costLabel.Text = "Locked"
		end
		MainGradientButtons.applyPurchasedGradient(host)
	elseif isEquipped then
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
		if balance < def.cashPrice then
			MainGradientButtons.applyPurchasedGradient(host)
		else
			MainGradientButtons.applyDefault(host)
		end
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
		if not GearConfig.isUnlocked(def.id, owned) then
			GameSoundEffects.playErrorNotif()
			return
		end
		if owned[def.id] then
			if not equipFn then
				return
			end
			inFlight = true
			local ok, err = equipFn:InvokeServer(def.id)
			inFlight = false
			if ok then
				GameSoundEffects.playUpgrade()
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
			GameSoundEffects.playUpgrade()
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

local function updatePowerLabel()
	if not powerAmountLabel then
		return
	end
	local power = WorkoutPower.readPower(player)
	lastShownPower = power
	local text = formatPower(power)
	if WorkoutPower.isEdited(player) then
		text ..= " (Edited)"
	end
	powerAmountLabel.Text = text
end

local function ensurePowerCounter(counters: Instance): TextLabel?
	local powerFrame = counters:FindFirstChild("Power")
	if not powerFrame then
		local cash = counters:FindFirstChild("Cash")
		if cash and cash:IsA("GuiObject") then
			powerFrame = cash:Clone()
			powerFrame.Name = "Power"
			powerFrame.Parent = counters
			local layout = counters:FindFirstChildOfClass("UIListLayout")
			if layout then
				(powerFrame :: GuiObject).LayoutOrder = (cash :: GuiObject).LayoutOrder + 1
			end
		end
	end
	if not powerFrame then
		return nil
	end
	local amount = powerFrame:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then
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
	if editBarGui then
		editBarGui.Visible = false
	end
end

local function openEditBar(main: ScreenGui)
	if not editBarGui then
		local frame = Instance.new("Frame")
		frame.Name = "PowerEditBar"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.55)
		frame.Size = UDim2.fromOffset(360, 140)
		frame.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
		frame.BorderSizePixel = 0
		frame.ZIndex = 50
		frame.Parent = main
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Parent = frame

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -20, 0, 28)
		title.Position = UDim2.fromOffset(10, 10)
		title.Font = Enum.Font.GothamBold
		title.Text = "Edit Power"
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextScaled = true
		title.ZIndex = 51
		title.Parent = frame
		local titleStroke = Instance.new("UIStroke")
		titleStroke.Thickness = 2
		titleStroke.Parent = title

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Name = "Value"
		valueLabel.BackgroundTransparency = 1
		valueLabel.Size = UDim2.new(1, -20, 0, 24)
		valueLabel.Position = UDim2.fromOffset(10, 42)
		valueLabel.Font = Enum.Font.GothamBold
		valueLabel.TextColor3 = Color3.new(1, 1, 1)
		valueLabel.TextScaled = true
		valueLabel.ZIndex = 51
		valueLabel.Parent = frame
		local valueStroke = Instance.new("UIStroke")
		valueStroke.Thickness = 2
		valueStroke.Parent = valueLabel

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Size = UDim2.new(1, -40, 0, 14)
		track.Position = UDim2.new(0, 20, 0, 78)
		track.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
		track.BorderSizePixel = 0
		track.ZIndex = 51
		track.Parent = frame
		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(1, 0)
		trackCorner.Parent = track

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = Color3.fromRGB(80, 220, 120)
		fill.BorderSizePixel = 0
		fill.ZIndex = 52
		fill.Parent = track
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(1, 0)
		fillCorner.Parent = fill

		local knob = Instance.new("Frame")
		knob.Name = "Knob"
		knob.Size = UDim2.fromOffset(22, 22)
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Position = UDim2.fromScale(0, 0.5)
		knob.BackgroundColor3 = Color3.new(1, 1, 1)
		knob.BorderSizePixel = 0
		knob.ZIndex = 53
		knob.Parent = track
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local okBtn = Instance.new("TextButton")
		okBtn.Name = "Ok"
		okBtn.Size = UDim2.fromOffset(100, 28)
		okBtn.Position = UDim2.new(0.5, -110, 1, -36)
		okBtn.BackgroundColor3 = Color3.fromRGB(70, 190, 90)
		okBtn.Text = "Okay"
		okBtn.TextColor3 = Color3.new(1, 1, 1)
		okBtn.Font = Enum.Font.GothamBold
		okBtn.TextScaled = true
		okBtn.ZIndex = 51
		okBtn.Parent = frame
		local okStroke = Instance.new("UIStroke")
		okStroke.Thickness = 2
		okStroke.Parent = okBtn
		local okCorner = Instance.new("UICorner")
		okCorner.CornerRadius = UDim.new(0, 8)
		okCorner.Parent = okBtn

		local cancelBtn = Instance.new("TextButton")
		cancelBtn.Name = "Cancel"
		cancelBtn.Size = UDim2.fromOffset(100, 28)
		cancelBtn.Position = UDim2.new(0.5, 10, 1, -36)
		cancelBtn.BackgroundColor3 = Color3.fromRGB(180, 70, 70)
		cancelBtn.Text = "Cancel"
		cancelBtn.TextColor3 = Color3.new(1, 1, 1)
		cancelBtn.Font = Enum.Font.GothamBold
		cancelBtn.TextScaled = true
		cancelBtn.ZIndex = 51
		cancelBtn.Parent = frame
		local cancelStroke = Instance.new("UIStroke")
		cancelStroke.Thickness = 2
		cancelStroke.Parent = cancelBtn
		local cancelCorner = Instance.new("UICorner")
		cancelCorner.CornerRadius = UDim.new(0, 8)
		cancelCorner.Parent = cancelBtn

		-- Wire drag + buttons once at creation.
		local dragging = false
		local movedConn: RBXScriptConnection? = nil
		local endedConn: RBXScriptConnection? = nil
		local function stopDrag()
			dragging = false
			if movedConn then
				movedConn:Disconnect()
				movedConn = nil
			end
			if endedConn then
				endedConn:Disconnect()
				endedConn = nil
			end
		end

		frame:SetAttribute("MaxPower", 1_000_000)

		local function currentMax(): number
			local m = frame:GetAttribute("MaxPower")
			return if typeof(m) == "number" then m else 1_000_000
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
				return if typeof(cur) == "number" then cur else 0
			end
			return (x - absPos) / absSize
		end

		knob.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = true
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
						stopDrag()
					end
				end)
			end
		end)

		track.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				applyAlpha(alphaFromInput(input.Position.X))
			end
		end)

		UIButtonEffects.wireScaleButtonAnim(okBtn, function()
			local a = frame:GetAttribute("Alpha")
			local alphaVal = if typeof(a) == "number" then a else 0
			local amount = math.floor(alphaVal * currentMax() + 0.5)
			if setPowerFn then
				local ok = setPowerFn:InvokeServer(amount)
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

	local maxPower = math.max(1_000_000, WorkoutPower.readPower(player) * 4, 10_000)
	frame:SetAttribute("MaxPower", maxPower)
	local alpha = math.clamp(WorkoutPower.readPower(player) / maxPower, 0, 1)
	frame:SetAttribute("Alpha", alpha)
	fill.Size = UDim2.fromScale(alpha, 1)
	knob.Position = UDim2.new(alpha, 0, 0.5, 0)
	valueLabel.Text = formatPower(math.floor(alpha * maxPower + 0.5))
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
