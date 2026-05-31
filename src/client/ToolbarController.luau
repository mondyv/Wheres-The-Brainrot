--[[
	ToolbarController
	Replaces the default Roblox backpack/hotbar with the custom Toolbar frame.

	Expected SideUI hierarchy:
	  SideUI
	  └── Toolbar
	      ├── Hotbar
	      │   └── 1 .. 9   (slot frames with nested Button)
	      ├── ToggleBackpack
	      ├── ToggleBackpackImage  (icon toggle; lives in Hotbar row after visible slots)
	  └── Backpack  (optional expanded view)

	Studio layout: anchor Hotbar + Backpack at X=0.5 under Toolbar once at init. ToggleBackpackImage hides while the inventory panel is open (close via X).
	Hotbar slots may use nested `Button` (e.g. Hotbar["1"].Button.Icon).
	Brainrot pickups: tuck/untuck via drag; ghost drag; search; backpack frame outline + open/close tweens.
	Backpack UI rows 1..19 show stashed items in dense order (tucked hotbar slots + list indices >9); row labels use server list index.

	Toolbar UI access: spawn safe zone (SafeZoneHitbox / Reddie / Raddie) and RedWall deposit area.
--]]

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local CarryGate = require(script.Parent.CarryGate)
local DropTargets = require(script.Parent.ToolbarDropTargets)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local player    = Players.LocalPlayer

local defaultBackpackGuardConn: RBXScriptConnection? = nil

local function disableDefaultRobloxBackpack()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
end

local function ensureDefaultRobloxBackpackStaysOff()
	disableDefaultRobloxBackpack()
	if defaultBackpackGuardConn then
		return
	end
	defaultBackpackGuardConn = RunService.Heartbeat:Connect(function()
		pcall(function()
			if StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack) then
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end
		end)
	end)
end

local playerGui = player:WaitForChild("PlayerGui")
local mainGui   = PlayerGuiMain.ensure(player)
local sideUI    = mainGui:WaitForChild("SideUI")
local toolbar   = sideUI:WaitForChild("Toolbar")
local hotbar    = toolbar:WaitForChild("Hotbar")

local function applyToolbarInitialHiddenState()
	toolbar.Visible = false
	local backpack = toolbar:FindFirstChild("Backpack")
	if backpack and backpack:IsA("GuiObject") then
		(backpack :: GuiObject).Visible = false
	end
	for i = 1, 9 do
		local slot = hotbar:FindFirstChild(tostring(i))
		if slot and slot:IsA("GuiObject") then
			(slot :: GuiObject).Visible = false
		end
	end
	local icon = toolbar:FindFirstChild("ToggleBackpackImage") or hotbar:FindFirstChild("ToggleBackpackImage")
	if icon and icon:IsA("GuiObject") then
		(icon :: GuiObject).Visible = false
	end
end

applyToolbarInitialHiddenState()

-- ── Tween configs ─────────────────────────────────────────────────────────────

local SHOW_TWEEN      = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN      = TweenInfo.new(0.2,  Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIGHLIGHT_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EQUIP_POP_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BACKPACK_OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local BACKPACK_CLOSE_TWEEN = TweenInfo.new(0.26, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local DRAG_GHOST_SMOOTH = 0.55 -- per-frame lerp toward cursor (higher = snappier follow)
local TOGGLE_BACKPACK_ICON_MIN_ABS_PX = 28
local TOGGLE_BACKPACK_ICON_SIZE_SCALE = 0.68

-- ── Key → slot index map ──────────────────────────────────────────────────────

local KEY_TO_SLOT: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One]   = 1,
	[Enum.KeyCode.Two]   = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four]  = 4,
	[Enum.KeyCode.Five]  = 5,
	[Enum.KeyCode.Six]   = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine]  = 9,
}

-- ── State ─────────────────────────────────────────────────────────────────────

local slots: { GuiObject }   = {}    -- ordered slot frames (index 1-9)
local slotTools: { Tool? }   = {}    -- tool assigned to each slot
local extraToolSlotByIndex: { [number]: Tool } = {} -- non-brainrot hotbar tools (e.g. lucky block)
local activeSlot: number?    = nil
local uiHotbarHighlight: number? = nil -- nil = no slot ring (toggle off); otherwise mirrors selection / equip
local toolbarShown: boolean  = false
local canUseToolbar: boolean = false
local safezonePollAccum = 0.0
local SAFEZONE_POLL_INTERVAL = 0.12
local SAFEZONE_EXIT_POLLS_REQUIRED = 3
local safezoneOutStreak = 0
local toolbarVisibilityTween: Tween? = nil
local SAFEZONE_AUTO_EQUIP_DEBOUNCE = 0.4
local lastSafezoneAutoEquipAttempt = 0.0
local pendingAutoEquipSlot: number? = nil
local pendingReturnedBrainrotName: string? = nil

local MAX_BACKPACK_BRAINROT_SLOTS = 19
local HOTBAR_INVENTORY_SLOTS = 9
-- Fallback if server omits fields (older payloads).
local DEFAULT_BRAINROT_CAPACITY = 100
local brainrotInventoryUsed: number = 0
local brainrotInventoryMax: number = DEFAULT_BRAINROT_CAPACITY
local brainrotEntries: { { name: string, icon: string, sourcePath: string, rarity: string?, mutation: string?, level: number?, baseIncome: number? } } = {}
local backpackContainer: Instance? = nil
local backpackGuiFrame: GuiObject? = nil
local backpackHeaderLabel: Instance? = nil
local backpackEquipWired = false
local equipBestWired = false

local brainrotParkedInUI: { [number]: boolean } = {}
-- UI backpack rows 1..MAX map through this → server list index (tucked + slot >9) so stashed pets fill consecutive rows.
local backpackDisplayOrder: { number } = {}
local pendingToolbarDrag: {
	kind: string,
	idx: number,
	start: Vector2,
	texture: string?,
	rowButton: GuiButton?,
	equippedOnDown: boolean?,
	isExtraTool: boolean?,
}? = nil
-- Drag started inside the safe zone; finish drop even if zone poll flickers before mouse up.
local activeToolbarDrag = false
local dragSuppressedToolbarClick = false
local DRAG_THRESHOLD_PX = 14
local DRAG_GHOST_THRESHOLD_PX = 6
-- Shared scale for "whole hotbar" hover while dragging toward slots (slightly subtler than per-slot hover).
local HOTBAR_BULK_DRAG_HOVER_SCALE = 1.06
local TOGGLE_BACKPACK_ICON_TINT = Color3.fromRGB(255, 255, 255)

local backpackSearchText: string = ""

local dragGhostGui: ScreenGui? = nil
local dragGhostImage: ImageLabel? = nil
local dragGhostSmoothPos: Vector2? = nil
local dragGhostConn: RBXScriptConnection? = nil

local backpackFrameRef: GuiObject? = nil
local toggleBackpackRef: GuiObject? = nil
local toggleBackpackIconRef: GuiObject? = nil
local refreshToggleBackpackIconLayout: () -> ()
local refreshSlotVisual: (number) -> ()
local updateHotbarSlotVisibility: () -> ()
local refreshBrainrotBackpackUI: () -> ()
local showToolbar: () -> ()
local hideToolbar: () -> ()
local refreshToolbarVisibility: () -> ()
local backpackSearchWired = false
local backpackCloseWired = false
local isBackpackPanelOpen = false
local backpackPanelScaleTween: Tween? = nil
local backpackPanelFadeTween: Tween? = nil
local backpackContainerScaleTween: Tween? = nil
local backpackFadeRoot: CanvasGroup? = nil

-- While dragging toward the hotbar (from backpack, or from hotbar back over the bar), all slots share one hover scale.
local hotbarDragBulkHover = false
local backpackDragHover = false
local BACKPACK_FRAME_DRAG_HOVER_SCALE = 1.045
local BACKPACK_ROW_DRAG_HOVER_SCALE = 1.06

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then return s end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid") :: Humanoid? or nil
end

local function getBackpack(): Folder?
	return player:FindFirstChildOfClass("Backpack") :: Folder?
end

local function isExtraHotbarTool(tool: Tool): boolean
	if tool:GetAttribute("BrainrotTool") == true then
		local invIdx = tool:GetAttribute("BrainrotInvIndex")
		return typeof(invIdx) ~= "number"
	end
	return true
end

local function collectExtraHotbarTools(): { Tool }
	local seen: { [Tool]: boolean } = {}
	local out: { Tool } = {}
	local function addFrom(root: Instance?)
		if not root then
			return
		end
		for _, item in root:GetChildren() do
			if item:IsA("Tool") and isExtraHotbarTool(item :: Tool) and not seen[item :: Tool] then
				seen[item :: Tool] = true
				table.insert(out, item :: Tool)
			end
		end
	end
	addFrom(getBackpack())
	addFrom(player.Character)
	return out
end

local function slotIconTargets(surface: GuiObject): { ImageLabel }
	local out: { ImageLabel } = {}
	local seen: { [ImageLabel]: boolean } = {}
	local function push(node: Instance?)
		if node and node:IsA("ImageLabel") and not seen[node :: ImageLabel] then
			seen[node :: ImageLabel] = true
			table.insert(out, node :: ImageLabel)
		end
	end
	push(surface:FindFirstChild("Icon"))
	for _, d in surface:GetDescendants() do
		if d:IsA("ImageLabel") and d.Name == "Icon" then
			push(d)
		end
	end
	if #out == 0 then
		for _, d in surface:GetDescendants() do
			if d:IsA("ImageLabel") then
				push(d)
				break
			end
		end
	end
	return out
end

local function applySlotIconStyle(icon: ImageLabel)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.BackgroundTransparency = 1
end

local function setSlotIcons(surface: GuiObject, image: string, visible: boolean)
	for _, icon in slotIconTargets(surface) do
		applySlotIconStyle(icon)
		icon.Image = image
		icon.Visible = visible
	end
end

local function hotbarSlotDragTexture(index: number): string?
	if brainrotEntries[index] and not brainrotParkedInUI[index] then
		local e = brainrotEntries[index] :: { icon: string }
		return (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
	end
	local tool = slotTools[index]
	if tool then
		local tex = (tool :: any).TextureId
		if typeof(tex) == "string" and tex ~= "" then
			return tex
		end
	end
	return nil
end

-- Defined after hotbarSlotScaleHost (see below).
local playEquipSlotAnimation: (number) -> ()

local function findBrainrotToolAtInvIndex(root: Instance?, invIndex: number): Tool?
	if not root then
		return nil
	end
	for _, c in root:GetChildren() do
		if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
			c.ManualActivationOnly = true
			local a = c:GetAttribute("BrainrotInvIndex")
			if typeof(a) == "number" and math.floor(a) == invIndex then
				return c
			end
		end
	end
	return nil
end

-- Hotbar / backpack rows often wrap controls in `Button`.
local function slotPrimaryButton(slot: GuiObject): GuiButton?
	local b = slot:FindFirstChild("Button")
	if b and b:IsA("GuiButton") then
		return b
	end
	if slot:IsA("GuiButton") then
		return slot
	end
	return slot:FindFirstChildWhichIsA("GuiButton", true)
end

local function resolveBackpackActionButton(root: GuiObject): GuiButton?
	if root:IsA("GuiButton") then
		return root
	end
	return slotPrimaryButton(root)
end

local function disableGuiInputCapture(gui: GuiObject)
	gui.Active = false
	if gui:IsA("GuiButton") then
		gui.Selectable = false
	end
end

local function enableGuiButtonInput(btn: GuiButton)
	btn.Active = true
	btn.Selectable = true
end

-- Studio templates sometimes use a plain Frame named `Button`; resolve a real GuiButton for touch input.
local function resolveHotbarSlotButton(slot: GuiObject): GuiButton?
	local named = slot:FindFirstChild("Button")
	if named then
		if named:IsA("GuiButton") then
			return named
		end
		if named:IsA("GuiObject") then
			disableGuiInputCapture(named :: GuiObject)
		end
		local nested = named:FindFirstChildWhichIsA("GuiButton", true)
		if nested then
			return nested
		end
	end
	return slotPrimaryButton(slot)
end

-- Icon / Rate / Key steal mouse hits unless they are non-interactive.
local function passthroughChildClicks(root: GuiObject)
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d ~= root then
			d.Active = false
		end
	end
end

-- Parent slot frames and overlay siblings steal mobile taps unless they are explicitly non-interactive.
local function configureHotbarSlotInput(slot: GuiObject, btn: GuiButton)
	disableGuiInputCapture(slot)
	for _, d in slot:GetDescendants() do
		if d:IsA("GuiObject") and d ~= btn and not d:IsDescendantOf(btn) then
			disableGuiInputCapture(d)
		end
	end
	local topZ = btn.ZIndex
	for _, ch in slot:GetChildren() do
		if ch:IsA("GuiObject") and ch ~= btn then
			topZ = math.max(topZ, (ch :: GuiObject).ZIndex)
		end
	end
	btn.ZIndex = topZ + 1
	passthroughChildClicks(btn)
	enableGuiButtonInput(btn)
end

local function ensureHotbarLayoutPassthrough()
	disableGuiInputCapture(hotbar)
end

local function toolSlotSurface(slot: GuiObject): GuiObject
	local b = slotPrimaryButton(slot)
	return (b and (b :: GuiObject)) or slot
end

-- UIScale target: slot button (not the whole frame) so hover doesn't resize the hotbar row.
local function hotbarSlotScaleHost(slot: GuiObject): Instance
	local btn = slotPrimaryButton(slot)
	if btn then
		return btn :: Instance
	end
	return slot
end

playEquipSlotAnimation = function(index: number)
	local slot = slots[index]
	if not slot then
		return
	end
	local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
	sc.Scale = 0.86
	TweenService:Create(sc, EQUIP_POP_TWEEN, { Scale = 1 }):Play()
end

-- Slot `Button` is often an ImageButton with a light template art layer; only tint (never swap Image id).
local SLOT_BUTTON_IMAGE_TINT = Color3.fromRGB(58, 60, 72)
local BACKPACK_SLOT_PANEL_OCCUPIED = Color3.fromRGB(26, 28, 34)

type BackpackSlotPanelDefaults = {
	bgTransparency: number,
	imageTransparency: number?,
	strokeTransparency: number?,
}

local backpackSlotPanelDefaults: { [GuiButton]: BackpackSlotPanelDefaults } = {}

local function captureBackpackSlotPanelDefaults(btn: GuiButton): BackpackSlotPanelDefaults
	local cached = backpackSlotPanelDefaults[btn]
	if cached then
		return cached
	end
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	local defaults: BackpackSlotPanelDefaults = {
		bgTransparency = btn.BackgroundTransparency,
		imageTransparency = if btn:IsA("ImageButton") then (btn :: ImageButton).ImageTransparency else nil,
		strokeTransparency = if stroke then stroke.Transparency else nil,
	}
	backpackSlotPanelDefaults[btn] = defaults
	return defaults
end

local function applyBackpackSlotPanelAppearance(btn: GuiButton, occupied: boolean)
	local defaults = captureBackpackSlotPanelDefaults(btn)
	local stroke = btn:FindFirstChildOfClass("UIStroke")

	if occupied then
		local color = BACKPACK_SLOT_PANEL_OCCUPIED
		if btn:IsA("ImageButton") then
			local imageBtn = btn :: ImageButton
			imageBtn.ImageColor3 = color
			imageBtn.ImageTransparency = defaults.imageTransparency or 0
		else
			btn.BackgroundColor3 = color
		end
		btn.BackgroundTransparency = defaults.bgTransparency
		if stroke then
			stroke.Enabled = true
			stroke.Transparency = defaults.strokeTransparency or 0
		end
	else
		btn.BackgroundTransparency = 1
		if btn:IsA("ImageButton") then
			(btn :: ImageButton).ImageTransparency = 1
		end
		if stroke then
			stroke.Transparency = 1
		end
	end
end

local function styleToolbarSlotButton(btn: GuiButton)
	enableGuiButtonInput(btn)
	if btn:IsA("ImageButton") then
		btn.AutoButtonColor = false
		btn.ImageColor3 = SLOT_BUTTON_IMAGE_TINT
	end
	for _, icon in slotIconTargets(btn :: GuiObject) do
		applySlotIconStyle(icon)
	end
end

local function styleToggleBackpackIcon(btn: GuiButton)
	enableGuiButtonInput(btn)
	if btn:IsA("ImageButton") then
		btn.AutoButtonColor = false
		btn.ImageColor3 = TOGGLE_BACKPACK_ICON_TINT
		btn.ImageTransparency = 0
	end
	for _, d in btn:GetDescendants() do
		if d:IsA("ImageLabel") then
			d.ImageColor3 = TOGGLE_BACKPACK_ICON_TINT
			d.ImageTransparency = 0
			d.ScaleType = Enum.ScaleType.Fit
		end
	end
end

local function prepareToggleTiltPivot(gui: GuiObject)
	if gui:GetAttribute("_TiltPivotReady") == true then
		return
	end
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.fromScale(0.5, 0.5)
	gui:SetAttribute("_TiltPivotReady", true)
end

local function resolveToggleBackpackVisual(iconHost: GuiObject, btn: GuiButton): GuiObject
	local named = iconHost:FindFirstChild("Icon", true) or btn:FindFirstChild("Icon", true)
	if named and named:IsA("GuiObject") then
		return named
	end
	local best: ImageLabel? = nil
	local bestArea = 0
	for _, d in iconHost:GetDescendants() do
		if d:IsA("ImageLabel") and d.Visible then
			local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
			if area > bestArea then
				bestArea = area
				best = d
			end
		end
	end
	if best then
		return best
	end
	if btn:IsA("ImageButton") then
		return btn
	end
	return iconHost
end

local function formatEntryIncomeLabel(entry: {
	name: string,
	rarity: string?,
	mutation: string?,
	level: number?,
	baseIncome: number?,
}): string
	local inc = BrainrotEconomy.incomePerSecond({
		name = entry.name,
		rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
		mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
		level = if typeof(entry.level) == "number" then entry.level else 1,
		baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
	})
	return BrainrotEconomy.formatCashShort(inc) .. "/s"
end

local function findBackpackChild(frame: Instance, name: string): Instance?
	local direct = frame:FindFirstChild(name)
	if direct then
		return direct
	end
	local fadeRoot = frame:FindFirstChild("_BackpackFadeRoot")
	if fadeRoot then
		return fadeRoot:FindFirstChild(name)
	end
	return nil
end

local BACKPACK_CHROME_NAMES = { "BackpackButtons", "OtherButtons", "SortButtons", "SortCatagory", "SortCategory" }

local function detachBackpackChromeFromFadeRoot(frame: GuiObject)
	local fadeRoot = frame:FindFirstChild("_BackpackFadeRoot")
	if not fadeRoot then
		return
	end
	for _, name in BACKPACK_CHROME_NAMES do
		local ch = fadeRoot:FindFirstChild(name)
		if ch then
			ch.Parent = frame
		end
	end
end

local function ensureBackpackChromeVisible(frame: GuiObject)
	frame.ClipsDescendants = false
	detachBackpackChromeFromFadeRoot(frame)
	for _, name in BACKPACK_CHROME_NAMES do
		local ch = frame:FindFirstChild(name) or findBackpackChild(frame, name)
		if ch and ch:IsA("GuiObject") then
			local gui = ch :: GuiObject
			gui.Visible = true
			disableGuiInputCapture(gui)
			if gui.ZIndex < 4 then
				gui.ZIndex = 4
			end
		end
	end
	local otherButtons = frame:FindFirstChild("OtherButtons")
	if otherButtons then
		local equipBest = otherButtons:FindFirstChild("EquipBest")
		if equipBest and equipBest:IsA("GuiObject") then
			local bestGui = equipBest :: GuiObject
			bestGui.Visible = true
			if bestGui.ZIndex < 5 then
				bestGui.ZIndex = 5
			end
		end
	end
	local container = findBackpackChild(frame, "Container")
	if container and container:IsA("GuiObject") then
		(container :: GuiObject).Visible = true
	end
end

local function rebuildBackpackDisplayOrder()
	backpackDisplayOrder = {}
	for ki = 1, #brainrotEntries do
		if brainrotEntries[ki] and (ki > HOTBAR_INVENTORY_SLOTS or brainrotParkedInUI[ki]) then
			table.insert(backpackDisplayOrder, ki)
		end
	end
end

local function listIndexForBackpackUiRow(uiRow: number): number?
	if uiRow < 1 or uiRow > MAX_BACKPACK_BRAINROT_SLOTS then
		return nil
	end
	return backpackDisplayOrder[uiRow]
end

local function brainrotEntryForBackpackSlot(uiRow: number): { name: string, icon: string, sourcePath: string }?
	local li = listIndexForBackpackUiRow(uiRow)
	if not li then
		return nil
	end
	return brainrotEntries[li]
end

local function matchesBackpackSearch(itemName: string): boolean
	local q = string.lower(string.gsub(string.gsub(backpackSearchText, "^%s+", ""), "%s+$", ""))
	if q == "" then
		return true
	end
	return string.find(string.lower(itemName), q, 1, true) ~= nil
end

local function resetBackpackDragHover()
	if not backpackDragHover then
		return
	end
	backpackDragHover = false
	if backpackFrameRef then
		local frame = backpackFrameRef :: GuiObject
		local sc = getOrAddUIScale(frame)
		TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = 1 }):Play()
		local stroke = frame:FindFirstChild("ToolbarBackpackOutline")
		if stroke and stroke:IsA("UIStroke") then
			TweenService:Create(stroke, HIGHLIGHT_TWEEN, { Transparency = 0.48 }):Play()
		end
	end
	if backpackContainer then
		for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
			local row = backpackContainer:FindFirstChild(tostring(idx))
			if row and row:IsA("GuiObject") and (row :: GuiObject).Visible then
				TweenService:Create(getOrAddUIScale(row), HIGHLIGHT_TWEEN, { Scale = 1 }):Play()
			end
		end
	end
end

local function enterBackpackDragHover()
	if backpackDragHover or not isBackpackPanelOpen then
		return
	end
	backpackDragHover = true
	if backpackFrameRef then
		local frame = backpackFrameRef :: GuiObject
		TweenService:Create(getOrAddUIScale(frame), HIGHLIGHT_TWEEN, { Scale = BACKPACK_FRAME_DRAG_HOVER_SCALE }):Play()
		local stroke = frame:FindFirstChild("ToolbarBackpackOutline")
		if stroke and stroke:IsA("UIStroke") then
			TweenService:Create(stroke, HIGHLIGHT_TWEEN, { Transparency = 0.12 }):Play()
		end
	end
	if backpackContainer then
		for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
			local row = backpackContainer:FindFirstChild(tostring(idx))
			if row and row:IsA("GuiObject") and (row :: GuiObject).Visible then
				TweenService:Create(getOrAddUIScale(row), HIGHLIGHT_TWEEN, { Scale = BACKPACK_ROW_DRAG_HOVER_SCALE }):Play()
			end
		end
	end
end

local function resetHotbarSlotHoverScalesAfterDrag()
	hotbarDragBulkHover = false
	for si = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[si]
		if not slot then
			continue
		end
		local sc = getOrAddUIScale(hotbarSlotScaleHost(slot) :: GuiObject)
		TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
	end
end

local function enterHotbarBackpackDragBulkHover()
	if hotbarDragBulkHover then
		return
	end
	hotbarDragBulkHover = true
	for si = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[si]
		if not slot then
			continue
		end
		local sc = getOrAddUIScale(hotbarSlotScaleHost(slot) :: GuiObject)
		TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = HOTBAR_BULK_DRAG_HOVER_SCALE }):Play()
	end
end

local function updateDragHoverTargets(overHotbar: boolean, overBackpack: boolean, overBackpackPanel: boolean)
	if overHotbar and not overBackpackPanel then
		enterHotbarBackpackDragBulkHover()
	elseif hotbarDragBulkHover then
		resetHotbarSlotHoverScalesAfterDrag()
	end
	if overBackpackPanel or (overBackpack and isBackpackPanelOpen) then
		enterBackpackDragHover()
	else
		resetBackpackDragHover()
	end
end

local function clearDragGhost()
	if dragGhostConn then
		dragGhostConn:Disconnect()
		dragGhostConn = nil
	end
	dragGhostSmoothPos = nil
	if dragGhostGui then
		dragGhostGui:Destroy()
		dragGhostGui = nil
	end
	dragGhostImage = nil
	resetHotbarSlotHoverScalesAfterDrag()
	resetBackpackDragHover()
end

local function startDragGhost(texture: string, screenPos: Vector2)
	clearDragGhost()
	local sg = Instance.new("ScreenGui")
	sg.Name = "ToolbarBrainrotDragGhost"
	-- Match PlayerGui coordinates so ghost AbsolutePosition lines up with hotbar hit-tests.
	sg.IgnoreGuiInset = false
	sg.DisplayOrder = 1000
	sg.ResetOnSpawn = false
	sg.Parent = playerGui
	local im = Instance.new("ImageLabel")
	im.Name = "Ghost"
	im.BackgroundTransparency = 0.65
	im.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	im.Image = texture
	im.ImageTransparency = 0.05
	im.Size = UDim2.fromOffset(72, 72)
	im.AnchorPoint = Vector2.new(0.5, 0.5)
	im.ZIndex = 10
	im.Parent = sg
	dragGhostGui = sg
	dragGhostImage = im
	dragGhostSmoothPos = screenPos
	im.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
	dragGhostConn = RunService.RenderStepped:Connect(function()
		if not dragGhostImage or not dragGhostSmoothPos then
			return
		end
		local m = UserInputService:GetMouseLocation()
		local target = Vector2.new(m.X, m.Y)
		dragGhostSmoothPos = dragGhostSmoothPos:Lerp(target, DRAG_GHOST_SMOOTH)
		dragGhostImage.Position = UDim2.fromOffset(dragGhostSmoothPos.X, dragGhostSmoothPos.Y)
	end)
end

local function ensureBackpackFrameOutline(frame: GuiObject)
	local s = frame:FindFirstChildOfClass("UIStroke")
	if not s then
		s = Instance.new("UIStroke")
		s.Name = "ToolbarBackpackOutline"
		s.Parent = frame
	end
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Thickness = 2
	s.Transparency = 0.48
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
end

local function cancelBackpackPanelTweens()
	if backpackPanelScaleTween then
		backpackPanelScaleTween:Cancel()
		backpackPanelScaleTween = nil
	end
	if backpackPanelFadeTween then
		backpackPanelFadeTween:Cancel()
		backpackPanelFadeTween = nil
	end
	if backpackContainerScaleTween then
		backpackContainerScaleTween:Cancel()
		backpackContainerScaleTween = nil
	end
end

local function ensureBackpackFadeRoot(frame: GuiObject): CanvasGroup
	if backpackFadeRoot and backpackFadeRoot.Parent == frame then
		return backpackFadeRoot
	end
	local existing = frame:FindFirstChild("_BackpackFadeRoot")
	if existing and existing:IsA("CanvasGroup") then
		backpackFadeRoot = existing
		return existing
	end
	local cg = Instance.new("CanvasGroup")
	cg.Name = "_BackpackFadeRoot"
	cg.Size = UDim2.fromScale(1, 1)
	cg.BackgroundTransparency = 1
	cg.BorderSizePixel = 0
	cg.GroupTransparency = 0
	local toMove: { Instance } = {}
	for _, ch in frame:GetChildren() do
		table.insert(toMove, ch)
	end
	cg.Parent = frame
	for _, ch in toMove do
		if ch ~= cg then
			local skip = false
			for _, name in BACKPACK_CHROME_NAMES do
				if ch.Name == name then
					skip = true
					break
				end
			end
			if not skip then
				ch.Parent = cg
			end
		end
	end
	backpackFadeRoot = cg
	return cg
end

local function resolveBackpackHeaderLabel(backpackFrame: Instance): Instance?
	local cat = findBackpackChild(backpackFrame, "SortCatagory") or findBackpackChild(backpackFrame, "SortCategory")
	if cat and (cat:IsA("TextLabel") or cat:IsA("TextButton")) then
		return cat
	end
	if cat and cat:IsA("GuiObject") then
		local named = cat:FindFirstChild("Text") or cat:FindFirstChild("Title") or cat:FindFirstChild("Label")
		if named and (named:IsA("TextLabel") or named:IsA("TextButton")) then
			return named
		end
		local anyLabel = cat:FindFirstChildWhichIsA("TextLabel", true)
		if anyLabel then
			return anyLabel
		end
		local anyBtn = cat:FindFirstChildWhichIsA("TextButton", true)
		if anyBtn then
			return anyBtn
		end
	end
	return nil
end

local function refreshInventoryHeaderText()
	local label = backpackHeaderLabel
	if not label or (not label:IsA("TextLabel") and not label:IsA("TextButton")) then
		return
	end
	if label:IsA("TextLabel") then
		(label :: TextLabel).Text = string.format("All Items [%d/%d]", brainrotInventoryUsed, brainrotInventoryMax)
	elseif label:IsA("TextButton") then
		(label :: TextButton).Text = string.format("All Items [%d/%d]", brainrotInventoryUsed, brainrotInventoryMax)
	end
end

local function setBackpackPanelOpen(open: boolean)
	if open and not canUseToolbar then
		return
	end
	if not backpackFrameRef then
		return
	end
	if open and isBackpackPanelOpen then
		ensureBackpackChromeVisible(backpackFrameRef :: GuiObject)
		return
	end
	isBackpackPanelOpen = open
	local f = backpackFrameRef
	cancelBackpackPanelTweens()
	local sc = getOrAddUIScale(f :: Instance)
	local fadeRoot = ensureBackpackFadeRoot(f)
	if open then
		f.Visible = true
		ensureBackpackChromeVisible(f)
		fadeRoot.GroupTransparency = 0
		sc.Scale = 0.94
		backpackPanelScaleTween = TweenService:Create(sc, BACKPACK_OPEN_TWEEN, { Scale = 1 })
		backpackPanelScaleTween:Play()
		if backpackContainer and backpackContainer:IsA("GuiObject") then
			local csc = getOrAddUIScale(backpackContainer :: Instance)
			csc.Scale = 0.96
			backpackContainerScaleTween = TweenService:Create(
				csc,
				TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
			backpackContainerScaleTween:Play()
		end
		if canUseToolbar then
			showToolbar()
		end
		updateHotbarSlotVisibility()
		for i = 1, #slots do
			refreshSlotVisual(i)
		end
		refreshBrainrotBackpackUI()
	else
		backpackPanelScaleTween = TweenService:Create(sc, BACKPACK_CLOSE_TWEEN, { Scale = 0.9 })
		backpackPanelFadeTween = TweenService:Create(fadeRoot, BACKPACK_CLOSE_TWEEN, { GroupTransparency = 1 })
		backpackPanelScaleTween:Play()
		backpackPanelFadeTween:Play()
		if backpackContainer and backpackContainer:IsA("GuiObject") then
			local csc = getOrAddUIScale(backpackContainer :: Instance)
			backpackContainerScaleTween = TweenService:Create(csc, BACKPACK_CLOSE_TWEEN, { Scale = 0.94 })
			backpackContainerScaleTween:Play()
		end
		backpackPanelFadeTween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed and not isBackpackPanelOpen then
				f.Visible = false
				sc.Scale = 1
				fadeRoot.GroupTransparency = 0
				if backpackContainer and backpackContainer:IsA("GuiObject") then
					getOrAddUIScale(backpackContainer :: Instance).Scale = 1
				end
				updateHotbarSlotVisibility()
				for i = 1, #slots do
					refreshSlotVisual(i)
				end
			end
			if backpackPanelFadeTween and state == Enum.PlaybackState.Completed then
				backpackPanelFadeTween = nil
			end
		end)
	end
end

showToolbar = function()
	if toolbarShown then
		return
	end
	toolbarShown = true
	toolbar.Visible = true
	local scale = getOrAddUIScale(toolbar)
	if toolbarVisibilityTween then
		toolbarVisibilityTween:Cancel()
		toolbarVisibilityTween = nil
	end
	if scale.Scale < 0.85 then
		scale.Scale = 0.8
	end
	toolbarVisibilityTween = TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 })
	toolbarVisibilityTween:Play()
	task.defer(function()
		task.defer(refreshToggleBackpackIconLayout)
	end)
end

hideToolbar = function()
	if not toolbarShown then
		return
	end
	if activeToolbarDrag then
		return
	end
	toolbarShown = false
	local scale = getOrAddUIScale(toolbar)
	if toolbarVisibilityTween then
		toolbarVisibilityTween:Cancel()
		toolbarVisibilityTween = nil
	end
	local t = TweenService:Create(scale, HIDE_TWEEN, { Scale = 0.8 })
	toolbarVisibilityTween = t
	t.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and not toolbarShown then
			toolbar.Visible = false
		end
		if toolbarVisibilityTween == t then
			toolbarVisibilityTween = nil
		end
	end)
	t:Play()
end

local function canSelectHotbarSlot(): boolean
	return canUseToolbar
end

local function hotbarSlotHasSelectableContent(index: number): boolean
	if brainrotParkedInUI[index] then
		return false
	end
	if brainrotEntries[index] ~= nil then
		return true
	end
	if slotTools[index] ~= nil then
		return true
	end
	local mapped = extraToolSlotByIndex[index]
	if mapped and mapped.Parent then
		return true
	end
	return false
end

local function refreshToolbarVisibility()
	if canUseToolbar then
		showToolbar()
	else
		hideToolbar()
	end
end

local deselectAllHotbarSlots: () -> ()
local applyAutoEquipFromSync: (number) -> ()

local function getPrimaryCarriedBrainrotName(): string?
	local char = player.Character
	if not char then
		return nil
	end
	for _, d in char:GetDescendants() do
		if d:IsA("Model") then
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" then
				local attrName = d:GetAttribute("BrainrotName")
				if typeof(attrName) == "string" and attrName ~= "" then
					return attrName
				end
				if d.Name ~= "" then
					return d.Name
				end
			end
		end
	end
	return nil
end

local function findHotbarSlotForBrainrotName(itemName: string): number?
	for i = 1, HOTBAR_INVENTORY_SLOTS do
		local e = brainrotEntries[i]
		if e and e.name == itemName and not brainrotParkedInUI[i] then
			return i
		end
	end
	return nil
end

local function tryAutoSelectReturnedBrainrot()
	if not canUseToolbar then
		return
	end
	local now = os.clock()
	if now - lastSafezoneAutoEquipAttempt < SAFEZONE_AUTO_EQUIP_DEBOUNCE then
		return
	end
	lastSafezoneAutoEquipAttempt = now

	if typeof(pendingAutoEquipSlot) == "number" then
		local slot = math.clamp(math.floor(pendingAutoEquipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)
		if brainrotEntries[slot] and (slot > HOTBAR_INVENTORY_SLOTS or not brainrotParkedInUI[slot]) then
			applyAutoEquipFromSync(slot)
			pendingAutoEquipSlot = nil
			pendingReturnedBrainrotName = nil
		end
		return
	end

	if pendingReturnedBrainrotName then
		local slot = findHotbarSlotForBrainrotName(pendingReturnedBrainrotName)
		if slot then
			applyAutoEquipFromSync(slot)
			pendingReturnedBrainrotName = nil
		end
	end
end

local function onSafezonePresenceChanged(inZone: boolean)
	if canUseToolbar == inZone then
		return
	end
	canUseToolbar = inZone
	if inZone then
		if CarryGate.isCarrying() then
			local name = getPrimaryCarriedBrainrotName()
			if name then
				pendingReturnedBrainrotName = name
			end
		end
		tryAutoSelectReturnedBrainrot()
	else
		pendingReturnedBrainrotName = nil
		setBackpackPanelOpen(false)
		deselectAllHotbarSlots()
		if not activeToolbarDrag then
			clearDragGhost()
			pendingToolbarDrag = nil
		end
	end
	refreshToolbarVisibility()
end

local function isCharacterInToolbarAccessZone(character: Model?): boolean
	if not character then
		return false
	end
	if SafezoneUtil.isCharacterInToolbarZone(character) then
		return true
	end
	if SafezoneUtil.isCharacterInSafezone(character) then
		return true
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") and SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position) then
		return true
	end
	return false
end

local function toolbarInputAllowed(): boolean
	return canUseToolbar or activeToolbarDrag
end

local function pollSafezonePresence()
	local inZone = isCharacterInToolbarAccessZone(player.Character)
	if inZone then
		safezoneOutStreak = 0
		onSafezonePresenceChanged(true)
		return
	end
	safezoneOutStreak += 1
	if safezoneOutStreak >= SAFEZONE_EXIT_POLLS_REQUIRED then
		onSafezonePresenceChanged(false)
	end
end

-- ── Slot highlight ────────────────────────────────────────────────────────────

-- Selection = UIStroke only. Never touch the slot's own Image / ImageColor3 (that's the slot art designed in Studio).
local SLOT_STROKE_SELECTED = 0
local SLOT_STROKE_IDLE = 0.6
local slotStrokeLit: { [number]: boolean } = {}

local function applyButtonSelectionStyle(btn: GuiObject, lit: boolean)
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = if lit then SLOT_STROKE_SELECTED else SLOT_STROKE_IDLE
	end
end

local function setSlotHighlight(index: number?, lit: boolean)
	if not index then
		return
	end
	if slotStrokeLit[index] == lit then
		return
	end
	slotStrokeLit[index] = lit
	local slot = slots[index]
	if not slot then
		return
	end
	local btn = slotPrimaryButton(slot)
	if btn then
		applyButtonSelectionStyle(btn :: GuiObject, lit)
	end
end

local function syncAllHotbarSelectionStrokes()
	for i = 1, #slots do
		local lit = uiHotbarHighlight ~= nil and i == uiHotbarHighlight
		setSlotHighlight(i, lit)
	end
end

local function setHotbarSelection(index: number?, animateEquip: boolean?)
	local changed = uiHotbarHighlight ~= index
	uiHotbarHighlight = index
	activeSlot = index
	syncAllHotbarSelectionStrokes()
	if animateEquip ~= false and changed and typeof(index) == "number" then
		playEquipSlotAnimation(index)
	end
end

local function resetAllSlotsToIdle()
	for i, slot in ipairs(slots) do
		setSlotHighlight(i, false)
	end
end

-- Leaving the safe zone: unequip held brainrot and clear every hotbar selection ring.
deselectAllHotbarSlots = function()
	local hum = getHumanoid()
	if hum then
		hum:UnequipTools()
	end
	uiHotbarHighlight = nil
	activeSlot = nil
	table.clear(slotStrokeLit)
	for si = 1, #slots do
		setSlotHighlight(si, false)
		local slot = slots[si]
		if slot then
			local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
			sc.Scale = 1
		end
	end
end

-- ── Slot icon update ──────────────────────────────────────────────────────────

refreshSlotVisual = function(index: number)
	local slot = slots[index]
	if not slot then
		return
	end

	local surface = toolSlotSurface(slot)
	local keyLabel = surface:FindFirstChild("Key") or surface:FindFirstChild("Number")
	local rate = surface:FindFirstChild("Rate")

	-- 1. slotTools[index] → tool icon  2. parked → blank  3. brainrotEntries[index] → entry  4. else blank
	if slotTools[index] ~= nil then
		local tool = slotTools[index] :: Tool
		local invIdx = tool:GetAttribute("BrainrotInvIndex")
		local entryForTool: { name: string, icon: string, sourcePath: string }? = nil
		if typeof(invIdx) == "number" then
			local ei = math.clamp(math.floor(invIdx), 1, math.max(1, #brainrotEntries))
			entryForTool = brainrotEntries[ei]
		end
		local tex = (tool :: any).TextureId
		if entryForTool and entryForTool.icon ~= "" then
			tex = entryForTool.icon
		end
		setSlotIcons(
			surface,
			(tex and tex ~= "") and tex or "rbxasset://textures/ui/GuiImagePlaceholder.png",
			true
		)
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = if entryForTool then formatEntryIncomeLabel(entryForTool) else tool.Name
		end
	elseif brainrotParkedInUI[index] == true then
		setSlotIcons(surface, "", false)
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = ""
		end
	elseif brainrotEntries[index] ~= nil then
		local e = brainrotEntries[index] :: { name: string, icon: string, sourcePath: string }
		setSlotIcons(
			surface,
			(e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png",
			true
		)
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = formatEntryIncomeLabel(e)
		end
	else
		setSlotIcons(surface, "", false)
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = ""
		end
	end
end

local function hotbarSlotIsOccupied(index: number): boolean
	if brainrotParkedInUI[index] then
		return false
	end
	if slotTools[index] ~= nil then
		return true
	end
	local mapped = extraToolSlotByIndex[index]
	if mapped and mapped.Parent then
		return true
	end
	return brainrotEntries[index] ~= nil
end

local hotbarListLayout: UIListLayout? = nil
local toolbarHorizontalCenterApplied = false

local function centerToolbarChildHorizontally(gui: GuiObject)
	local pos = gui.Position
	local ap = gui.AnchorPoint
	gui.AnchorPoint = Vector2.new(0.5, ap.Y)
	gui.Position = UDim2.new(0.5, 0, pos.Y.Scale, pos.Y.Offset)
end

local function applyToolbarHorizontalCenterOnce()
	if toolbarHorizontalCenterApplied then
		return
	end
	toolbarHorizontalCenterApplied = true
	if hotbar:IsA("GuiObject") then
		centerToolbarChildHorizontally(hotbar :: GuiObject)
	end
	if backpackFrameRef then
		centerToolbarChildHorizontally(backpackFrameRef)
	end
end

local function ensureHotbarListLayout(): UIListLayout
	if hotbarListLayout and hotbarListLayout.Parent == hotbar then
		return hotbarListLayout
	end
	local layout = hotbar:FindFirstChildOfClass("UIListLayout")
	if not layout then
		layout = Instance.new("UIListLayout")
		layout.Parent = hotbar
	end
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	hotbarListLayout = layout
	return layout
end

local function getHotbarSlotSizeTemplate(): UDim2?
	for i = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[i]
		if slot and slot:IsA("GuiObject") then
			return (slot :: GuiObject).Size
		end
	end
	return nil
end

local function pinToggleIconMinAbsoluteSize(icon: GuiObject, targetW: number, targetH: number)
	icon:SetAttribute("_MinW", math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(targetW + 0.5)))
	icon:SetAttribute("_MinH", math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(targetH + 0.5)))
end

local function scaledToggleIconSizeFromTemplate(slotTemplate: UDim2): UDim2
	local w = slotTemplate.X.Offset
	local h = slotTemplate.Y.Offset
	if w < 8 or h < 8 then
		return slotTemplate
	end
	return UDim2.fromOffset(
		math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(w * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5)),
		math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(h * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5))
	)
end

local function ensureToggleBackpackIconSizeConstraint(icon: GuiObject)
	local minW = icon:GetAttribute("_MinW")
	local minH = icon:GetAttribute("_MinH")
	if typeof(minW) ~= "number" or typeof(minH) ~= "number" then
		return
	end
	local constraint = icon:FindFirstChild("ToggleIconSizeConstraint")
	if not constraint or not constraint:IsA("UISizeConstraint") then
		constraint = Instance.new("UISizeConstraint")
		constraint.Name = "ToggleIconSizeConstraint"
		constraint.Parent = icon
	end
	local sizeLock = constraint :: UISizeConstraint
	sizeLock.MinSize = Vector2.new(minW, minH)

	local slot = slots[1]
	if slot and slot:IsA("GuiObject") then
		local slotAbs = (slot :: GuiObject).AbsoluteSize
		if slotAbs.X > 0 and slotAbs.Y > 0 then
			local aspect = icon:FindFirstChild("ToggleIconAspect")
			if not aspect or not aspect:IsA("UIAspectRatioConstraint") then
				aspect = Instance.new("UIAspectRatioConstraint")
				aspect.Name = "ToggleIconAspect"
				aspect.Parent = icon
			end
			local aspectLock = aspect :: UIAspectRatioConstraint
			aspectLock.AspectRatio = slotAbs.X / slotAbs.Y
			aspectLock.AspectType = Enum.AspectType.ScaleWithParentSize
		end
	end
end

local function wireToggleBackpackIconResizeSync()
	if hotbar:GetAttribute("_ToggleIconResizeWired") == true then
		return
	end
	hotbar:SetAttribute("_ToggleIconResizeWired", true)
	hotbar:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(refreshToggleBackpackIconLayout)
	end)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(refreshToggleBackpackIconLayout)
		end)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				task.defer(refreshToggleBackpackIconLayout)
			end)
		end
	end)
end

local function captureToggleIconPixelSize(icon: GuiObject): (number?, number?)
	local pinnedW = icon:GetAttribute("_PinnedW")
	local pinnedH = icon:GetAttribute("_PinnedH")
	if typeof(pinnedW) == "number" and typeof(pinnedH) == "number" then
		return pinnedW, pinnedH
	end
	local sz = icon.Size
	if sz.X.Offset >= 8 and sz.Y.Offset >= 8 then
		return sz.X.Offset, sz.Y.Offset
	end
	local abs = icon.AbsoluteSize
	if abs.X >= 8 and abs.Y >= 8 then
		return abs.X, abs.Y
	end
	for i = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[i]
		if slot and slot:IsA("GuiObject") then
			local rs = (slot :: GuiObject).Size
			if rs.X.Offset >= 8 and rs.Y.Offset >= 8 then
				return rs.X.Offset, rs.Y.Offset
			end
			local rabs = (slot :: GuiObject).AbsoluteSize
			if rabs.X >= 8 and rabs.Y >= 8 then
				return rabs.X, rabs.Y
			end
		end
	end
	return nil, nil
end

refreshToggleBackpackIconLayout = function()
	if not toggleBackpackIconRef then
		return
	end
	local icon = toggleBackpackIconRef :: GuiObject
	if isBackpackPanelOpen then
		icon.Visible = false
		return
	end

	local layout = ensureHotbarListLayout()
	layout.Padding = UDim.new(0, 6)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	local w, h = captureToggleIconPixelSize(icon)
	local slotTemplate = getHotbarSlotSizeTemplate()
	local iconSize: UDim2
	if slotTemplate then
		iconSize = scaledToggleIconSizeFromTemplate(slotTemplate)
	elseif w and h then
		iconSize = UDim2.fromOffset(
			math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(w * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5)),
			math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(h * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5))
		)
	else
		iconSize = UDim2.fromOffset(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, TOGGLE_BACKPACK_ICON_MIN_ABS_PX)
	end
	icon.Size = iconSize

	icon.AnchorPoint = Vector2.new(0, 0)
	if icon.Parent ~= hotbar then
		icon.Parent = hotbar
	end
	icon.LayoutOrder = 100
	icon.Visible = true

	pinToggleIconMinAbsoluteSize(icon, iconSize.X.Offset, iconSize.Y.Offset)
	ensureToggleBackpackIconSizeConstraint(icon)
end

updateHotbarSlotVisibility = function()
	ensureHotbarListLayout()
	for i = 1, #slots do
		local slot = slots[i]
		if slot then
			slot.Visible = hotbarSlotIsOccupied(i) or isBackpackPanelOpen
		end
	end
	if toggleBackpackIconRef then
		local icon = toggleBackpackIconRef :: GuiObject
		icon.Visible = not isBackpackPanelOpen
		if not isBackpackPanelOpen then
			task.defer(refreshToggleBackpackIconLayout)
		end
	end
end

local function toggleBackpackPanel()
	if not canUseToolbar then
		return
	end
	if not backpackFrameRef then
		return
	end
	setBackpackPanelOpen(not isBackpackPanelOpen)
end

local function wireToggleBackpackIcon()
	local iconHost = toolbar:FindFirstChild("ToggleBackpackImage") or hotbar:FindFirstChild("ToggleBackpackImage")
	if not iconHost or not iconHost:IsA("GuiObject") then
		return
	end
	toggleBackpackIconRef = iconHost
	toggleBackpackRef = iconHost

	local btn: GuiButton? = nil
	if iconHost:IsA("GuiButton") then
		btn = iconHost :: GuiButton
	else
		btn = slotPrimaryButton(iconHost)
	end
	if not btn then
		warn("[ToolbarController] ToggleBackpackImage has no GuiButton")
		return
	end

	disableGuiInputCapture(iconHost)
	enableGuiButtonInput(btn)
	styleToggleBackpackIcon(btn)
	local tiltTarget = resolveToggleBackpackVisual(iconHost, btn)
	if tiltTarget ~= iconHost then
		prepareToggleTiltPivot(tiltTarget)
	end
	-- Tilt + scale hover only (no glisten/spin polish).
	UIButtonEffects.wireTiltHoverButton(btn, toggleBackpackPanel, iconHost, tiltTarget, false)
	wireToggleBackpackIconResizeSync()
	task.defer(refreshToggleBackpackIconLayout)
end

-- ── Tool assignment ───────────────────────────────────────────────────────────

local function rebuildSlots()
	-- Clear existing assignment
	for i = 1, #slots do
		slotTools[i] = nil
	end

	local backpack = getBackpack()
	local char = player.Character
	local equipped: Tool? = nil
	if char then
		equipped = char:FindFirstChildOfClass("Tool") :: Tool?
	end

	local maxHotbar = math.min(HOTBAR_INVENTORY_SLOTS, #slots)
	-- Hotbar 1..9 mirrors brainrot inventory indices 1..9 (like Roblox's first toolbar slots).
	for i = 1, maxHotbar do
		if brainrotParkedInUI[i] then
			slotTools[i] = nil
		else
			local t = if char then findBrainrotToolAtInvIndex(char, i) else nil
			if not t and backpack then
				t = findBrainrotToolAtInvIndex(backpack, i)
			end
			slotTools[i] = t
		end
	end

	-- Drop stale extra-tool slot pins; keep equipped tools visible in the hotbar.
	for idx, tool in pairs(extraToolSlotByIndex) do
		if not tool.Parent or not isExtraHotbarTool(tool) then
			extraToolSlotByIndex[idx] = nil
		end
	end

	local extras = collectExtraHotbarTools()
	local assignedExtras: { [Tool]: boolean } = {}

	for idx, tool in pairs(extraToolSlotByIndex) do
		if idx >= 1 and idx <= maxHotbar and slotTools[idx] == nil and not brainrotParkedInUI[idx] and brainrotEntries[idx] == nil then
			if tool.Parent then
				slotTools[idx] = tool
				assignedExtras[tool] = true
			else
				extraToolSlotByIndex[idx] = nil
			end
		end
	end

	for _, tool in ipairs(extras) do
		if not assignedExtras[tool] then
			for i = 1, maxHotbar do
				if slotTools[i] == nil and not brainrotParkedInUI[i] and brainrotEntries[i] == nil then
					slotTools[i] = tool
					extraToolSlotByIndex[i] = tool
					assignedExtras[tool] = true
					break
				end
			end
		end
	end

	-- Refresh visuals
	for i = 1, #slots do
		refreshSlotVisual(i)
	end
	updateHotbarSlotVisibility()

	-- Highlight follows equipped tool; drop stale ring when that slot no longer has a brainrot (e.g. placed on stand).
	local equippedSlot: number? = nil
	if equipped then
		local invIdx = equipped:GetAttribute("BrainrotInvIndex")
		if typeof(invIdx) == "number" then
			local raw = math.floor(invIdx)
			if raw >= 1 and raw <= HOTBAR_INVENTORY_SLOTS then
				equippedSlot = raw
			end
		else
			for i = 1, #slots do
				if slotTools[i] == equipped then
					equippedSlot = i
					break
				end
			end
		end
	end
	if equippedSlot then
		uiHotbarHighlight = equippedSlot
	elseif uiHotbarHighlight ~= nil then
		local hi = math.clamp(uiHotbarHighlight, 1, HOTBAR_INVENTORY_SLOTS)
		local slotStillHasBrainrot = slotTools[hi] ~= nil
			or extraToolSlotByIndex[hi] ~= nil
			or (brainrotEntries[hi] ~= nil and brainrotParkedInUI[hi] ~= true)
		if not slotStillHasBrainrot then
			uiHotbarHighlight = nil
		end
	end
	if uiHotbarHighlight ~= nil then
		uiHotbarHighlight = math.clamp(uiHotbarHighlight, 1, HOTBAR_INVENTORY_SLOTS)
		activeSlot = uiHotbarHighlight
	else
		activeSlot = nil
	end
	syncAllHotbarSelectionStrokes()

	refreshToolbarVisibility()
end

refreshBrainrotBackpackUI = function()
	local container = backpackContainer
	if not container then
		return
	end
	rebuildBackpackDisplayOrder()
	for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
		local row = container:FindFirstChild(tostring(idx))
		if not row or not row:IsA("GuiObject") then
			continue
		end
		local entry = brainrotEntryForBackpackSlot(idx)
		if entry and backpackSearchText ~= "" and not matchesBackpackSearch(entry.name) then
			entry = nil
		end
		row.Visible = entry ~= nil
		if not entry then
			continue
		end
		local surface = toolSlotSurface(row :: GuiObject)
		local rate = surface:FindFirstChild("Rate")
		local key = surface:FindFirstChild("Key")
		if entry then
			setSlotIcons(
				surface,
				entry.icon ~= "" and entry.icon or "rbxasset://textures/ui/GuiImagePlaceholder.png",
				true
			)
			for _, icon in slotIconTargets(surface) do
				icon.AnchorPoint = Vector2.new(0.5, 0.5)
				icon.Position = UDim2.new(0.5, 0, 0.5, 0)
			end
			if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
				rate.Text = formatEntryIncomeLabel(entry)
			end
			if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
				local li = listIndexForBackpackUiRow(idx)
				key.Text = if li then tostring(li) else tostring(idx)
			end
		else
			setSlotIcons(surface, "", false)
			for _, icon in slotIconTargets(surface) do
				icon.AnchorPoint = Vector2.new(0.5, 0.5)
				icon.Position = UDim2.new(0.5, 0, 0.5, 0)
			end
			if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
				rate.Text = ""
			end
			if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
				key.Text = tostring(idx)
			end
		end
		local btn = slotPrimaryButton(row :: GuiObject)
		if btn then
			applyBackpackSlotPanelAppearance(btn, entry ~= nil)
		end
		passthroughChildClicks(surface :: GuiObject)
	end
end

local function requestEquipBestBrainrot()
	if not canUseToolbar then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local ev = folder and folder:FindFirstChild("EquipBestBrainrot")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireServer()
	end
end

local function requestMoveBackpackEntryToHotbar(listIdx: number)
	if not canUseToolbar then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
	if parkEv and parkEv:IsA("RemoteEvent") then
		parkEv:FireServer(listIdx, false)
	end
end

local function requestEquipBrainrotSlot(slotIdx: number, forceEquip: boolean?)
	if not forceEquip and not canUseToolbar then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local ev = folder and folder:FindFirstChild("EquipBrainrotSlot")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireServer(slotIdx, forceEquip == true)
	end
end

local function wireBrainrotBackpackEquips()
	if backpackEquipWired or not backpackContainer then
		return
	end
	backpackEquipWired = true
	for uiRow = 1, MAX_BACKPACK_BRAINROT_SLOTS do
		local row = backpackContainer:FindFirstChild(tostring(uiRow))
		if not row or not row:IsA("GuiObject") then
			continue
		end
		local btn = slotPrimaryButton(row :: GuiObject)
		if btn then
			passthroughChildClicks(btn :: GuiObject)
			styleToolbarSlotButton(btn)
			local scale = getOrAddUIScale(hotbarSlotScaleHost(row :: GuiObject))
			btn.MouseEnter:Connect(function()
				if hotbarDragBulkHover or not canUseToolbar then
					return
				end
				UIInteractionSounds.playHover()
				TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.1 }):Play()
			end)
			btn.MouseLeave:Connect(function()
				if hotbarDragBulkHover then
					return
				end
				TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
			end)
			btn.MouseButton1Down:Connect(function()
				if not canUseToolbar then
					return
				end
				if pendingToolbarDrag then
					return
				end
				local listIdx = listIndexForBackpackUiRow(uiRow)
				local entry = brainrotEntryForBackpackSlot(uiRow)
				if not listIdx or not entry then
					return
				end
				UIInteractionSounds.playClick()
				local tex = (entry.icon ~= "" and entry.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
				activeToolbarDrag = true
				pendingToolbarDrag = {
					kind = "backpack",
					idx = listIdx,
					start = UserInputService:GetMouseLocation(),
					texture = tex,
					rowButton = btn,
					equippedOnDown = false,
				}
			end)
		end
	end
end

local function wireEquipBestButton(backpackFrame: Instance)
	if equipBestWired then
		return
	end
	local frameGui = if backpackFrame:IsA("GuiObject") then backpackFrame :: GuiObject else nil
	if frameGui then
		ensureBackpackChromeVisible(frameGui)
	end
	local otherButtons = backpackFrame:FindFirstChild("OtherButtons") or findBackpackChild(backpackFrame, "OtherButtons")
	local equipBestInst = otherButtons and otherButtons:FindFirstChild("EquipBest")
	if not equipBestInst or not equipBestInst:IsA("GuiObject") then
		warn("[ToolbarController] EquipBest button not found under Backpack.OtherButtons")
		return
	end
	local btn = resolveBackpackActionButton(equipBestInst :: GuiObject)
	if not btn then
		warn("[ToolbarController] EquipBest has no GuiButton")
		return
	end
	equipBestWired = true
	passthroughChildClicks(btn :: GuiObject)
	enableGuiButtonInput(btn)
	UIButtonEffects.wireAccentButton(btn, function()
		requestEquipBestBrainrot()
	end)
end

local function wireBackpackSearch(backpackFrame: Instance)
	if backpackSearchWired then
		return
	end
	local btns = findBackpackChild(backpackFrame, "BackpackButtons")
	local search = btns and btns:FindFirstChild("Search")
	local tb = search and search:FindFirstChild("TextBox")
	if not tb or not tb:IsA("TextBox") then
		return
	end
	backpackSearchWired = true
	tb.Active = true
	tb.ClearTextOnFocus = false
	if search and search:IsA("GuiObject") then
		disableGuiInputCapture(search :: GuiObject)
		local searchFrame = search :: GuiObject
		searchFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				tb:CaptureFocus()
			end
		end)
	end
	local function applySearch()
		backpackSearchText = tb.Text
		refreshBrainrotBackpackUI()
	end
	tb:GetPropertyChangedSignal("Text"):Connect(applySearch)
	tb.FocusLost:Connect(applySearch)
end

local function wireBackpackCloseButton(backpackFrame: Instance)
	if backpackCloseWired then
		return
	end
	local btns = findBackpackChild(backpackFrame, "BackpackButtons")
	local closeInst = btns and btns:FindFirstChild("Close")
	if not closeInst or not closeInst:IsA("GuiObject") then
		return
	end
	local closeBtn: GuiButton? = if closeInst:IsA("GuiButton") then closeInst :: GuiButton else nil
	if not closeBtn then
		closeBtn = slotPrimaryButton(closeInst :: GuiObject)
	end
	if not closeBtn then
		closeBtn = closeInst:FindFirstChildWhichIsA("GuiButton", true)
	end
	if not closeBtn then
		return
	end
	backpackCloseWired = true
	passthroughChildClicks(closeBtn :: GuiObject)
	UIButtonEffects.wireGlistenCloseButton(closeBtn, function()
		setBackpackPanelOpen(false)
	end)
end

local function wireSortCategoryTabs(backpackFrame: Instance)
	local sorts = findBackpackChild(backpackFrame, "SortButtons")
	if not sorts then
		return
	end
	local lastSel: GuiObject? = nil
	local function highlight(tab: GuiObject)
		if lastSel and lastSel ~= tab then
			local prevStroke = lastSel:FindFirstChildWhichIsA("UIStroke", true)
			if prevStroke then
				prevStroke.Transparency = 0.75
			end
		end
		lastSel = tab
		local s = tab:FindFirstChildWhichIsA("UIStroke", true)
		if s then
			s.Transparency = 0
		end
	end
	for _, ch in sorts:GetChildren() do
		if ch:IsA("GuiButton") then
			passthroughChildClicks(ch :: GuiObject)
			enableGuiButtonInput(ch)
			UIButtonEffects.wireScaleButtonAnim(ch, function()
				highlight(ch :: GuiObject)
			end)
		end
	end
	local allTab = sorts:FindFirstChild("All")
	if allTab and allTab:IsA("GuiObject") then
		highlight(allTab :: GuiObject)
	end
end

local selectSlot: (number) -> ()

local function setBrainrotEntriesFromServer(payload: any)
	local entriesSource: any = payload
	local usedOverride: number? = nil
	local maxOverride: number? = nil
	if typeof(payload) == "table" then
		local t = payload :: any
		if typeof(t.entries) == "table" then
			entriesSource = t.entries
			if typeof(t.used) == "number" then
				usedOverride = math.floor(t.used)
			end
			if typeof(t.max) == "number" then
				maxOverride = math.floor(t.max)
			end
			if typeof(t.tuckedSlots) == "table" then
				brainrotParkedInUI = {}
				for _, n in ipairs(t.tuckedSlots :: { any }) do
					if typeof(n) == "number" then
						local ii = math.clamp(math.floor(n), 1, HOTBAR_INVENTORY_SLOTS)
						brainrotParkedInUI[ii] = true
					end
				end
			else
				brainrotParkedInUI = {}
			end
		end
	end
	if typeof(entriesSource) ~= "table" then
		return
	end
	local nextList: { { name: string, icon: string, sourcePath: string, rarity: string?, mutation: string?, level: number?, baseIncome: number? } } = {}
	for _, e in ipairs(entriesSource :: { any }) do
		if typeof(e) == "table" then
			local name = (e :: any).name
			local icon = (e :: any).icon
			local sourcePath = (e :: any).sourcePath
			local rarity = (e :: any).rarity
			local mutation = (e :: any).mutation
			local level = (e :: any).level
			local baseIncome = (e :: any).baseIncome
			if typeof(name) == "string" and typeof(icon) == "string" then
				table.insert(nextList, {
					name = name,
					icon = icon,
					sourcePath = if typeof(sourcePath) == "string" then sourcePath else "",
					rarity = if typeof(rarity) == "string" then rarity else nil,
					mutation = if typeof(mutation) == "string" then mutation else nil,
					level = if typeof(level) == "number" then math.floor(level) else nil,
					baseIncome = if typeof(baseIncome) == "number" then baseIncome else nil,
				})
			end
		end
	end
	brainrotEntries = nextList
	brainrotInventoryUsed = usedOverride or #nextList
	brainrotInventoryMax = maxOverride or DEFAULT_BRAINROT_CAPACITY
	warn(
		"[ToolbarController] inventory sync entries=",
		#nextList,
		"equipSlot=",
		if typeof(payload) == "table" and typeof((payload :: any).equipSlot) == "number"
			then tostring((payload :: any).equipSlot)
			else "nil"
	)
	refreshInventoryHeaderText()
	refreshBrainrotBackpackUI()
	rebuildSlots()
	if canUseToolbar then
		refreshToolbarVisibility()
	end
	if typeof(payload) == "table" then
		local equipSlot = (payload :: any).equipSlot
		if typeof(equipSlot) == "number" then
			pendingAutoEquipSlot = equipSlot
			pendingReturnedBrainrotName = nil
			applyAutoEquipFromSync(equipSlot)
			tryAutoSelectReturnedBrainrot()
		elseif pendingReturnedBrainrotName then
			tryAutoSelectReturnedBrainrot()
		end
	end
end

-- ── Equip from slot ───────────────────────────────────────────────────────────

selectSlot = function(index: number)
	if not canSelectHotbarSlot() then
		return
	end
	if not hotbarSlotHasSelectableContent(index) then
		return
	end

	local hasBrainrotEntry = brainrotEntries[index] ~= nil and not brainrotParkedInUI[index]
	local tool = slotTools[index]
	local hum = getHumanoid()
	if not hum then
		return
	end
	local char = player.Character
	local equipped = char and char:FindFirstChildOfClass("Tool")

	-- Extra tool slot (e.g. lucky block) with no brainrot inventory index.
	if tool and not hasBrainrotEntry then
		if equipped == tool then
			hum:UnequipTools()
			setHotbarSelection(nil, false)
			task.defer(rebuildSlots)
			return
		end
		extraToolSlotByIndex[index] = tool
		setHotbarSelection(index)
		hum:EquipTool(tool)
		task.defer(rebuildSlots)
		return
	end

	if tool and equipped == tool then
		hum:UnequipTools()
		setHotbarSelection(nil)
		return
	end

	if not tool then
		if uiHotbarHighlight == index then
			hum:UnequipTools()
			setHotbarSelection(nil)
			return
		end
		if hasBrainrotEntry then
			if equipped and equipped:IsA("Tool") and equipped:GetAttribute("BrainrotTool") == true then
				local invIdx = equipped:GetAttribute("BrainrotInvIndex")
				if typeof(invIdx) == "number" and math.floor(invIdx) == index and uiHotbarHighlight == index then
					hum:UnequipTools()
					setHotbarSelection(nil)
					return
				end
			end
			setHotbarSelection(index)
			requestEquipBrainrotSlot(index, true)
			task.defer(rebuildSlots)
			task.delay(0.15, rebuildSlots)
			task.delay(0.35, rebuildSlots)
			return
		end
		setHotbarSelection(index)
		hum:UnequipTools()
		return
	end

	setHotbarSelection(index)
	hum:EquipTool(tool)
	task.defer(rebuildSlots)
end

-- After deposit, server sends equipSlot = inventory index of the new brainrot (hotbar 1–9 mirror those indices).
-- Must not use selectSlot here — it toggles off when the server already equipped the matching tool.
applyAutoEquipFromSync = function(equipSlot: number)
	local slot = math.clamp(math.floor(equipSlot), 1, HOTBAR_INVENTORY_SLOTS)
	setHotbarSelection(slot)

	local function tryHoldBrainrot(): boolean
		rebuildSlots()
		local hum = getHumanoid()
		if not hum then
			return false
		end
		local tool = slotTools[slot]
		local char = player.Character
		local equipped = char and char:FindFirstChildOfClass("Tool")
		if tool then
			if equipped ~= tool then
				hum:EquipTool(tool)
			end
			return true
		end
		if brainrotEntries[slot] and not brainrotParkedInUI[slot] then
			requestEquipBrainrotSlot(slot, true)
		end
		return false
	end

	if tryHoldBrainrot() then
		return
	end
	task.defer(tryHoldBrainrot)
	task.delay(0.15, tryHoldBrainrot)
end

local HOTBAR_KEY_ACTION = "ToolbarHotbarNumberKeys"

local function bindToolbarHotbarKeybinds()
	ContextActionService:UnbindAction(HOTBAR_KEY_ACTION)
	ContextActionService:BindActionAtPriority(
		HOTBAR_KEY_ACTION,
		function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if UserInputService:GetFocusedTextBox() ~= nil then
				return Enum.ContextActionResult.Pass
			end
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return Enum.ContextActionResult.Pass
			end
			local idx = KEY_TO_SLOT[input.KeyCode]
			if not idx then
				return Enum.ContextActionResult.Pass
			end
			if not canSelectHotbarSlot() then
				return Enum.ContextActionResult.Pass
			end
			if not hotbarSlotHasSelectableContent(idx) then
				return Enum.ContextActionResult.Pass
			end
			UIInteractionSounds.playHover()
			selectSlot(idx)
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
		Enum.KeyCode.Six,
		Enum.KeyCode.Seven,
		Enum.KeyCode.Eight,
		Enum.KeyCode.Nine
	)
end

-- ── Character wiring ──────────────────────────────────────────────────────────

local function wireCharacter(character: Model)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(rebuildSlots)
		end
	end)
	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(rebuildSlots)
		end
	end)
	task.defer(rebuildSlots)
end

-- ── Init ──────────────────────────────────────────────────────────────────────

local ToolbarController = {}

function ToolbarController.prepareEarly()
	disableDefaultRobloxBackpack()
	applyToolbarInitialHiddenState()
end

function ToolbarController.init()
	ensureDefaultRobloxBackpackStaysOff()
	task.defer(ensureDefaultRobloxBackpackStaysOff)

	toolbar.Visible = false
	applyToolbarInitialHiddenState()

	getOrAddUIScale(hotbar).Scale = 1

	ensureHotbarListLayout()

	-- Collect slot references (named "1" through "9" inside Hotbar)
	for i = 1, 9 do
		local slot = hotbar:FindFirstChild(tostring(i))
		if slot then
			slots[i] = slot
		else
			warn("[ToolbarController] Slot '" .. i .. "' not found in Hotbar")
		end
	end

	ensureHotbarLayoutPassthrough()

	DropTargets.configure({
		playerGui = playerGui,
		hotbar = hotbar,
		slots = slots,
		hotbarInventorySlots = HOTBAR_INVENTORY_SLOTS,
		maxBackpackSlots = MAX_BACKPACK_BRAINROT_SLOTS,
		getDragGhostGui = function()
			return dragGhostGui
		end,
		getPendingToolbarDrag = function()
			return pendingToolbarDrag
		end,
		getHotbarDragBulkHover = function()
			return hotbarDragBulkHover
		end,
		getBackpackContainer = function()
			return backpackContainer
		end,
		getBackpackGuiFrame = function()
			return backpackGuiFrame
		end,
		getBackpackFrameRef = function()
			return backpackFrameRef
		end,
		getToggleBackpackRef = function()
			return toggleBackpackRef
		end,
		getIsBackpackPanelOpen = function()
			return isBackpackPanelOpen
		end,
		toolSlotSurface = toolSlotSurface,
	})

	-- Tap / hover: nested `Button` (SideUI.Toolbar.Hotbar[n].Button) or slot is the button.
	-- Mobile: only `Activated` selects/equips; parent frames must not capture touch input.
	for i, slot in ipairs(slots) do
		if slot:IsA("GuiObject") then
			(slot :: GuiObject).LayoutOrder = i
		end
		local btn = resolveHotbarSlotButton(slot)
		if btn then
			configureHotbarSlotInput(slot, btn)
			styleToolbarSlotButton(btn)
			local function onHotbarSlotTapSelect()
				if not canSelectHotbarSlot() then
					return
				end
				if dragSuppressedToolbarClick then
					dragSuppressedToolbarClick = false
					return
				end
				if not hotbarSlotHasSelectableContent(i) then
					return
				end
				UIInteractionSounds.playClick()
				selectSlot(i)
			end
			btn.Activated:Connect(onHotbarSlotTapSelect)
			-- PC-only drag start; touch taps must not enter the drag pipeline (blocks Activated on some devices).
			btn.MouseButton1Down:Connect(function()
				if not canUseToolbar then
					return
				end
				if DropTargets.isTouchPointerInput() then
					return
				end
				local tex = hotbarSlotDragTexture(i)
				if not tex then
					return
				end
				UIInteractionSounds.playClick()
				local isExtraTool = not (brainrotEntries[i] and not brainrotParkedInUI[i])
				local tool = slotTools[i]
				local equippedOnDown = false
				if tool and player.Character and tool.Parent == player.Character then
					equippedOnDown = true
				end
				activeToolbarDrag = true
				pendingToolbarDrag = {
					kind = "hotbar",
					idx = i,
					start = UserInputService:GetMouseLocation(),
					texture = tex,
					rowButton = nil,
					isExtraTool = isExtraTool,
					equippedOnDown = equippedOnDown,
				}
			end)
		else
			warn("[ToolbarController] Hotbar slot '" .. tostring(i) .. "' has no TextButton/ImageButton for tap input")
		end

		local scale = getOrAddUIScale(hotbarSlotScaleHost(slot))
		local hoverTarget: GuiObject = (btn and (btn :: GuiObject)) or slot
		hoverTarget.MouseEnter:Connect(function()
			if hotbarDragBulkHover then
				return
			end
			UIInteractionSounds.playHover()
			TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.12 }):Play()
		end)
		hoverTarget.MouseLeave:Connect(function()
			if hotbarDragBulkHover then
				return
			end
			TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
		end)
	end

	resetAllSlotsToIdle()
	bindToolbarHotbarKeybinds()

	-- Backpack changes
	local backpack = player:WaitForChild("Backpack")
	backpack.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then task.defer(rebuildSlots) end
	end)
	backpack.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then task.defer(rebuildSlots) end
	end)

	-- Character spawning
	player.CharacterAdded:Connect(function(char: Model)
		wireCharacter(char)
		task.defer(pollSafezonePresence)
	end)
	if player.Character then
		wireCharacter(player.Character)
	end

	canUseToolbar = isCharacterInToolbarAccessZone(player.Character)
	refreshToolbarVisibility()
	if canUseToolbar then
		tryAutoSelectReturnedBrainrot()
	end

	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(function()
		if not canUseToolbar then
			return
		end
		if CarryGate.usedSlots() > 0 then
			return
		end
		tryAutoSelectReturnedBrainrot()
	end)

	RunService.Heartbeat:Connect(function(dt)
		safezonePollAccum += dt
		if safezonePollAccum < SAFEZONE_POLL_INTERVAL then
			return
		end
		safezonePollAccum = 0
		pollSafezonePresence()
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 120)
		if map then
			map.ChildAdded:Connect(function(ch)
				if ch.Name == "Spawn And Bases" then
					SafezoneUtil.invalidateCache()
					pollSafezonePresence()
				end
			end)
			local spawnBases = map:WaitForChild("Spawn And Bases", 60)
			if spawnBases then
				spawnBases.DescendantAdded:Connect(function(desc)
					if not desc:IsA("BasePart") then
						return
					end
					if desc.Name == "Reddie" or desc.Name == "RedWall" or desc.Name == "RedPart"
						or desc.Name == "Raddie" or desc.Name == "SafezoneHitbox" or desc.Name == "SafeZoneHitbox" then
						SafezoneUtil.invalidateCache()
						pollSafezonePresence()
					end
				end)
			end
			SafezoneUtil.invalidateCache()
			pollSafezonePresence()
		end
	end)

	-- ToggleBackpack + brainrot backpack grid (Backpack.Container["1"]..["19"])
	wireToggleBackpackIcon()
	local toggleBtn = toolbar:FindFirstChild("ToggleBackpack") or hotbar:FindFirstChild("ToggleBackpack")
	if toggleBtn and toggleBtn:IsA("GuiObject") then
		if toggleBackpackIconRef then
			(toggleBtn :: GuiObject).Visible = false
		else
			toggleBackpackRef = toggleBtn :: GuiObject
		end
	end
	local backpackFrame = toolbar:FindFirstChild("Backpack")
	if backpackFrame then
		backpackContainer = backpackFrame:FindFirstChild("Container")
		if backpackFrame:IsA("GuiObject") then
			local bf = backpackFrame :: GuiObject
			backpackGuiFrame = bf
			backpackFrameRef = bf
			ensureBackpackFrameOutline(bf)
			ensureBackpackFadeRoot(bf)
			ensureBackpackChromeVisible(bf)
		end
		backpackHeaderLabel = resolveBackpackHeaderLabel(backpackFrame)
		refreshInventoryHeaderText()
		if backpackContainer then
			for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
				local row = backpackContainer:FindFirstChild(tostring(idx))
				if row and row:IsA("GuiObject") then
					local btn = slotPrimaryButton(row :: GuiObject)
					if btn then
						styleToolbarSlotButton(btn)
					end
				end
			end
		end
		task.defer(refreshBrainrotBackpackUI)
		wireBrainrotBackpackEquips()
		wireEquipBestButton(backpackFrame)
		wireBackpackSearch(backpackFrame)
		wireBackpackCloseButton(backpackFrame)
		wireSortCategoryTabs(backpackFrame)
		isBackpackPanelOpen = false
		if backpackFrame:IsA("GuiObject") then
			(backpackFrame :: GuiObject).Visible = false
		end
	end
	if toggleBtn and toggleBtn:IsA("GuiButton") and not toggleBackpackIconRef then
		toggleBtn.MouseEnter:Connect(function()
			UIInteractionSounds.playHover()
		end)
		toggleBtn.MouseButton1Down:Connect(function()
			UIInteractionSounds.playClick()
		end)
		toggleBtn.Activated:Connect(toggleBackpackPanel)
	end

	task.defer(function()
		if hotbar:IsA("GuiObject") then
			(hotbar :: GuiObject).AutomaticSize = Enum.AutomaticSize.None
		end
		applyToolbarHorizontalCenterOnce()
		updateHotbarSlotVisibility()
	end)

	-- `(`)` key opens / closes the brainrot backpack (matches the on-screen prompt text).
	if backpackFrame then
		ContextActionService:BindActionAtPriority(
			"ToolbarOpenBackpack",
			function(_, state, _)
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Pass
				end
				if UserInputService:GetFocusedTextBox() ~= nil then
					return Enum.ContextActionResult.Pass
				end
				if not canUseToolbar then
					return Enum.ContextActionResult.Sink
				end
				setBackpackPanelOpen(not isBackpackPanelOpen)
				UIInteractionSounds.playClick()
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.Backquote
		)
	end

	UserInputService.InputChanged:Connect(function(input, _gp)
		if not toolbarInputAllowed() then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local pnd = pendingToolbarDrag
		if not pnd or not pnd.texture then
			return
		end
		local m = UserInputService:GetMouseLocation()
		if input.UserInputType == Enum.UserInputType.Touch then
			m = Vector2.new(input.Position.X, input.Position.Y)
		end
		if not dragGhostImage then
			if (m - pnd.start).Magnitude < DRAG_GHOST_THRESHOLD_PX then
				return
			end
			if pnd.kind == "backpack" then
				if not pnd.rowButton then
					return
				end
				local ownerRow = DropTargets.ancestorBackpackRowIndexFromGuiObject(pnd.rowButton :: GuiObject)
				if not ownerRow then
					return
				end
				local allowGhost = input.UserInputType == Enum.UserInputType.Touch
					or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
				local ok, hitsOrErr = pcall(function()
					return playerGui:GetGuiObjectsAtPosition(m.X, m.Y)
				end)
				if ok and typeof(hitsOrErr) == "table" then
					for _, hit in hitsOrErr :: { Instance } do
						if dragGhostGui and hit:IsDescendantOf(dragGhostGui) then
							continue
						end
						if not hit:IsA("GuiObject") then
							continue
						end
						local rowUnder = DropTargets.ancestorBackpackRowIndexFromGuiObject(hit)
						if rowUnder then
							if rowUnder == ownerRow then
								allowGhost = true
							else
								allowGhost = false
							end
							break
						end
					end
				end
				if not allowGhost then
					return
				end
			end
			startDragGhost(pnd.texture, m)
			local probeEnd = m
			local probeWindow = DropTargets.screenPointWithGuiInset(probeEnd)
			local ghostCenter = if dragGhostImage
				then dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
				else nil
			local overHotbar, overBackpack, overBackpackPanel = DropTargets.probeDragHoverTargets(
				probeWindow,
				probeEnd,
				ghostCenter,
				nil
			)
			updateDragHoverTargets(overHotbar, overBackpack, overBackpackPanel)
			return
		end
		local rawEnd = UserInputService:GetMouseLocation()
		if input.UserInputType == Enum.UserInputType.Touch then
			rawEnd = Vector2.new(input.Position.X, input.Position.Y)
		end
		local mouseWindow = DropTargets.screenPointWithGuiInset(rawEnd)
		local ghostCenter: Vector2? = nil
		if dragGhostImage then
			ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
		end
		local ghostViewport = if ghostCenter
			then ghostCenter - Vector2.new(GuiService:GetGuiInset().X, GuiService:GetGuiInset().Y)
			else nil
		local overHotbar, overBackpack, overBackpackPanel = DropTargets.probeDragHoverTargets(
			mouseWindow,
			rawEnd,
			ghostCenter,
			ghostViewport
		)
		if pnd.kind == "hotbar" and not isBackpackPanelOpen and overBackpack then
			setBackpackPanelOpen(true)
		end
		updateDragHoverTargets(overHotbar, overBackpack, overBackpackPanel)
	end)

	UserInputService.InputEnded:Connect(function(input, _gp)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not toolbarInputAllowed() then
			activeToolbarDrag = false
			pendingToolbarDrag = nil
			clearDragGhost()
			return
		end
		local pnd = pendingToolbarDrag
		pendingToolbarDrag = nil
		activeToolbarDrag = false
		if not pnd then
			clearDragGhost()
			return
		end
		local rawEnd = UserInputService:GetMouseLocation()
		if input.UserInputType == Enum.UserInputType.Touch then
			rawEnd = Vector2.new(input.Position.X, input.Position.Y)
		end
		if (rawEnd - pnd.start).Magnitude < DRAG_THRESHOLD_PX then
			if pnd.kind == "backpack" then
				requestMoveBackpackEntryToHotbar(pnd.idx)
			end
			clearDragGhost()
			return
		end
		local mouseWindow = DropTargets.screenPointWithGuiInset(rawEnd)
		local ghostCenter: Vector2? = nil
		if dragGhostImage then
			ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
		end
		local insetProbe = GuiService:GetGuiInset()
		local ghostViewport = if ghostCenter then ghostCenter - Vector2.new(insetProbe.X, insetProbe.Y) else nil
		local destBackpackRow = DropTargets.backpackRowIndexFromDropProbes(rawEnd, mouseWindow, ghostViewport)
		clearDragGhost()
		dragSuppressedToolbarClick = true

		local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
		local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
		if not parkEv or not parkEv:IsA("RemoteEvent") then
			return
		end

		local overBackpack = DropTargets.pointOverBackpackDropTarget(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and DropTargets.pointOverBackpackDropTarget(ghostCenter, rawEnd))
			or (ghostViewport ~= nil and DropTargets.pointOverBackpackFromGuiHitScan(ghostViewport))
		local targetHotbar: number? = nil
		if not overBackpack then
			targetHotbar = DropTargets.hotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter)
		end
		local overHotbar = targetHotbar ~= nil
			or DropTargets.pointOverHotbarDropZoneProbes(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and DropTargets.pointOverHotbarDropZoneProbes(ghostCenter, rawEnd))
			or (ghostViewport ~= nil and DropTargets.pointOverHotbarFromGuiHitScan(ghostViewport))

		if pnd.kind == "hotbar" then
			if pnd.isExtraTool then
				if overBackpack then
					setBackpackPanelOpen(true)
					local hum = getHumanoid()
					local tool = extraToolSlotByIndex[pnd.idx] or slotTools[pnd.idx]
					if hum and tool and tool.Parent == player.Character then
						hum:UnequipTools()
					end
					task.defer(rebuildSlots)
					UIInteractionSounds.playClick()
				elseif targetHotbar
					and targetHotbar ~= pnd.idx
					and brainrotEntries[targetHotbar] == nil
					and brainrotParkedInUI[targetHotbar] ~= true
				then
					local tool = extraToolSlotByIndex[pnd.idx] or slotTools[pnd.idx]
					local other = extraToolSlotByIndex[targetHotbar]
					if tool then
						extraToolSlotByIndex[targetHotbar] = tool
					else
						extraToolSlotByIndex[targetHotbar] = nil
					end
					if other then
						extraToolSlotByIndex[pnd.idx] = other
					else
						extraToolSlotByIndex[pnd.idx] = nil
					end
					task.defer(rebuildSlots)
					UIInteractionSounds.playClick()
				end
				return
			end
			local hasEntry = brainrotEntries[pnd.idx] and not brainrotParkedInUI[pnd.idx]
			if not hasEntry then
				return
			end
			if overBackpack then
				-- Hotbar → backpack panel: tuck (server sync updates UI).
				setBackpackPanelOpen(true);
				(parkEv :: RemoteEvent):FireServer(pnd.idx, true)
				UIInteractionSounds.playClick()
			elseif targetHotbar and targetHotbar ~= pnd.idx then
				-- Hotbar → hotbar swap.
				(parkEv :: RemoteEvent):FireServer(pnd.idx, false, targetHotbar)
				UIInteractionSounds.playClick()
			end
		elseif pnd.kind == "backpack" then
			local entry = brainrotEntries[pnd.idx]
			if not entry then
				return
			end
			if overHotbar then
				-- Backpack → hotbar: server assigns lowest free slot 1..9 (no slot memory).
				(parkEv :: RemoteEvent):FireServer(pnd.idx, false)
				UIInteractionSounds.playClick()
			elseif overBackpack and destBackpackRow then
				local destListIdx = listIndexForBackpackUiRow(destBackpackRow)
				if not destListIdx then
					destListIdx = #brainrotEntries + 1
				end
				if destListIdx ~= pnd.idx then
					-- Insert at server list index (pushes existing entries to the right; no swap/replace).
					(parkEv :: RemoteEvent):FireServer(pnd.idx, false, nil, destListIdx)
					UIInteractionSounds.playClick()
				end
			end
		end
	end)

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("BushRemotes", 45)
		if not folder then
			return
		end
		local sync = folder:WaitForChild("BrainrotInventorySync", 20)
		local getFn = folder:WaitForChild("GetBrainrotInventory", 20)
		if sync and sync:IsA("RemoteEvent") then
			sync.OnClientEvent:Connect(setBrainrotEntriesFromServer)
		end
		if getFn and getFn:IsA("RemoteFunction") then
			local ok, res = pcall(function()
				return (getFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(res) == "table" then
				setBrainrotEntriesFromServer(res)
			end
		end
	end)
end

return ToolbarController