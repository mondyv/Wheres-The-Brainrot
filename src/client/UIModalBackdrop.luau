--[[
	Modal backdrop using StarterGui → PlayerGui "Blur" ScreenGui.

	• Ref-counted push/pop — blur only visible while refCount > 0.
	• Forces full-screen layout (Starter templates often ship as a centered patch).
	• Cool frosted veil + tweened Lighting.BlurEffect for a smooth backdrop.
	• When refCount == 0, an Enabled guard turns the ScreenGui off if nested LocalScripts
	  re-enable it.

	Legacy Lighting.UIModalBlur + Main.UIModalDim are removed on first attach.

	Starter blur pastes often add Lighting.DepthOfFieldEffect then Debris:Destroy(script), leaving FX
	stacked — we strip DepthOfField without Attribute KeepDepthOfField (see docs/StarterGuiBlur.md).
--]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Set Attribute KeepDepthOfField = true on any DepthOfFieldEffect you keep for world/cinematics (do not wipe).
local KEEP_DEPTH_ATTR = "KeepDepthOfField"
local BLUR_EFFECT_NAME = "UIModalBlur"
local GRADIENT_NAME = "UIModalBackdropGradient"

local player = Players.LocalPlayer

local refCount = 0
local blurScreenGui: ScreenGui? = nil
local legacyCleaned = false
local enabledGuardAttached: ScreenGui? = nil
local suspendDescendantConn: RBXScriptConnection? = nil
local heartbeatSuspendConn: RBXScriptConnection? = nil
local overlayTween: Tween? = nil
local overlayOutTweens: { Tween } = {}
local worldBlurTween: Tween? = nil
local backdropAnimating = false

-- Cool slate-blue frost — not a bright white sheet.
local OVERLAY_COLOR = Color3.fromRGB(16, 24, 38)
local OVERLAY_MAIN_TRANSPARENCY = 0.76
local OVERLAY_BLUR_MODULE_TRANSPARENCY = 0.82
local VIEWPORT_IMAGE_TRANSPARENCY = 0.62
local WORLD_BLUR_SIZE = 11

local FADE_IN = TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function cancelOverlayTween()
	if overlayTween then
		overlayTween:Cancel()
		overlayTween = nil
	end
	for _, t in overlayOutTweens do
		t:Cancel()
	end
	table.clear(overlayOutTweens)
end

local function cancelWorldBlurTween()
	if worldBlurTween then
		worldBlurTween:Cancel()
		worldBlurTween = nil
	end
end

local function cancelVisualTweens()
	cancelOverlayTween()
	cancelWorldBlurTween()
end

local function cleanupLegacyBackdropOnce()
	if legacyCleaned then
		return
	end
	legacyCleaned = true

	local uimod = Lighting:FindFirstChild("UIModalBlur")
	if uimod and uimod:IsA("BlurEffect") then
		uimod:Destroy()
	end
	local pg = player:FindFirstChild("PlayerGui") :: Instance?
	if not pg then
		return
	end
	local mainSg = pg:FindFirstChild("Main")
	if mainSg and mainSg:IsA("ScreenGui") then
		local dim = mainSg:FindFirstChild("UIModalDim", true)
		if dim then
			dim:Destroy()
		end
	end
end

local function getMainHudScreenGui(): ScreenGui?
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	local m = pg:FindFirstChild("Main")
	if m and m:IsA("ScreenGui") then
		return m :: ScreenGui
	end
	return nil
end

local function ensureWorldBlur(): BlurEffect
	local fx = Lighting:FindFirstChild(BLUR_EFFECT_NAME)
	if fx and fx:IsA("BlurEffect") then
		return fx :: BlurEffect
	end
	fx = Instance.new("BlurEffect")
	fx.Name = BLUR_EFFECT_NAME
	fx.Size = 0
	fx.Parent = Lighting
	return fx :: BlurEffect
end

local function tweenWorldBlur(targetSize: number, tweenInfo: TweenInfo, onComplete: (() -> ())?)
	cancelWorldBlurTween()
	local fx = ensureWorldBlur()
	if targetSize <= 0 and fx.Size <= 0 then
		if onComplete then
			onComplete()
		end
		return
	end
	worldBlurTween = TweenService:Create(fx, tweenInfo, { Size = targetSize })
	if onComplete then
		worldBlurTween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				onComplete()
			end
		end)
	end
	worldBlurTween:Play()
end

local function applyFullscreenLayout(gui: ScreenGui)
	local mainFrame = gui:FindFirstChild("Main")
	if mainFrame and mainFrame:IsA("Frame") then
		mainFrame.AutomaticSize = Enum.AutomaticSize.None
		mainFrame.Size = UDim2.fromScale(1, 1)
		mainFrame.Position = UDim2.fromScale(0, 0)
		mainFrame.AnchorPoint = Vector2.zero
	end

	local blurMod = mainFrame and mainFrame:FindFirstChild("BlurModule")
	if blurMod and blurMod:IsA("GuiObject") then
		local g = blurMod :: GuiObject
		g.AutomaticSize = Enum.AutomaticSize.None
		g.Size = UDim2.fromScale(1, 1)
		g.Position = UDim2.fromScale(0, 0)
		g.AnchorPoint = Vector2.zero
	end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then
			(d :: ViewportFrame).Size = UDim2.fromScale(1, 1)
			d.Position = UDim2.fromScale(0, 0)
			d.AnchorPoint = Vector2.zero
		end
	end
end

local function ensureOverlayGradient(mainFrame: Frame): UIGradient
	local grad = mainFrame:FindFirstChild(GRADIENT_NAME)
	if grad and grad:IsA("UIGradient") then
		return grad :: UIGradient
	end
	grad = Instance.new("UIGradient")
	grad.Name = GRADIENT_NAME
	grad.Rotation = 115
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 44, 68)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(14, 20, 32)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 34, 52)),
	})
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(0.45, 0.28),
		NumberSequenceKeypoint.new(1, 0.16),
	})
	grad.Parent = mainFrame
	return grad :: UIGradient
end

local function applyOverlayStyle(gui: ScreenGui, mainTransparency: number)
	local mainFrame = gui:FindFirstChild("Main")
	if mainFrame and mainFrame:IsA("Frame") then
		local frame = mainFrame :: Frame
		frame.BackgroundColor3 = OVERLAY_COLOR
		frame.BackgroundTransparency = mainTransparency
		frame.BorderSizePixel = 0
		frame.Active = false
		ensureOverlayGradient(frame)
	end

	local blurMod = mainFrame and mainFrame:FindFirstChild("BlurModule")
	if blurMod and blurMod:IsA("GuiObject") then
		local g = blurMod :: GuiObject
		g.BackgroundColor3 = OVERLAY_COLOR
		g.BackgroundTransparency = OVERLAY_BLUR_MODULE_TRANSPARENCY
		g.Active = false
	end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then
			local vf = d :: ViewportFrame
			vf.ImageTransparency = VIEWPORT_IMAGE_TRANSPARENCY
			vf.Active = false
		elseif d:IsA("GuiObject") and d.Name ~= "Main" and d.Name ~= "BlurModule" then
			(d :: GuiObject).Active = false
		end
	end
end

local function configureBlurPlacement(gui: ScreenGui)
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local mainHud = getMainHudScreenGui()
	local baseOrder = if mainHud then mainHud.DisplayOrder else 0
	gui.DisplayOrder = math.min(baseOrder - 5, -1)
end

local function attachEnabledGuard(gui: ScreenGui)
	if enabledGuardAttached == gui then
		return
	end
	enabledGuardAttached = gui
	gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if refCount <= 0 and not backdropAnimating and gui.Enabled then
			gui.Enabled = false
		end
	end)
end

local function suspendBlurScripts(gui: ScreenGui, suspend: boolean)
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("LocalScript") then
			(d :: LocalScript).Disabled = suspend
		end
	end
end

local function wireSuspendDynamicScripts(gui: ScreenGui)
	if suspendDescendantConn then
		suspendDescendantConn:Disconnect()
		suspendDescendantConn = nil
	end
	suspendDescendantConn = gui.DescendantAdded:Connect(function(ch)
		if refCount <= 0 and ch:IsA("LocalScript") then
			(ch :: LocalScript).Disabled = true
		end
	end)
end

local function lightningCleanupModalDepthOfField()
	for _, ch in ipairs(Lighting:GetChildren()) do
		if ch:IsA("DepthOfFieldEffect") and ch:GetAttribute(KEEP_DEPTH_ATTR) ~= true then
			ch:Destroy()
		end
	end
end

local function prepareBackdropForFadeOut(gui: ScreenGui)
	suspendBlurScripts(gui, true)
	gui.Enabled = true
	local mainFrame = gui:FindFirstChild("Main")
	if mainFrame and mainFrame:IsA("GuiObject") then
		(mainFrame :: GuiObject).Visible = true
	end
end

local function tweenOverlayOut(gui: ScreenGui, onComplete: (() -> ())?)
	local mainFrame = gui:FindFirstChild("Main")
	if not (mainFrame and mainFrame:IsA("Frame")) then
		if onComplete then
			onComplete()
		end
		return
	end

	local tweens: { Tween } = {}
	local function trackTween(t: Tween)
		table.insert(tweens, t)
		table.insert(overlayOutTweens, t)
		t:Play()
	end

	trackTween(TweenService:Create(mainFrame :: Frame, FADE_OUT, { BackgroundTransparency = 1 }))

	local blurMod = mainFrame:FindFirstChild("BlurModule")
	if blurMod and blurMod:IsA("GuiObject") then
		trackTween(TweenService:Create(blurMod :: GuiObject, FADE_OUT, { BackgroundTransparency = 1 }))
	end

	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then
			trackTween(TweenService:Create(d :: ViewportFrame, FADE_OUT, { ImageTransparency = 1 }))
		end
	end

	if #tweens == 0 then
		if onComplete then
			onComplete()
		end
		return
	end

	local completed = 0
	for _, t in tweens do
		t.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				completed += 1
				if completed >= #tweens then
					table.clear(overlayOutTweens)
					if onComplete then
						onComplete()
					end
				end
			end
		end)
	end
end

local function setBackdropInactiveHard(gui: ScreenGui?)
	if heartbeatSuspendConn then
		heartbeatSuspendConn:Disconnect()
		heartbeatSuspendConn = nil
	end
	if not gui then
		return
	end
	local function slamOff()
		gui.Enabled = false
		local mainFrame = gui:FindFirstChild("Main")
		if mainFrame and mainFrame:IsA("GuiObject") then
			(mainFrame :: GuiObject).Visible = false
		end
	end
	if refCount > 0 then
		suspendBlurScripts(gui, false)
		gui.Enabled = true
		local mainFrame = gui:FindFirstChild("Main")
		if mainFrame and mainFrame:IsA("GuiObject") then
			(mainFrame :: GuiObject).Visible = true
		end
		return
	end
	suspendBlurScripts(gui, true)
	slamOff()
	lightningCleanupModalDepthOfField()
	local fx = Lighting:FindFirstChild(BLUR_EFFECT_NAME)
	if fx and fx:IsA("BlurEffect") then
		(fx :: BlurEffect).Size = 0
	end
	-- Some StarterGui blur snippets re-enable ScreenGui / Main every frame; clamp while idle (throttled).
	local idleClampAccum = 0
	heartbeatSuspendConn = RunService.Heartbeat:Connect(function(dt)
		if refCount > 0 or not gui.Parent then
			return
		end
		idleClampAccum += dt
		if idleClampAccum < 0.35 then
			return
		end
		idleClampAccum = 0
		if gui.Enabled then
			gui.Enabled = false
		end
		local mf = gui:FindFirstChild("Main")
		if mf and mf:IsA("GuiObject") and (mf :: GuiObject).Visible then
			(mf :: GuiObject).Visible = false
		end
	end)
end

local function animateBackdrop(gui: ScreenGui, opening: boolean, onComplete: (() -> ())?)
	cancelVisualTweens()
	backdropAnimating = true

	local function finish()
		backdropAnimating = false
		if onComplete then
			onComplete()
		end
	end

	local mainFrame = gui:FindFirstChild("Main")
	if not (mainFrame and mainFrame:IsA("Frame")) then
		if opening then
			tweenWorldBlur(WORLD_BLUR_SIZE, FADE_IN, finish)
		else
			tweenWorldBlur(0, FADE_OUT, finish)
		end
		return
	end

	local frame = mainFrame :: Frame
	if opening then
		applyOverlayStyle(gui, 1)
		overlayTween = TweenService:Create(frame, FADE_IN, {
			BackgroundTransparency = OVERLAY_MAIN_TRANSPARENCY,
		})
		overlayTween:Play()
		tweenWorldBlur(WORLD_BLUR_SIZE, FADE_IN)
		overlayTween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed and refCount > 0 then
				finish()
			elseif state == Enum.PlaybackState.Completed then
				backdropAnimating = false
			end
		end)
	else
		local completed = 0
		local function maybeDone()
			completed += 1
			if completed >= 2 and refCount <= 0 then
				finish()
			end
		end
		tweenOverlayOut(gui, maybeDone)
		tweenWorldBlur(0, FADE_OUT, maybeDone)
	end
end

local function holdBackdropVisible(gui: ScreenGui)
	cancelVisualTweens()
	setBackdropInactiveHard(gui)
	applyOverlayStyle(gui, OVERLAY_MAIN_TRANSPARENCY)
	ensureWorldBlur().Size = WORLD_BLUR_SIZE
end

local function attachBlurGui(gui: ScreenGui)
	cleanupLegacyBackdropOnce()
	blurScreenGui = gui
	attachEnabledGuard(gui)
	wireSuspendDynamicScripts(gui)
	configureBlurPlacement(gui)
	applyFullscreenLayout(gui)
	applyOverlayStyle(gui, 1)
	setBackdropInactiveHard(gui)
end

local function ensureBlurGui(): ScreenGui?
	local pg = player:WaitForChild("PlayerGui")
	local b = pg:FindFirstChild("Blur")
	if not (b and b:IsA("ScreenGui")) then
		b = pg:WaitForChild("Blur", 30)
	end
	if not b or not b:IsA("ScreenGui") then
		warn('[UIModalBackdrop] PlayerGui.Blur not found — add ScreenGui named "Blur" under StarterGui.')
		return nil
	end
	local sg = b :: ScreenGui
	if blurScreenGui ~= sg then
		attachBlurGui(sg)
	else
		configureBlurPlacement(sg)
		applyFullscreenLayout(sg)
	end
	return blurScreenGui
end

local function syncVisual()
	local gui = ensureBlurGui()
	if not gui then
		return
	end
	configureBlurPlacement(gui)
	applyFullscreenLayout(gui)

	if refCount > 0 then
		if refCount == 1 then
			setBackdropInactiveHard(gui)
			animateBackdrop(gui, true, function()
				if blurScreenGui and blurScreenGui.Parent and refCount > 0 then
					applyOverlayStyle(blurScreenGui, OVERLAY_MAIN_TRANSPARENCY)
				end
			end)
			task.defer(function()
				task.defer(function()
					if blurScreenGui and blurScreenGui.Parent and refCount > 0 then
						configureBlurPlacement(blurScreenGui)
						applyFullscreenLayout(blurScreenGui)
						applyOverlayStyle(blurScreenGui, OVERLAY_MAIN_TRANSPARENCY)
					end
				end)
			end)
		else
			holdBackdropVisible(gui)
		end
	else
		prepareBackdropForFadeOut(gui)
		animateBackdrop(gui, false, function()
			if blurScreenGui and blurScreenGui.Parent and refCount <= 0 then
				setBackdropInactiveHard(blurScreenGui)
			end
		end)
	end
end

local UIModalBackdrop = {}

--[[	Call once at client boot (before other UI) so StarterGui.Blur does not flash enabled. ]]
function UIModalBackdrop.init()
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("Blur")
	if existing and existing:IsA("ScreenGui") then
		refCount = 0
		attachBlurGui(existing :: ScreenGui)
		lightningCleanupModalDepthOfField()
		ensureWorldBlur().Size = 0
		return
	end
	pg.ChildAdded:Connect(function(ch)
		if ch.Name == "Blur" and ch:IsA("ScreenGui") then
			refCount = 0
			attachBlurGui(ch :: ScreenGui)
			ensureWorldBlur().Size = 0
		end
	end)
end

function UIModalBackdrop.push()
	ensureBlurGui()
	refCount += 1
	syncVisual()
end

function UIModalBackdrop.pop()
	if refCount <= 0 then
		return
	end
	refCount -= 1
	syncVisual()
end

return UIModalBackdrop
