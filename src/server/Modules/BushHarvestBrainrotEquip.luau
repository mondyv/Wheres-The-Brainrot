-- [ACTIVE] BushHarvestBrainrotEquip
--[[
	Brainrot Tool equip/build helpers extracted from BushHarvest.server so the main
	script stays under Luau's 200 local register limit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))

local M = {}

export type BrainrotInvEntry = {
	name: string,
	icon: string,
	sourcePath: string,
	rarity: string,
	mutation: string,
	level: number,
	baseIncome: number,
}

export type EquipDeps = {
	Brainrots: any,
	SafezoneUtil: any,
	brainrotInventories: { [Player]: { BrainrotInvEntry } },
	brainrotParkedInExpandedBackpack: { [Player]: { [number]: boolean } },
	HOTBAR_UI_SLOTS: number,
	MAX_BACKPACK_BRAINROT_SLOTS: number,
	assignEntryToLowestFreeHotbarSlot: (
		Player,
		{ BrainrotInvEntry },
		{ [number]: boolean },
		number
	) -> number?,
	playerInInventoryZone: (Player) -> boolean,
	getMainPart: (Model) -> BasePart?,
	findTemplateBySourcePath: (Folder, string) -> Model?,
	findFirstTemplateByModelName: (Folder, string) -> Model?,
	findMutationTemplate: (Folder, string, string) -> Model?,
}

local function removeBrainrotToolAtInventoryIndex(parent: Instance, invIndex: number)
	for _, c in ipairs(parent:GetChildren()) do
		if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
			local a = c:GetAttribute("BrainrotInvIndex")
			if typeof(a) == "number" and math.floor(a) == invIndex then
				c:Destroy()
			end
		end
	end
end

local function buildBrainrotToolFromTemplate(
	template: Model,
	entry: BrainrotInvEntry,
	invIndex: number,
	getMainPart: (Model) -> BasePart?
): Tool?
	local clone = template:Clone()
	BrainrotCarryVisual.applyScaleForLevel(clone, entry.level)
	for _, d in clone:GetDescendants() do
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
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	local tool = Instance.new("Tool")
	tool.Name = entry.name
	tool:SetAttribute("BrainrotTool", true)
	tool:SetAttribute("BrainrotInvIndex", invIndex)
	tool:SetAttribute("BrainrotSourcePath", entry.sourcePath)
	tool:SetAttribute("BrainrotName", entry.name)
	tool:SetAttribute("BrainrotRarity", entry.rarity)
	tool:SetAttribute("BrainrotMutation", entry.mutation)
	tool:SetAttribute("BrainrotLevel", math.max(1, math.floor(entry.level)))
	tool:SetAttribute("BrainrotBaseIncome", entry.baseIncome)
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true
	if entry.icon ~= "" then
		pcall(function()
			tool.TextureId = entry.icon
		end)
	end

	main.Name = "Handle"
	main.Anchored = false
	main.Massless = true
	main.Parent = tool

	for _, p in parts do
		if p ~= main then
			p.Anchored = false
			p.Massless = true
			p.Parent = tool
			local w = Instance.new("WeldConstraint")
			w.Part0 = main
			w.Part1 = p
			w.Parent = main
		end
	end

	BrainrotCarryVisual.applyNonColliding(tool)

	clone:Destroy()
	tool.Grip = CFrame.new()
	return tool
end

function M.destroyAllBrainrotToolsForPlayer(plr: Player)
	local bp = plr:FindFirstChildOfClass("Backpack")
	local char = plr.Character
	if bp then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				c:Destroy()
			end
		end
	end
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				c:Destroy()
			end
		end
	end
end

function M.swapBrainrotToolIndices(plr: Player, oldA: number, oldB: number)
	local roots: { Instance } = {}
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp then
		table.insert(roots, bp)
	end
	local char = plr.Character
	if char then
		table.insert(roots, char)
	end
	for _, root in ipairs(roots) do
		for _, c in ipairs(root:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("BrainrotTool") == true then
				local a = c:GetAttribute("BrainrotInvIndex")
				if typeof(a) == "number" then
					local af = math.floor(a)
					if af == oldA then
						c:SetAttribute("BrainrotInvIndex", oldB)
					elseif af == oldB then
						c:SetAttribute("BrainrotInvIndex", oldA)
					end
				end
			end
		end
	end
end

function M.createEquipBrainrotSlotForPlayer(deps: EquipDeps): (Player, number, boolean?) -> number?
	return function(player: Player, slot: number, forceEquip: boolean?): number?
		local char = player.Character
		if not forceEquip then
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local canEquip = deps.playerInInventoryZone(player)
				or deps.SafezoneUtil.isCharacterInToolbarZone(char)
				or (hrp and hrp:IsA("BasePart") and deps.SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position))
			if not canEquip then
				return nil
			end
		end
		local list = deps.brainrotInventories[player]
		if not list then
			return nil
		end
		local map = deps.brainrotParkedInExpandedBackpack[player]
		if not map then
			map = {}
			deps.brainrotParkedInExpandedBackpack[player] = map
		end
		local idx = math.clamp(math.floor(slot), 1, math.max(1, #list))
		if not list[idx] then
			return nil
		end
		-- forceEquip (bag click): equip while staying in the backpack. Do not
		-- promote onto the hotbar — that stole the bag outline.
		if (idx > deps.HOTBAR_UI_SLOTS or map[idx]) and not forceEquip then
			local hotbarSlot = deps.assignEntryToLowestFreeHotbarSlot(player, list, map, idx)
			if not hotbarSlot then
				return nil
			end
		end
		local entry = list[idx]
		if not char then
			return nil
		end
		local brainrots = deps.Brainrots.getBrainrotsFolder()
		if not brainrots then
			return nil
		end
		local mut = if typeof(entry.mutation) == "string" and entry.mutation ~= "" then entry.mutation else "normal"
		-- Mutation mesh first (Gold/Diamond/etc). sourcePath often still points at Normal.
		local template: Model? = deps.findMutationTemplate(brainrots, entry.name, mut)
		if not template and entry.sourcePath ~= "" then
			template = deps.findTemplateBySourcePath(brainrots, entry.sourcePath)
		end
		if not template then
			template = deps.findFirstTemplateByModelName(brainrots, entry.name)
		end
		if not template then
			return nil
		end
		local tool = buildBrainrotToolFromTemplate(template, entry, idx, deps.getMainPart)
		if not tool then
			return nil
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local bp = player:FindFirstChildOfClass("Backpack")
		if not hum or not bp then
			tool:Destroy()
			return nil
		end
		removeBrainrotToolAtInventoryIndex(bp, idx)
		removeBrainrotToolAtInventoryIndex(char, idx)
		-- Drop whatever is already in hand (other brainrot / workout gear) so
		-- a hotbar swap is one press, not unequip-then-equip.
		for _, child in char:GetChildren() do
			if child:IsA("Tool") and child ~= tool then
				if child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
					child.RequiresHandle = true
				end
			end
		end
		hum:UnequipTools()
		for _, child in char:GetChildren() do
			if child:IsA("Tool") and child ~= tool then
				child.Parent = bp
			end
		end
		tool.Parent = char
		if tool.Parent ~= char then
			tool.Parent = bp
			hum:EquipTool(tool)
		end
		task.delay(0.1, function()
			if not hum.Parent or not tool.Parent or tool.Parent == char then
				return
			end
			tool.Parent = char
		end)
		return idx
	end
end

return M
