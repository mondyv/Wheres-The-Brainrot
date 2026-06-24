-- [ACTIVE] XrayController
--[[
	XrayController
	With the X-Ray Vision gamepass, reveals what brainrot (if any) is hiding inside
	the currently targeted bush. Clones the BrainrotHeader billboard so name / rarity /
	rate layout matches stands and carry headers (no overlapping text).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local PromptConfig = require(script.Parent.ProximityPromptEffectsConfig)

local player = Players.LocalPlayer

local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local BUSH_HIDDEN_NAME_ATTR = "HiddenBrainrotName"
local BUSH_HIDDEN_MUTATION_ATTR = "HiddenBrainrotMutation"
local BUSH_HIDDEN_LEVEL_ATTR = "HiddenBrainrotLevel"
local BUSH_HIDDEN_BASE_INCOME_ATTR = "HiddenBrainrotBaseIncome"

local DEFAULT_BB_SIZE = UDim2.fromOffset(280, 130)
local EMPTY_BB_SIZE = UDim2.fromOffset(320, 58)
local EMPTY_NAME_TEXT_SIZE = 24
local HEADER_MAX_DISTANCE = 90

local XrayController = {}

local templateCache: BillboardGui? = nil
local billboard: BillboardGui? = nil
local fullBillboardSize: UDim2 = DEFAULT_BB_SIZE
local defaultNameTextSize: number = 18
local infoFrame: Frame? = nil
local panelStroke: UIStroke? = nil
local activeBushConns: { RBXScriptConnection } = {}

local function disconnectActiveBushConns()
	for _, conn in activeBushConns do
		conn:Disconnect()
	end
	table.clear(activeBushConns)
end

local function ownsXrayVision(): boolean
	if player:GetAttribute(StoreConfig.ATTR.XRAY_OWNED) == true then
		return true
	end
	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, StoreConfig.GAMEPASS.XRAY)
	end)
	if not ok then
		warn("[XrayController] UserOwnsGamePassAsync failed:", owned)
	end
	return ok and owned == true
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

local function hideInfoChild(frame: Instance, name: string)
	local node = frame:FindFirstChild(name) or frame:FindFirstChild(name, true)
	if node and node:IsA("GuiObject") then
		node.Visible = false
	end
end

local function hideInfoLabels(frame: Instance, names: { string })
	for _, name in names do
		hideInfoChild(frame, name)
	end
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
		hideInfoChild(frame, "Type")
		local nameNode = frame:FindFirstChild("Name", true)
		if nameNode and nameNode:IsA("TextLabel") then
			defaultNameTextSize = nameNode.TextSize
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
	name: string?,
	rarity: string?,
	mutation: string?,
	incomePerSecond: number,
}?
	local hasBrainrot = bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true
	local hiddenName = bush:GetAttribute(BUSH_HIDDEN_NAME_ATTR)
	local hiddenRarity = bush:GetAttribute(BUSH_HIDDEN_RARITY_ATTR)
	local hiddenMutation = bush:GetAttribute(BUSH_HIDDEN_MUTATION_ATTR)
	local hiddenLevel = bush:GetAttribute(BUSH_HIDDEN_LEVEL_ATTR)
	local hiddenBaseIncome = bush:GetAttribute(BUSH_HIDDEN_BASE_INCOME_ATTR)

	if not hasBrainrot or typeof(hiddenName) ~= "string" or hiddenName == "" then
		return {
			hasBrainrot = false,
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
		name = hiddenName,
		rarity = rarity,
		mutation = mutation,
		incomePerSecond = income,
	}
end

local function applyEmptyHiddenState(infoFrame: Frame)
	BrainrotHeaderStyle.applyInfoFrame(infoFrame, {
		name = "No brainrots hiding!",
		rarity = "common",
		mutation = "normal",
		level = 1,
		rateText = "",
	})
	hideInfoLabels(infoFrame, { "Level", "Type", "Rarity", "Rate" })

	local nameNode = infoFrame:FindFirstChild("Name", true)
	if nameNode and nameNode:IsA("TextLabel") then
		nameNode.TextSize = EMPTY_NAME_TEXT_SIZE
		nameNode.TextScaled = false
		nameNode.TextWrapped = true
		nameNode.TextColor3 = Color3.fromRGB(235, 235, 240)
		nameNode.TextStrokeTransparency = 0
		nameNode.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		nameNode.AnchorPoint = Vector2.new(0.5, 0.5)
		nameNode.Position = UDim2.fromScale(0.5, 0.5)
		nameNode.Size = UDim2.new(1, -12, 1, -8)
		nameNode.TextXAlignment = Enum.TextXAlignment.Center
		nameNode.TextYAlignment = Enum.TextYAlignment.Center
	end
end

local function restoreNameLabelLayout(nameNode: TextLabel)
	nameNode.TextSize = defaultNameTextSize
	nameNode.TextScaled = false
	nameNode.AnchorPoint = Vector2.new(0.5, 0.5)
	nameNode.Position = UDim2.fromScale(0.5, 0.5)
	nameNode.Size = UDim2.new(1, -8, 0, 28)
	nameNode.TextXAlignment = Enum.TextXAlignment.Center
	nameNode.TextYAlignment = Enum.TextYAlignment.Center
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
	if visible then
		billboard.Enabled = true
	else
		billboard.Enabled = false
	end
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
	if not loot then
		setVisible(false)
		return
	end

	if loot.hasBrainrot and loot.name and loot.rarity then
		billboard.Size = fullBillboardSize
		BrainrotHeaderStyle.applyInfoFrame(infoFrame, {
			name = loot.name,
			rarity = loot.rarity,
			mutation = loot.mutation or "normal",
			level = 1,
			rateText = formatRate(loot.incomePerSecond),
		})
		hideInfoLabels(infoFrame, { "Level", "Type" })
		local nameNode = infoFrame:FindFirstChild("Name", true)
		if nameNode and nameNode:IsA("TextLabel") then
			restoreNameLabelLayout(nameNode)
		end
		applyPanelStrokeColor(loot.rarity, loot.mutation)
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
	}
	for _, attr in attrs do
		table.insert(activeBushConns, bush:GetAttributeChangedSignal(attr):Connect(refresh))
	end
end

local function bushOutlineGradient(bush: Instance): ColorSequence?
	if not ownsXrayVision() then
		return nil
	end
	if bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) ~= true then
		return nil
	end
	local loot = readHiddenLoot(bush)
	if not loot or not loot.hasBrainrot then
		return nil
	end
	return BrainrotHeaderStyle.getLootOutlineGradientSequence(loot.rarity, loot.mutation)
end

local function init()
	buildBillboard()
	BushHoldInteraction.setBushOutlineGradientProvider(bushOutlineGradient)
	BushHoldInteraction.onActiveBushChanged(onActiveBushChanged)

	player:GetAttributeChangedSignal(StoreConfig.ATTR.XRAY_OWNED):Connect(function()
		onActiveBushChanged(BushHoldInteraction.getActiveBush())
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if plr ~= player or not wasPurchased or gamePassId ~= StoreConfig.GAMEPASS.XRAY then
			return
		end
		task.defer(function()
			onActiveBushChanged(BushHoldInteraction.getActiveBush())
		end)
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
