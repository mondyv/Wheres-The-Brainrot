-- [ACTIVE] AdminCommands.server
-- Server-authoritative admin command runner used by the F5 command bar.

local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AdminAllowlist = require(script.Parent:WaitForChild("Modules"):WaitForChild("AdminAllowlist"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local AdminBroadcastService = require(script.Parent:WaitForChild("Modules"):WaitForChild("AdminBroadcastService"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))

local COMMAND_REMOTE_NAME = "AdminCommand"
local CATALOG_REMOTE_NAME = "AdminAutocomplete"
-- Replicated flag: true only when server allowlist grants access (clients cannot forge this).
local ADMIN_ALLOWED_ATTR = "AdminPanelAllowed"
local MAX_GRANT_COUNT = 25
local MAX_CASH_GRANT = 1_000_000_000_000_000

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Remotes"
	created.Parent = ReplicatedStorage
	return created
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

local commandRF = ensureRemoteFunction(COMMAND_REMOTE_NAME)
local catalogRF = ensureRemoteFunction(CATALOG_REMOTE_NAME)

local function syncAdminAccess(player: Player)
	if not player.Parent then
		return
	end
	if AdminAllowlist.isPlayerAllowed(player) then
		player:SetAttribute(ADMIN_ALLOWED_ATTR, true)
	else
		player:SetAttribute(ADMIN_ALLOWED_ATTR, nil)
	end
end

Players.PlayerAdded:Connect(function(player)
	-- PlayerData and other boot scripts may run first; defer so allowlist always applies.
	task.defer(function()
		syncAdminAccess(player)
	end)
end)
for _, plr in Players:GetPlayers() do
	task.defer(function()
		syncAdminAccess(plr)
	end)
end

local function splitWords(raw: string): { string }
	local out: { string } = {}
	for token in string.gmatch(raw, "%S+") do
		table.insert(out, token)
	end
	return out
end

local function normalizeKey(value: string): string
	return string.lower((string.gsub(value, "[%s_%-%p]", "")))
end

local brainrotByKey: { [string]: Brainrots.BrainrotDef } = {}
for _, def in ipairs(Brainrots.BRAINROTS) do
	brainrotByKey[normalizeKey(def.name)] = def
end

local function resolveBrainrot(name: string): Brainrots.BrainrotDef?
	local exact = Brainrots.getByName(name)
	if exact then
		return exact
	end
	return brainrotByKey[normalizeKey(name)]
end

local function resolveTargets(sender: Player, query: string, allowAll: boolean): ({ Player }?, string?)
	local q = string.lower(query)
	if q == "me" or q == "self" then
		return { sender }, nil
	end
	if allowAll and q == "all" then
		return Players:GetPlayers(), nil
	end

	local exact: Player? = nil
	local partial: { Player } = {}
	for _, player in Players:GetPlayers() do
		local name = string.lower(player.Name)
		local displayName = string.lower(player.DisplayName)
		if name == q or displayName == q or tostring(player.UserId) == query then
			exact = player
			break
		end
		if string.find(name, q, 1, true) == 1 or string.find(displayName, q, 1, true) == 1 then
			table.insert(partial, player)
		end
	end
	if exact then
		return { exact }, nil
	end
	if #partial == 1 then
		return partial, nil
	end
	if #partial > 1 then
		return nil, "Player name is ambiguous."
	end
	return nil, "Player not found in this server."
end

local function waitForBindable(folderName: string, bindableName: string, timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 10)
	while os.clock() < deadline do
		local folder = ServerStorage:FindFirstChild(folderName)
		local bf = folder and folder:FindFirstChild(bindableName)
		if bf and bf:IsA("BindableFunction") then
			return bf
		end
		task.wait(0.1)
	end
	return nil
end

local function waitForBrainrotBindable(name: string): BindableFunction?
	return waitForBindable("BrainrotInternal", name, 10)
end

local function waitForLuckyBlockBindable(name: string): BindableFunction?
	return waitForBindable("LuckyBlockInternal", name, 10)
end

local function waitForRebirthBindable(name: string): BindableFunction?
	return waitForBindable("RebirthInternal", name, 10)
end

local LUCKY_BLOCK_NAMES = {
	"star rainbow",
	"Starter Lucky Block",
	"Mythic Lucky Block",
	"Godly Luckyblock",
	"Secret Lucky Block",
}

local MUTATION_NAMES = { "normal", "golden", "diamond", "lava", "galaxy", "rainbow" }

local function buildAutocompleteCatalog(sender: Player)
	local players = { "me", "all" }
	for _, plr in Players:GetPlayers() do
		-- Suggest usernames only (DisplayName still resolves if typed exactly).
		table.insert(players, plr.Name)
	end

	local brainrots: { string } = {}
	for _, def in ipairs(Brainrots.BRAINROTS) do
		if Brainrots.isPlayableBrainrotName(def.name) then
			table.insert(brainrots, def.name)
		end
	end
	table.sort(brainrots)

	return {
		players = players,
		brainrots = brainrots,
		luckyBlocks = LUCKY_BLOCK_NAMES,
		mutations = MUTATION_NAMES,
		allowed = AdminAllowlist.isPlayerAllowed(sender),
	}
end

local commands = {}

commands.help = {
	usage = "help",
	description = "List admin commands.",
	run = function(_sender: Player, _args: { string }): (boolean, string)
		return true,
			"Commands: addinventory, addcash, addluckyblock, resetdata, rebirth, tp, tpland, spectate, serverspawn, globalspawn, servernotif, globalnotif, servershutdown, serverluck, globalluck, kick, ban, unban, playtutorial, fly, help"
	end,
}

commands.tpland = {
	usage = "tpland <1-10> | tpland <player|me|all> <1-10>",
	description = "Teleport yourself or other players to a land's revive/spawn pad.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.tpland.usage
		end

		local landNum: number?
		local targetToken: string? = nil

		local asLand1 = tonumber(args[1])
		if asLand1 and not args[2] then
			landNum = math.floor(asLand1)
			targetToken = "me"
		elseif asLand1 and args[2] then
			landNum = math.floor(asLand1)
			targetToken = args[2]
		elseif args[2] and tonumber(args[2]) then
			landNum = math.floor(tonumber(args[2]) :: number)
			targetToken = args[1]
		else
			return false, "Usage: " .. commands.tpland.usage
		end

		if landNum < 1 or landNum > 10 then
			return false, "Land must be between 1 and 10."
		end

		local targets, targetErr = resolveTargets(sender, targetToken :: string, true)
		if not targets then
			return false, targetErr or "No target."
		end

		local spawnCf = LandResolver.getSpawnCFrameForLand(landNum)
		if not spawnCf then
			return false, string.format("Land %d spawn not found.", landNum)
		end

		local moved = 0
		local failed = 0
		for i, target in targets do
			local character = target.Character
			if not character or not character.Parent then
				failed += 1
				continue
			end
			local offset: CFrame
			if #targets <= 1 then
				offset = CFrame.identity
			else
				local angle = ((i - 1) / #targets) * math.pi * 2
				local radius = 4
				offset = CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			end
			PlotSpawnUtil.teleportCharacterToCFrame(character, spawnCf * offset)
			moved += 1
		end

		if moved == 0 then
			return false, "Teleport failed (missing characters)."
		end
		if #targets == 1 and targets[1] == sender then
			return true, string.format("Teleported to Land %d spawn.", landNum)
		end
		if failed > 0 then
			return true,
				string.format("Teleported %d player(s) to Land %d (%d failed).", moved, landNum, failed)
		end
		return true, string.format("Teleported %d player(s) to Land %d.", moved, landNum)
	end,
}
commands.land = commands.tpland
commands.teleportland = commands.tpland
commands.gotoland = commands.tpland
commands.tpl = commands.tpland

local function getPlayerRootCFrame(player: Player): CFrame?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end
	return hrp.CFrame
end

local function teleportPlayerNear(player: Player, destCf: CFrame, slotIndex: number, slotCount: number): boolean
	local character = player.Character
	if not character or not character.Parent then
		return false
	end
	local offset: CFrame
	if slotCount <= 1 then
		offset = CFrame.new(0, 0, 3)
	else
		local angle = ((slotIndex - 1) / slotCount) * math.pi * 2
		local radius = 4
		offset = CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	end
	PlotSpawnUtil.teleportCharacterToCFrame(character, destCf * offset)
	return true
end

commands.tp = {
	usage = "tp <player> | tp <who|all|me> <toPlayer|me> | tp all me",
	description = "Teleport yourself to a player, teleport players to each other, or bring everyone to you.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.tp.usage
		end

		-- Optional "to" keyword: tp Bob / tp to Bob / tp all to me / tp Alice to Bob
		local tokens: { string } = {}
		for _, arg in args do
			if string.lower(arg) ~= "to" then
				table.insert(tokens, arg)
			end
		end
		if #tokens == 0 or #tokens > 2 then
			return false, "Usage: " .. commands.tp.usage
		end

		local movers: { Player }
		local destination: Player

		if #tokens == 1 then
			local destList, destErr = resolveTargets(sender, tokens[1], false)
			if not destList then
				return false, destErr or "Destination player not found."
			end
			if #destList ~= 1 then
				return false, "Destination must be one player."
			end
			movers = { sender }
			destination = destList[1]
		else
			local whoList, whoErr = resolveTargets(sender, tokens[1], true)
			if not whoList then
				return false, whoErr or "Who to teleport not found."
			end
			local destList, destErr = resolveTargets(sender, tokens[2], false)
			if not destList then
				return false, destErr or "Destination player not found."
			end
			if #destList ~= 1 then
				return false, "Destination must be one player (not all)."
			end
			movers = whoList
			destination = destList[1]
		end

		local destCf = getPlayerRootCFrame(destination)
		if not destCf then
			return false, string.format("%s has no character to teleport to.", destination.Name)
		end

		local toMove: { Player } = {}
		for _, mover in movers do
			if mover ~= destination then
				table.insert(toMove, mover)
			end
		end
		if #toMove == 0 then
			return false, "Nothing to teleport (already at destination)."
		end

		local moved = 0
		local failed = 0
		for i, mover in toMove do
			if teleportPlayerNear(mover, destCf, i, #toMove) then
				moved += 1
			else
				failed += 1
			end
		end

		if moved == 0 then
			return false, "Teleport failed (missing characters)."
		end
		if failed > 0 then
			return true,
				string.format("Teleported %d player(s) to %s (%d failed).", moved, destination.Name, failed)
		end
		if #toMove == 1 and toMove[1] == sender then
			return true, string.format("Teleported to %s.", destination.Name)
		end
		return true, string.format("Teleported %d player(s) to %s.", moved, destination.Name)
	end,
}
commands.teleport = commands.tp
commands["goto"] = commands.tp

commands.addinventory = {
	usage = "addinventory <player|me|all> <brainrot> [count] [mutation] [level]",
	description = "Grant a brainrot to a player's inventory.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] or not args[2] then
			return false, "Usage: " .. commands.addinventory.usage
		end

		local targets, targetErr = resolveTargets(sender, args[1], true)
		if not targets then
			return false, targetErr or "No target."
		end

		local def = resolveBrainrot(args[2])
		if not def then
			return false, "Unknown brainrot: " .. args[2]
		end

		local count = 1
		local mutation = "normal"
		local level = 1
		if tonumber(args[3]) then
			count = math.clamp(math.floor(tonumber(args[3]) :: number), 1, MAX_GRANT_COUNT)
			mutation = args[4] or mutation
			level = if tonumber(args[5]) then math.max(1, math.floor(tonumber(args[5]) :: number)) else level
		else
			mutation = args[3] or mutation
			level = if tonumber(args[4]) then math.max(1, math.floor(tonumber(args[4]) :: number)) else level
		end

		local grant = waitForBrainrotBindable("GrantBrainrotAndEquip")
		if not grant then
			return false, "Inventory grant service is not ready."
		end

		local granted = 0
		for _, target in targets do
			PlayerDataService.waitUntilLoaded(target)
			for _ = 1, count do
				local ok = (grant :: BindableFunction):Invoke(target, {
					name = def.name,
					rarity = def.rarity,
					baseIncome = def.baseIncome,
					mutation = mutation,
					level = level,
				}, {
					equip = true,
				})
				if ok then
					granted += 1
				end
			end
			if target:GetAttribute("PlayerDataLoaded") == true then
				PlayerDataService.savePlayerData(target)
			end
		end

		return true, string.format("Granted %dx %s to %d player(s).", granted, def.name, #targets)
	end,
}

commands.give = commands.addinventory
commands.addinv = commands.addinventory

commands.resetdata = {
	usage = "resetdata <player|me|all>",
	description = "Reset cash, upgrades, rebirth, index, inventory, stands, and saved data.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.resetdata.usage
		end

		local targets, targetErr = resolveTargets(sender, args[1], true)
		if not targets then
			return false, targetErr or "No target."
		end

		for _, target in targets do
			PlayerDataService.waitUntilLoaded(target)
			local ok, err = PlayerDataService.resetPlayerData(target)
			if not ok then
				return false, string.format("Reset failed for %s: %s", target.Name, err or "unknown")
			end
		end

		return true, string.format("Reset data for %d player(s).", #targets)
	end,
}

commands.reset = commands.resetdata

commands.addcash = {
	usage = "addcash <player|me|all> <amount>",
	description = "Add cash to a player.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] or not args[2] then
			return false, "Usage: " .. commands.addcash.usage
		end
		local amount = tonumber(args[2])
		if not amount then
			return false, "Amount must be a number."
		end
		amount = math.clamp(math.floor(amount), 1, MAX_CASH_GRANT)

		local targets, targetErr = resolveTargets(sender, args[1], true)
		if not targets then
			return false, targetErr or "No target."
		end

		for _, target in targets do
			PlayerDataService.waitUntilLoaded(target)
			local cash = target:GetAttribute("Cash")
			local current = if typeof(cash) == "number" then cash else 0
			target:SetAttribute("Cash", current + amount)
			if target:GetAttribute("PlayerDataLoaded") == true then
				PlayerDataService.savePlayerData(target)
			end
		end

		return true, string.format("Added %d cash to %d player(s).", amount, #targets)
	end,
}

commands.cash = commands.addcash

commands.addluckyblock = {
	usage = "addluckyblock <player|me|all> <blockName> [count] [variant]",
	description = "Grant a lucky block tool.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] or not args[2] then
			return false, "Usage: " .. commands.addluckyblock.usage
		end

		local targets, targetErr = resolveTargets(sender, args[1], true)
		if not targets then
			return false, targetErr or "No target."
		end

		local blockName = args[2]
		local count = 1
		local variant: string? = nil
		if tonumber(args[3]) then
			count = math.clamp(math.floor(tonumber(args[3]) :: number), 1, MAX_GRANT_COUNT)
			variant = args[4]
		else
			variant = args[3]
		end

		local grant = waitForLuckyBlockBindable("GrantLuckyBlock")
		if not grant then
			return false, "Lucky block grant service is not ready."
		end

		local granted = 0
		for _, target in targets do
			PlayerDataService.waitUntilLoaded(target)
			for _ = 1, count do
				local ok = (grant :: BindableFunction):Invoke(target, blockName, {
					equip = true,
					variant = variant,
				})
				if ok then
					granted += 1
				end
			end
		end

		return true, string.format("Granted %d lucky block(s) (%s) to %d player(s).", granted, blockName, #targets)
	end,
}

commands.giveluckyblock = commands.addluckyblock

local function invokeServerSpawn(tierArg: string): (boolean, string)
	local internal = ServerStorage:FindFirstChild("GameInternal")
	local bf = internal and internal:FindFirstChild("ForceServerRaritySpawn")
	if not bf or not bf:IsA("BindableFunction") then
		return false, "Rarity spawn service is not ready."
	end
	local invokeOk, spawnOk, msg = pcall(function()
		return (bf :: BindableFunction):Invoke(tierArg)
	end)
	if not invokeOk then
		return false, "Spawn command failed."
	end
	return spawnOk == true, if typeof(msg) == "string" then msg else (if spawnOk then "Spawned." else "Spawn failed.")
end

commands.serverspawn = {
	usage = "serverspawn <mythic|legendary|godly|secret>",
	description = "Force a rarity spawn on this server only (does not reset timers).",
	run = function(_sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.serverspawn.usage
		end
		return invokeServerSpawn(args[1])
	end,
}

commands.globalspawn = {
	usage = "globalspawn <mythic|legendary|godly|secret>",
	description = "Force a rarity spawn on every server (does not reset timers).",
	run = function(_sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.globalspawn.usage
		end
		local internal = ServerStorage:FindFirstChild("GameInternal")
		local bf = internal and internal:FindFirstChild("BroadcastGlobalRaritySpawn")
		if not bf or not bf:IsA("BindableFunction") then
			return false, "Rarity spawn service is not ready."
		end
		local invokeOk, spawnOk, msg = pcall(function()
			return (bf :: BindableFunction):Invoke(args[1])
		end)
		if not invokeOk then
			return false, "Global spawn command failed."
		end
		return spawnOk == true,
			if typeof(msg) == "string" then msg else (if spawnOk then "Spawned globally." else "Spawn failed.")
	end,
}

commands.spawnglobal = commands.serverspawn

local function runBroadcastCommand(sender: Player, args: { string }, global: boolean): (boolean, string)
	local message = AdminBroadcastService.joinArgs(args)
	if not message then
		local usage = if global then "globalnotif <message>" else "servernotif <message>"
		return false, "Usage: " .. usage
	end
	if global then
		if not AdminBroadcastService.broadcastGlobal(message, sender.Name, sender.UserId) then
			return false, "Failed to send global notification."
		end
		return true, string.format("Global notification sent: %s", message)
	end
	if not AdminBroadcastService.broadcastServer(message, sender.Name, sender.UserId) then
		return false, "Failed to send server notification."
	end
	return true, string.format("Server notification sent: %s", message)
end

commands.servernotif = {
	usage = "servernotif <message>",
	description = "Show a top notification to everyone on this server.",
	run = function(sender: Player, args: { string }): (boolean, string)
		return runBroadcastCommand(sender, args, false)
	end,
}
commands.servernotifs = commands.servernotif

commands.globalnotif = {
	usage = "globalnotif <message>",
	description = "Show a top notification on every server.",
	run = function(sender: Player, args: { string }): (boolean, string)
		return runBroadcastCommand(sender, args, true)
	end,
}
commands.globalnotifs = commands.globalnotif

local shutdownToken = 0
local ADMIN_GLOBAL_LUCK_TOPIC = "AdminGlobalServerLuck_v1"

local function parseLuckMultiplier(raw: string?): number?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local trimmed = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	if trimmed == "off" or trimmed == "clear" or trimmed == "reset" then
		return 1
	end
	trimmed = string.gsub(trimmed, "x$", "")
	local value = tonumber(trimmed)
	if not value or value < 1 then
		return nil
	end
	return value
end

local function parseLuckDuration(raw: string?): number?
	if typeof(raw) ~= "string" or raw == "" then
		return StoreConfig.SERVER_LUCK_DURATION
	end
	local trimmed = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	local num, unit = string.match(trimmed, "^(%d+%.?%d*)%s*([smh]?)$")
	if not num then
		return nil
	end
	local value = tonumber(num)
	if not value or value <= 0 then
		return nil
	end
	if unit == "m" then
		value *= 60
	elseif unit == "h" then
		value *= 3600
	end
	return math.clamp(math.floor(value + 0.5), 1, 86400)
end

local function formatLuckDuration(totalSec: number): string
	local sec = math.max(0, math.floor(totalSec + 0.5))
	if sec >= 3600 then
		local h = math.floor(sec / 3600)
		local m = math.floor((sec % 3600) / 60)
		if m > 0 then
			return string.format("%dh %dm", h, m)
		end
		return string.format("%dh", h)
	end
	if sec >= 60 then
		local m = math.floor(sec / 60)
		local s = sec % 60
		if s > 0 then
			return string.format("%dm %ds", m, s)
		end
		return string.format("%dm", m)
	end
	return string.format("%ds", sec)
end

local function invokeSetServerLuck(multiplier: number, durationSec: number): (boolean, number?, number?)
	local bf = waitForBindable("StoreInternal", "SetServerLuck", 5)
	if not bf then
		return false, nil, nil
	end
	local ok, result = pcall(function()
		return (bf :: BindableFunction):Invoke(multiplier, durationSec)
	end)
	if not ok or typeof(result) ~= "table" or result.ok ~= true then
		return false, nil, nil
	end
	return true,
		if typeof(result.multiplier) == "number" then result.multiplier else nil,
		if typeof(result.remaining) == "number" then result.remaining else nil
end

local function runLuckCommand(sender: Player, args: { string }, global: boolean): (boolean, string)
	local mult = parseLuckMultiplier(args[1])
	if not mult then
		local usage = if global then "globalluck <mult|off> [duration]" else "serverluck <mult|off> [duration]"
		return false, "Usage: " .. usage
	end
	local duration = parseLuckDuration(args[2])
	if not duration then
		return false, "Invalid duration. Use seconds, 5m, or 1h."
	end

	if global then
		-- Apply + announce on this server immediately; other servers follow via MessagingService.
		local ok, applied, remaining = invokeSetServerLuck(mult, duration)
		if not ok then
			return false, "Server luck service is not ready."
		end
		local finalMult = applied or mult
		local finalRemaining = remaining or (if mult <= 1 then 0 else duration)
		local msg = if finalMult <= 1
			then "cleared global luck"
			else string.format("set global luck to %gx for %s", finalMult, formatLuckDuration(finalRemaining))
		AdminBroadcastService.broadcastServer(msg, sender.Name, sender.UserId, 8)

		local pubOk, pubErr = pcall(function()
			MessagingService:PublishAsync(ADMIN_GLOBAL_LUCK_TOPIC, {
				multiplier = mult,
				durationSec = duration,
				sender = sender.Name,
				senderUserId = sender.UserId,
				originJobId = game.JobId,
				sentAt = os.time(),
			})
		end)
		if not pubOk then
			warn("[AdminCommands] globalluck publish failed:", pubErr)
			return true, msg .. " (this server only — global publish failed)"
		end
		return true, if finalMult <= 1 then "Global luck cleared." else string.format("Global luck set to %gx for %s.", finalMult, formatLuckDuration(finalRemaining))
	end

	local ok, applied, remaining = invokeSetServerLuck(mult, duration)
	if not ok then
		return false, "Server luck service is not ready."
	end
	local finalMult = applied or mult
	local finalRemaining = remaining or (if mult <= 1 then 0 else duration)
	local msg = if finalMult <= 1
		then "cleared server luck"
		else string.format("set server luck to %gx for %s", finalMult, formatLuckDuration(finalRemaining))
	AdminBroadcastService.broadcastServer(msg, sender.Name, sender.UserId, 8)
	return true, if finalMult <= 1 then "Server luck cleared." else string.format("Server luck set to %gx for %s.", finalMult, formatLuckDuration(finalRemaining))
end

commands.serverluck = {
	usage = "serverluck <mult|off> [duration]",
	description = "Set luck on THIS server and announce it (username + verified badge).",
	run = function(sender: Player, args: { string }): (boolean, string)
		return runLuckCommand(sender, args, false)
	end,
}
commands.sluck = commands.serverluck

commands.globalluck = {
	usage = "globalluck <mult|off> [duration]",
	description = "Set luck on ALL servers and announce it (username + verified badge).",
	run = function(sender: Player, args: { string }): (boolean, string)
		return runLuckCommand(sender, args, true)
	end,
}
commands.gluck = commands.globalluck

local function parseShutdownSeconds(raw: string?): number?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local trimmed = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	local num, unit = string.match(trimmed, "^(%d+%.?%d*)%s*([smh]?)$")
	if not num then
		return nil
	end
	local value = tonumber(num)
	if not value or value <= 0 then
		return nil
	end
	if unit == "m" then
		value *= 60
	elseif unit == "h" then
		value *= 3600
	end
	return math.clamp(math.floor(value + 0.5), 1, 3600)
end

local function formatCountdown(totalSec: number): string
	local sec = math.max(0, math.floor(totalSec + 0.5))
	if sec >= 3600 then
		local h = math.floor(sec / 3600)
		local m = math.floor((sec % 3600) / 60)
		local s = sec % 60
		return string.format("%dh %dm %ds", h, m, s)
	end
	if sec >= 60 then
		local m = math.floor(sec / 60)
		local s = sec % 60
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", sec)
end

commands.servershutdown = {
	usage = "servershutdown <seconds|30s|5m>",
	description = "Countdown top notif on THIS server, then kick everyone (not global).",
	run = function(sender: Player, args: { string }): (boolean, string)
		local seconds = parseShutdownSeconds(args[1])
		if not seconds then
			return false, "Usage: " .. commands.servershutdown.usage
		end

		shutdownToken += 1
		local token = shutdownToken
		local endsAt = os.clock() + seconds
		local senderName = sender.Name
		local senderUserId = sender.UserId

		task.spawn(function()
			local lastBroadcastAt = -math.huge
			while token == shutdownToken do
				local remaining = math.max(0, math.ceil(endsAt - os.clock()))
				local interval = if remaining <= 10 then 1 elseif remaining <= 60 then 5 else 10
				local now = os.clock()
				if now - lastBroadcastAt >= interval - 0.05 or remaining <= 0 then
					lastBroadcastAt = now
					local msg = if remaining <= 0
						then "Server shutdown — update coming now!"
						else string.format("Server shutdown — update coming in %s", formatCountdown(remaining))
					AdminBroadcastService.broadcastServer(msg, senderName, senderUserId, interval + 1.5)
				end
				if remaining <= 0 then
					break
				end
				task.wait(0.25)
			end

			if token ~= shutdownToken then
				return
			end

			task.wait(0.35)
			for _, plr in Players:GetPlayers() do
				plr:Kick("Server shutdown — update coming. Please rejoin!")
			end
		end)

		return true, string.format("Server shutdown started: %s", formatCountdown(seconds))
	end,
}
commands.shutdown = commands.servershutdown
commands.servershut = commands.servershutdown

local MAX_REASON_LEN = 200
local DEFAULT_KICK_REASON = "You have been kicked by an admin."
local DEFAULT_BAN_REASON = "You have been banned from this experience."

local function joinReason(args: { string }, startIndex: number): string
	if startIndex > #args then
		return ""
	end
	local parts = {}
	for i = startIndex, #args do
		table.insert(parts, args[i])
	end
	local reason = table.concat(parts, " ")
	reason = (string.gsub(reason, "^%s*(.-)%s*$", "%1"))
	if #reason > MAX_REASON_LEN then
		reason = string.sub(reason, 1, MAX_REASON_LEN)
	end
	return reason
end

local function parseBanDuration(raw: string?): number?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local trimmed = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	if trimmed == "forever" or trimmed == "perm" or trimmed == "permanent" or trimmed == "perma" then
		return -1
	end
	local num, unit = string.match(trimmed, "^(%d+%.?%d*)%s*([smhd]?)$")
	if not num then
		return nil
	end
	local value = tonumber(num)
	if not value or value <= 0 then
		return nil
	end
	if unit == "m" then
		value *= 60
	elseif unit == "h" then
		value *= 3600
	elseif unit == "d" then
		value *= 86400
	end
	return math.clamp(math.floor(value + 0.5), 1, 365 * 86400)
end

local function formatBanDuration(durationSec: number): string
	if durationSec < 0 then
		return "permanent"
	end
	return formatCountdown(durationSec)
end

local function canModerateTarget(sender: Player, targetUserId: number, targetPlayer: Player?): (boolean, string?)
	if targetUserId == sender.UserId then
		return false, "You can't moderate yourself."
	end
	if AdminAllowlist.isAllowed(targetUserId) then
		return false, "You can't moderate an allowlisted admin."
	end
	if targetPlayer and AdminAllowlist.isPlayerAllowed(targetPlayer) then
		return false, "You can't moderate another admin."
	end
	return true, nil
end

local function resolveUserIdForModeration(sender: Player, query: string): (number?, string?, Player?)
	local targets, targetErr = resolveTargets(sender, query, false)
	if targets and #targets == 1 then
		local plr = targets[1]
		return plr.UserId, plr.Name, plr
	end
	local asId = tonumber(query)
	if asId and asId == math.floor(asId) and asId > 0 then
		local online = Players:GetPlayerByUserId(asId)
		return math.floor(asId), if online then online.Name else tostring(math.floor(asId)), online
	end
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(query)
	end)
	if ok and typeof(userId) == "number" then
		local online = Players:GetPlayerByUserId(userId)
		return userId, query, online
	end
	return nil, targetErr or "Player not found.", nil
end

commands.kick = {
	usage = "kick <player> [reason]",
	description = "Kick a player from this server.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.kick.usage
		end
		local targets, targetErr = resolveTargets(sender, args[1], false)
		if not targets then
			return false, targetErr or "Player not found."
		end
		if #targets ~= 1 then
			return false, "Kick only supports one player at a time."
		end
		local target = targets[1]
		local allowed, denyReason = canModerateTarget(sender, target.UserId, target)
		if not allowed then
			return false, denyReason or "Not allowed."
		end
		local reason = joinReason(args, 2)
		if reason == "" then
			reason = DEFAULT_KICK_REASON
		end
		local ok, err = pcall(function()
			target:Kick(reason)
		end)
		if not ok then
			warn("[AdminCommands] kick failed:", err)
			return false, "Kick failed."
		end
		return true, string.format("Kicked %s.", target.Name)
	end,
}

commands.ban = {
	usage = "ban <player|userid> [duration|forever] [reason]",
	description = "Ban a player from the experience (BanAsync). Duration like 1h, 7d, or forever.",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.ban.usage
		end
		local userId, displayName, onlinePlayer = resolveUserIdForModeration(sender, args[1])
		if not userId then
			return false, displayName or "Player not found."
		end
		local allowed, denyReason = canModerateTarget(sender, userId, onlinePlayer)
		if not allowed then
			return false, denyReason or "Not allowed."
		end

		local duration = -1
		local reasonStart = 2
		local maybeDuration = parseBanDuration(args[2])
		if maybeDuration ~= nil then
			duration = maybeDuration
			reasonStart = 3
		end
		local reason = joinReason(args, reasonStart)
		if reason == "" then
			reason = DEFAULT_BAN_REASON
		end

		local privateReason = string.format(
			"Banned by %s (%d). Duration=%s. Reason=%s",
			sender.Name,
			sender.UserId,
			formatBanDuration(duration),
			reason
		)
		local ok, err = pcall(function()
			Players:BanAsync({
				UserIds = { userId },
				ApplyToUniverse = true,
				Duration = duration,
				DisplayReason = reason,
				PrivateReason = privateReason,
				ExcludeAltAccounts = false,
			})
		end)
		if not ok then
			warn("[AdminCommands] BanAsync failed:", err)
			return false, "Ban failed. Make sure experience banning is enabled in Studio."
		end
		return true, string.format("Banned %s (%s).", displayName or tostring(userId), formatBanDuration(duration))
	end,
}

commands.unban = {
	usage = "unban <player|userid>",
	description = "Remove an experience ban (UnbanAsync).",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.unban.usage
		end
		local userId, displayName = resolveUserIdForModeration(sender, args[1])
		if not userId then
			return false, displayName or "Player not found."
		end
		local ok, err = pcall(function()
			Players:UnbanAsync({
				UserIds = { userId },
				ApplyToUniverse = true,
			})
		end)
		if not ok then
			warn("[AdminCommands] UnbanAsync failed:", err)
			return false, "Unban failed. Make sure experience banning is enabled in Studio."
		end
		return true, string.format("Unbanned %s.", displayName or tostring(userId))
	end,
}

commands.rebirth = {
	usage = "rebirth [player|me]",
	description = "Force rebirth (skips requirements).",
	run = function(sender: Player, args: { string }): (boolean, string)
		local targetToken = args[1] or "me"
		local targets, targetErr = resolveTargets(sender, targetToken, false)
		if not targets then
			return false, targetErr or "No target."
		end
		if #targets ~= 1 then
			return false, "Rebirth only supports one player at a time."
		end

		local perform = waitForBindable("RebirthInternal", "PerformRebirth", 30)
		if not perform then
			return false, "Rebirth service is not ready."
		end

		local target = targets[1]
		PlayerDataService.waitUntilLoaded(target)
		local invokeOk, ok, err = pcall(function()
			return (perform :: BindableFunction):Invoke(target, {
				skipRequirements = true,
				keepUpgrades = false,
			})
		end)
		if not invokeOk then
			warn("[AdminCommands] rebirth invoke error:", ok)
			return false, "Rebirth invoke failed. Check server output."
		end
		if not ok then
			if err == "max_rebirth" then
				return false, string.format("%s is already at max rebirth (%d).", target.Name, RebirthConfig.MAX_TIER)
			end
			return false, string.format("Rebirth failed for %s: %s", target.Name, tostring(err or "unknown"))
		end
		if target:GetAttribute("PlayerDataLoaded") == true then
			PlayerDataService.savePlayerData(target)
		end
		local count = RebirthConfig.getRebirthCount(target)
		return true, string.format("Rebirthed %s (now rebirth %d).", target.Name, count)
	end,
}

commands.playtutorial = {
	usage = "playtutorial",
	description = "Replay the first-join tutorial for yourself.",
	run = function(sender: Player, _args: { string }): (boolean, string)
		PlayerDataService.waitUntilLoaded(sender)
		PlayerDataService.replayTutorial(sender)
		return true, "Tutorial restarted."
	end,
}
commands.tutorial = commands.playtutorial
commands.replaytutorial = commands.playtutorial

commands.fly = {
	usage = "fly",
	description = "Toggle fly mode for yourself.",
	run = function(sender: Player, _args: { string }): (boolean, string)
		local enabled = sender:GetAttribute("AdminFlyEnabled") == true
		if not enabled then
			-- Don't fly while spectating.
			sender:SetAttribute("AdminSpectateUserId", nil)
		end
		sender:SetAttribute("AdminFlyEnabled", if enabled then nil else true)
		if enabled then
			return true, "Fly disabled."
		end
		return true, "Fly enabled. WASD move, Space/E up, Ctrl/Q down."
	end,
}

commands.spectate = {
	usage = "spectate <player> | spectate off",
	description = "Spectate another player. Press X (or spectate off) to exit.",
	run = function(sender: Player, args: { string }): (boolean, string)
		local token = args[1]
		if not token then
			return false, "Usage: " .. commands.spectate.usage
		end
		local lower = string.lower(token)
		if lower == "off" or lower == "stop" or lower == "end" or lower == "none" then
			sender:SetAttribute("AdminSpectateUserId", nil)
			return true, "Spectate ended."
		end

		local targets, targetErr = resolveTargets(sender, token, false)
		if not targets then
			return false, targetErr or "Player not found."
		end
		if #targets ~= 1 then
			return false, "Spectate only supports one player at a time."
		end
		local target = targets[1]
		if target == sender then
			sender:SetAttribute("AdminSpectateUserId", nil)
			return true, "Spectate ended."
		end
		if not target.Character or not target.Character:FindFirstChildOfClass("Humanoid") then
			return false, string.format("%s has no character to spectate.", target.Name)
		end

		sender:SetAttribute("AdminFlyEnabled", nil)
		sender:SetAttribute("AdminSpectateUserId", target.UserId)
		return true, string.format("Spectating %s. Press X to exit.", target.Name)
	end,
}
commands.spec = commands.spectate
commands.unspectate = {
	usage = "unspectate",
	description = "Stop spectating.",
	run = function(sender: Player, _args: { string }): (boolean, string)
		sender:SetAttribute("AdminSpectateUserId", nil)
		return true, "Spectate ended."
	end,
}

local function runCommand(sender: Player, raw: any): { ok: boolean, message: string }
	if not AdminAllowlist.isPlayerAllowed(sender) then
		warn("[AdminCommands] blocked admin invoke from", sender.Name, sender.UserId)
		return { ok = false, message = "You are not allowed to use admin commands." }
	end
	if typeof(raw) ~= "string" or raw == "" then
		return { ok = false, message = "Type 'help' for commands." }
	end

	local words = splitWords(raw)
	local commandName = string.lower(words[1] or "")
	table.remove(words, 1)

	local command = commands[commandName]
	if not command then
		return { ok = false, message = "Unknown command. Type 'help'." }
	end

	local ok, resultOk, resultMessage = pcall(function()
		return command.run(sender, words)
	end)
	if not ok then
		warn("[AdminCommands] command failed:", commandName, resultOk)
		return { ok = false, message = "Command errored. Check server output." }
	end
	return { ok = resultOk == true, message = tostring(resultMessage or "") }
end

Players.PlayerRemoving:Connect(function(leaving)
	leaving:SetAttribute("AdminSpectateUserId", nil)
	leaving:SetAttribute("AdminFlyEnabled", nil)
end)

commandRF.OnServerInvoke = function(sender: Player, raw: any)
	return runCommand(sender, raw)
end

catalogRF.OnServerInvoke = function(sender: Player)
	if not AdminAllowlist.isPlayerAllowed(sender) then
		return { allowed = false }
	end
	return buildAutocompleteCatalog(sender)
end
