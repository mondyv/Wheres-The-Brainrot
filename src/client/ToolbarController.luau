-- [ACTIVE] ToolbarController
--[[
	ToolbarController
	Replaces the default Roblox backpack/hotbar with the custom Toolbar frame.

	Expected SideUI hierarchy:
	  SideUI
	  └── Toolbar
	      ├── Hotbar
	      │   └── 1 .. 9   (slot frames with nested Button)
	      ├── ToggleBackpack  (optional fallback if ToggleBackpackImage missing)
	      ├── ToggleBackpackImage  (icon toggle; lives in Hotbar row after visible slots)
	      └── Backpack  (expanded inventory panel)

	Studio layout: anchor Hotbar + Backpack at X=0.5 under Toolbar once at init.
	ToggleBackpackImage is reparented into Hotbar when closed; hides while inventory is open.
	Hotbar slots may use nested `Button` (e.g. Hotbar["1"].Button.Icon).
	Brainrot pickups: tuck/untuck via drag; ghost drag; search; backpack frame outline + open/close tweens.
	Backpack UI reuses Backpack.Container and fills visible stashed brainrots from the top-left. Empty rows stay visible.

	Toolbar UI access: spawn SafeZoneHitbox (and legacy Reddie/Raddie). RedWall is deposit —
	hides backpack only when outside the safe zone (Reddie was renamed to RedWall on some maps).
--]]

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local GamepadService = game:GetService("GamepadService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local _Workspace = game:GetService("Workspace")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GamepadInput = require(script.Parent.GamepadInput)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local CarryGate = require(script.Parent.CarryGate)
local DropTargets = require(script.Parent.ToolbarDropTargets)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local LoadingScreenController = require(script.Parent.LoadingScreenController)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local BrainrotItemTooltip = require(script.Parent.BrainrotItemTooltip)
local GearViewportIcon = require(script.Parent.GearViewportIcon)
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

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
	local guardAccum = 0
	defaultBackpackGuardConn = RunService.Heartbeat:Connect(function(dt)
		guardAccum += dt
		if guardAccum < 5 then
			return
		end
		guardAccum = 0
		pcall(function()
			if StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack) then
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end
		end)
	end)
end

local playerGui = player:WaitForChild("PlayerGui")
local mainGui = PlayerGuiMain.ensure(player)
local sideUI = mainGui:WaitForChild("SideUI")
local toolbar = sideUI:WaitForChild("Toolbar")
local hotbar = toolbar:WaitForChild("Hotbar")

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
	local backpackEarly = toolbar:FindFirstChild("Backpack")
	local icon = if backpackEarly then backpackEarly:FindFirstChild("ToggleBackpackImage") else nil
	if not icon then
		icon = toolbar:FindFirstChild("ToggleBackpackImage") or hotbar:FindFirstChild("ToggleBackpackImage")
	end
	if icon and icon:IsA("GuiObject") then
		(icon :: GuiObject).Visible = false
	end
end

applyToolbarInitialHiddenState()

-- ── Tween configs ─────────────────────────────────────────────────────────────

local SHOW_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIGHLIGHT_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EQUIP_POP_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BACKPACK_OPEN_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BACKPACK_CLOSE_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local BACKPACK_ICON_IN_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BACKPACK_ICON_OUT_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BACKPACK_SLIDE_PX = 96
local BACKPACK_PANEL_ZINDEX = 40
local HOTBAR_FRONT_ZINDEX = 50
local BACKPACK_BEHIND_HOTBAR_ZINDEX = 5
local BACKPACK_OPEN_START_SCALE = 0.92
local BACKPACK_CLOSE_END_SCALE = 0.96
local DRAG_GHOST_SMOOTH = 0.55 -- per-frame lerp toward cursor (higher = snappier follow)
local MOBILE_DRAG_HOLD_SEC = 0.2 -- long-press before mobile inventory drag starts (keeps tap-to-select)
local TOGGLE_BACKPACK_ICON_MIN_ABS_PX = 28
-- Match hotbar slot Size 1:1 (scale + offset) so resize keeps the icon in sync.
local TOGGLE_BACKPACK_ICON_SIZE_SCALE = 1

-- ── Key → slot index map ──────────────────────────────────────────────────────

local KEY_TO_SLOT: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

-- ── State ─────────────────────────────────────────────────────────────────────

local slots: { GuiObject } = {} -- ordered slot frames (index 1-9)
local slotTools: { Tool? } = {} -- tool assigned to each slot
local extraToolSlotByIndex: { [number]: Tool } = {} -- non-brainrot hotbar tools (e.g. lucky block)
local parkedExtraTools: { Tool } = {} -- tucked off hotbar, shown in backpack panel
local extraToolRowByTool: { [Tool]: GuiObject } = {}
local _activeSlot: number? = nil
local uiHotbarHighlight: number? = nil -- nil = no slot ring (toggle off); otherwise mirrors selection / equip
local slotStrokeLit: { [number]: boolean } = {}
local toolbarShown: boolean = false
local canUseToolbar: boolean = false
local safezonePollAccum = 0.0
local SAFEZONE_POLL_INTERVAL = if UserInputService.TouchEnabled then 0.5 else 0.25
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
local brainrotEntries: {
	{
		uid: string?,
		name: string,
		icon: string,
		sourcePath: string,
		rarity: string?,
		mutation: string?,
		level: number?,
		baseIncome: number?,
	}
} =
	{}
local backpackContainer: Instance? = nil
local backpackGuiFrame: GuiObject? = nil
local backpackHeaderLabel: Instance? = nil
local backpackEquipWired = false
local equipBestWired = false
local equipBestBusyUntil = 0.0

local brainrotParkedInUI: { [number]: boolean } = {}
-- Normal brainrots are stored by server inventory index, but their visible hotbar
-- slot can now be different. Example: inventory index 3 can display in hotbar slot 8.
local brainrotHotbarSlotByIndex: { [number]: number } = {}
local brainrotIndexByHotbarSlot: { [number]: number } = {}
-- UI backpack rows 1..MAX map through this → server list index (tucked + slot >9) so stashed pets fill consecutive rows.
local backpackDisplayOrder: { number } = {}
-- Client-only display priority for items freshly moved/tucked into the backpack.
-- Without this, high inventory indices appear after every lower index, which feels
-- like the item was thrown to the end instead of the top-left.
local backpackFrontDisplayOrder: { number } = {}
local pendingToolbarDrag: {
	kind: string,
	idx: number,
	start: Vector2,
	texture: string?,
	uid: string?,
	rowButton: GuiButton?,
	equippedOnDown: boolean?,
	isExtraTool: boolean?,
	tool: Tool?,
	sourceSize: Vector2?,
}? =
	nil
-- Drag started inside the safe zone; finish drop even if zone poll flickers before mouse up.
-- Cached while dragging so mouse-up still lands in the selected slot even if the ghost/touch
-- endpoint briefly misses the button on the final frame.
local lastResolvedHotbarDropSlot: number? = nil
local activeToolbarDrag = false
local dragSuppressedToolbarClick = false
local mobileDragHoldToken = 0
local DRAG_THRESHOLD_PX = 14
local DRAG_GHOST_THRESHOLD_PX = 6
-- Shared scale for the single hotbar slot under the cursor while dragging (not the whole bar).
local HOTBAR_DRAG_HOVER_SCALE = 1.06

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
local hideToolbar: (boolean?) -> ()
local tryAutoSelectReturnedBrainrot: () -> ()
local requestBrainrotInventoryFromServer: () -> ()
local backpackSearchWired = false
local backpackCloseWired = false
local isBackpackPanelOpen = false
-- Keep empty hotbar drop targets visible through the close tween so they don't snap away mid-animation.
local isBackpackPanelClosing = false
local backpackPanelScaleTween: Tween? = nil
local backpackPanelPosTween: Tween? = nil
local backpackContainerScaleTween: Tween? = nil
local backpackRestPosition: UDim2? = nil
local toggleIconScaleTween: Tween? = nil
local _tweenEmptyHotbarSlotsOut: () -> ()
local resetEmptyHotbarSlotScales: () -> ()
local cancelEmptyHotbarCloseTweens: () -> ()
local animateToggleBackpackIcon: (boolean) -> ()
local cancelToggleIconTween: () -> ()

-- While dragging over the hotbar, only the slot under the cursor scales.
-- `hotbarDragZoneActive` keeps drop hit-pad expansion without resizing every cell.
local hotbarDragZoneActive = false
local hotbarDragHoverSlot: number? = nil
local backpackDragHover = false
local BACKPACK_FRAME_DRAG_HOVER_SCALE = 1.045
local _BACKPACK_ROW_DRAG_HOVER_SCALE = 1.0

local ToolbarController = {}

-- Luau allows at most 200 locals per function; the module chunk already holds ~100.
-- Wrap helpers + init in an IIFE so they get their own register scope.
(function()
	-- ── Helpers ───────────────────────────────────────────────────────────────────

	local function getOrAddUIScale(parent: Instance): UIScale
		local s = parent:FindFirstChildOfClass("UIScale")
		if s then
			return s
		end
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
		-- Workout gears always first, then ToolbarPriority, then name.
		table.sort(out, function(a: Tool, b: Tool)
			local aGear = a:GetAttribute("WorkoutGearTool") == true
			local bGear = b:GetAttribute("WorkoutGearTool") == true
			if aGear ~= bGear then
				return aGear
			end
			local ap = a:GetAttribute("ToolbarPriority")
			local bp = b:GetAttribute("ToolbarPriority")
			local an = if typeof(ap) == "number" then ap else 0
			local bn = if typeof(bp) == "number" then bp else 0
			if an ~= bn then
				return an > bn
			end
			return a.Name < b.Name
		end)
		return out
	end

	local slotIconCache: { [GuiObject]: { ImageLabel } } = {}

	local function slotIconTargets(surface: GuiObject): { ImageLabel }
		local cached = slotIconCache[surface]
		if cached then
			local first = cached[1]
			if first and first.Parent then
				return cached
			end
			slotIconCache[surface] = nil
		end
		local out: { ImageLabel } = {}
		local seen: { [ImageLabel]: boolean } = {}
		local function push(node: Instance?)
			if node and node:IsA("ImageLabel") and not seen[node :: ImageLabel] then
				seen[node :: ImageLabel] = true
				table.insert(out, node :: ImageLabel)
			end
		end
		push(surface:FindFirstChild("Icon"))
		if #out == 0 then
			for _, d in surface:GetChildren() do
				if d:IsA("ImageLabel") and d.Name == "Icon" then
					push(d)
				end
			end
		end
		if #out == 0 then
			for _, d in surface:GetDescendants() do
				if d:IsA("ImageLabel") and d.Name == "Icon" then
					push(d)
				end
			end
		end
		if #out == 0 then
			for _, d in surface:GetChildren() do
				if d:IsA("ImageLabel") then
					push(d)
					break
				end
			end
		end
		slotIconCache[surface] = out
		return out
	end

	local function applySlotIconStyle(icon: ImageLabel)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.BackgroundTransparency = 1
		icon.ImageColor3 = Color3.new(1, 1, 1)
		icon.ImageTransparency = 0
	end

	local function luckyBlockDisplayLabel(tool: Tool): string
		local kind = tool:GetAttribute("LuckyBlockKind")
		if typeof(kind) == "string" and kind ~= "" then
			local ok, name = pcall(function()
				return LuckyBlockCatalog.displayName(kind)
			end)
			if ok and typeof(name) == "string" and name ~= "" then
				return name
			end
			return kind
		end
		return tool.Name
	end

	local function setSlotIcons(surface: GuiObject, image: string, visible: boolean)
		if surface:FindFirstChild("GearViewport") then
			GearViewportIcon.clear(surface)
		end
		for _, icon in slotIconTargets(surface) do
			applySlotIconStyle(icon)
			icon.Image = image
			icon.Visible = visible
		end
	end

	local function setSlotGearViewport(surface: GuiObject, gearId: number)
		for _, icon in slotIconTargets(surface) do
			icon.Visible = false
		end
		GearViewportIcon.mount(surface, gearId, { rotate = false })
	end

	local function toolDisplayTexture(tool: Tool): string
		local attrIcon = tool:GetAttribute("ToolbarIcon")
		if typeof(attrIcon) == "string" and attrIcon ~= "" then
			return attrIcon
		end
		local tex = (tool :: any).TextureId
		if typeof(tex) == "string" and tex ~= "" then
			return tex
		end
		if tool:GetAttribute("LuckyBlockTool") == true then
			local kind = tool:GetAttribute("LuckyBlockKind")
			if typeof(kind) == "string" and kind ~= "" then
				local ok, asset = pcall(function()
					return LuckyBlockCatalog.resolveIconAssetId(kind)
				end)
				if ok and typeof(asset) == "string" and asset ~= "" then
					return asset
				end
			end
		end
		return ""
	end

	local function rebuildBrainrotHotbarReverseMap()
		brainrotIndexByHotbarSlot = {}

		local validMappings: { { idx: number, slot: number } } = {}
		for rawIdx, rawSlot in pairs(brainrotHotbarSlotByIndex) do
			local idxNum = if typeof(rawIdx) == "number" then rawIdx else tonumber(rawIdx)
			if typeof(idxNum) == "number" and typeof(rawSlot) == "number" then
				local idx = math.floor(idxNum)
				local slot = math.floor(rawSlot)
				if
					idx >= 1
					and brainrotEntries[idx] ~= nil
					and brainrotParkedInUI[idx] ~= true
					and slot >= 1
					and slot <= HOTBAR_INVENTORY_SLOTS
				then
					table.insert(validMappings, { idx = idx, slot = slot })
				end
			end
		end

		-- pairs() order is not stable. Rebuild the maps in inventory order so two
		-- bad/conflicting mappings never make pets jump into random slots.
		table.sort(validMappings, function(a, b)
			return a.idx < b.idx
		end)

		brainrotHotbarSlotByIndex = {}
		for _, mapping in ipairs(validMappings) do
			if brainrotIndexByHotbarSlot[mapping.slot] == nil then
				brainrotHotbarSlotByIndex[mapping.idx] = mapping.slot
				brainrotIndexByHotbarSlot[mapping.slot] = mapping.idx
				brainrotParkedInUI[mapping.idx] = nil
			else
				-- Conflict fallback: keep one owner for the hotbar cell and park the other.
				brainrotParkedInUI[mapping.idx] = true
			end
		end
	end

	local function brainrotIndexForHotbarSlot(slot: number): number?
		if slot < 1 or slot > HOTBAR_INVENTORY_SLOTS then
			return nil
		end
		rebuildBrainrotHotbarReverseMap()
		local explicit = brainrotIndexByHotbarSlot[slot]
		if explicit and brainrotEntries[explicit] ~= nil then
			return explicit
		end
		-- Legacy/default path: index 1..9 appears in the matching slot unless it
		-- was tucked or explicitly moved elsewhere.
		if
			brainrotEntries[slot] ~= nil
			and brainrotParkedInUI[slot] ~= true
			and brainrotHotbarSlotByIndex[slot] == nil
		then
			return slot
		end
		return nil
	end

	local function hotbarSlotForBrainrotIndex(invIndex: number): number?
		if invIndex < 1 or brainrotEntries[invIndex] == nil or brainrotParkedInUI[invIndex] == true then
			return nil
		end
		local mapped = brainrotHotbarSlotByIndex[invIndex]
		if typeof(mapped) == "number" then
			local slot = math.floor(mapped)
			if slot >= 1 and slot <= HOTBAR_INVENTORY_SLOTS then
				return slot
			end
		end
		if invIndex <= HOTBAR_INVENTORY_SLOTS then
			rebuildBrainrotHotbarReverseMap()
			local owner = brainrotIndexByHotbarSlot[invIndex]
			if owner and owner ~= invIndex then
				return nil
			end
			return invIndex
		end
		return nil
	end

	local function pointOverHotbarHitScan(rawViewport: Vector2?): boolean
		if rawViewport == nil then
			return false
		end
		local fn = (DropTargets :: any).pointOverHotbarFromGuiHitScan
		if typeof(fn) ~= "function" then
			return false
		end
		local ok, result = pcall(fn, rawViewport)
		return ok and result == true
	end

	-- Compatibility wrappers: if Studio is still using an older ToolbarDropTargets
	-- module, drag/drop must fail safely instead of throwing an "attempt to call
	-- a nil value" inside the InputEnded callback.
	local function dtScreenPointWithGuiInset(screen: Vector2): Vector2
		local fn = (DropTargets :: any).screenPointWithGuiInset
		if typeof(fn) == "function" then
			local ok, result = pcall(fn, screen)
			if ok and typeof(result) == "Vector2" then
				return result
			end
		end
		local inset = GuiService:GetGuiInset()
		return screen + Vector2.new(inset.X, inset.Y)
	end

	local function dtIsTouchPointerInput(): boolean
		local fn = (DropTargets :: any).isTouchPointerInput
		if typeof(fn) == "function" then
			local ok, result = pcall(fn)
			return ok and result == true
		end
		return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
	end

	local function dtProbeDragHoverTargets(
		mouseWindow: Vector2,
		rawEnd: Vector2,
		ghostCenter: Vector2?,
		ghostViewport: Vector2?
	): (boolean, boolean, boolean)
		local fn = (DropTargets :: any).probeDragHoverTargets
		if typeof(fn) == "function" then
			local ok, a, b, c = pcall(fn, mouseWindow, rawEnd, ghostCenter, ghostViewport)
			if ok then
				return a == true, b == true, c == true
			end
		end
		return false, false, false
	end

	local function dtHotbarSlotIndexFromDropProbes(
		mouseWindow: Vector2,
		rawEnd: Vector2,
		ghostCenter: Vector2?
	): number?
		local fn = (DropTargets :: any).hotbarSlotIndexFromDropProbes
		if typeof(fn) == "function" then
			local ok, result = pcall(fn, mouseWindow, rawEnd, ghostCenter)
			if ok and typeof(result) == "number" then
				local slot = math.floor(result)
				if slot >= 1 and slot <= HOTBAR_INVENTORY_SLOTS then
					return slot
				end
			end
		end
		return nil
	end

	local function dtBackpackRowIndexFromDropProbes(
		rawEnd: Vector2,
		mouseWindow: Vector2,
		ghostViewport: Vector2?
	): number?
		local fn = (DropTargets :: any).backpackRowIndexFromDropProbes
		if typeof(fn) == "function" then
			local ok, result = pcall(fn, rawEnd, mouseWindow, ghostViewport)
			if ok and typeof(result) == "number" then
				local row = math.floor(result)
				if row >= 1 and row <= MAX_BACKPACK_BRAINROT_SLOTS then
					return row
				end
			end
		end
		return nil
	end

	local function dtPointOverHotbarDropZoneProbes(dropPoint: Vector2, rawEnd: Vector2): boolean
		local fn = (DropTargets :: any).pointOverHotbarDropZoneProbes
		if typeof(fn) == "function" then
			local ok, result = pcall(fn, dropPoint, rawEnd)
			return ok and result == true
		end
		return false
	end

	local function hotbarSlotDragTexture(index: number): string?
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		if brainrotIdx and brainrotEntries[brainrotIdx] and not brainrotParkedInUI[brainrotIdx] then
			local e = brainrotEntries[brainrotIdx] :: { icon: string }
			return (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
		end
		local tool = slotTools[index]
		if tool then
			local tex = toolDisplayTexture(tool)
			if tex ~= "" then
				return tex
			end
		end
		return nil
	end

	local function isExtraToolParked(tool: Tool): boolean
		for _, t in parkedExtraTools do
			if t == tool then
				return true
			end
		end
		return false
	end

	local function removeExtraToolFromParkedList(tool: Tool)
		for i = #parkedExtraTools, 1, -1 do
			if parkedExtraTools[i] == tool then
				table.remove(parkedExtraTools, i)
			end
		end
	end

	local function removeExtraToolFromAllHotbarSlots(tool: Tool)
		for idx, mapped in pairs(extraToolSlotByIndex) do
			if mapped == tool then
				extraToolSlotByIndex[idx] = nil
			end
		end
	end

	local function slotIndexIsHotbar(index: number): boolean
		return index >= 1 and index <= HOTBAR_INVENTORY_SLOTS
	end

	local function slotHasActiveBrainrot(index: number): boolean
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		return slotIndexIsHotbar(index)
			and brainrotIdx ~= nil
			and brainrotEntries[brainrotIdx] ~= nil
			and brainrotParkedInUI[brainrotIdx] ~= true
	end

	local function slotCanHoldExtraTool(index: number): boolean
		if not slotIndexIsHotbar(index) then
			return false
		end
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		return brainrotIdx == nil or brainrotParkedInUI[brainrotIdx] == true
	end

	local function slotCanAcceptExtraToolDrop(index: number): boolean
		-- Drops are allowed on active brainrot cells too. The brainrot gets tucked
		-- into the expanded backpack first, then the extra tool owns the hotbar slot.
		return slotIndexIsHotbar(index)
	end

	local function requestTuckBrainrotHotbarSlot(index: number)
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		if not brainrotIdx or not slotHasActiveBrainrot(index) then
			return
		end
		brainrotParkedInUI[brainrotIdx] = true
		brainrotHotbarSlotByIndex[brainrotIdx] = nil
		rebuildBrainrotHotbarReverseMap()
		local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
		local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
		if parkEv and parkEv:IsA("RemoteEvent") then
			(parkEv :: RemoteEvent):FireServer(brainrotIdx, true)
		end
	end

	local function extraToolAtHotbarSlot(index: number): Tool?
		local mapped = extraToolSlotByIndex[index]
		if mapped and mapped.Parent and isExtraHotbarTool(mapped) then
			return mapped
		end
		local shown = slotTools[index]
		if shown and shown.Parent and isExtraHotbarTool(shown) and slotCanHoldExtraTool(index) then
			return shown
		end
		return nil
	end

	local function sanitizeExtraToolSlotPins()
		local firstSlotForTool: { [Tool]: number } = {}
		for idx, tool in pairs(extraToolSlotByIndex) do
			if
				idx < 1
				or idx > HOTBAR_INVENTORY_SLOTS
				or not tool.Parent
				or not isExtraHotbarTool(tool)
				or not slotCanHoldExtraTool(idx)
			then
				extraToolSlotByIndex[idx] = nil
			elseif firstSlotForTool[tool] then
				-- One Tool instance can never own two hotbar cells. This was the Lucky Block
				-- “dupe” visual when a stale mapping survived a swap.
				extraToolSlotByIndex[idx] = nil
			else
				firstSlotForTool[tool] = idx
			end
		end
		for i = #parkedExtraTools, 1, -1 do
			local tool = parkedExtraTools[i]
			if not tool.Parent or firstSlotForTool[tool] then
				table.remove(parkedExtraTools, i)
			end
		end
	end

	local function parkExtraToolInBackpack(tool: Tool, fromSlot: number?)
		removeExtraToolFromParkedList(tool)
		removeExtraToolFromAllHotbarSlots(tool)
		if typeof(fromSlot) == "number" then
			extraToolSlotByIndex[fromSlot] = nil
		end
		table.insert(parkedExtraTools, tool)
		local hum = getHumanoid()
		if hum and tool.Parent == player.Character then
			hum:UnequipTools()
		end
		sanitizeExtraToolSlotPins()
	end

	local function unparkExtraToolToHotbar(tool: Tool, toSlot: number): boolean
		if not slotCanAcceptExtraToolDrop(toSlot) then
			return false
		end
		requestTuckBrainrotHotbarSlot(toSlot)
		if not slotCanHoldExtraTool(toSlot) then
			return false
		end
		removeExtraToolFromParkedList(tool)
		removeExtraToolFromAllHotbarSlots(tool)
		extraToolSlotByIndex[toSlot] = tool
		sanitizeExtraToolSlotPins()
		return true
	end

	local function findWorkoutGearTool(): Tool?
		for _, tool in ipairs(collectExtraHotbarTools()) do
			if tool:GetAttribute("WorkoutGearTool") == true and tool.Parent then
				return tool
			end
		end
		for _, tool in ipairs(parkedExtraTools) do
			if tool:GetAttribute("WorkoutGearTool") == true and tool.Parent then
				return tool
			end
		end
		return nil
	end

	-- Dumbbell / workout gear always owns hotbar slot 1; brainrots there go to backpack UI.
	local function ensureWorkoutGearOwnsHotbarSlot1(maxHotbar: number)
		if maxHotbar < 1 then
			return
		end
		local gearTool = findWorkoutGearTool()
		if not gearTool then
			return
		end
		if isExtraToolParked(gearTool) then
			return
		end

		if slotHasActiveBrainrot(1) then
			requestTuckBrainrotHotbarSlot(1)
		end
		slotTools[1] = nil

		local occupant = extraToolSlotByIndex[1]
		if occupant and occupant ~= gearTool and occupant.Parent then
			parkExtraToolInBackpack(occupant, 1)
		end

		removeExtraToolFromParkedList(gearTool)
		removeExtraToolFromAllHotbarSlots(gearTool)
		extraToolSlotByIndex[1] = gearTool
		slotTools[1] = gearTool
	end

	local refreshParkedExtraToolsUI: () -> ()
	local setBackpackPanelOpen: (boolean) -> ()
	local findBackpackTemplateRow: (Instance?) -> GuiObject?
	local applyBackpackSlotPanelAppearance: (GuiButton, boolean) -> ()
	local requestEquipFromBackpackExtra: (Tool) -> ()
	local syncBackpackSelectionStrokes: () -> ()
	local uiBackpackListHighlight: number? = nil
	local uiBackpackExtraHighlight: Tool? = nil
	local gamepadCursorEnabled = false

	local function guiObjectTreeVisible(gui: GuiObject): boolean
		local n: Instance? = gui
		while n do
			if n:IsA("GuiObject") and not (n :: GuiObject).Visible then
				return false
			end
			if n:IsA("LayerCollector") and n:IsA("ScreenGui") and not (n :: ScreenGui).Enabled then
				return false
			end
			n = n.Parent
		end
		return true
	end

	local function syncToolbarGamepadCursor()
		local want = GamepadInput.isPreferred()
			and canUseToolbar
			and (isBackpackPanelOpen or pendingToolbarDrag ~= nil or activeToolbarDrag)
		if not want then
			if gamepadCursorEnabled then
				gamepadCursorEnabled = false
				pcall(function()
					GamepadService:DisableGamepadCursor()
				end)
			end
			return
		end
		local host: GuiObject? = nil
		if backpackFrameRef and backpackFrameRef:IsA("GuiObject") and guiObjectTreeVisible(backpackFrameRef) then
			host = backpackFrameRef
		elseif toolbar and toolbar:IsA("GuiObject") and guiObjectTreeVisible(toolbar) then
			host = toolbar
		end
		if not host then
			if gamepadCursorEnabled then
				gamepadCursorEnabled = false
				pcall(function()
					GamepadService:DisableGamepadCursor()
				end)
			end
			return
		end
		gamepadCursorEnabled = true
		local ok, err = pcall(function()
			GamepadService:EnableGamepadCursor(host)
		end)
		if not ok then
			warn("[ToolbarController] gamepad cursor sync failed:", err)
			gamepadCursorEnabled = false
		end
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
	-- Hotbar / backpack rows often wrap controls in `Button` (sometimes a Frame).
	local function slotPrimaryButton(slot: GuiObject): GuiButton?
		local named = slot:FindFirstChild("Button")
		if named then
			if named:IsA("GuiButton") then
				return named
			end
			if named:IsA("GuiObject") then
				local nested = named:FindFirstChildWhichIsA("GuiButton", true)
				if nested then
					return nested
				end
			end
		end
		if slot:IsA("GuiButton") then
			return slot
		end
		for _, d in slot:GetDescendants() do
			if d:IsA("GuiButton") and d.Name ~= "Selected" and d.Name ~= "Sellect" then
				return d
			end
		end
		return nil
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
		if root:GetAttribute("_ToolbarPassClicks") == true then
			return
		end
		for _, d in root:GetDescendants() do
			if d:IsA("GuiObject") and d ~= root then
				d.Active = false
			end
		end
		root:SetAttribute("_ToolbarPassClicks", true)
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

	local SLOT_BUTTON_IMAGE_TINT = Color3.fromRGB(58, 60, 72)
	local BACKPACK_SLOT_PANEL_OCCUPIED = Color3.fromRGB(26, 28, 34)

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

	refreshParkedExtraToolsUI = function()
		local container = backpackContainer
		if not container then
			return
		end

		-- Drop rows for tools that are no longer parked / no longer exist.
		for tool, row in pairs(extraToolRowByTool) do
			if not isExtraToolParked(tool) or not tool.Parent then
				if row and row.Parent then
					row:Destroy()
				end
				extraToolRowByTool[tool] = nil
			end
		end

		for i = #parkedExtraTools, 1, -1 do
			local tool = parkedExtraTools[i]
			if not tool.Parent then
				table.remove(parkedExtraTools, i)
			end
		end

		local template = findBackpackTemplateRow(container)
		if not template then
			local fallback = container:FindFirstChild("1")
			if fallback and fallback:IsA("GuiObject") then
				template = fallback :: GuiObject
			end
		end
		if not template then
			return
		end

		-- Clear leftover host from older attempts (extras now live as grid siblings).
		local oldHost = container:FindFirstChild("__ExtraTools")
		if oldHost then
			oldHost:Destroy()
		end
		if backpackFrameRef then
			local frameHost = backpackFrameRef:FindFirstChild("__ExtraTools")
			if frameHost then
				frameHost:Destroy()
			end
		end

		for index, tool in ipairs(parkedExtraTools) do
			local row = extraToolRowByTool[tool]
			if not row or not row.Parent then
				row = (template :: GuiObject):Clone()
				row:SetAttribute("_ToolbarBackpackTemplate", nil)
				row:SetAttribute("_ToolbarGeneratedBackpackRow", nil)
				row:SetAttribute("ToolbarBackpackUiRow", nil)
				row.Name = "__Extra_" .. tostring(index)
				row.LayoutOrder = MAX_BACKPACK_BRAINROT_SLOTS + index
				row.Visible = true
				row.Parent = container
				extraToolRowByTool[tool] = row

				local btn = slotPrimaryButton(row :: GuiObject)
				if btn then
					passthroughChildClicks(btn :: GuiObject)
					styleToolbarSlotButton(btn)
					applyBackpackSlotPanelAppearance(btn, true)
					local scale = getOrAddUIScale(hotbarSlotScaleHost(row :: GuiObject))
				btn.MouseEnter:Connect(function()
					if not canUseToolbar then
						return
					end
					UIInteractionSounds.playHover()
				end)
				btn.MouseLeave:Connect(function()
					TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = SLOT_IDLE_SCALE }):Play()
				end)
				btn.Activated:Connect(function()
					if not canUseToolbar then
						return
					end
					if dragSuppressedToolbarClick then
						dragSuppressedToolbarClick = false
						return
					end
					UIInteractionSounds.playClick()
					requestEquipFromBackpackExtra(tool)
				end)
				btn.MouseButton1Down:Connect(function()
						if not canUseToolbar then
							return
						end
						if GamepadInput.isPreferred() then
							requestEquipFromBackpackExtra(tool)
							dragSuppressedToolbarClick = true
							return
						end
						local tex = toolDisplayTexture(tool)
						if tex == "" then
							tex = "rbxasset://textures/ui/GuiImagePlaceholder.png"
						end
						activeToolbarDrag = true
						pendingToolbarDrag = {
							kind = "backpack_extra",
							idx = index,
							start = UserInputService:GetMouseLocation(),
							texture = tex,
							rowButton = btn,
							isExtraTool = true,
							tool = tool,
						}
					end)
					btn.InputBegan:Connect(function(input)
						if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= GamepadInput.ACCEPT then
							return
						end
						if not canUseToolbar then
							return
						end
						requestEquipFromBackpackExtra(tool)
						dragSuppressedToolbarClick = true
					end)
				end
			else
				row.Name = "__Extra_" .. tostring(index)
				row.LayoutOrder = MAX_BACKPACK_BRAINROT_SLOTS + index
				row.Visible = true
				if row.Parent ~= container then
					row.Parent = container
				end
			end

			local surface = toolSlotSurface(row :: GuiObject)
			if tool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
				if typeof(gearId) == "number" then
					setSlotGearViewport(surface, gearId)
				else
					setSlotIcons(surface, "rbxasset://textures/ui/GuiImagePlaceholder.png", true)
				end
				local rate = surface:FindFirstChild("Rate")
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = tool.Name
				end
				local key = surface:FindFirstChild("Key")
				if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
					key.Text = "GEAR"
				end
			else
				local tex = toolDisplayTexture(tool)
				setSlotIcons(
					surface,
					if tex ~= "" then tex else "rbxasset://textures/ui/GuiImagePlaceholder.png",
					true
				)
				local rate = surface:FindFirstChild("Rate")
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = luckyBlockDisplayLabel(tool)
				end
				local key = surface:FindFirstChild("Key")
				if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
					key.Text = "LB"
				end
			end
		end
		if typeof(syncBackpackSelectionStrokes) == "function" then
			syncBackpackSelectionStrokes()
		end
	end

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

	applyBackpackSlotPanelAppearance = function(btn: GuiButton, occupied: boolean)
		local defaults = captureBackpackSlotPanelDefaults(btn)

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
			-- Selection stroke (white vs idle) is owned by applyButtonSelectionStyle.
		else
			-- Empty backpack cells should still look like real slots.
			-- Only the icon/rate text gets cleared elsewhere.
			btn.BackgroundTransparency = defaults.bgTransparency
			if btn:IsA("ImageButton") then
				local imageBtn = btn :: ImageButton
				imageBtn.ImageColor3 = SLOT_BUTTON_IMAGE_TINT
				imageBtn.ImageTransparency = defaults.imageTransparency or 0
			end
		end
	end

	local function styleToggleBackpackIcon(btn: GuiButton)
		enableGuiButtonInput(btn)
		-- Don't rewrite Studio Image/ScaleType — only ensure the button is clickable.
		if btn:IsA("ImageButton") then
			btn.AutoButtonColor = false
		end
	end

	local function prepareToggleTiltPivot(gui: GuiObject)
		if gui:GetAttribute("_TiltPivotReady") == true then
			return
		end
		-- Preserve Studio Position/AnchorPoint — only mark ready for tilt scale.
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

	local function brainrotEntryIncomeValue(entry: {
		name: string,
		rarity: string?,
		mutation: string?,
		level: number?,
		baseIncome: number?,
	}): number
		local ok, inc = pcall(function()
			return BrainrotEconomy.incomePerSecond({
				name = entry.name,
				rarity = if typeof(entry.rarity) == "string" then entry.rarity else "common",
				mutation = if typeof(entry.mutation) == "string" then entry.mutation else "normal",
				level = if typeof(entry.level) == "number" then entry.level else 1,
				baseIncome = if typeof(entry.baseIncome) == "number" then entry.baseIncome else 0,
			})
		end)
		return if ok and typeof(inc) == "number" then inc else 0
	end

	local function formatEntryIncomeLabel(entry: {
		name: string,
		rarity: string?,
		mutation: string?,
		level: number?,
		baseIncome: number?,
	}): string
		return BrainrotEconomy.formatCashShort(brainrotEntryIncomeValue(entry)) .. "/s"
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

	local BACKPACK_TEMPLATE_ATTRIBUTE = "_ToolbarBackpackTemplate"
	local BACKPACK_GENERATED_ATTRIBUTE = "_ToolbarGeneratedBackpackRow"
	local BACKPACK_UI_ROW_ATTRIBUTE = "ToolbarBackpackUiRow"
	local backpackTemplateRow: GuiObject? = nil
	local generatedBackpackRows: { [number]: GuiObject } = {}
	local backpackRowSig: { [number]: string } = {}
	local backpackScrollingEnsured = false
	local backpackRowsReady = false

	local function isInsideGeneratedBackpackRow(inst: Instance, container: Instance): boolean
		local p: Instance? = inst.Parent
		while p and p ~= container do
			if p:IsA("GuiObject") and (p :: GuiObject):GetAttribute(BACKPACK_GENERATED_ATTRIBUTE) == true then
				return true
			end
			p = p.Parent
		end
		return false
	end

	findBackpackTemplateRow = function(container: Instance?): GuiObject?
		if not container then
			return nil
		end
		if
			backpackTemplateRow
			and backpackTemplateRow.Parent
			and backpackTemplateRow:GetAttribute(BACKPACK_TEMPLATE_ATTRIBUTE) == true
			and backpackTemplateRow:GetAttribute(BACKPACK_GENERATED_ATTRIBUTE) ~= true
			and not isInsideGeneratedBackpackRow(backpackTemplateRow, container)
		then
			backpackTemplateRow.Visible = false
			backpackTemplateRow.LayoutOrder = 100000
			return backpackTemplateRow
		end
		backpackTemplateRow = nil

		local function consider(candidate: Instance?): GuiObject?
			if
				not candidate
				or not candidate:IsA("GuiObject")
				or candidate:GetAttribute(BACKPACK_GENERATED_ATTRIBUTE) == true
				or isInsideGeneratedBackpackRow(candidate, container)
			then
				return nil
			end
			local gui = candidate :: GuiObject
			gui:SetAttribute(BACKPACK_TEMPLATE_ATTRIBUTE, true)
			gui.Visible = false
			gui.LayoutOrder = 100000
			backpackTemplateRow = gui
			return gui
		end

		local found = consider(container:FindFirstChild("1"))
		if found then
			return found
		end
		for _, child in container:GetChildren() do
			if child:IsA("ScrollingFrame") or child.Name == "Scrolling" or child.Name == "Holder" then
				found = consider(child:FindFirstChild("1"))
				if found then
					return found
				end
			end
		end
		return nil
	end

	local function findGeneratedBackpackRow(container: Instance?, index: number): GuiObject?
		if not container then
			return nil
		end
		local cached = generatedBackpackRows[index]
		if
			cached
			and cached.Parent
			and cached:GetAttribute(BACKPACK_GENERATED_ATTRIBUTE) == true
			and cached:GetAttribute(BACKPACK_UI_ROW_ATTRIBUTE) == index
		then
			return cached
		end
		generatedBackpackRows[index] = nil
		return nil
	end

	local function findBackpackRow(container: Instance?, index: number): GuiObject?
		if not container then
			return nil
		end

		local generated = findGeneratedBackpackRow(container, index)
		if generated then
			return generated
		end
		return nil
	end

	local function ensureBackpackGeneratedRows(container: Instance?)
		if not container then
			return
		end

		if backpackRowsReady then
			local missing = false
			for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
				local row = generatedBackpackRows[idx]
				if not row or not row.Parent then
					missing = true
					break
				end
			end
			if not missing then
				return
			end
		end

		table.clear(generatedBackpackRows)
		local seenIndex: { [number]: GuiObject } = {}
		local destroyedDupes = 0
		for _, inst in container:GetDescendants() do
			if inst:IsA("GuiObject") and inst:GetAttribute(BACKPACK_GENERATED_ATTRIBUTE) == true then
				local rowIndex = inst:GetAttribute(BACKPACK_UI_ROW_ATTRIBUTE)
				if typeof(rowIndex) ~= "number" then
					inst:Destroy()
					destroyedDupes += 1
				else
					local idx = math.floor(rowIndex)
					if idx < 1 or idx > MAX_BACKPACK_BRAINROT_SLOTS then
						inst:Destroy()
						destroyedDupes += 1
					elseif seenIndex[idx] then
						inst:Destroy()
						destroyedDupes += 1
					else
						seenIndex[idx] = inst :: GuiObject
						generatedBackpackRows[idx] = inst :: GuiObject
					end
				end
				if destroyedDupes > 0 and destroyedDupes % 50 == 0 then
					task.wait(0.05)
				end
			end
		end

		local template = findBackpackTemplateRow(container)
		if not template then
			backpackRowsReady = next(generatedBackpackRows) ~= nil
			return
		end

		local rowsParent = template.Parent or container
		template.Visible = false
		template.LayoutOrder = 100000

		for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
			local row = generatedBackpackRows[idx]
			if not row or not row.Parent then
				row = template:Clone()
				row.Visible = false
				row.Parent = rowsParent
			end
			row.Name = "__ToolbarBP_" .. tostring(idx)
			row:SetAttribute(BACKPACK_TEMPLATE_ATTRIBUTE, false)
			row:SetAttribute(BACKPACK_GENERATED_ATTRIBUTE, true)
			row:SetAttribute(BACKPACK_UI_ROW_ATTRIBUTE, idx)
			row.LayoutOrder = idx
			generatedBackpackRows[idx] = row
		end
		backpackRowsReady = true
	end

	local BACKPACK_CHROME_NAMES = {
		"BackpackButtons",
		"OtherButtons",
		"SortButtons",
		"SortCatagory",
		"SortCategory",
	}

	local function ensureBackpackScrollingVisible(root: Instance)
		if backpackScrollingEnsured then
			return
		end
		backpackScrollingEnsured = true
		-- Fixes the backpack scrollbar / visible slider being hidden on load.
		-- This only touches scrolling UI under the backpack frame.
		for _, inst in root:GetDescendants() do
			if inst:IsA("ScrollingFrame") then
				local scrolling = inst :: ScrollingFrame
				scrolling.Visible = true
				scrolling.Active = true
				scrolling.ScrollingEnabled = true
				scrolling.ScrollBarImageTransparency = 0
				if scrolling.ScrollBarThickness <= 0 then
					scrolling.ScrollBarThickness = 8
				end
				if scrolling.AutomaticCanvasSize == Enum.AutomaticSize.None then
					scrolling.AutomaticCanvasSize = Enum.AutomaticSize.Y
				end
			elseif inst.Name == "Scrolling" and inst:IsA("GuiObject") then
				(inst :: GuiObject).Visible = true
			end
		end
	end

	local function scrollBackpackToTop(root: Instance)
		for _, inst in root:GetDescendants() do
			if inst:IsA("ScrollingFrame") then
				(inst :: ScrollingFrame).CanvasPosition = Vector2.new(0, 0)
			end
		end
	end

	local function detachBackpackChromeFromFadeRoot(frame: GuiObject)
		local fadeRoot = frame:FindFirstChild("_BackpackFadeRoot")
		if not fadeRoot then
			return
		end

		-- Repair older/broken versions that moved Backpack.Container/Scrolling into
		-- _BackpackFadeRoot. The real Backpack children must stay directly under
		-- Backpack; otherwise your authored layout and scrolling setup break.
		for _, ch in fadeRoot:GetChildren() do
			ch.Parent = frame
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
		ensureBackpackScrollingVisible(frame)
	end

	local function ensureBackpackContainerTopLeftLayout(container: Instance)
		-- UIGridLayout/UIListLayout can live either directly in Container or inside
		-- Container.Scrolling/Holder with the template row. Do not move Container;
		-- just force the authored layout to start from the top-left.
		ensureBackpackGeneratedRows(container)

		local template = findBackpackTemplateRow(container)
		local rowsParent = if template and template.Parent then template.Parent else container

		local grid = rowsParent:FindFirstChildOfClass("UIGridLayout")
			or container:FindFirstChildWhichIsA("UIGridLayout", true)
		if grid then
			grid.SortOrder = Enum.SortOrder.LayoutOrder
			grid.FillDirection = Enum.FillDirection.Horizontal
			grid.StartCorner = Enum.StartCorner.TopLeft
			grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
			grid.VerticalAlignment = Enum.VerticalAlignment.Top
			return
		end

		local list = rowsParent:FindFirstChildOfClass("UIListLayout")
			or container:FindFirstChildWhichIsA("UIListLayout", true)
		if list then
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.HorizontalAlignment = Enum.HorizontalAlignment.Left
			list.VerticalAlignment = Enum.VerticalAlignment.Top
		end
	end

	local function rebuildBackpackDisplayOrder()
		-- Backpack panel must always fill from TOP-LEFT.
		-- Items freshly sent back to the backpack are pinned first so a high
		-- inventory index does not visually jump to the end of the grid.
		backpackDisplayOrder = {}
		local seen: { [number]: boolean } = {}
		local cleanedFront: { number } = {}

		for _, rawIdx in ipairs(backpackFrontDisplayOrder) do
			local invIndex = math.floor(rawIdx)
			if
				invIndex >= 1
				and brainrotEntries[invIndex] ~= nil
				and (brainrotParkedInUI[invIndex] == true or hotbarSlotForBrainrotIndex(invIndex) == nil)
				and seen[invIndex] ~= true
			then
				seen[invIndex] = true
				table.insert(cleanedFront, invIndex)
				table.insert(backpackDisplayOrder, invIndex)
			end
		end

		backpackFrontDisplayOrder = cleanedFront

		for invIndex = 1, #brainrotEntries do
			if
				seen[invIndex] ~= true
				and brainrotEntries[invIndex] ~= nil
				and (brainrotParkedInUI[invIndex] == true or hotbarSlotForBrainrotIndex(invIndex) == nil)
			then
				seen[invIndex] = true
				table.insert(backpackDisplayOrder, invIndex)
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

	local function normalizedBackpackSearchText(): string
		local q = string.lower((string.gsub((string.gsub(backpackSearchText, "^%s+", "")), "%s+$", "")))
		-- Some Studio templates put the visual placeholder directly in TextBox.Text
		-- instead of PlaceholderText. Treat those as an empty search, otherwise a
		-- refresh after adding/tucking a brainrot filters every row out.
		if q == "" or q == "search" or q == "search." or q == "search.." or q == "search..." then
			return ""
		end
		return q
	end

	local function matchesBackpackSearch(itemName: string): boolean
		local q = normalizedBackpackSearchText()
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
				local row = findBackpackRow(backpackContainer, idx)
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
			TweenService:Create(getOrAddUIScale(frame), HIGHLIGHT_TWEEN, { Scale = BACKPACK_FRAME_DRAG_HOVER_SCALE })
				:Play()
			local stroke = frame:FindFirstChild("ToolbarBackpackOutline")
			if stroke and stroke:IsA("UIStroke") then
				TweenService:Create(stroke, HIGHLIGHT_TWEEN, { Transparency = 0.12 }):Play()
			end
		end
		if backpackContainer then
			-- Do not bulk-grow backpack cells while dragging inside the backpack.
			-- The ghost already gives feedback, and scaling the grid makes the grabbed
			-- brainrot look like it is resizing/pop-corrupting. Keep cells locked at 1.
			for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
				local row = findBackpackRow(backpackContainer, idx)
				if row and row:IsA("GuiObject") and (row :: GuiObject).Visible then
					TweenService:Create(getOrAddUIScale(row), HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
				end
			end
		end
	end

	local function resetHotbarSlotHoverScalesAfterDrag()
		hotbarDragZoneActive = false
		hotbarDragHoverSlot = nil
		for si = 1, HOTBAR_INVENTORY_SLOTS do
			local slot = slots[si]
			if not slot then
				continue
			end
			local sc = getOrAddUIScale(hotbarSlotScaleHost(slot) :: GuiObject)
			TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
		end
	end

	local function setHotbarDragHoverSlot(slotIndex: number?)
		if hotbarDragHoverSlot == slotIndex then
			return
		end
		local prev = hotbarDragHoverSlot
		hotbarDragHoverSlot = slotIndex
		if prev and prev ~= slotIndex then
			local prevSlot = slots[prev]
			if prevSlot then
				local sc = getOrAddUIScale(hotbarSlotScaleHost(prevSlot) :: GuiObject)
				TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
			end
		end
		if slotIndex then
			local slot = slots[slotIndex]
			if slot then
				local sc = getOrAddUIScale(hotbarSlotScaleHost(slot) :: GuiObject)
				TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = HOTBAR_DRAG_HOVER_SCALE }):Play()
			end
		end
	end

	local function updateDragHoverTargets(
		overHotbar: boolean,
		overBackpack: boolean,
		overBackpackPanel: boolean,
		hoveredHotbarSlot: number?
	)
		if overHotbar and not overBackpackPanel then
			hotbarDragZoneActive = true
			setHotbarDragHoverSlot(hoveredHotbarSlot)
		elseif hotbarDragZoneActive or hotbarDragHoverSlot ~= nil then
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

	local function startDragGhost(texture: string, screenPos: Vector2, sourceSize: Vector2?)
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
		im.ScaleType = Enum.ScaleType.Fit
		im.ImageTransparency = 0.05
		local side = 48
		if sourceSize then
			side = math.clamp(math.min(sourceSize.X, sourceSize.Y) * 0.85, 36, 56)
		elseif UserInputService.TouchEnabled then
			side = 44
		end
		im.Size = UDim2.fromOffset(side, side)
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
		if backpackPanelPosTween then
			backpackPanelPosTween:Cancel()
			backpackPanelPosTween = nil
		end
		if backpackContainerScaleTween then
			backpackContainerScaleTween:Cancel()
			backpackContainerScaleTween = nil
		end
		cancelToggleIconTween()
		cancelEmptyHotbarCloseTweens()
	end

	local emptyHotbarCloseTweens: { Tween } = {}

	cancelEmptyHotbarCloseTweens = function()
		for _, tw in emptyHotbarCloseTweens do
			tw:Cancel()
		end
		table.clear(emptyHotbarCloseTweens)
	end

	cancelToggleIconTween = function()
		if toggleIconScaleTween then
			toggleIconScaleTween:Cancel()
			toggleIconScaleTween = nil
		end
	end

	-- resetEmptyHotbarSlotScales / _tweenEmptyHotbarSlotsOut / animateToggleBackpackIcon after hotbar helpers

	-- Keep repairing old empty fade wrappers so they never hold real content.
	local function ensureBackpackFadeRoot(frame: GuiObject)
		local existing = frame:FindFirstChild("_BackpackFadeRoot")
		if existing then
			for _, ch in existing:GetChildren() do
				ch.Parent = frame
			end
		end
	end

	local function getBackpackRestPosition(f: GuiObject): UDim2
		if backpackRestPosition then
			return backpackRestPosition
		end
		local pos = f.Position
		backpackRestPosition = pos
		return pos
	end

	local function prepareBackpackPanelLayer(f: GuiObject, behindHotbar: boolean?)
		-- Open: draw above hotbar. Close: drop behind so the panel doesn't smash through slots.
		if behindHotbar then
			f.ZIndex = BACKPACK_BEHIND_HOTBAR_ZINDEX
			if hotbar:IsA("GuiObject") then
				local hb = hotbar :: GuiObject
				if hb.ZIndex < HOTBAR_FRONT_ZINDEX then
					hb.ZIndex = HOTBAR_FRONT_ZINDEX
				end
			end
		else
			f.ZIndex = BACKPACK_PANEL_ZINDEX
		end
		f.ClipsDescendants = false
		if toolbar:IsA("GuiObject") then
			(toolbar :: GuiObject).ClipsDescendants = false
		end
		if hotbar:IsA("GuiObject") then
			(hotbar :: GuiObject).ClipsDescendants = false
		end
	end

	local function backpackSlideDistance(f: GuiObject): number
		local h = f.AbsoluteSize.Y
		if h > 1 then
			return math.max(BACKPACK_SLIDE_PX, math.floor(h * 0.42 + 0.5))
		end
		return BACKPACK_SLIDE_PX
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

	setBackpackPanelOpen = function(open: boolean)
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
		if open then
			isBackpackPanelClosing = false
			isBackpackPanelOpen = true
			resetEmptyHotbarSlotScales()
		else
			isBackpackPanelOpen = false
			isBackpackPanelClosing = true
			BrainrotItemTooltip.hide(true)
		end
		local f = backpackFrameRef :: GuiObject
		cancelBackpackPanelTweens()
		ensureBackpackFadeRoot(f)
		local sc = getOrAddUIScale(f :: Instance)
		local rest = getBackpackRestPosition(f)
		local slide = backpackSlideDistance(f)
		-- Open: start above and drop down. Close: continue downward behind the hotbar.
		local fromAbove = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset - slide)
		local exitBelow = UDim2.new(rest.X.Scale, rest.X.Offset, rest.Y.Scale, rest.Y.Offset + slide)

		if open then
			animateToggleBackpackIcon(false)
			prepareBackpackPanelLayer(f, false)
			-- Settle empty hotbar slots before the panel appears so layout doesn't jump mid-slide.
			if canUseToolbar then
				showToolbar()
			end
			updateHotbarSlotVisibility()
			for i = 1, #slots do
				refreshSlotVisual(i)
			end
			-- Pose off-screen first, then reveal — avoids one-frame flash at rest (the "jump").
			f.Visible = false
			f.Position = fromAbove
			sc.Scale = BACKPACK_OPEN_START_SCALE
			ensureBackpackChromeVisible(f)
			scrollBackpackToTop(f)
			syncToolbarGamepadCursor()
			task.defer(function()
				if not isBackpackPanelOpen or backpackFrameRef ~= f then
					return
				end
				f.Position = fromAbove
				sc.Scale = BACKPACK_OPEN_START_SCALE
				f.Visible = true
				backpackPanelPosTween = TweenService:Create(f, BACKPACK_OPEN_TWEEN, { Position = rest })
				backpackPanelScaleTween = TweenService:Create(sc, BACKPACK_OPEN_TWEEN, { Scale = 1 })
				backpackPanelPosTween:Play()
				backpackPanelScaleTween:Play()
				task.defer(refreshBrainrotBackpackUI)
			end)
		else
			prepareBackpackPanelLayer(f, true)
			updateHotbarSlotVisibility()
			f.Visible = true
			f.Position = rest
			sc.Scale = 1
			backpackPanelPosTween = TweenService:Create(f, BACKPACK_CLOSE_TWEEN, { Position = exitBelow })
			backpackPanelScaleTween = TweenService:Create(sc, BACKPACK_CLOSE_TWEEN, { Scale = BACKPACK_CLOSE_END_SCALE })
			backpackPanelPosTween:Play()
			backpackPanelScaleTween:Play()
			backpackPanelPosTween.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed and not isBackpackPanelOpen then
					isBackpackPanelClosing = false
					resetEmptyHotbarSlotScales()
					f.Visible = false
					f.Position = rest
					sc.Scale = 1
					-- Collapse empty slots first so icon lands in its final hotbar spot, then ease in.
					updateHotbarSlotVisibility()
					for i = 1, #slots do
						refreshSlotVisual(i)
					end
					syncToolbarGamepadCursor()
					task.defer(function()
						if not isBackpackPanelOpen and not isBackpackPanelClosing then
							animateToggleBackpackIcon(true)
						end
					end)
				end
				if state == Enum.PlaybackState.Completed then
					backpackPanelPosTween = nil
					backpackPanelScaleTween = nil
				end
			end)
		end
	end

	showToolbar = function()
		if LoadingScreenController.isActive() then
			return
		end
		if GameplayUiVisibility.isHidden() then
			return
		end
		if toolbarShown then
			if toggleBackpackIconRef and not isBackpackPanelOpen and not isBackpackPanelClosing then
				if not toggleBackpackIconRef.Visible then
					animateToggleBackpackIcon(true)
				else
					refreshToggleBackpackIconLayout()
				end
			end
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
		local showTween = TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 })
		toolbarVisibilityTween = showTween
		showTween:Play()
		task.defer(function()
			updateHotbarSlotVisibility()
			if not isBackpackPanelOpen and not isBackpackPanelClosing then
				animateToggleBackpackIcon(true)
			end
		end)
	end

	hideToolbar = function(instant: boolean?)
		if not toolbarShown then
			return
		end
		if activeToolbarDrag then
			return
		end
		toolbarShown = false
		cancelToggleIconTween()
		if toggleBackpackIconRef then
			toggleBackpackIconRef.Visible = false
			getOrAddUIScale(toggleBackpackIconRef :: Instance).Scale = 1
		end
		local scale = getOrAddUIScale(toolbar)
		if toolbarVisibilityTween then
			toolbarVisibilityTween:Cancel()
			toolbarVisibilityTween = nil
		end
		if instant then
			scale.Scale = 0.8
			toolbar.Visible = false
			return
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
		if slotTools[index] ~= nil then
			return true
		end
		local mapped = extraToolSlotByIndex[index]
		if mapped and mapped.Parent then
			return true
		end
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		return brainrotIdx ~= nil and brainrotEntries[brainrotIdx] ~= nil and brainrotParkedInUI[brainrotIdx] ~= true
	end

	local function refreshToolbarVisibility()
		if LoadingScreenController.isActive() then
			hideToolbar()
			return
		end
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

	local function _findHotbarSlotForBrainrotName(itemName: string): number?
		for invIndex = 1, #brainrotEntries do
			local e = brainrotEntries[invIndex]
			local slot = hotbarSlotForBrainrotIndex(invIndex)
			if e and slot and e.name == itemName and not brainrotParkedInUI[invIndex] then
				return slot
			end
		end
		return nil
	end

	local function findInventoryIndexForBrainrotName(itemName: string): number?
		-- Prefer newest matching entry (deposits append) so returning Cocofanto
		-- does not select an older duplicate already on the hotbar.
		for invIndex = #brainrotEntries, 1, -1 do
			local e = brainrotEntries[invIndex]
			if e and e.name == itemName and not brainrotParkedInUI[invIndex] then
				return invIndex
			end
		end
		return nil
	end

	tryAutoSelectReturnedBrainrot = function()
		if not canUseToolbar then
			return
		end
		local now = os.clock()
		if now - lastSafezoneAutoEquipAttempt < SAFEZONE_AUTO_EQUIP_DEBOUNCE then
			return
		end
		lastSafezoneAutoEquipAttempt = now

		-- Prefer the brainrot that was on the player's head when they re-entered.
		if pendingReturnedBrainrotName then
			local invIndex = findInventoryIndexForBrainrotName(pendingReturnedBrainrotName)
			if invIndex then
				applyAutoEquipFromSync(invIndex)
				pendingReturnedBrainrotName = nil
				pendingAutoEquipSlot = nil
				return
			end
		end

		-- Backpack tap-to-hold must keep the bag outline; inventory sync must not
		-- promote that item onto the hotbar or re-equip after a deselect.
		if uiBackpackListHighlight ~= nil or uiBackpackExtraHighlight ~= nil then
			pendingAutoEquipSlot = nil
			return
		end

		if typeof(pendingAutoEquipSlot) == "number" then
			local invIndex = math.floor(pendingAutoEquipSlot)
			if brainrotEntries[invIndex] and not brainrotParkedInUI[invIndex] then
				applyAutoEquipFromSync(invIndex)
				pendingAutoEquipSlot = nil
				pendingReturnedBrainrotName = nil
			end
		end
	end

	local zoneExitUiToken = 0

	local function onSafezonePresenceChanged(inZone: boolean)
		if canUseToolbar == inZone then
			-- Mid-load polls can set canUseToolbar while showToolbar no-ops.
			-- Re-assert visibility whenever we confirm we're still in-zone.
			if inZone and not LoadingScreenController.isActive() then
				refreshToolbarVisibility()
			end
			return
		end
		canUseToolbar = inZone
		syncToolbarGamepadCursor()

		if not inZone then
			zoneExitUiToken += 1
			local token = zoneExitUiToken
			pendingReturnedBrainrotName = nil

			if isBackpackPanelOpen then
				setBackpackPanelOpen(false)
			end
			if toolbarShown and not activeToolbarDrag then
				hideToolbar(true)
			end
			if activeToolbarDrag then
				return
			end

			task.defer(function()
				if token ~= zoneExitUiToken or canUseToolbar then
					return
				end
				task.wait()
				if token ~= zoneExitUiToken or canUseToolbar then
					return
				end
				deselectAllHotbarSlots()
				if not activeToolbarDrag then
					clearDragGhost()
					pendingToolbarDrag = nil
				end
			end)
			return
		end

		task.defer(function()
			if canUseToolbar ~= inZone then
				return
			end
			if CarryGate.isCarrying() then
				local name = getPrimaryCarriedBrainrotName()
				if name then
					pendingReturnedBrainrotName = name
				end
			end
			tryAutoSelectReturnedBrainrot()
			refreshToolbarVisibility()
			updateHotbarSlotVisibility()
			refreshToggleBackpackIconLayout()
		end)
	end

	local function isCharacterInToolbarAccessZone(character: Model?): boolean
		if not character then
			return false
		end
		-- SafezoneHitbox (spawn) always unlocks the backpack/hotbar.
		-- RedWall may overlap spawn after the Reddie→RedWall rename — do not let
		-- deposit volume hide the toolbar while the player is still in the safe zone.
		if SafezoneUtil.isCharacterInSafezone(character) then
			return true
		end
		if SafezoneUtil.isCharacterInToolbarZone(character) then
			return true
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position) then
			return false
		end
		return false
	end

	local function toolbarInputAllowed(): boolean
		return canUseToolbar or activeToolbarDrag
	end

	local function pollSafezonePresence()
		local character = player.Character
		local inZone = isCharacterInToolbarAccessZone(character)
		if inZone then
			safezoneOutStreak = 0
			onSafezonePresenceChanged(true)
			return
		end
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position) then
			safezoneOutStreak = SAFEZONE_EXIT_POLLS_REQUIRED
			onSafezonePresenceChanged(false)
			return
		end
		safezoneOutStreak += 1
		if safezoneOutStreak >= SAFEZONE_EXIT_POLLS_REQUIRED then
			onSafezonePresenceChanged(false)
		end
	end

	-- ── Slot highlight ────────────────────────────────────────────────────────────

	-- Selection uses each slot's authored Button.UIStroke (Studio preset, including hotbar 1).
	local SLOT_STROKE_SELECTED = 0
	local SLOT_STROKE_IDLE_FALLBACK = 0.82
	local SLOT_STROKE_SELECTED_COLOR = Color3.fromRGB(255, 255, 255)
	local SLOT_SELECTED_SCALE = 1.08
	local SLOT_IDLE_SCALE = 1.0
	local SLOT_HOVER_SCALE = 1.12
	local authoredStrokeLook: { [UIStroke]: { color: Color3 } } = {}

	local function hotbarSlotRestScale(index: number): number
		if uiHotbarHighlight ~= nil and index == uiHotbarHighlight then
			return SLOT_SELECTED_SCALE
		end
		return SLOT_IDLE_SCALE
	end

	playEquipSlotAnimation = function(index: number)
		local slot = slots[index]
		if not slot then
			return
		end
		local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
		local target = hotbarSlotRestScale(index)
		sc.Scale = target * 0.82
		TweenService:Create(sc, EQUIP_POP_TWEEN, { Scale = target }):Play()
	end

	local function applyHotbarSlotScales()
		for i = 1, #slots do
			local slot = slots[i]
			if not slot then
				continue
			end
			local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
			sc.Scale = hotbarSlotRestScale(i)
		end
	end

	local function authoredSlotStroke(btn: GuiObject): UIStroke?
		local fake = btn:FindFirstChild("ToolbarSlotSelectStroke")
		if fake then
			fake:Destroy()
		end
		for _, ch in btn:GetChildren() do
			if ch:IsA("UIStroke") then
				return ch
			end
		end
		return nil
	end

	local function applyButtonSelectionStyle(btn: GuiObject, lit: boolean)
		local stroke = authoredSlotStroke(btn)
		if not stroke then
			return
		end
		if authoredStrokeLook[stroke] == nil then
			authoredStrokeLook[stroke] = { color = stroke.Color }
		end
		pcall(function()
			(stroke :: any).BorderStrokePosition = Enum.BorderStrokePosition.Center
		end)
		stroke.Enabled = true
		if lit then
			stroke.Color = SLOT_STROKE_SELECTED_COLOR
			stroke.Transparency = SLOT_STROKE_SELECTED
		else
			stroke.Color = authoredStrokeLook[stroke].color
			stroke.Transparency = SLOT_STROKE_IDLE_FALLBACK
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
			if not hotbarDragHoverSlot then
				local slot = slots[i]
				if slot then
					local sc = getOrAddUIScale(hotbarSlotScaleHost(slot))
					TweenService:Create(sc, HIGHLIGHT_TWEEN, { Scale = hotbarSlotRestScale(i) }):Play()
				end
			end
		end
	end

	local function setHotbarSelection(index: number?, animateEquip: boolean?)
		local changed = uiHotbarHighlight ~= index
		uiHotbarHighlight = index
		_activeSlot = index
		if typeof(index) == "number" then
			uiBackpackListHighlight = nil
			uiBackpackExtraHighlight = nil
		end
		syncAllHotbarSelectionStrokes()
		if typeof(syncBackpackSelectionStrokes) == "function" then
			syncBackpackSelectionStrokes()
		end
		if animateEquip ~= false and changed and typeof(index) == "number" then
			playEquipSlotAnimation(index)
		end
	end

	syncBackpackSelectionStrokes = function()
		if backpackContainer then
			for uiRow = 1, MAX_BACKPACK_BRAINROT_SLOTS do
				local row = findBackpackRow(backpackContainer, uiRow)
				if row then
					local btn = slotPrimaryButton(row)
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local lit = typeof(listIdx) == "number" and uiBackpackListHighlight == listIdx
					if btn then
						applyBackpackSlotPanelAppearance(btn, brainrotEntryForBackpackSlot(uiRow) ~= nil)
						applyButtonSelectionStyle(btn, lit)
						local scale = getOrAddUIScale(hotbarSlotScaleHost(row :: GuiObject))
						TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = SLOT_IDLE_SCALE }):Play()
					end
				end
			end
		end
		for tool, row in extraToolRowByTool do
			if row and row.Parent then
				local btn = slotPrimaryButton(row)
				local lit = uiBackpackExtraHighlight == tool
				if btn then
					applyBackpackSlotPanelAppearance(btn, true)
					applyButtonSelectionStyle(btn, lit)
					local scale = getOrAddUIScale(hotbarSlotScaleHost(row :: GuiObject))
					TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = SLOT_IDLE_SCALE }):Play()
				end
			end
		end
	end

	local function resetAllSlotsToIdle()
		for i, slot in ipairs(slots) do
			setSlotHighlight(i, false)
		end
	end

	-- Leaving the safe zone: unequip held brainrot and clear every hotbar selection ring.
	deselectAllHotbarSlots = function()
		BrainrotItemTooltip.hide(true)
		local hum = getHumanoid()
		if hum then
			hum:UnequipTools()
		end
		uiHotbarHighlight = nil
		_activeSlot = nil
		table.clear(slotStrokeLit)
		for si = 1, #slots do
			setSlotHighlight(si, false)
		end
		applyHotbarSlotScales()
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
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		local brainrotEntry = if brainrotIdx then brainrotEntries[brainrotIdx] else nil

		if slotTools[index] ~= nil then
			local tool = slotTools[index] :: Tool
			if tool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
				if typeof(gearId) == "number" then
					setSlotGearViewport(surface, gearId)
				else
					setSlotIcons(surface, "rbxasset://textures/ui/GuiImagePlaceholder.png", true)
				end
				if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
					keyLabel.Text = tostring(index)
				end
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = tool.Name
				end
			elseif tool:GetAttribute("LuckyBlockTool") == true then
				local tex = toolDisplayTexture(tool)
				setSlotIcons(surface, (tex ~= "") and tex or "rbxasset://textures/ui/GuiImagePlaceholder.png", true)
				if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
					keyLabel.Text = tostring(index)
				end
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = luckyBlockDisplayLabel(tool)
				end
			else
				local invIdx = tool:GetAttribute("BrainrotInvIndex")
				local entryForTool = nil
				if typeof(invIdx) == "number" then
					local ei = math.clamp(math.floor(invIdx), 1, math.max(1, #brainrotEntries))
					entryForTool = brainrotEntries[ei]
				end
				local tex = toolDisplayTexture(tool)
				if entryForTool and entryForTool.icon ~= "" then
					tex = entryForTool.icon
				end
				setSlotIcons(surface, (tex ~= "") and tex or "rbxasset://textures/ui/GuiImagePlaceholder.png", true)
				if keyLabel and (keyLabel:IsA("TextLabel") or keyLabel:IsA("TextButton")) then
					keyLabel.Text = tostring(index)
				end
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = if entryForTool then formatEntryIncomeLabel(entryForTool) else tool.Name
				end
			end
		elseif brainrotEntry ~= nil and brainrotIdx and brainrotParkedInUI[brainrotIdx] ~= true then
			local e = brainrotEntry :: { name: string, icon: string, sourcePath: string }
			setSlotIcons(surface, (e.icon ~= "" and e.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png", true)
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
		if slotTools[index] ~= nil then
			return true
		end
		local mapped = extraToolSlotByIndex[index]
		if mapped and mapped.Parent then
			return true
		end
		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		return brainrotIdx ~= nil and brainrotEntries[brainrotIdx] ~= nil and brainrotParkedInUI[brainrotIdx] ~= true
	end

	resetEmptyHotbarSlotScales = function()
		cancelEmptyHotbarCloseTweens()
		for i = 1, #slots do
			local slot = slots[i]
			if slot and not hotbarSlotIsOccupied(i) then
				getOrAddUIScale(hotbarSlotScaleHost(slot)).Scale = hotbarSlotRestScale(i)
			end
		end
	end

	_tweenEmptyHotbarSlotsOut = function()
		-- No per-slot shrink — empty toolbar cells hide together after panel close.
		cancelEmptyHotbarCloseTweens()
	end

	local hotbarListLayout: UIListLayout? = nil
	local hotbarListLayoutCreated = false
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
			backpackRestPosition = backpackFrameRef.Position
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
			hotbarListLayoutCreated = true
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

	local function captureStudioToggleIconSize(icon: GuiObject)
		-- Fallback only — live layout prefers current hotbar slot Size on every refresh.
		if icon:GetAttribute("_StudioSizePinned") == true then
			return
		end
		local sz = icon.Size
		local abs = icon.AbsoluteSize
		local w = if sz.X.Offset >= 8 then sz.X.Offset elseif abs.X >= 8 then abs.X else nil
		local h = if sz.Y.Offset >= 8 then sz.Y.Offset elseif abs.Y >= 8 then abs.Y else nil
		if typeof(w) == "number" and typeof(h) == "number" then
			icon:SetAttribute("_PinnedW", math.floor(w + 0.5))
			icon:SetAttribute("_PinnedH", math.floor(h + 0.5))
			icon:SetAttribute("_StudioSizePinned", true)
		end
	end

	local function scaledToggleIconSizeFromTemplate(slotTemplate: UDim2): UDim2
		-- Preserve Scale so the icon tracks viewport the same way slots do.
		local ox = slotTemplate.X.Offset
		local oy = slotTemplate.Y.Offset
		if slotTemplate.X.Scale ~= 0 or slotTemplate.Y.Scale ~= 0 then
			return UDim2.new(
				slotTemplate.X.Scale,
				math.floor(ox * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5),
				slotTemplate.Y.Scale,
				math.floor(oy * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5)
			)
		end
		if ox < 8 or oy < 8 then
			return slotTemplate
		end
		return UDim2.fromOffset(
			math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(ox * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5)),
			math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(oy * TOGGLE_BACKPACK_ICON_SIZE_SCALE + 0.5))
		)
	end

	local function ensureToggleBackpackIconSizeConstraint(icon: GuiObject)
		local minW = icon:GetAttribute("_MinW")
		local minH = icon:GetAttribute("_MinH")
		if typeof(minW) ~= "number" or typeof(minH) ~= "number" then
			return
		end
		-- Fixed pixel clamp only — never AbsoluteSize + ScaleWithParentSize (Studio timeout loop).
		local aspect = icon:FindFirstChild("ToggleIconAspect")
		if aspect then
			aspect:Destroy()
		end
		local constraint = icon:FindFirstChild("ToggleIconSizeConstraint")
		if not constraint or not constraint:IsA("UISizeConstraint") then
			constraint = Instance.new("UISizeConstraint")
			constraint.Name = "ToggleIconSizeConstraint"
			constraint.Parent = icon
		end
		local sizeLock = constraint :: UISizeConstraint
		sizeLock.MinSize = Vector2.new(minW :: number, minH :: number)
		sizeLock.MaxSize = Vector2.new(minW :: number, minH :: number)
	end

	local toggleIconResizeToken = 0
	local function scheduleToggleBackpackIconLayoutRefresh()
		toggleIconResizeToken += 1
		local token = toggleIconResizeToken
		task.defer(function()
			if token ~= toggleIconResizeToken then
				return
			end
			refreshToggleBackpackIconLayout()
		end)
	end

	local function wireToggleBackpackIconResizeSync()
		-- Viewport-only: hotbar AbsoluteSize sync caused icon drift / spacing blowout.
		if hotbar:GetAttribute("_ToggleIconResizeWired") == true then
			return
		end
		hotbar:SetAttribute("_ToggleIconResizeWired", true)
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(scheduleToggleBackpackIconLayoutRefresh)
		end
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			local cam = workspace.CurrentCamera
			if cam then
				cam:GetPropertyChangedSignal("ViewportSize"):Connect(scheduleToggleBackpackIconLayoutRefresh)
			end
		end)
	end

	local function captureToggleIconPixelSize(icon: GuiObject): (number?, number?)
		-- Prefer live hotbar slot AbsoluteSize so resize keeps icon matched to slots.
		for i = 1, HOTBAR_INVENTORY_SLOTS do
			local slot = slots[i]
			if slot and slot:IsA("GuiObject") and (slot :: GuiObject).Visible then
				local rabs = (slot :: GuiObject).AbsoluteSize
				if rabs.X >= 8 and rabs.Y >= 8 then
					return rabs.X, rabs.Y
				end
			end
		end
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
		return nil, nil
	end

	refreshToggleBackpackIconLayout = function()
		if not toggleBackpackIconRef then
			return
		end
		local icon = toggleBackpackIconRef :: GuiObject
		-- Size/parent only — visibility is owned by animateToggleBackpackIcon / toolbar show.
		captureStudioToggleIconSize(icon)

		local layout = ensureHotbarListLayout()
		-- Only tighten spacing when we had to create the layout; never stomp Studio padding.
		if hotbarListLayoutCreated then
			layout.Padding = UDim.new(0, 2)
		end
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center

		-- Prefer Studio-authored size. Fall back to full hotbar slot size (no shrink).
		local w, h = captureToggleIconPixelSize(icon)
		local iconSize: UDim2
		if typeof(w) == "number" and typeof(h) == "number" then
			iconSize = UDim2.fromOffset(
				math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(w + 0.5)),
				math.max(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, math.floor(h + 0.5))
			)
		else
			local slotTemplate = getHotbarSlotSizeTemplate()
			if slotTemplate then
				iconSize = scaledToggleIconSizeFromTemplate(slotTemplate)
			else
				iconSize = UDim2.fromOffset(TOGGLE_BACKPACK_ICON_MIN_ABS_PX, TOGGLE_BACKPACK_ICON_MIN_ABS_PX)
			end
		end
		icon.Size = iconSize

		icon.AnchorPoint = Vector2.new(0, 0)
		if icon.Parent ~= hotbar then
			icon.Parent = hotbar
		end
		icon.LayoutOrder = 100

		pinToggleIconMinAbsoluteSize(icon, iconSize.X.Offset, iconSize.Y.Offset)
		ensureToggleBackpackIconSizeConstraint(icon)
	end

	animateToggleBackpackIcon = function(show: boolean)
		if not toggleBackpackIconRef then
			return
		end
		local icon = toggleBackpackIconRef :: GuiObject
		cancelToggleIconTween()
		local sc = getOrAddUIScale(icon :: Instance)

		if show then
			if not (canUseToolbar and toolbarShown) then
				icon.Visible = false
				sc.Scale = 1
				return
			end
			refreshToggleBackpackIconLayout()
			icon.Visible = true
			sc.Scale = 0.55
			local tw = TweenService:Create(sc, BACKPACK_ICON_IN_TWEEN, { Scale = 1 })
			toggleIconScaleTween = tw
			tw:Play()
			tw.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then
					sc.Scale = 1
				end
				if toggleIconScaleTween == tw then
					toggleIconScaleTween = nil
				end
			end)
		else
			if not icon.Visible then
				sc.Scale = 1
				return
			end
			sc.Scale = math.clamp(sc.Scale, 0.55, 1)
			local tw = TweenService:Create(sc, BACKPACK_ICON_OUT_TWEEN, { Scale = 0.55 })
			toggleIconScaleTween = tw
			tw:Play()
			tw.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then
					icon.Visible = false
					sc.Scale = 1
				end
				if toggleIconScaleTween == tw then
					toggleIconScaleTween = nil
				end
			end)
		end
	end

	updateHotbarSlotVisibility = function()
		ensureHotbarListLayout()
		local toolbarActive = canUseToolbar and toolbarShown
		local anyOccupied = false
		for i = 1, #slots do
			if hotbarSlotIsOccupied(i) then
				anyOccupied = true
				break
			end
		end
		-- Empty hotbar cells while backpack is open or still closing (avoids snap-hide mid-tween).
		local showEmptyDropTargets = isBackpackPanelOpen or isBackpackPanelClosing
		local showHotbarSlots = anyOccupied or showEmptyDropTargets
		-- Keep the Hotbar frame visible whenever the toolbar is up so ToggleBackpackImage
		-- (a child of Hotbar) still shows when every slot is empty.
		if hotbar:IsA("GuiObject") then
			(hotbar :: GuiObject).Visible = toolbarActive
		end
		for i = 1, #slots do
			local slot = slots[i]
			if slot then
				slot.Visible = toolbarActive and showHotbarSlots and (hotbarSlotIsOccupied(i) or showEmptyDropTargets)
			end
		end
		-- Icon visibility/scale is driven by animateToggleBackpackIcon — don't snap Visible here.
		if
			toggleBackpackIconRef
			and toggleBackpackIconRef.Visible
			and toolbarActive
			and not isBackpackPanelOpen
			and not isBackpackPanelClosing
		then
			task.defer(refreshToggleBackpackIconLayout)
		elseif toggleBackpackIconRef and not toolbarActive then
			cancelToggleIconTween()
			toggleBackpackIconRef.Visible = false
			getOrAddUIScale(toggleBackpackIconRef :: Instance).Scale = 1
		end
	end

	local lastBackpackToggleAt = 0.0
	local function toggleBackpackPanel()
		if not canUseToolbar then
			return
		end
		if not backpackFrameRef then
			return
		end
		local now = os.clock()
		if now - lastBackpackToggleAt < 0.12 then
			return
		end
		lastBackpackToggleAt = now
		setBackpackPanelOpen(not isBackpackPanelOpen)
	end

	local function findToggleBackpackImageHost(): GuiObject?
		local underToolbar = toolbar:FindFirstChild("ToggleBackpackImage")
		if underToolbar and underToolbar:IsA("GuiObject") then
			return underToolbar
		end
		local underHotbar = hotbar:FindFirstChild("ToggleBackpackImage")
		if underHotbar and underHotbar:IsA("GuiObject") then
			return underHotbar
		end
		local backpack = toolbar:FindFirstChild("Backpack")
		if backpack then
			local underBp = backpack:FindFirstChild("ToggleBackpackImage")
			if underBp and underBp:IsA("GuiObject") then
				return underBp
			end
		end
		return nil
	end

	local function ensureToggleBackpackHitButton(iconHost: GuiObject): GuiButton
		if iconHost:IsA("GuiButton") then
			return iconHost :: GuiButton
		end
		local nested = slotPrimaryButton(iconHost)
		if nested then
			nested.Size = UDim2.fromScale(1, 1)
			nested.Position = UDim2.fromScale(0, 0)
			nested.BackgroundTransparency = 1
			if nested:IsA("ImageButton") then
				(nested :: ImageButton).ImageTransparency = 1
			end
			if nested:IsA("TextButton") then
				(nested :: TextButton).Text = ""
			end
			return nested
		end
		local existing = iconHost:FindFirstChild("_ToggleHit")
		if existing and existing:IsA("GuiButton") then
			return existing
		end
		local hit = Instance.new("TextButton")
		hit.Name = "_ToggleHit"
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.Size = UDim2.fromScale(1, 1)
		hit.Position = UDim2.fromScale(0, 0)
		hit.AnchorPoint = Vector2.new(0, 0)
		hit.ZIndex = iconHost.ZIndex + 8
		hit.Parent = iconHost
		return hit
	end

	local function wireToggleBackpackIcon()
		local iconHost = findToggleBackpackImageHost()
		if not iconHost then
			return
		end
		toggleBackpackIconRef = iconHost
		toggleBackpackRef = iconHost

		-- Hotbar is non-interactive for slot hit-testing; the icon itself must still receive clicks.
		-- Studio often uses an ImageLabel here, so clicks were falling through to the world.
		iconHost.Active = true
		passthroughChildClicks(iconHost)
		local btn = ensureToggleBackpackHitButton(iconHost)
		enableGuiButtonInput(btn)
		-- Pin Studio size BEFORE any layout pass mutates it.
		captureStudioToggleIconSize(iconHost)
		styleToggleBackpackIcon(btn)
		GamepadInput.mountHint(iconHost, GamepadInput.SECONDARY)
		local tiltTarget = resolveToggleBackpackVisual(iconHost, btn)
		if tiltTarget ~= iconHost then
			prepareToggleTiltPivot(tiltTarget)
		end
		-- Same toggle as ` / Y. skipTapGate so a camera-drag doesn't eat this click.
		UIButtonEffects.wireTiltHoverButton(btn, toggleBackpackPanel, iconHost, tiltTarget, false, true)
		wireToggleBackpackIconResizeSync()
		task.defer(function()
			-- Second pin after AbsoluteSize settles (scale-sized Studio icons).
			captureStudioToggleIconSize(iconHost)
			refreshToggleBackpackIconLayout()
			if canUseToolbar and toolbarShown and not isBackpackPanelOpen and not isBackpackPanelClosing then
				animateToggleBackpackIcon(true)
			end
		end)
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
		-- Hotbar 1..9 displays whichever server inventory index is mapped to that slot.
		for i = 1, maxHotbar do
			local invIndex = brainrotIndexForHotbarSlot(i)
			if invIndex and brainrotParkedInUI[invIndex] ~= true then
				local t = if char then findBrainrotToolAtInvIndex(char, invIndex) else nil
				if not t and backpack then
					t = findBrainrotToolAtInvIndex(backpack, invIndex)
				end
				slotTools[i] = t
			else
				slotTools[i] = nil
			end
		end

		-- Drop stale extra-tool slot pins; keep equipped tools visible in the hotbar.
		sanitizeExtraToolSlotPins()
		for idx, tool in pairs(extraToolSlotByIndex) do
			if not tool.Parent or not isExtraHotbarTool(tool) then
				extraToolSlotByIndex[idx] = nil
			end
		end

		-- Workout gear always claims slot 1 (brainrot there → backpack inventory UI).
		ensureWorkoutGearOwnsHotbarSlot1(maxHotbar)

		local extras = collectExtraHotbarTools()
		local assignedExtras: { [Tool]: boolean } = {}

		for idx, tool in pairs(extraToolSlotByIndex) do
			if idx >= 1 and idx <= maxHotbar and slotTools[idx] == nil and slotCanHoldExtraTool(idx) then
				if tool.Parent then
					slotTools[idx] = tool
					assignedExtras[tool] = true
				else
					extraToolSlotByIndex[idx] = nil
				end
			elseif idx == 1 and tool:GetAttribute("WorkoutGearTool") == true and tool.Parent then
				-- Keep gear pinned even if slotTools was briefly occupied during rebuild.
				slotTools[1] = tool
				assignedExtras[tool] = true
			end
		end

		for _, tool in ipairs(extras) do
			if tool:GetAttribute("WorkoutGearTool") == true then
				if isExtraToolParked(tool) then
					continue
				end
				removeExtraToolFromParkedList(tool)
				if not assignedExtras[tool] then
					extraToolSlotByIndex[1] = tool
					slotTools[1] = tool
					assignedExtras[tool] = true
				end
				continue
			end

			if isExtraToolParked(tool) then
				continue
			end

			if not assignedExtras[tool] then
				local placedInHotbar = false

				for i = 1, maxHotbar do
					if slotTools[i] == nil and slotCanHoldExtraTool(i) then
						slotTools[i] = tool
						extraToolSlotByIndex[i] = tool
						assignedExtras[tool] = true
						placedInHotbar = true
						break
					end
				end

				-- IMPORTANT:
				-- If there is no hotbar slot available, do NOT let the Lucky Block become invisible.
				-- Park it in the backpack UI instead.
				if not placedInHotbar and tool.Parent then
					removeExtraToolFromAllHotbarSlots(tool)

					local wasParked = isExtraToolParked(tool)
					if not wasParked then
						table.insert(parkedExtraTools, tool)
						-- Open bag so the parked lucky block is obvious when hotbar is full.
						if tool:GetAttribute("LuckyBlockTool") == true then
							task.defer(function()
								if setBackpackPanelOpen and canUseToolbar then
									setBackpackPanelOpen(true)
								end
							end)
						end
					end
				end
			end
		end

		-- Refresh visuals
		for i = 1, #slots do
			refreshSlotVisual(i)
		end
		updateHotbarSlotVisibility()
		refreshParkedExtraToolsUI()

		-- Highlight follows the equipped brainrot's hotbar cell. Never keep a backpack
		-- outline while the same tool is on the hotbar (that desyncs the rings).
		local equippedSlot: number? = nil
		if equipped then
			local invIdx = equipped:GetAttribute("BrainrotInvIndex")
			if typeof(invIdx) == "number" then
				local raw = math.floor(invIdx)
				equippedSlot = hotbarSlotForBrainrotIndex(raw)
			else
				for i = 1, #slots do
					if slotTools[i] == equipped then
						equippedSlot = i
						break
					end
				end
			end
		end
		-- Keep a backpack outline while that bag item is equipped. Do not steal
		-- the ring back onto a hotbar cell.
		if uiBackpackListHighlight ~= nil or uiBackpackExtraHighlight ~= nil then
			uiHotbarHighlight = nil
			_activeSlot = nil
		elseif equippedSlot then
			local equippedTool = slotTools[equippedSlot]
			local isGear = equippedTool ~= nil and equippedTool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true
			-- Gear lives in slot 1; don't treat it as a selected brainrot ring.
			if not isGear then
				uiHotbarHighlight = equippedSlot
			elseif uiHotbarHighlight ~= equippedSlot then
				uiHotbarHighlight = nil
			end
		elseif uiHotbarHighlight ~= nil then
			local hi = math.clamp(uiHotbarHighlight, 1, HOTBAR_INVENTORY_SLOTS)
			local hiBrainrotIdx = brainrotIndexForHotbarSlot(hi)
			local slotStillHasBrainrot = slotTools[hi] ~= nil
				or extraToolSlotByIndex[hi] ~= nil
				or (
					hiBrainrotIdx ~= nil
					and brainrotEntries[hiBrainrotIdx] ~= nil
					and brainrotParkedInUI[hiBrainrotIdx] ~= true
				)
			if not slotStillHasBrainrot then
				uiHotbarHighlight = nil
			end
		end
		if uiHotbarHighlight ~= nil then
			uiHotbarHighlight = math.clamp(uiHotbarHighlight, 1, HOTBAR_INVENTORY_SLOTS)
			_activeSlot = uiHotbarHighlight
		else
			_activeSlot = nil
		end
		syncAllHotbarSelectionStrokes()
		syncBackpackSelectionStrokes()

		refreshToolbarVisibility()
	end

	local rebuildSlotsQueued = false
	local function queueRebuildSlots()
		if rebuildSlotsQueued then
			return
		end
		rebuildSlotsQueued = true
		task.defer(function()
			rebuildSlotsQueued = false
			rebuildSlots()
		end)
	end

	refreshBrainrotBackpackUI = function()
		local container = backpackContainer
		if not container then
			return
		end
		rebuildBackpackDisplayOrder()
		ensureBackpackContainerTopLeftLayout(container)
		if backpackFrameRef then
			ensureBackpackScrollingVisible(backpackFrameRef)
		end

		local hasActiveSearch = normalizedBackpackSearchText() ~= ""

		for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
			local row = findBackpackRow(container, idx)
			if not row or not row:IsA("GuiObject") then
				continue
			end

			(row :: GuiObject).LayoutOrder = idx

			local entry = brainrotEntryForBackpackSlot(idx)
			local listIdx = listIndexForBackpackUiRow(idx)
			if entry and hasActiveSearch and not matchesBackpackSearch(entry.name) then
				entry = nil
				listIdx = nil
			end

			row.Visible = entry ~= nil

			local icon = ""
			local income = ""
			local keyText = tostring(idx)
			if entry then
				icon = entry.icon ~= "" and entry.icon or "rbxasset://textures/ui/GuiImagePlaceholder.png"
				income = formatEntryIncomeLabel(entry)
				keyText = if listIdx then tostring(listIdx) else tostring(idx)
			end
			local sig = (if entry then "1" else "0") .. "|" .. tostring(listIdx or 0) .. "|" .. icon .. "|" .. income .. "|" .. keyText
			if backpackRowSig[idx] == sig then
				continue
			end
			backpackRowSig[idx] = sig

			local surface = toolSlotSurface(row :: GuiObject)
			local rate = surface:FindFirstChild("Rate")
			local key = surface:FindFirstChild("Key")

			if entry then
				setSlotIcons(surface, icon, true)
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = income
				end
				if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
					key.Text = keyText
				end
			else
				setSlotIcons(surface, "", false)
				if rate and (rate:IsA("TextLabel") or rate:IsA("TextButton")) then
					rate.Text = ""
				end
				if key and (key:IsA("TextLabel") or key:IsA("TextButton")) then
					key.Text = keyText
				end
			end

			local btn = slotPrimaryButton(row :: GuiObject)
			if btn then
				applyBackpackSlotPanelAppearance(btn, entry ~= nil)
			end
			passthroughChildClicks(surface :: GuiObject)
		end

		refreshParkedExtraToolsUI()
		if typeof(syncBackpackSelectionStrokes) == "function" then
			syncBackpackSelectionStrokes()
		end
	end

	local function findBestBrainrotInventoryIndex(): number?
		local bestIdx: number? = nil
		local bestIncome = -math.huge
		for i, entry in ipairs(brainrotEntries) do
			local inc = brainrotEntryIncomeValue(entry)
			if inc > bestIncome then
				bestIncome = inc
				bestIdx = i
			end
		end
		return bestIdx
	end

	local function isBestBrainrotAlreadyEquipped(): boolean
		local bestIdx = findBestBrainrotInventoryIndex()
		if not bestIdx then
			return true
		end
		local char = player.Character
		local equipped = char and char:FindFirstChildOfClass("Tool")
		if not equipped or equipped:GetAttribute("BrainrotTool") ~= true then
			return false
		end
		local a = equipped:GetAttribute("BrainrotInvIndex")
		return typeof(a) == "number" and math.floor(a) == bestIdx
	end

	local function requestEquipBestBrainrot()
		if not canUseToolbar then
			return
		end
		-- Already holding the highest-income brainrot — no remote, toast, or reshuffle.
		if isBestBrainrotAlreadyEquipped() then
			return
		end

		-- Debounce Equip Best so it cannot double-fire while sync packets are still arriving.
		local now = os.clock()
		if now < equipBestBusyUntil then
			return
		end
		equipBestBusyUntil = now + 0.75

		local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
		local equipEv = folder and folder:FindFirstChild("EquipBestBrainrot")
		if not equipEv or not equipEv:IsA("RemoteEvent") then
			warn("[ToolbarController] EquipBestBrainrot remote missing")
			return
		end
		-- Server picks highest-income brainrot and equips it (moves to hotbar if needed).
		(equipEv :: RemoteEvent):FireServer()
	end

	local optimisticBrainrotMoveToHotbar: (number, number) -> ()

	local function firstEmptyHotbarSlot(preferredSlot: number?): number?
		local startSlot = 1
		local gearTool = findWorkoutGearTool()
		if gearTool and not isExtraToolParked(gearTool) then
			startSlot = 2
		end
		if typeof(preferredSlot) == "number" then
			local preferred = math.clamp(math.floor(preferredSlot), startSlot, HOTBAR_INVENTORY_SLOTS)
			if preferred >= startSlot and not hotbarSlotIsOccupied(preferred) then
				return preferred
			end
		end

		for slot = startSlot, HOTBAR_INVENTORY_SLOTS do
			if not hotbarSlotIsOccupied(slot) then
				return slot
			end
		end

		return nil
	end

	local function refreshAfterLocalBrainrotMove()
		refreshBrainrotBackpackUI()
		queueRebuildSlots()
	end

	local function _setLocalBrainrotTucked(index: number, tucked: boolean)
		if index < 1 or index > HOTBAR_INVENTORY_SLOTS then
			return
		end
		if brainrotEntries[index] == nil then
			brainrotParkedInUI[index] = nil
			return
		end
		if tucked then
			brainrotParkedInUI[index] = true
		else
			brainrotParkedInUI[index] = nil
		end
	end

	local function localBrainrotIsBackpackVisible(index: number): boolean
		return brainrotParkedInUI[index] == true or hotbarSlotForBrainrotIndex(index) == nil
	end

	local function brainrotUidAtIndex(index: number): string?
		local entry = brainrotEntries[index]
		if entry and typeof(entry.uid) == "string" and entry.uid ~= "" then
			return entry.uid
		end
		return nil
	end

	local function resolveBrainrotIndexForDrag(index: number, uid: string?): number?
		if typeof(uid) == "string" and uid ~= "" then
			for invIndex, entry in ipairs(brainrotEntries) do
				if entry and entry.uid == uid then
					return invIndex
				end
			end
		end

		if typeof(index) == "number" and brainrotEntries[index] ~= nil then
			return index
		end

		return nil
	end

	local function freezeCurrentHotbarLayout()
		-- Make every currently visible hotbar brainrot explicit before a drag mutation.
		-- Without this, legacy/default slot fallback can refill empty cells and make
		-- unrelated pets jump to other hotbar positions after one pet is tucked.
		local frozen: { [number]: number } = {}
		for slot = 1, HOTBAR_INVENTORY_SLOTS do
			local invIndex = brainrotIndexForHotbarSlot(slot)
			if invIndex and brainrotEntries[invIndex] and brainrotParkedInUI[invIndex] ~= true then
				frozen[invIndex] = slot
			end
		end
		brainrotHotbarSlotByIndex = frozen
		rebuildBrainrotHotbarReverseMap()
	end

	local function moveBrainrotBackpackDisplayRow(listIdx: number, destUiRow: number)
		if not brainrotEntries[listIdx] or not localBrainrotIsBackpackVisible(listIdx) then
			return
		end

		rebuildBackpackDisplayOrder()
		local order: { number } = {}
		local seen: { [number]: boolean } = {}

		for _, invIndex in ipairs(backpackDisplayOrder) do
			if invIndex ~= listIdx and seen[invIndex] ~= true then
				seen[invIndex] = true
				table.insert(order, invIndex)
			end
		end

		local insertAt = math.clamp(math.floor(destUiRow), 1, #order + 1)
		table.insert(order, insertAt, listIdx)
		backpackFrontDisplayOrder = order
		refreshBrainrotBackpackUI()
	end

	local function optimisticBrainrotTuckToBackpack(listIdx: number)
		if not brainrotEntries[listIdx] then
			return
		end
		freezeCurrentHotbarLayout()
		brainrotParkedInUI[listIdx] = true
		brainrotHotbarSlotByIndex[listIdx] = nil
		for i = #backpackFrontDisplayOrder, 1, -1 do
			if backpackFrontDisplayOrder[i] == listIdx then
				table.remove(backpackFrontDisplayOrder, i)
			end
		end
		table.insert(backpackFrontDisplayOrder, 1, listIdx)
		rebuildBrainrotHotbarReverseMap()
		refreshAfterLocalBrainrotMove()
	end

	optimisticBrainrotMoveToHotbar = function(listIdx: number, targetSlot: number)
		if not brainrotEntries[listIdx] then
			return
		end
		freezeCurrentHotbarLayout()
		local target = math.clamp(math.floor(targetSlot), 1, HOTBAR_INVENTORY_SLOTS)
		local oldSlot = hotbarSlotForBrainrotIndex(listIdx)
		local displacedIdx = brainrotIndexForHotbarSlot(target)

		if displacedIdx and displacedIdx ~= listIdx then
			if oldSlot then
				brainrotHotbarSlotByIndex[displacedIdx] = oldSlot
				brainrotParkedInUI[displacedIdx] = nil
			else
				brainrotHotbarSlotByIndex[displacedIdx] = nil
				brainrotParkedInUI[displacedIdx] = true
			end
		end

		brainrotHotbarSlotByIndex[listIdx] = target
		brainrotParkedInUI[listIdx] = nil
		for i = #backpackFrontDisplayOrder, 1, -1 do
			if backpackFrontDisplayOrder[i] == listIdx then
				table.remove(backpackFrontDisplayOrder, i)
			end
		end
		rebuildBrainrotHotbarReverseMap()
		refreshAfterLocalBrainrotMove()
	end

	local function _optimisticBrainrotMoveToBackpackIndex(listIdx: number, _destListIdx: number)
		-- Keep server inventory order authoritative. Locally, just remove it from
		-- the visible hotbar so it does not snap back while waiting for sync.
		optimisticBrainrotTuckToBackpack(listIdx)
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

	local function fireBrainrotPark(listIdx: number, tucked: boolean, hotbarSlot: number?)
		local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
		local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
		if parkEv and parkEv:IsA("RemoteEvent") then
			if typeof(hotbarSlot) == "number" then
				(parkEv :: RemoteEvent):FireServer(listIdx, tucked, hotbarSlot)
			else
				(parkEv :: RemoteEvent):FireServer(listIdx, tucked)
			end
		end
	end

	local function gamepadTuckHotbarSlot(slotIndex: number): boolean
		if not GamepadInput.isPreferred() then
			return false
		end
		local idx = brainrotIndexForHotbarSlot(slotIndex)
		if idx and brainrotEntries[idx] and not brainrotParkedInUI[idx] then
			if not isBackpackPanelOpen then
				setBackpackPanelOpen(true)
			end
			optimisticBrainrotTuckToBackpack(idx)
			fireBrainrotPark(idx, true)
			UIInteractionSounds.playClick()
			return true
		end
		local extra = extraToolAtHotbarSlot(slotIndex)
		if extra then
			if not isBackpackPanelOpen then
				setBackpackPanelOpen(true)
			end
			parkExtraToolInBackpack(extra, slotIndex)
			refreshParkedExtraToolsUI()
			UIInteractionSounds.playClick()
			return true
		end
		return false
	end
	local function requestEquipFromBackpack(listIdx: number)
		if not canUseToolbar then
			return
		end
		if not brainrotEntries[listIdx] then
			return
		end

		if uiBackpackListHighlight == listIdx then
			pendingAutoEquipSlot = nil
			local hum = getHumanoid()
			if hum then
				hum:UnequipTools()
			end
			uiBackpackListHighlight = nil
			uiBackpackExtraHighlight = nil
			uiHotbarHighlight = nil
			_activeSlot = nil
			syncAllHotbarSelectionStrokes()
			syncBackpackSelectionStrokes()
			queueRebuildSlots()
			return
		end

		local hum = getHumanoid()
		if hum then
			hum:UnequipTools()
		end
		uiHotbarHighlight = nil
		_activeSlot = nil
		uiBackpackListHighlight = listIdx
		uiBackpackExtraHighlight = nil
		syncAllHotbarSelectionStrokes()
		syncBackpackSelectionStrokes()
		requestEquipBrainrotSlot(listIdx, true)
		queueRebuildSlots()
		task.delay(0.2, queueRebuildSlots)
	end

	-- Lucky blocks / extra tools parked in the bag: tap to equip without a hotbar cell.
	requestEquipFromBackpackExtra = function(tool: Tool)
		if not canUseToolbar then
			return
		end
		if not tool.Parent then
			return
		end
		local hum = getHumanoid()
		if not hum then
			return
		end
		local char = player.Character
		local equipped = char and char:FindFirstChildOfClass("Tool")
		if equipped == tool then
			hum:UnequipTools()
			setHotbarSelection(nil, false)
			uiBackpackListHighlight = nil
			uiBackpackExtraHighlight = nil
			syncBackpackSelectionStrokes()
			queueRebuildSlots()
			return
		end
		-- Equip from the bag cell; keep the inventory outline.
		setHotbarSelection(nil, false)
		uiBackpackListHighlight = nil
		uiBackpackExtraHighlight = tool
		syncBackpackSelectionStrokes()
		hum:EquipTool(tool)
		UIInteractionSounds.playClick()
		queueRebuildSlots()
		refreshParkedExtraToolsUI()
	end

	local function wireBrainrotBackpackEquips()
		if backpackEquipWired or not backpackContainer then
			return
		end
		ensureBackpackGeneratedRows(backpackContainer)
		backpackEquipWired = true
		for uiRow = 1, MAX_BACKPACK_BRAINROT_SLOTS do
			local row = findBackpackRow(backpackContainer, uiRow)
			if not row or not row:IsA("GuiObject") then
				continue
			end
			local btn = slotPrimaryButton(row :: GuiObject)
			if btn then
				configureHotbarSlotInput(row :: GuiObject, btn)
				styleToolbarSlotButton(btn)
				local scale = getOrAddUIScale(hotbarSlotScaleHost(row :: GuiObject))
				btn.MouseEnter:Connect(function()
					if pendingToolbarDrag or activeToolbarDrag or hotbarDragZoneActive or not canUseToolbar then
						return
					end
					UIInteractionSounds.playHover()
				end)
				btn.MouseLeave:Connect(function()
					BrainrotItemTooltip.hide(true)
					TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = SLOT_IDLE_SCALE }):Play()
				end)
				if btn:GetAttribute("_BrainrotTooltipBound") ~= true then
					btn:SetAttribute("_BrainrotTooltipBound", true)
					local rowIndex = uiRow
					BrainrotItemTooltip.bind(btn, function()
						local entry = brainrotEntryForBackpackSlot(rowIndex)
						return if entry then entry.name else nil
					end)
				end
				btn.Activated:Connect(function()
					if not MobileTouchGate.canTapUi() then
						return
					end
					if not canUseToolbar then
						return
					end
					if dragSuppressedToolbarClick then
						dragSuppressedToolbarClick = false
						return
					end
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local entry = brainrotEntryForBackpackSlot(uiRow)
					if not listIdx or not entry then
						return
					end
					UIInteractionSounds.playClick()
					requestEquipFromBackpack(listIdx)
				end)
				btn.MouseButton1Down:Connect(function()
					if not canUseToolbar then
						return
					end
					if pendingToolbarDrag then
						return
					end
					if dtIsTouchPointerInput() then
						return
					end
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local entry = brainrotEntryForBackpackSlot(uiRow)
					if not listIdx or not entry then
						return
					end
					if GamepadInput.isPreferred() then
						requestEquipFromBackpack(listIdx)
						dragSuppressedToolbarClick = true
						return
					end
					UIInteractionSounds.playClick()
					BrainrotItemTooltip.hide(true)
					local tex = (entry.icon ~= "" and entry.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
					lastResolvedHotbarDropSlot = nil
					activeToolbarDrag = true
					TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
					pendingToolbarDrag = {
						kind = "backpack",
						idx = listIdx,
						start = UserInputService:GetMouseLocation(),
						texture = tex,
						uid = brainrotUidAtIndex(listIdx),
						sourceSize = btn.AbsoluteSize,
						rowButton = btn,
						equippedOnDown = false,
					}
				end)
				btn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= GamepadInput.ACCEPT then
						return
					end
					if not canUseToolbar or pendingToolbarDrag then
						return
					end
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local entry = brainrotEntryForBackpackSlot(uiRow)
					if not listIdx or not entry then
						return
					end
					requestEquipFromBackpack(listIdx)
					dragSuppressedToolbarClick = true
				end)

				btn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Touch then
						return
					end
					if not canUseToolbar or pendingToolbarDrag then
						return
					end
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local entry = brainrotEntryForBackpackSlot(uiRow)
					if not listIdx or not entry then
						return
					end
					mobileDragHoldToken += 1
					local token = mobileDragHoldToken
					local startPos = Vector2.new(input.Position.X, input.Position.Y)
					local tex = (entry.icon ~= "" and entry.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
					task.delay(MOBILE_DRAG_HOLD_SEC, function()
						if token ~= mobileDragHoldToken or pendingToolbarDrag or not canUseToolbar then
							return
						end
						UIInteractionSounds.playClick()
						BrainrotItemTooltip.hide(true)
						lastResolvedHotbarDropSlot = nil
						activeToolbarDrag = true
						TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
						pendingToolbarDrag = {
							kind = "backpack",
							idx = listIdx,
							start = startPos,
							texture = tex,
							uid = brainrotUidAtIndex(listIdx),
							sourceSize = btn.AbsoluteSize,
							rowButton = btn,
							equippedOnDown = false,
						}
						dragSuppressedToolbarClick = true
					end)
				end)
				btn.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						mobileDragHoldToken += 1
					end
				end)
				btn.InputChanged:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Touch then
						return
					end
					if pendingToolbarDrag or not canUseToolbar then
						return
					end
					local listIdx = listIndexForBackpackUiRow(uiRow)
					local entry = brainrotEntryForBackpackSlot(uiRow)
					if not listIdx or not entry then
						return
					end
					local pos = Vector2.new(input.Position.X, input.Position.Y)
					local btnPos = btn.AbsolutePosition
					local btnSize = btn.AbsoluteSize
					local center = btnPos + btnSize * 0.5
					if (pos - center).Magnitude < math.max(btnSize.X, btnSize.Y) * 0.55 + DRAG_GHOST_THRESHOLD_PX then
						return
					end
					mobileDragHoldToken += 1
					local tex = (entry.icon ~= "" and entry.icon) or "rbxasset://textures/ui/GuiImagePlaceholder.png"
					UIInteractionSounds.playClick()
					BrainrotItemTooltip.hide(true)
					lastResolvedHotbarDropSlot = nil
					activeToolbarDrag = true
					TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = 1.0 }):Play()
					pendingToolbarDrag = {
						kind = "backpack",
						idx = listIdx,
						start = pos,
						texture = tex,
						uid = brainrotUidAtIndex(listIdx),
						sourceSize = btn.AbsoluteSize,
						rowButton = btn,
						equippedOnDown = false,
					}
					dragSuppressedToolbarClick = true
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
		local otherButtons = backpackFrame:FindFirstChild("OtherButtons")
			or findBackpackChild(backpackFrame, "OtherButtons")
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
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
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
		local receivedTuckedSlots = false
		local receivedHotbarSlots = false
		local previousHotbarSlotByUid: { [string]: number } = {}
		local previousParkedByUid: { [string]: boolean } = {}
		local previousKnownUids: { [string]: boolean } = {}
		local previousBackpackFrontUids: { string } = {}

		for oldIndex, oldEntry in ipairs(brainrotEntries) do
			if oldEntry and typeof(oldEntry.uid) == "string" and oldEntry.uid ~= "" then
				local uid = oldEntry.uid :: string
				previousKnownUids[uid] = true
				local oldSlot = brainrotHotbarSlotByIndex[oldIndex]
				if typeof(oldSlot) == "number" then
					previousHotbarSlotByUid[uid] = oldSlot
				end
				if brainrotParkedInUI[oldIndex] == true then
					previousParkedByUid[uid] = true
				end
			end
		end

		for _, oldIndex in ipairs(backpackFrontDisplayOrder) do
			local oldEntry = brainrotEntries[oldIndex]
			if oldEntry and typeof(oldEntry.uid) == "string" and oldEntry.uid ~= "" then
				table.insert(previousBackpackFrontUids, oldEntry.uid :: string)
			end
		end
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
					receivedTuckedSlots = true
					brainrotParkedInUI = {}
					for _, n in ipairs(t.tuckedSlots :: { any }) do
						if typeof(n) == "number" then
							local ii = math.floor(n)
							if ii >= 1 then
								brainrotParkedInUI[ii] = true
							end
						end
					end
				else
					-- Older payloads may omit tuckedSlots. Preserve local parked state
					-- by uid after the new entries list is rebuilt below.
				end

				if typeof(t.hotbarSlots) == "table" then
					receivedHotbarSlots = true
					brainrotHotbarSlotByIndex = {}

					for rawIdx, rawSlot in pairs(t.hotbarSlots :: any) do
						local idxNum = if typeof(rawIdx) == "number" then rawIdx else tonumber(rawIdx)

						if typeof(idxNum) == "number" and typeof(rawSlot) == "number" then
							local idx = math.floor(idxNum)
							local slot = math.floor(rawSlot)

							if idx >= 1 and slot >= 1 and slot <= HOTBAR_INVENTORY_SLOTS then
								brainrotHotbarSlotByIndex[idx] = slot
							end
						end
					end
				else
					-- Older server payloads do not include explicit hotbarSlots. Preserve
					-- the local custom hotbar mapping made by drag/drop and Equip Best;
					-- otherwise higher-index pets snap back into the backpack after sync.
					-- rebuildBrainrotHotbarReverseMap() below still removes invalid/conflict
					-- mappings, so this does not revive deleted items.
				end

				rebuildBrainrotHotbarReverseMap()
			end
		end
		if typeof(entriesSource) ~= "table" then
			return
		end
		local nextList: {
			{
				uid: string?,
				name: string,
				icon: string,
				sourcePath: string,
				rarity: string?,
				mutation: string?,
				level: number?,
				baseIncome: number?,
			}
		} =
			{}
		for _, e in ipairs(entriesSource :: { any }) do
			if typeof(e) == "table" then
				local uid = (e :: any).uid
				local name = (e :: any).name
				local icon = (e :: any).icon
				local sourcePath = (e :: any).sourcePath
				local rarity = (e :: any).rarity
				local mutation = (e :: any).mutation
				local level = (e :: any).level
				local baseIncome = (e :: any).baseIncome
				if typeof(name) == "string" then
					local iconStr = if typeof(icon) == "string" then icon else ""
					if iconStr == "" then
						iconStr = BrainrotsConfig:GetNormalIcon(name)
					end
					table.insert(nextList, {
						uid = if typeof(uid) == "string" and uid ~= "" then uid else nil,
						name = name,
						icon = iconStr,
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

		if not receivedHotbarSlots then
			local remappedHotbar: { [number]: number } = {}
			for newIndex, entry in ipairs(brainrotEntries) do
				if entry and typeof(entry.uid) == "string" and entry.uid ~= "" then
					local previousSlot = previousHotbarSlotByUid[entry.uid]
					if typeof(previousSlot) == "number" then
						remappedHotbar[newIndex] = previousSlot
					end
				end
			end
			brainrotHotbarSlotByIndex = remappedHotbar
		end

		if not receivedTuckedSlots then
			local remappedParked: { [number]: boolean } = {}
			for newIndex, entry in ipairs(brainrotEntries) do
				if
					entry
					and typeof(entry.uid) == "string"
					and entry.uid ~= ""
					and previousParkedByUid[entry.uid] == true
				then
					remappedParked[newIndex] = true
				end
			end
			brainrotParkedInUI = remappedParked
		end

		for newIndex, entry in ipairs(brainrotEntries) do
			if brainrotParkedInUI[newIndex] then
				continue
			end
			if typeof(brainrotHotbarSlotByIndex[newIndex]) == "number" then
				continue
			end
			local uid = if entry then entry.uid else nil
			if typeof(uid) == "string" and previousKnownUids[uid] == true then
				continue
			end
			local slot = firstEmptyHotbarSlot(nil)
			if slot then
				brainrotHotbarSlotByIndex[newIndex] = slot
				local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
				local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
				if parkEv and parkEv:IsA("RemoteEvent") then
					(parkEv :: RemoteEvent):FireServer(newIndex, false, slot)
				end
			end
		end

		if #previousBackpackFrontUids > 0 then
			local remappedFront: { number } = {}
			local seenFront: { [number]: boolean } = {}
			for _, uid in ipairs(previousBackpackFrontUids) do
				for newIndex, entry in ipairs(brainrotEntries) do
					if entry and entry.uid == uid and seenFront[newIndex] ~= true then
						seenFront[newIndex] = true
						table.insert(remappedFront, newIndex)
						break
					end
				end
			end
			backpackFrontDisplayOrder = remappedFront
		end

		rebuildBrainrotHotbarReverseMap()
		brainrotInventoryUsed = usedOverride or #nextList
		brainrotInventoryMax = maxOverride or DEFAULT_BRAINROT_CAPACITY
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
				-- Keep pendingReturnedBrainrotName so head-carry identity wins over a
				-- stale/mis-typed equipSlot (hotbar cell vs inventory index).
				if canUseToolbar then
					tryAutoSelectReturnedBrainrot()
				end
			elseif pendingReturnedBrainrotName and canUseToolbar then
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

		local brainrotIdx = brainrotIndexForHotbarSlot(index)
		local hasBrainrotEntry = brainrotIdx ~= nil
			and brainrotEntries[brainrotIdx] ~= nil
			and not brainrotParkedInUI[brainrotIdx]
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
				queueRebuildSlots()
				return
			end
			extraToolSlotByIndex[index] = tool
			setHotbarSelection(index)
			hum:EquipTool(tool)
			queueRebuildSlots()
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
					if
						typeof(invIdx) == "number"
						and brainrotIdx ~= nil
						and math.floor(invIdx) == brainrotIdx
						and uiHotbarHighlight == index
					then
						hum:UnequipTools()
						setHotbarSelection(nil)
						return
					end
				end
				setHotbarSelection(index)
				requestEquipBrainrotSlot(brainrotIdx :: number, true)
				queueRebuildSlots()
				task.delay(0.2, queueRebuildSlots)
				return
			end
			setHotbarSelection(index)
			hum:UnequipTools()
			return
		end

		setHotbarSelection(index)
		hum:EquipTool(tool)
		queueRebuildSlots()
	end

	-- After deposit, server sends equipSlot = inventory list index of the deposited brainrot.
	-- Resolve the visible hotbar cell via the slot map (never treat that index as a hotbar cell).
	applyAutoEquipFromSync = function(equipSlot: number)
		if uiBackpackListHighlight ~= nil or uiBackpackExtraHighlight ~= nil then
			return
		end
		if not canUseToolbar then
			pendingAutoEquipSlot = equipSlot
			return
		end
		local invIndex = math.floor(equipSlot)
		if not brainrotEntries[invIndex] then
			return
		end
		if brainrotParkedInUI[invIndex] then
			brainrotParkedInUI[invIndex] = nil
		end

		local function bumpRandomBackpackItemToTop(exceptIdx: number)
			rebuildBackpackDisplayOrder()
			local pool: { number } = {}
			for _, idx in ipairs(backpackDisplayOrder) do
				if idx ~= exceptIdx then
					table.insert(pool, idx)
				end
			end
			if #pool == 0 then
				return
			end
			moveBrainrotBackpackDisplayRow(pool[math.random(1, #pool)], 1)
		end

		local function pickRandomDisplacedHotbarSlot(): number?
			local pool: { number } = {}
			local startSlot = 1
			local gearTool = findWorkoutGearTool()
			if gearTool and not isExtraToolParked(gearTool) then
				startSlot = 2
			end
			for slot = startSlot, HOTBAR_INVENTORY_SLOTS do
				local occupant = brainrotIndexForHotbarSlot(slot)
				if occupant and occupant ~= invIndex and extraToolSlotByIndex[slot] == nil then
					local tool = slotTools[slot]
					if not (tool and tool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true) then
						table.insert(pool, slot)
					end
				end
			end
			if #pool == 0 then
				return nil
			end
			return pool[math.random(1, #pool)]
		end

		local slot = hotbarSlotForBrainrotIndex(invIndex)
		if not slot then
			slot = firstEmptyHotbarSlot()
			if not slot then
				slot = pickRandomDisplacedHotbarSlot()
				if slot then
					local displacedIdx = brainrotIndexForHotbarSlot(slot)
					if displacedIdx and displacedIdx ~= invIndex then
						optimisticBrainrotTuckToBackpack(displacedIdx)
						fireBrainrotPark(displacedIdx, true)
					end
				end
			end
			if slot then
				optimisticBrainrotMoveToHotbar(invIndex, slot)
				fireBrainrotPark(invIndex, false, slot)
			end
		end
		if not slot then
			-- Hotbar still has no cell (gear-only / extras). Equip from the bag without a fake ring.
			uiBackpackListHighlight = nil
			uiBackpackExtraHighlight = nil
			setHotbarSelection(nil, false)
			requestEquipBrainrotSlot(invIndex, true)
			bumpRandomBackpackItemToTop(invIndex)
			queueRebuildSlots()
			return
		end

		uiBackpackListHighlight = nil
		uiBackpackExtraHighlight = nil
		setHotbarSelection(slot)
		bumpRandomBackpackItemToTop(invIndex)

		local function tryHoldBrainrot(): boolean
			rebuildSlots()
			local hum = getHumanoid()
			if not hum then
				return false
			end
			local mapped = hotbarSlotForBrainrotIndex(invIndex)
			if mapped then
				slot = mapped
				setHotbarSelection(slot, false)
			end
			local tool = slotTools[slot]
			local char = player.Character
			local equipped = char and char:FindFirstChildOfClass("Tool")
			if tool then
				if equipped ~= tool then
					hum:EquipTool(tool)
				end
				local toolInv = tool:GetAttribute("BrainrotInvIndex")
				if typeof(toolInv) == "number" and math.floor(toolInv) ~= invIndex then
					requestEquipBrainrotSlot(invIndex, true)
				end
				return true
			end
			if brainrotEntries[invIndex] and not brainrotParkedInUI[invIndex] then
				requestEquipBrainrotSlot(invIndex, true)
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
	local HOTBAR_DPAD_ACTION = "ToolbarHotbarDPadCycle"

	local function cycleHotbarSlot(delta: number)
		if not canSelectHotbarSlot() then
			return
		end
		local equippedIdx = 0
		local char = player.Character
		local equipped = char and char:FindFirstChildOfClass("Tool")
		if equipped then
			for i = 1, 9 do
				if slotTools[i] == equipped then
					equippedIdx = i
					break
				end
			end
		end
		for n = 1, 9 do
			local idx = ((equippedIdx - 1 + delta * n) % 9) + 1
			if hotbarSlotHasSelectableContent(idx) then
				UIInteractionSounds.playHover()
				selectSlot(idx)
				return
			end
		end
	end

	local function bindToolbarHotbarKeybinds()
		ContextActionService:UnbindAction(HOTBAR_KEY_ACTION)
		ContextActionService:UnbindAction(HOTBAR_DPAD_ACTION)
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
		ContextActionService:BindActionAtPriority(
			HOTBAR_DPAD_ACTION,
			function(_, state, input)
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Pass
				end
				if UserInputService:GetFocusedTextBox() ~= nil then
					return Enum.ContextActionResult.Pass
				end
				if not GamepadInput.isPreferred() then
					return Enum.ContextActionResult.Pass
				end
				if input.KeyCode == Enum.KeyCode.DPadLeft then
					cycleHotbarSlot(-1)
					return Enum.ContextActionResult.Sink
				elseif input.KeyCode == Enum.KeyCode.DPadRight then
					cycleHotbarSlot(1)
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.DPadLeft,
			Enum.KeyCode.DPadRight
		)
	end

	-- ── Character wiring ──────────────────────────────────────────────────────────

	local characterToolConns: { RBXScriptConnection } = {}
	local function disconnectCharacterToolConns()
		for _, conn in characterToolConns do
			conn:Disconnect()
		end
		table.clear(characterToolConns)
	end

	local function wireCharacter(character: Model)
		disconnectCharacterToolConns()
		table.insert(
			characterToolConns,
			character.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					queueRebuildSlots()
				end
			end)
		)
		table.insert(
			characterToolConns,
			character.ChildRemoved:Connect(function(child)
				if child:IsA("Tool") then
					queueRebuildSlots()
				end
			end)
		)

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		end
		if humanoid then
			humanoid.Died:Connect(function()
				activeToolbarDrag = false
				pendingToolbarDrag = nil
				dragSuppressedToolbarClick = false
				clearDragGhost()
				setBackpackPanelOpen(false)
			end)
		end

		queueRebuildSlots()
	end

	requestBrainrotInventoryFromServer = function()
		task.spawn(function()
			local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
			if not folder then
				folder = ReplicatedStorage:WaitForChild("BushRemotes", 20)
			end
			if not folder then
				return
			end
			local getFn = folder:FindFirstChild("GetBrainrotInventory")
			if not getFn or not getFn:IsA("RemoteFunction") then
				getFn = folder:WaitForChild("GetBrainrotInventory", 15)
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

	local _initialInventoryRevealed = false

	-- After loading, canUseToolbar may already be true from mid-load safezone polls
	-- while showToolbar() no-op'd. Re-sync so hotbar/backpack appear without pressing `.
	local function revealInventoryAfterLoadIfReady()
		if LoadingScreenController.isActive() then
			return false
		end
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(3)
		pollSafezonePresence()
		-- If safezone cache was late, force a second poll after a short wait.
		if not canUseToolbar and player.Character then
			task.wait(0.15)
			SafezoneUtil.warmCacheAsync()
			SafezoneUtil.awaitCacheReady(2)
			pollSafezonePresence()
		end
		refreshToolbarVisibility()
		updateHotbarSlotVisibility()
		refreshToggleBackpackIconLayout()
		if canUseToolbar then
			-- Force show even if an earlier mid-load showToolbar no-op'd.
			if GameplayUiVisibility.isHidden() then
				toolbarShown = true
				return true
			end
			if not toolbarShown then
				showToolbar()
			else
				toolbar.Visible = true
			end
			updateHotbarSlotVisibility()
			refreshToggleBackpackIconLayout()
			if tryAutoSelectReturnedBrainrot then
				tryAutoSelectReturnedBrainrot()
			end
			requestBrainrotInventoryFromServer()
			return true
		end
		return false
	end

	local function ensureSpawnToolbarVisible()
		task.spawn(function()
			SafezoneUtil.warmCacheAsync()
			SafezoneUtil.awaitCacheReady(8)
			for _ = 1, 60 do
				if LoadingScreenController.isActive() then
					task.wait(0.25)
					continue
				end
				SafezoneUtil.warmCacheAsync()
				pollSafezonePresence()
				refreshToolbarVisibility()
				updateHotbarSlotVisibility()
				refreshToggleBackpackIconLayout()
				if canUseToolbar then
					if revealInventoryAfterLoadIfReady() then
						return
					end
				end
				task.wait(0.25)
			end
			pollSafezonePresence()
			refreshToolbarVisibility()
			if canUseToolbar then
				showToolbar()
				updateHotbarSlotVisibility()
			end
			requestBrainrotInventoryFromServer()
		end)
	end

	local function watchLoadingThenRevealInventory()
		task.spawn(function()
			for _ = 1, 120 do
				if revealInventoryAfterLoadIfReady() then
					return
				end
				task.wait(0.25)
			end
			revealInventoryAfterLoadIfReady()
		end)
	end

	local function refreshToolbarAfterWorldChange()
		activeToolbarDrag = false
		pendingToolbarDrag = nil
		dragSuppressedToolbarClick = false
		clearDragGhost()
		isBackpackPanelOpen = false
		isBackpackPanelClosing = false
		_initialInventoryRevealed = false
		if backpackFrameRef and backpackFrameRef:IsA("GuiObject") then
			(backpackFrameRef :: GuiObject).Visible = false
		end
		toolbarShown = false
		safezoneOutStreak = 0
		rebuildSlots()
		applyHotbarSlotScales()
		ensureSpawnToolbarVisible()
		watchLoadingThenRevealInventory()
		task.defer(function()
			for _ = 1, 20 do
				if revealInventoryAfterLoadIfReady() then
					return
				end
				task.wait(0.2)
			end
		end)
	end

	-- ── Init ──────────────────────────────────────────────────────────────────────

	function ToolbarController.prepareEarly()
		disableDefaultRobloxBackpack()
		applyToolbarInitialHiddenState()
	end

	function ToolbarController.init()
		ensureDefaultRobloxBackpackStaysOff()
		task.defer(ensureDefaultRobloxBackpackStaysOff)
		SafezoneUtil.warmCacheAsync()
		BrainrotItemTooltip.init()

		local ReviveController = require(script.Parent.ReviveController)
		ReviveController.registerHudRestoredCallback(function()
			task.defer(refreshToolbarAfterWorldChange)
		end)

		GameplayUiVisibility.onRestored(function()
			if GameplayUiVisibility.isHidden() then
				return
			end
			task.defer(refreshToolbarAfterWorldChange)
		end)

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

		table.clear(slotStrokeLit)
		for i = 1, #slots do
			setSlotHighlight(i, false)
		end

		ensureHotbarLayoutPassthrough()

		local configureDropTargets = (DropTargets :: any).configure
		if typeof(configureDropTargets) == "function" then
			configureDropTargets({
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
					return hotbarDragZoneActive or hotbarDragHoverSlot ~= nil
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
		end

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
					if not MobileTouchGate.canTapUi() then
						return
					end
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
				local function beginHotbarPendingDrag(startPos: Vector2)
					local tex = hotbarSlotDragTexture(i)
					if not tex then
						return
					end
					-- Click SFX plays once from Activated (onHotbarSlotTapSelect), not here —
					-- MouseButton1Down + Activated were stacking duplicate plays.
					BrainrotItemTooltip.hide(true)
					local dragBrainrotIdx = brainrotIndexForHotbarSlot(i)
					local isExtraTool = dragBrainrotIdx == nil or brainrotParkedInUI[dragBrainrotIdx] == true
					local tool = slotTools[i]
					local equippedOnDown = false
					if tool and player.Character and tool.Parent == player.Character then
						equippedOnDown = true
					end
					lastResolvedHotbarDropSlot = nil
					activeToolbarDrag = true
					pendingToolbarDrag = {
						kind = "hotbar",
						idx = if isExtraTool then i else dragBrainrotIdx :: number,
						start = startPos,
						texture = tex,
						uid = if isExtraTool or not dragBrainrotIdx
							then nil
							else brainrotUidAtIndex(dragBrainrotIdx :: number),
						rowButton = nil,
						isExtraTool = isExtraTool,
						equippedOnDown = equippedOnDown,
					}
				end

				-- PC: drag starts immediately on mouse down. Gamepad A tucks into the bag (no drag).
				btn.MouseButton1Down:Connect(function()
					if not canUseToolbar then
						return
					end
					if dtIsTouchPointerInput() then
						return
					end
					if GamepadInput.isPreferred() then
						if gamepadTuckHotbarSlot(i) then
							dragSuppressedToolbarClick = true
						end
						return
					end
					beginHotbarPendingDrag(UserInputService:GetMouseLocation())
				end)
				btn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= GamepadInput.ACCEPT then
						return
					end
					if not canUseToolbar then
						return
					end
					if gamepadTuckHotbarSlot(i) then
						dragSuppressedToolbarClick = true
					end
				end)

				-- Mobile: long-press (or hold + slide) starts drag so short taps still Activate/select.
				btn.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Touch then
						return
					end
					if not canUseToolbar then
						return
					end
					if pendingToolbarDrag or not hotbarSlotDragTexture(i) then
						return
					end
					mobileDragHoldToken += 1
					local token = mobileDragHoldToken
					local startPos = Vector2.new(input.Position.X, input.Position.Y)
					task.delay(MOBILE_DRAG_HOLD_SEC, function()
						if token ~= mobileDragHoldToken then
							return
						end
						if pendingToolbarDrag or not canUseToolbar then
							return
						end
						beginHotbarPendingDrag(startPos)
						dragSuppressedToolbarClick = true
					end)
				end)
				btn.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						mobileDragHoldToken += 1
					end
				end)
				btn.InputChanged:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Touch then
						return
					end
					if pendingToolbarDrag or not canUseToolbar then
						return
					end
					local pos = Vector2.new(input.Position.X, input.Position.Y)
					local btnPos = btn.AbsolutePosition
					local btnSize = btn.AbsoluteSize
					local center = btnPos + btnSize * 0.5
					if (pos - center).Magnitude < math.max(btnSize.X, btnSize.Y) * 0.55 + DRAG_GHOST_THRESHOLD_PX then
						return
					end
					if not hotbarSlotDragTexture(i) then
						return
					end
					mobileDragHoldToken += 1
					beginHotbarPendingDrag(pos)
					dragSuppressedToolbarClick = true
				end)
			else
				warn(
					"[ToolbarController] Hotbar slot '"
						.. tostring(i)
						.. "' has no TextButton/ImageButton for tap input"
				)
			end

			local scale = getOrAddUIScale(hotbarSlotScaleHost(slot))
			local hoverTarget: GuiObject = (btn and (btn :: GuiObject)) or slot
			hoverTarget.MouseEnter:Connect(function()
				if hotbarDragZoneActive or hotbarDragHoverSlot ~= nil then
					return
				end
				UIInteractionSounds.playHover()
				TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = SLOT_HOVER_SCALE }):Play()
			end)
			hoverTarget.MouseLeave:Connect(function()
				BrainrotItemTooltip.hide(true)
				if hotbarDragZoneActive or hotbarDragHoverSlot ~= nil then
					return
				end
				TweenService:Create(scale, HIGHLIGHT_TWEEN, { Scale = hotbarSlotRestScale(i) }):Play()
			end)

			if btn and btn:GetAttribute("_BrainrotTooltipBound") ~= true then
				btn:SetAttribute("_BrainrotTooltipBound", true)
				local slotIndex = i
				BrainrotItemTooltip.bind(btn, function()
					local brainrotIdx = brainrotIndexForHotbarSlot(slotIndex)
					if brainrotIdx and brainrotEntries[brainrotIdx] then
						return brainrotEntries[brainrotIdx].name
					end
					local tool = slotTools[slotIndex]
					if tool then
						local toolName = tool:GetAttribute("BrainrotName")
						if typeof(toolName) == "string" and toolName ~= "" then
							return toolName
						end
						return tool.Name
					end
					return nil
				end)
			end
		end

		resetAllSlotsToIdle()
		applyHotbarSlotScales()
		bindToolbarHotbarKeybinds()

		-- Backpack changes
		local backpack = player:WaitForChild("Backpack")
		backpack.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				queueRebuildSlots()
			end
		end)
		backpack.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				queueRebuildSlots()
			end
		end)

		-- Character spawning
		player.CharacterAdded:Connect(function(char: Model)
			wireCharacter(char)
			task.defer(refreshToolbarAfterWorldChange)
			ensureSpawnToolbarVisible()
		end)
		if player.Character then
			wireCharacter(player.Character)
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
			if not map then
				return
			end
			local function onSpawnBasesReady()
				SafezoneUtil.warmCacheAsync()
				pollSafezonePresence()
				refreshToolbarVisibility()
				updateHotbarSlotVisibility()
				refreshToggleBackpackIconLayout()
				requestBrainrotInventoryFromServer()
			end
			map.ChildAdded:Connect(function(ch)
				if ch.Name == "Spawn And Bases" then
					task.defer(onSpawnBasesReady)
				end
			end)
			if map:FindFirstChild("Spawn And Bases") then
				task.defer(onSpawnBasesReady)
			end
		end)

		ensureSpawnToolbarVisible()

		task.spawn(function()
			task.wait(1.5)
			if not toolbar or not toolbar.Parent then
				return
			end
			local sc = getOrAddUIScale(toolbar)
			local savedShown = toolbarShown
			local savedVisible = toolbar.Visible
			sc.Scale = 1
			local t = TweenService:Create(sc, HIDE_TWEEN, { Scale = 0.8 })
			t:Play()
			t.Completed:Wait()
			sc.Scale = if savedShown then 1 else 0.8
			if not savedShown then
				toolbar.Visible = savedVisible
			end
		end)

		-- ToggleBackpackImage lives on the hotbar; wire it before closing the backpack panel.
		wireToggleBackpackIcon()
		local toggleBtn = toolbar:FindFirstChild("ToggleBackpack") or hotbar:FindFirstChild("ToggleBackpack")
		if toggleBtn and toggleBtn:IsA("GuiObject") then
			if toggleBackpackIconRef then
				(toggleBtn :: GuiObject).Visible = false
			else
				toggleBackpackRef = toggleBtn :: GuiObject
				if toggleBtn:IsA("GuiButton") then
					toggleBtn.MouseEnter:Connect(function()
						UIInteractionSounds.playHover()
					end)
					toggleBtn.MouseButton1Down:Connect(function()
						UIInteractionSounds.playClick()
					end)
					toggleBtn.Activated:Connect(toggleBackpackPanel)
				end
			end
		end

		local backpackFrame = toolbar:FindFirstChild("Backpack")
		if backpackFrame then
			backpackContainer = backpackFrame:FindFirstChild("Container")
			if backpackFrame:IsA("GuiObject") then
				local bf = backpackFrame :: GuiObject
				backpackGuiFrame = bf
				backpackFrameRef = bf
				backpackRestPosition = bf.Position
				prepareBackpackPanelLayer(bf, false)
				ensureBackpackFrameOutline(bf)
				ensureBackpackFadeRoot(bf)
				ensureBackpackChromeVisible(bf)
			end
			backpackHeaderLabel = resolveBackpackHeaderLabel(backpackFrame)
			refreshInventoryHeaderText()
			if backpackContainer then
				ensureBackpackGeneratedRows(backpackContainer)
				for idx = 1, MAX_BACKPACK_BRAINROT_SLOTS do
					local row = findBackpackRow(backpackContainer, idx)
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
			isBackpackPanelClosing = false
			if backpackFrame:IsA("GuiObject") then
				(backpackFrame :: GuiObject).Visible = false
			end
		end

		task.defer(function()
			if hotbar:IsA("GuiObject") then
				(hotbar :: GuiObject).AutomaticSize = Enum.AutomaticSize.None
			end
			applyToolbarHorizontalCenterOnce()
			updateHotbarSlotVisibility()
			if toggleBackpackIconRef and canUseToolbar and toolbarShown and not isBackpackPanelOpen then
				animateToggleBackpackIcon(true)
			end
		end)

		ensureSpawnToolbarVisible()
		-- After backpack is wired closed above: wait for loading to end, then show
		-- hotbar + open backpack (same as pressing `) when already in safezone.
		watchLoadingThenRevealInventory()
		LoadingScreenController.registerOnGameplayReady(function()
			revealInventoryAfterLoadIfReady()
		end)

		-- ` / Y opens / closes the brainrot backpack (Y = Triangle on PlayStation).
		if backpackFrame then
			ContextActionService:BindActionAtPriority("ToolbarOpenBackpack", function(_, state, _)
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Pass
				end
				if UserInputService:GetFocusedTextBox() ~= nil then
					return Enum.ContextActionResult.Pass
				end
				if not canUseToolbar then
					return Enum.ContextActionResult.Sink
				end
				toggleBackpackPanel()
				UIInteractionSounds.playClick()
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Backquote, GamepadInput.SECONDARY)

			GamepadInput.onPreferredChanged(function()
				syncToolbarGamepadCursor()
			end)
		end

		UserInputService.InputChanged:Connect(function(input, _gp)
			if not toolbarInputAllowed() then
				return
			end
			if
				input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch
				and input.UserInputType ~= Enum.UserInputType.Gamepad1
			then
				return
			end
			local pnd = pendingToolbarDrag
			if not pnd or not pnd.texture then
				return
			end
			-- Keep cursor alive while dragging on gamepad so stick moves the ghost.
			if GamepadInput.isPreferred() then
				syncToolbarGamepadCursor()
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
					-- Normal brainrots used to only start a ghost while the cursor was still
					-- over the original backpack row. In a tight grid, the first movement
					-- event after crossing the threshold is often already over another row,
					-- so dragging brainrots inside the backpack/hotbar felt completely dead.
					local stillHolding = input.UserInputType == Enum.UserInputType.Touch
						or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
						or GamepadInput.isAcceptHeld()
					if not stillHolding then
						return
					end
				end
				startDragGhost(pnd.texture, m, pnd.sourceSize or (if pnd.rowButton then pnd.rowButton.AbsoluteSize else nil))
				-- Reveal empty hotbar cells immediately when dragging from the backpack.
				if pnd.kind == "backpack" or pnd.kind == "backpack_extra" or pnd.kind == "hotbar" then
					hotbarDragZoneActive = true
					updateHotbarSlotVisibility()
				end
				local probeEnd = m
				local probeWindow = dtScreenPointWithGuiInset(probeEnd)
				local ghostCenter = if dragGhostImage
					then dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
					else nil
				local overHotbar, overBackpack, overBackpackPanel =
					dtProbeDragHoverTargets(probeWindow, probeEnd, ghostCenter, nil)
				local hoverSlot = dtHotbarSlotIndexFromDropProbes(probeWindow, probeEnd, ghostCenter)
				updateDragHoverTargets(overHotbar, overBackpack, overBackpackPanel, hoverSlot)
				return
			end
			local rawEnd = UserInputService:GetMouseLocation()
			if input.UserInputType == Enum.UserInputType.Touch then
				rawEnd = Vector2.new(input.Position.X, input.Position.Y)
			end
			local mouseWindow = dtScreenPointWithGuiInset(rawEnd)
			local ghostCenter: Vector2? = nil
			if dragGhostImage then
				ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
			end
			local ghostViewport = if ghostCenter
				then ghostCenter - Vector2.new(GuiService:GetGuiInset().X, GuiService:GetGuiInset().Y)
				else nil
			local overHotbar, overBackpack, overBackpackPanel =
				dtProbeDragHoverTargets(mouseWindow, rawEnd, ghostCenter, ghostViewport)
			local hoveringHotbarSlot = dtHotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter)
			if hoveringHotbarSlot then
				lastResolvedHotbarDropSlot = hoveringHotbarSlot
			end
			if pnd.kind == "hotbar" and not isBackpackPanelOpen and overBackpack then
				setBackpackPanelOpen(true)
			end
			updateDragHoverTargets(overHotbar, overBackpack, overBackpackPanel, hoveringHotbarSlot)
		end)

		UserInputService.InputEnded:Connect(function(input, _gp)
			local isPrimaryClick = input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
				or (input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == GamepadInput.ACCEPT)
			if not isPrimaryClick then
				return
			end
			if not toolbarInputAllowed() then
				activeToolbarDrag = false
				pendingToolbarDrag = nil
				lastResolvedHotbarDropSlot = nil
				clearDragGhost()
				syncToolbarGamepadCursor()
				return
			end
			local pnd = pendingToolbarDrag
			pendingToolbarDrag = nil
			activeToolbarDrag = false
			if not pnd then
				lastResolvedHotbarDropSlot = nil
				clearDragGhost()
				syncToolbarGamepadCursor()
				return
			end
			local rawEnd = UserInputService:GetMouseLocation()
			if input.UserInputType == Enum.UserInputType.Touch then
				rawEnd = Vector2.new(input.Position.X, input.Position.Y)
			end

			if pnd.kind == "backpack" or (pnd.kind == "hotbar" and not pnd.isExtraTool) then
				local resolvedIdx = resolveBrainrotIndexForDrag(pnd.idx, pnd.uid)
				if not resolvedIdx then
					clearDragGhost()
					lastResolvedHotbarDropSlot = nil
					syncToolbarGamepadCursor()
					return
				end
				pnd.idx = resolvedIdx
			end

			if (rawEnd - pnd.start).Magnitude < DRAG_THRESHOLD_PX then
				-- GuiButton.Activated already toggles backpack cells. Firing equip
				-- again here unequips then the server puts the tool back.
				clearDragGhost()
				syncToolbarGamepadCursor()
				return
			end
			local mouseWindow = dtScreenPointWithGuiInset(rawEnd)
			local ghostCenter: Vector2? = nil
			if dragGhostImage then
				ghostCenter = dragGhostImage.AbsolutePosition + dragGhostImage.AbsoluteSize * 0.5
			end
			local insetProbe = GuiService:GetGuiInset()
			local ghostViewport = if ghostCenter then ghostCenter - Vector2.new(insetProbe.X, insetProbe.Y) else nil
			local destBackpackRow = dtBackpackRowIndexFromDropProbes(rawEnd, mouseWindow, ghostViewport)

			-- Resolve targets before clearDragGhost so empty hotbar cells / pads are still active.
			local overHotbar, overBackpack, overBackpackPanel =
				dtProbeDragHoverTargets(mouseWindow, rawEnd, ghostCenter, ghostViewport)
			local targetHotbar: number? = dtHotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter)
			local releaseOverHotbarZone = overHotbar
				or dtPointOverHotbarDropZoneProbes(mouseWindow, rawEnd)
				or (ghostCenter ~= nil and dtPointOverHotbarDropZoneProbes(ghostCenter, rawEnd))
				or pointOverHotbarHitScan(ghostViewport)
			local releaseOverBackpack = (overBackpack or overBackpackPanel or destBackpackRow ~= nil)
			if not targetHotbar and lastResolvedHotbarDropSlot and releaseOverHotbarZone then
				-- Backpack → hotbar: allow cache even if release also overlaps the bag frame.
				-- Hotbar → backpack: ignore stale cache when release is clearly on the bag.
				if pnd.kind == "backpack" or pnd.kind == "backpack_extra" or not releaseOverBackpack then
					targetHotbar = lastResolvedHotbarDropSlot
				end
			end
			lastResolvedHotbarDropSlot = nil

			clearDragGhost()
			dragSuppressedToolbarClick = true

			-- Hotbar wins when a hotbar cell/zone was targeted (fixes backpack → hotbar).
			local droppedOnBackpack = releaseOverBackpack and targetHotbar == nil and not releaseOverHotbarZone
			local overHotbarZone = targetHotbar ~= nil or releaseOverHotbarZone

			if pnd.kind == "hotbar" and pnd.isExtraTool then
				local tool = extraToolAtHotbarSlot(pnd.idx) or extraToolSlotByIndex[pnd.idx] or slotTools[pnd.idx]
				if droppedOnBackpack then
					setBackpackPanelOpen(true)
					if tool then
						parkExtraToolInBackpack(tool, pnd.idx)
						queueRebuildSlots()
						refreshParkedExtraToolsUI()
					end
					UIInteractionSounds.playClick()
				elseif
					targetHotbar
					and targetHotbar ~= pnd.idx
					and tool
					and slotCanAcceptExtraToolDrop(targetHotbar)
				then
					local other = extraToolAtHotbarSlot(targetHotbar)
					if not other then
						requestTuckBrainrotHotbarSlot(targetHotbar)
					end
					removeExtraToolFromParkedList(tool)
					removeExtraToolFromAllHotbarSlots(tool)
					if other and other ~= tool then
						removeExtraToolFromParkedList(other)
						removeExtraToolFromAllHotbarSlots(other)
						extraToolSlotByIndex[pnd.idx] = other
					end
					extraToolSlotByIndex[targetHotbar] = tool
					sanitizeExtraToolSlotPins()
					queueRebuildSlots()
					refreshParkedExtraToolsUI()
					UIInteractionSounds.playClick()
				end
				return
			end

			if pnd.kind == "backpack_extra" and pnd.tool then
				local tool = pnd.tool :: Tool
				if targetHotbar and slotCanAcceptExtraToolDrop(targetHotbar) then
					local occupying = extraToolAtHotbarSlot(targetHotbar)
					if occupying and occupying ~= tool then
						parkExtraToolInBackpack(occupying, targetHotbar)
					end
					if unparkExtraToolToHotbar(tool, targetHotbar) then
						queueRebuildSlots()
						refreshParkedExtraToolsUI()
						UIInteractionSounds.playClick()
					end
				end
				return
			end

			local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
			local parkEv = folder and folder:FindFirstChild("BrainrotSetParkedSlot")
			if not parkEv or not parkEv:IsA("RemoteEvent") then
				return
			end

			local remote = parkEv :: RemoteEvent

			if pnd.kind == "hotbar" then
				local sourceHotbarSlot = hotbarSlotForBrainrotIndex(pnd.idx)
				local hasEntry = brainrotEntries[pnd.idx]
					and not brainrotParkedInUI[pnd.idx]
					and sourceHotbarSlot ~= nil
				if not hasEntry then
					return
				end
				if droppedOnBackpack then
					-- Hotbar → backpack panel: tuck immediately, then let server confirm.
					setBackpackPanelOpen(true)
					optimisticBrainrotTuckToBackpack(pnd.idx)
					remote:FireServer(pnd.idx, true)
					UIInteractionSounds.playClick()
				elseif targetHotbar and targetHotbar ~= sourceHotbarSlot then
					-- Hotbar → hotbar swap. Send the displaced pet's new slot too;
					-- otherwise the server may resolve the conflict differently and the
					-- hotbar appears to reshuffle after the next sync.
					local displacedIdx = brainrotIndexForHotbarSlot(targetHotbar)
					if displacedIdx and displacedIdx ~= pnd.idx and sourceHotbarSlot then
						remote:FireServer(displacedIdx, false, sourceHotbarSlot)
					end
					optimisticBrainrotMoveToHotbar(pnd.idx, targetHotbar)
					remote:FireServer(pnd.idx, false, targetHotbar)
					UIInteractionSounds.playClick()
				end
			elseif pnd.kind == "backpack" then
				local entry = brainrotEntries[pnd.idx]
				if not entry then
					return
				end
				if targetHotbar then
					-- Backpack → exact hotbar slot. If the target slot is occupied,
					-- park that occupant first so the server does not pick a random
					-- conflict resolution and reshuffle the hotbar on sync.
					local displacedIdx = brainrotIndexForHotbarSlot(targetHotbar)
					if displacedIdx and displacedIdx ~= pnd.idx then
						remote:FireServer(displacedIdx, true)
					end
					optimisticBrainrotMoveToHotbar(pnd.idx, targetHotbar)
					remote:FireServer(pnd.idx, false, targetHotbar)
					UIInteractionSounds.playClick()
				elseif overHotbarZone then
					-- Fallback: dropped over the hotbar row but not a specific cell.
					-- Still choose a deterministic slot; never let the server pick a random one.
					local fallbackSlot =
						firstEmptyHotbarSlot(if pnd.idx <= HOTBAR_INVENTORY_SLOTS then pnd.idx else nil)
					if fallbackSlot then
						optimisticBrainrotMoveToHotbar(pnd.idx, fallbackSlot)
						remote:FireServer(pnd.idx, false, fallbackSlot)
						UIInteractionSounds.playClick()
					end
				elseif droppedOnBackpack and destBackpackRow then
					-- Backpack → backpack reorder. This only changes the visible backpack
					-- order; it does not touch Equip Best or hotbar slot mappings.
					moveBrainrotBackpackDisplayRow(pnd.idx, destBackpackRow)
					UIInteractionSounds.playClick()
				end
			end
			syncToolbarGamepadCursor()
		end)

		task.spawn(function()
			local folder = ReplicatedStorage:WaitForChild("BushRemotes", 45)
			if not folder then
				return
			end
			local sync = folder:WaitForChild("BrainrotInventorySync", 20)
			if sync and sync:IsA("RemoteEvent") then
				sync.OnClientEvent:Connect(setBrainrotEntriesFromServer)
			end
			requestBrainrotInventoryFromServer()
		end)
	end
end)()

return ToolbarController
