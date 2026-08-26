-- [ACTIVE] RebirthController
--[[
	Rebirth2 UI — requirements, rewards preview, rebirth / skip buttons, sidebar badge, plot sign.
--]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local HUDController = require(script.Parent.HUDController)
local MainGradientButtons = require(script.Parent.MainGradientButtons)
local TopNotifController = require(script.Parent.TopNotifController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local MobileHaptics = require(script.Parent.MobileHaptics)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer
local _playerGui = player:WaitForChild("PlayerGui")

local OPEN_NOTIF = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BADGE_SWAY = TweenInfo.new(0.72, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BADGE_INNER_SWAY = TweenInfo.new(0.52, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BADGE_INNER_PULSE = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
local BADGE_SWAY_DEG = 5
local BADGE_INNER_SWAY_DEG = 2.5
local CLICK_OVERLAY_NAME = "__RebirthClickOverlay"

local SKIP_SUBTITLE_TEXT = "[Keep Your Speed]"

local RARITY_GRADIENT_NAMES: { [string]: string } = {
	common = "Common",
	uncommon = "Uncommon",
	rare = "Rare",
	epic = "Epic",
	mythic = "Mythical",
	legendary = "Legendary",
	["brainrot god"] = "Godly",
	secret = "Godly",
}

local RARITY_DISPLAY_TEXT: { [string]: string } = {
	Common = "Common",
	Uncommon = "Uncommon",
	Rare = "Rare",
	Epic = "Epic",
	Mythical = "Mythic",
	Legendary = "Legendary",
	Godly = "Godly",
}

local REBIRTH_BUTTON_TEXT = "REBIRTH"

local rebirthFrame: Frame? = nil
local rebirthBtnHost: GuiObject? = nil
local skipBtnHost: GuiObject? = nil
local rarityGradientsFolder: Folder? = nil
local rebirthSidebarNotif: GuiObject? = nil
local rebirthSidebarNotifInner: TextLabel? = nil
local badgeSwayTween: Tween? = nil
local badgeInnerSwayTween: Tween? = nil
local badgeInnerPulseTween: Tween? = nil
local lastCanRebirth = false
local lastSnapshot: RebirthConfig.RebirthSnapshot? = nil
local skipPriceLabels: { TextLabel } = {}
local skipPriceTemplates: { [TextLabel]: string } = {}
local rebirthBusy = false

local getStateRF: RemoteFunction? = nil
local performRF: RemoteFunction? = nil
local updatedRE: RemoteEvent? = nil
local lastRebirthSignShow: boolean? = nil

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

local function waitMain(): ScreenGui?
	return PlayerGuiMain.ensure(player)
end

local function findRebirthSidebarNotif(main: ScreenGui): GuiObject?
	local sideUI = main:FindFirstChild("SideUI")
	if not sideUI then
		return nil
	end
	local rebirthBtn = sideUI:FindFirstChild("Rebirth", true)
	local notif = rebirthBtn and rebirthBtn:FindFirstChild("Notif")
	if notif and notif:IsA("GuiObject") then
		return notif :: GuiObject
	end
	return nil
end

local function findNotifInnerLabel(notif: GuiObject): TextLabel?
	if notif:IsA("TextLabel") then
		return notif :: TextLabel
	end
	local direct = notif:FindFirstChildWhichIsA("TextLabel")
	if direct then
		return direct
	end
	for _, name in { "!", "Text", "TextLabel", "Label", "Icon" } do
		local inst = notif:FindFirstChild(name, true)
		if inst and inst:IsA("TextLabel") then
			return inst
		end
	end
	return nil
end

local function stopBadgeSway()
	if badgeSwayTween then
		badgeSwayTween:Cancel()
		badgeSwayTween = nil
	end
	if badgeInnerSwayTween then
		badgeInnerSwayTween:Cancel()
		badgeInnerSwayTween = nil
	end
	if badgeInnerPulseTween then
		badgeInnerPulseTween:Cancel()
		badgeInnerPulseTween = nil
	end
	if rebirthSidebarNotif then
		rebirthSidebarNotif.Rotation = 0
	end
	if rebirthSidebarNotifInner then
		rebirthSidebarNotifInner.Rotation = 0
		local innerScale = rebirthSidebarNotifInner:FindFirstChildOfClass("UIScale")
		if innerScale then
			innerScale.Scale = 1
		end
	end
end

local function startBadgeSway()
	if not rebirthSidebarNotif then
		return
	end
	stopBadgeSway()
	rebirthSidebarNotif.Rotation = -BADGE_SWAY_DEG
	badgeSwayTween = TweenService:Create(rebirthSidebarNotif, BADGE_SWAY, { Rotation = BADGE_SWAY_DEG })
	badgeSwayTween:Play()

	if rebirthSidebarNotifInner then
		rebirthSidebarNotifInner.Rotation = BADGE_INNER_SWAY_DEG
		badgeInnerSwayTween = TweenService:Create(
			rebirthSidebarNotifInner,
			BADGE_INNER_SWAY,
			{ Rotation = -BADGE_INNER_SWAY_DEG }
		)
		badgeInnerSwayTween:Play()

		local innerScale = getOrAddUIScale(rebirthSidebarNotifInner)
		innerScale.Scale = 0.985
		badgeInnerPulseTween = TweenService:Create(innerScale, BADGE_INNER_PULSE, { Scale = 1.015 })
		badgeInnerPulseTween:Play()
	end
end

local function hideSidebarBadge()
	stopBadgeSway()
	if not rebirthSidebarNotif then
		return
	end
	rebirthSidebarNotif.Visible = false
	local scale = rebirthSidebarNotif:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end
end

local function showSidebarBadge()
	if not rebirthSidebarNotif then
		return
	end
	if rebirthSidebarNotif.Visible and badgeSwayTween then
		return
	end
	local scale = getOrAddUIScale(rebirthSidebarNotif)
	rebirthSidebarNotif.Visible = true
	scale.Scale = 0.15
	TweenService:Create(scale, OPEN_NOTIF, { Scale = 1 }):Play()
	startBadgeSway()
end

local function setIconFit(inst: Instance)
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		inst.ScaleType = Enum.ScaleType.Fit
	end
end

local function applyIconFitToFrame(frame: Frame)
	for _, desc in frame:GetDescendants() do
		if desc.Name == "Icon" or (desc.Parent and desc.Parent.Name == "Completed" and desc:IsA("ImageLabel")) then
			setIconFit(desc)
		end
	end
	local headerIcon = frame:FindFirstChild("Header", true)
	headerIcon = headerIcon and headerIcon:FindFirstChild("Icon")
	if headerIcon then
		setIconFit(headerIcon)
	end
end

local function rarityGradientName(rarityId: string): string?
	local key = RebirthConfig.normalizeRarity(rarityId)
	return RARITY_GRADIENT_NAMES[key]
end

local function applyFrameRarityLabel(rarityNode: Instance, rarityId: string)
	local gradName = rarityGradientName(rarityId)
	if not gradName then
		return
	end

	local displayText = RARITY_DISPLAY_TEXT[gradName] or gradName
	local label: TextLabel? = nil

	if rarityNode:IsA("TextLabel") then
		label = rarityNode :: TextLabel
	else
		for _, ch in rarityNode:GetChildren() do
			if ch:IsA("TextLabel") then
				local nameKey = string.lower(ch.Name)
				local wantKey = string.lower(gradName)
				local matches = nameKey == wantKey
					or (wantKey == "mythical" and nameKey == "mythic")
					or (wantKey == "godly" and (nameKey == "brainrotgod" or nameKey == "godly"))
				ch.Visible = matches
				if matches then
					label = ch
				end
			end
		end
		if not label then
			for _, ch in rarityNode:GetChildren() do
				if ch:IsA("TextLabel") then
					label = ch
					ch.Visible = true
					break
				end
			end
		end
		if not label then
			label = rarityNode:FindFirstChildWhichIsA("TextLabel", true)
		end
	end

	if not label then
		return
	end

	label.Visible = true
	label.Text = displayText
	label.TextColor3 = Color3.new(1, 1, 1)

	for _, ch in label:GetChildren() do
		if ch:IsA("UIGradient") then
			ch:Destroy()
		end
	end

	local template = rarityGradientsFolder and rarityGradientsFolder:FindFirstChild(gradName)
	if template and template:IsA("UIGradient") then
		local clone = template:Clone()
		clone.Enabled = true
		clone.Parent = label
	end
end

local function setLabelText(node: Instance?, text: string)
	if not node then
		return
	end
	if node:IsA("TextLabel") or node:IsA("TextButton") then
		(node :: TextLabel).Text = text
		return
	end
	local tl = node:FindFirstChildWhichIsA("TextLabel")
	if tl then
		tl.Text = text
	end
end

local function getRebirthButtonIcon(frame: Frame): string
	local header = frame:FindFirstChild("Header")
	local icon = header and header:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") and icon.Image ~= "" then
		return icon.Image
	end
	if icon and icon:IsA("ImageButton") and icon.Image ~= "" then
		return icon.Image
	end
	local rebirthBtn = frame:FindFirstChild("Buttons", true)
	rebirthBtn = rebirthBtn and rebirthBtn:FindFirstChild("Rebirth")
	local infoIcon = rebirthBtn and rebirthBtn:FindFirstChild("Info")
	infoIcon = infoIcon and infoIcon:FindFirstChild("Icon")
	if infoIcon and infoIcon:IsA("ImageLabel") and infoIcon.Image ~= "" then
		return infoIcon.Image
	end
	return ""
end

local function getCarryUpgradeIcon(main: ScreenGui): string
	local frames = main:FindFirstChild("Frames")
	local upgrades = frames and frames:FindFirstChild("Upgrades")
	local container = upgrades and upgrades:FindFirstChild("Container")
	local row = container and container:FindFirstChild("Carry1")
	local icon = row and row:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") and icon.Image ~= "" then
		return icon.Image
	end
	if icon and icon:IsA("ImageButton") and icon.Image ~= "" then
		return icon.Image
	end
	return ""
end

local function getMoneyIconFromRequirements(frame: Frame): string
	local items = frame:FindFirstChild("Requirements", true)
	items = items and items:FindFirstChild("Items")
	local cashRow = items and items:FindFirstChild("1")
	local icon = cashRow and cashRow:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") and icon.Image ~= "" then
		return icon.Image
	end
	return ""
end

local function setCompleted(row: Frame?, visible: boolean)
	if not row then
		return
	end
	local completed = row:FindFirstChild("Completed")
	if completed and completed:IsA("GuiObject") then
		completed.Visible = visible
	end
end

local function applyBrainrotRequirementRow(row: Frame, reqInfo: RebirthConfig.BrainrotReqState)
	local rarityNode = row:FindFirstChild("Rarity")
	if rarityNode then
		applyFrameRarityLabel(rarityNode, reqInfo.rarity)
	end

	setLabelText(row:FindFirstChild("ItemType"), RebirthConfig.formatBrainrotDisplayName(reqInfo.name))

	local icon = row:FindFirstChild("Icon")
	if icon and typeof(reqInfo.icon) == "string" and reqInfo.icon ~= "" then
		if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
			icon.Image = reqInfo.icon
			setIconFit(icon)
		end
	end

	setCompleted(row, reqInfo.met)
end

local function findRewardCards(frame: Frame): (Frame?, Frame?)
	local rewards = frame:FindFirstChild("Rewards")
	if not rewards then
		return nil, nil
	end
	local items = rewards:FindFirstChild("Items")
	if not items then
		return nil, nil
	end
	local slot = items:FindFirstChild("Slot")
	local boost = items:FindFirstChild("Boost")
	local floorCard = if slot and slot:IsA("Frame") then slot else nil
	local moneyCard = if boost and boost:IsA("Frame") then boost else nil
	return floorCard, moneyCard
end

local function setCardText(card: Frame?, topText: string?, bottomText: string?, iconImage: string?, visible: boolean?)
	if not card then
		return
	end
	if typeof(visible) == "boolean" then
		card.Visible = visible
	end

	local amount = card:FindFirstChild("Amount", true)
	if amount and amount:IsA("TextLabel") and topText then
		amount.Text = topText
	end

	local boostLabel = card:FindFirstChild("Boost", true)
	if boostLabel and boostLabel:IsA("TextLabel") and topText then
		boostLabel.Text = topText
	end

	local textLabel = card:FindFirstChild("TextLabel", true)
	if textLabel and textLabel:IsA("TextLabel") and bottomText then
		textLabel.Text = bottomText
	end

	local itemType = card:FindFirstChild("ItemType", true)
	if itemType and itemType:IsA("TextLabel") and bottomText then
		itemType.Text = bottomText
	end

	local icon = card:FindFirstChild("Icon", true)
	if icon and iconImage and iconImage ~= "" then
		if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
			icon.Image = iconImage
			setIconFit(icon)
		end
	end
end

local function applyMoneyRewardText(frame: Frame, rewardText: string)
	local rewards = frame:FindFirstChild("Rewards")
	if not rewards then
		return
	end
	local items = rewards:FindFirstChild("Items")
	local powerBoost = items and items:FindFirstChild("PowerBoost")
	for _, desc in rewards:GetDescendants() do
		if powerBoost and (desc == powerBoost or desc:IsDescendantOf(powerBoost)) then
			continue
		end
		if not desc:IsA("TextLabel") then
			continue
		end
		if desc.Name == "Boost" or (desc.Name == "Amount" and string.find(desc.Text, "%%", 1, true)) then
			desc.Text = rewardText
		elseif string.find(desc.Text, "+%", 1, true) and string.find(desc.Text, "%%", 1, true) then
			desc.Text = rewardText
		end
	end
end

local function applyPowerBoostCard(frame: Frame, rewardText: string)
	local rewards = frame:FindFirstChild("Rewards")
	local items = rewards and rewards:FindFirstChild("Items")
	local card = items and items:FindFirstChild("PowerBoost")
	if not (card and card:IsA("GuiObject")) then
		return
	end
	card.Visible = true
	setCardText(card :: Frame, rewardText, "Power", nil, true)
end

local function setGuiTreeVisible(root: Instance?, visible: boolean)
	if not root then
		return
	end
	if root:IsA("GuiObject") then
		(root :: GuiObject).Visible = visible
	elseif root:IsA("BillboardGui") or root:IsA("SurfaceGui") then
		(root :: any).Enabled = visible
	end
	for _, ch in root:GetDescendants() do
		if ch:IsA("GuiObject") then
			(ch :: GuiObject).Visible = visible
		elseif ch:IsA("BillboardGui") or ch:IsA("SurfaceGui") then
			(ch :: any).Enabled = visible
		end
	end
end

local function refreshPlotRebirthSign(snapshot: RebirthConfig.RebirthSnapshot)
	local show = snapshot.canRebirth and snapshot.isFloorRebirth
	if lastRebirthSignShow == show then
		return
	end
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		-- Don't cache: the plot may not have streamed in yet, retry on the next refresh.
		return
	end
	lastRebirthSignShow = show
	for _, desc in plot:GetDescendants() do
		if desc:IsA("Model") and (desc.Name == "RebirthSign" or string.find(desc.Name, "RebirthSign", 1, true)) then
			setGuiTreeVisible(desc, show)
			for _, part in desc:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = if show then 0 else 1
				end
			end
		end
	end
end

local function ensureClickOverlay(host: GuiObject): TextButton
	for _, d in host:GetDescendants() do
		if d == host or d.Name == CLICK_OVERLAY_NAME then
			continue
		end
		if d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("TextLabel") then
			(d :: GuiObject).Active = false
		end
	end

	host.Active = true

	local existing = host:FindFirstChild(CLICK_OVERLAY_NAME)
	local clickBtn: TextButton
	if existing and existing:IsA("TextButton") then
		clickBtn = existing
	else
		if existing then
			existing:Destroy()
		end
		clickBtn = Instance.new("TextButton")
		clickBtn.Name = CLICK_OVERLAY_NAME
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.Position = UDim2.fromScale(0, 0)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.TextTransparency = 1
		clickBtn.AutoButtonColor = false
		clickBtn.BorderSizePixel = 0
		clickBtn.ZIndex = 1000
		clickBtn.Parent = host
	end

	clickBtn.Active = true
	clickBtn.Selectable = true
	clickBtn.AutoButtonColor = false
	return clickBtn
end

local function wireClickButton(button: GuiButton, animTarget: Instance, onClick: () -> ())
	local scale = getOrAddUIScale(if animTarget:IsA("GuiObject") then animTarget :: GuiObject else button)
	local lastFire = 0
	local function fire()
		local now = os.clock()
		if now - lastFire < 0.12 then
			return
		end
		lastFire = now
		onClick()
	end
	button.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		fire()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
end

local function wireFrameButton(host: Instance?, onClick: () -> ())
	if not host or not host:IsA("GuiObject") then
		return
	end
	local hostGui = host :: GuiObject
	local clickBtn = ensureClickOverlay(hostGui)
	wireClickButton(clickBtn, hostGui, onClick)
end

local function rememberPriceLabel(label: TextLabel)
	if skipPriceTemplates[label] then
		return
	end
	skipPriceTemplates[label] = label.Text
	table.insert(skipPriceLabels, label)
end

local function setRegionalPrice(label: TextLabel, price: number)
	local template = skipPriceTemplates[label]
	if not template then
		template = label.Text
		skipPriceTemplates[label] = template
	end
	label.Text = string.gsub(template, "%d+", tostring(price), 1)
end

local function setRebirthActionEnabled(enabled: boolean)
	for _, host in { rebirthBtnHost, skipBtnHost } do
		if not host or not host:IsA("GuiObject") then
			continue
		end
		local overlay = host:FindFirstChild(CLICK_OVERLAY_NAME)
		if overlay and overlay:IsA("GuiButton") then
			overlay.Active = enabled
			overlay.AutoButtonColor = enabled
		end
		host.Active = enabled
	end
end

local function applyMaxRebirthUi(frame: Frame, snapshot: RebirthConfig.RebirthSnapshot, moneyIcon: string)
	local req = frame:FindFirstChild("Requirements")
	if req and req:IsA("GuiObject") then
		req.Visible = false
	end

	local moneyRewardText = RebirthConfig.moneyRewardTextForTier(snapshot.rebirthCount)
	local floorCard, moneyCard = findRewardCards(frame)
	setCardText(floorCard, nil, nil, nil, false)
	setCardText(moneyCard, moneyRewardText, "Money (MAX)", moneyIcon, true)
	applyMoneyRewardText(frame, moneyRewardText)
	applyPowerBoostCard(frame, RebirthConfig.powerRewardTextForTier(snapshot.rebirthCount))

	local headerName = frame:FindFirstChild("Header", true)
	headerName = headerName and headerName:FindFirstChild("Name")
	if headerName and headerName:IsA("TextLabel") then
		headerName.Text = ("Rebirth #%d — MAX"):format(snapshot.rebirthCount)
	end

	local rebirthInfoHost = frame:FindFirstChild("Buttons", true)
	rebirthInfoHost = rebirthInfoHost and rebirthInfoHost:FindFirstChild("Rebirth")
	local rebirthInfo = rebirthInfoHost and rebirthInfoHost:FindFirstChild("Info")
	if rebirthBtnHost and rebirthBtnHost:IsA("GuiObject") then
		MainGradientButtons.applyPurchased(rebirthBtnHost :: GuiObject, "MAX")
	elseif rebirthInfo then
		setLabelText(rebirthInfo:FindFirstChild("Name"), "MAX")
	end

	if skipBtnHost and skipBtnHost:IsA("GuiObject") then
		MainGradientButtons.applyPurchasedGradient(skipBtnHost :: GuiObject)
	end

	local skipSubtitle = skipBtnHost and skipBtnHost:FindFirstChild("TextLabel")
	if skipSubtitle and skipSubtitle:IsA("TextLabel") then
		skipSubtitle.Text = "Max rebirth reached"
	end

	setRebirthActionEnabled(false)
end

local function applySnapshot(snapshot: RebirthConfig.RebirthSnapshot, main: ScreenGui)
	local prev = lastSnapshot
	lastSnapshot = snapshot
	local frame = rebirthFrame
	if not frame then
		return
	end

	local frameOpen = frame.Visible
	local canRebirthChanged = not prev or prev.canRebirth ~= snapshot.canRebirth
	local cashMetChanged = not prev or prev.cashMet ~= snapshot.cashMet
	if not frameOpen then
		if snapshot.isMaxRebirth then
			hideSidebarBadge()
			lastCanRebirth = false
		elseif canRebirthChanged or cashMetChanged then
			-- The sign depends on isFloorRebirth too; refreshPlotRebirthSign caches and early-outs itself.
			refreshPlotRebirthSign(snapshot)
			if snapshot.canRebirth then
				if not lastCanRebirth then
					UIInteractionSounds.playNotif()
				end
				showSidebarBadge()
			else
				hideSidebarBadge()
			end
			lastCanRebirth = snapshot.canRebirth
		end
		return
	end

	if snapshot.isMaxRebirth then
		hideSidebarBadge()
		lastCanRebirth = false
		if frameOpen then
			local moneyIcon = getMoneyIconFromRequirements(frame)
			applyMaxRebirthUi(frame, snapshot, moneyIcon)
		end
		refreshPlotRebirthSign(snapshot)
		return
	end

	setRebirthActionEnabled(true)
	if rebirthBtnHost and rebirthBtnHost:IsA("GuiObject") then
		MainGradientButtons.applyDefault(rebirthBtnHost :: GuiObject)
	end
	if skipBtnHost and skipBtnHost:IsA("GuiObject") then
		MainGradientButtons.applyDefault(skipBtnHost :: GuiObject)
	end
	local skipSubtitle = skipBtnHost and skipBtnHost:FindFirstChild("TextLabel")
	if skipSubtitle and skipSubtitle:IsA("TextLabel") then
		skipSubtitle.Text = SKIP_SUBTITLE_TEXT
	end
	local req = frame:FindFirstChild("Requirements")
	if req and req:IsA("GuiObject") then
		req.Visible = true
	end

	local carryIcon = getCarryUpgradeIcon(main)
	local moneyIcon = getMoneyIconFromRequirements(frame)
	local rebirthIcon = getRebirthButtonIcon(frame)
	local moneyRewardText = RebirthConfig.moneyRewardTextForTier(snapshot.nextTier)

	local items = req and req:FindFirstChild("Items")
	local cashRow = items and items:FindFirstChild("1")
	if cashRow and cashRow:IsA("Frame") then
		local amount = cashRow:FindFirstChild("Amount")
		if amount and amount:IsA("TextLabel") then
			amount.Text = BrainrotEconomy.formatCashShort(snapshot.cashRequired)
		end
		local itemType = cashRow:FindFirstChild("ItemType")
		if itemType and itemType:IsA("TextLabel") then
			itemType.Text = "Cash"
		end
		setCompleted(cashRow, snapshot.cashMet)
	end

	for _, reqInfo in snapshot.brainrotReqs do
		local row = items and items:FindFirstChild(tostring(reqInfo.itemIndex))
		if row and row:IsA("Frame") then
			row.Visible = true
			applyBrainrotRequirementRow(row, reqInfo)
		end
	end
	if items then
		for _, idx in { "2", "3" } do
			local row = items:FindFirstChild(idx)
			if row and row:IsA("Frame") then
				local used = false
				for _, reqInfo in snapshot.brainrotReqs do
					if tostring(reqInfo.itemIndex) == idx then
						used = true
						break
					end
				end
				if not used then
					row.Visible = false
				end
			end
		end
	end

	local floorCard, moneyCard = findRewardCards(frame)
	if snapshot.isFloorRebirth then
		setCardText(floorCard, "+1", "Floor", carryIcon, true)
		setCardText(moneyCard, nil, nil, nil, false)
	else
		setCardText(floorCard, nil, nil, nil, false)
		setCardText(moneyCard, moneyRewardText, "Money", moneyIcon, true)
		applyMoneyRewardText(frame, moneyRewardText)
	end
	applyPowerBoostCard(frame, RebirthConfig.powerRewardTextForTier(snapshot.nextTier))

	local rebirthInfoHost = frame:FindFirstChild("Buttons", true)
	rebirthInfoHost = rebirthInfoHost and rebirthInfoHost:FindFirstChild("Rebirth")
	local rebirthInfo = rebirthInfoHost and rebirthInfoHost:FindFirstChild("Info")
	if rebirthInfo then
		local nameLabel = rebirthInfo:FindFirstChild("Name")
		local iconLabel = rebirthInfo:FindFirstChild("Icon")
		setLabelText(nameLabel, REBIRTH_BUTTON_TEXT)
		if iconLabel and rebirthIcon ~= "" then
			if iconLabel:IsA("ImageLabel") or iconLabel:IsA("ImageButton") then
				iconLabel.Image = rebirthIcon
				setIconFit(iconLabel)
			end
		end
	end

	local headerName = frame:FindFirstChild("Header", true)
	headerName = headerName and headerName:FindFirstChild("Name")
	if headerName and headerName:IsA("TextLabel") then
		headerName.Text = ("Rebirth #%d"):format(snapshot.nextTier)
	end

	refreshPlotRebirthSign(snapshot)

	if snapshot.canRebirth and not frameOpen then
		if not lastCanRebirth then
			UIInteractionSounds.playNotif()
		end
		showSidebarBadge()
	else
		hideSidebarBadge()
	end
	lastCanRebirth = snapshot.canRebirth
end

local function fetchAndApply(main: ScreenGui)
	if not getStateRF then
		return
	end
	local ok, snapshot = pcall(function()
		return getStateRF:InvokeServer()
	end)
	if ok and typeof(snapshot) == "table" then
		applySnapshot(snapshot :: RebirthConfig.RebirthSnapshot, main)
	elseif not ok then
		warn("[RebirthController] GetRebirthState failed:", snapshot)
	end
end

local function tryRebirth(main: ScreenGui)
	if rebirthBusy or not performRF then
		return
	end
	if not lastSnapshot or lastSnapshot.isMaxRebirth then
		GameSoundEffects.playErrorNotif()
		return
	end
	if not lastSnapshot.canRebirth then
		if not lastSnapshot.cashMet then
			TopNotifController.showCantAfford()
		else
			GameSoundEffects.playErrorNotif()
		end
		return
	end
	rebirthBusy = true
	local invoked, ok, err = pcall(function()
		return performRF:InvokeServer()
	end)
	rebirthBusy = false
	if not invoked then
		warn("[RebirthController] PerformRebirth invoke failed:", ok)
		GameSoundEffects.playErrorNotif()
		return
	end
	if ok then
		UIInteractionSounds.playClick()
		MobileHaptics.confirm()
		HUDController.closeCurrentFrame()
		fetchAndApply(main)
	else
		GameSoundEffects.playErrorNotif()
		if err then
			warn("[RebirthController] Rebirth failed:", err)
		end
	end
end

local function trySkipPurchase()
	if rebirthBusy or (lastSnapshot and lastSnapshot.isMaxRebirth) then
		if lastSnapshot and lastSnapshot.isMaxRebirth then
			GameSoundEffects.playErrorNotif()
		end
		return
	end
	rebirthBusy = true
	task.delay(1.5, function()
		rebirthBusy = false
	end)
	pcall(function()
		PurchasePrompt.promptProduct(RebirthConfig.SKIP_DEV_PRODUCT_ID)
	end)
end

local function refreshSkipPriceLabels()
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(RebirthConfig.SKIP_DEV_PRODUCT_ID, Enum.InfoType.Product)
		end)
		if not ok or typeof(info) ~= "table" or typeof(info.PriceInRobux) ~= "number" then
			return
		end
		for _, label in skipPriceLabels do
			if label.Parent then
				setRegionalPrice(label, info.PriceInRobux)
			end
		end
	end)
end

local RebirthController = {}

function RebirthController.init()
	local main = waitMain()
	if not main then
		warn("[RebirthController] Main ScreenGui missing")
		return
	end

	MainGradientButtons.init(main)

	local frames = main:WaitForChild("Frames")
	rebirthFrame = frames:WaitForChild("Rebirth2") :: Frame
	-- Never leave the frames container absorbing mouse input (breaks camera + plot SurfaceGuis).
	frames.Active = false
	rebirthFrame.Active = false

	local gradients = rebirthFrame:FindFirstChild("Gradients")
	local rarities = gradients and gradients:FindFirstChild("Rarities")
	if rarities and rarities:IsA("Folder") then
		rarityGradientsFolder = rarities
	end
	applyIconFitToFrame(rebirthFrame)

	rebirthSidebarNotif = findRebirthSidebarNotif(main)
	if rebirthSidebarNotif then
		rebirthSidebarNotif.Visible = false
		rebirthSidebarNotifInner = findNotifInnerLabel(rebirthSidebarNotif)
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	if remotes then
		getStateRF = remotes:WaitForChild("GetRebirthState", 30) :: RemoteFunction?
		performRF = remotes:WaitForChild("PerformRebirth", 30) :: RemoteFunction?
		updatedRE = remotes:WaitForChild("RebirthUpdated", 30) :: RemoteEvent?
		if not getStateRF then
			warn("[RebirthController] GetRebirthState remote missing")
		end
	else
		warn("[RebirthController] Remotes folder missing")
	end

	local buttons = rebirthFrame:FindFirstChild("Buttons")
	rebirthBtnHost = if buttons then buttons:FindFirstChild("Rebirth") :: GuiObject? else nil
	skipBtnHost = if buttons then buttons:FindFirstChild("Skip") :: GuiObject? else nil

	wireFrameButton(rebirthBtnHost, function()
		tryRebirth(main)
	end)
	wireFrameButton(skipBtnHost, function()
		trySkipPurchase()
	end)

	local skipInfo = skipBtnHost and skipBtnHost:FindFirstChild("Info")
	local priceLabel = skipInfo and skipInfo:FindFirstChild("Price")
	if priceLabel and priceLabel:IsA("TextLabel") then
		rememberPriceLabel(priceLabel)
	end
	local skipSubtitle = skipBtnHost and skipBtnHost:FindFirstChild("TextLabel")
	if skipSubtitle and skipSubtitle:IsA("TextLabel") then
		skipSubtitle.Text = SKIP_SUBTITLE_TEXT
	end
	refreshSkipPriceLabels()

	local header = rebirthFrame:FindFirstChild("Header")
	local headerButtons = header and header:FindFirstChild("Buttons")
	local closeHost = headerButtons and headerButtons:FindFirstChild("Close")
	if closeHost then
		local closeBtn: GuiButton? = if closeHost:IsA("GuiButton") then closeHost :: GuiButton
			else closeHost:FindFirstChildWhichIsA("GuiButton", true)
		if closeBtn then
			UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
				HUDController.closeCurrentFrame()
			end)
		else
			wireFrameButton(closeHost, function()
				HUDController.closeCurrentFrame()
			end)
		end
	end

	rebirthFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if rebirthFrame.Visible then
			hideSidebarBadge()
			fetchAndApply(main)
		elseif lastSnapshot and lastSnapshot.canRebirth then
			showSidebarBadge()
		end
	end)

	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		-- New plot: clear the cached sign state so the refresh applies to the new plot's signs.
		lastRebirthSignShow = nil
		if lastSnapshot then
			refreshPlotRebirthSign(lastSnapshot)
		end
	end)

	if updatedRE then
		updatedRE.OnClientEvent:Connect(function(snapshot)
			if typeof(snapshot) == "table" then
				applySnapshot(snapshot :: RebirthConfig.RebirthSnapshot, main)
			end
		end)
	end

	local indexRemotes = ReplicatedStorage:WaitForChild("IndexRemotes", 30)
	if indexRemotes then
		local indexUnlockedRE = indexRemotes:WaitForChild("IndexUnlocked", 30)
		if indexUnlockedRE and indexUnlockedRE:IsA("RemoteEvent") then
			indexUnlockedRE.OnClientEvent:Connect(function()
				fetchAndApply(main)
			end)
		end
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, wasPurchased: boolean)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if productId == RebirthConfig.SKIP_DEV_PRODUCT_ID then
			HUDController.closeFrameByName("Rebirth2")
			HUDController.closeFrameByName("Store")
		end
	end)

	fetchAndApply(main)
end

return RebirthController
