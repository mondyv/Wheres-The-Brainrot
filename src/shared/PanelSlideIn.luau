-- [ACTIVE] PanelSlideIn
--[[
	Open animations for HUD panels:
	• slideGui — whole Container / content host from the left
	• slideInSequence — staggered children (Index TypeButtons), layout-safe
	• playForPanel — recipe for Shop / Sell / Store / Daily / Index / Config
]]

local TweenService = game:GetService("TweenService")

local M = {}

local DEFAULT_TWEEN = TweenInfo.new(0.48, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local DEFAULT_STAGGER = 0.065
local DEFAULT_DISTANCE = 110

local restPositions: { [GuiObject]: UDim2 } = {}
local animGeneration = 0
local activeLayout: (UIListLayout | UIGridLayout)? = nil

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

local function findLayout(parent: Instance?): UIListLayout | UIGridLayout | nil
	if not parent then
		return nil
	end
	return parent:FindFirstChildOfClass("UIListLayout") or parent:FindFirstChildOfClass("UIGridLayout")
end

local function restoreActiveLayout()
	if activeLayout and activeLayout.Parent then
		activeLayout.Enabled = true
		for _, ch in activeLayout.Parent:GetChildren() do
			if ch:IsA("GuiObject") then
				restPositions[ch] = nil
				local scale = ch:FindFirstChild("PanelSlideScale")
				if scale and scale:IsA("UIScale") then
					scale.Scale = 1
				end
			end
		end
	end
	activeLayout = nil
end

function M.cancel()
	animGeneration += 1
	restoreActiveLayout()
	for gui, rest in restPositions do
		if gui.Parent then
			gui.Position = rest
			local scale = gui:FindFirstChild("PanelSlideScale")
			if scale and scale:IsA("UIScale") then
				scale.Scale = 1
			end
		end
	end
end

function M.slideGui(gui: GuiObject?, opts: SlideOpts?)
	if not gui or not gui.Parent then
		return
	end

	local options = opts or {}
	local from: SlideFrom = options.from or "Left"
	local distance = if typeof(options.distance) == "number" then options.distance else DEFAULT_DISTANCE
	local tweenInfo = options.tweenInfo or DEFAULT_TWEEN
	local scalePop = options.scalePop ~= false
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.72
	local myGen = if typeof(options.generation) == "number" then options.generation else animGeneration

	restPositions[gui] = nil
	local rest = gui.Position
	restPositions[gui] = rest

	gui.Position = offsetPosition(rest, from, distance)
	local scale: UIScale? = nil
	if scalePop then
		scale = getOrAddScale(gui)
		scale.Scale = startScale
	end

	task.defer(function()
		if myGen ~= animGeneration or not gui.Parent then
			if restPositions[gui] then
				gui.Position = restPositions[gui]
			end
			return
		end
		TweenService:Create(gui, tweenInfo, { Position = rest }):Play()
		if scale and scale.Parent then
			TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
		end
	end)
end

function M.slideInSequence(guis: { GuiObject }, opts: SlideOpts?)
	if #guis == 0 then
		return
	end

	local options = opts or {}
	local from: SlideFrom = options.from or "Left"
	local stagger = if typeof(options.stagger) == "number" then options.stagger else DEFAULT_STAGGER
	local distance = if typeof(options.distance) == "number" then options.distance else 64
	local tweenInfo = options.tweenInfo or DEFAULT_TWEEN
	local scalePop = options.scalePop ~= false
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.35

	if not options.skipCancel then
		M.cancel()
	end

	local myGen = if typeof(options.generation) == "number" then options.generation else (animGeneration + 1)
	if typeof(options.generation) ~= "number" then
		animGeneration = myGen
	end

	local parent = guis[1].Parent
	local layout = findLayout(parent)
	if layout then
		layout.Enabled = true
	end
	for _, gui in ipairs(guis) do
		if gui.Parent then
			restPositions[gui] = gui.Position
		end
	end

	if layout then
		activeLayout = layout
		layout.Enabled = false
	end

	local pending = 0
	local function finishOne()
		pending -= 1
		if pending <= 0 and myGen == animGeneration then
			restoreActiveLayout()
		end
	end

	for i, gui in ipairs(guis) do
		if not gui.Parent then
			continue
		end
		local rest = restPositions[gui] or gui.Position
		gui.Position = offsetPosition(rest, from, distance)
		local scale: UIScale? = nil
		if scalePop then
			scale = getOrAddScale(gui)
			scale.Scale = startScale
		end

		pending += 1
		task.delay((i - 1) * stagger, function()
			if myGen ~= animGeneration or not gui.Parent then
				finishOne()
				return
			end
			local move = TweenService:Create(gui, tweenInfo, { Position = rest })
			move:Play()
			if scale and scale.Parent then
				TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
			end
			local conn: RBXScriptConnection?
			conn = move.Completed:Connect(function()
				if conn then
					conn:Disconnect()
				end
				finishOne()
			end)
		end)
	end

	if pending == 0 then
		restoreActiveLayout()
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

local PANEL_CONTENT: { [string]: { containers: { string }, staggerParent: string?, staggerNames: { string }? } } = {
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

	for _, name in recipe.containers do
		local host = frame:FindFirstChild(name)
		if not host then
			host = frame:FindFirstChild(name, true)
		end
		if host and host:IsA("GuiObject") then
			-- Don't slide a nested Container if we already slide StoreFrame as parent.
			if name == "Container" and host.Parent and host.Parent.Name == "StoreFrame" and frame.Name == "Store" then
				continue
			end
			M.slideGui(host, {
				from = "Left",
				distance = if frame.Name == "Index" then 140 else 100,
				scalePop = true,
				startScale = if frame.Name == "Index" then 0.45 else 0.72,
				generation = myGen,
			})
		end
	end

	if recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
		local tabs = M.collectNamedChildren(parent, recipe.staggerNames)
		if #tabs > 0 then
			task.defer(function()
				if myGen ~= animGeneration or not frame.Parent or not frame.Visible then
					return
				end
				M.slideInSequence(tabs, {
					from = "Left",
					stagger = 0.07,
					distance = 72,
					scalePop = true,
					startScale = 0.2,
					generation = myGen,
					skipCancel = true,
				})
			end)
		end
	end
end

return M
