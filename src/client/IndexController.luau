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
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local MobileHaptics = require(script.Parent.MobileHaptics)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local OPEN_NOTIF = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_NOTIF = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_HOVER = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_CLICK = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TILT_RESET = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUEST_BAR_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ROW_HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local INDEX_BADGE_SWAY = TweenInfo.new(0.72, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_INNER_SWAY = TweenInfo.new(0.52, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_INNER_PULSE = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
local INDEX_BADGE_SWAY_DEG = 2
local INDEX_BADGE_INNER_SWAY_DEG = 1

local LOCKED_NAME_COLOR = Color3.fromRGB(0, 0, 0)
local INDEX_PLACEHOLDER_IMAGE = "rbxasset://textures/ui/GuiImagePlaceholder.png"

local function usableIndexIcon(tex: string): boolean
	return tex ~= "" and tex ~= INDEX_PLACEHOLDER_IMAGE and tex ~= "rbxassetid://0"
end

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
local luckyBlockHeaderBtn: GuiButton? = nil

local selectedMutation = "normal"
local catalogRows: { Frame } = {}
local getStateRF: RemoteFunction? = nil
local collectRF: RemoteFunction? = nil
local collectAllRF: RemoteFunction? = nil
local unlockedRE: RemoteEvent? = nil
local questBarTween: Tween? = nil
local rowHoverConns: { RBXScriptConnection } = {}
local collectAllBtn: GuiButton? = nil
local collectAllHost: GuiObject? = nil
local collectedToast: GuiObject? = nil
local collectedAmountLabel: TextLabel? = nil
local collectedToastToken = 0
local collectedToastBasePos: UDim2? = nil
local pendingCollects = 0
local selectMutation: (mutationId: string) -> ()
local stateCache: { [string]: any } = {}
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

local function tabNameKey(name: string): string
	return string.lower((string.gsub(name, "[%s_%-]", "")))
end

local SELECTED_KEYS: { [string]: boolean } = {
	selected = true,
	on = true,
	active = true,
	sel = true,
	green = true,
	selectedbg = true,
	selectedbackground = true,
	onbg = true,
}

local UNSELECTED_KEYS: { [string]: boolean } = {
	notselected = true,
	unselected = true,
	deselected = true,
	off = true,
	idle = true,
	inactive = true,
	unsel = true,
	gray = true,
	grey = true,
	dim = true,
	unselectedbg = true,
	offbg = true,
}

local function classifyTabState(key: string): string?
	if key == "" then
		return nil
	end
	if UNSELECTED_KEYS[key]
		or string.find(key, "notselect", 1, true)
		or string.find(key, "unselect", 1, true)
	then
		return "off"
	end
	if SELECTED_KEYS[key] or string.find(key, "select", 1, true) or string.find(key, "green", 1, true) then
		return "on"
	end
	if string.find(key, "gray", 1, true) or string.find(key, "grey", 1, true) or string.find(key, "dim", 1, true) then
		return "off"
	end
	return nil
end

local function setChromeNode(node: Instance, on: boolean)
	if node:IsA("UIGradient") then
		node.Enabled = false
		if on then
			node.Enabled = true
		end
		return
	end
	if node:IsA("GuiObject") then
		local gui = node :: GuiObject
		gui.Visible = on
		if on then
			gui.ZIndex = math.max(gui.ZIndex, 4)
		end
		for _, d in node:GetDescendants() do
			if d:IsA("UIGradient") then
				d.Enabled = false
				if on then
					d.Enabled = true
				end
			end
		end
	end
end

local function isSelectedOverlayName(name: string): boolean
	return name == "Selected" or name == "Sellect"
end

local function collectSelectedOverlays(tabRoot: Instance): { GuiObject }
	local out: { GuiObject } = {}
	local seen: { [Instance]: boolean } = {}
	local function add(node: Instance?)
		if node and node:IsA("GuiObject") and isSelectedOverlayName(node.Name) and not seen[node] then
			seen[node] = true
			table.insert(out, node :: GuiObject)
		end
	end
	for _, child in tabRoot:GetChildren() do
		add(child)
	end
	for _, d in tabRoot:GetDescendants() do
		add(d)
	end
	return out
end

local function setSelectedOverlay(gui: GuiObject, on: boolean, _instant: boolean?)
	gui.Active = false
	pcall(function()
		(gui :: any).Interactable = false
	end)
	local extraScale = gui:FindFirstChild("IndexSelectedScale")
	if extraScale then
		extraScale:Destroy()
	end
	-- Restore any previously faded Studio image so Visible=true actually shows it.
	if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
		(gui :: ImageLabel).ImageTransparency = 0
	end
	gui.Visible = on
end

local function applyTabVisual(tabBtn: Instance, selected: boolean, instant: boolean?)
	for _, overlay in collectSelectedOverlays(tabBtn) do
		setSelectedOverlay(overlay, selected, instant)
	end
	local unsel = tabBtn:FindFirstChild("NotSelected", true)
	if unsel and unsel:IsA("GuiObject") and not isSelectedOverlayName(unsel.Name) then
		(unsel :: GuiObject).Visible = not selected
	end
end

local function findTypeButtons(): Instance?
	if not indexFrame then
		return nil
	end
	return indexFrame:FindFirstChild("TypeButtons") or indexFrame:FindFirstChild("TypeButtons", true)
end

local function isNotifTabName(instName: string): boolean
	return string.sub(string.lower(instName), 1, 5) == "notif"
end

local function isTabHostInstance(inst: Instance): boolean
	if isNotifTabName(inst.Name) then
		return false
	end
	if not inst:IsA("GuiObject") then
		return false
	end
	if
		inst:IsA("UIGradient")
		or inst:IsA("UIStroke")
		or inst:IsA("UICorner")
		or inst:IsA("UIPadding")
		or inst:IsA("UIListLayout")
		or inst:IsA("UIGridLayout")
		or inst:IsA("UIScale")
	then
		return false
	end
	return true
end

local function findTabRoot(typeButtons: Instance, btnName: string): Instance?
	local lower = string.lower(btnName)
	local aliases: { [string]: { string } } = {
		gold = { "gold", "golden" },
	}
	local names = aliases[lower] or { lower }

	local function nameMatches(instName: string): boolean
		local n = string.lower(instName)
		if isNotifTabName(n) then
			return false
		end
		for _, want in names do
			if n == want then
				return true
			end
		end
		return false
	end

	local direct = typeButtons:FindFirstChild(btnName)
	if direct and isTabHostInstance(direct) then
		return direct
	end
	for _, ch in typeButtons:GetChildren() do
		if nameMatches(ch.Name) and isTabHostInstance(ch) then
			return ch
		end
	end
	for _, holder in typeButtons:GetChildren() do
		if holder:IsA("GuiObject") and not nameMatches(holder.Name) and isTabHostInstance(holder) then
			local nested = holder:FindFirstChild(btnName)
			if nested and isTabHostInstance(nested) then
				return nested
			end
			for _, ch in holder:GetChildren() do
				if nameMatches(ch.Name) and isTabHostInstance(ch) then
					return ch
				end
			end
		end
	end
	-- Older Studio layouts nested the real tab under TypeButtons.
	for _, d in typeButtons:GetDescendants() do
		if isTabHostInstance(d) and nameMatches(d.Name) then
			return d
		end
	end
	return nil
end

local function syncTypeButtonSelectedOverlays(instant: boolean?)
	local typeButtons = findTypeButtons()
	if not typeButtons then
		return
	end
	for mutId, btnName in IndexConfig.TAB_BUTTON_NAME do
		local btn = findTabRoot(typeButtons, btnName)
		if btn then
			applyTabVisual(btn, mutId == selectedMutation, instant == true)
		end
	end
end

local function resolveTabButton(tabRoot: Instance): GuiButton?
	if tabRoot:IsA("GuiButton") and not isSelectedOverlayName(tabRoot.Name) then
		return tabRoot
	end
	local named = tabRoot:FindFirstChild("Button")
	if named and named:IsA("GuiButton") and not isSelectedOverlayName(named.Name) then
		return named
	end
	for _, d in tabRoot:GetDescendants() do
		if d:IsA("GuiButton") and not isSelectedOverlayName(d.Name) then
			return d
		end
	end
	return nil
end

local function resolveTabTiltTarget(_tabRoot: Instance, btn: GuiObject): GuiObject
	-- Tilt the tab chrome, not the Name label — label rotation reads as "sway".
	return btn
end

local function wireTabInteractions(tabRoot: Instance, mutationId: string)
	if not tabRoot:IsA("GuiObject") then
		return
	end
	local rootGui = tabRoot :: GuiObject
	rootGui.Active = true
	pcall(function()
		(rootGui :: any).Interactable = true
	end)
	for _, overlay in collectSelectedOverlays(tabRoot) do
		overlay.Active = false
		pcall(function()
			(overlay :: any).Interactable = false
		end)
	end

	local btn = resolveTabButton(tabRoot)
	if btn then
		btn.Active = true
		pcall(function()
			(btn :: any).Interactable = true
		end)
	end
	local tiltTarget = resolveTabTiltTarget(tabRoot, btn or rootGui)
	local scaleHost: GuiObject = if btn then btn else rootGui
	local scale = scaleHost:FindFirstChild("IndexTabHoverScale")
	if not (scale and scale:IsA("UIScale")) then
		scale = Instance.new("UIScale")
		scale.Name = "IndexTabHoverScale"
		scale.Scale = 1
		scale.Parent = scaleHost
	end
	local hoverScale = scale :: UIScale

	local lastFire = 0
	local function fireSelect()
		local now = os.clock()
		if now - lastFire < 0.2 then
			return
		end
		lastFire = now
		UIInteractionSounds.playClick()
		TweenService:Create(hoverScale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		TweenService:Create(tiltTarget, TILT_CLICK, { Rotation = 3 }):Play()
		selectMutation(mutationId)
		task.delay(0.08, function()
			if hoverScale.Parent then
				TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1.05 }):Play()
			end
			if tiltTarget.Parent then
				TweenService:Create(tiltTarget, TILT_RESET, { Rotation = 0 }):Play()
			end
		end)
	end

	local function onEnter()
		UIInteractionSounds.playHover()
		TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1.05 }):Play()
		TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -3 }):Play()
	end
	local function onLeave()
		TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1 }):Play()
		TweenService:Create(tiltTarget, TILT_RESET, { Rotation = 0 }):Play()
	end

	rootGui.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			fireSelect()
		end
	end)
	rootGui.MouseEnter:Connect(onEnter)
	rootGui.MouseLeave:Connect(onLeave)
	if btn and btn ~= rootGui then
		btn.Activated:Connect(fireSelect)
		btn.MouseEnter:Connect(onEnter)
		btn.MouseLeave:Connect(onLeave)
	elseif btn then
		btn.Activated:Connect(fireSelect)
	end
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
	catalog: { any },
	mutationId: string
)
	if mutationId == IndexConfig.LUCKY_BLOCK_TAB then
		table.sort(catalog, function(a, b)
			local ra = IndexConfig.RARITY_SORT[string.lower(tostring(a.rarity or ""))] or 99
			local rb = IndexConfig.RARITY_SORT[string.lower(tostring(b.rarity or ""))] or 99
			if ra ~= rb then
				return ra < rb
			end
			local ta = if typeof(a.tier) == "number" then a.tier else 99
			local tb = if typeof(b.tier) == "number" then b.tier else 99
			if ta ~= tb then
				return ta < tb
			end
			local na = if typeof(a.displayName) == "string" then a.displayName else a.name
			local nb = if typeof(b.displayName) == "string" then b.displayName else b.name
			return na < nb
		end)
		return
	end
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
	entry: any,
	mutationId: string,
	unlocked: boolean,
	_animateRow: boolean?,
	_rowIndex: number?,
	_animStartedAt: number?
)
	local isLucky = mutationId == IndexConfig.LUCKY_BLOCK_TAB or entry.kind == "luckyblock"
	local displayName = if typeof(entry.displayName) == "string" and entry.displayName ~= ""
		then entry.displayName
		elseif typeof(entry.name) == "string"
		then entry.name
		else "Lucky Block"

	local frame = row:FindFirstChild("Frame") or row
	local icon = frame:FindFirstChild("Icon", true)
	if icon and not (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		local inner = icon:FindFirstChildWhichIsA("ImageLabel") or icon:FindFirstChildWhichIsA("ImageButton")
		if inner then
			icon = inner
		end
	end
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		local tex = if typeof(entry.icon) == "string" then entry.icon else ""
		if not usableIndexIcon(tex) then
			tex = ""
			-- Never resolve lucky-block folders for brainrots — leftover / fuzzy
			-- matches put brainrot art on Lucky Block rows (and vice versa).
			if isLucky then
				tex = LuckyBlockCatalog.resolveIconAssetId(entry.name or displayName)
				if not usableIndexIcon(tex) then
					tex = LuckyBlockCatalog.resolveIconAssetId(displayName)
				end
			end
		end
		local img = icon :: ImageLabel
		-- Always assign: reused catalog rows keep the previous tab's Image otherwise.
		img.Image = if usableIndexIcon(tex) then tex else ""
		img.Visible = true
		img.ImageTransparency = 0
		setBlackoutOnIcon(icon, not unlocked)
	end

	local nameLabel = frame:FindFirstChild("Name", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		if unlocked then
			BrainrotHeaderStyle.setTextOnNode(nameLabel, displayName)
			nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			if typeof(entry.rarity) == "string" and entry.rarity ~= "" then
				BrainrotHeaderStyle.ensureRarityGradient(nameLabel, entry.rarity)
				BrainrotHeaderStyle.selectGradient(nameLabel, BrainrotHeaderStyle.rarityGradientNames(entry.rarity))
			end
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
				if isLucky then
					BrainrotHeaderStyle.applyRarityLabel(rarityNode, entry.rarity or "epic")
				else
					BrainrotHeaderStyle.applyRarityLabel(rarityNode, entry.rarity)
				end
			else
				BrainrotHeaderStyle.setTextOnNode(rarityNode, "???")
				BrainrotHeaderStyle.selectGradient(rarityNode, nil)
			end
		end
		local typeNode = info:FindFirstChild("Type", true)
		if typeNode then
			if unlocked then
				if isLucky then
					BrainrotHeaderStyle.setTextOnNode(typeNode, "Lucky Block")
					BrainrotHeaderStyle.selectGradient(typeNode, nil)
					if typeNode:IsA("GuiObject") then
						(typeNode :: GuiObject).Visible = true
					end
				else
					BrainrotHeaderStyle.applyMutationLabel(typeNode, mutationId)
				end
			else
				BrainrotHeaderStyle.setTextOnNode(typeNode, "???")
				BrainrotHeaderStyle.selectGradient(typeNode, nil)
			end
		end
	end

	local decor = frame:FindFirstChild("Decor", true)
	local rs: Instance? = nil
	if decor then
		local strokeHost = decor:FindFirstChild("Highlight", true)
		if strokeHost then
			rs = strokeHost:FindFirstChild("RarityStroke", true) or strokeHost
		end
	end
	if not rs then
		rs = frame:FindFirstChild("RarityStroke", true) or row:FindFirstChild("RarityStroke", true)
	end
	if rs and typeof(entry.rarity) == "string" and entry.rarity ~= "" then
		-- Locked entries still show rarity on the border (name/type stay ???).
		BrainrotHeaderStyle.applyRarityStroke(rs, entry.rarity)
		if rs:IsA("GuiObject") then
			(rs :: GuiObject).Visible = true
		end
		if rs:IsA("UIStroke") then
			rs.Enabled = true
		end
		local highlight = rs.Parent
		if highlight and highlight:IsA("GuiObject") then
			highlight.Visible = true
		end
	end

	local rowHost = if frame:IsA("GuiObject") then frame :: GuiObject else row
	local rowScale = getOrAddUIScale(rowHost)
	rowScale.Scale = 1

	row:SetAttribute("IndexName", entry.name)
	row:SetAttribute("IndexMutation", mutationId)
	row:SetAttribute("IndexRarity", if typeof(entry.rarity) == "string" then entry.rarity else "common")

	local collectHost = row:FindFirstChild("Collect")
	if collectHost and collectHost:IsA("GuiObject") then
		local pendingCollect = unlocked and row:GetAttribute("IndexCollected") ~= true
		collectHost.Visible = pendingCollect
		if pendingCollect then
			collectHost.Visible = true
			collectHost.ZIndex = math.max(collectHost.ZIndex, 6)
			local hostScale = getOrAddUIScale(collectHost)
			hostScale.Scale = 1
			local prize = collectHost:FindFirstChild("Prize")
			local xpLabel = prize and (prize:FindFirstChild("XpAmount") or prize:FindFirstChild("XpAmount", true))
			if xpLabel and (xpLabel:IsA("TextLabel") or xpLabel:IsA("TextButton")) then
				local xpAmt = IndexConfig.collectXpFor(entry.rarity, mutationId)
				xpLabel.Text = "+" .. tostring(xpAmt) .. " XP"
			end
		end
	end

	-- Hover the whole entry box (not only the icon).
	table.insert(
		rowHoverConns,
		rowHost.MouseEnter:Connect(function()
			if not tooltipLabel then
				return
			end
			if isLucky then
				local tip = if typeof(entry.dropsMultiline) == "string" and entry.dropsMultiline ~= ""
					then entry.dropsMultiline
					elseif typeof(entry.name) == "string"
					then LuckyBlockCatalog.formatDropsMultiline(entry.name)
					else "?"
				tooltipLabel.Text = tip
				tooltipLabel.TextColor3 = Color3.fromRGB(255, 245, 210)
			else
				local rate = incomeForCatalog(entry, mutationId)
				tooltipLabel.Text = BrainrotEconomy.formatCashShort(rate) .. "/s"
				tooltipLabel.TextColor3 = Color3.fromRGB(220, 255, 230)
			end
			tooltipLabel.Visible = true
			TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1.03 }):Play()
		end)
	)
	table.insert(
		rowHoverConns,
		rowHost.MouseLeave:Connect(function()
			if tooltipLabel then
				tooltipLabel.Visible = false
			end
			TweenService:Create(rowScale, ROW_HOVER_TWEEN, { Scale = 1 }):Play()
		end)
	)
end

local function hideCollectChrome(row: Frame)
	row:SetAttribute("IndexCollected", true)
	local collectHost = row:FindFirstChild("Collect")
	if collectHost and collectHost:IsA("GuiObject") then
		if not collectHost.Visible then
			return
		end
		local scale = getOrAddUIScale(collectHost)
		local tw = TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0.01,
		})
		tw:Play()
		tw.Completed:Once(function()
			collectHost.Visible = false
			scale.Scale = 1
		end)
	end
end

local function playCollectedXpToast(xp: number)
	if not collectedToast then
		return
	end
	local n = math.floor(xp)
	if n <= 0 then
		return
	end
	collectedToastToken += 1
	local token = collectedToastToken
	local toast = collectedToast
	if collectedAmountLabel then
		collectedAmountLabel.Text = "+" .. tostring(n) .. " XP"
	elseif toast:IsA("TextLabel") then
		(toast :: TextLabel).Text = "+" .. tostring(n) .. " XP"
	end
	if collectedToastBasePos == nil then
		collectedToastBasePos = toast.Position
	end
	local basePos = collectedToastBasePos :: UDim2
	toast.Visible = true
	toast.Position = basePos
	local scale = getOrAddUIScale(toast)
	scale.Scale = 0.4
	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	local fadeTargets: { GuiObject } = { toast }
	if collectedAmountLabel then
		table.insert(fadeTargets, collectedAmountLabel)
	end
	for _, node in fadeTargets do
		if node:IsA("TextLabel") or node:IsA("TextButton") then
			local lab = node :: TextLabel
			lab.TextTransparency = 0
		end
	end
	task.delay(1.05, function()
		if token ~= collectedToastToken or not toast.Parent then
			return
		end
		TweenService:Create(toast, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = basePos + UDim2.fromOffset(0, -42),
		}):Play()
		TweenService:Create(scale, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = 0.72,
		}):Play()
		for _, node in fadeTargets do
			if node:IsA("TextLabel") or node:IsA("TextButton") then
				TweenService:Create(node, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					TextTransparency = 1,
				}):Play()
			end
		end
		task.delay(0.42, function()
			if token ~= collectedToastToken then
				return
			end
			toast.Visible = false
			toast.Position = basePos
			scale.Scale = 1
			for _, node in fadeTargets do
				if node:IsA("TextLabel") or node:IsA("TextButton") then
					(node :: TextLabel).TextTransparency = 0
				end
			end
		end)
	end)
end

local function setPendingCollectCount(n: number)
	pendingCollects = math.max(0, math.floor(n))
	local show = pendingCollects > 0
	if collectAllHost then
		collectAllHost.Visible = show
		local parent = collectAllHost.Parent
		if parent and parent:IsA("GuiObject") and parent ~= indexFrame then
			local pn = string.lower(parent.Name)
			if string.find(pn, "collect", 1, true) then
				(parent :: GuiObject).Visible = show
			end
		end
	end
	if collectAllBtn then
		collectAllBtn.Visible = show
		collectAllBtn.Active = show
	end
end

local function countVisiblePendingCollects(): number
	local n = 0
	for _, row in catalogRows do
		if row.Parent and row.Visible then
			local collectHost = row:FindFirstChild("Collect")
			if collectHost and collectHost:IsA("GuiObject") and collectHost.Visible then
				n += 1
			end
		end
	end
	return n
end

local function markAllCachedCollected()
	for _, cached in stateCache do
		if typeof(cached) == "table" then
			if typeof(cached.collected) ~= "table" then
				cached.collected = {}
			end
			if typeof(cached.unlocked) == "table" then
				for key, on in cached.unlocked do
					if on then
						cached.collected[key] = true
					end
				end
			end
			cached.pendingCollectCount = 0
		end
	end
end

local function hideAllVisibleCollectChrome()
	for _, row in catalogRows do
		if row.Parent and row.Visible then
			hideCollectChrome(row)
		end
	end
end

local function wireCollectButton(row: Frame)
	local collectHost = row:FindFirstChild("Collect")
	if not collectHost then
		return
	end
	local btn = collectHost:FindFirstChild("CollectButton")
	if not (btn and btn:IsA("GuiButton")) then
		btn = collectHost:FindFirstChildWhichIsA("GuiButton", true)
	end
	if not btn or not btn:IsA("GuiButton") then
		return
	end
	if btn:GetAttribute("IndexCollectWired") == true then
		return
	end
	btn:SetAttribute("IndexCollectWired", true)
	btn.Active = true
	pcall(function()
		(btn :: any).Interactable = true
	end)
	UIButtonEffects.wireScaleButtonAnim(btn, function()
		if row:GetAttribute("IndexCollected") == true then
			return
		end
		if not collectRF then
			return
		end
		local name = row:GetAttribute("IndexName")
		local mutationId = row:GetAttribute("IndexMutation")
		if typeof(name) ~= "string" or typeof(mutationId) ~= "string" then
			return
		end
		local origin = btn.AbsolutePosition + btn.AbsoluteSize * 0.5
		local LevelController = require(script.Parent.LevelController)
		if typeof(LevelController.setNextXpOrigin) == "function" then
			LevelController.setNextXpOrigin(origin)
		end
		local ok, result = pcall(function()
			return collectRF:InvokeServer(name, mutationId)
		end)
		if not ok then
			warn("[IndexController] CollectIndexEntry failed:", result)
			LevelController.clearNextXpOrigin()
			return
		end
		if typeof(result) ~= "table" or result.ok ~= true then
			LevelController.clearNextXpOrigin()
			return
		end
		local cached = stateCache[mutationId]
		if cached then
			if typeof(cached.collected) ~= "table" then
				cached.collected = {}
			end
			cached.collected[IndexConfig.unlockKey(name, mutationId)] = true
		end
		hideCollectChrome(row)
		MobileHaptics.confirm()
		if typeof(result.xp) == "number" then
			playCollectedXpToast(result.xp)
		end
		setPendingCollectCount(countVisiblePendingCollects())
	end)
end

local function refreshQuest(goldenCount: number, questComplete: boolean)
	if not questsFrame then
		return
	end
	-- Golden quest stays visible on all Index tabs (including Lucky Blocks).
	questsFrame.Visible = true
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

local function buildSortedCatalog(catalog: { any }, mutationId: string): { any }
	local list: { any } = {}
	for _, e in catalog do
		if typeof(e) == "table" then
			table.insert(list, e)
		end
	end
	sortCatalog(list, mutationId)
	return list
end

local function gridHasVisibleRows(): boolean
	for _, row in catalogRows do
		if row.Parent and row.Visible then
			return true
		end
	end
	return false
end

local function indexRowStillHas3D(row: Instance): boolean
	return row:FindFirstChildWhichIsA("ViewportFrame", true) ~= nil
		or row:FindFirstChildWhichIsA("WorldModel", true) ~= nil
		or row:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function flattenIndexRow3D(row: Instance)
	if row:GetAttribute("IndexFlat") == true and not indexRowStillHas3D(row) then
		return
	end
	-- Viewport / WorldModel / leftover MeshParts. Do not destroy Model (can wrap the row button).
	local heavy: { Instance } = {}
	for _, d in row:GetDescendants() do
		if d:IsA("ViewportFrame") or d:IsA("WorldModel") or d:IsA("BasePart") then
			table.insert(heavy, d)
		end
	end
	for _, d in heavy do
		if d.Name == "Icon" and d:IsA("ViewportFrame") then
			local vf = d :: ViewportFrame
			local img = Instance.new("ImageLabel")
			img.Name = "Icon"
			img.BackgroundTransparency = 1
			img.BorderSizePixel = 0
			img.Size = vf.Size
			img.Position = vf.Position
			img.AnchorPoint = vf.AnchorPoint
			img.LayoutOrder = vf.LayoutOrder
			img.ZIndex = vf.ZIndex
			img.ScaleType = Enum.ScaleType.Fit
			local blackout = vf:FindFirstChild("Blackout")
			if blackout then
				blackout.Parent = img
			end
			img.Parent = vf.Parent
		end
		d:Destroy()
	end
	row:SetAttribute("IndexFlat", true)
end

local function anyBrainrotState(): any?
	local lucky = IndexConfig.LUCKY_BLOCK_TAB
	local preferred = stateCache[selectedMutation]
	if preferred and typeof(preferred.catalog) == "table" then
		return preferred
	end
	local normal = stateCache.normal
	if normal and typeof(normal.catalog) == "table" then
		return normal
	end
	for mutId, state in stateCache do
		if mutId ~= lucky and typeof(state) == "table" and typeof(state.catalog) == "table" then
			return state
		end
	end
	return nil
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
	_gridMutation = nil
	if container:IsA("GuiObject") then
		(container :: GuiObject).Visible = true
	end
	-- Don't use the server's global pending count — that includes other tabs.
	setPendingCollectCount(0)

	local list = buildSortedCatalog(catalog, selectedMutation)
	local order = 0
	local index = 1
	local BATCH = ROW_BATCH_SIZE

	local function spawnBatch()
		if token ~= rebuildToken or not container or not rowTemplate then
			return
		end
		local batchEnd = math.min(index + BATCH - 1, #list)
		for i = index, batchEnd do
			local entry = list[i]
			order += 1
			local row = catalogRows[i]
			if row and row.Parent then
				if row.Parent ~= container then
					row.Parent = container
				end
				if row:GetAttribute("IndexFlat") ~= true then
					flattenIndexRow3D(row)
				end
			else
				row = rowTemplate:Clone()
				flattenIndexRow3D(row)
				row.Name = "Entry_" .. entry.name
				row.Parent = container
				catalogRows[i] = row
			end
			row.Name = "Entry_" .. entry.name
			row.Visible = true
			row.LayoutOrder = order
			local key = IndexConfig.unlockKey(entry.name, selectedMutation)
			local isUnlocked = unlocked[key] == true
			local collectedMap = state.collected
			local isCollected = typeof(collectedMap) == "table" and collectedMap[key] == true
			row:SetAttribute("IndexCollected", isCollected)
			local popOk, popErr = pcall(populateRow, row, entry, selectedMutation, isUnlocked, false, i, nil)
			if not popOk then
				warn("[IndexController] populateRow failed:", entry.name, selectedMutation, popErr)
			end
			wireCollectButton(row)
		end
		index = batchEnd + 1
		if index <= #list then
			if #list > BATCH then
				task.wait(0.03)
			end
			spawnBatch()
		else
			for i = #list + 1, #catalogRows do
				local extra = catalogRows[i]
				if extra then
					extra.Visible = false
				end
			end
			_gridMutation = selectedMutation
			refreshQuest(
				if typeof(state.goldenCount) == "number" then math.floor(state.goldenCount) else 0,
				state.questComplete == true
			)
			setPendingCollectCount(countVisiblePendingCollects())
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
		if not indexFrame or not indexFrame.Visible then
			return
		end
		if mutationId == selectedMutation then
			rebuildGrid(state, animateRows)
		end
	end)
end

local function loadMutationGrid(mutationId: string, animateRows: boolean)
	if mutationId == IndexConfig.LUCKY_BLOCK_TAB then
		local cached = stateCache[mutationId]
		if cached then
			applyCachedState(mutationId, animateRows)
			refreshStateInBackground(mutationId, false)
			return
		end
		clearGrid()
		_gridMutation = nil
		refreshStateInBackground(mutationId, animateRows)
		return
	end

	local cached = stateCache[mutationId]
	if cached then
		applyCachedState(mutationId, animateRows)
		refreshStateInBackground(mutationId, false)
		return
	end
	local fallback = anyBrainrotState()
	if fallback then
		rebuildGrid(fallback, animateRows)
	else
		clearGrid()
		_gridMutation = nil
	end
	refreshStateInBackground(mutationId, animateRows)
end

local function patchCachedUnlock(mutationId: string, name: string, payload: any)
	local cached = stateCache[mutationId]
	if not cached or typeof(cached.unlocked) ~= "table" then
		return
	end
	local key = IndexConfig.unlockKey(name, mutationId)
	local already = cached.unlocked[key] == true
	cached.unlocked[key] = true
	if not already then
		if typeof(cached.collected) ~= "table" then
			cached.collected = {}
		end
	end
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

local LUCKY_BLOCK_SELECTED_TINT = Color3.fromRGB(255, 214, 64)
local LUCKY_BLOCK_IDLE_TINT = Color3.fromRGB(255, 255, 255)

local function applyLuckyBlockHeaderVisual(selected: boolean)
	if not luckyBlockHeaderBtn then
		return
	end
	applyTabVisual(luckyBlockHeaderBtn, selected)
	local scale = getOrAddUIScale(luckyBlockHeaderBtn)
	TweenService:Create(scale, HOVER_TWEEN, { Scale = if selected then 1.1 else 1 }):Play()
	for _, d in luckyBlockHeaderBtn:GetDescendants() do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local img = d :: ImageLabel
			if img:GetAttribute("LuckyIdleTint") == nil then
				img:SetAttribute("LuckyIdleTint", img.ImageColor3)
			end
			local idle = img:GetAttribute("LuckyIdleTint")
			local from = if typeof(idle) == "Color3" then idle else LUCKY_BLOCK_IDLE_TINT
			TweenService:Create(img, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				ImageColor3 = if selected then LUCKY_BLOCK_SELECTED_TINT else from,
			}):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Thickness = if selected then 2.4 else 1,
				Color = if selected then LUCKY_BLOCK_SELECTED_TINT else Color3.fromRGB(255, 255, 255),
			}):Play()
		end
	end
	if luckyBlockHeaderBtn:IsA("ImageButton") or luckyBlockHeaderBtn:IsA("ImageLabel") then
		local img = luckyBlockHeaderBtn :: ImageLabel
		TweenService:Create(img, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			ImageColor3 = if selected then LUCKY_BLOCK_SELECTED_TINT else LUCKY_BLOCK_IDLE_TINT,
		}):Play()
	end
end

selectMutation = function(mutationId: string)
	if not IndexConfig.TAB_DISPLAY_NAME[mutationId] then
		return
	end
	if selectedMutation == mutationId and _gridMutation == mutationId and gridHasVisibleRows() then
		hideTabNotif(mutationId)
		syncTypeButtonSelectedOverlays(false)
		applyLuckyBlockHeaderVisual(mutationId == IndexConfig.LUCKY_BLOCK_TAB)
		return
	end
	selectedMutation = mutationId
	hideTabNotif(mutationId)
	updateHeader()
	syncTypeButtonSelectedOverlays(false)
	applyLuckyBlockHeaderVisual(mutationId == IndexConfig.LUCKY_BLOCK_TAB)
	if tooltipLabel then
		tooltipLabel.Visible = false
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
	if mutationId == IndexConfig.LUCKY_BLOCK_TAB then
		indexNotifLabel.Text = string.format("%s has been added to index!", name)
	else
		indexNotifLabel.Text = string.format("%s %s Has been added to index!", typeName, name)
	end
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
	lbl.BackgroundTransparency = 0.28
	lbl.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	lbl.TextColor3 = Color3.fromRGB(220, 255, 230)
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.TextWrapped = false
	lbl.RichText = false
	UiFonts.applyBodyLabel(lbl, 12, 8)
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.Visible = false
	lbl.ZIndex = 50
	lbl.Parent = sg
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = lbl
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = lbl
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.2
	stroke.Color = Color3.fromRGB(255, 210, 90)
	stroke.Transparency = 0.35
	stroke.Parent = lbl
	tooltipLabel = lbl

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or not tooltipLabel.Visible then
			return
		end
		local pos = input.Position
		tooltipLabel.Position = UDim2.fromOffset(pos.X + 14, pos.Y + 14)
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

	headerTitle = nil
	local headerInst = indexFrame:FindFirstChild("Header")
	if headerInst then
		headerTitle = findLabel(headerInst, { "Title", "HeaderTitle", "Name" })
	end
	-- Prefer direct child so we don't grab a nested Decor/Container by mistake.
	-- After PanelSlideIn wraps scrolls, Container may be a CanvasGroup clip host.
	local PanelSlideIn = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PanelSlideIn"))
	local containerInst = indexFrame:FindFirstChild("Container")
	if not containerInst then
		containerInst = indexFrame:FindFirstChild("Container", true)
	end
	if containerInst then
		containerInst = PanelSlideIn.unwrapScrollHost(containerInst) or containerInst
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
		for _, ch in container:GetChildren() do
			if ch:IsA("GuiObject") then
				flattenIndexRow3D(ch)
			end
		end
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
			if
				rowTemplate:FindFirstChild("TypeButtons", true)
				or rowTemplate:FindFirstChild("CollectAllButton", true)
				or rowTemplate:FindFirstChild("Quests", true)
			then
				warn("[IndexController] Index row template looks like the whole panel — refusing to clone it")
				rowTemplate = nil
			else
				flattenIndexRow3D(rowTemplate)
				rowTemplate.Visible = false
				local collectOnTemplate = rowTemplate:FindFirstChild("Collect")
				if collectOnTemplate and collectOnTemplate:IsA("GuiObject") then
					collectOnTemplate.Visible = false
				end
			end
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

	local collectedRoot = indexFrame:FindFirstChild("Collected")
	if collectedRoot and collectedRoot:IsA("GuiObject") then
		collectedToast = collectedRoot
		collectedToast.Visible = false
		collectedAmountLabel = findLabel(collectedRoot, {
			"CollectedAmmount",
			"CollectedAmount",
			"Amount",
			"Text",
		})
	end

	local collectAllNode = indexFrame:FindFirstChild("CollectAllButton")
		or indexFrame:FindFirstChild("CollectAllButton", true)
	if collectAllNode and collectAllNode:IsA("GuiObject") then
		collectAllHost = collectAllNode :: GuiObject
		collectAllHost.Visible = false
		local collectParent = collectAllHost.Parent
		if collectParent and collectParent:IsA("GuiObject") and collectParent ~= indexFrame then
			local pn = string.lower(collectParent.Name)
			if string.find(pn, "collect", 1, true) then
				(collectParent :: GuiObject).Visible = false
			end
		end
		local btn = if collectAllNode:IsA("GuiButton")
			then collectAllNode
			else collectAllNode:FindFirstChildWhichIsA("GuiButton", true)
		if btn and btn:IsA("GuiButton") then
			collectAllBtn = btn
			btn.Active = false
			pcall(function()
				(btn :: any).Interactable = true
			end)
			btn.Visible = false
			setPendingCollectCount(0)
			local collectAllBusy = false
			UIButtonEffects.wireScaleButtonAnim(btn, function()
				if collectAllBusy or pendingCollects <= 0 or not collectAllRF then
					return
				end
				collectAllBusy = true
				local origin = btn.AbsolutePosition + btn.AbsoluteSize * 0.5
				local LevelController = require(script.Parent.LevelController)
				if typeof(LevelController.setNextXpOrigin) == "function" then
					LevelController.setNextXpOrigin(origin)
				end
				local ok, result = pcall(function()
					return collectAllRF:InvokeServer()
				end)
				collectAllBusy = false
				if not ok then
					warn("[IndexController] CollectAllIndexEntries failed:", result)
					if typeof(LevelController.clearNextXpOrigin) == "function" then
						LevelController.clearNextXpOrigin()
					end
					return
				end
				if typeof(result) ~= "table" or result.ok ~= true then
					if typeof(LevelController.clearNextXpOrigin) == "function" then
						LevelController.clearNextXpOrigin()
					end
					setPendingCollectCount(countVisiblePendingCollects())
					return
				end
				markAllCachedCollected()
				hideAllVisibleCollectChrome()
				if typeof(result.xp) == "number" then
					playCollectedXpToast(result.xp)
				end
				setPendingCollectCount(0)
			end)
		else
			warn("[IndexController] CollectAllButton has no GuiButton")
		end
	else
		warn("[IndexController] CollectAllButton missing")
	end

	local typeButtons = findTypeButtons()
	if typeButtons then
		local wiredRoots: { [Instance]: boolean } = {}
		for mutationId, btnName in IndexConfig.TAB_BUTTON_NAME do
			local tabRoot = findTabRoot(typeButtons, btnName)
			if tabRoot and not wiredRoots[tabRoot] then
				wireTabInteractions(tabRoot, mutationId)
				wiredRoots[tabRoot] = true
			end
		end
		syncTypeButtonSelectedOverlays(true)
	end

	local header = indexFrame:FindFirstChild("Header") or indexFrame:FindFirstChild("Header", true)
	if header then
		local luckyIcon = header:FindFirstChild(IndexConfig.HEADER_LUCKY_BLOCK_ICON)
			or header:FindFirstChild(IndexConfig.HEADER_LUCKY_BLOCK_ICON, true)
		if luckyIcon then
			local btn = resolveTabButton(luckyIcon)
			if btn then
				luckyBlockHeaderBtn = btn
				btn.Active = true
				pcall(function()
					(btn :: any).Interactable = true
				end)
				local hoverScale = getOrAddUIScale(btn)
				btn.MouseButton1Down:Connect(function()
					UIInteractionSounds.playClick()
					TweenService:Create(hoverScale, CLICK_TWEEN, { Scale = 0.94 }):Play()
					selectMutation(IndexConfig.LUCKY_BLOCK_TAB)
				end)
				btn.MouseButton1Click:Connect(function()
					selectMutation(IndexConfig.LUCKY_BLOCK_TAB)
				end)
				btn.MouseEnter:Connect(function()
					if selectedMutation ~= IndexConfig.LUCKY_BLOCK_TAB then
						TweenService:Create(hoverScale, HOVER_TWEEN, { Scale = 1.06 }):Play()
					end
				end)
				btn.MouseLeave:Connect(function()
					TweenService:Create(hoverScale, HOVER_TWEEN, {
						Scale = if selectedMutation == IndexConfig.LUCKY_BLOCK_TAB then 1.08 else 1,
					}):Play()
				end)
				applyLuckyBlockHeaderVisual(false)
			else
				warn("[IndexController] Lucky Block Icon has no GuiButton")
			end
		else
			warn("[IndexController] Header missing Lucky Block Icon")
		end
	end

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
			syncTypeButtonSelectedOverlays(true)
			task.delay(0.45, function()
				if indexFrame and indexFrame.Visible then
					syncTypeButtonSelectedOverlays(true)
				end
			end)
			-- Ensure tabs stay clickable after panel open.
			local typeButtons = findTypeButtons()
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
	syncTypeButtonSelectedOverlays(true)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("IndexRemotes", 60)
		if remotes then
			local rf = remotes:WaitForChild("GetIndexState", 30)
			local collectFn = remotes:WaitForChild("CollectIndexEntry", 30)
			local collectAllFn = remotes:WaitForChild("CollectAllIndexEntries", 30)
			local re = remotes:WaitForChild("IndexUnlocked", 30)
			if collectFn and collectFn:IsA("RemoteFunction") then
				collectRF = collectFn
			end
			if collectAllFn and collectAllFn:IsA("RemoteFunction") then
				collectAllRF = collectAllFn
			end
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
					local unlockName = if typeof(payload.unlockName) == "string" then payload.unlockName else name
					if typeof(name) == "string" and typeof(mutation) == "string" then
						showIndexNotif(name, mutation)
						onIndexUnlock(mutation)
						if typeof(unlockName) == "string" then
							patchCachedUnlock(mutation, unlockName, payload)
						end
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
					if mutation ~= IndexConfig.LUCKY_BLOCK_TAB then
						refreshQuest(
							if typeof(payload.goldenCount) == "number" then math.floor(payload.goldenCount) else 0,
							payload.questComplete == true
						)
					end
				end)
			end
		end
	end)
end

return IndexController
