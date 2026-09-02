-- [ACTIVE] GearService
-- Owns gear grant/equip/tools + workout power ticks (server).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local LevelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LevelConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local LevelService = require(script.Parent:WaitForChild("LevelService"))

local GearService = {}

local workoutSessions: { [Player]: { gearId: number, conn: RBXScriptConnection?, lastTick: number } } = {}
local lastWorkoutGainAt: { [number]: number } = {}
local workoutXpStreak: { [number]: number } = {}
local WORKOUT_GAIN_COOLDOWN = 1.0
local playerConns: { [Player]: { RBXScriptConnection } } = {}

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
	local clone = GearConfig.cloneGearModel(def.id)
	local tool = Instance.new("Tool")
	tool.Name = def.name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = false
	tool:SetAttribute(GearConfig.GEAR_TOOL_ATTR, true)
	tool:SetAttribute(GearConfig.GEAR_ID_ATTR, def.id)
	-- Highest toolbar priority — custom hotbar keeps workout gear in slot 1.
	tool:SetAttribute("ToolbarPriority", 100_000)
	if def.id == 6 then
		tool:SetAttribute("RainbowGear", true)
	end

	local handle: BasePart
	if clone then
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
		-- Keep non-part VFX under the tool (attachments/emitters move with parts).
		-- Skip 2D ImageLabels — those are shop/inventory icons, not world meshes.
		for _, d in clone:GetChildren() do
			if d:IsA("GuiBase") or d:IsA("Script") or d:IsA("LocalScript") then
				continue
			end
			if not d:IsA("BasePart") then
				d.Parent = tool
			end
		end
		clone:Destroy()
		handle = main
		local icon = GearConfig.getIconImage(def.id)
		if icon ~= "" then
			tool.TextureId = icon
			tool:SetAttribute("ToolbarIcon", icon)
		end
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

local function destroyAllGearTools(player: Player)
	local function wipe(root: Instance?)
		if not root then
			return
		end
		for _, c in root:GetChildren() do
			if c:IsA("Tool") and c:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				c:Destroy()
			end
		end
	end
	wipe(player:FindFirstChildOfClass("Backpack"))
	wipe(player.Character)
end

function GearService.ensureTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	local equipped = player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR)
	local equippedId = if typeof(equipped) == "number" then math.floor(equipped) else 0

	-- Only one dumbbell tool at a time (the equipped one).
	if equippedId <= 0 or not GearService.owns(player, equippedId) then
		destroyAllGearTools(player)
		return
	end

	local existing = GearService.findGearTool(player, equippedId)
	-- Remove every other gear tool.
	local function purgeOthers(root: Instance?)
		if not root then
			return
		end
		for _, c in root:GetChildren() do
			if c:IsA("Tool") and c:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				local id = c:GetAttribute(GearConfig.GEAR_ID_ATTR)
				if id ~= equippedId then
					c:Destroy()
				end
			end
		end
	end
	purgeOthers(backpack)
	purgeOthers(player.Character)

	if not existing then
		local def = GearConfig.get(equippedId)
		if def then
			local tool = GearService.buildGearTool(def)
			if tool then
				tool.Parent = backpack
			end
		end
	end
end

function GearService.grantGear(player: Player, gearId: number, autoEquip: boolean?): boolean
	local def = GearConfig.get(gearId)
	if not def then
		return false
	end
	local owned = GearService.getOwnedSet(player)
	if not owned[gearId] then
		owned[gearId] = true
		GearService.setOwnedSet(player, owned)
	end
	if autoEquip then
		-- Backpack/hotbar swap only — equipGear never EquipTool / never starts a workout.
		local ok, err = GearService.equipGear(player, gearId)
		if not ok then
			warn("[GearService] auto-equip after grant failed:", err)
		end
	end
	return true
end

function GearService.resetLoadout(player: Player)
	GearService.stopWorkout(player)
	GearService.setOwnedSet(player, {})
	player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, 0)
	destroyAllGearTools(player)
end

function GearService.equipGear(player: Player, gearId: number): (boolean, string?)
	if gearId == 0 then
		GearService.stopWorkout(player)
		player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, 0)
		destroyAllGearTools(player)
		return true, nil
	end
	if not GearService.owns(player, gearId) then
		return false, "Not owned"
	end
	GearService.stopWorkout(player)
	player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, gearId)
	destroyAllGearTools(player)
	local def = GearConfig.get(gearId)
	if not def then
		return false, "Unknown gear"
	end
	local tool = GearService.buildGearTool(def)
	if not tool then
		return false, "Tool build failed"
	end
	-- Put in backpack / hotbar only — do not EquipTool. Auto-equip was starting
	-- workouts while the upgrades shop was still open.
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		tool:Destroy()
		return false, "No backpack"
	end
	tool.Parent = backpack
	return true, nil
end

local lastDoubleTapAt: { [number]: number } = {}

local function computeTickGain(player: Player, def: any): number
	local gain = def.powerGain
	if player:GetAttribute(StoreConfig.ATTR.DOUBLE_POWER_OWNED) == true then
		gain = math.floor(gain * StoreConfig.DOUBLE_POWER_MULTIPLIER + 0.5)
	end
	return math.max(1, math.floor(gain * RebirthConfig.getPowerGainMultiplier(player) + 1e-6))
end

function GearService.claimWorkoutDoubleTap(player: Player): number
	local session = workoutSessions[player]
	if not session then
		return 0
	end
	local now = os.clock()
	local uid = player.UserId
	if now - (lastDoubleTapAt[uid] or 0) < 0.75 then
		return 0
	end
	local def = GearConfig.get(session.gearId)
	if not def then
		return 0
	end
	lastDoubleTapAt[uid] = now
	local gain = computeTickGain(player, def) * 2
	WorkoutPower.addPower(player, gain)
	return gain
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
	lastDoubleTapAt[player.UserId] = nil
	player:SetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR, false)
	local tool = GearService.findGearTool(player, session.gearId)
	if tool then
		tool.RequiresHandle = true
	end
end

function GearService.startWorkout(player: Player, gearId: number): (boolean, string?)
	local def = GearConfig.get(gearId)
	if not def then
		return false, "Unknown gear"
	end
	if not GearService.owns(player, gearId) then
		return false, "Not owned"
	end

	-- Already curling this gear — ignore spam re-equip / re-invoke.
	local existing = workoutSessions[player]
	if existing and existing.gearId == gearId then
		return true, nil
	end

	GearService.stopWorkout(player)
	player:SetAttribute(GearConfig.EQUIPPED_GEAR_ATTR, gearId)
	player:SetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR, true)
	local equippedTool = GearService.findGearTool(player, gearId)
	if equippedTool then
		equippedTool.RequiresHandle = false
		local char = player.Character
		if char then
			for _, d in char:GetDescendants() do
				if (d:IsA("Motor6D") or d:IsA("Weld")) and string.find(string.lower(d.Name), "grip", 1, true) then
					d:Destroy()
				end
			end
		end
	end

	local function applyGainTick()
		local now = os.clock()
		local prev = lastWorkoutGainAt[player.UserId] or 0
		if now - prev < WORKOUT_GAIN_COOLDOWN then
			return false
		end
		lastWorkoutGainAt[player.UserId] = now
		local gain = def.powerGain
		if player:GetAttribute(StoreConfig.ATTR.DOUBLE_POWER_OWNED) == true then
			gain = math.floor(gain * StoreConfig.DOUBLE_POWER_MULTIPLIER + 0.5)
		end
		gain = math.max(1, math.floor(gain * RebirthConfig.getPowerGainMultiplier(player) + 1e-6))
		WorkoutPower.addPower(player, gain)
		player:SetAttribute("WorkoutLastGain", gain)
		local pulse = player:GetAttribute("WorkoutPowerPulse")
		player:SetAttribute("WorkoutPowerPulse", (if typeof(pulse) == "number" then pulse else 0) + 1)
		local uid = player.UserId
		local streak = (workoutXpStreak[uid] or 0) + 1
		if streak >= LevelConfig.WORKOUT_XP_EVERY_GAINS then
			workoutXpStreak[uid] = 0
			LevelService.addXp(player, LevelConfig.XP.workout, "workout")
		else
			workoutXpStreak[uid] = streak
		end
		return true
	end

	-- First gain only if cooldown allows (blocks hotbar spam for free +power).
	applyGainTick()

	local last = lastWorkoutGainAt[player.UserId] or 0
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
		if now - session.lastTick < WORKOUT_GAIN_COOLDOWN then
			return
		end
		if applyGainTick() then
			session.lastTick = now
		end
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
	local cash = player:GetAttribute("Cash")
	if typeof(cash) ~= "number" or cash < def.cashPrice then
		return false, "Not enough cash"
	end
	player:SetAttribute("Cash", cash - def.cashPrice)
	if not GearService.grantGear(player, gearId, true) then
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
		lastWorkoutGainAt[player.UserId] = nil
		workoutXpStreak[player.UserId] = nil
		lastDoubleTapAt[player.UserId] = nil
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
