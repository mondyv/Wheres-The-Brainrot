-- [ACTIVE] GrassCullController
--[[
	TEMP lag test: hide all Map.Lands/*/grass grassparts on the client.
	Uses LocalTransparencyModifier (does NOT Destroy / does NOT change Transparency),
	so flip HIDE_ALL_GRASS back to false to restore instantly next session.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local M = {}

-- TEMP: set false to bring grass back.
local HIDE_ALL_GRASS = true

local HIDE_PER_FRAME = 120
local HIDDEN_MODIFIER = 1

local player = Players.LocalPlayer
local pending: { BasePart } = {}
local hiddenParts: { [BasePart]: boolean } = {}
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsConn: RBXScriptConnection? = nil
local descendantConns: { RBXScriptConnection } = {}

local function isGrassPart(inst: Instance): boolean
	return inst:IsA("BasePart") and string.lower(inst.Name) == "grasspart"
end

local function hidePart(part: BasePart)
	if hiddenParts[part] then
		return
	end
	hiddenParts[part] = true
	part.LocalTransparencyModifier = HIDDEN_MODIFIER
	part.CastShadow = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
end

local function showPart(part: BasePart)
	if not hiddenParts[part] then
		return
	end
	hiddenParts[part] = nil
	part.LocalTransparencyModifier = 0
end

local function enqueueGrassUnder(root: Instance)
	local stack: { Instance } = { root }
	while #stack > 0 do
		local inst = table.remove(stack) :: Instance
		if isGrassPart(inst) then
			table.insert(pending, inst :: BasePart)
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
	end
end

local function landsFolder(): Instance?
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Lands")
end

local function queueAllLands()
	local lands = landsFolder()
	if not lands then
		return
	end
	for _, land in lands:GetChildren() do
		local grass = land:FindFirstChild("grass")
		if grass then
			enqueueGrassUnder(grass)
		end
	end
end

local function onHeartbeat(_dt: number)
	if not HIDE_ALL_GRASS then
		return
	end
	local n = math.min(#pending, HIDE_PER_FRAME)
	for _ = 1, n do
		local part = table.remove(pending)
		if part and part.Parent then
			hidePart(part)
		end
	end
end

local function watchLands(lands: Instance)
	for _, conn in descendantConns do
		conn:Disconnect()
	end
	table.clear(descendantConns)

	table.insert(
		descendantConns,
		lands.DescendantAdded:Connect(function(inst)
			if not HIDE_ALL_GRASS then
				return
			end
			if isGrassPart(inst) then
				table.insert(pending, inst :: BasePart)
			end
		end)
	)
end

function M.setEnabled(enabled: boolean)
	HIDE_ALL_GRASS = enabled
	if enabled then
		queueAllLands()
		return
	end
	table.clear(pending)
	for part in hiddenParts do
		if part.Parent then
			showPart(part)
		end
	end
	table.clear(hiddenParts)
end

function M.isHidden(): boolean
	return HIDE_ALL_GRASS
end

function M.init()
	if wired then
		return
	end
	wired = true

	if not HIDE_ALL_GRASS then
		return
	end

	task.spawn(function()
		local lands = landsFolder()
		local deadline = os.clock() + 30
		while not lands and os.clock() < deadline do
			task.wait(0.5)
			lands = landsFolder()
		end
		if not lands then
			warn("[GrassCullController] Map.Lands missing — cannot hide grass")
			return
		end

		watchLands(lands)
		queueAllLands()

		landsConn = lands.ChildAdded:Connect(function(land)
			local grass = land:FindFirstChild("grass")
			if grass then
				enqueueGrassUnder(grass)
			else
				task.defer(function()
					local late = land:FindFirstChild("grass")
					if late then
						enqueueGrassUnder(late)
					end
				end)
			end
		end)

		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
		warn("[GrassCullController] TEMP: hiding all land grass (LocalTransparencyModifier). Set HIDE_ALL_GRASS=false to restore.")
	end)
end

return M
