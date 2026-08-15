-- [ACTIVE] BrainrotHeaderStyle
--[[
	Gradient / tier names for BrainrotHeader billboards + Sell UI rows (client + server).
	UIGradient children live on the TextLabel that renders the text (not UIStroke).
--]]

local UiFonts = require(script.Parent.UiFonts)

local M = {}

M.RARITY_GRADIENT_NAME = {
	common = "COMMON",
	uncommon = "UNCOMMON",
	rare = "RARE",
	epic = "EPIC",
	mythic = "MYTHIC",
	mythical = "MYTHICAL",
	legendary = "LEGENDARY",
	godly = "GODLY",
	["brainrot god"] = "GODLY",
	secret = "SECRET",
}

M.RARITY_GRADIENT_ALIASES = {
	mythic = { "MYTHICAL" },
	["brainrot god"] = { "BrainrotGod" },
	secret = { "Secret" },
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
	local key = string.lower(rarityId)
	return collectNames(M.RARITY_GRADIENT_NAME[key], M.RARITY_GRADIENT_ALIASES[key])
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

local gameGradientsRarityFolder: Folder? = nil

local function getGameGradientsRarityFolder(): Folder?
	if gameGradientsRarityFolder and gameGradientsRarityFolder.Parent then
		return gameGradientsRarityFolder
	end
	local RunService = game:GetService("RunService")
	if not RunService:IsClient() then
		return nil
	end
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local main = player.PlayerGui:FindFirstChild("Main") or player.PlayerGui:WaitForChild("Main", 8)
	local gameGradients = main and main:FindFirstChild("GameGradients")
	local rarities = gameGradients and gameGradients:FindFirstChild("Rarity")
	if rarities and rarities:IsA("Folder") then
		gameGradientsRarityFolder = rarities
	end
	return gameGradientsRarityFolder
end

local function findGameGradientTemplate(names: { string }): UIGradient?
	local folder = getGameGradientsRarityFolder()
	if not folder then
		return nil
	end
	for _, name in names do
		local template = folder:FindFirstChild(name)
		if template and template:IsA("UIGradient") then
			return template
		end
		local title = string.sub(name, 1, 1) .. string.lower(string.sub(name, 2))
		template = folder:FindFirstChild(title)
		if template and template:IsA("UIGradient") then
			return template
		end
		local upper = string.upper(name)
		template = folder:FindFirstChild(upper)
		if template and template:IsA("UIGradient") then
			return template
		end
	end
	return nil
end

local gameGradientsTypeFolder: Folder? = nil

local function getGameGradientsTypeFolder(): Folder?
	if gameGradientsTypeFolder and gameGradientsTypeFolder.Parent then
		return gameGradientsTypeFolder
	end
	local RunService = game:GetService("RunService")
	if not RunService:IsClient() then
		return nil
	end
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local main = player.PlayerGui:FindFirstChild("Main") or player.PlayerGui:WaitForChild("Main", 8)
	local gameGradients = main and main:FindFirstChild("GameGradients")
	local types = gameGradients and gameGradients:FindFirstChild("Type")
	if types and types:IsA("Folder") then
		gameGradientsTypeFolder = types
	end
	return gameGradientsTypeFolder
end

local function findTypeGradientTemplate(names: { string }): UIGradient?
	local folder = getGameGradientsTypeFolder()
	if not folder then
		return nil
	end
	for _, name in names do
		local template = folder:FindFirstChild(name)
		if template and template:IsA("UIGradient") then
			return template
		end
	end
	return nil
end

function M.sampleGradientAccentColor(gradient: UIGradient?): Color3?
	if not gradient then
		return nil
	end
	local keypoints = gradient.Color.Keypoints
	if #keypoints == 0 then
		return nil
	end
	local r, g, b = 0, 0, 0
	for _, kp in keypoints do
		r += kp.Value.R
		g += kp.Value.G
		b += kp.Value.B
	end
	local n = #keypoints
	return Color3.new(r / n, g / n, b / n)
end

function M.rarityAccentColor(rarityId: string): Color3
	local template = findGameGradientTemplate(M.rarityGradientNames(rarityId))
	return M.sampleGradientAccentColor(template) or Color3.fromRGB(120, 220, 150)
end

function M.mutationAccentColor(mutationId: string): Color3?
	local gradientName = M.MUTATION_GRADIENT_NAME[mutationId]
	if not gradientName then
		return nil
	end
	local template = findTypeGradientTemplate({ gradientName })
	return M.sampleGradientAccentColor(template)
end

function M.sampleColorSequence(sequence: ColorSequence, alpha: number): Color3
	alpha = math.clamp(alpha, 0, 1)
	local keypoints = sequence.Keypoints
	if #keypoints == 0 then
		return Color3.new(1, 1, 1)
	end
	if #keypoints == 1 then
		return keypoints[1].Value
	end
	for i = 1, #keypoints - 1 do
		local a = keypoints[i]
		local b = keypoints[i + 1]
		if alpha >= a.Time and alpha <= b.Time then
			local span = math.max(1e-6, b.Time - a.Time)
			return a.Value:Lerp(b.Value, (alpha - a.Time) / span)
		end
	end
	return keypoints[#keypoints].Value
end

function M.getLootOutlineGradientSequence(rarityId: string?, mutationId: string?): ColorSequence?
	if typeof(mutationId) == "string" and mutationId ~= "" and mutationId ~= "normal" then
		local gradientName = M.MUTATION_GRADIENT_NAME[mutationId]
		if gradientName then
			local mutationTemplate = findTypeGradientTemplate({ gradientName })
			if mutationTemplate then
				return mutationTemplate.Color
			end
		end
	end
	if typeof(rarityId) == "string" and rarityId ~= "" then
		local rarityTemplate = findGameGradientTemplate(M.rarityGradientNames(rarityId))
		if rarityTemplate then
			return rarityTemplate.Color
		end
	end
	return nil
end

function M.lootOutlineColorAtTime(rarityId: string?, mutationId: string?, clock: number): Color3
	local sequence = M.getLootOutlineGradientSequence(rarityId, mutationId)
	if sequence then
		return M.sampleColorSequence(sequence, (clock * 0.42) % 1)
	end
	return M.hiddenLootOutlineColor(rarityId, mutationId)
end

function M.hiddenLootOutlineColor(rarityId: string?, mutationId: string?): Color3
	if typeof(mutationId) == "string" and mutationId ~= "" and mutationId ~= "normal" then
		local mutationColor = M.mutationAccentColor(mutationId)
		if mutationColor then
			return mutationColor
		end
	end
	if typeof(rarityId) == "string" and rarityId ~= "" then
		return M.rarityAccentColor(rarityId)
	end
	return Color3.fromRGB(120, 220, 150)
end

function M.ensureRarityGradient(node: Instance, rarityId: string)
	local names = M.rarityGradientNames(rarityId)
	local host = M.gradientHost(node)
	for _, name in names do
		for _, gradient in collectGradientChildren(node) do
			if gradientNameMatches(gradient.Name, { name }) then
				return
			end
		end
	end
	local template = findGameGradientTemplate(names)
	if not template then
		return
	end
	local clone = template:Clone()
	clone.Enabled = true
	clone.Parent = host
end

function M.ensureTypeGradient(node: Instance, mutationId: string)
	local gradientName = M.MUTATION_GRADIENT_NAME[mutationId]
	if not gradientName then
		return
	end
	local host = M.gradientHost(node)
	for _, gradient in collectGradientChildren(node) do
		if gradientNameMatches(gradient.Name, { gradientName }) then
			return
		end
	end
	local template = findTypeGradientTemplate({ gradientName })
	if not template then
		return
	end
	local clone = template:Clone()
	clone.Enabled = true
	clone.Parent = host
end

function M.applyRarityLabel(node: Instance, rarityId: string)
	local display = M.RARITY_DISPLAY_NAME[rarityId] or string.upper(rarityId)
	M.setTextOnNode(node, display)
	M.ensureRarityGradient(node, rarityId)
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
	M.ensureTypeGradient(node, mutationId)
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

function M.applyRateGradient(node: Instance)
	local gradients = collectGradientChildren(node)
	if #gradients == 1 then
		for _, gradient in gradients do
			gradient.Enabled = true
		end
	elseif #gradients > 0 then
		M.selectGradient(node, "Rate")
	end
end

function M.applyRateLabel(node: Instance, rateText: string)
	M.setTextOnNode(node, rateText)
	M.applyRateGradient(node)
	if node:IsA("GuiObject") then
		(node :: GuiObject).Visible = true
	end
end

local headerInfoCache: { [string]: Instance } = {}

function M.getHeaderInfoChild(childName: string): Instance?
	local cached = headerInfoCache[childName]
	if cached and cached.Parent then
		return cached
	end

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local header = templates and templates:FindFirstChild("BrainrotHeader")
	local billboard = header and header:FindFirstChild("BillboardGui")
	local info = billboard and billboard:FindFirstChild("Info", true)
	local node = info and (info:FindFirstChild(childName) or info:FindFirstChild(childName, true))
	if node then
		headerInfoCache[childName] = node
	end
	return node
end

function M.cloneGradientChildren(source: Instance, target: TextLabel)
	local sourceHost = M.gradientHost(source)
	for _, child in sourceHost:GetChildren() do
		if child:IsA("UIGradient") then
			local clone = child:Clone()
			clone.Parent = target
		end
	end
end

function M.activeGradientName(source: Instance): string?
	for _, gradient in collectGradientChildren(source) do
		if gradient.Enabled then
			return gradient.Name
		end
	end
	local all = collectGradientChildren(source)
	if #all == 1 then
		return all[1].Name
	end
	return nil
end

function M.copyActiveGradientFromSource(source: Instance, target: Instance)
	local gradientName = M.activeGradientName(source)
	if gradientName then
		M.selectGradient(target, gradientName)
	end
end

function M.copyStrokeFromSource(source: Instance, target: TextLabel, thicknessScale: number?): UIStroke?
	local sourceLabel = M.resolveTextLabel(source)
	if not sourceLabel then
		return nil
	end
	local sourceStroke = sourceLabel:FindFirstChildOfClass("UIStroke")
	if not sourceStroke then
		return nil
	end
	local stroke = sourceStroke:Clone()
	if typeof(thicknessScale) == "number" then
		stroke.Thickness = sourceStroke.Thickness * thicknessScale
	end
	stroke.Parent = target
	return stroke
end

function M.prepareFloatTextLabel(label: TextLabel, styleSource: Instance, textSize: number, font: Enum.Font?)
	local sourceLabel = M.resolveTextLabel(styleSource)
	if font then
		label.FontFace = Font.fromEnum(font)
	elseif sourceLabel then
		label.FontFace = sourceLabel.FontFace
	else
		UiFonts.applyBody(label)
	end
	label.TextSize = textSize
	label.TextStrokeTransparency = 1
	prepareLabelForGradient(label)
	M.cloneGradientChildren(styleSource, label)
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
