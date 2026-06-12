-- [ACTIVE] AdminCommands.server
-- Server-authoritative admin command runner used by the F5 command bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AdminAllowlist = require(script.Parent:WaitForChild("Modules"):WaitForChild("AdminAllowlist"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

local COMMAND_REMOTE_NAME = "AdminCommand"
-- Replicated flag: true only when server allowlist grants access (clients cannot forge this).
local ADMIN_ALLOWED_ATTR = "AdminPanelAllowed"
local MAX_GRANT_COUNT = 25

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

local function syncAdminAccess(player: Player)
	if AdminAllowlist.isPlayerAllowed(player) then
		player:SetAttribute(ADMIN_ALLOWED_ATTR, true)
	end
end

Players.PlayerAdded:Connect(syncAdminAccess)
for _, plr in Players:GetPlayers() do
	syncAdminAccess(plr)
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

local function waitForBrainrotBindable(name: string): BindableFunction?
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		local folder = ServerStorage:FindFirstChild("BrainrotInternal")
		local bf = folder and folder:FindFirstChild(name)
		if bf and bf:IsA("BindableFunction") then
			return bf
		end
		task.wait(0.1)
	end
	return nil
end

local commands = {}

commands.help = {
	usage = "help",
	description = "List admin commands.",
	run = function(_sender: Player, _args: { string }): (boolean, string)
		return true,
			"Commands: addinventory <player|me|all> <brainrot> [count] [mutation] [level], resetdata <player|me|all>, help"
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
