-- [ACTIVE] SafezoneQuickNav.server
--[[
	SideUI.Top.Buttons teleports (Sell / Base / Upgrade) while inside the safe zone.
	Client fades → InvokeServer(dest) → stream+teleport → fade out.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local WebTrapConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WebTrapConfig"))

-- Short guard so double-taps / Activated+Down don't chain teleports. Fade already covers most spam.
local COOLDOWN_SEC = 0.55
local HRP_CLEARANCE = 3.1

local STAND_DEST = {
	Sell = {
		aliases = { "Sell Stand", "Sell" },
		hitboxNames = { "SellPadHitbox", "SellHitbox" },
	},
	Upgrade = {
		aliases = { "Upgrade Stand", "Upgrade" },
		hitboxNames = { "UpgradePadHitbox", "UpgradeHitbox" },
	},
}

local lastNavAt: { [Player]: number } = {}
local navRF: RemoteFunction? = nil

local function ensureRemote(): RemoteFunction
	if navRF and navRF.Parent then
		return navRF
	end
	local existing = ReplicatedStorage:FindFirstChild("SafezoneQuickNav")
	if existing and existing:IsA("RemoteFunction") then
		navRF = existing
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = "SafezoneQuickNav"
	rf.Parent = ReplicatedStorage
	navRF = rf
	return rf
end

local function cooldownOk(player: Player): boolean
	local now = os.clock()
	return (lastNavAt[player] or 0) + COOLDOWN_SEC <= now
end

local function nameMatches(instName: string, aliases: { string }): boolean
	local ak = string.lower(string.gsub(instName, "%s+", ""))
	for _, alias in aliases do
		local want = string.lower(string.gsub(alias, "%s+", ""))
		if ak == want then
			return true
		end
	end
	return false
end

local function findStandFolder(uiStands: Instance, aliases: { string }): Instance?
	for _, child in uiStands:GetChildren() do
		if nameMatches(child.Name, aliases) then
			return child
		end
	end
	return nil
end

local function findHitbox(stand: Instance, hitboxNames: { string }): BasePart?
	for _, name in hitboxNames do
		local exact = stand:FindFirstChild(name, true)
		if exact and exact:IsA("BasePart") then
			return exact
		end
	end
	for _, d in stand:GetDescendants() do
		if d:IsA("BasePart") and string.find(d.Name, "Hitbox", 1, true) then
			return d
		end
	end
	return nil
end

local function padTeleportCFrame(hitbox: BasePart): CFrame
	local topY = hitbox.Position.Y + hitbox.Size.Y * 0.5
	local pos = Vector3.new(hitbox.Position.X, topY + HRP_CLEARANCE, hitbox.Position.Z)
	local look = hitbox.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		local right = hitbox.CFrame.RightVector
		flat = Vector3.new(right.X, 0, right.Z)
	end
	if flat.Magnitude < 0.05 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

local function resolveStandCFrame(destKey: string): CFrame?
	local cfg = STAND_DEST[destKey]
	if not cfg then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	local uiStands = map and map:FindFirstChild("UIStands")
	if not uiStands then
		return nil
	end
	local stand = findStandFolder(uiStands, cfg.aliases)
	if not stand then
		return nil
	end
	local hitbox = findHitbox(stand, cfg.hitboxNames)
	if not hitbox then
		return nil
	end
	return padTeleportCFrame(hitbox)
end

local function resolveDestCFrame(player: Player, dest: string): (CFrame?, string?)
	if dest == "Base" then
		local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
		if not spawnCf then
			return nil, "Base not ready yet"
		end
		return spawnCf, nil
	end
	if dest == "Sell" or dest == "Upgrade" then
		local cf = resolveStandCFrame(dest)
		if not cf then
			return nil, dest .. " stand not ready"
		end
		return cf, nil
	end
	return nil, "Unknown destination"
end

local function canNavigate(player: Player): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "No character"
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Cannot teleport right now"
	end
	if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true then
		return false, "You're stuck in a web"
	end
	-- Match client button visibility — warm cache so server isn't empty on first press.
	SafezoneUtil.warmCacheAsync()
	SafezoneUtil.awaitCacheReady(1.5)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local inZone = SafezoneUtil.isCharacterInSafezone(character)
		or SafezoneUtil.isCharacterInToolbarZone(character)
	if not inZone and hrp and hrp:IsA("BasePart") then
		inZone = SafezoneUtil.isWorldPointInRedWall(hrp.Position)
	end
	if not inZone then
		return false, "Only available in the safe zone"
	end
	if not cooldownOk(player) then
		return false, "Please wait a moment"
	end
	return true, nil
end

local function onNavigate(player: Player, destRaw: any): (boolean, string?)
	if typeof(destRaw) ~= "string" then
		return false, "Invalid destination"
	end
	local dest = destRaw
	local ok, reason = canNavigate(player)
	if not ok then
		return false, reason or "Cannot teleport"
	end
	local character = player.Character
	if not character then
		return false, "No character"
	end
	local destCf, destErr = resolveDestCFrame(player, dest)
	if not destCf then
		return false, destErr or "Destination missing"
	end
	if dest == "Base" then
		if not PlotSpawnUtil.teleportPlayerHome(player, character, 12) then
			return false, "Base not ready yet"
		end
	else
		PlotSpawnUtil.streamAndTeleportWithRetries(player, character, destCf, false)
	end
	lastNavAt[player] = os.clock()
	return true, nil
end

Players.PlayerRemoving:Connect(function(player)
	lastNavAt[player] = nil
end)

ensureRemote().OnServerInvoke = onNavigate
