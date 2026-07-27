-- [ACTIVE] PlotOutlineController
--[[
	While the local player is in the shared safezone, THEIR owned plot gets a
	faint outline around the full floor pad. It fades out as they walk toward it.
	Never outlines other players' plots.
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
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
-- Farthest visible outline (still a bit transparent).
local OUTLINE_FAR_TRANSPARENCY = 0.42
-- SelectionBox line thickness (Highlight has no thickness API).
local BOX_LINE_THICKNESS = 0.16

local PlotOutlineController = {}

local selectionBox: SelectionBox? = nil
local outlineProxy: BasePart? = nil
local pollConn: RBXScriptConnection? = nil
local accum = 0
local cachedPlot: Instance? = nil
local cachedCenter: Vector3? = nil
local wired = false

local function destroyOutline()
	if selectionBox then
		selectionBox:Destroy()
		selectionBox = nil
	end
	if outlineProxy then
		outlineProxy:Destroy()
		outlineProxy = nil
	end
end

local function isOwnedByLocalPlayer(plot: Instance): boolean
	local uid = plot:GetAttribute("PlotOwnerUserId")
	return typeof(uid) == "number" and uid == player.UserId
end

-- Invisible part matching the full floor AABB so SelectionBox wraps the whole pad.
local function ensureFloorOutlineProxy(plot: Instance): BasePart?
	local cf, size = PlotSpawnUtil.getPlotFloorOutlineCFrameSize(plot)
	if not cf or not size then
		return nil
	end

	local proxy = outlineProxy
	if not proxy or not proxy.Parent then
		if proxy then
			proxy:Destroy()
		end
		proxy = Instance.new("Part")
		proxy.Name = "PlotSafezoneOutlineProxy"
		proxy.Anchored = true
		proxy.CanCollide = false
		proxy.CanQuery = false
		proxy.CanTouch = false
		proxy.CastShadow = false
		proxy.Massless = true
		proxy.Transparency = 1
		proxy.Material = Enum.Material.SmoothPlastic
		proxy.Parent = Workspace.CurrentCamera or plot
		outlineProxy = proxy
	end

	proxy.Size = size
	proxy.CFrame = cf
	return proxy
end

local function ensureOutline(plot: Instance): SelectionBox?
	local proxy = ensureFloorOutlineProxy(plot)
	if not proxy then
		return nil
	end

	local box = selectionBox
	if not box or not box.Parent or box.Adornee ~= proxy then
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
		box.Adornee = proxy
		box.Parent = Workspace.CurrentCamera or plot
		selectionBox = box
	end

	return box
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
	-- Owned plot only — never outline someone else's base.
	local plot = PlotPaths.findPlotOwnedByPlayer(player)
	if not plot then
		local bySlot = PlotPaths.findPlotForAssignedSlot(player)
		if bySlot and isOwnedByLocalPlayer(bySlot) then
			plot = bySlot
		end
	end
	if plot and not isOwnedByLocalPlayer(plot) then
		plot = nil
	end
	cachedPlot = plot
	cachedCenter = if plot then resolvePlotCenter(plot) else nil
	if not plot then
		destroyOutline()
	end
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
		if selectionBox then
			selectionBox.Visible = false
			selectionBox.Transparency = 1
		end
		return
	end

	if not cachedPlot or not cachedPlot.Parent or not isOwnedByLocalPlayer(cachedPlot) then
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
	local box = ensureOutline(plot)
	local visible = transparency < 0.995
	if box then
		box.Visible = visible
		box.Transparency = transparency
		box.LineThickness = BOX_LINE_THICKNESS
		box.Color3 = OUTLINE_COLOR
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
