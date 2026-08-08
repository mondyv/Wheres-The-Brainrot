-- [ACTIVE] PanelSlideIn
--[[
	Open / close polish for HUD panels (no UIListLayout.Enabled — unsupported on some clients):
	• Panel shell: HUDController Back scale
	• Header / containers / footers: staggered UIScale pop-in
	• Index TypeButtons: staggered tab pop (layout untouched)
	• Close: content scales down slightly ahead of / with the shell
	• ScrollingFrames wrap in CanvasGroup so UIScale never unclips the canvas
]]

local TweenService = game:GetService("TweenService")

local M = {}

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TAB_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_CONTENT_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local DEFAULT_STAGGER = 0.048
local CLIP_ATTR = "_PanelScrollClip"
local WRAPPED_ATTR = "_PanelScrollWrapped"

local animGeneration = 0

export type SlideOpts = {
	stagger: number?,
	tweenInfo: TweenInfo?,
	startScale: number?,
	generation: number?,
	skipCancel: boolean?,
}

local function getOrAddScale(gui: GuiObject): UIScale
	local existing = gui:FindFirstChild("PanelSlideScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = "PanelSlideScale"
	scale.Scale = 1
	scale.Parent = gui
	return scale
end

function M.cancel()
	animGeneration += 1
end

-- UIScale on ScrollingFrame (or ancestors) unclips the full canvas. CanvasGroup
-- still clips its children when scaled — wrap once, animate the wrapper.
local function wrapScrollingFrame(scroll: ScrollingFrame)
	if scroll:GetAttribute(WRAPPED_ATTR) == true then
		return
	end
	local parent = scroll.Parent
	if not parent then
		return
	end
	if parent:IsA("CanvasGroup") and parent:GetAttribute(CLIP_ATTR) == true then
		scroll:SetAttribute(WRAPPED_ATTR, true)
		scroll.ClipsDescendants = true
		return
	end

	local clip = Instance.new("CanvasGroup")
	clip.Name = "_PanelScrollClip"
	clip:SetAttribute(CLIP_ATTR, true)
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.GroupTransparency = 0
	clip.ClipsDescendants = true
	clip.Size = scroll.Size
	clip.Position = scroll.Position
	clip.AnchorPoint = scroll.AnchorPoint
	clip.LayoutOrder = scroll.LayoutOrder
	clip.ZIndex = scroll.ZIndex
	clip.Visible = scroll.Visible
	clip.Parent = parent

	scroll.Size = UDim2.fromScale(1, 1)
	scroll.Position = UDim2.fromScale(0, 0)
	scroll.AnchorPoint = Vector2.new(0, 0)
	scroll.ClipsDescendants = true
	scroll.Parent = clip
	scroll:SetAttribute(WRAPPED_ATTR, true)
end

local function ensureScrollClips(frame: Frame)
	if frame:IsA("ScrollingFrame") then
		wrapScrollingFrame(frame)
	end
	for _, d in frame:GetDescendants() do
		if d:IsA("ScrollingFrame") then
			wrapScrollingFrame(d)
		end
	end
end

local function animRoot(gui: GuiObject): GuiObject
	if gui:IsA("ScrollingFrame") then
		local p = gui.Parent
		if p and p:IsA("CanvasGroup") and p:GetAttribute(CLIP_ATTR) == true then
			return p
		end
	end
	return gui
end

local function hostHasScrolling(host: GuiObject): boolean
	if host:IsA("ScrollingFrame") then
		return true
	end
	if host:IsA("CanvasGroup") and host:GetAttribute(CLIP_ATTR) == true then
		return true
	end
	return host:FindFirstChildWhichIsA("ScrollingFrame", true) ~= nil
end

function M.slideGui(gui: GuiObject?, opts: SlideOpts?)
	if not gui or not gui.Parent then
		return
	end
	local options = opts or {}
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.86
	local tweenInfo = options.tweenInfo or OPEN_TWEEN
	local myGen = if typeof(options.generation) == "number" then options.generation else animGeneration

	local target = animRoot(gui)
	local scale = getOrAddScale(target)
	scale.Scale = startScale
	task.defer(function()
		if myGen ~= animGeneration or not target.Parent then
			scale.Scale = 1
			return
		end
		TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
	end)
end

-- Staggered pop only — never mutates UIListLayout (Enabled is unsupported on some clients).
function M.slideInSequence(guis: { GuiObject }, opts: SlideOpts?)
	if #guis == 0 then
		return
	end

	local options = opts or {}
	local stagger = if typeof(options.stagger) == "number" then options.stagger else DEFAULT_STAGGER
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.7
	local tweenInfo = options.tweenInfo or TAB_TWEEN

	if not options.skipCancel then
		M.cancel()
	end

	local myGen = if typeof(options.generation) == "number" then options.generation else (animGeneration + 1)
	if typeof(options.generation) ~= "number" then
		animGeneration = myGen
	end

	for i, gui in ipairs(guis) do
		if not gui.Parent then
			continue
		end
		local target = animRoot(gui)
		local scale = getOrAddScale(target)
		scale.Scale = startScale
		task.delay((i - 1) * stagger, function()
			if myGen ~= animGeneration or not target.Parent then
				return
			end
			TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
		end)
	end
end

function M.collectNamedChildren(parent: Instance?, names: { string }): { GuiObject }
	local out: { GuiObject } = {}
	if not parent then
		return out
	end
	for _, name in names do
		local child = parent:FindFirstChild(name)
		if child and child:IsA("GuiObject") then
			table.insert(out, child)
		end
	end
	return out
end

local function collectDirectGuiChildren(parent: Instance?, skipNames: { [string]: boolean }?): { GuiObject }
	local out: { GuiObject } = {}
	if not parent then
		return out
	end
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			if skipNames and skipNames[child.Name] then
				continue
			end
			-- Skip layout / constraint helpers.
			if child:IsA("UIListLayout")
				or child:IsA("UIGridLayout")
				or child:IsA("UIPadding")
				or child:IsA("UICorner")
				or child:IsA("UIStroke")
				or child:IsA("UIGradient")
				or child:IsA("UIAspectRatioConstraint")
				or child:IsA("UISizeConstraint")
				or child:IsA("UIScale")
			then
				continue
			end
			-- Clip wrappers aren't content rows.
			if child:IsA("CanvasGroup") and child:GetAttribute(CLIP_ATTR) == true then
				continue
			end
			table.insert(out, child)
		end
	end
	return out
end

local PANEL_CONTENT: {
	[string]: {
		containers: { string },
		staggerParent: string?,
		staggerNames: { string }?,
		staggerDirectChildren: boolean?,
	},
} = {
	Shop = { containers = { "Header", "Container" } },
	Sell = { containers = { "Header", "Container", "NothingToSellText" } },
	SellInfo = { containers = { "Info", "Buttons", "Notice" } },
	Store = { containers = { "Header", "StoreFrame" } },
	Daily = { containers = { "Header", "Container" } },
	Upgrades = { containers = { "Header", "Container" } },
	Rebirth2 = { containers = { "Header", "Container", "Buttons" } },
	Gift = { containers = { "Header", "Container" } },
	Spinner = { containers = { "Header", "Container" } },
	Chances = { containers = { "Header", "Container" } },
	Index = {
		containers = { "Header", "Container" },
		staggerParent = "TypeButtons",
		staggerNames = { "Normal", "Gold", "Diamond", "Lava", "Galaxy", "Rainbow" },
	},
	["Config/Settings"] = { containers = { "Header", "Container" } },
	Config = { containers = { "Header", "Container" } },
	Settings = { containers = { "Header", "Container" } },
	OfflineEarnings2x = { containers = { "Header", "Container", "Buttons" } },
}

local function resolveHost(frame: Frame, name: string): GuiObject?
	local host = frame:FindFirstChild(name)
	if not host then
		host = frame:FindFirstChild(name, true)
	end
	-- Prefer the real scroll inside a clip wrapper named after the host.
	if host and host:IsA("CanvasGroup") and host:GetAttribute(CLIP_ATTR) == true then
		local scroll = host:FindFirstChildWhichIsA("ScrollingFrame")
		if scroll then
			return scroll
		end
	end
	if host and host:IsA("GuiObject") then
		return host
	end
	return nil
end

local function gatherOpenTargets(frame: Frame): { GuiObject }
	local recipe = PANEL_CONTENT[frame.Name]
	local targets: { GuiObject } = {}
	local seen: { [GuiObject]: boolean } = {}

	local function add(gui: GuiObject?)
		if not gui or seen[gui] then
			return
		end
		seen[gui] = true
		table.insert(targets, gui)
	end

	if recipe then
		for _, name in recipe.containers do
			local host = resolveHost(frame, name)
			if host then
				-- Avoid double-animating StoreFrame.Container when StoreFrame already pops.
				if name == "Container" and host.Parent and host.Parent.Name == "StoreFrame" and frame.Name == "Store" then
					continue
				end
				add(host)
			end
		end
	else
		-- Generic fallback: animate common panel chrome so unknown frames still feel good.
		for _, name in { "Header", "Container", "StoreFrame", "Buttons", "Info", "Notice" } do
			add(resolveHost(frame, name))
		end
	end

	return targets
end

-- Wrap scrolls + squash scales BEFORE the panel is Visible (no flash, full anims).
function M.prepareForPanel(frame: Frame)
	ensureScrollClips(frame)
	local targets = gatherOpenTargets(frame)
	for i, host in ipairs(targets) do
		local startScale = if i == 1 then 0.88 else 0.82
		getOrAddScale(animRoot(host)).Scale = startScale
	end
end

function M.playForPanel(frame: Frame)
	M.cancel()
	animGeneration += 1
	local myGen = animGeneration

	ensureScrollClips(frame)
	M.prepareForPanel(frame)

	local targets = gatherOpenTargets(frame)
	for i, host in ipairs(targets) do
		local delaySec = (i - 1) * 0.04
		local startScale = if i == 1 then 0.88 else 0.82
		task.delay(delaySec, function()
			if myGen ~= animGeneration or not host.Parent then
				return
			end
			M.slideGui(host, {
				startScale = startScale,
				generation = myGen,
				tweenInfo = OPEN_TWEEN,
			})
		end)
	end

	local recipe = PANEL_CONTENT[frame.Name]
	if recipe and recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
			or frame:FindFirstChild(recipe.staggerParent, true)
		local tabs = M.collectNamedChildren(parent, recipe.staggerNames)
		if #tabs > 0 then
			-- Pre-squash tabs so they don't flash at full size before stagger.
			for _, tab in tabs do
				getOrAddScale(tab).Scale = 0.72
			end
			M.slideInSequence(tabs, {
				stagger = 0.05,
				startScale = 0.72,
				generation = myGen,
				skipCancel = true,
			})
		end
	elseif recipe and recipe.staggerDirectChildren then
		local parent = resolveHost(frame, recipe.containers[1] or "Container")
		local kids = collectDirectGuiChildren(parent, { Header = true })
		if #kids > 0 then
			M.slideInSequence(kids, {
				stagger = 0.035,
				startScale = 0.78,
				generation = myGen,
				skipCancel = true,
			})
		end
	end

	-- Soft pop on a few direct children of Container (rows / cards).
	-- Skip scroll hosts — scaling grid rows still spills past the canvas.
	local container = resolveHost(frame, "Container") or resolveHost(frame, "StoreFrame")
	if container and frame.Name ~= "Index" and not hostHasScrolling(container) then
		local kids = collectDirectGuiChildren(container, {
			UIListLayout = true,
			UIPadding = true,
			ScrollBarAdjuster = true,
			TypeButtons = true,
		})
		local maxKids = math.min(#kids, 8)
		if maxKids >= 2 then
			local slice: { GuiObject } = {}
			for i = 1, maxKids do
				table.insert(slice, kids[i])
			end
			M.slideInSequence(slice, {
				stagger = 0.032,
				startScale = 0.86,
				generation = myGen,
				skipCancel = true,
				tweenInfo = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			})
		end
	end
end

function M.playCloseForPanel(frame: Frame)
	M.cancel()
	animGeneration += 1
	local myGen = animGeneration

	local targets = gatherOpenTargets(frame)
	for _, host in ipairs(targets) do
		if not host.Parent then
			continue
		end
		local scale = getOrAddScale(animRoot(host))
		TweenService:Create(scale, CLOSE_CONTENT_TWEEN, { Scale = 0.9 }):Play()
	end

	local recipe = PANEL_CONTENT[frame.Name]
	if recipe and recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
			or frame:FindFirstChild(recipe.staggerParent, true)
		for _, tab in M.collectNamedChildren(parent, recipe.staggerNames) do
			local scale = getOrAddScale(tab)
			TweenService:Create(scale, CLOSE_CONTENT_TWEEN, { Scale = 0.86 }):Play()
		end
	end

	task.delay(0.2, function()
		if myGen ~= animGeneration then
			return
		end
		for _, host in ipairs(targets) do
			local root = animRoot(host)
			local scale = root:FindFirstChild("PanelSlideScale")
			if scale and scale:IsA("UIScale") then
				scale.Scale = 1
			end
		end
	end)
end

return M
