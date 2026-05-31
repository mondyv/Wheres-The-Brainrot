--[[
	LuckyBlock.server
	Authority for the Star-Rainbow lucky block tool.

	Exposes ServerStorage.LuckyBlockInternal.GrantLuckyBlock(player, blockName) so other
	systems (Daily Day 7) can hand the player the tool.

	Client → server flow when the equipped lucky block is clicked:
	  1. Client fires LuckyBlockRoll RemoteEvent with the tool reference.
	  2. Server validates ownership + cooldown, picks the brainrot to grant, and replies
	     with a LuckyBlockShakeStart event ({ durationSec, brainrotName, rarity }).
	  3. After the shake elapses server destroys the tool, fires the brainrot SFX, and
	     hands the brainrot through BrainrotInternal.GrantBrainrotAndEquip so it auto-
	     equips in the player's hand, triggers Index unlock, and pushes inventory sync.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))

local SHAKE_DURATION_SEC = 2.4

-- Roll weights for the brainrot that pops out of the lucky block.
local RARITY_WEIGHTS: { [string]: number } = {
	mythic = 60,
	legendary = 30,
	["brainrot god"] = 10,
}

-- ── Remotes ─────────────────────────────────────────────────────────────────

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("LuckyBlockRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "LuckyBlockRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local rollRE = ensureRemoteEvent("LuckyBlockRoll")
local shakeStartRE = ensureRemoteEvent("LuckyBlockShakeStart")

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function brainrotInternalBF(name: string): BindableFunction?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		return nil
	end
	local bf = folder:FindFirstChild(name)
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

local function ensurePlayBrainrotSFXRemote(): RemoteEvent?
	local existing = ReplicatedStorage:FindFirstChild("PlayBrainrotSFX")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	return nil
end

local function findLuckyBlocksRoot(): Folder?
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	if not root then
		return nil
	end
	local list = root:FindFirstChild("lucky blocks")
	if list and list:IsA("Folder") then
		return list
	end
	return nil
end

local function findStarRainbowTemplate(): Model?
	local root = findLuckyBlocksRoot()
	if not root then
		return nil
	end
	local star = root:FindFirstChild("star")
	local target = star and star:FindFirstChild("star rainbow")
	if target and target:IsA("Model") then
		return target
	end
	-- Fallback: any descendant whose name contains "rainbow".
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") and string.find(string.lower(d.Name), "rainbow", 1, true) then
			return d
		end
	end
	return nil
end

local function findLuckyBlockTemplate(blockName: string?): Model?
	if not blockName or blockName == "star rainbow" or blockName == "" then
		return findStarRainbowTemplate()
	end
	local root = findLuckyBlocksRoot()
	if not root then
		return nil
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") and d.Name == blockName then
			return d
		end
	end
	return nil
end

local function getMainPart(model: Model): BasePart?
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end
	for _, name in { "Handle", "Main", "Root" } do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			return d
		end
	end
	return nil
end

local function pickIconFromModel(model: Model): string
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ImageLabel") and d.Image ~= "" then
			return d.Image
		end
	end
	return ""
end

local function resolveStarRainbowIconId(): string
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	local icons = root and root:FindFirstChild("Lucky Block Icons")
	if not icons then
		return ""
	end
	for _, name in { "star rainbow", "Star Rainbow", "star_rainbow" } do
		local node = icons:FindFirstChild(name, true)
		if node then
			if node:IsA("ImageLabel") and node.Image ~= "" then
				return node.Image
			end
			if node:IsA("ImageButton") and node.Image ~= "" then
				return node.Image
			end
			for _, d in node:GetDescendants() do
				if d:IsA("ImageLabel") and d.Image ~= "" then
					return d.Image
				end
			end
		end
	end
	for _, d in icons:GetDescendants() do
		if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image ~= "" then
			if string.find(string.lower(d.Name), "rainbow", 1, true)
				or string.find(string.lower(d:GetFullName()), "rainbow", 1, true)
			then
				return d.Image
			end
		end
	end
	return ""
end

local function buildLuckyBlockTool(template: Model, blockName: string): Tool?
	local clone = template:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	local main = getMainPart(clone)
	if not main then
		clone:Destroy()
		return nil
	end

	local parts: { BasePart } = {}
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	local tool = Instance.new("Tool")
	tool.Name = "Lucky Block"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = false
	tool:SetAttribute("LuckyBlockTool", true)
	tool:SetAttribute("LuckyBlockKind", blockName)

	local icon = pickIconFromModel(template)
	if icon == "" then
		icon = resolveStarRainbowIconId()
	end
	if icon ~= "" then
		pcall(function()
			tool.TextureId = icon
		end)
	end

	main.Name = "Handle"
	main.Anchored = false
	main.Massless = true
	main.CanCollide = false
	main.Parent = tool

	for _, p in ipairs(parts) do
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

	tool.Grip = CFrame.new()
	clone:Destroy()
	return tool
end

local function findEquippedOrBackpackLuckyBlock(player: Player): Tool?
	local char = player.Character
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
				return c
			end
		end
	end
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
				return c
			end
		end
	end
	return nil
end

local function destroyAllLuckyBlocks(player: Player)
	local char = player.Character
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
				c:Destroy()
			end
		end
	end
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
				c:Destroy()
			end
		end
	end
end

local function pickRarityWeighted(): string
	local total = 0
	for _, w in pairs(RARITY_WEIGHTS) do
		total += w
	end
	local r = math.random() * total
	local acc = 0
	for rarity, w in pairs(RARITY_WEIGHTS) do
		acc += w
		if r <= acc then
			return rarity
		end
	end
	return "mythic"
end

local function pickRandomBrainrotByRarity(rarity: string): { name: string, rarity: string, baseIncome: number }?
	local candidates = {}
	for _, def in ipairs(Brainrots.BRAINROTS) do
		if def.rarity == rarity then
			table.insert(candidates, def)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

-- ── Grant API for other systems ─────────────────────────────────────────────

local function ensureInternalFolder(): Folder
	local existing = ServerStorage:FindFirstChild("LuckyBlockInternal")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LuckyBlockInternal"
	folder.Parent = ServerStorage
	return folder
end

local internal = ensureInternalFolder()

local function ensureBindable(name: string): BindableFunction
	local existing = internal:FindFirstChild(name)
	if existing and existing:IsA("BindableFunction") then
		return existing
	end
	local bf = Instance.new("BindableFunction")
	bf.Name = name
	bf.Parent = internal
	return bf
end

local grantBF = ensureBindable("GrantLuckyBlock")
grantBF.OnInvoke = function(plrArg: any, blockNameArg: any, optsArg: any): boolean
	if typeof(plrArg) ~= "Instance" or not (plrArg :: Instance):IsA("Player") then
		return false
	end
	local plr = plrArg :: Player
	local blockName = if typeof(blockNameArg) == "string" then blockNameArg else "star rainbow"
	local shouldEquip = true
	if typeof(optsArg) == "table" and optsArg.equip == false then
		shouldEquip = false
	end

	local template = findLuckyBlockTemplate(blockName)
	if not template then
		warn("[LuckyBlock] No template found for", blockName)
		return false
	end
	local tool = buildLuckyBlockTool(template, blockName)
	if not tool then
		return false
	end
	local bp = plr:FindFirstChildOfClass("Backpack")
	if not bp then
		tool:Destroy()
		return false
	end
	tool.Parent = bp
	if shouldEquip then
		local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			pcall(function()
				(hum :: Humanoid):EquipTool(tool)
			end)
		end
	end
	return true
end

-- ── Click → roll handler ────────────────────────────────────────────────────

local rollInFlight: { [Player]: boolean } = {}

local function tryRoll(player: Player)
	if rollInFlight[player] then
		return
	end
	local tool = findEquippedOrBackpackLuckyBlock(player)
	if not tool then
		return
	end
	local pick: any = nil
	for _ = 1, 4 do
		local rarity = pickRarityWeighted()
		local def = pickRandomBrainrotByRarity(rarity)
		if def then
			pick = def
			break
		end
	end
	if not pick then
		return
	end

	rollInFlight[player] = true

	-- Lock the tool from being clicked again mid-shake.
	tool:SetAttribute("LuckyBlockRolling", true)
	pcall(function()
		(tool :: Tool).Enabled = false
	end)

	shakeStartRE:FireClient(player, {
		durationSec = SHAKE_DURATION_SEC,
		brainrotName = pick.name,
		rarity = pick.rarity,
	})

	task.delay(SHAKE_DURATION_SEC, function()
		rollInFlight[player] = nil
		destroyAllLuckyBlocks(player)

		local grant = brainrotInternalBF("GrantBrainrotAndEquip")
		if grant then
			pcall(function()
				grant:Invoke(player, {
					name = pick.name,
					rarity = pick.rarity,
					mutation = "normal",
					level = 1,
					baseIncome = pick.baseIncome,
				}, { equip = true })
			end)
		end

		local sfxRE = ensurePlayBrainrotSFXRemote()
		if sfxRE then
			sfxRE:FireClient(player, pick.name)
		end
	end)
end

rollRE.OnServerEvent:Connect(function(player: Player)
	tryRoll(player)
end)

Players.PlayerRemoving:Connect(function(player)
	rollInFlight[player] = nil
end)
