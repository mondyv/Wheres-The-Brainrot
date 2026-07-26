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
local OUTLINE_FAR_TRANSPARENCY = 0.62

local PlotOutlineController = {}

local highlight: Highlight? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local wired = false

local function destroyHighlight()
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
end

local function ensureHighlight(plot: Instance): Highlight?
	local hl = highlight
	if hl and hl.Parent and hl.Adornee == plot then
		return hl
	end
	destroyHighlight()
	hl = Instance.new("Highlight")
	hl.Name = "PlotSafezoneOutline"
	hl.FillTransparency = 1
	hl.OutlineTransparency = 1
	hl.OutlineColor = OUTLINE_COLOR
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Enabled = false
	hl.Adornee = plot
	hl.Parent = Workspace.CurrentCamera or plot
	highlight = hl
	return hl
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
		return
	end

	if not cachedPlot or not cachedPlot.Parent then
		refreshCachedPlot()
	end
	local plot = cachedPlot
	local center = cachedCenter
	if not plot or not center then
		destroyHighlight()
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local dist = xzDist(hrp.Position, center)
	local transparency = outlineTransparencyForDistance(dist)
	local hl = ensureHighlight(plot)
	if not hl then
		return
	end
	hl.Enabled = transparency < 0.995
	hl.OutlineTransparency = transparency
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
