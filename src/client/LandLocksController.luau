-- [ACTIVE] LandLocksController
-- Local fade + collision for Workspace.Map["Land Locks"]["Land N Lock"] based on PowerMax.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LandPowerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandPowerConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))

local player = Players.LocalPlayer
local FADE = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local M = {}

local locksFolder: Instance? = nil
local lockByLand: { [number]: Instance } = {}
local openByLand: { [number]: boolean } = {}
local tweensByLand: { [number]: { Tween } } = {}

local function cancelTweensFor(land: number)
	local list = tweensByLand[land]
	if not list then
		return
	end
	for _, tw in list do
		tw:Cancel()
	end
	table.clear(list)
end

local function trackTween(land: number, tw: Tween)
	local list = tweensByLand[land]
	if not list then
		list = {}
		tweensByLand[land] = list
	end
	table.insert(list, tw)
end

local function parseLandFromName(name: string): number?
	local n = string.match(name, "^Land%s*(%d+)%s*Lock$")
	if not n then
		n = string.match(name, "(%d+)")
	end
	local land = tonumber(n)
	if typeof(land) == "number" and land >= 2 and land <= LandPowerConfig.MAX_LAND then
		return math.floor(land)
	end
	return nil
end

local function fillLockLabels(root: Instance, required: number)
	local shown = LandPowerConfig.formatPower(required)
	for _, d in root:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local key = string.lower(d.Name)
			local shouldSet = key == "amount"
				or key == "power"
				or key == "recommended"
				or key == "value"
				or key == "number"
				or string.find(key, "power", 1, true) ~= nil
			if not shouldSet then
				local txt = d.Text
				if txt == "" or string.match(txt, "^[%d,]+$") ~= nil then
					shouldSet = true
				end
			end
			if shouldSet then
				d.Text = shown
			end
		end
	end
end

local function setLockVisual(land: number, root: Instance, open: boolean, instant: boolean)
	cancelTweensFor(land)
	local goalT = if open then 1 else 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = not open
			d.CanTouch = not open
			if instant then
				d.LocalTransparencyModifier = goalT
			else
				local tw = TweenService:Create(d, FADE, { LocalTransparencyModifier = goalT })
				tw:Play()
				trackTween(land, tw)
			end
		elseif d:IsA("Decal") or d:IsA("Texture") then
			if instant then
				d.Transparency = goalT
			else
				local tw = TweenService:Create(d, FADE, { Transparency = goalT })
				tw:Play()
				trackTween(land, tw)
			end
		elseif d:IsA("SurfaceGui") or d:IsA("BillboardGui") then
			d.Enabled = not open
		end
	end
	if root:IsA("BasePart") then
		root.CanCollide = not open
		root.CanTouch = not open
		if instant then
			root.LocalTransparencyModifier = goalT
		else
			local tw = TweenService:Create(root, FADE, { LocalTransparencyModifier = goalT })
			tw:Play()
			trackTween(land, tw)
		end
	end
end

local function refreshLocks(instant: boolean?)
	local power = math.max(WorkoutPower.readPowerMax(player), WorkoutPower.readPower(player))
	for land, inst in lockByLand do
		if not inst.Parent then
			continue
		end
		local shouldOpen = LandPowerConfig.meetsLandLock(power, land)
		local wasOpen = openByLand[land]
		if wasOpen == shouldOpen and not instant then
			continue
		end
		openByLand[land] = shouldOpen
		setLockVisual(land, inst, shouldOpen, instant == true or wasOpen == nil)
	end
end

local function registerLock(inst: Instance)
	local land = parseLandFromName(inst.Name)
	if not land then
		return
	end
	lockByLand[land] = inst
	fillLockLabels(inst, LandPowerConfig.requiredToEnterLand(land))
	openByLand[land] = nil
end

local function scanFolder(folder: Instance)
	table.clear(lockByLand)
	for _, ch in folder:GetChildren() do
		registerLock(ch)
	end
	refreshLocks(true)
end

function M.init()
	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 60)
		if not map then
			warn("[LandLocksController] Workspace.Map missing")
			return
		end
		local folder = map:WaitForChild("Land Locks", 60)
		if not folder then
			warn("[LandLocksController] Map.Land Locks missing")
			return
		end
		locksFolder = folder
		scanFolder(folder)
		folder.ChildAdded:Connect(function(ch)
			registerLock(ch)
			refreshLocks(true)
		end)
		folder.ChildRemoved:Connect(function(ch)
			local land = parseLandFromName(ch.Name)
			if land then
				lockByLand[land] = nil
				openByLand[land] = nil
			end
		end)
	end)

	player:GetAttributeChangedSignal(WorkoutPower.POWER_ATTR):Connect(function()
		refreshLocks(false)
	end)
	player:GetAttributeChangedSignal(WorkoutPower.POWER_MAX_ATTR):Connect(function()
		refreshLocks(false)
	end)
end

return M
