-- [ACTIVE] GameplayUiVisibility
--[[
	Shared cutscene HUD hide/show with Pokemon-style slide-to-edge animation.
	Ref-counted so nested cutscenes don't restore early.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local M = {}

local hideCount = 0
local SLIDE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SLIDE_IN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

type GuiSnap = {
	inst: GuiObject,
	wasVisible: boolean,
	basePos: UDim2,
	slidePos: UDim2,
}

type ScreenSnap = {
	gui: ScreenGui,
	wasEnabled: boolean,
}

local mainSnaps: { GuiSnap } = {}
local screenSnaps: { ScreenSnap } = {}
local chatWasEnabled = true
local activeTweens: { Tween } = {}
local keepNames: { [string]: boolean } = {}

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
	local center = absPos + absSize * 0.5
	local base = gui.Position
	local margin = 80

	if center.X < vp.X * 0.38 then
		-- Left side → slide further left
		return UDim2.new(base.X.Scale, base.X.Offset - (absSize.X + margin), base.Y.Scale, base.Y.Offset)
	elseif center.X > vp.X * 0.62 then
		return UDim2.new(base.X.Scale, base.X.Offset + (absSize.X + margin), base.Y.Scale, base.Y.Offset)
	elseif center.Y < vp.Y * 0.42 then
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset - (absSize.Y + margin))
	else
		return UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset + (absSize.Y + margin))
	end
end

local function buildKeepSet(extraKeep: { string }?)
	table.clear(keepNames)
	keepNames.FloatingClaimCutscene = true
	keepNames.BushSpiderCutscene = true
	keepNames.StandDialogueCutscene = true
	if extraKeep then
		for _, name in extraKeep do
			keepNames[name] = true
		end
	end
end

local function snapshotAndSlideOut()
	cancelTweens()
	table.clear(mainSnaps)
	table.clear(screenSnaps)

	local main = PlayerGuiMain.ensure(player)
	-- Force Main enabled so children can animate out
	if main:IsA("ScreenGui") then
		main.Enabled = true
	end

	for _, child in main:GetChildren() do
		if child:IsA("GuiObject") then
			local gui = child :: GuiObject
			local basePos = gui.Position
			local slidePos = computeSlidePos(gui)
			table.insert(mainSnaps, {
				inst = gui,
				wasVisible = gui.Visible,
				basePos = basePos,
				slidePos = slidePos,
			})
			if gui.Visible then
				playTween(gui, SLIDE_OUT, { Position = slidePos })
			end
		end
	end

	task.delay(SLIDE_OUT.Time + 0.02, function()
		if hideCount <= 0 then
			return
		end
		for _, entry in mainSnaps do
			if entry.inst.Parent then
				entry.inst.Visible = false
				entry.inst.Position = entry.basePos
			end
		end
	end)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, ch in pg:GetChildren() do
			if ch:IsA("ScreenGui") and not keepNames[ch.Name] then
				-- Keep Main enabled (we hide its children); disable other gameplay ScreenGuis
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

	for _, entry in mainSnaps do
		if entry.inst.Parent then
			entry.inst.Position = entry.slidePos
			entry.inst.Visible = entry.wasVisible
			if entry.wasVisible then
				playTween(entry.inst, SLIDE_IN, { Position = entry.basePos })
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
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			sideUI.Visible = true
		end
	end

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, chatWasEnabled)
	end)

	task.delay(SLIDE_IN.Time + 0.05, function()
		if hideCount > 0 then
			return
		end
		table.clear(mainSnaps)
		table.clear(screenSnaps)
	end)
end

--[[
	hide(opts?) — opts.keepScreenGuiNames: extra ScreenGui names to leave enabled
]]
function M.hide(opts: { keepScreenGuiNames: { string }? }?)
	hideCount += 1
	if hideCount == 1 then
		buildKeepSet(if opts then opts.keepScreenGuiNames else nil)
		-- Defer one frame so AbsolutePosition is valid
		task.defer(function()
			if hideCount > 0 then
				snapshotAndSlideOut()
			end
		end)
	else
		if opts and opts.keepScreenGuiNames then
			for _, name in opts.keepScreenGuiNames do
				keepNames[name] = true
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
