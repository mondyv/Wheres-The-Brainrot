-- [ACTIVE] PanelSlideIn
--[[
	Open / close polish for HUD panels (no UIListLayout.Enabled — unsupported on some clients):
	• Panel shell: HUDController Back scale
	• Header / containers / footers: staggered UIScale pop-in
	• Index TypeButtons: staggered tab pop (layout untouched)
	• Close: content scales down slightly ahead of / with the shell
]]

local TweenService = game:GetService("TweenService")

local M = {}

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TAB_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_CONTENT_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local DEFAULT_STAGGER = 0.048

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

function M.slideGui(gui: GuiObject?, opts: SlideOpts?)
	if not gui or not gui.Parent then
		return
	end
	local options = opts or {}
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.86
	local tweenInfo = options.tweenInfo or OPEN_TWEEN
	local myGen = if typeof(options.generation) == "number" then options.generation else animGeneration

	local scale = getOrAddScale(gui)
	scale.Scale = startScale
	task.defer(function()
		if myGen ~= animGeneration or not gui.Parent then
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
		local scale = getOrAddScale(gui)
		scale.Scale = startScale
		task.delay((i - 1) * stagger, function()
			if myGen ~= animGeneration or not gui.Parent then
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

local function hostHasScrolling(host: GuiObject): boolean
	if host:IsA("ScrollingFrame") then
		return true
	end
	return host:FindFirstChildWhichIsA("ScrollingFrame", true) ~= nil
end

-- UIScale on a ScrollingFrame (or its ancestor) briefly unclips the full canvas —
-- that one-frame "see the whole list" flash. Prefer clip + delayed Visible instead.
local function prepareScrollSafe(host: GuiObject)
	host.ClipsDescendants = true
	if host:IsA("ScrollingFrame") then
		(host :: ScrollingFrame).ClipsDescendants = true
	end
	for _, d in host:GetDescendants() do
		if d:IsA("ScrollingFrame") then
			d.ClipsDescendants = true
		end
	end
end

-- Squash open targets BEFORE the panel is Visible so nothing flashes at full size.
function M.prepareForPanel(frame: Frame)
	local targets = gatherOpenTargets(frame)
	for i, host in ipairs(targets) do
		prepareScrollSafe(host)
		if hostHasScrolling(host) then
			-- Hide scroll hosts until their turn — never UIScale them.
			host.Visible = false
		else
			local startScale = if i == 1 then 0.88 else 0.82
			getOrAddScale(host).Scale = startScale
		end
	end

	local container = resolveHost(frame, "Container") or resolveHost(frame, "StoreFrame")
	if container then
		prepareScrollSafe(container)
	end
end

function M.playForPanel(frame: Frame)
	M.cancel()
	animGeneration += 1
	local myGen = animGeneration

	-- Ensure prepare ran even if caller forgot (idempotent).
	M.prepareForPanel(frame)

	local targets = gatherOpenTargets(frame)
	for i, host in ipairs(targets) do
		local delaySec = (i - 1) * 0.04
		local startScale = if i == 1 then 0.88 else 0.82
		if hostHasScrolling(host) then
			task.delay(delaySec, function()
				if myGen ~= animGeneration or not host.Parent then
					return
				end
				prepareScrollSafe(host)
				host.Visible = true
			end)
		else
			-- Scale already set in prepare — only tween after stagger.
			task.delay(delaySec, function()
				if myGen ~= animGeneration or not host.Parent then
					return
				end
				local scale = getOrAddScale(host)
				scale.Scale = startScale
				TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
			end)
		end
	end

	local recipe = PANEL_CONTENT[frame.Name]
	if recipe and recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
			or frame:FindFirstChild(recipe.staggerParent, true)
		local tabs = M.collectNamedChildren(parent, recipe.staggerNames)
		if #tabs > 0 then
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

	-- Soft pop on a few direct children of Container (rows / cards) for Index-like feel.
	-- Skip when the container scrolls — UIScale on list rows unclips the canvas.
	local container = resolveHost(frame, "Container") or resolveHost(frame, "StoreFrame")
	if container and frame.Name ~= "Index" and not hostHasScrolling(container) then
		local kids = collectDirectGuiChildren(container, {
			UIListLayout = true,
			UIPadding = true,
			ScrollBarAdjuster = true,
			TypeButtons = true,
		})
		-- Cap so huge scrolling lists don't stagger forever.
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
		if hostHasScrolling(host) then
			continue
		end
		local scale = getOrAddScale(host)
		TweenService:Create(scale, CLOSE_CONTENT_TWEEN, { Scale = 0.9 }):Play()
	end

	-- Also tuck Index tabs / visible container kids.
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
			local scale = host:FindFirstChild("PanelSlideScale")
			if scale and scale:IsA("UIScale") then
				scale.Scale = 1
			end
			-- Restore scroll hosts so the next open can prepare them again.
			if hostHasScrolling(host) and host.Parent then
				host.Visible = true
			end
		end
	end)
end

return M
