-- [ACTIVE] LuckyBlock.server
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
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local SHAKE_DURATION_SEC = 2.4

-- Default roll weights for the brainrot that pops out of the (star rainbow) lucky block.
local RARITY_WEIGHTS: { [string]: number } = {
	mythic = 60,
	legendary = 30,
	["brainrot god"] = 10,
}

-- Booster-pack lucky blocks roll from their own rarity pools (see StoreConfig).
local RARITY_WEIGHTS_BY_KIND: { [string]: { [string]: number } } = StoreConfig.LUCKY_BLOCK_RARITY_WEIGHTS

local function weightsForKind(kind: string?): { [string]: number }
	if typeof(kind) == "string" and RARITY_WEIGHTS_BY_KIND[kind] then
		return RARITY_WEIGHTS_BY_KIND[kind]
	end
	return RARITY_WEIGHTS
end

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

local function firstModelChild(container: Instance): Model?
	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("Model") then
			return c
		end
	end
	return nil
end

-- Booster-pack lucky blocks live under a *container* (e.g. "Starter Lucky Block")
-- whose children are the visual variants ("basic", "blue", "67", …). The actual tool
-- model is one of those variants, so when a variant is supplied we resolve it; if the
-- named node is already a leaf Model we use it directly.
local function findLuckyBlockTemplate(blockName: string?, variant: string?): Model?
	if not blockName or blockName == "star rainbow" or blockName == "" then
		return findStarRainbowTemplate()
	end
	local root = findLuckyBlocksRoot()
	if not root then
		return nil
	end

	-- Locate the node named blockName (any class — Folder or Model container).
	local node: Instance? = root:FindFirstChild(blockName)
	if not node then
		for _, d in ipairs(root:GetDescendants()) do
			if d.Name == blockName then
				node = d
				break
			end
		end
	end

	if node then
		local childModel = firstModelChild(node)
		if childModel then
			-- node is a container of variant models — pick the requested variant.
			if typeof(variant) == "string" and variant ~= "" then
				local exact = node:FindFirstChild(variant)
				if exact and exact:IsA("Model") then
					return exact
				end
				local lower = string.lower(variant)
				for _, d in ipairs(node:GetDescendants()) do
					if d:IsA("Model") and string.lower(d.Name) == lower then
						return d
					end
				end
				warn("[LuckyBlock] variant", variant, "not found in", blockName, "— using first child Model")
			end
			return childModel
		end
		if node:IsA("Model") then
			return node :: Model
		end
	end

	-- Legacy fallback: any descendant Model named exactly blockName.
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
	local function readIconNode(node: Instance): string
		if node:IsA("ImageLabel") and node.Image ~= "" then
			return node.Image
		end
		if node:IsA("ImageButton") and node.Image ~= "" then
			return node.Image
		end
		if node:IsA("Decal") and node.Texture ~= "" then
			return node.Texture
		end
		if node:IsA("BillboardGui") or node:IsA("SurfaceGui") then
			for _, d in node:GetDescendants() do
				if d:IsA("ImageLabel") and d.Image ~= "" then
					return d.Image
				end
				if d:IsA("ImageButton") and d.Image ~= "" then
					return d.Image
				end
			end
		end
		return ""
	end

	local iconNode = model:FindFirstChild("Icon")
	if iconNode then
		local tex = readIconNode(iconNode)
		if tex ~= "" then
			return tex
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d.Name == "Icon" then
			local tex = readIconNode(d)
			if tex ~= "" then
				return tex
			end
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ImageLabel") and d.Image ~= "" then
			return d.Image
		end
	end
	return ""
end

local function getActivatedLuckyBlock(player: Player, toolArg: any): Tool?
	if typeof(toolArg) ~= "Instance" then
		return nil
	end

	if not toolArg:IsA("Tool") then
		return nil
	end

	local tool = toolArg :: Tool

	if tool:GetAttribute("LuckyBlockTool") ~= true then
		return nil
	end

	-- Only allow equipped Lucky Blocks to roll.
	-- This prevents backpack Lucky Blocks from randomly being consumed.
	if tool.Parent ~= player.Character then
		return nil
	end

	return tool
end

local function _resolveStarRainbowIconId(): string
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
			if
				string.find(string.lower(d.Name), "rainbow", 1, true)
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
		elseif
			d.Name == "Icon"
			and (
				d:IsA("ImageLabel")
				or d:IsA("ImageButton")
				or d:IsA("Decal")
				or d:IsA("BillboardGui")
				or d:IsA("SurfaceGui")
			)
		then
			d:Destroy()
		end
	end
	local iconChild = clone:FindFirstChild("Icon")
	if
		iconChild
		and (
			iconChild:IsA("ImageLabel")
			or iconChild:IsA("ImageButton")
			or iconChild:IsA("Decal")
			or iconChild:IsA("BillboardGui")
			or iconChild:IsA("SurfaceGui")
		)
	then
		iconChild:Destroy()
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
	if icon ~= "" then
		pcall(function()
			tool.TextureId = icon
		end)
		tool:SetAttribute("ToolbarIcon", icon)
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

local function playerOwnsLuckyBlockTool(player: Player, tool: Instance?): boolean
	if not tool or not tool:IsA("Tool") then
		return false
	end
	if tool:GetAttribute("LuckyBlockTool") ~= true then
		return false
	end

	local char = player.Character
	if char and tool.Parent == char then
		return true
	end

	local bp = player:FindFirstChildOfClass("Backpack")
	if bp and tool.Parent == bp then
		return true
	end

	return false
end

local function _findEquippedOrBackpackLuckyBlock(player: Player, preferredTool: Instance?): Tool?
	if playerOwnsLuckyBlockTool(player, preferredTool) then
		return preferredTool :: Tool
	end

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

local function destroyRolledLuckyBlock(player: Player, tool: Tool)
	if playerOwnsLuckyBlockTool(player, tool) then
		tool:Destroy()
	end
end

local function pickRarityWeighted(weights: { [string]: number }): string
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local r = math.random() * total
	local acc = 0
	for rarity, w in pairs(weights) do
		acc += w
		if r <= acc then
			return rarity
		end
	end
	for rarity in pairs(weights) do
		return rarity
	end
	return "mythic"
end

local function pickRandomBrainrotByRarity(rarity: string): { name: string, rarity: string, baseIncome: number }?
	local candidates = {}
	for _, def in ipairs(Brainrots.BRAINROTS) do
		if def.rarity == rarity and Brainrots.isPlayableBrainrotName(def.name) then
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
	local variant: string? = nil
	if typeof(optsArg) == "table" then
		if optsArg.equip == false then
			shouldEquip = false
		end
		if typeof(optsArg.variant) == "string" then
			variant = optsArg.variant
		end
	end

	local template = findLuckyBlockTemplate(blockName, variant)
	if not template then
		warn("[LuckyBlock] No template found for", blockName, "variant:", variant)
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
		local function tryEquip(): boolean
			local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				pcall(function()
					(hum :: Humanoid):EquipTool(tool)
				end)
				return tool.Parent == plr.Character
			end
			return false
		end
		if not tryEquip() then
			task.spawn(function()
				for _ = 1, 24 do
					if tryEquip() then
						return
					end
					task.wait(0.25)
				end
			end)
		end
	end
	return true
end

-- ── Click → roll handler ────────────────────────────────────────────────────

local rollInFlight: { [Player]: boolean } = {}

local function tryRoll(player: Player, requestedTool: Instance?)
	if rollInFlight[player] then
		return
	end

	local tool = getActivatedLuckyBlock(player, requestedTool)
	if not tool then
		return
	end
	local weights = weightsForKind(tool:GetAttribute("LuckyBlockKind"))
	local pick: any = nil
	for _ = 1, 4 do
		local rarity = pickRarityWeighted(weights)
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
		destroyRolledLuckyBlock(player, tool)
		if player.Parent == nil then
			-- Player left during the shake; nothing to grant or fire.
			return
		end

		local grant = brainrotInternalBF("GrantBrainrotAndEquip")
		if grant then
			local okGrant, errGrant = pcall(function()
				grant:Invoke(player, {
					name = pick.name,
					rarity = pick.rarity,
					mutation = "normal",
					level = 1,
					baseIncome = pick.baseIncome,
				}, { equip = true })
			end)
			if not okGrant then
				warn("[LuckyBlock] GrantBrainrotAndEquip failed for", player.Name, ":", errGrant)
			end
		end

		local sfxRE = ensurePlayBrainrotSFXRemote()
		if sfxRE then
			sfxRE:FireClient(player, pick.name)
		end
	end)
end

rollRE.OnServerEvent:Connect(function(player: Player, requestedTool: Instance?)
	tryRoll(player, requestedTool)
end)

Players.PlayerRemoving:Connect(function(player)
	rollInFlight[player] = nil
end)
