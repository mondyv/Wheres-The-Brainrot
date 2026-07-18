-- [ACTIVE] ToolbarDropTargets
--[[
	Hit-testing for toolbar drag-and-drop (hotbar slots, backpack panel, inventory rows).
	Extracted from ToolbarController to stay under Luau's per-chunk local register limit.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

export type Config = {
	playerGui: PlayerGui,
	hotbar: GuiObject,
	slots: { GuiObject },
	hotbarInventorySlots: number,
	maxBackpackSlots: number,
	getDragGhostGui: () -> ScreenGui?,
	getPendingToolbarDrag: () -> any,
	getHotbarDragBulkHover: () -> boolean,
	getBackpackContainer: () -> Instance?,
	getBackpackGuiFrame: () -> GuiObject?,
	getBackpackFrameRef: () -> GuiObject?,
	getToggleBackpackRef: () -> GuiObject?,
	getIsBackpackPanelOpen: () -> boolean,
	toolSlotSurface: (GuiObject) -> GuiObject,
}

local cfg: Config? = nil

local DropTargets = {}

function DropTargets.configure(config: Config)
	cfg = config
end

local function requireCfg(): Config
	assert(cfg, "ToolbarDropTargets.configure must run before use")
	return cfg
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

function DropTargets.isTouchPointerInput(): boolean
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

function DropTargets.screenPointInGui(gui: GuiObject, screen: Vector2): boolean
	return screenPointInGui(gui, screen)
end

function DropTargets.screenPointWithGuiInset(screen: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return screen + Vector2.new(inset.X, inset.Y)
end

local function hotbarDragDropPadActive(): boolean
	local c = requireCfg()
	if c.getHotbarDragBulkHover() then
		return true
	end
	local pnd = c.getPendingToolbarDrag()
	if c.getDragGhostGui() and pnd and pnd.kind == "hotbar" then
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

local function hotbarSlotIndexUnderPoint(screen: Vector2): number?
	local c = requireCfg()
	for si = c.hotbarInventorySlots, 1, -1 do
		local slot = c.slots[si]
		if not slot then
			continue
		end
		-- Include hidden empty drop cells: AbsoluteSize is still valid while parent Hotbar is shown.
		local surface = c.toolSlotSurface(slot)
		if surface.AbsoluteSize.X <= 0 or surface.AbsoluteSize.Y <= 0 then
			continue
		end
		if screenPointInHotbarSurface(surface, screen) then
			return si
		end
	end
	return nil
end

local function ancestorHotbarSlotIndexFromGuiObject(inst: Instance): number?
	local c = requireCfg()
	local w: Instance? = inst
	while w and w ~= c.playerGui do
		if w.Parent == c.hotbar then
			local n = tonumber(w.Name)
			if n and n >= 1 and n <= c.hotbarInventorySlots then
				return n
			end
		end
		w = w.Parent
	end
	return nil
end

local function hotbarSlotIndexFromGuiHitScan(rawViewport: Vector2): number?
	local c = requireCfg()
	local ok, hitsOrErr = pcall(function()
		return c.playerGui:GetGuiObjectsAtPosition(rawViewport.X, rawViewport.Y)
	end)
	if not ok or typeof(hitsOrErr) ~= "table" then
		return nil
	end
	local ghost = c.getDragGhostGui()
	for _, hit in hitsOrErr :: { Instance } do
		if ghost and hit:IsDescendantOf(ghost) then
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

function DropTargets.pointOverHotbarFromGuiHitScan(rawViewport: Vector2): boolean
	local c = requireCfg()
	local ok, hitsOrErr = pcall(function()
		return c.playerGui:GetGuiObjectsAtPosition(rawViewport.X, rawViewport.Y)
	end)
	if not ok or typeof(hitsOrErr) ~= "table" then
		return false
	end
	local ghost = c.getDragGhostGui()
	for _, hit in hitsOrErr :: { Instance } do
		if ghost and hit:IsDescendantOf(ghost) then
			continue
		end
		if hit:IsA("GuiObject") and guiInstanceIsUnder(hit, c.hotbar) then
			return true
		end
	end
	return false
end

function DropTargets.hotbarSlotIndexFromDropProbes(
	mouseWindow: Vector2,
	rawViewport: Vector2,
	ghostCenter: Vector2?
): number?
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

	local probes: { Vector2 } = { mouseWindow, DropTargets.screenPointWithGuiInset(rawViewport), rawViewport }
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

local function pointOverHotbarDropZoneOne(screen: Vector2): boolean
	local c = requireCfg()
	if screenPointInHotbarSurface(c.hotbar, screen) then
		return true
	end
	for i = 1, c.hotbarInventorySlots do
		local slot = c.slots[i]
		if slot then
			local surface = c.toolSlotSurface(slot)
			if screenPointInHotbarSurface(surface, screen) then
				return true
			end
		end
	end
	return false
end

function DropTargets.pointOverHotbarDropZoneProbes(dropPoint: Vector2, rawViewport: Vector2): boolean
	return pointOverHotbarDropZoneOne(dropPoint)
		or pointOverHotbarDropZoneOne(DropTargets.screenPointWithGuiInset(rawViewport))
		or DropTargets.pointOverHotbarFromGuiHitScan(rawViewport)
end

local function isBackpackPanelVisible(): boolean
	local c = requireCfg()
	if not c.getIsBackpackPanelOpen() then
		return false
	end
	local frame = c.getBackpackFrameRef()
	if not frame then
		return false
	end
	return frame.Visible
end

function DropTargets.pointOverBackpackFromGuiHitScan(rawViewport: Vector2): boolean
	local c = requireCfg()
	local cont = c.getBackpackContainer()
	if not cont then
		return false
	end
	local ok, hitsOrErr = pcall(function()
		return c.playerGui:GetGuiObjectsAtPosition(rawViewport.X, rawViewport.Y)
	end)
	if not ok or typeof(hitsOrErr) ~= "table" then
		return false
	end
	local ghost = c.getDragGhostGui()
	for _, hit in hitsOrErr :: { Instance } do
		if ghost and hit:IsDescendantOf(ghost) then
			continue
		end
		if hit:IsA("GuiObject") and guiInstanceIsUnder(hit, cont :: GuiObject) then
			return true
		end
	end
	return false
end

local function pointOverBackpackProbes(dropPoint: Vector2, rawViewport: Vector2): boolean
	if not isBackpackPanelVisible() then
		return false
	end
	local c = requireCfg()
	local insetPt = DropTargets.screenPointWithGuiInset(rawViewport)
	if
		DropTargets.pointOverBackpackFromGuiHitScan(rawViewport) or DropTargets.pointOverBackpackFromGuiHitScan(insetPt)
	then
		return true
	end
	local cont = c.getBackpackContainer()
	if cont then
		local cg = cont :: GuiObject
		if screenPointInGui(cg, dropPoint) or screenPointInGui(cg, insetPt) then
			return true
		end
	end
	local frame = c.getBackpackGuiFrame()
	if frame then
		if screenPointInGui(frame, dropPoint) or screenPointInGui(frame, insetPt) then
			return true
		end
	end
	return false
end

function DropTargets.pointOverBackpackDropTarget(dropPoint: Vector2, rawViewport: Vector2): boolean
	if pointOverBackpackProbes(dropPoint, rawViewport) then
		return true
	end
	local c = requireCfg()
	local insetPt = DropTargets.screenPointWithGuiInset(rawViewport)
	local probes = { dropPoint, insetPt }
	local toggle = c.getToggleBackpackRef()
	if toggle then
		for _, pt in probes do
			if screenPointInGui(toggle, pt) then
				return true
			end
		end
	end
	local frame = c.getBackpackFrameRef()
	if c.getIsBackpackPanelOpen() and frame then
		for _, pt in probes do
			if screenPointInGui(frame, pt) then
				return true
			end
		end
	end
	return false
end

function DropTargets.ancestorBackpackRowIndexFromGuiObject(inst: Instance): number?
	local c = requireCfg()
	local cont = c.getBackpackContainer()
	if not cont then
		return nil
	end
	local w: Instance? = inst
	while w and w ~= c.playerGui do
		if w.Parent == cont then
			local n = tonumber(w.Name)
			if n and n >= 1 and n <= c.maxBackpackSlots then
				return n
			end
		end
		w = w.Parent
	end
	return nil
end

function DropTargets.backpackRowIndexFromDropProbes(
	rawViewport: Vector2,
	mouseWindow: Vector2,
	ghostViewport: Vector2?
): number?
	if not isBackpackPanelVisible() then
		return nil
	end
	local c = requireCfg()
	local probes: { Vector2 } = { rawViewport, mouseWindow }
	if ghostViewport then
		table.insert(probes, ghostViewport)
	end
	local ghost = c.getDragGhostGui()
	for _, pt in probes do
		local ok, hitsOrErr = pcall(function()
			return c.playerGui:GetGuiObjectsAtPosition(pt.X, pt.Y)
		end)
		if not ok or typeof(hitsOrErr) ~= "table" then
			continue
		end
		for _, hit in hitsOrErr :: { Instance } do
			if ghost and hit:IsDescendantOf(ghost) then
				continue
			end
			local slotIdx = DropTargets.ancestorBackpackRowIndexFromGuiObject(hit)
			if slotIdx then
				return slotIdx
			end
		end
	end
	return nil
end

function DropTargets.probeDragHoverTargets(
	mouseWindow: Vector2,
	rawEnd: Vector2,
	ghostCenter: Vector2?,
	ghostViewport: Vector2?
): (boolean, boolean, boolean)
	local c = requireCfg()
	local overBackpackPanel = false
	local frame = c.getBackpackFrameRef()
	if c.getIsBackpackPanelOpen() and frame then
		local insetPt = DropTargets.screenPointWithGuiInset(rawEnd)
		overBackpackPanel = screenPointInGui(frame, mouseWindow)
			or screenPointInGui(frame, insetPt)
			or DropTargets.pointOverBackpackFromGuiHitScan(rawEnd)
			or DropTargets.pointOverBackpackFromGuiHitScan(insetPt)
		if ghostCenter then
			local ghostInset = DropTargets.screenPointWithGuiInset(ghostCenter)
			overBackpackPanel = overBackpackPanel
				or screenPointInGui(frame, ghostCenter)
				or screenPointInGui(frame, ghostInset)
				or DropTargets.pointOverBackpackFromGuiHitScan(ghostCenter)
		end
		if ghostViewport then
			overBackpackPanel = overBackpackPanel or DropTargets.pointOverBackpackFromGuiHitScan(ghostViewport)
		end
	end
	local overHotbar = not overBackpackPanel
		and (
			DropTargets.hotbarSlotIndexFromDropProbes(mouseWindow, rawEnd, ghostCenter) ~= nil
			or DropTargets.pointOverHotbarDropZoneProbes(mouseWindow, rawEnd)
			or (ghostCenter ~= nil and DropTargets.pointOverHotbarDropZoneProbes(ghostCenter, rawEnd))
			or (ghostViewport ~= nil and DropTargets.pointOverHotbarFromGuiHitScan(ghostViewport))
		)
	local overBackpack = DropTargets.pointOverBackpackDropTarget(mouseWindow, rawEnd)
		or (ghostCenter ~= nil and DropTargets.pointOverBackpackDropTarget(ghostCenter, rawEnd))
	return overHotbar, overBackpack, overBackpackPanel
end

return DropTargets
