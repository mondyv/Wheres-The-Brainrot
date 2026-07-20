-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show with Pokemon-style staggered slide-to-edge.
	Ref-counted so nested hides don't restore early.

	Fullscreen hosts (SideUI) expand into real chrome groups. Slide direction + wave
	order use each group's visible content center so left/right/bottom pieces move
	as separate staggered units (not one simultaneous fullscreen slab).
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
local SLIDE_OUT = TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WAVE_STAGGER = 0.08

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

local mainSnaps: { GuiSnap } = {}
local screenSnaps: { ScreenSnap } = {}
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

-- Content-weighted center so fullscreen wrappers still slide by where the chrome actually sits.
local function contentCenter(gui: GuiObject, vp: Vector2): Vector2
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local found = false
	local areaCap = vp.X * vp.Y * 0.45

	local function consider(g: GuiObject)
		if not g.Visible then
			return
		end
		local sz = g.AbsoluteSize
		local area = sz.X * sz.Y
		if area < 24 * 24 or area >= areaCap then
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
		return Vector2.new((minX + maxX) * 0.5, (minY + maxY) * 0.5)
	end
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	return absPos + absSize * 0.5
end

local function computeSlidePos(gui: GuiObject, vp: Vector2): UDim2
	local absSize = gui.AbsoluteSize
	local base = gui.Position
	local margin = 80
	local travelX = math.max(absSize.X + margin, 180)
	local travelY = math.max(absSize.Y + margin, 140)
	local center = contentCenter(gui, vp)
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

-- Lower content exits first (bottom → top wave)
local function waveOrderKey(gui: GuiObject, vp: Vector2): number
	local center = contentCenter(gui, vp)
	return -center.Y + center.X * 0.02
end

local function isFullscreenHost(gui: GuiObject, vp: Vector2): boolean
	if gui.Name == "SideUI" then
		return true
	end
	local absSize = gui.AbsoluteSize
	return absSize.X >= vp.X * 0.65 and absSize.Y >= vp.Y * 0.5
end

local function collectTargets(main: Instance): { GuiObject }
	local vp = viewportSize()
	local targets: { GuiObject } = {}
	local seen: { [GuiObject]: boolean } = {}

	local function addTarget(gui: GuiObject)
		if seen[gui] or not gui.Visible then
			return
		end
		seen[gui] = true
		table.insert(targets, gui)
	end

	for _, child in main:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end
		if keepMainChildNames[child.Name] then
			continue
		end
		local gui = child :: GuiObject
		if isFullscreenHost(gui, vp) then
			-- Animate SideUI chrome groups (Lef1, Top, Counters, Toolbar, …) as separate wave units
			for _, sub in gui:GetChildren() do
				if sub:IsA("GuiObject") and (sub :: GuiObject).Visible then
					addTarget(sub :: GuiObject)
				end
			end
		elseif gui.Visible then
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

local function snapshotAndSlideOut()
	animGen += 1
	local gen = animGen
	cancelTweens()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	local vp = viewportSize()
	local pending: { GuiSnap } = {}
	for _, gui in collectTargets(main) do
		local basePos = gui.Position
		local slidePos = computeSlidePos(gui, vp)
		table.insert(pending, {
			inst = gui,
			wasVisible = true,
			basePos = basePos,
			slidePos = slidePos,
			order = waveOrderKey(gui, vp),
		})
	end

	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	for i, entry in ipairs(pending) do
		table.insert(mainSnaps, entry)
		local delaySec = (i - 1) * WAVE_STAGGER
		task.delay(delaySec, function()
			if gen ~= animGen or hideCount <= 0 or not entry.inst.Parent then
				return
			end
			playTween(entry.inst, SLIDE_OUT, { Position = entry.slidePos })
		end)
	end

	local totalOut = SLIDE_OUT.Time + math.max(0, #pending - 1) * WAVE_STAGGER + 0.02
	task.delay(totalOut, function()
		if gen ~= animGen or hideCount <= 0 then
			return
		end
		for _, entry in mainSnaps do
			if entry.inst.Parent then
				-- Stay parked off-screen (no snap back to base while hidden — avoids restore jitter)
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

	-- Park everything off-screen first so nothing pops at rest position
	for _, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = false
		end
	end

	for i, entry in ipairs(pending) do
		if entry.inst.Parent then
			if entry.wasVisible then
				local delaySec = (i - 1) * WAVE_STAGGER
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

	-- Restore other ScreenGuis after the first HUD piece starts (less flash/jitter)
	task.delay(0.02, function()
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

	local totalIn = SLIDE_IN.Time + math.max(0, #pending - 1) * WAVE_STAGGER + 0.04
	task.delay(totalIn, function()
		if gen ~= animGen or hideCount > 0 then
			return
		end
		-- Snap any stragglers to base in case a tween was interrupted
		for _, entry in mainSnaps do
			if entry.inst.Parent and entry.wasVisible then
				entry.inst.Position = entry.basePos
				entry.inst.Visible = true
			end
		end
		table.clear(mainSnaps)
		table.clear(screenSnaps)
	end)
end

function M.hide(opts: HideOpts?)
	hideCount += 1
	if hideCount == 1 then
		buildKeepSets(opts)
		task.defer(function()
			if hideCount > 0 then
				snapshotAndSlideOut()
			end
		end)
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
