--[[
	Gradient / tier names for BrainrotHeader billboards + Sell UI rows (client + server).
	UIGradient children live on the TextLabel that renders the text (not UIStroke).
--]]

local M = {}

M.RARITY_GRADIENT_NAME = {
	common = "COMMON",
	uncommon = "UNCOMMON",
	rare = "RARE",
	epic = "EPIC",
	mythic = "MYTHIC",
	legendary = "LEGENDARY",
	["brainrot god"] = "GODLY",
	secret = "GODLY",
}

M.RARITY_GRADIENT_ALIASES = {
	mythic = { "MYTHICAL" },
	["brainrot god"] = { "BrainrotGod" },
	secret = { "BrainrotGod", "SECRET" },
}

M.RARITY_DISPLAY_NAME = {
	common = "COMMON",
	uncommon = "UNCOMMON",
	rare = "RARE",
	epic = "EPIC",
	mythic = "MYTHIC",
	legendary = "LEGENDARY",
	["brainrot god"] = "GODLY",
	secret = "SECRET",
}

M.MUTATION_GRADIENT_NAME = {
	normal = nil,
	golden = "Gold",
	diamond = "Diamond",
	lava = "Lava",
	galaxy = "Galaxy",
	rainbow = "Rainbow",
}

M.MUTATION_DISPLAY_NAME = {
	normal = "Normal",
	golden = "Gold",
	diamond = "Diamond",
	lava = "Lava",
	galaxy = "Galaxy",
	rainbow = "Rainbow",
}

function M.levelTierName(level: number): string
	if level <= 29 then
		return "1-29"
	elseif level <= 49 then
		return "30-49"
	elseif level <= 69 then
		return "50-69"
	elseif level <= 89 then
		return "70-89"
	end
	return "90-100"
end

local function isTextGui(inst: Instance): boolean
	return inst:IsA("TextLabel") or inst:IsA("TextButton")
end

local function findInfoChild(infoFrame: Instance, name: string): Instance?
	return infoFrame:FindFirstChild(name) or infoFrame:FindFirstChild(name, true)
end

-- UIGradient must be parented to the TextLabel/TextButton that renders the glyphs.
function M.resolveTextLabel(node: Instance): TextLabel?
	if isTextGui(node) then
		return node :: TextLabel
	end
	local tl = node:FindFirstChildWhichIsA("TextLabel") or node:FindFirstChildWhichIsA("TextButton")
	if tl then
		for _, c in node:GetChildren() do
			if c:IsA("UIGradient") then
				c.Parent = tl
			end
		end
		return tl :: TextLabel
	end
	return nil
end

function M.gradientHost(node: Instance): Instance
	return M.resolveTextLabel(node) or node
end

local function prepareLabelForGradient(host: Instance)
	if isTextGui(host) then
		local label = host :: TextLabel
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextTransparency = 0
	end
end

local function collectGradientChildren(node: Instance): { UIGradient }
	local host = M.gradientHost(node)
	local out: { UIGradient } = {}

	local function addFrom(parent: Instance)
		for _, c in parent:GetChildren() do
			if c:IsA("UIGradient") then
				table.insert(out, c)
			end
		end
	end

	addFrom(host)
	if node ~= host then
		addFrom(node)
	end

	return out
end

local function collectNames(primary: string?, aliases: { string }?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(name: string?)
		if name and not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	add(primary)
	if aliases then
		for _, alias in aliases do
			add(alias)
		end
	end
	return out
end

function M.rarityGradientNames(rarityId: string): { string }
	return collectNames(M.RARITY_GRADIENT_NAME[rarityId], M.RARITY_GRADIENT_ALIASES[rarityId])
end

local function gradientNameMatches(instName: string, wanted: { string }): boolean
	for _, name in wanted do
		if instName == name then
			return true
		end
	end
	local lower = string.lower(instName)
	for _, name in wanted do
		if string.lower(name) == lower then
			return true
		end
	end
	return false
end

function M.selectGradient(parent: Instance, gradientNames: string | { string } | nil)
	local names: { string } = {}
	if typeof(gradientNames) == "string" then
		table.insert(names, gradientNames)
	elseif typeof(gradientNames) == "table" then
		names = gradientNames
	end

	local host = M.gradientHost(parent)
	prepareLabelForGradient(host)

	for _, gradient in collectGradientChildren(parent) do
		if gradient.Parent ~= host then
			gradient.Parent = host
		end
		gradient.Enabled = (#names > 0 and gradientNameMatches(gradient.Name, names))
	end
end

function M.setTextOnNode(node: Instance, text: string)
	local tl = M.resolveTextLabel(node)
	if tl then
		tl.Text = text
		prepareLabelForGradient(tl)
	elseif isTextGui(node) then
		local label = node :: TextLabel
		label.Text = text
		prepareLabelForGradient(label)
	end
end

function M.applyRarityLabel(node: Instance, rarityId: string)
	local display = M.RARITY_DISPLAY_NAME[rarityId] or string.upper(rarityId)
	M.setTextOnNode(node, display)
	M.selectGradient(node, M.rarityGradientNames(rarityId))
	if node:IsA("GuiObject") then
		(node :: GuiObject).Visible = true
	end
end

function M.applyRarityStroke(strokeNode: Instance, rarityId: string)
	M.selectGradient(strokeNode, M.rarityGradientNames(rarityId))
	if strokeNode:IsA("UIStroke") then
		strokeNode.Enabled = true
	end
end

function M.applyMutationLabel(node: Instance, mutationId: string)
	local gradientName = M.MUTATION_GRADIENT_NAME[mutationId]
	local display = M.MUTATION_DISPLAY_NAME[mutationId] or mutationId
	M.setTextOnNode(node, display)
	M.selectGradient(node, gradientName)
	if node:IsA("GuiObject") then
		(node :: GuiObject).Visible = true
	end
end

function M.applyLevelLabel(node: Instance, level: number)
	local lvl = math.max(1, math.floor(level))
	M.setTextOnNode(node, string.format("Lvl %d", lvl))
	M.selectGradient(node, M.levelTierName(lvl))
	if node:IsA("GuiObject") then
		(node :: GuiObject).Visible = true
	end
end

function M.applyRateLabel(node: Instance, rateText: string)
	M.setTextOnNode(node, rateText)
	local gradients = collectGradientChildren(node)
	if #gradients == 1 then
		for _, gradient in gradients do
			gradient.Enabled = true
		end
	elseif #gradients > 1 then
		M.selectGradient(node, "Rate")
	end
	if node:IsA("GuiObject") then
		(node :: GuiObject).Visible = true
	end
end

function M.applyInfoFrame(infoFrame: Instance, data: {
	name: string,
	rarity: string,
	mutation: string,
	level: number,
	rateText: string,
})
	local nameNode = findInfoChild(infoFrame, "Name")
	if nameNode then
		M.setTextOnNode(nameNode, data.name)
	end

	local rarityNode = findInfoChild(infoFrame, "Rarity")
	if rarityNode then
		M.applyRarityLabel(rarityNode, data.rarity)
	end

	local typeNode = findInfoChild(infoFrame, "Type")
	if typeNode then
		M.applyMutationLabel(typeNode, data.mutation)
	end

	local levelNode = findInfoChild(infoFrame, "Level")
	if levelNode then
		M.applyLevelLabel(levelNode, data.level)
	end

	local rateNode = findInfoChild(infoFrame, "Rate")
	if rateNode then
		M.applyRateLabel(rateNode, data.rateText)
	end
end

return M
