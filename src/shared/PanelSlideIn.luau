-- [ACTIVE] PanelSlideIn
--[[
	Open animations for HUD panels:
	• ScrollingFrame containers: scale/back pop only (scrollbar stays put, no L/R drag)
	• Other containers: clipped position slide + scale pop
	• Index TypeButtons: staggered scale+slide (layout-safe UIScale; optional offset via UIPadding skip)
	• Never moves the whole panel frame
]]

local TweenService = game:GetService("TweenService")

local M = {}

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TAB_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DEFAULT_STAGGER = 0.07
local DEFAULT_DISTANCE = 100

local designedRest: { [GuiObject]: UDim2 } = {}
local animGeneration = 0
local savedClip: { [GuiObject]: boolean } = {}

export type SlideFrom = "Left" | "Right" | "Up" | "Down"

export type SlideOpts = {
	from: SlideFrom?,
	stagger: number?,
	distance: number?,
	tweenInfo: TweenInfo?,
	scalePop: boolean?,
	startScale: number?,
	generation: number?,
	skipCancel: boolean?,
}

local function offsetPosition(rest: UDim2, from: SlideFrom, distance: number): UDim2
	if from == "Left" then
		return rest + UDim2.fromOffset(-distance, 0)
	elseif from == "Right" then
		return rest + UDim2.fromOffset(distance, 0)
	elseif from == "Up" then
		return rest + UDim2.fromOffset(0, -distance)
	end
	return rest + UDim2.fromOffset(0, distance)
end

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

local function rememberRest(gui: GuiObject): UDim2
	local rest = designedRest[gui]
	if rest then
		return rest
	end
	rest = gui.Position
	designedRest[gui] = rest
	return rest
end

local function enableClip(gui: GuiObject)
	local parent = gui.Parent
	if parent and parent:IsA("GuiObject") then
		if savedClip[parent] == nil then
			savedClip[parent] = parent.ClipsDescendants
		end
		parent.ClipsDescendants = true
	end
	if savedClip[gui] == nil then
		savedClip[gui] = gui.ClipsDescendants
	end
	gui.ClipsDescendants = true
end

function M.cancel()
	animGeneration += 1
	for gui, rest in designedRest do
		if gui.Parent then
			gui.Position = rest
			local scale = gui:FindFirstChild("PanelSlideScale")
			if scale and scale:IsA("UIScale") then
				scale.Scale = 1
			end
		end
	end
	for gui, was in savedClip do
		if gui.Parent then
			gui.ClipsDescendants = was
		end
	end
	table.clear(savedClip)
end

function M.slideGui(gui: GuiObject?, opts: SlideOpts?)
	if not gui or not gui.Parent then
		return
	end

	local options = opts or {}
	local from: SlideFrom = options.from or "Left"
	local distance = if typeof(options.distance) == "number" then options.distance else DEFAULT_DISTANCE
	local tweenInfo = options.tweenInfo or SLIDE_TWEEN
	local scalePop = options.scalePop ~= false
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.82
	local myGen = if typeof(options.generation) == "number" then options.generation else animGeneration

	enableClip(gui)

	-- ScrollingFrames must not Position-tween — that drags the scrollbar and can hide content off-panel.
	if gui:IsA("ScrollingFrame") then
		local scale = getOrAddScale(gui)
		scale.Scale = startScale
		task.defer(function()
			if myGen ~= animGeneration or not gui.Parent then
				scale.Scale = 1
				return
			end
			TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
		end)
		return
	end

	local rest = rememberRest(gui)
	gui.Position = offsetPosition(rest, from, distance)
	local scale: UIScale? = nil
	if scalePop then
		scale = getOrAddScale(gui)
		scale.Scale = startScale
	end

	task.defer(function()
		if myGen ~= animGeneration or not gui.Parent then
			gui.Position = rest
			if scale then
				scale.Scale = 1
			end
			return
		end
		TweenService:Create(gui, tweenInfo, { Position = rest }):Play()
		if scale and scale.Parent then
			TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
		end
	end)
end

-- Staggered TypeButtons: slide in from the left + Back scale (clips inside TypeButtons).
function M.slideInSequence(guis: { GuiObject }, opts: SlideOpts?)
	if #guis == 0 then
		return
	end

	local options = opts or {}
	local stagger = if typeof(options.stagger) == "number" then options.stagger else DEFAULT_STAGGER
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.05
	local distance = if typeof(options.distance) == "number" then options.distance else 56
	local tweenInfo = options.tweenInfo or TAB_TWEEN
	local from: SlideFrom = options.from or "Left"

	if not options.skipCancel then
		M.cancel()
	end

	local myGen = if typeof(options.generation) == "number" then options.generation else (animGeneration + 1)
	if typeof(options.generation) ~= "number" then
		animGeneration = myGen
	end

	local parent = guis[1].Parent
	if parent and parent:IsA("GuiObject") then
		enableClip(parent)
	end

	-- Capture layout rest positions with layout enabled, then free-move for the slide.
	local layout = if parent
		then (parent:FindFirstChildOfClass("UIListLayout") or parent:FindFirstChildOfClass("UIGridLayout"))
		else nil
	if layout then
		layout.Enabled = true
	end
	local rests: { [GuiObject]: UDim2 } = {}
	for _, gui in ipairs(guis) do
		if gui.Parent then
			rests[gui] = gui.Position
			designedRest[gui] = rests[gui]
		end
	end
	if layout then
		layout.Enabled = false
	end

	local pending = 0
	local function finishOne()
		pending -= 1
		if pending <= 0 and myGen == animGeneration then
			if layout and layout.Parent then
				layout.Enabled = true
			end
			for gui, rest in rests do
				if gui.Parent then
					gui.Position = rest
				end
			end
		end
	end

	for i, gui in ipairs(guis) do
		if not gui.Parent then
			continue
		end
		local rest = rests[gui] or gui.Position
		gui.Position = offsetPosition(rest, from, distance)
		local scale = getOrAddScale(gui)
		scale.Scale = startScale
		pending += 1
		task.delay((i - 1) * stagger, function()
			if myGen ~= animGeneration or not gui.Parent then
				finishOne()
				return
			end
			local move = TweenService:Create(gui, tweenInfo, { Position = rest })
			move:Play()
			TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
			local conn: RBXScriptConnection?
			conn = move.Completed:Connect(function()
				if conn then
					conn:Disconnect()
				end
				finishOne()
			end)
		end)
	end

	if pending == 0 and layout then
		layout.Enabled = true
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

local PANEL_CONTENT: {
	[string]: {
		containers: { string },
		staggerParent: string?,
		staggerNames: { string }?,
	},
} = {
	Shop = { containers = { "Container" } },
	Sell = { containers = { "Container" } },
	Store = { containers = { "StoreFrame" } },
	Daily = { containers = { "Container" } },
	Index = {
		containers = { "Container" },
		staggerParent = "TypeButtons",
		staggerNames = { "Normal", "Gold", "Diamond", "Lava", "Galaxy", "Rainbow" },
	},
	["Config/Settings"] = { containers = { "Container" } },
	Config = { containers = { "Container" } },
	Settings = { containers = { "Container" } },
}

function M.playForPanel(frame: Frame)
	local recipe = PANEL_CONTENT[frame.Name]
	if not recipe then
		return
	end

	M.cancel()
	animGeneration += 1
	local myGen = animGeneration

	if savedClip[frame] == nil then
		savedClip[frame] = frame.ClipsDescendants
	end
	frame.ClipsDescendants = true

	for _, name in recipe.containers do
		local host = frame:FindFirstChild(name)
		if not host then
			host = frame:FindFirstChild(name, true)
		end
		if host and host:IsA("GuiObject") then
			if name == "Container" and host.Parent and host.Parent.Name == "StoreFrame" and frame.Name == "Store" then
				continue
			end
			M.slideGui(host, {
				from = "Left",
				distance = 100,
				scalePop = true,
				startScale = 0.78,
				generation = myGen,
				tweenInfo = SLIDE_TWEEN,
			})
		end
	end

	if recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
		local tabs = M.collectNamedChildren(parent, recipe.staggerNames)
		if #tabs > 0 then
			-- TypeButtons sit beside the list — don't wait on container; start immediately.
			M.slideInSequence(tabs, {
				from = "Left",
				stagger = 0.08,
				distance = 64,
				startScale = 0.01,
				generation = myGen,
				skipCancel = true,
				tweenInfo = TAB_TWEEN,
			})
		end
	end
end

return M
