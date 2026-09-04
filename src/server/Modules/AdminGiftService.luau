-- [ACTIVE] AdminGiftService
--[[
	Grant brainrots / lucky blocks / gears, then play a sky-drop on the recipient.
	`global` fans out to every live server (online players only).
]]

local Debris = game:GetService("Debris")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AdminGiftConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminGiftConfig"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local Brainrots = require(script.Parent:WaitForChild("Brainrots"))
local GearService = require(script.Parent:WaitForChild("GearService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local M = {}

export type GiftSpec = {
	kind: "brainrot" | "luckyBlock" | "gear",
	id: string,
	mutation: string?,
	level: number?,
	count: number?,
	variant: string?,
	reason: string?,
}

type VisualPayload = {
	kind: string,
	id: string,
	displayName: string,
	rarity: string,
	reason: string,
	variant: string?,
	templateName: string?,
}

local dropRE: RemoteEvent? = nil
local messagingReady = false
local started = false
local templateSerial = 0

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

local function ensureEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = folder
	return ev
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

local function resolveLuckyBlock(name: string): string?
	for _, id in LuckyBlockCatalog.allIds() do
		if string.lower(id) == string.lower(name) or normalizeKey(id) == normalizeKey(name) then
			return id
		end
		local display = LuckyBlockCatalog.displayName(id)
		if string.lower(display) == string.lower(name) or normalizeKey(display) == normalizeKey(name) then
			return id
		end
	end
	return nil
end

local function resolveGear(raw: string): any
	local asNum = tonumber(raw)
	if asNum then
		return GearConfig.get(math.floor(asNum))
	end
	local key = normalizeKey(raw)
	for _, def in GearConfig.GEARS do
		if normalizeKey(def.name) == key or normalizeKey(def.assetName) == key then
			return def
		end
	end
	return nil
end

local function waitForBindable(folderName: string, bindableName: string, timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 8)
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

local function visualFor(spec: GiftSpec): VisualPayload?
	local reason = spec.reason or AdminGiftConfig.REASON_ADMIN
	if spec.kind == "brainrot" then
		local def = resolveBrainrot(spec.id)
		if not def then
			return nil
		end
		return {
			kind = "brainrot",
			id = def.name,
			displayName = def.name,
			rarity = def.rarity,
			reason = reason,
		}
	elseif spec.kind == "luckyBlock" then
		local blockId = resolveLuckyBlock(spec.id)
		if not blockId then
			return nil
		end
		local cat = LuckyBlockCatalog.get(blockId)
		return {
			kind = "luckyBlock",
			id = blockId,
			displayName = LuckyBlockCatalog.displayName(blockId),
			rarity = if cat then cat.indexRarity else "legendary",
			reason = reason,
			variant = spec.variant,
		}
	elseif spec.kind == "gear" then
		local def = resolveGear(spec.id)
		if not def then
			return nil
		end
		return {
			kind = "gear",
			id = tostring(def.id),
			displayName = def.name,
			rarity = def.rarity,
			reason = reason,
		}
	end
	return nil
end

function M.parseReward(kindRaw: any, idRaw: any): (GiftSpec?, string?)
	if typeof(kindRaw) ~= "string" or typeof(idRaw) ~= "string" then
		return nil, "Need a reward kind and id."
	end
	local kind = string.lower(kindRaw)
	local id = string.gsub(idRaw, "^%s*(.-)%s*$", "%1")
	if id == "" then
		return nil, "Reward id is empty."
	end
	if kind == "brainrot" or kind == "br" then
		local def = resolveBrainrot(id)
		if not def then
			return nil, "Unknown brainrot."
		end
		return { kind = "brainrot", id = def.name }, nil
	elseif kind == "luckyblock" or kind == "lucky" or kind == "block" or kind == "lb" then
		local blockId = resolveLuckyBlock(id)
		if not blockId then
			return nil, "Unknown lucky block."
		end
		return { kind = "luckyBlock", id = blockId }, nil
	elseif kind == "gear" then
		local def = resolveGear(id)
		if not def then
			return nil, "Unknown gear."
		end
		return { kind = "gear", id = tostring(def.id) }, nil
	end
	return nil, "Reward kind must be brainrot, luckyBlock, or gear."
end

function M.labelFor(spec: GiftSpec): string
	local vis = visualFor(spec)
	return if vis then vis.displayName else spec.id
end

local function templateFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(AdminGiftConfig.TEMPLATE_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = AdminGiftConfig.TEMPLATE_FOLDER
	folder.Parent = ReplicatedStorage
	return folder
end

local function stripClone(model: Model)
	local remove: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			table.insert(remove, d)
		end
	end
	for _, d in remove do
		d:Destroy()
	end
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
end

local function cloneBrainrotTemplate(name: string, mutation: string?): Model?
	local root = Brainrots.getBrainrotsFolder()
	if not root then
		return nil
	end
	local nameFolder = Brainrots.findBrainrotStorageFolder(root, name)
	if not nameFolder then
		return nil
	end
	local template: Model? = nil
	for _, variantName in ipairs(Brainrots.mutationTemplateCandidateNames(mutation or "normal")) do
		local v = nameFolder:FindFirstChild(variantName)
		if v and v:IsA("Model") then
			template = v
			break
		end
		if v then
			local nested = v:FindFirstChildWhichIsA("Model")
			if nested then
				template = nested
				break
			end
		end
	end
	if not template then
		local normal = nameFolder:FindFirstChild("Normal")
		if normal and normal:IsA("Model") then
			template = normal
		else
			template = nameFolder:FindFirstChildWhichIsA("Model", true)
		end
	end
	if not template then
		return nil
	end
	local clone = template:Clone()
	templateSerial += 1
	clone.Name = "AdminGiftDrop_" .. tostring(templateSerial)
	stripClone(clone)
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	clone.Parent = templateFolder()
	return clone
end

local function present(player: Player, spec: GiftSpec)
	if not dropRE then
		dropRE = ensureEvent(AdminGiftConfig.DROP_REMOTE)
	end
	local vis = visualFor(spec)
	if not vis then
		return
	end
	local template: Model? = nil
	if spec.kind == "brainrot" then
		template = cloneBrainrotTemplate(spec.id, spec.mutation)
	end
	if template then
		vis.templateName = template.Name
		-- Replication must land before FireClient or the client gets nil.
		task.delay(0.15, function()
			if not player.Parent then
				if template.Parent then
					template:Destroy()
				end
				return
			end
			if not dropRE then
				return
			end
			dropRE:FireClient(player, vis, template)
			Debris:AddItem(template, 10)
		end)
	else
		dropRE:FireClient(player, vis)
	end
end

local function grantBrainrot(player: Player, spec: GiftSpec): number
	local def = resolveBrainrot(spec.id)
	if not def then
		return 0
	end
	local grant = waitForBindable("BrainrotInternal", "GrantBrainrotAndEquip", 5)
	if not grant then
		warn("[AdminGiftService] GrantBrainrotAndEquip missing")
		return 0
	end
	local count = math.clamp(math.floor(spec.count or 1), 1, AdminGiftConfig.MAX_COUNT)
	local mutation = spec.mutation or "normal"
	local level = math.max(1, math.floor(spec.level or 1))
	local granted = 0
	for _ = 1, count do
		local ok, result = pcall(function()
			return grant:Invoke(player, {
				name = def.name,
				rarity = def.rarity,
				baseIncome = def.baseIncome,
				mutation = mutation,
				level = level,
			}, {
				equip = false,
			})
		end)
		if not ok then
			warn("[AdminGiftService] brainrot grant failed:", result)
		elseif result then
			granted += 1
		end
	end
	return granted
end

local function grantLuckyBlock(player: Player, spec: GiftSpec): number
	local blockId = resolveLuckyBlock(spec.id)
	if not blockId then
		return 0
	end
	local grant = waitForBindable("LuckyBlockInternal", "GrantLuckyBlock", 5)
	if not grant then
		warn("[AdminGiftService] GrantLuckyBlock missing")
		return 0
	end
	local count = math.clamp(math.floor(spec.count or 1), 1, AdminGiftConfig.MAX_COUNT)
	local variant = spec.variant
	if typeof(variant) ~= "string" or variant == "" then
		variant = LuckyBlockCatalog.defaultVariant(blockId)
	end
	local granted = 0
	for _ = 1, count do
		local ok, result = pcall(function()
			return grant:Invoke(player, blockId, {
				equip = false,
				variant = variant,
			})
		end)
		if not ok then
			warn("[AdminGiftService] lucky block grant failed:", result)
		elseif result then
			granted += 1
		end
	end
	return granted
end

local function grantGear(player: Player, spec: GiftSpec): number
	local def = resolveGear(spec.id)
	if not def then
		return 0
	end
	for i = 1, def.id do
		GearService.grantGear(player, i, false)
	end
	return 1
end

function M.giveToPlayer(player: Player, spec: GiftSpec): (boolean, string?)
	if not player.Parent then
		return false, "Player left."
	end
	PlayerDataService.waitUntilLoaded(player)
	if spec.kind == "brainrot" and not resolveBrainrot(spec.id) then
		return false, "Unknown brainrot."
	elseif spec.kind == "luckyBlock" and not resolveLuckyBlock(spec.id) then
		return false, "Unknown lucky block."
	elseif spec.kind == "gear" and not resolveGear(spec.id) then
		return false, "Unknown gear."
	end
	present(player, spec)

	local finished = false
	local function commitGrant()
		if finished then
			return
		end
		finished = true
		if not player.Parent then
			return
		end
		local granted = 0
		if spec.kind == "brainrot" then
			granted = grantBrainrot(player, spec)
		elseif spec.kind == "luckyBlock" then
			granted = grantLuckyBlock(player, spec)
		elseif spec.kind == "gear" then
			granted = grantGear(player, spec)
		end
		if granted <= 0 then
			warn("[AdminGiftService] delayed grant failed for", player.Name, spec.kind, spec.id)
			return
		end
		if player:GetAttribute("PlayerDataLoaded") == true then
			PlayerDataService.savePlayerData(player)
		end
	end

	local leavingConn: RBXScriptConnection? = nil
	leavingConn = Players.PlayerRemoving:Connect(function(leaving)
		if leaving ~= player then
			return
		end
		if leavingConn then
			leavingConn:Disconnect()
			leavingConn = nil
		end
		commitGrant()
	end)
	task.delay(AdminGiftConfig.GRANT_DELAY_SEC, function()
		if leavingConn then
			leavingConn:Disconnect()
			leavingConn = nil
		end
		commitGrant()
	end)
	return true, M.labelFor(spec)
end

function M.giveToOnline(spec: GiftSpec): number
	local n = 0
	for _, player in Players:GetPlayers() do
		local ok = M.giveToPlayer(player, spec)
		if ok then
			n += 1
		end
	end
	return n
end

function M.publishGlobal(spec: GiftSpec)
	if not messagingReady then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(AdminGiftConfig.MESSAGING_TOPIC, {
				originJobId = game.JobId,
				spec = spec,
			})
		end)
		if not ok then
			warn("[AdminGiftService] global publish failed:", err)
		end
	end)
end

function M.start()
	if started then
		return
	end
	started = true
	dropRE = ensureEvent(AdminGiftConfig.DROP_REMOTE)
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(AdminGiftConfig.MESSAGING_TOPIC, function(packet)
				if typeof(packet) ~= "table" or typeof(packet.Data) ~= "table" then
					return
				end
				local data = packet.Data
				if typeof(data.originJobId) == "string" and data.originJobId == game.JobId then
					return
				end
				if typeof(data.spec) ~= "table" then
					return
				end
				local spec = data.spec :: GiftSpec
				if spec.kind ~= "brainrot" and spec.kind ~= "luckyBlock" and spec.kind ~= "gear" then
					return
				end
				if typeof(spec.id) ~= "string" then
					return
				end
				M.giveToOnline(spec)
			end)
		end)
		if ok then
			messagingReady = true
		else
			warn("[AdminGiftService] MessagingService subscribe failed:", err)
		end
	end)
end

return M
