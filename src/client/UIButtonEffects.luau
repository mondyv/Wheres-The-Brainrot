-- [ACTIVE] UIButtonEffects
-- Shared UI polish: scale hover, in-bounds glisten (hover only), contained diagonal sweep (hover only).
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local GLINT_SEGMENT = 0.22
local GLINT_THICKNESS = 3
local SWEEP_WIDTH_PX = 10
local SWEEP_WIDTH_MAX_PX = 12
local SWEEP_INSET_PX = 10
local SWEEP_LENGTH_DIAG_RATIO = 0.4
local SWEEP_WIDTH_MIN_RATIO = 0.1
local SWEEP_FALLBACK_HEIGHT_SCALE = 0.36
local SWEEP_PATH_START = 0.24
local SWEEP_PATH_END = 0.76
local SWEEP_BG_TRANSPARENCY = 0.52
local SWEEP_GRADIENT_CENTER = 0.22
local SWEEP_FADE_OUT_SEC = 0.25
local EDGE_TWEEN = TweenInfo.new(0.11, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local DIAG_SWEEP_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local wiredClose: { [GuiButton]: boolean } = {}
local sweepMoveTweenByClip: { [Instance]: Tween } = {}
local sweepFadeTweenByClip: { [Instance]: Tween } = {}

local M = {}

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

-- Keep badges (NEW, Notif, etc.) able to stick past the button edge; only __SweepClip clips the shine.
local function ensureButtonUnclip(btn: GuiObject)
	btn.ClipsDescendants = false
end

local function getStrokeInset(btn: GuiObject): number
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		return math.max(2, math.ceil(stroke.Thickness * 0.55))
	end
	return 2
end

local function getSweepInset(btn: GuiObject): number
	return math.max(SWEEP_INSET_PX, getStrokeInset(btn) + 4)
end

local function resolveOutlineFrame(btn: GuiObject): GuiObject
	local decor = btn:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	if highlight and highlight:IsA("GuiObject") then
		return highlight :: GuiObject
	end
	return btn
end

-- Match glisten bounds: Decor.Highlight when present, else Icon, else the button root.
local function resolveSweepHost(btn: GuiObject): GuiObject
	local outline = resolveOutlineFrame(btn)
	if outline ~= btn then
		return outline
	end
	local icon = btn:FindFirstChild("Icon", true)
	if icon and icon:IsA("GuiObject") then
		return icon :: GuiObject
	end
	return btn
end

local function ensureOverlayFrame(parent: GuiObject, name: string, zBoost: number, insetPx: number?): Frame
	local inset = insetPx or 0
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Frame") then
		local f = existing :: Frame
		f.ClipsDescendants = true
		f.AnchorPoint = Vector2.new(0, 0)
		f.Position = UDim2.fromOffset(inset, inset)
		f.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
		f.ZIndex = (parent.ZIndex or 1) + zBoost
		f.Active = false
		return f
	end
	if existing then
		existing:Destroy()
	end

	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	f.AnchorPoint = Vector2.new(0, 0)
	f.Position = UDim2.fromOffset(inset, inset)
	f.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
	f.ZIndex = (parent.ZIndex or 1) + zBoost
	f.Active = false
	f.Parent = parent
	return f
end

local function ensureGlistenTrack(btn: GuiObject): Frame
	for _, host in btn:GetDescendants() do
		if host.Name == "__GlistenTrack" and host:IsA("Frame") and host.Parent ~= btn then
			host:Destroy()
		end
	end
	local stale = btn:FindFirstChild("__GlistenTrack")
	if stale then
		stale:Destroy()
	end
	local outline = resolveOutlineFrame(btn)
	if outline ~= btn then
		local stale = btn:FindFirstChild("__GlistenTrack")
		if stale then
			stale:Destroy()
		end
	end
	return ensureOverlayFrame(outline, "__GlistenTrack", 15, 0)
end

local function configureSweepBar(shine: Frame, clip: Frame)
	shine.AnchorPoint = Vector2.new(0.5, 0.5)
	shine.Rotation = 45
	shine.BackgroundTransparency = SWEEP_BG_TRANSPARENCY

	local w = clip.AbsoluteSize.X
	local h = clip.AbsoluteSize.Y
	if w >= 6 and h >= 6 then
		local minDim = math.min(w, h)
		local diagonal = math.sqrt(w * w + h * h)
		local barW = math.clamp(
			math.floor(minDim * SWEEP_WIDTH_MIN_RATIO + 0.5),
			5,
			SWEEP_WIDTH_MAX_PX
		)
		local barH = math.clamp(
			math.floor(diagonal * SWEEP_LENGTH_DIAG_RATIO + 0.5),
			math.floor(minDim * 0.45),
			math.floor(diagonal * 0.52)
		)
		shine.Size = UDim2.fromOffset(barW, barH)
	else
		shine.Size = UDim2.new(0, SWEEP_WIDTH_PX, SWEEP_FALLBACK_HEIGHT_SCALE, 0)
	end

	local grad = shine:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Parent = shine
	end
	grad.Rotation = 90
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.38, SWEEP_GRADIENT_CENTER),
		NumberSequenceKeypoint.new(0.62, SWEEP_GRADIENT_CENTER),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function whenSweepClipReady(clip: Frame, run: () -> ())
	local fired = false
	local sizeConn: RBXScriptConnection? = nil

	local function tryRun()
		if fired or not clip.Parent then
			return
		end
		if clip.AbsoluteSize.X >= 6 and clip.AbsoluteSize.Y >= 6 then
			fired = true
			if sizeConn then
				sizeConn:Disconnect()
				sizeConn = nil
			end
			run()
		end
	end

	tryRun()
	if fired then
		return
	end
	sizeConn = clip:GetPropertyChangedSignal("AbsoluteSize"):Connect(tryRun)
	task.defer(tryRun)
end

local function ensureSweepClip(host: GuiObject, btn: GuiObject): Frame
	local iconHost = host ~= btn
	if iconHost then
		host.ClipsDescendants = true
		local staleOnBtn = btn:FindFirstChild("__SweepClip")
		if staleOnBtn then
			staleOnBtn:Destroy()
		end
	end

	local existing = host:FindFirstChild("__SweepClip")
	if existing and existing:IsA("Frame") then
		local clip = existing :: Frame
		clip.BackgroundTransparency = 1
		clip.BorderSizePixel = 0
		clip.ClipsDescendants = true
		clip.Active = false
		if iconHost then
			clip.AnchorPoint = Vector2.new(0, 0)
			clip.Position = UDim2.fromScale(0, 0)
			clip.Size = UDim2.fromScale(1, 1)
			clip.ZIndex = (host.ZIndex or 1) + 1
		else
			local inset = getSweepInset(btn)
			clip.AnchorPoint = Vector2.new(0, 0)
			clip.Position = UDim2.fromOffset(inset, inset)
			clip.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
			local icon = btn:FindFirstChild("Icon", true)
			local baseZ = if icon and icon:IsA("GuiObject") then (icon :: GuiObject).ZIndex else (btn.ZIndex or 1)
			clip.ZIndex = math.max(1, baseZ - 1)
		end
		return clip
	end
	if existing then
		existing:Destroy()
	end

	local clip = Instance.new("Frame")
	clip.Name = "__SweepClip"
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.Active = false
	if iconHost then
		clip.AnchorPoint = Vector2.new(0, 0)
		clip.Position = UDim2.fromScale(0, 0)
		clip.Size = UDim2.fromScale(1, 1)
		clip.ZIndex = (host.ZIndex or 1) + 1
		clip.Parent = host
	else
		local inset = getSweepInset(btn)
		clip.AnchorPoint = Vector2.new(0, 0)
		clip.Position = UDim2.fromOffset(inset, inset)
		clip.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
		local icon = btn:FindFirstChild("Icon", true)
		local baseZ = if icon and icon:IsA("GuiObject") then (icon :: GuiObject).ZIndex else (btn.ZIndex or 1)
		clip.ZIndex = math.max(1, baseZ - 1)
		clip.Parent = host
	end
	return clip
end

-- MouseEnter does not fire on mobile; mirror hover with touch on the button.
local function bindPointerHover(btn: GuiButton, onEnter: () -> (), onLeave: () -> ())
	local hovering = false
	local touchDown = false

	local function enter()
		if hovering then
			return
		end
		hovering = true
		onEnter()
	end

	local function leave()
		if not hovering then
			return
		end
		hovering = false
		touchDown = false
		onLeave()
	end

	btn.MouseEnter:Connect(enter)
	btn.MouseLeave:Connect(leave)

	if UserInputService.TouchEnabled then
		btn.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.Touch then
				touchDown = true
				enter()
			end
		end)
		btn.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch and touchDown then
				leave()
			end
		end)
	end
end

local function hideGlistenOnHost(host: Instance)
	local gTrack = host:FindFirstChild("__GlistenTrack")
	if not gTrack then
		return
	end
	local glint = gTrack:FindFirstChild("Glint")
	if glint and glint:IsA("Frame") then
		glint.Visible = false
		glint:SetAttribute("__GlistenPlaying", nil)
	end
end

local function stopSweepOnClip(clip: Instance)
	local moveTw = sweepMoveTweenByClip[clip]
	if moveTw then
		moveTw:Cancel()
		sweepMoveTweenByClip[clip] = nil
	end
	local fadeTw = sweepFadeTweenByClip[clip]
	if fadeTw then
		fadeTw:Cancel()
		sweepFadeTweenByClip[clip] = nil
	end
	clip:SetAttribute("__DiagSweepPlaying", nil)
	local shine = clip:FindFirstChild("__DiagSweep")
	if shine and shine:IsA("Frame") then
		shine.Visible = false
		local clipFrame = clip :: Frame
		configureSweepBar(shine :: Frame, clipFrame)
	end
end

local function hideEffectLayers(btn: GuiObject)
	hideGlistenOnHost(resolveOutlineFrame(btn))
	hideGlistenOnHost(btn)

	for _, host in { resolveSweepHost(btn), btn } do
		local clip = host:FindFirstChild("__SweepClip")
		if clip then
			stopSweepOnClip(clip)
		end
	end
end

local function createGlintBar(): Frame
	local glint = Instance.new("Frame")
	glint.Name = "Glint"
	glint.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	glint.BackgroundTransparency = 0.12
	glint.BorderSizePixel = 0

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.05
	stroke.Parent = glint

	return glint
end

function M.hideHoverEffects(btn: GuiObject)
	hideEffectLayers(btn)
end

function M.playBorderGlisten(btn: GuiObject)
	local track = ensureGlistenTrack(btn)
	local glint = track:FindFirstChild("Glint") :: Frame?
	if not glint then
		glint = createGlintBar()
		glint.Parent = track
	end

	if glint:GetAttribute("__GlistenPlaying") then
		return
	end
	glint:SetAttribute("__GlistenPlaying", true)
	glint.Visible = true

	local seg = GLINT_SEGMENT
	local edgePad = 0.01

	-- Travel along outline: top → right → bottom → left
	local phases = {
		{
			size = UDim2.new(seg, 0, 0, GLINT_THICKNESS),
			anchor = Vector2.new(0, 0),
			from = UDim2.new(edgePad, 0, 0, 0),
			to = UDim2.new(1 - seg - edgePad, 0, 0, 0),
		},
		{
			size = UDim2.new(0, GLINT_THICKNESS, seg, 0),
			anchor = Vector2.new(1, 0),
			from = UDim2.new(1, 0, edgePad, 0),
			to = UDim2.new(1, 0, 1 - seg - edgePad, 0),
		},
		{
			size = UDim2.new(seg, 0, 0, GLINT_THICKNESS),
			anchor = Vector2.new(1, 1),
			from = UDim2.new(1 - edgePad, 0, 1, 0),
			to = UDim2.new(seg + edgePad, 0, 1, 0),
		},
		{
			size = UDim2.new(0, GLINT_THICKNESS, seg, 0),
			anchor = Vector2.new(0, 1),
			from = UDim2.new(0, 0, 1 - edgePad, 0),
			to = UDim2.new(0, 0, seg + edgePad, 0),
		},
	}

	local function runPhase(i: number)
		if not glint.Parent then
			glint:SetAttribute("__GlistenPlaying", nil)
			return
		end
		if i > #phases then
			glint.Visible = false
			glint:SetAttribute("__GlistenPlaying", nil)
			return
		end

		local p = phases[i]
		glint.Size = p.size
		glint.AnchorPoint = p.anchor
		glint.Position = p.from
		local tw = TweenService:Create(glint, EDGE_TWEEN, { Position = p.to })
		tw.Completed:Connect(function()
			runPhase(i + 1)
		end)
		tw:Play()
	end

	runPhase(1)
end

function M.playDiagonalSweep(btn: GuiObject)
	local legacyShimmer = btn:FindFirstChild("__Shimmer")
	if legacyShimmer then
		legacyShimmer:Destroy()
	end

	local host = resolveSweepHost(btn)
	local clip = ensureSweepClip(host, btn)
	stopSweepOnClip(clip)
	clip:SetAttribute("__DiagSweepPlaying", true)

	local shine = clip:FindFirstChild("__DiagSweep")
	if not shine or not shine:IsA("Frame") then
		if shine then
			shine:Destroy()
		end
		shine = Instance.new("Frame")
		shine.Name = "__DiagSweep"
		shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		shine.BorderSizePixel = 0
		shine.Visible = false
		shine.ZIndex = clip.ZIndex + 1
		shine.Parent = clip
	end

	whenSweepClipReady(clip, function()
		if clip:GetAttribute("__DiagSweepPlaying") ~= true or not shine.Parent then
			return
		end

		configureSweepBar(shine, clip)
		shine.BackgroundTransparency = SWEEP_BG_TRANSPARENCY
		shine.Visible = true
		shine.Position = UDim2.new(SWEEP_PATH_START, 0, SWEEP_PATH_START, 0)

		local move = TweenService:Create(shine, DIAG_SWEEP_TWEEN, {
			Position = UDim2.new(SWEEP_PATH_END, 0, SWEEP_PATH_END, 0),
		})
		sweepMoveTweenByClip[clip] = move
		move.Completed:Connect(function(state)
			if sweepMoveTweenByClip[clip] == move then
				sweepMoveTweenByClip[clip] = nil
			end
			if state ~= Enum.PlaybackState.Completed then
				return
			end
			if not shine.Parent or clip:GetAttribute("__DiagSweepPlaying") ~= true then
				stopSweepOnClip(clip)
				return
			end

			local fade = TweenService:Create(
				shine,
				TweenInfo.new(SWEEP_FADE_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 1 }
			)
			sweepFadeTweenByClip[clip] = fade
			fade.Completed:Connect(function(fadeState)
				if sweepFadeTweenByClip[clip] == fade then
					sweepFadeTweenByClip[clip] = nil
				end
				if fadeState ~= Enum.PlaybackState.Completed then
					return
				end
				stopSweepOnClip(clip)
			end)
			fade:Play()
		end)
		move:Play()
	end)
end

local function playHoverPolish(btn: GuiButton, withSweep: boolean)
	M.playBorderGlisten(btn)
	if withSweep then
		M.playDiagonalSweep(btn)
	end
end

-- Scale hover/press only.
function M.wireScaleButtonAnim(btn: GuiButton, onActivated: () -> ())
	local scale = getOrAddUIScale(btn)
	local hovering = false

	local function tweenScale(target: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	bindPointerHover(
		btn,
		function()
			hovering = true
			UIInteractionSounds.playHover()
			tweenScale(1.08, HOVER_TWEEN)
		end,
		function()
			hovering = false
			tweenScale(1, HOVER_TWEEN)
		end
	)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		tweenScale(0.9, CLICK_TWEEN)
		-- Fire on Down: UIScale shrink cancels Activated/Click if we wait for release.
		onActivated()
	end)
	btn.MouseButton1Up:Connect(function()
		tweenScale(if hovering then 1.08 else 1, RELEASE_TWEEN)
	end)
end

-- Sidebar buttons: tilt + scale; glisten + sweep only while hovered.
function M.wireTiltHoverButton(
	btn: GuiButton,
	onActivated: () -> (),
	scaleRoot: GuiObject,
	tiltTarget: GuiObject,
	withPolish: boolean?
)
	ensureButtonUnclip(btn)
	local scale = getOrAddUIScale(scaleRoot)
	local hovering = false
	local lastFire = 0

	local TILT_HOVER = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local TILT_LEAVE = TweenInfo.new(0.22, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	local TILT_CLICK = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local HOVER_SCALE = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function fireActivated()
		local now = os.clock()
		if now - lastFire < 0.08 then
			return
		end
		lastFire = now
		onActivated()
	end

	bindPointerHover(
		btn,
		function()
			hovering = true
			UIInteractionSounds.playHover()
			TweenService:Create(scale, HOVER_SCALE, { Scale = 1.1 }):Play()
			TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -10 }):Play()
			if withPolish then
				playHoverPolish(btn, true)
			end
		end,
		function()
			hovering = false
			-- Leave scale/tilt alone for effects: glisten + sweep finish full travel even on tap.
			TweenService:Create(scale, HOVER_SCALE, { Scale = 1 }):Play()
			TweenService:Create(tiltTarget, TILT_LEAVE, { Rotation = 0 }):Play()
		end
	)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, TILT_CLICK, { Scale = 0.94 }):Play()
		TweenService:Create(tiltTarget, TILT_CLICK, { Rotation = 6 }):Play()
		fireActivated()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_SCALE, { Scale = if hovering then 1.1 else 1 }):Play()
		if hovering then
			TweenService:Create(tiltTarget, TILT_HOVER, { Rotation = -10 }):Play()
		else
			TweenService:Create(tiltTarget, TILT_LEAVE, { Rotation = 0 }):Play()
		end
	end)
end

function M.wireSidebarButton(btn: GuiButton, onActivated: () -> ())
	local icon = btn:FindFirstChild("Icon", true)
	local tiltTarget: GuiObject = if icon and icon:IsA("GuiObject") then icon else btn
	M.wireTiltHoverButton(btn, onActivated, btn, tiltTarget, true)
end

-- Accent / Robux buttons: scale + hover-only polish.
function M.wireAccentButton(btn: GuiButton, onActivated: () -> ())
	ensureButtonUnclip(btn)
	local scale = getOrAddUIScale(btn)
	local hovering = false
	local lastFire = 0

	bindPointerHover(
		btn,
		function()
			hovering = true
			UIInteractionSounds.playHover()
			TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.08 }):Play()
			playHoverPolish(btn, true)
		end,
		function()
			hovering = false
			-- Let glisten/sweep finish the full path after a quick mobile tap.
			TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		end
	)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.92 }):Play()
		local now = os.clock()
		if now - lastFire >= 0.08 then
			lastFire = now
			onActivated()
		end
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, if hovering then HOVER_TWEEN else RELEASE_TWEEN, { Scale = if hovering then 1.08 else 1 }):Play()
	end)
end

-- Close (X): scale + thin in-bounds glisten on hover only (no sweep — keeps X readable).
function M.wireGlistenCloseButton(btn: GuiButton, onActivated: () -> ())
	if wiredClose[btn] then
		return
	end
	wiredClose[btn] = true
	UiFonts.applyButtonTree(btn)

	local scale = getOrAddUIScale(btn)
	local hovering = false
	local lastFire = 0

	bindPointerHover(
		btn,
		function()
			hovering = true
			UIInteractionSounds.playHover()
			TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.08 }):Play()
			M.playBorderGlisten(btn)
		end,
		function()
			hovering = false
			-- Finish the full outline lap even if hover was only a moment.
			TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		end
	)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.9 }):Play()
		local now = os.clock()
		if now - lastFire >= 0.08 then
			lastFire = now
			onActivated()
		end
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, if hovering then HOVER_TWEEN else RELEASE_TWEEN, { Scale = if hovering then 1.08 else 1 }):Play()
	end)
end

local function findFrameCloseButton(frame: Instance): GuiButton?
	-- Strict path only — recursive Close/X search was wiring huge controls that ate panel clicks.
	local header = frame:FindFirstChild("Header")
	local buttons = header and header:FindFirstChild("Buttons")
	local close = buttons and buttons:FindFirstChild("Close")
	if close and close:IsA("GuiButton") then
		return close
	end
	if close and not close:IsA("GuiButton") then
		local nested = close:FindFirstChildOfClass("ImageButton") or close:FindFirstChildOfClass("TextButton")
		if nested then
			return nested
		end
	end
	return nil
end

function M.wireAllFrameCloseButtons(framesFolder: Instance, onClose: (Frame) -> ())
	for _, child in framesFolder:GetChildren() do
		if not child:IsA("Frame") then
			continue
		end
		local frame = child :: Frame
		local closeBtn = findFrameCloseButton(frame)
		if closeBtn then
			M.wireGlistenCloseButton(closeBtn, function()
				onClose(frame)
			end)
		end
	end

	local spinner = framesFolder:FindFirstChild("Spinner")
	if spinner then
		local closeFolder = spinner:FindFirstChild("Close")
		local closeBtn = closeFolder and closeFolder:FindFirstChild("Close")
		if closeBtn and closeBtn:IsA("GuiButton") then
			M.wireGlistenCloseButton(closeBtn, function()
				onClose(spinner :: Frame)
			end)
		end
	end
end

return M
