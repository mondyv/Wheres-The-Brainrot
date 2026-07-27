-- [ACTIVE] GrassCullController
--[[
	Client-only land content cull (kept name for init wiring).

	Default: park non-essential LandN children when 2+ lands away (keep ±1).
	Low Graphics: keep current land only, and also park grass/trees/rocks/decor
	on that land (bushes stay). Never Destroy — restore when range/settings change.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))

local M = {}

-- Keep current land and ±keepRadius. Unload when abs(delta) > keepRadius.
local DEFAULT_KEEP_RADIUS = 1
local keepRadius = DEFAULT_KEEP_RADIUS
local lowGraphics = false
local POLL_SEC = 0.45
local START_DELAY_SEC = 4
local FEATURE_ENABLED = true

local player = Players.LocalPlayer
local wired = false
local heartbeatConn: RBXScriptConnection? = nil
local landsChildConn: RBXScriptConnection? = nil
local accum = 0.0
local currentLand = 0
local cullActive = false

type CullEntry = {
	inst: Instance,
	home: Instance,
	land: number,
}

local entries: { [Instance]: CullEntry } = {}
local landFolders: { [number]: Instance } = {}
local landChildConns: { [number]: RBXScriptConnection } = {}

local cacheFolder: Folder? = nil

local function getCache(): Folder
	local existing = cacheFolder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LandContentCullCache"
	folder.Parent = player:FindFirstChild("PlayerScripts") or player
	cacheFolder = folder
	return folder
end

local function landsRoot(): Instance?
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Lands")
end

local function landNumberFromFolder(landFolder: Instance): number?
	local n = string.match(landFolder.Name, "^Land(%d+)$")
	if not n then
		return nil
	end
	return tonumber(n)
end

local function shouldKeepChild(inst: Instance): boolean
	if inst:IsA("BaseScript") or inst:IsA("ModuleScript") then
		return true
	end

	local name = string.lower(inst.Name)

	if name == "spawn" or name == "spawnpart" or name == "landspawn" then
		return true
	end
	if string.find(name, "hitbox", 1, true) then
		return true
	end
	if string.find(name, "comingsoon", 1, true) then
		return true
	end
	if string.find(name, "safezone", 1, true) then
		return true
	end

	-- Walk surfaces: BaseParts only. Models named Island/Ground must NOT stay whole.
	if not inst:IsA("BasePart") then
		return false
	end

	if
		name == "ground"
		or name == "floor"
		or name == "terrain"
		or name == "baseplate"
		or name == "path"
		or name == "road"
		or name == "bridge"
		or name == "platform"
		or name == "collision"
		or name == "walkway"
	then
		return true
	end

	return false
end

local function alnumLower(name: string): string
	return string.gsub(string.lower(name), "[^a-z0-9]", "")
end

-- Heavy decor safe to hide even on the current land in Low Graphics (never bushes).
local function isLowGfxDecorName(name: string): boolean
	local ak = alnumLower(name)
	if ak == "" then
		return false
	end
	if string.find(ak, "bush", 1, true) then
		return false
	end
	if ak == "grass" or string.find(ak, "grass", 1, true) then
		return true
	end
	if ak == "trees" or ak == "tree" or ak == "rocks" or ak == "rock" then
		return true
	end
	if
		ak == "decor"
		or ak == "decoration"
		or ak == "decorations"
		or ak == "foliage"
		or ak == "vegetation"
		or ak == "plants"
		or ak == "plant"
		or ak == "leaves"
		or ak == "flowers"
		or ak == "clutter"
		or ak == "scenery"
		or ak == "props"
	then
		return true
	end
	return false
end

local function shouldKeepLand(landNum: number, playerLand: number): boolean
	if playerLand <= 0 then
		-- Don't touch anything until we know where the player is (avoids mass reparent on join).
		return true
	end
	return math.abs(landNum - playerLand) <= keepRadius
end

local function shouldParkEntry(entry: CullEntry, playerLand: number): boolean
	if not shouldKeepLand(entry.land, playerLand) then
		return true
	end
	-- Low Graphics: also dump grass/trees/rocks on the land you're standing on.
	if lowGraphics and isLowGfxDecorName(entry.inst.Name) then
		return true
	end
	return false
end

local function parkEntry(entry: CullEntry)
	if not cullActive then
		return
	end
	local cache = getCache()
	local inst = entry.inst
	if not inst.Parent then
		return
	end
	if inst.Parent == cache then
		return
	end
	entry.home = inst.Parent
	inst.Parent = cache
end

local function restoreEntry(entry: CullEntry)
	local inst = entry.inst
	local home = entry.home
	if not home or not home.Parent then
		return
	end
	if inst.Parent == home then
		return
	end
	inst.Parent = home
end

local function unregisterEntry(inst: Instance)
	entries[inst] = nil
end

local function registerCullable(landNum: number, inst: Instance)
	if entries[inst] then
		return
	end
	if shouldKeepChild(inst) then
		return
	end
	local home = inst.Parent
	if not home then
		return
	end
	local cache = getCache()
	if home == cache then
		return
	end

	local entry: CullEntry = {
		inst = inst,
		home = home,
		land = landNum,
	}
	entries[inst] = entry

	inst.Destroying:Once(function()
		unregisterEntry(inst)
	end)

	if cullActive and currentLand > 0 and shouldParkEntry(entry, currentLand) then
		parkEntry(entry)
	end
end

local function applyForPlayerLand(playerLand: number)
	if not cullActive or playerLand <= 0 then
		return
	end
	currentLand = playerLand
	local parked = 0
	for _, entry in entries do
		if shouldParkEntry(entry, playerLand) then
			parkEntry(entry)
			parked += 1
			-- Spread massive reparents across frames so join never freezes black.
			if parked % 3 == 0 then
				task.wait()
			end
		else
			restoreEntry(entry)
		end
	end
end

local function hookLandFolder(landFolder: Instance, landNum: number)
	landFolders[landNum] = landFolder

	local existingConn = landChildConns[landNum]
	if existingConn then
		existingConn:Disconnect()
		landChildConns[landNum] = nil
	end

	for _, child in landFolder:GetChildren() do
		registerCullable(landNum, child)
		-- One level deep: grass folders parented under Island/etc.
		if not shouldKeepChild(child) then
			for _, nested in child:GetChildren() do
				if isLowGfxDecorName(nested.Name) then
					registerCullable(landNum, nested)
				end
			end
		end
	end

	landChildConns[landNum] = landFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			if child.Parent == landFolder then
				registerCullable(landNum, child)
				if not shouldKeepChild(child) then
					for _, nested in child:GetChildren() do
						if isLowGfxDecorName(nested.Name) then
							registerCullable(landNum, nested)
						end
					end
				end
			end
		end)
	end)
end

local function scanExistingLands()
	local lands = landsRoot()
	if not lands then
		return
	end
	for _, child in lands:GetChildren() do
		local landNum = landNumberFromFolder(child)
		if landNum then
			hookLandFolder(child, landNum)
		end
	end
end

local function playerLandNow(): number
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return currentLand
	end
	local land = math.floor(LandResolver.resolveLandAtPosition(hrp.Position))
	if land < 1 then
		return currentLand
	end
	return land
end

local function onHeartbeat(dt: number)
	if not FEATURE_ENABLED or not cullActive then
		return
	end
	accum += dt
	if accum < POLL_SEC then
		return
	end
	accum = 0

	local land = playerLandNow()
	if land ~= currentLand and land > 0 then
		applyForPlayerLand(land)
	end
end

local function onLandFolderAdded(landFolder: Instance)
	local landNum = landNumberFromFolder(landFolder)
	if not landNum then
		return
	end
	hookLandFolder(landFolder, landNum)
	if cullActive and currentLand > 0 then
		task.defer(applyForPlayerLand, currentLand)
	end
end

function M.setEnabled(enabled: boolean)
	FEATURE_ENABLED = enabled
	if enabled then
		scanExistingLands()
		if cullActive then
			applyForPlayerLand(playerLandNow())
		end
		return
	end
	for _, entry in entries do
		restoreEntry(entry)
	end
end

-- Low Graphics: current land only + hide grass/trees/rocks on that land too.
function M.setLowGraphics(enabled: boolean)
	local nextOn = enabled == true
	if lowGraphics == nextOn then
		return
	end
	lowGraphics = nextOn
	keepRadius = if nextOn then 0 else DEFAULT_KEEP_RADIUS
	if cullActive then
		local land = playerLandNow()
		if land > 0 then
			task.defer(applyForPlayerLand, land)
		end
	end
end

function M.init()
	if wired then
		return
	end
	wired = true

	if not FEATURE_ENABLED then
		return
	end

	task.spawn(function()
		-- Never reparent map content during loading / first frames.
		task.wait(START_DELAY_SEC)

		local lands = landsRoot()
		local deadline = os.clock() + 30
		while not lands and os.clock() < deadline do
			task.wait(0.5)
			lands = landsRoot()
		end
		if not lands then
			warn("[GrassCullController] Map.Lands missing — land content cull skipped")
			return
		end

		getCache()
		scanExistingLands()

		local land = playerLandNow()
		if land <= 0 then
			local charDeadline = os.clock() + 15
			while land <= 0 and os.clock() < charDeadline do
				task.wait(0.5)
				land = playerLandNow()
			end
		end

		cullActive = true
		if land > 0 then
			applyForPlayerLand(land)
		end

		landsChildConn = lands.ChildAdded:Connect(onLandFolderAdded)
		heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
	end)
end

return M
