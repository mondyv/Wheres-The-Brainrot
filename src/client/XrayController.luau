-- [ACTIVE] XrayController
--[[
	XrayController
	With the X-Ray Vision gamepass, reveals what brainrot (if any) is hiding inside
	the currently targeted bush. Clones the BrainrotHeader billboard so name / rarity /
	mutation / rate layout matches stands and carry headers (no overlapping text).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local PromptConfig = require(script.Parent.ProximityPromptEffectsConfig)

local player = Players.LocalPlayer

local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local BUSH_HIDDEN_NAME_ATTR = "HiddenBrainrotName"
local BUSH_HIDDEN_MUTATION_ATTR = "HiddenBrainrotMutation"
local BUSH_HIDDEN_LEVEL_ATTR = "HiddenBrainrotLevel"
local BUSH_HIDDEN_BASE_INCOME_ATTR = "HiddenBrainrotBaseIncome"
local BUSH_HAS_LUCKY_ATTR = "HasHiddenLuckyBlock"
local BUSH_HIDDEN_LUCKY_KIND_ATTR = "HiddenLuckyBlockKind"

local DEFAULT_BB_SIZE = UDim2.fromOffset(300, 140)
local EMPTY_BB_SIZE = UDim2.fromOffset(320, 58)
local EMPTY_NAME_TEXT_SIZE = 22
local EMPTY_BRAINROT_TEXT = "No Brainrot"
local HEADER_MAX_DISTANCE = 90
local NAME_MIN_TEXT_SIZE = 16
local NAME_MAX_TEXT_SIZE = 26

local XrayController = {}

local templateCache: BillboardGui? = nil
local billboard: BillboardGui? = nil
local fullBillboardSize: UDim2 = DEFAULT_BB_SIZE
local infoFrame: Frame? = nil
local panelStroke: UIStroke? = nil
local activeBushConns: { RBXScriptConnection } = {}

type LabelLayout = {
	size: UDim2,
	position: UDim2,
	anchorPoint: Vector2,
	textSize: number,
	textScaled: boolean,
	textWrapped: boolean,
	textXAlignment: Enum.TextXAlignment,
	textYAlignment: Enum.TextYAlignment,
	visible: boolean,
}

local nameLabelLayout: LabelLayout? = nil
local typeLabelLayout: LabelLayout? = nil

local function disconnectActiveBushConns()
	for _, conn in activeBushConns do
		conn:Disconnect()
	end
	table.clear(activeBushConns)
end

-- Never call UserOwnsGamePassAsync from aim/highlight — it yields and freezes bush search.
local xrayOwnedCached = false

local function refreshXrayOwnedCache()
	xrayOwnedCached = player:GetAttribute(StoreConfig.ATTR.XRAY_OWNED) == true
		or player:GetAttribute(StoreConfig.ATTR.GIFTED_XRAY) == true
		or player:GetAttribute(StoreConfig.ATTR.PURCHASED_XRAY) == true
end

local function ownsXrayVision(): boolean
	return xrayOwnedCached
end

local function formatRate(income: number): string
	return BrainrotEconomy.formatCashShort(income) .. "/s"
end

local function getHeaderTemplate(): BillboardGui?
	if templateCache and templateCache.Parent then
		return templateCache
	end
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	if not templates then
		return nil
	end
	local header = templates:FindFirstChild("BrainrotHeader")
	if not header then
		return nil
	end
	local direct = header:FindFirstChild("BillboardGui")
	if direct and direct:IsA("BillboardGui") then
		templateCache = direct
		return direct
	end
	local any = header:FindFirstChildWhichIsA("BillboardGui", true)
	if any and any:IsA("BillboardGui") then
		templateCache = any
		return any
	end
	return nil
end

local function resolveInfoTextLabel(info: Instance, childName: string): TextLabel?
	local node = info:FindFirstChild(childName) or info:FindFirstChild(childName, true)
	if not node then
		return nil
	end
	return BrainrotHeaderStyle.resolveTextLabel(node)
end

local function captureLabelLayout(label: TextLabel): LabelLayout
	return {
		size = label.Size,
		position = label.Position,
		anchorPoint = label.AnchorPoint,
		textSize = label.TextSize,
		textScaled = label.TextScaled,
		textWrapped = label.TextWrapped,
		textXAlignment = label.TextXAlignment,
		textYAlignment = label.TextYAlignment,
		visible = label.Visible,
	}
end

local function applyLabelLayout(label: TextLabel, layout: LabelLayout)
	label.Size = layout.size
	label.Position = layout.position
	label.AnchorPoint = layout.anchorPoint
	label.TextSize = layout.textSize
	label.TextScaled = layout.textScaled
	label.TextWrapped = layout.textWrapped
	label.TextXAlignment = layout.textXAlignment
	label.TextYAlignment = layout.textYAlignment
	label.Visible = layout.visible
end

local function hideInfoChild(frame: Instance, name: string)
	local node = frame:FindFirstChild(name) or frame:FindFirstChild(name, true)
	if node and node:IsA("GuiObject") then
		node.Visible = false
	end
end

local function ensureNameReadable(label: TextLabel)
	label.Visible = true
	label.TextTransparency = 0
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	-- Prefer scaled text in the template slot so long names stay readable.
	if nameLabelLayout then
		applyLabelLayout(label, nameLabelLayout)
	end
	label.TextScaled = true
	label.TextWrapped = true
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	constraint.MinTextSize = NAME_MIN_TEXT_SIZE
	constraint.MaxTextSize = math.max(NAME_MAX_TEXT_SIZE, nameLabelLayout and nameLabelLayout.textSize or NAME_MAX_TEXT_SIZE)
end

local function buildBillboard()
	local template = getHeaderTemplate()
	if not template then
		warn("[XrayController] BrainrotHeader template missing")
		return
	end

	local bb = template:Clone()
	bb.Name = "XrayReveal"
	bb.Enabled = false
	bb.ResetOnSpawn = false
	bb.AlwaysOnTop = true
	bb.Active = false
	bb.LightInfluence = 0
	bb.MaxDistance = HEADER_MAX_DISTANCE
	bb.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	bb.Size = if template.Size.Y.Offset > 4 then template.Size else DEFAULT_BB_SIZE
	fullBillboardSize = bb.Size
	bb.StudsOffsetWorldSpace = Vector3.zero
	bb.StudsOffset = PromptConfig.BUSH_XRAY_UI_OFFSET

	local frame = bb:FindFirstChild("Info", true)
	if frame and frame:IsA("Frame") then
		infoFrame = frame
		hideInfoChild(frame, "Level")
		local nameLabel = resolveInfoTextLabel(frame, "Name")
		if nameLabel then
			nameLabelLayout = captureLabelLayout(nameLabel)
		end
		local typeLabel = resolveInfoTextLabel(frame, "Type")
		if typeLabel then
			typeLabelLayout = captureLabelLayout(typeLabel)
		end
	end

	local panel = bb:FindFirstChildWhichIsA("Frame", true)
	if panel then
		panelStroke = panel:FindFirstChildOfClass("UIStroke")
	end

	local pg = player:FindFirstChild("PlayerGui")
	bb.Parent = pg or workspace.CurrentCamera
	billboard = bb
end

local function bushAdornee(bush: Instance): BasePart?
	return BushRootUtil.ensurePromptAnchorPart(bush)
end

local function readHiddenLoot(bush: Instance): {
	hasBrainrot: boolean,
	hasLucky: boolean,
	name: string?,
	rarity: string?,
	mutation: string?,
	level: number,
	incomePerSecond: number,
	isLuckyBlock: boolean,
}
	local tutorialActive = player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true
	local hasLucky = not tutorialActive and bush:GetAttribute(BUSH_HAS_LUCKY_ATTR) == true
	local luckyKind = bush:GetAttribute(BUSH_HIDDEN_LUCKY_KIND_ATTR)
	if hasLucky and typeof(luckyKind) == "string" and luckyKind ~= "" then
		return {
			hasBrainrot = false,
			hasLucky = true,
			isLuckyBlock = true,
			name = LuckyBlockCatalog.displayName(luckyKind),
			rarity = LuckyBlockCatalog.primaryDropRarity(luckyKind),
			mutation = "normal",
			level = 1,
			incomePerSecond = 0,
		}
	end

	local hasBrainrot = bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true
	local hiddenName = bush:GetAttribute(BUSH_HIDDEN_NAME_ATTR)
	local hiddenRarity = bush:GetAttribute(BUSH_HIDDEN_RARITY_ATTR)
	local hiddenMutation = bush:GetAttribute(BUSH_HIDDEN_MUTATION_ATTR)
	local hiddenLevel = bush:GetAttribute(BUSH_HIDDEN_LEVEL_ATTR)
	local hiddenBaseIncome = bush:GetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR)

	if not hasBrainrot or typeof(hiddenName) ~= "string" or hiddenName == "" then
		return {
			hasBrainrot = false,
			hasLucky = false,
			isLuckyBlock = false,
			level = 1,
			incomePerSecond = 0,
		}
	end

	local rarity = if typeof(hiddenRarity) == "string" then hiddenRarity else "common"
	local mutation = if typeof(hiddenMutation) == "string" and hiddenMutation ~= "" then hiddenMutation else "normal"
	local level = if typeof(hiddenLevel) == "number" then math.max(1, math.floor(hiddenLevel)) else 1
	local baseIncome = if typeof(hiddenBaseIncome) == "number" then hiddenBaseIncome else 0
	local income = BrainrotEconomy.incomePerSecond({
		name = hiddenName,
		rarity = rarity,
		mutation = mutation,
		level = level,
		baseIncome = baseIncome,
	})

	return {
		hasBrainrot = true,
		hasLucky = false,
		isLuckyBlock = false,
		name = hiddenName,
		rarity = rarity,
		mutation = mutation,
		level = level,
		incomePerSecond = income,
	}
end

local function clearLabelGradients(label: TextLabel)
	for _, child in label:GetChildren() do
		if child:IsA("UIGradient") then
			child:Destroy()
		end
	end
end

local function applyEmptyHiddenState(info: Frame)
	hideInfoChild(info, "Level")
	hideInfoChild(info, "Type")
	hideInfoChild(info, "Rarity")
	hideInfoChild(info, "Rate")

	local nameNode = resolveInfoTextLabel(info, "Name")
	if nameNode then
		clearLabelGradients(nameNode)
		nameNode.Visible = true
		nameNode.Text = EMPTY_BRAINROT_TEXT
		nameNode.TextScaled = false
		nameNode.TextSize = EMPTY_NAME_TEXT_SIZE
		nameNode.TextWrapped = true
		nameNode.TextColor3 = Color3.fromRGB(235, 235, 240)
		nameNode.TextTransparency = 0
		nameNode.TextStrokeTransparency = 0
		nameNode.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		nameNode.AnchorPoint = Vector2.new(0.5, 0.5)
		nameNode.Position = UDim2.fromScale(0.5, 0.5)
		nameNode.Size = UDim2.new(1, -12, 1, -8)
		nameNode.TextXAlignment = Enum.TextXAlignment.Center
		nameNode.TextYAlignment = Enum.TextYAlignment.Center
	end
end

local function applyPanelStrokeColor(rarity: string?, mutation: string?)
	if not panelStroke then
		return
	end
	panelStroke.Color = BrainrotHeaderStyle.hiddenLootOutlineColor(rarity, mutation)
end

local function setVisible(visible: boolean)
	if not billboard then
		return
	end
	billboard.Enabled = visible
end

local function updateForBush(bush: Instance)
	if not billboard or not infoFrame then
		return
	end

	local adornee = bushAdornee(bush)
	if not adornee then
		setVisible(false)
		return
	end

	billboard.Adornee = adornee
	billboard.StudsOffset = PromptConfig.BUSH_XRAY_UI_OFFSET

	local loot = readHiddenLoot(bush)

	if (loot.hasBrainrot or loot.hasLucky) and loot.name and loot.rarity then
		billboard.Size = fullBillboardSize
		local mutation = loot.mutation or "normal"
		if loot.isLuckyBlock then
			BrainrotHeaderStyle.applyInfoFrame(infoFrame, {
				name = loot.name,
				rarity = loot.rarity,
				mutation = "normal",
				level = 1,
				rateText = "",
			})
			hideInfoChild(infoFrame, "Level")
			hideInfoChild(infoFrame, "Rate")
			hideInfoChild(infoFrame, "Type")

			local nameNode = resolveInfoTextLabel(infoFrame, "Name")
			if nameNode then
				ensureNameReadable(nameNode)
				BrainrotHeaderStyle.setTextOnNode(nameNode, loot.name)
			end

			local rarityNode = resolveInfoTextLabel(infoFrame, "Rarity")
			if rarityNode then
				BrainrotHeaderStyle.applyRarityLabel(rarityNode, loot.rarity)
				rarityNode.Visible = true
			end
		else
			BrainrotHeaderStyle.applyInfoFrame(infoFrame, {
				name = loot.name,
				rarity = loot.rarity,
				mutation = mutation,
				level = loot.level,
				rateText = formatRate(loot.incomePerSecond),
			})
			hideInfoChild(infoFrame, "Level")

			local nameNode = resolveInfoTextLabel(infoFrame, "Name")
			if nameNode then
				ensureNameReadable(nameNode)
				BrainrotHeaderStyle.setTextOnNode(nameNode, loot.name)
			end

			local typeNode = resolveInfoTextLabel(infoFrame, "Type")
			if typeNode then
				if typeLabelLayout then
					applyLabelLayout(typeNode, typeLabelLayout)
				end
				BrainrotHeaderStyle.applyMutationLabel(typeNode, mutation)
				typeNode.Visible = true
				typeNode.TextTransparency = 0
				typeNode.TextStrokeTransparency = 0
				typeNode.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			end
		end

		applyPanelStrokeColor(loot.rarity, if loot.isLuckyBlock then nil else mutation)
	else
		billboard.Size = EMPTY_BB_SIZE
		applyEmptyHiddenState(infoFrame)
		if panelStroke then
			panelStroke.Color = Color3.fromRGB(90, 90, 100)
		end
	end
end

local function onActiveBushChanged(bush: Instance?)
	disconnectActiveBushConns()

	if not bush or not ownsXrayVision() then
		setVisible(false)
		return
	end

	updateForBush(bush)
	setVisible(true)

	local function refresh()
		updateForBush(bush)
	end

	local attrs = {
		BUSH_HIDDEN_NAME_ATTR,
		BUSH_HAS_BRAINROT_ATTR,
		BUSH_HIDDEN_RARITY_ATTR,
		BUSH_HIDDEN_MUTATION_ATTR,
		BUSH_HIDDEN_LEVEL_ATTR,
		BUSH_HIDDEN_BASE_INCOME_ATTR,
		BUSH_HAS_LUCKY_ATTR,
		BUSH_HIDDEN_LUCKY_KIND_ATTR,
	}
	for _, attr in attrs do
		table.insert(activeBushConns, bush:GetAttributeChangedSignal(attr):Connect(refresh))
	end
end

local function bushOutlineGradient(bush: Instance): ColorSequence?
	if not ownsXrayVision() then
		return nil
	end
	local loot = readHiddenLoot(bush)
	if not loot or (not loot.hasBrainrot and not loot.hasLucky) then
		return nil
	end
	-- Outline follows rarity (mutation still shown in the header Type label).
	return BrainrotHeaderStyle.getLootOutlineGradientSequence(loot.rarity, nil)
end

local function init()
	refreshXrayOwnedCache()
	buildBillboard()
	BushHoldInteraction.setBushOutlineGradientProvider(bushOutlineGradient)
	BushHoldInteraction.onActiveBushChanged(onActiveBushChanged)

	local function onXrayAttrChanged()
		refreshXrayOwnedCache()
		onActiveBushChanged(BushHoldInteraction.getActiveBush())
	end
	player:GetAttributeChangedSignal(StoreConfig.ATTR.XRAY_OWNED):Connect(onXrayAttrChanged)
	player:GetAttributeChangedSignal(StoreConfig.ATTR.GIFTED_XRAY):Connect(onXrayAttrChanged)
	player:GetAttributeChangedSignal(StoreConfig.ATTR.PURCHASED_XRAY):Connect(onXrayAttrChanged)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if plr ~= player or not wasPurchased or gamePassId ~= StoreConfig.GAMEPASS.XRAY then
			return
		end
		xrayOwnedCached = true
		task.defer(function()
			onActiveBushChanged(BushHoldInteraction.getActiveBush())
		end)
	end)

	task.spawn(function()
		if xrayOwnedCached then
			return
		end
		local ok, owned = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, StoreConfig.GAMEPASS.XRAY)
		end)
		if not ok then
			warn("[XrayController] UserOwnsGamePassAsync failed:", owned)
			return
		end
		if owned ~= true then
			return
		end
		xrayOwnedCached = true
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local claim = remotes and remotes:FindFirstChild("ClaimOwnedGamepass")
		if claim and claim:IsA("RemoteEvent") then
			claim:FireServer(StoreConfig.GAMEPASS.XRAY)
		end
		onActiveBushChanged(BushHoldInteraction.getActiveBush())
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[XrayController]", err)
	end
end

XrayController.init = boot
return XrayController
