-- [ACTIVE] KillParts.server
--[[
	Map["Land Borders"].Killparts — touching a kill part soft-respawns on the
	player's plot Base (same as cobweb / Return), not the default baseplate spawn.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReviveService = require(script.Parent:WaitForChild("Modules"):WaitForChild("ReviveService"))

local DEBOUNCE_SEC = 0.75
-- Longer than soft-respawn teleport retries so falling into Killparts cannot death-loop.
local SPAWN_IMMUNITY_SEC = 5
local FOLDER_PATH = { "Map", "Land Borders", "Killparts" }

local wired: { [BasePart]: boolean } = {}
local debounceUntil: { [Player]: number } = {}
local spawnImmuneUntil: { [Player]: number } = {}
local playerConns: { [Player]: { RBXScriptConnection } } = {}

local function resolveKillpartsFolder(): Instance?
	local node: Instance = Workspace
	for _, name in FOLDER_PATH do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function killCharacter(char: Model)
	local player = Players:GetPlayerFromCharacter(char)
	if player then
		ReviveService.softRespawnAtPlotBase(player)
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		hum.Health = 0
	end
end

local function onKillPartTouched(hit: BasePart)
	local char = hit:FindFirstAncestorOfClass("Model")
	if not char then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then
		return
	end
	local now = os.clock()
	local immuneUntil = spawnImmuneUntil[player]
	if immuneUntil and now < immuneUntil then
		return
	end
	local untilT = debounceUntil[player]
	if untilT and now < untilT then
		return
	end
	debounceUntil[player] = now + DEBOUNCE_SEC
	killCharacter(char)
end

local function wireKillPart(part: BasePart)
	if wired[part] then
		return
	end
	wired[part] = true
	part.CanTouch = true
	part.Touched:Connect(onKillPartTouched)
end

local function isKillPartCandidate(inst: Instance): boolean
	if not inst:IsA("BasePart") then
		return false
	end
	local key = string.gsub(string.lower(inst.Name), "%s+", "")
	return key == "killpart" or key == "killbrick" or key == "killzone"
end

local function tryWire(inst: Instance)
	if isKillPartCandidate(inst) then
		wireKillPart(inst :: BasePart)
		return
	end
	if inst:IsA("BasePart") and inst.Parent and string.gsub(string.lower(inst.Parent.Name), "%s+", "") == "killparts" then
		-- Any BasePart directly under Killparts (even if not named KillPart).
		wireKillPart(inst)
	end
end

local function scanFolder(folder: Instance)
	for _, d in folder:GetDescendants() do
		tryWire(d)
	end
	-- Direct children that are parts (common Studio layout: Killparts.KillPart × N).
	for _, ch in folder:GetChildren() do
		tryWire(ch)
	end
	folder.DescendantAdded:Connect(function(inst)
		task.defer(tryWire, inst)
	end)
end

local function hookPlayer(player: Player)
	local list = playerConns[player]
	if list then
		for _, c in list do
			c:Disconnect()
		end
	end
	list = {}
	playerConns[player] = list
	table.insert(
		list,
		player.CharacterAdded:Connect(function()
			local now = os.clock()
			debounceUntil[player] = now + SPAWN_IMMUNITY_SEC
			spawnImmuneUntil[player] = now + SPAWN_IMMUNITY_SEC
		end)
	)
end

Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(function(player)
	debounceUntil[player] = nil
	spawnImmuneUntil[player] = nil
	local list = playerConns[player]
	if list then
		for _, c in list do
			c:Disconnect()
		end
		playerConns[player] = nil
	end
end)
for _, plr in Players:GetPlayers() do
	hookPlayer(plr)
end

task.spawn(function()
	local folder = resolveKillpartsFolder()
	if not folder then
		local map = Workspace:WaitForChild("Map", 120)
		if not map then
			warn("[KillParts] Workspace.Map missing")
			return
		end
		local borders = map:WaitForChild("Land Borders", 120)
		if not borders then
			warn("[KillParts] Map['Land Borders'] missing")
			return
		end
		folder = borders:WaitForChild("Killparts", 60)
		if not folder then
			warn("[KillParts] Land Borders.Killparts missing")
			return
		end
	end
	scanFolder(folder)
end)
