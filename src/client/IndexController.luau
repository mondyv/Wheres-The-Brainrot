-- [ACTIVE] IndexController
--[[
	Index UI — mutation tabs, catalog grid, golden quest, unlock toast.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local HUDController = require(script.Parent.HUDController)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local IndexConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("IndexConfig"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local OPEN_NOTIF = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_NOTIF = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_HOVER = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_CLICK = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_RESET = TweenInfo.new(0.2, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local QUEST_BAR_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ROW_HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local INDEX_BADGE_SWAY = TweenInfo.new(0.72, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_INNER_SWAY = TweenInfo.new(0.52, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_INNER_PULSE = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_SWAY_DEG = 5
local INDEX_BADGE_INNER_SWAY_DEG = 2.5

local LOCKED_NAME_COLOR = Color3.fromRGB(0, 0, 0)

local indexFrame: Frame? = nil
local headerTitle: TextLabel? = nil
local container: GuiObject? = nil
local rowTemplate: Frame? = nil
local questsFrame: Frame? = nil
local progressBar: Frame? = nil
local progressAmount: TextLabel? = nil
local indexNotif: GuiObject? = nil
local indexNotifLabel: TextLabel? = nil
local indexSidebarNotif: GuiObject? = nil
local indexSidebarNotifInner: TextLabel? = nil
local indexBadgeSwayTween: Tween? = nil
local indexBadgeInnerSwayTween: Tween? = nil
local indexBadgeInnerPulseTween: Tween? = nil
local tabNotifNodes: { [string]: GuiObject } = {}
local tabNotifSwayTweens: { [string]: Tween } = {}
local tabNotifInnerSwayTweens: { [string]: Tween } = {}
local tabNotifInnerPulseTweens: { [string]: Tween } = {}
local pendingTabNotifs: { [string]: boolean } = {}
local tooltipLabel: TextLabel? = nil
local tooltipGui: ScreenGui? = nil

local selectedMutation = "normal"
local catalogRows: { Frame } = {}
local getStateRF: RemoteFunction? = nil
local unlockedRE: RemoteEvent? = nil
local questBarTween: Tween? = nil
local rowHoverConns: { RBXScriptConnection } = {}
local selectMutation: (mutationId: string) -> ()
local stateCache: { [string]: any } = {}
local sortedCatalogCache: { [string]: { { name: string, rarity: string, baseIncome: number, icon: string } } } = {}
local _gridMutation: string? = nil
local rebuildToken = 0
local ROW_BATCH_SIZE = 14

local function getOrAddUIScale(obj: GuiObject): UIScale
	for _, ch in obj:GetChildren() do
		if ch:IsA("UIScale") and ch.Name ~= "PanelSlideScale" then
			return ch
		end
	end
	local s = Instance.new("UIScale")
	s.Name = "IndexUIScale"
	s.Scale = 1
	s.Parent = obj
	return s
end

local function waitMain(): ScreenGui?
	return PlayerGuiMain.ensure(player)
end

local function findLabel(root: Instance, names: { string }): TextLabel?
	for _, n in names do
		local inst = root:FindFirstChild(n, true)
		if inst and inst:IsA("TextLabel") then
			return inst
		end
	end
	return nil
end

local function findIndexSidebarNotif(main: ScreenGui): GuiObject?
	local sideUI = main:FindFirstChild("SideUI")
	if not sideUI then
		return nil
	end
	local lef1 = sideUI:FindFirstChild("Lef1") or sideUI:FindFirstChild("Left1")
	if not lef1 then
		return nil
	end
	local buttons = lef1:FindFirstChild("Buttons")
	local row2 = buttons and buttons:FindFirstChild("Row2")
	local indexBtn = row2 and row2:FindFirstChild("Index")
	local notif = indexBtn and indexBtn:FindFirstChild("Notif")
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
	return findLabel(notif, { "!", "Text", "TextLabel", "Label", "Icon" })
end

local function stopIndexBadgeSway()
	if indexBadgeSwayTween then
		indexBadgeSwayTween:Cancel()
		indexBadgeSwayTween = nil
	end
	if indexBadgeInnerSwayTween then
		indexBadgeInnerSwayTween:Cancel()
		indexBadgeInnerSwayTween = nil
	end
	if indexBadgeInnerPulseTween then
		indexBadgeInnerPulseTween:Cancel()
		indexBadgeInnerPulseTween = nil
	end
	if indexSidebarNotif then
		indexSidebarNotif.Rotation = 0
	end
	if indexSidebarNotifInner then
		indexSidebarNotifInner.Rotation = 0
		local innerScale = indexSidebarNotifInner:FindFirstChildOfClass("UIScale")
		if innerScale then
			innerScale.Scale = 1
		end
	end
end

local function startIndexBadgeSway()
	if not indexSidebarNotif then
		return
	end
	stopIndexBadgeSway()
	indexSidebarNotif.Rotation = -INDEX_BADGE_SWAY_DEG
	indexBadgeSwayTween = TweenService:Create(
		indexSidebarNotif,
		INDEX_BADGE_SWAY,
		{ Rotation = INDEX_BADGE_SWAY_DEG }
	)
	indexBadgeSwayTween:Play()

	if indexSidebarNotifInner then
		indexSidebarNotifInner.Rotation = INDEX_BADGE_INNER_SWAY_DEG
		indexBadgeInnerSwayTween = TweenService:Create(
			indexSidebarNotifInner,
			INDEX_BADGE_INNER_SWAY,
			{ Rotation = -INDEX_BADGE_INNER_SWAY_DEG }
		)
		indexBadgeInnerSwayTween:Play()

		local innerScale = getOrAddUIScale(indexSidebarNotifInner)
		innerScale.Scale = 0.985
		indexBadgeInnerPulseTween = TweenService:Create(innerScale, INDEX_BADGE_INNER_PULSE, { Scale = 1.015 })
		indexBadgeInnerPulseTween:Play()
	end
end

local function hideIndexSidebarBadge()
	stopIndexBadgeSway()
	if not indexSidebarNotif then
		return
	end
	indexSidebarNotif.Visible = false
	local scale = indexSidebarNotif:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 1
	end
end

local function stopTabNotifSway(mutationId: string)
	local sway = tabNotifSwayTweens[mutationId]
	if sway then
		sway:Cancel()
		tabNotifSwayTweens[mutationId] = nil
	end
	local innerSway = tabNotifInnerSwayTweens[mutationId]
	if innerSway then
		innerSway:Cancel()
		tabNotifInnerSwayTweens[mutationId] = nil
	end
	local innerPulse = tabNotifInnerPulseTweens[mutationId]
	if innerPulse then
		innerPulse:Cancel()
		tabNotifInnerPulseTweens[mutationId] = nil
	end
	local notif = tabNotifNodes[mutationId]
	if notif then
		notif.Rotation = 0
		local inner = findNotifInnerLabel(notif)
		if inner then
			inner.Rotation = 0
			local innerScale = inner:FindFirstChildOfClass("UIScale")
			if innerScale then
				innerScale.Scale = 1
			end
		end
	end
end

local function startTabNotifSway(mutationId: string)
	local notif = tabNotifNodes[mutationId]
	if not notif then
		return
	end
	stopTabNotifSway(mutationId)
	notif.Rotation = -INDEX_BADGE_SWAY_DEG
	tabNotifSwayTweens[mutationId] = TweenService:Create(notif, INDEX_BADGE_SWAY, { Rotation = INDEX_BADGE_SWAY_DEG })
	tabNotifSwayTweens[mutationId]:Play()

	local inner = findNotifInnerLabel(notif)
	if inner then
		inner.Rotation = INDEX_BADGE_INNER_SWAY_DEG
		tabNotifInnerSwayTweens[mutationId] = TweenService:Create(
			inner,
			INDEX_BADGE_INNER_SWAY,
			{ Rotation = -INDEX_BADGE_INNER_SWAY_DEG }
		)
		tabNotifInnerSwayTweens[mutationId]:Play()
		local innerScale = getOrAddUIScale(inner)
		innerScale.Scale = 1
		tabNotifInnerPulseTweens[mutationId] = TweenService:Create(innerScale, INDEX_BADGE_INNER_PULSE, { Scale = 1.08 })
		tabNotifInnerPulseTweens[mutationId]:Play()
	end
end

local function hideTabNotif(mutationId: string)
	stopTabNotifSway(mutationId)
	pendingTabNotifs[mutationId] = false
	local notif = tabNotifNodes[mutationId]
	if notif then
		notif.Visible = false
	end
end

local function showTabNotif(mutationId: string)
	local notif = tabNotifNodes[mutationId]
	if not notif then
		return
	end
	pendingTabNotifs[mutationId] = true
	notif.Visible = true
	startTabNotifSway(mutationId)
end

local function cacheTabNotifs()
	if not indexFrame then
		return
	end
	for mutationId, notifName in IndexConfig.TAB_NOTIF_NAME do
		local notif = indexFrame:FindFirstChild(notifName)
		if notif and notif:IsA("GuiObject") then
			tabNotifNodes[mutationId] = notif :: GuiObject
			notif.Visible = false
		end
	end
end

local function onIndexUnlock(mutationId: string)
	if not IndexConfig.TAB_NOTIF_NAME[mutationId] then
		return
	end
	local indexOpenOnTab = indexFrame and indexFrame.Visible and mutationId == selectedMutation
	if indexOpenOnTab then
		hideTabNotif(mutationId)
	else
		showTabNotif(mutationId)
	end
end

local function showIndexSidebarBadge()
	if not indexSidebarNotif then
		return
	end
	if indexSidebarNotif.Visible and indexBadgeSwayTween then
		return
	end
	local scale = getOrAddUIScale(indexSidebarNotif)
	indexSidebarNotif.Visible = true
	scale.Scale = 0.15
	TweenService:Create(scale, OPEN_NOTIF, { Scale = 1 }):Play()
	startIndexBadgeSway()
end

local function setGradientEnabled(root: Instance, enabled: boolean)
	if root:IsA("UIGradient") then
		root.Enabled = enabled
	end
	for _, d in root:GetDescendants() do
		if d:IsA("UIGradient") then
			d.Enabled = enabled
		end
	end
end

local function applyTabVisual(tabBtn: Instance, selected: boolean)
	local selectedGrad = tabBtn:FindFirstChild("Selected", true)
	local notSelectedGrad = tabBtn:FindFirstChild("NotSelected", true)

	if selectedGrad then
		if selectedGrad:IsA("UIGradient") then
			selectedGrad.Enabled = selected
		elseif selectedGrad:IsA("GuiObject") then
			(selectedGrad :: GuiObject).Visible = selected
			setGradientEnabled(selectedGrad, selected)
		else
			setGradientEnabled(selectedGrad, selected)
		end
	end

	if notSelectedGrad then
		if notSelectedGrad:IsA("UIGradient") then
			notSelectedGrad.Enabled = not selected
		elseif notSelectedGrad:IsA("GuiObject") then
			(notSelectedGrad :: GuiObject).Visible = not selected
			setGradientEnabled(notSelectedGrad, not selected)
		else
			setGradientEnabled(notSelectedGrad, not selected)
		end
	end
end

local function resolveTabButton(tabRoot: Instance): GuiButton?
	if tabRoot:IsA("GuiButton") then
		return tabRoot
	end
	local btn = tabRoot:FindFirstChildWhichIsA("GuiButton", true)
	if btn then
		return btn
	end
	return nil
end

local function resolveTabTiltTarget(tabRoot: Instance, btn: GuiButton): GuiObject
	local nameLbl = tabRoot:FindFirstChild("Name", true)
	if nameLbl and nameLbl:IsA("GuiObject") then
		return nameLbl :: GuiObject
	end
	local icon = btn:FindFirstChild("Icon", true)
	if icon and icon:IsA("GuiObject") then
		return icon :: GuiObject
	end
	return btn
end

local function wireTabInteractions(tabRoot: Instance, mutationId: string)
	local btn = resolveTabButton(tabRoot)
	if not btn then
		warn("[IndexController] no GuiButton under TypeButtons." .. tabRoot.Name)
		return
	end
	btn.Active = true
	pcall(function()
		(btn :: any).Interactable = true
	end)
	local tiltTarget = resolveTabTiltTarget(tabRoot, btn)
	-- Dedicated scale so PanelSlideScale on the tab root doesn't fight hover.
	local scale = btn:FindFirstChild("IndexTabHoverScale")
	if not (scale and scale:IsA("UIScale")) then
		scale = Instance.new("UIScale")
		scale.Name = "IndexTabHoverScale"
		scale.Scale = 1
		scale.Parent = btn
	end
	local hoverScale = scale :: UIScale

	local lastFire = 0
	local function fireSelect()
		local now = os.clock()
		if now - lastFire < 0.15 then
			return
		end
		lastFire = now
		UIInteractionSounds.playClick()
		TweenService:Create(hoverScale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		TweenService:Create(tiltTarget, TILT_CLICK, { Rotation = 2.5 }):Play()
		selectMutation(mutationId)
	end

	btn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -4 }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1 }):Play()
		TweenService:Create(tiltTarget, TILT_RESET, { Rotation = 0 }):Play()
	end)
	btn.Activated:Connect(fireSelect)
end

local function incomeForCatalog(entry: { name: string, rarity: string, baseIncome: number }, mutationId: string): number
	return BrainrotEconomy.incomePerSecond({
		name = entry.name,
		rarity = entry.rarity,
		mutation = mutationId,
		level = 1,
		baseIncome = entry.baseIncome,
	})
end

local function sortCatalog(
	catalog: { { name: string, rarity: string, baseIncome: number, icon: string? } },
	mutationId: string
)
	table.sort(catalog, function(a, b)
		local ia = incomeForCatalog(a, mutationId)
		local ib = incomeForCatalog(b, mutationId)
		if ia ~= ib then
			return ia < ib
		end
		local ra = IndexConfig.RARITY_SORT[a.rarity] or 99
		local rb = IndexConfig.RARITY_SORT[b.rarity] or 99
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
end

local function setBlackoutOnIcon(iconHost: Instance, locked: boolean)
	local blackout = iconHost:FindFirstChild("Blackout", true)
	if blackout then
		for _, d in blackout:GetDescendants() do
			if d:IsA("UIGradient") then
				d.Enabled = locked
			end
		end
		if blackout:IsA("UIGradient") then
			blackout.Enabled = locked
		end
	end
end

local function populateRow(
	row: Frame,
	entry: { name: string, rarity: string, baseIncome: number, icon: string },
	mutationId: string,
	unlocked: boolean,
	_animateRow: boolean?,
	_rowIndex: number?,
	_animStartedAt: number?
)
	local frame = row:FindFirstChild("Frame") or row
	local icon = frame:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") then
		if entry.icon ~= "" then
			icon.Image = entry.icon
		end
		setBlackoutOnIcon(icon, not unlocked)
	end

	local nameLabel = frame:FindFirstChild("Name", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		if unlocked then
			BrainrotHeaderStyle.setTextOnNode(nameLabel, entry.name)
			nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		else
			nameLabel.Text = "???"
			nameLabel.TextColor3 = LOCKED_NAME_COLOR
			BrainrotHeaderStyle.selectGradient(nameLabel, nil)
		end
	end

	local info = frame:FindFirstChild("Info", true)
	if info then
		local rarityNode = info:FindFirstChild("Rarity", true)
		if rarityNode then
			if unlocked then
				BrainrotHeaderStyle.applyRarityLabel(rarityNode, entry.rarity)
			else
				BrainrotHeaderStyle.setTextOnNode(rarityNode, "???")
				BrainrotHeaderStyle.selectGradient(rarityNode, nil)
			end
		end
		local typeNode = info:FindFirstChild("Type", true)
		if typeNode then
			if unlocked then
				BrainrotHeaderStyle.applyMutationLabel(typeNode, mutationId)
			else
				BrainrotHeaderStyle.setTextOnNode(typeNode, "???")
				BrainrotHeaderStyle.selectGradient(typeNode, nil)
			end
		end
	end

	local decor = frame:FindFirstChild("Decor", true)
	if decor then
		local strokeHost = decor:FindFirstChild("Highlight", true)
		if strokeHost then
			local rs = strokeHost:FindFirstChild("RarityStroke", true) or strokeHost
			BrainrotHeaderStyle.applyRarityStroke(rs, entry.rarity)
		end
	end

	local rowHost = if frame:IsA("GuiObject") then frame :: GuiObject else row
	local rowScale = getOrAddUIScale(rowHost)
	rowScale.Scale = 1

	if icon and icon:IsA("GuiObject") then
		table.insert(
			rowHoverConns,
			icon.MouseEnter:Connect(function()
				if not tooltipLabel then
					return
				end
				local rate = incomeForCatalog(entry, mutationId)
				tooltipLabel.Text = BrainrotEconomy.formatCashShort(rate) .. "/s"
				tooltipLabel.Visible = true
				TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1.03 }):Play()
			end)
		)
		table.insert(
			rowHoverConns,
			icon.MouseLeave:Connect(function()
				if tooltipLabel then
					tooltipLabel.Visible = false
				end
				TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1 }):Play()
			end)
		)
	end
end

local function refreshQuest(goldenCount: number, questComplete: boolean)
	if not questsFrame then
		return
	end
	local amount = progressAmount
		or findLabel(questsFrame, { "Amount", "Collected", "ProgressText", "TextLabel" })
	if amount then
		if questComplete then
			amount.Text = "Completed!"
		else
			amount.Text = string.format("%d/%d Collected", goldenCount, IndexConfig.GOLDEN_QUEST_TARGET)
		end
	end
	if progressBar then
		local show = goldenCount > 0 and not questComplete
		progressBar.Visible = show
		if show then
			local frac = math.clamp(goldenCount / IndexConfig.GOLDEN_QUEST_TARGET, 0, 1)
			local goal = UDim2.new(frac, 0, progressBar.Size.Y.Scale, progressBar.Size.Y.Offset)
			if questBarTween then
				questBarTween:Cancel()
			end
			questBarTween = TweenService:Create(progressBar, QUEST_BAR_TWEEN, { Size = goal })
			questBarTween:Play()
		end
	end
end

local function clearGrid()
	for _, conn in rowHoverConns do
		conn:Disconnect()
	end
	table.clear(rowHoverConns)
	-- Keep pooled rows; just hide them. Destroying hundreds of clones freezes the client.
	for _, row in catalogRows do
		if row.Parent then
			row.Visible = false
		end
	end
end

local function buildSortedCatalog(
	catalog: { any },
	mutationId: string
): { { name: string, rarity: string, baseIncome: number, icon: string } }
	local cached = sortedCatalogCache[mutationId]
	if cached then
		return cached
	end

	local list: { { name: string, rarity: string, baseIncome: number, icon: string } } = {}
	for _, e in catalog do
		if typeof(e) == "table" then
			table.insert(list, e)
		end
	end
	sortCatalog(list, mutationId)
	sortedCatalogCache[mutationId] = list
	return list
end

local function rebuildGrid(state: any, animateRows: boolean?)
	if not container or not rowTemplate then
		return
	end
	local catalog = state.catalog
	if typeof(catalog) ~= "table" then
		return
	end
	local unlocked = state.unlocked
	if typeof(unlocked) ~= "table" then
		unlocked = {}
	end

	rebuildToken += 1
	local token = rebuildToken
	clearGrid()
	_gridMutation = selectedMutation

	local list = buildSortedCatalog(catalog, selectedMutation)
	local order = 0
	local index = 1
	local BATCH = math.min(ROW_BATCH_SIZE, 10)

	local function spawnBatch()
		if token ~= rebuildToken or not container or not rowTemplate then
			return
		end
		local batchEnd = math.min(index + BATCH - 1, #list)
		for i = index, batchEnd do
			local entry = list[i]
			order += 1
			local row = catalogRows[i]
			if not row or not row.Parent then
				row = rowTemplate:Clone()
				row.Name = "Entry_" .. entry.name
				row.Parent = container
				catalogRows[i] = row
			else
				row.Name = "Entry_" .. entry.name
			end
			row.Visible = true
			row.LayoutOrder = order
			local key = IndexConfig.unlockKey(entry.name, selectedMutation)
			local isUnlocked = unlocked[key] == true
			populateRow(row, entry, selectedMutation, isUnlocked, false, i, nil)
		end
		index = batchEnd + 1
		if index <= #list then
			-- Real frame yield so tab switches don't hitch.
			task.wait()
			spawnBatch()
		else
			for i = #list + 1, #catalogRows do
				local extra = catalogRows[i]
				if extra then
					extra.Visible = false
				end
			end
			refreshQuest(
				if typeof(state.goldenCount) == "number" then math.floor(state.goldenCount) else 0,
				state.questComplete == true
			)
		end
	end

	task.spawn(spawnBatch)
end

local function fetchStateFor(mutationId: string): any?
	if not getStateRF then
		return nil
	end
	local ok, result = pcall(function()
		return getStateRF:InvokeServer(mutationId)
	end)
	if not ok then
		warn("[IndexController] GetIndexState failed:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		warn("[IndexController] GetIndexState returned non-table for", mutationId)
		return nil
	end
	return result
end

local function applyCachedState(mutationId: string, animateRows: boolean?)
	local cached = stateCache[mutationId]
	if cached then
		rebuildGrid(cached, animateRows)
	end
end

local function refreshStateInBackground(mutationId: string, animateRows: boolean?)
	task.spawn(function()
		-- Wait briefly if remotes aren't ready yet (open can race init).
		local deadline = os.clock() + 8
		while not getStateRF and os.clock() < deadline do
			task.wait(0.2)
		end
		local state = fetchStateFor(mutationId)
		if not state then
			return
		end
		stateCache[mutationId] = state
		if selectedMutation == mutationId and indexFrame and indexFrame.Visible then
			rebuildGrid(state, animateRows)
		end
	end)
end

local function loadMutationGrid(mutationId: string, animateRows: boolean)
	if stateCache[mutationId] then
		applyCachedState(mutationId, animateRows)
		refreshStateInBackground(mutationId, false)
	else
		clearGrid()
		_gridMutation = nil
		refreshStateInBackground(mutationId, animateRows)
	end
end

local function patchCachedUnlock(mutationId: string, name: string, payload: any)
	local cached = stateCache[mutationId]
	if not cached or typeof(cached.unlocked) ~= "table" then
		return
	end
	cached.unlocked[IndexConfig.unlockKey(name, mutationId)] = true
	if typeof(payload.goldenCount) == "number" then
		cached.goldenCount = math.floor(payload.goldenCount)
	end
	if payload.questComplete == true then
		cached.questComplete = true
	end
end

local function updateHeader()
	if headerTitle then
		local tabName = IndexConfig.TAB_DISPLAY_NAME[selectedMutation] or selectedMutation
		headerTitle.Text = "Index: " .. tabName
	end
end

selectMutation = function(mutationId: string)
	if not IndexConfig.TAB_DISPLAY_NAME[mutationId] then
		return
	end
	selectedMutation = mutationId
	hideTabNotif(mutationId)
	updateHeader()
	local typeButtons = indexFrame and indexFrame:FindFirstChild("TypeButtons")
	if typeButtons then
		for mutId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local btn = typeButtons:FindFirstChild(btnName)
			if btn then
				applyTabVisual(btn, mutId == selectedMutation)
			end
		end
	end
	loadMutationGrid(mutationId, false)
end

local function hideIndexNotif()
	if not indexNotif then
		return
	end
	local host = indexNotif:FindFirstChildWhichIsA("Frame") or indexNotif
	local scale = getOrAddUIScale(host :: GuiObject)
	local tween = TweenService:Create(scale, CLOSE_NOTIF, { Scale = 0.01 })
	tween.Completed:Once(function()
		indexNotif.Visible = false
	end)
	tween:Play()
end

local function showIndexNotif(name: string, mutationId: string)
	if not indexNotif or not indexNotifLabel then
		return
	end
	local typeName = IndexConfig.TAB_DISPLAY_NAME[mutationId] or mutationId
	indexNotifLabel.Text = string.format("%s %s Has been added to index!", typeName, name)
	indexNotifLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	BrainrotHeaderStyle.selectGradient(indexNotifLabel, BrainrotHeaderStyle.MUTATION_GRADIENT_NAME[mutationId])

	local host = indexNotif:FindFirstChildWhichIsA("Frame") or indexNotif
	local scale = getOrAddUIScale(host :: GuiObject)
	indexNotif.Visible = true
	scale.Scale = 0.01
	TweenService:Create(scale, OPEN_NOTIF, { Scale = 1 }):Play()
	UIInteractionSounds.playNotif()
	task.delay(3.2, hideIndexNotif)
end

local function ensureTooltip()
	if tooltipGui and tooltipGui.Parent then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "IndexIncomeTooltip"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 200
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui
	tooltipGui = sg

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Tip"
	lbl.BackgroundTransparency = 0.35
	lbl.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	lbl.TextColor3 = Color3.fromRGB(220, 255, 230)
	UiFonts.applyBodyLabel(lbl, 11, 7)
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.Visible = false
	lbl.Parent = sg
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = lbl
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = lbl
	tooltipLabel = lbl

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or not tooltipLabel.Visible then
			return
		end
		local pos = input.Position
		tooltipLabel.Position = UDim2.fromOffset(pos.X + 4, pos.Y + 4)
	end)
end

local IndexController = {}

function IndexController.init()
	local main = waitMain()
	if not main then
		warn("[IndexController] Main missing")
		return
	end

	local frames = main:WaitForChild("Frames", 30)
	indexFrame = if frames then frames:FindFirstChild("Index") :: Frame? else nil
	if not indexFrame then
		warn("[IndexController] Main.Frames.Index missing")
		return
	end

	headerTitle = findLabel(indexFrame, { "Title", "HeaderTitle", "Name" })
		or (indexFrame:FindFirstChild("Header") and findLabel(indexFrame.Header, { "Title", "Name" }))
	-- Prefer direct child so we don't grab a nested Decor/Container by mistake.
	local containerInst = indexFrame:FindFirstChild("Container")
	if not containerInst then
		containerInst = indexFrame:FindFirstChild("Container", true)
	end
	container = if containerInst and containerInst:IsA("ScrollingFrame")
		then containerInst
		elseif containerInst and containerInst:IsA("GuiObject")
		then containerInst:FindFirstChildWhichIsA("ScrollingFrame", true)
		else nil
	if not container and containerInst and containerInst:IsA("Frame") then
		container = containerInst :: any
	end
	if container then
		rowTemplate = container:FindFirstChild("1") :: Frame?
		if not rowTemplate then
			for _, ch in container:GetChildren() do
				if ch:IsA("Frame") and ch.Name ~= "UIListLayout" and ch.Name ~= "UIGridLayout" and ch.Name ~= "UIPadding" then
					rowTemplate = ch
					break
				end
			end
		end
		if rowTemplate then
			rowTemplate.Visible = false
		else
			warn("[IndexController] Index Container has no row template")
		end
	else
		warn("[IndexController] Index Container missing")
	end

	questsFrame = indexFrame:FindFirstChild("Quests", true) :: Frame?
	if questsFrame then
		local progress = questsFrame:FindFirstChild("Progress", true)
		if progress then
			progressBar = progress:FindFirstChild("Bar", true) :: Frame?
		end
		progressAmount = findLabel(questsFrame, { "Amount", "Collected", "ProgressText" })
	end

	local top = main:FindFirstChild("SideUI")
	if top then
		top = top:FindFirstChild("Top")
	end
	if top then
		indexNotif = top:FindFirstChild("IndexNotif") :: GuiObject?
		if indexNotif then
			indexNotif.Visible = false
			indexNotifLabel = findLabel(indexNotif, { "Text", "TextLabel", "Message", "Name" })
		end
	end

	indexSidebarNotif = findIndexSidebarNotif(main)
	if indexSidebarNotif then
		indexSidebarNotif.Visible = false
		indexSidebarNotifInner = findNotifInnerLabel(indexSidebarNotif)
	end

	cacheTabNotifs()

	ensureTooltip()

	local typeButtons = indexFrame:FindFirstChild("TypeButtons")
	if typeButtons then
		for mutationId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local tabRoot = typeButtons:FindFirstChild(btnName)
			if tabRoot then
				wireTabInteractions(tabRoot, mutationId)
				applyTabVisual(tabRoot, mutationId == selectedMutation)
			end
		end
	end

	local header = indexFrame:FindFirstChild("Header", true)
	local closeBtn = if header then header:FindFirstChild("Close", true) or header:FindFirstChild("X", true) else nil
	if closeBtn and closeBtn:IsA("GuiButton") then
		UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
			HUDController.closeCurrentFrame()
		end)
	end

	indexFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if indexFrame.Visible then
			hideIndexSidebarBadge()
			hideTabNotif(selectedMutation)
			-- Ensure tabs stay clickable after panel open.
			local typeButtons = indexFrame:FindFirstChild("TypeButtons")
			if typeButtons then
				for _, ch in typeButtons:GetChildren() do
					local slideScale = ch:FindFirstChild("PanelSlideScale")
					if slideScale and slideScale:IsA("UIScale") then
						slideScale.Scale = 1
					end
					local btn = resolveTabButton(ch)
					if btn then
						btn.Active = true
						pcall(function()
							(btn :: any).Interactable = true
						end)
					end
				end
			end
			if container then
				(container :: GuiObject).Active = true
				local contScale = container:FindFirstChild("PanelSlideScale")
				if contScale and contScale:IsA("UIScale") then
					contScale.Scale = 1
				end
			end
			loadMutationGrid(selectedMutation, false)
		else
			-- Keep cache; only hide rows so reopen can rebuild without refetch lag.
			clearGrid()
			_gridMutation = nil
			if tooltipLabel then
				tooltipLabel.Visible = false
			end
		end
	end)

	updateHeader()
	local typeButtonsInit = indexFrame:FindFirstChild("TypeButtons")
	if typeButtonsInit then
		for mutId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local btn = typeButtonsInit:FindFirstChild(btnName)
			if btn then
				applyTabVisual(btn, mutId == selectedMutation)
			end
		end
	end

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("IndexRemotes", 60)
		if remotes then
			local rf = remotes:WaitForChild("GetIndexState", 30)
			local re = remotes:WaitForChild("IndexUnlocked", 30)
			if rf and rf:IsA("RemoteFunction") then
				getStateRF = rf
				-- Warm normal tab cache so first open isn't empty; grid still only builds when visible.
				local bootState = fetchStateFor("normal")
				if bootState then
					stateCache.normal = bootState
				end
				if indexFrame and indexFrame.Visible then
					loadMutationGrid(selectedMutation, false)
				end
			end
			if re and re:IsA("RemoteEvent") then
				unlockedRE = re
				unlockedRE.OnClientEvent:Connect(function(payload)
					if typeof(payload) ~= "table" then
						return
					end
					local name = payload.name
					local mutation = payload.mutation
					if typeof(name) == "string" and typeof(mutation) == "string" then
						showIndexNotif(name, mutation)
						onIndexUnlock(mutation)
						patchCachedUnlock(mutation, name, payload)
						if not (indexFrame and indexFrame.Visible) then
							showIndexSidebarBadge()
						end
					end
					if indexFrame and indexFrame.Visible and typeof(mutation) == "string" then
						if mutation == selectedMutation then
							applyCachedState(mutation, false)
						end
						refreshStateInBackground(mutation, false)
					end
					refreshQuest(
						if typeof(payload.goldenCount) == "number" then math.floor(payload.goldenCount) else 0,
						payload.questComplete == true
					)
				end)
			end
		end
	end)
end

return IndexController
