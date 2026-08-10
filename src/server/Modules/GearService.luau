-- [ACTIVE] GearService
-- Owns gear grant/equip/tools + workout power ticks (server).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))

local GearService = {}

local gearsFolder: Folder? = nil
local workoutSessions: { [Player]: { gearId: number, conn: RBXScriptConnection?, lastTick: number } } = {}
local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function getGearsFolder(): Folder?
	if gearsFolder and gearsFolder.Parent then
		return gearsFolder
	end
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local folder = assets and assets:FindFirstChild("Gears")
	if folder and folder:IsA("Folder") then
		gearsFolder = folder
		return folder
	end
	return nil
end

local function getGearTemplate(def: GearConfig.GearDef): Model?
	local folder = getGearsFolder()
	if not folder then
		return nil
	end
	local inst = folder:FindFirstChild(def.assetName)
	if inst and inst:IsA("Model") then
		return inst
	end
	return nil
end

local function getHandlePart(model: Model): BasePart?
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	local primary = model:FindFirstChild("Primary")
	if primary and primary:IsA("BasePart") then
		return primary
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

function GearService.getOwnedSet(player: Player): { [number]: boolean }
	return GearConfig.parseOwned(player:GetAttribute(GearConfig.OWNED_GEARS_ATTR))
end

function GearService.setOwnedSet(player: Player, set: { [number]: boolean })
	player:SetAttribute(GearConfig.OWNED_GEARS_ATTR, GearConfig.encodeOwned(set))
end

function GearService.owns(player: Player, gearId: number): boolean
	return GearService.getOwnedSet(player)[gearId] == true
end

function GearService.findGearTool(player: Player, gearId: number): Tool?
	local function scan(root: Instance?): Tool?
		if not root then
			return nil
		end
		for _, c in root:GetChildren() do
			if c:IsA("Tool") and c:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				local id = c:GetAttribute(GearConfig.GEAR_ID_ATTR)
				if id == gearId then
					return c
				end
			end
		end
		return nil
	end
	return scan(player:FindFirstChildOfClass("Backpack")) or scan(player.Character)
end

function GearService.buildGearTool(def: GearConfig.GearDef): Tool?
	local template = getGearTemplate(def)
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = false
	tool:SetAttribute(GearConfig.GEAR_TOOL_ATTR, true)
	tool:SetAttribute(GearConfig.GEAR_ID_ATTR, def.id)
	tool:SetAttribute("ToolbarPriority", 1000 - def.id) -- lower id = first in hotbar

	local handle: BasePart
	if template then
		local clone = template:Clone()
		for _, d in clone:GetDescendants() do
			if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
				d:Destroy()
			end
		end
		local main = getHandlePart(clone)
		if not main then
			clone:Destroy()
			tool:Destroy()
			return nil
		end
		local parts: { BasePart } = {}
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		main.Name = "Handle"
		main.Anchored = false
		main.Massless = true
		main.CanCollide = false
		main.Parent = tool
		for _, p in parts do
			if p ~= main then
				p.Anchored = false
				p.Massless = true
				p.CanCollide = false
				p.Parent = tool
				local w = Instance.new("WeldConstraint")
				w.Part0 = main
				w.Part1 = p
				w.Parent = main
			end
		end
		clone:Destroy()
		handle = main
	else
		handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(0.4, 0.4, 2)
		handle.Color = Color3.fromRGB(140, 100, 60)
		handle.Anchored = false
		handle.Massless = true
		handle.CanCollide = false
		handle.Parent = tool
	end

	return tool
end

function GearService.ensureTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	local owned = GearService.getOwnedSet(player)
	for _, def in GearConfig.GEARS do
		if owned[def.id] then
			if not GearService.findGearTool(player, def.id) then
				local tool = GearService.buildGearTool(def)
				if tool then
					tool.Parent = backpack
				end
			end
		end
	end
end

function GearService.grantGear(player: Player, gearId: number): boolean
	local def = GearConfig.get(gearId)
	if not def then
		return false
	end
	local owned = GearService.getOwnedSet(player)
	if owned[gearId] then
		return true
	end
	if not GearConfig.isUnlocked(gearId, owned) then
		return false
	end
	owned[gearId] = true
	GearService.setOwnedSet(player, owned)
	GearService.ensureTools(player)
	return true
end

function GearService.equipGear(player: Player, gearId: number): (boolean, string?)
	if gearId == 0 then
		player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, 0)
		return true, nil
	end
	if not GearService.owns(player, gearId) then
		return false, "Not owned"
	end
	player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, gearId)
	-- Put tool in character for immediate use.
	local tool = GearService.findGearTool(player, gearId)
	local character = player.Character
	if tool and character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:EquipTool(tool)
		end
	end
	return true, nil
end

function GearService.stopWorkout(player: Player)
	local session = workoutSessions[player]
	if not session then
		return
	end
	if session.conn then
		session.conn:Disconnect()
		session.conn = nil
	end
	workoutSessions[player] = nil
	player:SetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR, false)
end

function GearService.startWorkout(player: Player, gearId: number): (boolean, string?)
	local def = GearConfig.get(gearId)
	if not def then
		return false, "Unknown gear"
	end
	if not GearService.owns(player, gearId) then
		return false, "Not owned"
	end
	GearService.stopWorkout(player)
	player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, gearId)
	player:SetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR, true)

	local last = os.clock()
	local session = { gearId = gearId, conn = nil :: RBXScriptConnection?, lastTick = last }
	session.conn = RunService.Heartbeat:Connect(function()
		if not player.Parent then
			GearService.stopWorkout(player)
			return
		end
		local char = player.Character
		if not char then
			GearService.stopWorkout(player)
			return
		end
		local tool = GearService.findGearTool(player, gearId)
		if not tool or tool.Parent ~= char then
			GearService.stopWorkout(player)
			return
		end
		local now = os.clock()
		if now - session.lastTick < 1 then
			return
		end
		session.lastTick = now
		WorkoutPower.addPower(player, def.powerGain)
		-- Client listens to Power change + WorkoutActive for VFX; fire a pulse attr.
		local pulse = player:GetAttribute("WorkoutPowerPulse")
		player:SetAttribute("WorkoutPowerPulse", (if typeof(pulse) == "number" then pulse else 0) + 1)
		player:SetAttribute("WorkoutLastGain", def.powerGain)
	end)
	workoutSessions[player] = session
	return true, nil
end

function GearService.purchaseCash(player: Player, gearId: number): (boolean, string?)
	local def = GearConfig.get(gearId)
	if not def then
		return false, "Unknown gear"
	end
	local owned = GearService.getOwnedSet(player)
	if owned[gearId] then
		return false, "Already owned"
	end
	if not GearConfig.isUnlocked(gearId, owned) then
		return false, "Locked"
	end
	local cash = player:GetAttribute("Cash")
	if typeof(cash) ~= "number" or cash < def.cashPrice then
		return false, "Not enough cash"
	end
	player:SetAttribute("Cash", cash - def.cashPrice)
	if not GearService.grantGear(player, gearId) then
		player:SetAttribute("Cash", cash)
		return false, "Grant failed"
	end
	return true, nil
end

local function bindPlayer(player: Player)
	if playerConns[player] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	table.insert(
		conns,
		player.CharacterAdded:Connect(function()
			task.defer(function()
				GearService.ensureTools(player)
			end)
		end)
	)
	playerConns[player] = conns
	task.defer(function()
		GearService.ensureTools(player)
	end)
end

function GearService.init()
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		GearService.stopWorkout(player)
		local conns = playerConns[player]
		if conns then
			for _, c in conns do
				c:Disconnect()
			end
			playerConns[player] = nil
		end
	end)
	for _, p in Players:GetPlayers() do
		bindPlayer(p)
	end
end

return GearService
