-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show with Pokemon-style staggered slide-to-edge.
	Never animates Main.Frames (panel host). Interrupting a restore hard-snaps bases
	before a new hide so positions cannot corrupt (fixes offset panels / missing HUD).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayMusicMuffle = require(script.Parent.GameplayMusicMuffle)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local muffleHeld = false
local restoreFlourish = false
local animGen = 0
-- Soft edge exit/enter — Cubic eases into rest instead of a Quint hard stop.
local SLIDE_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)
local SLIDE_IN = TweenInfo.new(0.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
local SLIDE_IN_FLOURISH = TweenInfo.new(0.48, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local WAVE_STAGGER = 0.012
local FLOURISH_STAGGER = 0.028
local MAX_WAVE_SPAN = 0.085

type GuiSnap = {
	inst: GuiObject,
	wasVisible: boolean,
	basePos: UDim2,
	slidePos: UDim2,
	order: number,
	clips: boolean,
}

type ScreenSnap = {
	gui: ScreenGui,
	wasEnabled: boolean,
}

type ClipRestore = {
	inst: Instance,
	clipsDescendants: boolean?,
	clipToDeviceSafeArea: boolean?,
	safeAreaCompatibility: Enum.SafeAreaCompatibility?,
}

local mainSnaps: { GuiSnap } = {}
local screenSnaps: { ScreenSnap } = {}
local clipRestores: { ClipRestore } = {}
-- Survives snap clears so forceShow can still snap HUD chrome back on-screen.
local lastingBasePos: { [GuiObject]: UDim2 } = {}
local chatWasEnabled = true
local activeTweens: { Tween } = {}
local keepScreenNames: { [string]: boolean } = {}
local keepMainChildNames: { [string]: boolean } = {}
local keepSideChildNames: { [string]: boolean } = {}
local sideUIRef: GuiObject? = nil
local sideUIWasVisible = true
local restoreCallbacks: { () -> () } = {}
local hideCallbacks: { () -> () } = {}

local function fireHidden()
	for _, cb in hideCallbacks do
		task.defer(cb)
	end
end

local function fireRestored()
	for _, cb in restoreCallbacks do
		task.defer(cb)
	end
end

export type HideOpts = {
	keepScreenGuiNames: { string }?,
	keepMainChildNames: { string }?,
	keepSideChildNames: { string }?,
	hideScreenGuiNames: { string }?,
	hideMainChildNames: { string }?,
	skipMuffle: boolean?,
}

export type ShowOpts = {
	instant: boolean?,
	flourish: boolean?,
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

local function restoreClipping()
	for _, entry in clipRestores do
		local inst = entry.inst
		if not inst.Parent then
			continue
		end
		if entry.clipsDescendants ~= nil and inst:IsA("GuiObject") then
			(inst :: GuiObject).ClipsDescendants = entry.clipsDescendants
		end
		if inst:IsA("ScreenGui") then
			local sg = inst :: ScreenGui
			if entry.clipToDeviceSafeArea ~= nil then
				pcall(function()
					(sg :: any).ClipToDeviceSafeArea = entry.clipToDeviceSafeArea
				end)
			end
			if entry.safeAreaCompatibility ~= nil then
				pcall(function()
					(sg :: any).SafeAreaCompatibility = entry.safeAreaCompatibility
				end)
			end
		end
	end
	table.clear(clipRestores)
end

local function disableClippingForSlide(main: Instance, sideUI: GuiObject?)
	table.clear(clipRestores)

	if main:IsA("ScreenGui") then
		local sg = main :: ScreenGui
		local restore: ClipRestore = { inst = sg }
		pcall(function()
			restore.clipToDeviceSafeArea = (sg :: any).ClipToDeviceSafeArea
			;(sg :: any).ClipToDeviceSafeArea = false
		end)
		pcall(function()
			restore.safeAreaCompatibility = (sg :: any).SafeAreaCompatibility
			;(sg :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
		end)
		table.insert(clipRestores, restore)
	end

	local function unclipGui(gui: GuiObject)
		table.insert(clipRestores, {
			inst = gui,
			clipsDescendants = gui.ClipsDescendants,
		})
		gui.ClipsDescendants = false
	end

	if sideUI then
		unclipGui(sideUI)
	end
	for _, entry in mainSnaps do
		if entry.inst.Parent then
			unclipGui(entry.inst)
		end
	end
end

local function contentBounds(gui: GuiObject, vp: Vector2): (Vector2, Vector2)
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local found = false
	local areaCap = vp.X * vp.Y * 0.5

	local function consider(g: GuiObject)
		if not g.Visible then
			return
		end
		local sz = g.AbsoluteSize
		local area = sz.X * sz.Y
		if area < 16 * 16 or area >= areaCap then
			return
		end
		local pos = g.AbsolutePosition
		minX = math.min(minX, pos.X)
		minY = math.min(minY, pos.Y)
		maxX = math.max(maxX, pos.X + sz.X)
		maxY = math.max(maxY, pos.Y + sz.Y)
		found = true
	end

	consider(gui)
	for _, d in gui:GetDescendants() do
		if d:IsA("GuiObject") then
			consider(d :: GuiObject)
		end
	end

	if found then
		local center = Vector2.new((minX + maxX) * 0.5, (minY + maxY) * 0.5)
		local size = Vector2.new(math.max(maxX - minX, 40), math.max(maxY - minY, 40))
		return center, size
	end
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	local fallbackCenter = absPos + absSize * 0.5
	local fallbackSize = Vector2.new(math.min(absSize.X, vp.X * 0.4), math.min(absSize.Y, vp.Y * 0.4))
	return fallbackCenter, fallbackSize
end

local function computeSlidePos(gui: GuiObject, vp: Vector2): UDim2
	local base = gui.Position
	local center, contentSize = contentBounds(gui, vp)
	local inset = GuiService:GetGuiInset()
	local topInset = inset.Y
	local margin = 48 + topInset * 0.25
	local travelX = math.clamp(contentSize.X * 0.82 + margin * 0.65, 64, vp.X * 0.42)
	local travelY = math.clamp(contentSize.Y * 0.82 + margin * 0.65, 52, vp.Y * 0.34)
	local nx = center.X / math.max(vp.X, 1)

	if nx < 0.38 then
		return UDim2.new(base.X.Scale, base.X.Offset - travelX, base.Y.Scale, base.Y.Offset)
	elseif nx > 0.62 then
		return UDim2.new(base.X.Scale, base.X.Offset + travelX, base.Y.Scale, base.Y.Offset)
	elseif center.Y < vp.Y * 0.36 then
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - travelY)
	else
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + travelY)
	end
end

local function waveOrderKey(gui: GuiObject, vp: Vector2): number
	local center = contentBounds(gui, vp)
	return -center.Y + center.X * 0.02
end

local function collectTargets(main: Instance): { GuiObject }
	local targets: { GuiObject } = {}
	local seen: { [GuiObject]: boolean } = {}

	local function addTarget(gui: GuiObject)
		if seen[gui] or not gui.Visible then
			return
		end
		seen[gui] = true
		table.insert(targets, gui)
	end

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		sideUIRef = sideUI :: GuiObject
		for _, sub in sideUI:GetChildren() do
			if sub:IsA("GuiObject") then
				-- Keep mobile admin entry visible through shop/cutscene HUD hides.
				if sub.Name == "AdminFrame" or keepSideChildNames[sub.Name] then
					continue
				end
				addTarget(sub :: GuiObject)
			end
		end
	else
		sideUIRef = nil
	end

	for _, child in main:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end
		if child.Name == "SideUI" or keepMainChildNames[child.Name] then
			continue
		end
		addTarget(child :: GuiObject)
	end

	return targets
end

local function buildKeepSets(opts: HideOpts?)
	table.clear(keepScreenNames)
	table.clear(keepMainChildNames)
	table.clear(keepSideChildNames)
	-- Frames is the panel host — never slide it (causes offset/missing shop panels)
	keepMainChildNames.Frames = true
	keepMainChildNames.TutorialQuestHost = true
	-- Tim Cheese quest HUD must hide with shop/stand panels (not stay on top).
	keepScreenNames.FloatingClaimCutscene = true
	keepScreenNames.BushSpiderCutscene = true
	keepScreenNames.WaveWebChaseFx = true
	keepScreenNames.StandDialogueCutscene = true
	keepScreenNames.TutorialObjective = true
	keepScreenNames.TutorialUiPointer = true
	keepScreenNames.TouchGui = true
	keepScreenNames.WorkoutComboGui = true
	keepScreenNames.SwingTargetMarker = true
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
		if opts.keepSideChildNames then
			for _, name in opts.keepSideChildNames do
				keepSideChildNames[name] = true
			end
		end
		if opts.hideScreenGuiNames then
			for _, name in opts.hideScreenGuiNames do
				keepScreenNames[name] = nil
			end
		end
		if opts.hideMainChildNames then
			for _, name in opts.hideMainChildNames do
				keepMainChildNames[name] = nil
			end
		end
	end
end

local function waveDelay(index: number, count: number): number
	if count <= 1 then
		return 0
	end
	local stagger = if restoreFlourish then FLOURISH_STAGGER else WAVE_STAGGER
	stagger = math.min(stagger, MAX_WAVE_SPAN / (count - 1))
	if restoreFlourish then
		stagger = math.min(FLOURISH_STAGGER, 0.22 / (count - 1))
	end
	return (index - 1) * stagger
end

local function restoreScreenGuis()
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
	local mainGui = pg and pg:FindFirstChild("Main")
	if mainGui and mainGui:IsA("ScreenGui") then
		mainGui.Enabled = true
	end
	-- Frames must always be available for panels
	if mainGui then
		local frames = mainGui:FindFirstChild("Frames")
		if frames and frames:IsA("GuiObject") then
			(frames :: GuiObject).Visible = true
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, chatWasEnabled)
	end)
end

local function hardRestoreSnaps()
	cancelTweens()
	for _, entry in mainSnaps do
		if entry.inst.Parent then
			entry.inst.Position = entry.basePos
			lastingBasePos[entry.inst] = entry.basePos
			entry.inst.Visible = true
			if entry.clips ~= nil then
				entry.inst.ClipsDescendants = entry.clips
			end
		end
	end
	-- Fallback when snaps were cleared mid-restore (gift buy race): pull from lasting bases.
	for gui, basePos in lastingBasePos do
		if gui.Parent then
			gui.Position = basePos
			gui.Visible = true
		else
			lastingBasePos[gui] = nil
		end
	end
	if sideUIRef and sideUIRef.Parent then
		sideUIRef.Visible = true
	end
	restoreClipping()
	restoreScreenGuis()
end

local function nuclearUnparkHud()
	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end
	local side = main:FindFirstChild("SideUI")
	if side and side:IsA("GuiObject") then
		side.Visible = true
		for _, ch in side:GetChildren() do
			if ch:IsA("GuiObject") then
				local g = ch :: GuiObject
				local remembered = lastingBasePos[g]
				if remembered then
					g.Position = remembered
				else
					local p = g.Position
					-- Slide-out parks via large offsets; strip those so layout scale remains.
					if math.abs(p.X.Offset) > 8 or math.abs(p.Y.Offset) > 8 then
						g.Position = UDim2.new(p.X.Scale, 0, p.Y.Scale, 0)
					end
				end
				g.Visible = true
			end
		end
	end
	local frames = main:FindFirstChild("Frames")
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
		(frames :: GuiObject).Active = false
	end
	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in { "Purchasing", "OfflineEarningsDim", "ReviveDim" } do
			local gui = pg:FindFirstChild(name)
			if gui and gui:IsA("ScreenGui") then
				gui.Enabled = false
			end
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
	end)
end

-- Undo an in-progress hide/restore so the next snapshot uses true layout positions
local function revertSnapsToBaseBeforeResnap()
	if #mainSnaps == 0 then
		return
	end
	cancelTweens()
	for _, entry in mainSnaps do
		if entry.inst.Parent then
			entry.inst.Position = entry.basePos
			entry.inst.Visible = entry.wasVisible
			if entry.clips ~= nil then
				entry.inst.ClipsDescendants = entry.clips
			end
		end
	end
	if sideUIRef and sideUIRef.Parent then
		sideUIRef.Visible = sideUIWasVisible
	end
	restoreClipping()
end

local function parkSnapsHidden()
	for _, entry in mainSnaps do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Visible = false
			entry.inst.Position = entry.slidePos
		end
	end
end

local function snapshotAndSlideOut()
	animGen += 1
	local gen = animGen
	-- Critical: if a restore was mid-flight, snap back to real bases before re-hiding
	revertSnapsToBaseBeforeResnap()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	-- Always keep Frames visible for panels
	local frames = main:FindFirstChild("Frames")
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
	end

	local vp = viewportSize()
	local pending: { GuiSnap } = {}
	for _, gui in collectTargets(main) do
		-- Never overwrite a known resting base with a mid-slide position.
		local basePos = lastingBasePos[gui]
		if not basePos then
			basePos = gui.Position
			lastingBasePos[gui] = basePos
		else
			-- Snap back before measuring slide so slide distance is correct.
			gui.Position = basePos
		end
		table.insert(pending, {
			inst = gui,
			wasVisible = true,
			basePos = basePos,
			slidePos = computeSlidePos(gui, vp),
			order = waveOrderKey(gui, vp),
			clips = gui.ClipsDescendants,
		})
	end

	-- Slide Tim Cheese quest chrome with SideUI (dedicated ScreenGui, not under Main).
	local pgEarly = player:FindFirstChild("PlayerGui")
	local questTracker = pgEarly and pgEarly:FindFirstChild("TimCheeseQuestTracker")
	if questTracker and questTracker:IsA("ScreenGui") and questTracker.Enabled then
		local host = questTracker:FindFirstChild("TimCheeseQuestHost")
		if host then
			for _, child in host:GetChildren() do
				if child:IsA("GuiObject") and (child :: GuiObject).Visible then
					local gui = child :: GuiObject
					local basePos = lastingBasePos[gui]
					if not basePos then
						basePos = gui.Position
						lastingBasePos[gui] = basePos
					else
						gui.Position = basePos
					end
					table.insert(pending, {
						inst = gui,
						wasVisible = true,
						basePos = basePos,
						slidePos = computeSlidePos(gui, vp),
						order = waveOrderKey(gui, vp),
						clips = gui.ClipsDescendants,
					})
				end
			end
		end
	end

	if sideUIRef then
		sideUIWasVisible = sideUIRef.Visible
	end

	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	for _, entry in ipairs(pending) do
		table.insert(mainSnaps, entry)
	end

	disableClippingForSlide(main, sideUIRef)

	local count = #pending
	for i, entry in ipairs(pending) do
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
		parkSnapsHidden()
	end)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, ch in pg:GetChildren() do
			if ch:IsA("ScreenGui") and not keepScreenNames[ch.Name] then
				if ch.Name == "Main" then
					continue
				end
				-- Quest tracker slides with chrome; disable after the slide parks.
				if ch.Name == "TimCheeseQuestTracker" then
					table.insert(screenSnaps, { gui = ch, wasEnabled = ch.Enabled })
					task.delay(totalOut, function()
						if gen ~= animGen or hideCount <= 0 then
							return
						end
						if ch.Parent then
							ch.Enabled = false
						end
					end)
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

local function finishRestoreCleanup()
	hardRestoreSnaps()
	table.clear(mainSnaps)
	table.clear(screenSnaps)
	PlayerGuiMain.hideAdminPanelUnlessAllowed()
	fireRestored()
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

	local main = PlayerGuiMain.ensure(player)
	if #clipRestores == 0 then
		disableClippingForSlide(main, sideUIRef)
	end

	if sideUIRef and sideUIRef.Parent then
		sideUIRef.Visible = sideUIWasVisible
	end

	local frames = main:FindFirstChild("Frames")
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
	end

	for _, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = false
		end
	end

	local count = #pending
	if count == 0 then
		finishRestoreCleanup()
		return
	end

	for i, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			local delaySec = waveDelay(i, count)
			task.delay(delaySec, function()
				if gen ~= animGen or hideCount > 0 or not entry.inst.Parent then
					return
				end
				entry.inst.Position = entry.slidePos
				entry.inst.Visible = true
				local info = if restoreFlourish then SLIDE_IN_FLOURISH else SLIDE_IN
				playTween(entry.inst, info, { Position = entry.basePos })
			end)
		elseif entry.inst.Parent then
			entry.inst.Position = entry.basePos
			entry.inst.Visible = false
		end
	end

	task.delay(0.01, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		restoreScreenGuis()
	end)

	local info = if restoreFlourish then SLIDE_IN_FLOURISH else SLIDE_IN
	local totalIn = info.Time + waveDelay(count, count) + 0.06
	task.delay(totalIn, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		restoreFlourish = false
		finishRestoreCleanup()
	end)
end

local function instantRestore()
	animGen += 1
	cancelTweens()
	finishRestoreCleanup()
end

function M.hide(opts: HideOpts?)
	hideCount += 1
	if hideCount == 1 then
		buildKeepSets(opts)
		if not (opts and opts.skipMuffle) then
			GameplayMusicMuffle.push()
			muffleHeld = true
		end
		fireHidden()
		snapshotAndSlideOut()
	else
		-- Nested hide (e.g. dialogue → panel): keep Frames, don't re-snapshot
		keepMainChildNames.Frames = true
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
			if opts.keepSideChildNames then
				for _, name in opts.keepSideChildNames do
					keepSideChildNames[name] = true
				end
			end
			if opts.hideScreenGuiNames then
				for _, name in opts.hideScreenGuiNames do
					keepScreenNames[name] = nil
				end
			end
			if opts.hideMainChildNames then
				for _, name in opts.hideMainChildNames do
					keepMainChildNames[name] = nil
				end
			end
		end
		local main = PlayerGuiMain.ensure(player)
		local frames = main:FindFirstChild("Frames")
		if frames and frames:IsA("GuiObject") then
			(frames :: GuiObject).Visible = true
		end
		fireHidden()
	end
end

function M.show(opts: ShowOpts?)
	if hideCount <= 0 then
		return
	end
	hideCount -= 1
	if hideCount == 0 then
		restoreFlourish = opts ~= nil and opts.flourish == true
		if muffleHeld then
			GameplayMusicMuffle.pop()
			muffleHeld = false
		end
		if opts and opts.instant then
			restoreFlourish = false
			instantRestore()
		else
			slideInAndRestore()
		end
	end
end

function M.forceShow()
	hideCount = 0
	muffleHeld = false
	GameplayMusicMuffle.forceClear()
	instantRestore()
	nuclearUnparkHud()
	fireRestored()
end

function M.isHidden(): boolean
	return hideCount > 0
end

function M.allowsToolbar(): boolean
	return keepSideChildNames.Toolbar == true
end

function M.revealSideChild(name: string): GuiObject?
	local main = PlayerGuiMain.ensure(player)
	local side = main and main:FindFirstChild("SideUI")
	local child = side and side:FindFirstChild(name)
	if not (child and child:IsA("GuiObject")) then
		return nil
	end
	local g = child :: GuiObject
	for _, entry in mainSnaps do
		if entry.inst == g then
			g.Position = entry.basePos
			g.Visible = true
			return g
		end
	end
	local base = lastingBasePos[g]
	if base then
		g.Position = base
	end
	g.Visible = true
	return g
end

function M.reparkSideChild(name: string)
	local main = PlayerGuiMain.ensure(player)
	local side = main and main:FindFirstChild("SideUI")
	local child = side and side:FindFirstChild(name)
	if not (child and child:IsA("GuiObject")) then
		return
	end
	local g = child :: GuiObject
	for _, entry in mainSnaps do
		if entry.inst == g then
			g.Position = entry.slidePos
			g.Visible = false
			return
		end
	end
end

function M.onRestored(callback: () -> ())
	table.insert(restoreCallbacks, callback)
end

function M.onHidden(callback: () -> ())
	table.insert(hideCallbacks, callback)
end

function M.slideTweenInfos(): (TweenInfo, TweenInfo)
	return SLIDE_OUT, SLIDE_IN
end

function M.slideDestination(gui: GuiObject): UDim2
	return computeSlidePos(gui, viewportSize())
end

function M.slideWaveDelay(index: number, count: number): number
	return waveDelay(index, count)
end

function M.slideWaveOrder(gui: GuiObject): number
	return waveOrderKey(gui, viewportSize())
end

return M
