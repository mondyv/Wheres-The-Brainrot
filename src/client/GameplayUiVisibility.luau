-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show with Pokemon-style staggered slide-to-edge.
	Animates SideUI chrome *groups* (Lef1, Top, Counters, Toolbar, …) as whole units
	so nothing is left half-visible. No layout detach — avoids broken/stuck UI.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameplayMusicMuffle = require(script.Parent.GameplayMusicMuffle)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local animGen = 0
local SLIDE_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WAVE_STAGGER = 0.028
local MAX_WAVE_SPAN = 0.2

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
local sideUIRef: GuiObject? = nil
local sideUIWasVisible = true

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

-- Content-weighted center so fullscreen wrappers slide by where chrome actually sits.
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
		if area < 20 * 20 or area >= areaCap then
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
	return gui.AbsolutePosition + gui.AbsoluteSize * 0.5
end

local function computeSlidePos(gui: GuiObject, vp: Vector2): UDim2
	local absSize = gui.AbsoluteSize
	local base = gui.Position
	local margin = 72
	local travelX = math.max(absSize.X + margin, 160)
	local travelY = math.max(absSize.Y + margin, 120)
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

local function waveOrderKey(gui: GuiObject, vp: Vector2): number
	local center = contentCenter(gui, vp)
	return -center.Y + center.X * 0.02
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

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		sideUIRef = sideUI :: GuiObject
		-- Whole chrome groups — never partial buttons (avoids “some stays some goes”)
		for _, sub in sideUI:GetChildren() do
			if sub:IsA("GuiObject") then
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

local function forceHideAllSnaps()
	for _, entry in mainSnaps do
		if entry.inst.Parent then
			entry.inst.Visible = false
			entry.inst.Position = entry.slidePos
		end
	end
	-- Sweep any SideUI child that appeared mid-hide or was missed
	local side = sideUIRef
	if side and side.Parent then
		for _, sub in side:GetChildren() do
			if sub:IsA("GuiObject") then
				(sub :: GuiObject).Visible = false
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
			wasVisible = gui.Visible,
			basePos = basePos,
			slidePos = slidePos,
			order = waveOrderKey(gui, vp),
		})
	end

	if sideUIRef then
		sideUIWasVisible = sideUIRef.Visible
	end

	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	local count = #pending
	for i, entry in ipairs(pending) do
		table.insert(mainSnaps, entry)
		if not entry.wasVisible then
			continue
		end
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
		forceHideAllSnaps()
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

	if sideUIRef and sideUIRef.Parent then
		sideUIRef.Visible = sideUIWasVisible
	end

	for _, entry in ipairs(pending) do
		if entry.inst.Parent and entry.wasVisible then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = false
		end
	end

	local count = #pending
	if count == 0 then
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
				entry.inst.Visible = false
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
			if entry.inst.Parent then
				entry.inst.Position = entry.basePos
				entry.inst.Visible = entry.wasVisible
			end
		end
		-- Ensure every SideUI group is back if it was visible before
		local side = sideUIRef
		if side and side.Parent then
			side.Visible = sideUIWasVisible
			local restored: { [GuiObject]: boolean } = {}
			for _, entry in mainSnaps do
				restored[entry.inst] = true
			end
			for _, sub in side:GetChildren() do
				if sub:IsA("GuiObject") and not restored[sub :: GuiObject] then
					-- Missed child: show again at current position (safer than leaving hidden)
					(sub :: GuiObject).Visible = true
				end
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
		GameplayMusicMuffle.push()
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
		GameplayMusicMuffle.pop()
		slideInAndRestore()
	end
end

function M.forceShow()
	hideCount = 0
	GameplayMusicMuffle.forceClear()
	slideInAndRestore()
end

function M.isHidden(): boolean
	return hideCount > 0
end

return M
