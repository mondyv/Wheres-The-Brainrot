-- [ACTIVE] PanelSlideIn
--[[
	Staggered slide-in for panel children (shop rows, sell rows, index tabs).
	Temporarily disables UIListLayout/UIGridLayout so Position tweens can run.
]]

local TweenService = game:GetService("TweenService")

local M = {}

local DEFAULT_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local DEFAULT_STAGGER = 0.055
local DEFAULT_DISTANCE = 56

local restPositions: { [GuiObject]: UDim2 } = {}
local animGeneration = 0
local activeLayout: (UIListLayout | UIGridLayout)? = nil
local activeLayoutWasEnabled = true

export type SlideFrom = "Left" | "Right" | "Up" | "Down"

export type SlideOpts = {
	from: SlideFrom?,
	stagger: number?,
	distance: number?,
	tweenInfo: TweenInfo?,
	scalePop: boolean?,
}

local function ensureRest(gui: GuiObject): UDim2
	local cached = restPositions[gui]
	if cached then
		return cached
	end
	restPositions[gui] = gui.Position
	return gui.Position
end

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
	local list = parent:FindFirstChildOfClass("UIListLayout")
	if list then
		return list
	end
	local grid = parent:FindFirstChildOfClass("UIGridLayout")
	if grid then
		return grid
	end
	return nil
end

function M.cancel()
	animGeneration += 1
	if activeLayout and activeLayout.Parent then
		activeLayout.Enabled = activeLayoutWasEnabled
	end
	activeLayout = nil
end

function M.snapToRest(guis: { GuiObject })
	M.cancel()
	for _, gui in guis do
		local rest = restPositions[gui]
		if rest and gui.Parent then
			gui.Position = rest
		end
		local scale = gui:FindFirstChild("PanelSlideScale")
		if scale and scale:IsA("UIScale") then
			scale.Scale = 1
		end
	end
end

function M.rememberRest(gui: GuiObject)
	restPositions[gui] = gui.Position
end

function M.slideInSequence(guis: { GuiObject }, opts: SlideOpts?)
	if #guis == 0 then
		return
	end

	local options = opts or {}
	local from: SlideFrom = options.from or "Left"
	local stagger = if typeof(options.stagger) == "number" then options.stagger else DEFAULT_STAGGER
	local distance = if typeof(options.distance) == "number" then options.distance else DEFAULT_DISTANCE
	local tweenInfo = options.tweenInfo or DEFAULT_TWEEN
	local scalePop = options.scalePop ~= false

	M.cancel()
	animGeneration += 1
	local myGen = animGeneration

	-- Capture layout-assigned rest poses first.
	for _, gui in ipairs(guis) do
		if gui.Parent then
			restPositions[gui] = gui.Position
		end
	end

	local parent = guis[1].Parent
	local layout = findLayout(parent)
	if layout then
		activeLayout = layout
		activeLayoutWasEnabled = layout.Enabled
		layout.Enabled = false
	else
		activeLayout = nil
	end

	local pending = 0
	local function finishOne()
		pending -= 1
		if pending <= 0 then
			if activeLayout and activeLayout.Parent and myGen == animGeneration then
				activeLayout.Enabled = activeLayoutWasEnabled
				activeLayout = nil
			end
		end
	end

	for i, gui in ipairs(guis) do
		if not gui.Parent then
			continue
		end
		local rest = ensureRest(gui)
		gui.Position = offsetPosition(rest, from, distance)
		local scale: UIScale? = nil
		if scalePop then
			scale = getOrAddScale(gui)
			scale.Scale = 0.92
		end

		pending += 1
		local delaySec = (i - 1) * stagger
		task.delay(delaySec, function()
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
					conn = nil
				end
				finishOne()
			end)
		end)
	end

	if pending == 0 then
		if activeLayout and activeLayout.Parent then
			activeLayout.Enabled = activeLayoutWasEnabled
			activeLayout = nil
		end
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

function M.collectVisibleGuiChildren(parent: Instance?, skipNames: { [string]: boolean }?): { GuiObject }
	local out: { GuiObject } = {}
	if not parent then
		return out
	end
	local kids = parent:GetChildren()
	table.sort(kids, function(a, b)
		local ao = if a:IsA("GuiObject") then a.LayoutOrder else 0
		local bo = if b:IsA("GuiObject") then b.LayoutOrder else 0
		if ao ~= bo then
			return ao < bo
		end
		return a.Name < b.Name
	end)
	for _, child in kids do
		if skipNames and skipNames[child.Name] then
			continue
		end
		if child:IsA("GuiObject") and child.Visible then
			table.insert(out, child)
		end
	end
	return out
end

return M
