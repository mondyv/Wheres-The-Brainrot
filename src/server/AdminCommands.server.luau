-- [ACTIVE] AdminCommands.server
-- Server-authoritative admin command runner used by the F5 command bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AdminAllowlist = require(script.Parent:WaitForChild("Modules"):WaitForChild("AdminAllowlist"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local RebirthConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RebirthConfig"))

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
		table.insert(players, plr.Name)
		if plr.DisplayName ~= plr.Name then
			table.insert(players, plr.DisplayName)
		end
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
			"Commands: addinventory, addcash, addluckyblock, resetdata, rebirth, help"
	end,
}

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

commands.rebirth = {
	usage = "rebirth <player|me>",
	description = "Force rebirth (skips requirements).",
	run = function(sender: Player, args: { string }): (boolean, string)
		if not args[1] then
			return false, "Usage: " .. commands.rebirth.usage
		end

		local targets, targetErr = resolveTargets(sender, args[1], false)
		if not targets then
			return false, targetErr or "No target."
		end
		if #targets ~= 1 then
			return false, "Rebirth only supports one player at a time."
		end

		local perform = waitForRebirthBindable("PerformRebirth")
		if not perform then
			return false, "Rebirth service is not ready."
		end

		local target = targets[1]
		PlayerDataService.waitUntilLoaded(target)
		local ok, err = (perform :: BindableFunction):Invoke(target, {
			skipRequirements = true,
		})
		if not ok then
			if err == "max_rebirth" then
				return false, string.format("%s is already at max rebirth (%d).", target.Name, RebirthConfig.MAX_TIER)
			end
			return false, string.format("Rebirth failed for %s: %s", target.Name, tostring(err))
		end
		return true, string.format("Rebirthed %s.", target.Name)
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

commandRF.OnServerInvoke = function(sender: Player, raw: any)
	return runCommand(sender, raw)
end

catalogRF.OnServerInvoke = function(sender: Player)
	if not AdminAllowlist.isPlayerAllowed(sender) then
		return { allowed = false }
	end
	return buildAutocompleteCatalog(sender)
end
