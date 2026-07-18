-- [ACTIVE] PanelSlideIn
--[[
	Open polish for HUD panels (no UIListLayout.Enabled — not available on all clients):
	• Containers: scale pop only (ScrollingFrame-safe; scrollbar stays put)
	• Index TypeButtons: staggered UIScale pop (layout stays untouched)
	• HUDController still does the panel-level Back scale open
]]

local TweenService = game:GetService("TweenService")

local M = {}

local OPEN_TWEEN = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TAB_TWEEN = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DEFAULT_STAGGER = 0.055

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
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.88
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
	local startScale = if typeof(options.startScale) == "number" then options.startScale else 0.72
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
				startScale = 0.9,
				generation = myGen,
			})
		end
	end

	if recipe.staggerParent and recipe.staggerNames then
		local parent = frame:FindFirstChild(recipe.staggerParent)
		local tabs = M.collectNamedChildren(parent, recipe.staggerNames)
		if #tabs > 0 then
			M.slideInSequence(tabs, {
				stagger = 0.055,
				startScale = 0.78,
				generation = myGen,
				skipCancel = true,
			})
		end
	end
end

return M
