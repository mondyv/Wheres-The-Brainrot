--[[
	ToolbarController
	Replaces the default Roblox backpack/hotbar with the custom Toolbar frame.

	Expected SideUI hierarchy:
	  SideUI
	  └── Toolbar
	      ├── Hotbar
	      │   └── 1 .. 9   (slot frames with nested Button)
	      ├── ToggleBackpack
	      └── Backpack  (optional expanded view)

	Hotbar slots may use nested `Button` (e.g. Hotbar["1"].Button.Icon).
	Brainrot pickups: tuck/untuck via drag; ghost drag; search; backpack frame outline + open/close tweens.
	Backpack UI rows 1..19 show stashed items in dense order (tucked hotbar slots + list indices >9); row labels use server list index.
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
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local player    = Players.LocalPlayer

if not player.Character then
	player.CharacterAdded:Wait()
end

local playerGui = player.PlayerGui
local mainGui   = playerGui:WaitForChild("Main")
local sideUI    = mainGui:WaitForChild("SideUI")
local toolbar   = sideUI:WaitForChild("Toolbar")
local hotbar    = toolbar:WaitForChild("Hotbar")

-- ── Tween configs ─────────────────────────────────────────────────────────────

local SHOW_TWEEN      = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN      = TweenInfo.new(0.2,  Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIGHLIGHT_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BACKPACK_OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local BACKPACK_CLOSE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local DRAG_GHOST_SMOOTH = 0.55 -- per-frame lerp toward cursor (higher = snappier follow)

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
local activeSlot: number?    = nil
local uiHotbarHighlight: number? = nil -- nil = no slot ring (toggle off); otherwise mirrors selection / equip
local toolbarShown: boolean  = false
local playerInSafezone: boolean = false
local safezonePollAccum = 0.0
local SAFEZONE_POLL_INTERVAL = 0.12

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

local brainrotParkedInUI: { [number]: boolean } = {}
-- UI backpack rows 1..MAX map through this → server list index (tucked + slot >9) so stashed pets fill consecutive rows.
local backpackDisplayOrder: { number } = {}
local pendingToolbarDrag: {
	kind: string,
	idx: number,
	start: Vector2,
	texture: string?,
	rowButton: GuiButton?,
}? = nil
local dragSuppressedToolbarClick = false
local DRAG_THRESHOLD_PX = 14
local DRAG_GHOST_THRESHOLD_PX = 6
-- Shared scale for "whole hotbar" hover while dragging toward slots (slightly subtler than per-slot hover).
local HOTBAR_BULK_DRAG_HOVER_SCALE = 1.06

local backpackSearchText: string = ""

local dragGhostGui: ScreenGui? = nil
local dragGhostImage: ImageLabel? = nil
local dragGhostSmoothPos: Vector2? = nil
local dragGhostConn: RBXScriptConnection? = nil

local backpackFrameRef: GuiObject? = nil
local backpackSearchWired = false
local backpackCloseWired = false
local isBackpackPanelOpen = false

-- While dragging toward the hotbar (from backpack, or from hotbar back over the bar), all slots share one hover scale.
local hotbarDragBulkHover = false

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

local function toolSlotSurface(slot: GuiObject): GuiObject
	local b = slotPrimaryButton(slot)
	return (b and (b :: GuiObject)) or slot
end

-- UIScale target: the whole slot frame, so hover/selection grows the entire bar.
local function hotbarSlotScaleHost(slot: GuiObject): Instance
	return slot
end

-- Slot `Button` is often an ImageButton with a light template art layer; only tint (never swap Image id).
local SLOT_BUTTON_IMAGE_TINT = Color3.fromRGB(58, 60, 72)

local function styleToolbarSlotButton(btn: GuiButton)
	if btn:IsA("ImageButton") then
		btn.AutoButtonColor = false
		btn.ImageColor3 = SLOT_BUTTON_IMAGE_TINT
	end
	local icon = btn:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.ScaleType = Enum.ScaleType.Fit
	end
end

-- Icon / Rate / Key steal mouse hits unless they are non-interactive.
local function passthroughChildClicks(root: GuiObject)
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d ~= root then
			d.Active = false
		end
	end
end

local function screenPointInGui(gui: GuiObject, screen: Vector2): boolean
	local p = gui.AbsolutePosition
	local s = gui.AbsoluteSize
	if s.X <= 0 or s.Y <= 0 then
		return false
	end
	return screen.X >= p.X and screen.X <= p.X + s.X and screen.Y >= p.Y and screen.Y <= p.Y + s.Y
end

local function screenPointInGuiWithPad(gui: GuiObject, screen: Vector2, pad: number): boolean
	local p = gui.AbsolutePosition
	local s = gui.AbsoluteSize
	if s.X <= 0 or s.Y <= 0 then
		return false
	end
	local padv = Vector2.new(pad, pad)
	p = p - padv
	s = s + padv * 2
	return screen.X >= p.X and screen.X <= p.X + s.X and screen.Y >= p.Y and screen.Y <= p.Y + s.Y
end

local function hotbarDragDropPadActive(): boolean
	if hotbarDragBulkHover then
		return true
	end
	if dragGhostGui and pendingToolbarDrag and pendingToolbarDrag.kind == "hotbar" then
		return true
	end
	return false
end

local function screenPointInHotbarSurface(surface: GuiObject, screen: Vector2): boolean
	local pad = if hotbarDragDropPadActive() then 14 else 0
	if pad > 0 then
		return screenPointInGuiWithPad(surface, screen, pad)
	end
	return screenPointInGui(surface, screen)
end

-- Mouse / touch from UserInputService is in viewport space; GuiObject.Absolute* uses full window (see GuiInset).
local function screenPointWithGuiInset(screen: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return screen + Vector2.new(inset.X, inset.Y)
end

-- Which hotbar slot (1–9) is under this screen point, if any. Later slots win if rects overlap (Z-order).
-- Always hit-test the full slot surface (the nested Button), not the Icon — otherwise drops land "outside"
-- the icon on the slot chrome and backpack → hotbar never registers.
local function hotbarSlotIndexUnderPoint(screen: Vector2): number?
	for si = HOTBAR_INVENTORY_SLOTS, 1, -1 do
		local slot = slots[si]
		if not slot or not slot.Visible then
			continue
		end
		local surface = toolSlotSurface(slot)
		if screenPointInHotbarSurface(surface, screen) then
			return si
		end
	end
	return nil
end

-- Uses engine hit-testing in viewport space (same family as GetMouseLocation). Resolves hotbar slot even when
-- manual AbsolutePosition math disagrees with the mouse because different ScreenGuis use different GuiInset modes.
local function ancestorHotbarSlotIndexFromGuiObject(inst: Instance): number?
	local w: Instance? = inst
	while w and w ~= playerGui do
		if w.Parent == hotbar then
			local n = tonumber(w.Name)
			if n and n >= 1 and n <= HOTBAR_INVENTORY_SLOTS then
				return n
			end
		end
		w = w.Parent
	end
	return nil
end

local function hotbarSlotIndexFromGuiHitScan(rawViewport: Vector2): number?
	local ok, hitsOrErr = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(rawViewport.X, rawViewport.Y)
	end)
	if not ok or typeof(hitsOrErr) ~= "table" then
		return nil
	end
	for _, hit in hitsOrErr :: { Instance } do
		if dragGhostGui and hit:IsDescendantOf(dragGhostGui) then
			continue
		end
		local idx = ancestorHotbarSlotIndexFromGuiObject(hit)
		if idx then
			return idx
		end
	end
	return nil
end

local function guiInstanceIsUnder(instance: Instance, potentialAncestor: Instance): boolean
	local w: Instance? = instance
	while w do
		if w == potentialAncestor then
			return true
		end
		w = w.Parent
	end
	return false
end

local function pointOverHotbarFromGuiHitScan(rawViewport: Vector2): boolean
	local ok, hitsOrErr = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(rawViewport.X, rawViewport.Y)
	end)
	if not ok or typeof(hitsOrErr) ~= "table" then
		return false
	end
	for _, hit in hitsOrErr :: { Instance } do
		if dragGhostGui and hit:IsDescendantOf(dragGhostGui) then
			continue
		end
		if hit:IsA("GuiObject") and guiInstanceIsUnder(hit, hotbar) then
			return true
		end
	end
	return false
end

-- Try several points: window-space mouse (matches most GuiObject.AbsolutePosition), ghost center, raw viewport.
local function hotbarSlotIndexFromDropProbes(mouseWindow: Vector2, rawViewport: Vector2, ghostCenter: Vector2?): number?
	local inset = GuiService:GetGuiInset()
	local insetVec = Vector2.new(inset.X, inset.Y)

	local guiFirst = hotbarSlotIndexFromGuiHitScan(rawViewport)
	if guiFirst then
		return guiFirst
	end
	if ghostCenter then
		local ghostAsViewport = ghostCenter - insetVec
		local g2 = hotbarSlotIndexFromGuiHitScan(ghostAsViewport)
		if g2 then
			return g2
		end
	end

	local probes: { Vector2 } = { mouseWindow, screenPointWithGuiInset(rawViewport), rawViewport }
	if ghostCenter then
		table.insert(probes, ghostCenter)
	end
	for _, pt in probes do
		local hit = hotbarSlotIndexUnderPoint(pt)
		if hit then
			return hit
		end
	end
	return nil
end

-- Hit test for "dropped anywhere on hotbar" (parent + slots).
local function pointOverHotbarDropZoneOne(screen: Vector2): boolean
	if screenPointInHotbarSurface(hotbar :: GuiObject, screen) then
		return true
	end
	for i = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[i]
		if slot then
			local surface = toolSlotSurface(slot)
			if screenPointInHotbarSurface(surface, screen) then
				return true
			end
		end
	end
	return false
end

local function pointOverHotbarDropZoneProbes(dropPoint: Vector2, rawViewport: Vector2): boolean
	return pointOverHotbarDropZoneOne(dropPoint)
		or pointOverHotbarDropZoneOne(screenPointWithGuiInset(rawViewport))
		or pointOverHotbarFromGuiHitScan(rawViewport)
end

local function pointOverBackpackProbes(dropPoint: Vector2, rawViewport: Vector2): boolean
	if not backpackGuiFrame then
		return false
	end
	local frame = backpackGuiFrame :: GuiObject
	return screenPointInGui(frame, dropPoint) or screenPointInGui(frame, screenPointWithGuiInset(rawViewport))
end

local function ancestorBackpackRowIndexFromGuiObject(inst: Instance): number?
	local cont = backpackContainer
	if not cont then
		return nil
	end
	local w: Instance? = inst
	while w and w ~= playerGui do
		if w.Parent == cont then
			local n = tonumber(w.Name)
			if n and n >= 1 and n <= MAX_BACKPACK_BRAINROT_SLOTS then
				return n
			end
		end
		w = w.Parent
	end
	return nil
end

local function backpackRowIndexFromDropProbes(rawViewport: Vector2, mouseWindow: Vector2, ghostViewport: Vector2?): number?
	local probes: { Vector2 } = { rawViewport, mouseWindow }
	if ghostViewport then
		table.insert(probes, ghostViewport)
	end
	for _, pt in probes do
		local ok, hitsOrErr = pcall(function()
			return playerGui:GetGuiObjectsAtPosition(pt.X, pt.Y)
		end)
		if not ok or typeof(hitsOrErr) ~= "table" then
			continue
		end
		for _, hit in hitsOrErr :: { Instance } do
			if dragGhostGui and hit:IsDescendantOf(dragGhostGui) then
				continue
			end
			local slotIdx = ancestorBackpackRowIndexFromGuiObject(hit)
			if slotIdx then
				return slotIdx
			end
		end
	end
	return nil
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

local function resetHotbarSlotHoverScalesAfterDrag()
	hotbarDragBulkHover = false
	for si = 1, HOTBAR_INVENTORY_SLOTS do
		local slot = slots[si]
		if not slot then
			continue
		end
		local sc = getOrAddUIScale(hotbarSlotScaleHost(slot) :: GuiObject)
		local sel = uiHotbarHighlight
		local baseScale = if sel == si then 1.08 else 1.0
		TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = baseScale }):Play()
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

local function resolveBackpackHeaderLabel(backpackFrame: Instance): Instance?
	local cat = backpackFrame:FindFirstChild("SortCatagory") or backpackFrame:FindFirstChild("SortCategory")
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
	if not backpackFrameRef then
		return
	end
	isBackpackPanelOpen = open
	local f = backpackFrameRef
	if open then
		f.Visible = true
		local sc = getOrAddUIScale(f :: Instance)
		sc.Scale = 0.92
		TweenService:Create(sc, BACKPACK_OPEN_TWEEN, { Scale = 1 }):Play()
		if backpackContainer and backpackContainer:IsA("GuiObject") then
			local csc = getOrAddUIScale(backpackContainer :: Instance)
			csc.Scale = 0.96
			TweenService:Create(csc, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	else
		local sc = getOrAddUIScale(f :: Instance)
		local tw = TweenService:Create(sc, BACKPACK_CLOSE_TWEEN, { Scale = 0.92 })
		tw.Completed:Once(function()
			if not isBackpackPanelOpen then
				f.Visible = false
			end
		end)
		tw:Play()
	end
end

local function showToolbar()
	if toolbarShown then return end
	toolbarShown   = true
	toolbar.Visible = true
	local scale   = getOrAddUIScale(toolbar)
	scale.Scale   = 0.8
	TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 }):Play()
end

local function hideToolbar()
	if not toolbarShown then return end
	toolbarShown = false
	local scale  = getOrAddUIScale(toolbar)
	local t = TweenService:Create(scale, HIDE_TWEEN, { Scale = 0.8 })
	t.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed and not toolbarShown then
			toolbar.Visible = false
		end
	end)
	t:Play()
end

local function refreshToolbarVisibility()
	if playerInSafezone then
		showToolbar()
	else
		hideToolbar()
	end
end

local deselectAllHotbarSlots: () -> ()

local function onSafezonePresenceChanged(inZone: boolean)
	if playerInSafezone == inZone then
		return
	end
	playerInSafezone = inZone
	if not inZone then
		setBackpackPanelOpen(false)
		clearDragGhost()
		pendingToolbarDrag = nil
		deselectAllHotbarSlots()
	end
	refreshToolbarVisibility()
end

local function pollSafezonePresence()
	local char = player.Character
	onSafezonePresenceChanged(SafezoneUtil.isCharacterInSafezone(char))
end

-- ── Slot highlight ────────────────────────────────────────────────────────────

-- Selection = UIStroke only. Never touch the slot's own Image / ImageColor3 (that's the slot art designed in Studio).
local SLOT_STROKE_SELECTED = 0
local SLOT_STROKE_IDLE = 0.6

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
	local slot = slots[index]
	if not slot then
		return
	end
	local btn = slotPrimaryButton(slot)
	if btn then
		applyButtonSelectionStyle(btn :: GuiObject, lit)
	end
	local scale = getOrAddUIScale(hotbarSlotScaleHost(slot))
	TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = if lit then 1.08 else 1.0 }):Play()
	local sel = slot:FindFirstChild("Selection", true) or slot:FindFirstChild("Highlight", true)
	if sel and sel:IsA("GuiObject") then
		TweenService:Create(sel, HIGHLIGHT_TWEEN, {
			BackgroundTransparency = lit and 0 or 1,
		}):Play()
	end
end

local function resetAllSlotsToIdle()
	for _, slot in ipairs(slots) do
		local btn = slotPrimaryButton(slot)
		if btn then
			applyButtonSelectionStyle(btn :: GuiObject, false)
		end
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
	for si = 1, #slots do
		setSlotHighlight(si, false)
		local slot = slots[si]
		if slot then
			local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
			sc.Scale = 1
		end
	end
	resetAllSlotsToIdle()
end

-- ── Slot icon update ──────────────────────────────────────────────────────────

local function refreshSlotVisual(index: number)
	local slot = slots[index]
	if not slot then
		return
	end

	local surface = toolSlotSurface(slot)
	local icon = surface:FindFirstChild("Icon") or surface:FindFirstChildOfClass("ImageLabel")
	-- Do not use FindFirstChildOfClass("TextLabel") — it matches `Rate` before `Key` and leaves $10/s stuck on screen.
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
		if icon and icon:IsA("ImageLabel") then
			icon.ScaleType = Enum.ScaleType.Fit
			icon.BackgroundTransparency = 1
			local tex = (tool :: any).TextureId
			if entryForTool and entryForTool.icon ~= "" then
				tex = entryForTool.icon
			end
			icon.Image = (tex and tex ~= "") and tex or "rbxasset://textures/ui/GuiImagePlaceholder.png"
			icon.Visible = true
		end
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = if entryForTool then entryForTool.name else tool.Name
		end
	elseif brainrotParkedInUI[index] == true then
		if icon and icon:IsA("ImageLabel") then
			icon.ScaleType = Enum.ScaleType.Fit
			icon.BackgroundTransparency = 1
			icon.Image = ""
			icon.Visible = false
		end
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = ""
		end
	elseif brainrotEntries[index] ~= nil then
		local e = brainrotEntries[index] :: { name: string, icon: string, sourcePath: string }
		if icon and icon:IsA("ImageLabel") then
			icon.ScaleType = Enum.ScaleType.Fit
			icon.BackgroundTransparency = 1
			icon.Image = (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
			icon.Visible = true
		end
		if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
			keyLabel.Text = tostring(index)
		end
		if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
			rate.Text = e.name
		end
	else
		if icon and icon:IsA("ImageLabel") then
			icon.ScaleType = Enum.ScaleType.Fit
			icon.BackgroundTransparency = 1
			icon.Image = ""
			icon.Visible = false
		end
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
	return brainrotEntries[index] ~= nil
end

local hotbarListLayout: UIListLayout? = nil

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

local function updateHotbarSlotVisibility()
	ensureHotbarListLayout()
	for i = 1, #slots do
		local slot = slots[i]
		if slot then
			slot.Visible = hotbarSlotIsOccupied(i)
		end
	end
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

	-- Any remaining empty slots: non-brainrot tools, or legacy brainrot tools without BrainrotInvIndex.
	local extras: { Tool } = {}
	if backpack then
		for _, item in ipairs(backpack:GetChildren()) do
			if item:IsA("Tool") then
				if item:GetAttribute("BrainrotTool") ~= true then
					table.insert(extras, item :: Tool)
				else
					local invIdx = item:GetAttribute("BrainrotInvIndex")
					if typeof(invIdx) ~= "number" then
						table.insert(extras, item :: Tool)
					end
				end
			end
		end
	end
	local ei = 1
	for i = 1, maxHotbar do
		if slotTools[i] == nil and not brainrotParkedInUI[i] and extras[ei] then
			slotTools[i] = extras[ei]
			ei += 1
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
	for i = 1, #slots do
		setSlotHighlight(i, uiHotbarHighlight ~= nil and i == uiHotbarHighlight)
	end

	refreshToolbarVisibility()
end

local function refreshBrainrotBackpackUI()
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
		row.Visible = true
		local surface = toolSlotSurface(row :: GuiObject)
		local icon = surface:FindFirstChild("Icon")
		local rate = surface:FindFirstChild("Rate")
		local key = surface:FindFirstChild("Key")
		local entry = brainrotEntryForBackpackSlot(idx)
		if entry and backpackSearchText ~= "" and not matchesBackpackSearch(entry.name) then
			entry = nil
		end
		if entry then
			if icon and icon:IsA("ImageLabel") then
				icon.ScaleType = Enum.ScaleType.Fit
				icon.BackgroundTransparency = 1
				icon.Image = entry.icon ~= "" and entry.icon or "rbxasset://textures/ui/GuiImagePlaceholder.png"
				icon.Visible = true
				icon.AnchorPoint = Vector2.new(0.5, 0.5)
				icon.Position = UDim2.new(0.5, 0, 0.5, 0)
			end
			if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
				rate.Text = entry.name
			end
			if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
				local li = listIndexForBackpackUiRow(idx)
				key.Text = if li then tostring(li) else tostring(idx)
			end
		else
			if icon and icon:IsA("ImageLabel") then
				icon.ScaleType = Enum.ScaleType.Fit
				icon.BackgroundTransparency = 1
				icon.Image = ""
				icon.Visible = false
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
		passthroughChildClicks(surface :: GuiObject)
	end
end

local function requestEquipBrainrotSlot(slotIdx: number)
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	local ev = folder and folder:FindFirstChild("EquipBrainrotSlot")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireServer(slotIdx)
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
			btn.MouseButton1Click:Connect(function()
				if dragSuppressedToolbarClick then
					dragSuppressedToolbarClick = false
					return
				end
				local listIdx = listIndexForBackpackUiRow(uiRow)
				local canEquip = listIdx
					and brainrotEntries[listIdx]
					and (listIdx > HOTBAR_INVENTORY_SLOTS or brainrotParkedInUI[listIdx])
				if canEquip then
					requestEquipBrainrotSlot(listIdx :: number)
					UIInteractionSounds.playClick()
				end
			end)
			btn.MouseButton1Down:Connect(function()
				if pendingToolbarDrag then
					return
				end
				local listIdx = listIndexForBackpackUiRow(uiRow)
				local e = listIdx and brainrotEntries[listIdx]
				if e then
					local tex = (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
					pendingToolbarDrag = {
						kind = "backpack",
						idx = listIdx :: number,
						start = UserInputService:GetMouseLocation(),
						texture = tex,
						rowButton = btn,
					}
				end
			end)
		end
	end
end

local function wireBackpackSearch(backpackFrame: Instance)
	if backpackSearchWired then
		return
	end
	local btns = backpackFrame:FindFirstChild("BackpackButtons")
	local search = btns and btns:FindFirstChild("Search")
	local tb = search and search:FindFirstChild("TextBox")
	if not tb or not tb:IsA("TextBox") then
		return
	end
	backpackSearchWired = true
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
	local btns = backpackFrame:FindFirstChild("BackpackButtons")
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
	local sorts = backpackFrame:FindFirstChild("SortButtons")
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
			ch.MouseButton1Click:Connect(function()
				highlight(ch :: GuiObject)
				UIInteractionSounds.playClick()
			end)
		end
	end
	local allTab = sorts:FindFirstChild("All")
	if allTab and allTab:IsA("GuiObject") then
		highlight(allTab :: GuiObject)
	end
end

local selectSlot: (number) -> ()
local applyAutoEquipFromSync: (number) -> ()

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
	refreshInventoryHeaderText()
	refreshBrainrotBackpackUI()
	rebuildSlots()
	if typeof(payload) == "table" then
		local equipSlot = (payload :: any).equipSlot
		if typeof(equipSlot) == "number" then
			applyAutoEquipFromSync(equipSlot)
		end
	end
end

-- ── Equip from slot ───────────────────────────────────────────────────────────

selectSlot = function(index: number)
	if not brainrotEntries[index] or brainrotParkedInUI[index] then
		return
	end
	local tool = slotTools[index]
	local hum = getHumanoid()
	if not hum then
		return
	end
	local char = player.Character
	local equipped = char and char:FindFirstChildOfClass("Tool")

	if tool and equipped == tool then
		hum:UnequipTools()
		uiHotbarHighlight = nil
		activeSlot = nil
		for si = 1, #slots do
			setSlotHighlight(si, false)
		end
		return
	end

	if not tool then
		if uiHotbarHighlight == index then
			hum:UnequipTools()
			uiHotbarHighlight = nil
			activeSlot = nil
			for si = 1, #slots do
				setSlotHighlight(si, false)
			end
			return
		end
		if brainrotEntries[index] and not brainrotParkedInUI[index] then
			if equipped and equipped:IsA("Tool") and equipped:GetAttribute("BrainrotTool") == true then
				local invIdx = equipped:GetAttribute("BrainrotInvIndex")
				if typeof(invIdx) == "number" and math.floor(invIdx) == index and uiHotbarHighlight == index then
					hum:UnequipTools()
					uiHotbarHighlight = nil
					activeSlot = nil
					for si = 1, #slots do
						setSlotHighlight(si, false)
					end
					return
				end
			end
			uiHotbarHighlight = index
			activeSlot = index
			for i = 1, #slots do
				setSlotHighlight(i, i == index)
			end
			requestEquipBrainrotSlot(index)
			return
		end
		uiHotbarHighlight = index
		activeSlot = index
		hum:UnequipTools()
		for i = 1, #slots do
			setSlotHighlight(i, i == index)
		end
		return
	end

	uiHotbarHighlight = index
	activeSlot = index
	for i = 1, #slots do
		setSlotHighlight(i, i == index)
	end
	hum:EquipTool(tool)
end

-- After deposit, server sends equipSlot = inventory index of the new brainrot (hotbar 1–9 mirror those indices).
-- Must not use selectSlot here — it toggles off when the server already equipped the matching tool.
applyAutoEquipFromSync = function(equipSlot: number)
	local slot = math.clamp(math.floor(equipSlot), 1, MAX_BACKPACK_BRAINROT_SLOTS)

	local function applyHotbarHighlight()
		if slot > HOTBAR_INVENTORY_SLOTS then
			return
		end
		uiHotbarHighlight = slot
		activeSlot = slot
		for i = 1, #slots do
			setSlotHighlight(i, i == slot)
		end
	end

	local function tryHoldBrainrot(): boolean
		applyHotbarHighlight()
		local hum = getHumanoid()
		if not hum then
			return false
		end
		rebuildSlots()
		applyHotbarHighlight()

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
			requestEquipBrainrotSlot(slot)
		end
		return false
	end

	tryHoldBrainrot()
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
			if not brainrotEntries[idx] or brainrotParkedInUI[idx] then
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

function ToolbarController.init()
	-- Disable the default Roblox backpack GUI (defer again — CoreGui can turn on during load).
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
	task.defer(function()
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
	end)

	toolbar.Visible = false

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

	-- Click / hover: nested `Button` (SideUI.Toolbar.Hotbar[n].Button) or slot is the button
	for i, slot in ipairs(slots) do
		local btn = slotPrimaryButton(slot)
		if btn then
			passthroughChildClicks(btn :: GuiObject)
			styleToolbarSlotButton(btn)
			btn.MouseButton1Click:Connect(function()
				if dragSuppressedToolbarClick then
					dragSuppressedToolbarClick = false
					return
				end
				if not brainrotEntries[i] or brainrotParkedInUI[i] then
					return
				end
				selectSlot(i)
			end)
			btn.MouseButton1Down:Connect(function()
				UIInteractionSounds.playClick()
				if brainrotEntries[i] and not brainrotParkedInUI[i] then
					local e = brainrotEntries[i]
					local tex = (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
					pendingToolbarDrag = {
						kind = "hotbar",
						idx = i,
						start = UserInputService:GetMouseLocation(),
						texture = tex,
						rowButton = nil,
					}
				end
			end)
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
			local sel = uiHotbarHighlight
			local baseScale = if sel == i then 1.08 else 1.0
			TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = baseScale }):Play()
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

	playerInSafezone = SafezoneUtil.isCharacterInSafezone(player.Character)
	refreshToolbarVisibility()

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
					if desc.Name == "RedWall" or desc.Name == "RedPart" or desc.Name == "Raddie" or desc.Name == "SafezoneHitbox" then
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
	local toggleBtn = toolbar:FindFirstChild("ToggleBackpack") or hotbar:FindFirstChild("ToggleBackpack")
	local backpackFrame = toolbar:FindFirstChild("Backpack")
	if backpackFrame then
		backpackContainer = backpackFrame:FindFirstChild("Container")
		if backpackFrame:IsA("GuiObject") then
			local bf = backpackFrame :: GuiObject
			backpackGuiFrame = bf
			backpackFrameRef = bf
			ensureBackpackFrameOutline(bf)
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
		wireBackpackSearch(backpackFrame)
		wireBackpackCloseButton(backpackFrame)
		wireSortCategoryTabs(backpackFrame)
	end
	if toggleBtn and backpackFrame and toggleBtn:IsA("GuiButton") then
		isBackpackPanelOpen = false
		backpackFrame.Visible = false
		toggleBtn.MouseEnter:Connect(function()
			UIInteractionSounds.playHover()
		end)
		toggleBtn.MouseButton1Down:Connect(function()
			UIInteractionSounds.playClick()
		end)
		toggleBtn.MouseButton1Click:Connect(function()
			setBackpackPanelOpen(not isBackpackPanelOpen)
		end)
	end

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
				local ownerRow = ancestorBackpackRowIndexFromGuiObject(pnd.rowButton :: GuiObject)
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
						local rowUnder = ancestorBackpackRowIndexFromGuiObject(hit)
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
			if pnd.kind == "backpack" then
				enterHotbarBackpackDragBulkHover()
			end
			return
		end
		if pnd.kind ~= "hotbar" then
			return
		end
		local rawEnd = UserInputService:GetMouseLocation()
		if input.UserInputType == Enum.UserInputType.Touch then
			rawEnd = Vector2.new(input.Position.X, input.Position.Y)
		end
		local mouseWindow = screenPointWithGuiInset(rawEnd)
		local ghostCenter: Vector2? = nil
		if dragGhostImage then
			ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
		end
		local insetProbe = GuiService:GetGuiInset()
		local ghostViewport = if ghostCenter then ghostCenter - Vector2.new(insetProbe.X, insetProbe.Y) else nil
		local targetHotbar = hotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter)
		local overHotbar = targetHotbar ~= nil
			or pointOverHotbarDropZoneProbes(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and pointOverHotbarDropZoneProbes(ghostCenter, rawEnd))
			or (ghostViewport ~= nil and pointOverHotbarFromGuiHitScan(ghostViewport))
		if overHotbar then
			enterHotbarBackpackDragBulkHover()
		elseif hotbarDragBulkHover then
			resetHotbarSlotHoverScalesAfterDrag()
		end
	end)

	UserInputService.InputEnded:Connect(function(input, _gp)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local pnd = pendingToolbarDrag
		pendingToolbarDrag = nil
		if not pnd then
			clearDragGhost()
			return
		end
		local rawEnd = UserInputService:GetMouseLocation()
		if input.UserInputType == Enum.UserInputType.Touch then
			rawEnd = Vector2.new(input.Position.X, input.Position.Y)
		end
		if (rawEnd - pnd.start).Magnitude < DRAG_THRESHOLD_PX then
			clearDragGhost()
			return
		end
		local mouseWindow = screenPointWithGuiInset(rawEnd)
		local ghostCenter: Vector2? = nil
		if dragGhostImage then
			ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
		end
		local insetProbe = GuiService:GetGuiInset()
		local ghostViewport = if ghostCenter then ghostCenter - Vector2.new(insetProbe.X, insetProbe.Y) else nil
		local destBackpackRow = backpackRowIndexFromDropProbes(rawEnd, mouseWindow, ghostViewport)
		clearDragGhost()
		dragSuppressedToolbarClick = true

		local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
		local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
		if not parkEv or not parkEv:IsA("RemoteEvent") then
			return
		end

		local targetHotbar = hotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter)
		local overHotbar = targetHotbar ~= nil
			or pointOverHotbarDropZoneProbes(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and pointOverHotbarDropZoneProbes(ghostCenter, rawEnd))
			or (ghostViewport ~= nil and pointOverHotbarFromGuiHitScan(ghostViewport))
		local overBackpack = pointOverBackpackProbes(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and pointOverBackpackProbes(ghostCenter, rawEnd))

		if pnd.kind == "hotbar" then
			local hasEntry = brainrotEntries[pnd.idx] and not brainrotParkedInUI[pnd.idx]
			if not hasEntry then
				return
			end
			if targetHotbar and targetHotbar ~= pnd.idx then
				-- Hotbar → hotbar swap.
				(parkEv :: RemoteEvent):FireServer(pnd.idx, false, targetHotbar)
				UIInteractionSounds.playClick()
			elseif overBackpack then
				-- Hotbar → backpack panel: tuck (hide from hotbar, show in expanded backpack).
				rebuildBackpackDisplayOrder()
				local destListIdx = #backpackDisplayOrder + 1
				(parkEv :: RemoteEvent):FireServer(pnd.idx, true, nil, destListIdx)
				brainrotParkedInUI[pnd.idx] = true
				rebuildBackpackDisplayOrder()
				refreshBrainrotBackpackUI()
				rebuildSlots()
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