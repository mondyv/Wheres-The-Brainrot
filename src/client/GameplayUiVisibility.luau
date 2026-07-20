-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene / panel HUD hide/show with Pokemon-style staggered slide-to-edge.
	Ref-counted so nested hides don't restore early.
	Prefers left/right slides (SideUI / edge chrome) instead of accidental up/down.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local SLIDE_OUT = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local WAVE_STAGGER = 0.05

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

local function computeSlidePos(gui: GuiObject): UDim2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	local base = gui.Position
	local margin = 96
	local travel = math.max(absSize.X * 0.4, absSize.Y * 0.35, 180) + margin

	local coversMost = absSize.X >= vp.X * 0.65 and absSize.Y >= vp.Y * 0.5
	-- SideUI is usually a fullscreen host for left chrome — always exit left.
	if gui.Name == "SideUI" or coversMost then
		local goLeft = true
		if gui.Name ~= "SideUI" then
			if gui.AnchorPoint.X > 0.55 or base.X.Scale > 0.55 then
				goLeft = false
			elseif gui.AnchorPoint.X < 0.45 or base.X.Scale < 0.45 then
				goLeft = true
			else
				goLeft = (absPos.X + absSize.X * 0.5) <= vp.X * 0.5
			end
		end
		if goLeft then
			return UDim2.new(base.X.Scale, base.X.Offset - travel, base.Y.Scale, base.Y.Offset)
		end
		return UDim2.new(base.X.Scale, base.X.Offset + travel, base.Y.Scale, base.Y.Offset)
	end

	local centerX = absPos.X + absSize.X * 0.5
	local centerY = absPos.Y + absSize.Y * 0.5
	local distL = centerX
	local distR = vp.X - centerX
	local distT = centerY
	local distB = vp.Y - centerY
	local minH = math.min(distL, distR)
	local minV = math.min(distT, distB)

	-- Prefer horizontal unless clearly glued to top/bottom edge
	if minH <= minV * 1.25 then
		if distL <= distR then
			return UDim2.new(base.X.Scale, base.X.Offset - travel, base.Y.Scale, base.Y.Offset)
		end
		return UDim2.new(base.X.Scale, base.X.Offset + travel, base.Y.Scale, base.Y.Offset)
	end

	local vTravel = math.max(absSize.Y, 120) + margin
	if distT <= distB then
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - vTravel)
	end
	return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + vTravel)
end

local function waveOrderKey(gui: GuiObject): number
	local absPos = gui.AbsolutePosition
	-- Left-to-right wave primarily
	return absPos.X * 1.0 + absPos.Y * 0.15
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
	cancelTweens()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	local pending: { GuiSnap } = {}
	for _, child in main:GetChildren() do
		if child:IsA("GuiObject") then
			if keepMainChildNames[child.Name] then
				continue
			end
			local gui = child :: GuiObject
			local basePos = gui.Position
			local slidePos = computeSlidePos(gui)
			table.insert(pending, {
				inst = gui,
				wasVisible = gui.Visible,
				basePos = basePos,
				slidePos = slidePos,
				order = waveOrderKey(gui),
			})
		end
	end

	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	for i, entry in ipairs(pending) do
		table.insert(mainSnaps, entry)
		if entry.wasVisible then
			local delaySec = (i - 1) * WAVE_STAGGER
			task.delay(delaySec, function()
				if hideCount <= 0 or not entry.inst.Parent then
					return
				end
				playTween(entry.inst, SLIDE_OUT, { Position = entry.slidePos })
			end)
		end
	end

	local totalOut = SLIDE_OUT.Time + math.max(0, #pending - 1) * WAVE_STAGGER + 0.02
	task.delay(totalOut, function()
		if hideCount <= 0 then
			return
		end
		for _, entry in mainSnaps do
			if entry.inst.Parent and not keepMainChildNames[entry.inst.Name] then
				entry.inst.Visible = false
				entry.inst.Position = entry.basePos
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
	cancelTweens()

	local pending: { GuiSnap } = {}
	for _, entry in mainSnaps do
		table.insert(pending, entry)
	end
	table.sort(pending, function(a, b)
		return a.order < b.order
	end)

	for i, entry in ipairs(pending) do
		if entry.inst.Parent then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = entry.wasVisible
			if entry.wasVisible then
				local delaySec = (i - 1) * WAVE_STAGGER
				task.delay(delaySec, function()
					if hideCount > 0 or not entry.inst.Parent then
						return
					end
					playTween(entry.inst, SLIDE_IN, { Position = entry.basePos })
				end)
			else
				entry.inst.Position = entry.basePos
			end
		end
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

	local totalIn = SLIDE_IN.Time + math.max(0, #pending - 1) * WAVE_STAGGER + 0.05
	task.delay(totalIn, function()
		if hideCount > 0 then
			return
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
