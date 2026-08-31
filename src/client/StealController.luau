-- [ACTIVE] StealController
--[[
	StealController
	Hold-to-steal ProximityPrompt on OTHER players' occupied stands.
	Uses rarity outline via ProximityPromptEffects (stand-tagged prompts).
	Free VIP steals or Robux product by rarity; success toast on steal.
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local PlotStandPlaceholders = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotStandPlaceholders"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local TopNotifController = require(script.Parent.TopNotifController)
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer
local STAND_TAG = "BrainrotStand"
local HOLD_DURATION = 1.05
-- Same front-of-stand feel as brainrot pickup, with a little extra reach.
local MAX_DISTANCE = 20
local VISIBILITY_REFRESH_INTERVAL = 0.4

local StealController = {}

local stealPrompts: { [Model]: ProximityPrompt } = {}
local visibilityAccum = 0
local visibilityConn: RBXScriptConnection? = nil
local stealPriceByRarity: { [string]: number } = {}

local function prefetchStealPrices()
	for rarity, productId in StoreConfig.STEAL_PRODUCT_BY_RARITY do
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if not ok then
				warn("[StealController] GetProductInfo failed:", rarity, info)
				return
			end
			if typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
				stealPriceByRarity[rarity] = info.PriceInRobux
				refreshStealPromptVisibility()
			end
		end)
	end
end

local function liveStealPrice(rarity: string): number?
	local key = StoreConfig.normalizeStealRarity(rarity)
	local live = stealPriceByRarity[key]
	if typeof(live) == "number" then
		return live
	end
	return StoreConfig.getStealPriceRobux(rarity)
end

local function storeRemotes(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function resolveStandRarity(stand: Model): string?
	local name = stand:GetAttribute("BrainrotName")
	if typeof(name) == "string" and name ~= "" then
		local catalogRarity = BrainrotsConfig:GetRarity(name)
		if typeof(catalogRarity) == "string" and catalogRarity ~= "" then
			return catalogRarity
		end
	end
	local attr = stand:GetAttribute("BrainrotRarity")
	if typeof(attr) == "string" and attr ~= "" then
		return attr
	end
	return nil
end

local function getStealRemote(): RemoteEvent?
	local folder = storeRemotes()
	local re = folder and folder:FindFirstChild("StealRequest")
	if re and re:IsA("RemoteEvent") then
		return re
	end
	return nil
end

local function formatDisplayName(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

local function standAnchorPart(stand: Model): BasePart?
	local spawn = stand:FindFirstChild("Spawn", true)
	if spawn and spawn:IsA("BasePart") then
		-- Same front Decor cube as brainrot place/pickup prompts (not deep Spawn).
		return PlotStandPlaceholders.findPromptAnchorPart(stand, spawn :: BasePart)
	end
	if stand.PrimaryPart then
		return stand.PrimaryPart
	end
	return stand:FindFirstChildWhichIsA("BasePart", true)
end

local function stealRarityLabel(rarity: string): string
	local key = StoreConfig.normalizeStealRarity(rarity)
	local upper = BrainrotHeaderStyle.RARITY_DISPLAY_NAME[key]
	if typeof(upper) == "string" and upper ~= "" then
		return upper:sub(1, 1) .. upper:sub(2):lower()
	end
	if #key <= 1 then
		return string.upper(key)
	end
	return key:sub(1, 1):upper() .. key:sub(2)
end

local function stealTitleText(stand: Model): string
	local rarity = resolveStandRarity(stand)
	if typeof(rarity) == "string" and rarity ~= "" then
		return string.format("Steal (%s) Brainrot", stealRarityLabel(rarity))
	end
	return "Steal Brainrot"
end

local function stealCostText(stand: Model): string
	local free = player:GetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT)
	if typeof(free) == "number" and free > 0 then
		return string.format("Free · %d left", free)
	end
	local rarity = resolveStandRarity(stand)
	if typeof(rarity) == "string" then
		local price = liveStealPrice(rarity)
		if price then
			return string.format("R$%d", price)
		end
	end
	return "Steal"
end

local function standDistance(stand: Model): number?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end
	-- Cheap pivot distance first; only resolve Decor anchor when in range.
	local ok, pivot = pcall(function()
		return stand:GetPivot()
	end)
	if ok and typeof(pivot) == "CFrame" then
		local rough = ((hrp :: BasePart).Position - pivot.Position).Magnitude
		if rough > MAX_DISTANCE + 12 then
			return rough
		end
	end
	local anchor = standAnchorPart(stand)
	if not anchor then
		return if ok and typeof(pivot) == "CFrame" then ((hrp :: BasePart).Position - pivot.Position).Magnitude else nil
	end
	return ((hrp :: BasePart).Position - anchor.Position).Magnitude
end

local function isStandStealEligible(stand: Model): boolean
	local owner = stand:GetAttribute("StandOwnerUserId")
	local hasBrainrot = typeof(stand:GetAttribute("BrainrotName")) == "string"
	return hasBrainrot and typeof(owner) == "number" and owner ~= player.UserId
end

local function refreshStealPromptVisibility()
	local closestStand: Model? = nil
	local closestDist = math.huge

	for stand, prompt in stealPrompts do
		if not stand.Parent or not prompt.Parent then
			continue
		end

		-- Never tear down mid-hold — disable cancels PromptTriggered before the product popup.
		if ProximityPromptEffects.isPromptHolding(prompt) then
			if prompt.Enabled then
				closestStand = stand
				closestDist = 0
			end
			continue
		end

		if not isStandStealEligible(stand) then
			if prompt.Enabled then
				prompt.Enabled = false
				ProximityPromptEffects.forceHide(prompt)
			end
			continue
		end

		prompt.ActionText = stealTitleText(stand)
		prompt.ObjectText = stealCostText(stand)

		local dist = standDistance(stand)
		if not dist or dist > MAX_DISTANCE then
			if prompt.Enabled then
				prompt.Enabled = false
				ProximityPromptEffects.forceHide(prompt)
			end
			continue
		end

		if not ProximityPromptEffects.isPromptFacingCamera(prompt) then
			if prompt.Enabled then
				prompt.Enabled = false
				ProximityPromptEffects.forceHide(prompt)
			end
			continue
		end

		if dist < closestDist then
			closestDist = dist
			closestStand = stand
		end
	end

	for stand, prompt in stealPrompts do
		if not stand.Parent or not prompt.Parent then
			continue
		end
		if ProximityPromptEffects.isPromptHolding(prompt) then
			continue
		end
		local shouldShow = stand == closestStand
		if shouldShow then
			prompt.ActionText = stealTitleText(stand)
			prompt.ObjectText = stealCostText(stand)
			if not prompt.Enabled then
				prompt.Enabled = true
				ProximityPromptEffects.syncStandPlaceProximityUi(prompt)
			end
		elseif prompt.Enabled then
			prompt.Enabled = false
			ProximityPromptEffects.forceHide(prompt)
		end
	end
end

local function ensureStealPrompt(stand: Model): ProximityPrompt?
	local existing = stealPrompts[stand]
	local anchor = standAnchorPart(stand)
	if not anchor then
		return nil
	end
	if existing and existing.Parent then
		existing.MaxActivationDistance = MAX_DISTANCE
		if existing.Parent ~= anchor then
			existing.Parent = anchor
		end
		return existing
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ObjectText = "Steal"
	prompt.ActionText = "Steal Brainrot"
	prompt.HoldDuration = HOLD_DURATION
	prompt.MaxActivationDistance = MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Enabled = false
	prompt:SetAttribute("StealPrompt", true)
	prompt.Parent = anchor
	ProximityPromptEffects.stylePrompt(prompt)

	prompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer ~= player then
			return
		end
		local re = getStealRemote()
		if re then
			re:FireServer(stand)
		end
	end)

	stealPrompts[stand] = prompt
	return prompt
end

local function refreshStand(stand: Model)
	if not isStandStealEligible(stand) then
		local p = stealPrompts[stand]
		if p then
			p.Enabled = false
			ProximityPromptEffects.forceHide(p)
		end
		return
	end

	local prompt = ensureStealPrompt(stand)
	if prompt then
		prompt.ActionText = stealTitleText(stand)
		prompt.ObjectText = stealCostText(stand)
	end
end

local function hookStand(stand: Instance)
	if not stand:IsA("Model") then
		return
	end
	local model = stand :: Model
	for _, attr in { "StandOwnerUserId", "BrainrotName", "BrainrotRarity" } do
		model:GetAttributeChangedSignal(attr):Connect(function()
			refreshStand(model)
			refreshStealPromptVisibility()
		end)
	end
	refreshStand(model)
end

local function wirePurchaseAndNotifs()
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("StoreRemotes", 30)
		if not folder then
			return
		end
		local promptRE = folder:WaitForChild("StealPromptProduct", 15)
		if promptRE and promptRE:IsA("RemoteEvent") then
			promptRE.OnClientEvent:Connect(function(productId: any)
				if typeof(productId) ~= "number" then
					return
				end
				PurchasePrompt.promptProduct(productId)
			end)
		end
		local successRE = folder:WaitForChild("StealSuccess", 15)
		if successRE and successRE:IsA("RemoteEvent") then
			successRE.OnClientEvent:Connect(function(payload: any)
				local name = if typeof(payload) == "table" and typeof(payload.name) == "string"
					then payload.name
					else "Brainrot"
				local rarity = if typeof(payload) == "table" and typeof(payload.rarity) == "string"
					then payload.rarity
					else "common"
				local display = formatDisplayName(name)
				local msg = string.format("Successfully stolen %s!", display)
				pcall(function()
					TopNotifController.showRaritySpawn(msg, StoreConfig.normalizeStealRarity(rarity), 4.5)
				end)
				pcall(function()
					GameSoundEffects.playPurchase()
				end)
			end)
		end
		local failedRE = folder:WaitForChild("StealFailed", 15)
		if failedRE and failedRE:IsA("RemoteEvent") then
			failedRE.OnClientEvent:Connect(function(message: any)
				local msg = if typeof(message) == "string" and message ~= ""
					then message
					else "Steal failed."
				pcall(function()
					TopNotifController.showError(msg)
				end)
			end)
		end
	end)
end

local function startVisibilityLoop()
	if visibilityConn then
		return
	end
	visibilityConn = RunService.Heartbeat:Connect(function(dt)
		visibilityAccum += dt
		if visibilityAccum < VISIBILITY_REFRESH_INTERVAL then
			return
		end
		visibilityAccum = 0
		refreshStealPromptVisibility()
	end)
end

local function init()
	wirePurchaseAndNotifs()
	startVisibilityLoop()

	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		hookStand(stand)
	end
	CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(hookStand)
	CollectionService:GetInstanceRemovedSignal(STAND_TAG):Connect(function(stand)
		if stand:IsA("Model") then
			stealPrompts[stand :: Model] = nil
		end
	end)

	player:GetAttributeChangedSignal(StoreConfig.ATTR.FREE_STEAL_COUNT):Connect(function()
		refreshStealPromptVisibility()
	end)

	prefetchStealPrices()
	task.defer(refreshStealPromptVisibility)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[StealController]", err)
	end
end

StealController.init = boot
return StealController
