-- [ACTIVE] PlotOutlineController
--[[
	While the local player is in the shared safezone, their assigned plot gets a
	faint outline. It fades out as they walk toward the base floor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))

local player = Players.LocalPlayer

local POLL_INTERVAL = 0.12
-- Full faint outline beyond this XZ distance from plot floor center.
local FADE_START_DIST = 72
-- Fully invisible at/inside this distance (on the pad).
local FADE_END_DIST = 18
local OUTLINE_COLOR = Color3.fromRGB(170, 220, 255)
-- Farthest visible outline (still faint).
local OUTLINE_FAR_TRANSPARENCY = 0.48
-- SelectionBox line thickness (Highlight has no thickness API).
local BOX_LINE_THICKNESS = 0.055

local PlotOutlineController = {}

local highlight: Highlight? = nil
local selectionBox: SelectionBox? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local cachedFloorPart: BasePart? = nil
local wired = false

local function destroyOutline()
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if selectionBox then
		selectionBox:Destroy()
		selectionBox = nil
	end
end

local function resolveFloorAdornee(plot: Instance): BasePart?
	local story1 = PlotPaths.firstStoryFolder(plot)
	local floor = story1 and (story1:FindFirstChild("Floor") or story1:FindFirstChild("floor"))
	if floor and floor:IsA("BasePart") then
		return floor
	end
	if floor then
		local part = floor:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
	end
	return plot:FindFirstChildWhichIsA("BasePart", true)
end

local function ensureOutline(plot: Instance): (Highlight?, SelectionBox?)
	local floorPart = cachedFloorPart
	if not floorPart or not floorPart.Parent then
		floorPart = resolveFloorAdornee(plot)
		cachedFloorPart = floorPart
	end

	local hl = highlight
	if not hl or not hl.Parent or hl.Adornee ~= plot then
		if hl then
			hl:Destroy()
		end
		hl = Instance.new("Highlight")
		hl.Name = "PlotSafezoneOutline"
		hl.FillTransparency = 1
		hl.OutlineTransparency = 1
		hl.OutlineColor = OUTLINE_COLOR
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Enabled = false
		hl.Adornee = plot
		hl.Parent = Workspace.CurrentCamera or plot
		highlight = hl
	end

	local box = selectionBox
	if floorPart and (not box or not box.Parent or box.Adornee ~= floorPart) then
		if box then
			box:Destroy()
		end
		box = Instance.new("SelectionBox")
		box.Name = "PlotSafezoneOutlineBox"
		box.Color3 = OUTLINE_COLOR
		box.SurfaceColor3 = OUTLINE_COLOR
		box.SurfaceTransparency = 1
		box.LineThickness = BOX_LINE_THICKNESS
		box.Transparency = 1
		box.Visible = false
		box.Adornee = floorPart
		box.Parent = Workspace.CurrentCamera or plot
		selectionBox = box
	end

	return hl, box
end

local function resolvePlotCenter(plot: Instance): Vector3?
	local minV, maxV = PlotSpawnUtil.getPlotFloorBounds(plot)
	if minV and maxV then
		return Vector3.new((minV.X + maxV.X) * 0.5, (minV.Y + maxV.Y) * 0.5, (minV.Z + maxV.Z) * 0.5)
	end
	if plot:IsA("Model") then
		return (plot :: Model):GetPivot().Position
	end
	local part = plot:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function refreshCachedPlot()
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	cachedPlot = plot
	cachedCenter = if plot then resolvePlotCenter(plot) else nil
	cachedFloorPart = if plot then resolveFloorAdornee(plot) else nil
end

local function xzDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function outlineTransparencyForDistance(dist: number): number
	if dist <= FADE_END_DIST then
		return 1
	end
	if dist >= FADE_START_DIST then
		return OUTLINE_FAR_TRANSPARENCY
	end
	local t = (dist - FADE_END_DIST) / (FADE_START_DIST - FADE_END_DIST)
	return OUTLINE_FAR_TRANSPARENCY + (1 - OUTLINE_FAR_TRANSPARENCY) * (1 - t)
end

local function tickOutline()
	local character = player.Character
	if not character or not SafezoneUtil.isCharacterInSafezone(character) then
		if highlight then
			highlight.Enabled = false
			highlight.OutlineTransparency = 1
		end
		if selectionBox then
			selectionBox.Visible = false
			selectionBox.Transparency = 1
		end
		return
	end

	if not cachedPlot or not cachedPlot.Parent then
		refreshCachedPlot()
	end
	local plot = cachedPlot
	local center = cachedCenter
	if not plot or not center then
		destroyOutline()
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local dist = xzDist(hrp.Position, center)
	local transparency = outlineTransparencyForDistance(dist)
	local hl, box = ensureOutline(plot)
	local visible = transparency < 0.995
	if hl then
		hl.Enabled = visible
		hl.OutlineTransparency = transparency
	end
	if box then
		box.Visible = visible
		box.Transparency = transparency
		box.LineThickness = BOX_LINE_THICKNESS
	end
end

local function onHeartbeat(dt: number)
	accum += dt
	if accum < POLL_INTERVAL then
		return
	end
	accum = 0
	tickOutline()
end

function PlotOutlineController.init()
	if wired then
		return
	end
	wired = true

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
		SafezoneUtil.awaitCacheReady(8)
		refreshCachedPlot()
	end)

	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		refreshCachedPlot()
		tickOutline()
	end)

	player.CharacterAdded:Connect(function()
		task.defer(tickOutline)
	end)

	pollConn = RunService.Heartbeat:Connect(onHeartbeat)
end

return PlotOutlineController
