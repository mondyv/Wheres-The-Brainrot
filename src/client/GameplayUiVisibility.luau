-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show with Pokemon-style staggered slide-to-edge.
	Animates individual SideUI buttons (and non-button chrome leaves), not whole frame groups.
	Detaches UIListLayout/UIGridLayout during the slide so Position tweens aren't fought.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local animGen = 0
local SLIDE_OUT = TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WAVE_STAGGER = 0.02
local MAX_WAVE_SPAN = 0.22

type GuiSnap = {
	inst: GuiObject,
	wasVisible: boolean,
	basePos: UDim2,
	slidePos: UDim2,
	order: number,
}

type ScreenSnap = {
	gui: ScreenGui,
	wasEnabled: boolean,
}

type LayoutSnap = {
	layout: UIListLayout | UIGridLayout | UIPageLayout,
	parent: Instance,
}

local mainSnaps: { GuiSnap } = {}
local screenSnaps: { ScreenSnap } = {}
local layoutSnaps: { LayoutSnap } = {}
local chatWasEnabled = true
local activeTweens: { Tween } = {}
local keepScreenNames: { [string]: boolean } = {}
local keepMainChildNames: { [string]: boolean } = {}

export type HideOpts = {
	keepScreenGuiNames: { string }?,
	keepMainChildNames: { string }?,
}

local function cancelTweens()
	for _, tw in activeTweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(activeTweens)
end

local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any })
	local tw = TweenService:Create(inst, info, props)
	table.insert(activeTweens, tw)
	tw:Play()
	return tw
end

local function viewportSize(): Vector2
	local cam = Workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

local function restoreLayouts()
	for _, entry in layoutSnaps do
		if entry.layout and entry.parent and entry.parent.Parent then
			entry.layout.Parent = entry.parent
		end
	end
	table.clear(layoutSnaps)
end

local function detachLayouts(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("UIListLayout") or d:IsA("UIGridLayout") or d:IsA("UIPageLayout") then
			local parent = d.Parent
			if parent then
				table.insert(layoutSnaps, { layout = d, parent = parent })
				d.Parent = nil
			end
		end
	end
end

local function pieceCenter(gui: GuiObject): Vector2
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	return absPos + absSize * 0.5
end

local function computeSlidePos(gui: GuiObject, vp: Vector2): UDim2
	local absSize = gui.AbsoluteSize
	local base = gui.Position
	local margin = 56
	local travelX = math.max(absSize.X + margin, 120)
	local travelY = math.max(absSize.Y + margin, 90)
	local center = pieceCenter(gui)
	local nx = center.X / math.max(vp.X, 1)

	if nx < 0.4 then
		return UDim2.new(base.X.Scale, base.X.Offset - travelX, base.Y.Scale, base.Y.Offset)
	elseif nx > 0.6 then
		return UDim2.new(base.X.Scale, base.X.Offset + travelX, base.Y.Scale, base.Y.Offset)
	elseif center.Y < vp.Y * 0.38 then
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - travelY)
	else
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + travelY)
	end
end

local function waveOrderKey(gui: GuiObject): number
	local center = pieceCenter(gui)
	return -center.Y + center.X * 0.015
end

local function isUnderKeptMainChild(inst: Instance, main: Instance): boolean
	local p: Instance? = inst
	while p and p ~= main do
		if keepMainChildNames[p.Name] then
			return true
		end
		p = p.Parent
	end
	return false
end

local function isVisibleChain(gui: GuiObject, stopAt: Instance): boolean
	local p: Instance? = gui
	while p and p ~= stopAt do
		if p:IsA("GuiObject") and not (p :: GuiObject).Visible then
			return false
		end
		p = p.Parent
	end
	return gui.Visible
end

local function collectTargets(main: Instance): { GuiObject }
	local vp = viewportSize()
	local targets: { GuiObject } = {}
	local seen: { [GuiObject]: boolean } = {}

	local function addTarget(gui: GuiObject)
		if seen[gui] then
			return
		end
		local sz = gui.AbsoluteSize
		if sz.X < 18 or sz.Y < 18 then
			return
		end
		-- Skip near-fullscreen slabs
		if sz.X >= vp.X * 0.7 and sz.Y >= vp.Y * 0.55 then
			return
		end
		seen[gui] = true
		table.insert(targets, gui)
	end

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		local buttons: { GuiButton } = {}
		for _, d in sideUI:GetDescendants() do
			if d:IsA("GuiButton") and isVisibleChain(d :: GuiObject, sideUI) then
				table.insert(buttons, d :: GuiButton)
			end
		end

		-- Prefer outer buttons (skip nested clickables inside another button)
		for _, btn in buttons do
			local nested = false
			for _, other in buttons do
				if other ~= btn and btn:IsDescendantOf(other) then
					nested = true
					break
				end
			end
			if not nested then
				addTarget(btn)
			end
		end

		-- Non-button chrome (cash, boost, area, etc.) that isn't already covered by a button ancestor
		for _, d in sideUI:GetDescendants() do
			if not d:IsA("GuiObject") or d:IsA("GuiButton") then
				continue
			end
			local gui = d :: GuiObject
			if not isVisibleChain(gui, sideUI) then
				continue
			end
			local sz = gui.AbsoluteSize
			if sz.X < 36 or sz.Y < 28 then
				continue
			end
			if sz.X >= vp.X * 0.55 or sz.Y >= vp.Y * 0.4 then
				continue
			end
			-- Only leaf-ish chrome: no GuiButton descendants, and not an ancestor wrapper of a target
			local hasBtn = false
			for _, c in gui:GetDescendants() do
				if c:IsA("GuiButton") then
					hasBtn = true
					break
				end
			end
			if hasBtn then
				continue
			end
			local coversTarget = false
			for _, t in targets do
				if t:IsDescendantOf(gui) then
					coversTarget = true
					break
				end
			end
			if coversTarget then
				continue
			end
			-- Prefer named chrome leaves under Counters / Top / Return / Boosts
			local parent = gui.Parent
			local parentName = if parent then parent.Name else ""
			local useful = gui.Name == "Cash"
				or gui.Name == "Boost"
				or gui.Name == "CurrentArea"
				or gui.Name == "Notif"
				or gui.Name == "Return"
				or parentName == "Counters"
				or parentName == "Top"
				or parentName == "Boosts"
				or parentName == "GamepassBoostIcons"
			if useful then
				addTarget(gui)
			end
		end
	end

	-- Other Main children (not SideUI / kept)
	for _, child in main:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end
		if child.Name == "SideUI" or keepMainChildNames[child.Name] then
			continue
		end
		local gui = child :: GuiObject
		if not gui.Visible then
			continue
		end
		local sz = gui.AbsoluteSize
		if sz.X >= vp.X * 0.65 and sz.Y >= vp.Y * 0.5 then
			for _, sub in gui:GetDescendants() do
				if sub:IsA("GuiButton") and isVisibleChain(sub :: GuiObject, gui) then
					addTarget(sub :: GuiObject)
				end
			end
		else
			addTarget(gui)
		end
	end

	return targets
end

local function buildKeepSets(opts: HideOpts?)
	table.clear(keepScreenNames)
	table.clear(keepMainChildNames)
	keepScreenNames.FloatingClaimCutscene = true
	keepScreenNames.BushSpiderCutscene = true
	keepScreenNames.StandDialogueCutscene = true
	if opts then
		if opts.keepScreenGuiNames then
			for _, name in opts.keepScreenGuiNames do
				keepScreenNames[name] = true
			end
		end
		if opts.keepMainChildNames then
			for _, name in opts.keepMainChildNames do
				keepMainChildNames[name] = true
			end
		end
	end
end

local function waveDelay(index: number, count: number): number
	if count <= 1 then
		return 0
	end
	local stagger = math.min(WAVE_STAGGER, MAX_WAVE_SPAN / (count - 1))
	return (index - 1) * stagger
end

local function snapshotAndSlideOut()
	animGen += 1
	local gen = animGen
	cancelTweens()
	restoreLayouts()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	local vp = viewportSize()
	-- Freeze layouts so per-button Position tweens work
	local sideUI = main:FindFirstChild("SideUI")
	if sideUI then
		detachLayouts(sideUI)
	end

	local pending: { GuiSnap } = {}
	for _, gui in collectTargets(main) do
		if isUnderKeptMainChild(gui, main) then
			continue
		end
		local basePos = gui.Position
		local slidePos = computeSlidePos(gui, vp)
		table.insert(pending, {
			inst = gui,
			wasVisible = true,
			basePos = basePos,
			slidePos = slidePos,
			order = waveOrderKey(gui),
		})
	end

	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	local count = #pending
	for i, entry in ipairs(pending) do
		table.insert(mainSnaps, entry)
		local delaySec = waveDelay(i, count)
		task.delay(delaySec, function()
			if gen ~= animGen or hideCount <= 0 or not entry.inst.Parent then
				return
			end
			playTween(entry.inst, SLIDE_OUT, { Position = entry.slidePos })
		end)
	end

	local totalOut = SLIDE_OUT.Time + waveDelay(count, count) + 0.01
	task.delay(totalOut, function()
		if gen ~= animGen or hideCount <= 0 then
			return
		end
		for _, entry in mainSnaps do
			if entry.inst.Parent then
				entry.inst.Visible = false
				entry.inst.Position = entry.slidePos
			end
		end
	end)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, ch in pg:GetChildren() do
			if ch:IsA("ScreenGui") and not keepScreenNames[ch.Name] then
				if ch.Name == "Main" then
					continue
				end
				table.insert(screenSnaps, { gui = ch, wasEnabled = ch.Enabled })
				ch.Enabled = false
			end
		end
	end

	pcall(function()
		chatWasEnabled = true
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
	end)
end

local function slideInAndRestore()
	animGen += 1
	local gen = animGen
	cancelTweens()

	local pending: { GuiSnap } = {}
	for _, entry in mainSnaps do
		table.insert(pending, entry)
	end
	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	for _, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = false
		end
	end

	local count = #pending
	if count == 0 then
		restoreLayouts()
		for _, entry in screenSnaps do
			if entry.gui.Parent then
				entry.gui.Enabled = entry.wasEnabled
			end
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, chatWasEnabled)
		end)
		table.clear(mainSnaps)
		table.clear(screenSnaps)
		return
	end

	for i, entry in ipairs(pending) do
		if entry.inst.Parent then
			if entry.wasVisible then
				local delaySec = waveDelay(i, count)
				task.delay(delaySec, function()
					if gen ~= animGen or hideCount > 0 or not entry.inst.Parent then
						return
					end
					entry.inst.Position = entry.slidePos
					entry.inst.Visible = true
					playTween(entry.inst, SLIDE_IN, { Position = entry.basePos })
				end)
			else
				entry.inst.Position = entry.basePos
			end
		end
	end

	task.delay(0.01, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		for _, entry in screenSnaps do
			if entry.gui.Parent then
				if entry.gui.Name == "Main" then
					entry.gui.Enabled = true
				else
					entry.gui.Enabled = entry.wasEnabled
				end
			end
		end
		local pg = player:FindFirstChild("PlayerGui")
		local main = pg and pg:FindFirstChild("Main")
		if main and main:IsA("ScreenGui") then
			main.Enabled = true
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, chatWasEnabled)
		end)
	end)

	local totalIn = SLIDE_IN.Time + waveDelay(count, count) + 0.03
	task.delay(totalIn, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		for _, entry in mainSnaps do
			if entry.inst.Parent and entry.wasVisible then
				entry.inst.Position = entry.basePos
				entry.inst.Visible = true
			end
		end
		restoreLayouts()
		table.clear(mainSnaps)
		table.clear(screenSnaps)
	end)
end

function M.hide(opts: HideOpts?)
	hideCount += 1
	if hideCount == 1 then
		buildKeepSets(opts)
		-- Start immediately — no deferred wait
		snapshotAndSlideOut()
	else
		if opts then
			if opts.keepScreenGuiNames then
				for _, name in opts.keepScreenGuiNames do
					keepScreenNames[name] = true
				end
			end
			if opts.keepMainChildNames then
				for _, name in opts.keepMainChildNames do
					keepMainChildNames[name] = true
				end
			end
		end
	end
end

function M.show()
	if hideCount <= 0 then
		return
	end
	hideCount -= 1
	if hideCount == 0 then
		slideInAndRestore()
	end
end

function M.forceShow()
	hideCount = 0
	slideInAndRestore()
end

function M.isHidden(): boolean
	return hideCount > 0
end

return M
