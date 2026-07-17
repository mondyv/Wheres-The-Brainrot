-- [ACTIVE] PanelSlideIn
--[[
	Open animations for HUD panels:
	• slideGui — Container / content host slides into its designed Position
	• slideInSequence — staggered TypeButtons (UIScale pop; layout stays enabled)
	• playForPanel — only nested containers (+ Index tabs), never the whole panel frame
]]

local TweenService = game:GetService("TweenService")

local M = {}

local DEFAULT_TWEEN = TweenInfo.new(0.48, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local DEFAULT_STAGGER = 0.07
local TAB_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DEFAULT_DISTANCE = 120

local designedRest: { [GuiObject]: UDim2 } = {}
local animGeneration = 0

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
end

function M.slideGui(gui: GuiObject?, opts: SlideOpts?)
	if not gui or not gui.Parent then
		return
	end

	local options = opts or {}
	local from: SlideFrom = options.from or "Left"
	local distance = if typeof(options.distance) == "number" then options.distance else DEFAULT_DISTANCE
	local tweenInfo = options.tweenInfo or DEFAULT_TWEEN
	local scalePop = options.scalePop == true
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.92
	local myGen = if typeof(options.generation) == "number" then options.generation else animGeneration

	local rest = rememberRest(gui)
	gui.Position = offsetPosition(rest, from, distance)
	local scale: UIScale? = nil
	if scalePop then
		scale = getOrAddScale(gui)
		scale.Scale = startScale
	else
		local existing = gui:FindFirstChild("PanelSlideScale")
		if existing and existing:IsA("UIScale") then
			existing.Scale = 1
		end
	end

	task.defer(function()
		if myGen ~= animGeneration or not gui.Parent then
			gui.Position = rest
			return
		end
		TweenService:Create(gui, tweenInfo, { Position = rest }):Play()
		if scale and scale.Parent then
			TweenService:Create(scale, tweenInfo, { Scale = 1 }):Play()
		end
	end)
end

-- Staggered pop-in via UIScale only — keeps UIListLayout/UIGridLayout positions intact.
function M.slideInSequence(guis: { GuiObject }, opts: SlideOpts?)
	if #guis == 0 then
		return
	end

	local options = opts or {}
	local stagger = if typeof(options.stagger) == "number" then options.stagger else DEFAULT_STAGGER
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.08
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

	-- Only nested containers — header / panel chrome stay put.
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
				distance = if frame.Name == "Index" then 140 else 110,
				scalePop = false,
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
					stagger = 0.075,
					startScale = 0.05,
					generation = myGen,
					skipCancel = true,
					tweenInfo = TAB_TWEEN,
				})
			end)
		end
	end
end

return M
