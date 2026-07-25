-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show.
	Animates individual SideUI buttons (not whole Lef1/Top groups) on staggered
	quadratic arcs. Detaches list/grid layouts during the slide so Position tweens win.
	Never animates Main.Frames. Hard-resets bases before re-hide so positions stay clean.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayMusicMuffle = require(script.Parent.GameplayMusicMuffle)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local animGen = 0
local SLIDE_OUT_DUR = 0.22
local SLIDE_IN_DUR = 0.24
local WAVE_STAGGER = 0.032
local MAX_WAVE_SPAN = 0.28
local ARC_HEIGHT = 42

type GuiSnap = {
	inst: GuiObject,
	wasVisible: boolean,
	basePos: UDim2,
	deltaX: number,
	deltaY: number,
	arcSign: number,
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

type LayoutSnap = {
	layout: UIListLayout | UIGridLayout | UIPageLayout,
	parent: Instance,
}

type Flight = {
	entry: GuiSnap,
	t0: number,
	dur: number,
	goingOut: boolean,
}

local mainSnaps: { GuiSnap } = {}
local screenSnaps: { ScreenSnap } = {}
local clipRestores: { ClipRestore } = {}
local layoutSnaps: { LayoutSnap } = {}
local chatWasEnabled = true
local keepScreenNames: { [string]: boolean } = {}
local keepMainChildNames: { [string]: boolean } = {}
local sideUIRef: GuiObject? = nil
local sideUIWasVisible = true
local restoreCallbacks: { () -> () } = {}
local flightConn: RBXScriptConnection? = nil
local activeFlights: { Flight } = {}

export type HideOpts = {
	keepScreenGuiNames: { string }?,
	keepMainChildNames: { string }?,
}

export type ShowOpts = {
	instant: boolean?,
}

local function easeQuadIn(t: number): number
	return t * t
end

local function easeQuadOut(t: number): number
	local u = 1 - t
	return 1 - u * u
end

local function viewportSize(): Vector2
	local cam = Workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

local function stopFlights()
	if flightConn then
		flightConn:Disconnect()
		flightConn = nil
	end
	table.clear(activeFlights)
end

local function applyFlightPos(entry: GuiSnap, alpha: number, goingOut: boolean)
	local eased = if goingOut then easeQuadIn(alpha) else easeQuadOut(alpha)
	-- Quadratic arc: peaks mid-flight (4t(1-t))
	local arc = 4 * alpha * (1 - alpha) * ARC_HEIGHT * entry.arcSign
	local x = if goingOut then entry.deltaX * eased else entry.deltaX * (1 - eased)
	local y = if goingOut then entry.deltaY * eased else entry.deltaY * (1 - eased)
	-- Arc is perpendicular-ish: bias upward on horizontal exits, sideways on vertical
	local ax = 0
	local ay = 0
	if math.abs(entry.deltaX) >= math.abs(entry.deltaY) then
		ay = -arc
	else
		ax = arc * 0.55
	end
	local base = entry.basePos
	entry.inst.Position = UDim2.new(
		base.X.Scale,
		base.X.Offset + x + ax,
		base.Y.Scale,
		base.Y.Offset + y + ay
	)
end

local function ensureFlightLoop()
	if flightConn then
		return
	end
	flightConn = RunService.RenderStepped:Connect(function()
		if #activeFlights == 0 then
			stopFlights()
			return
		end
		local now = os.clock()
		local i = 1
		while i <= #activeFlights do
			local flight = activeFlights[i]
			local entry = flight.entry
			if not entry.inst.Parent then
				table.remove(activeFlights, i)
				continue
			end
			local a = math.clamp((now - flight.t0) / math.max(flight.dur, 0.01), 0, 1)
			applyFlightPos(entry, a, flight.goingOut)
			if a >= 1 then
				if flight.goingOut then
					entry.inst.Visible = false
					entry.inst.Position = UDim2.new(
						entry.basePos.X.Scale,
						entry.basePos.X.Offset + entry.deltaX,
						entry.basePos.Y.Scale,
						entry.basePos.Y.Offset + entry.deltaY
					)
				else
					entry.inst.Position = entry.basePos
					entry.inst.Visible = entry.wasVisible
				end
				table.remove(activeFlights, i)
			else
				i += 1
			end
		end
	end)
end

local function startFlight(entry: GuiSnap, goingOut: boolean, delaySec: number, dur: number, gen: number)
	task.delay(delaySec, function()
		if gen ~= animGen or not entry.inst.Parent then
			return
		end
		if goingOut and hideCount <= 0 then
			return
		end
		if not goingOut and hideCount > 0 then
			return
		end
		if goingOut then
			entry.inst.Visible = true
			entry.inst.Position = entry.basePos
		else
			entry.inst.Visible = true
			applyFlightPos(entry, 0, false) -- at full delta (goingOut false alpha 0 => delta*(1-0)=delta)
		end
		table.insert(activeFlights, {
			entry = entry,
			t0 = os.clock(),
			dur = dur,
			goingOut = goingOut,
		})
		ensureFlightLoop()
	end)
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
		for _, d in sideUI:GetDescendants() do
			if d:IsA("GuiObject") and (d :: GuiObject).ClipsDescendants then
				unclipGui(d :: GuiObject)
			end
		end
	end
end

local function pieceCenter(gui: GuiObject): Vector2
	return gui.AbsolutePosition + gui.AbsoluteSize * 0.5
end

local function computeSlideDelta(gui: GuiObject, vp: Vector2): (number, number, number)
	local absSize = gui.AbsoluteSize
	local center = pieceCenter(gui)
	local inset = GuiService:GetGuiInset()
	local margin = 36 + inset.Y * 0.2
	local travelX = math.clamp(absSize.X + margin, 70, vp.X * 0.5)
	local travelY = math.clamp(absSize.Y + margin, 60, vp.Y * 0.42)
	local nx = center.X / math.max(vp.X, 1)
	local arcSign = if center.X < vp.X * 0.5 then 1 else -1

	if nx < 0.4 then
		return -travelX, 0, arcSign
	elseif nx > 0.6 then
		return travelX, 0, -arcSign
	elseif center.Y < vp.Y * 0.38 then
		return 0, -travelY, arcSign
	else
		return 0, travelY, arcSign
	end
end

local function waveOrderKey(gui: GuiObject): number
	local center = pieceCenter(gui)
	return -center.Y + center.X * 0.015
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
		if sz.X >= vp.X * 0.7 and sz.Y >= vp.Y * 0.55 then
			return
		end
		seen[gui] = true
		table.insert(targets, gui)
	end

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		sideUIRef = sideUI :: GuiObject

		local buttons: { GuiButton } = {}
		for _, d in sideUI:GetDescendants() do
			if d:IsA("GuiButton") and isVisibleChain(d :: GuiObject, sideUI) then
				table.insert(buttons, d :: GuiButton)
			end
		end

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

		-- Non-button chrome leaves (cash, boost, area…)
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
			local covers = false
			for _, t in targets do
				if t:IsDescendantOf(gui) then
					covers = true
					break
				end
			end
			if covers then
				continue
			end
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
	keepMainChildNames.Frames = true
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

local function fireRestored()
	for _, cb in restoreCallbacks do
		task.defer(cb)
	end
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
	stopFlights()
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
	restoreLayouts()
	restoreClipping()
	restoreScreenGuis()
end

local function revertSnapsToBaseBeforeResnap()
	if #mainSnaps == 0 then
		return
	end
	stopFlights()
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
	restoreLayouts()
	restoreClipping()
end

local function snapshotAndSlideOut()
	animGen += 1
	local gen = animGen
	revertSnapsToBaseBeforeResnap()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	local frames = main:FindFirstChild("Frames")
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
	end

	local vp = viewportSize()
	-- Snapshot positions WHILE layouts still apply (true resting layout)
	local pending: { GuiSnap } = {}
	for _, gui in collectTargets(main) do
		local dx, dy, arcSign = computeSlideDelta(gui, vp)
		table.insert(pending, {
			inst = gui,
			wasVisible = true,
			basePos = gui.Position,
			deltaX = dx,
			deltaY = dy,
			arcSign = arcSign,
			order = waveOrderKey(gui),
			clips = gui.ClipsDescendants,
		})
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

	-- Freeze layouts so each button can fly on its own
	if sideUIRef then
		detachLayouts(sideUIRef)
	end
	disableClippingForSlide(main, sideUIRef)

	local count = #pending
	for i, entry in ipairs(pending) do
		startFlight(entry, true, waveDelay(i, count), SLIDE_OUT_DUR, gen)
	end

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

local function finishRestoreCleanup()
	hardRestoreSnaps()
	table.clear(mainSnaps)
	table.clear(screenSnaps)
	fireRestored()
end

local function slideInAndRestore()
	animGen += 1
	local gen = animGen
	stopFlights()

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
	-- Layouts should still be detached from hide; if not, detach again
	if sideUIRef and #layoutSnaps == 0 then
		detachLayouts(sideUIRef)
	end

	if sideUIRef and sideUIRef.Parent then
		sideUIRef.Visible = sideUIWasVisible
	end

	local frames = main:FindFirstChild("Frames")
	if frames and frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
	end

	local count = #pending
	if count == 0 then
		finishRestoreCleanup()
		return
	end

	-- Park at off-screen end of arc, then fly home
	for _, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Visible = false
			applyFlightPos(entry, 1, true)
		end
	end

	for i, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			startFlight(entry, false, waveDelay(i, count), SLIDE_IN_DUR, gen)
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

	local totalIn = SLIDE_IN_DUR + waveDelay(count, count) + 0.05
	task.delay(totalIn, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		finishRestoreCleanup()
	end)
end

local function instantRestore()
	animGen += 1
	stopFlights()
	finishRestoreCleanup()
end

function M.hide(opts: HideOpts?)
	hideCount += 1
	if hideCount == 1 then
		buildKeepSets(opts)
		GameplayMusicMuffle.push()
		snapshotAndSlideOut()
	else
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
		end
		local main = PlayerGuiMain.ensure(player)
		local frames = main:FindFirstChild("Frames")
		if frames and frames:IsA("GuiObject") then
			(frames :: GuiObject).Visible = true
		end
	end
end

function M.show(opts: ShowOpts?)
	if hideCount <= 0 then
		return
	end
	hideCount -= 1
	if hideCount == 0 then
		GameplayMusicMuffle.pop()
		if opts and opts.instant then
			instantRestore()
		else
			slideInAndRestore()
		end
	end
end

function M.forceShow()
	hideCount = 0
	GameplayMusicMuffle.forceClear()
	instantRestore()
end

function M.isHidden(): boolean
	return hideCount > 0
end

function M.onRestored(callback: () -> ())
	table.insert(restoreCallbacks, callback)
end

return M
