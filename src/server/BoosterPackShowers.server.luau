-- [ACTIVE] BoosterPackShowers.server
--[[
	Map.Booster Pack Showers — walking onto a stand Hitbox prompts that pack's dev product.
	Stand folders: Starter Stand, Mythic Stand, Godly Stand, Secret Stand, StrawbeerryElephantStand.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local SHOWERS_FOLDER_NAME = "Booster Pack Showers"
local TOUCH_COOLDOWN_SEC = 3
local WIRED_ATTR = "_BoosterShowerHitboxWired"

-- Studio stand folder name → StoreConfig.PACKS frameName
local STAND_FRAME_NAMES: { [string]: string } = {
	["Starter Stand"] = "StarterPack",
	["Mythic Stand"] = "MythicPack",
	["Godly Stand"] = "GodlyPack",
	["Secret Stand"] = "SecretPack",
}

local EXCLUSIVE_STAND_PRODUCTS: { [string]: number } = {
	["StrawbeerryElephantStand"] = StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT,
	["StrawberryElephantStand"] = StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT,
}

local packByFrameName: { [string]: typeof(StoreConfig.PACKS[1]) } = {}
for _, pack in StoreConfig.PACKS do
	packByFrameName[pack.frameName] = pack
end

local touchCooldown: { [Player]: { [string]: boolean } } = {}
local wiredStands: { [Instance]: boolean } = {}

local function firePurchaseEffect(player: Player)
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local events = assets and assets:FindFirstChild("Events")
	local re = events and events:FindFirstChild("PurchaseEffectShow")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player)
	end
end

local function packRemaining(player: Player, pack: typeof(StoreConfig.PACKS[1])): number
	local bought = player:GetAttribute(pack.boughtAttr)
	local count = if typeof(bought) == "number" then bought else 0
	return math.max(0, StoreConfig.PACK_PURCHASE_LIMIT - count)
end

local function promptPackPurchase(player: Player, pack: typeof(StoreConfig.PACKS[1]))
	if packRemaining(player, pack) <= 0 then
		return
	end
	firePurchaseEffect(player)
	MarketplaceService:PromptProductPurchase(player, pack.productId)
end

local function playerFromTouchPart(other: BasePart): Player?
	local character = other:FindFirstAncestorWhichIsA("Model")
	if not character then
		return nil
	end
	return Players:GetPlayerFromCharacter(character)
end

local function findStandHitbox(stand: Instance): BasePart?
	local direct = stand:FindFirstChild("Hitbox")
	if direct and direct:IsA("BasePart") then
		return direct
	end
	local nested = stand:FindFirstChild("Hitbox", true)
	if nested and nested:IsA("BasePart") then
		return nested
	end
	return nil
end

local function bindHitboxTouch(stand: Instance, hitbox: BasePart, onPrompt: (Player) -> ())
	if wiredStands[stand] or stand:GetAttribute(WIRED_ATTR) == true then
		return
	end
	wiredStands[stand] = true
	stand:SetAttribute(WIRED_ATTR, true)

	hitbox.CanTouch = true
	local standKey = stand.Name
	hitbox.Touched:Connect(function(other: BasePart)
		if not other:IsA("BasePart") then
			return
		end
		local plr = playerFromTouchPart(other)
		if not plr then
			return
		end
		if not touchCooldown[plr] then
			touchCooldown[plr] = {}
		end
		if touchCooldown[plr][standKey] then
			return
		end
		touchCooldown[plr][standKey] = true
		onPrompt(plr)
		task.delay(TOUCH_COOLDOWN_SEC, function()
			if touchCooldown[plr] then
				touchCooldown[plr][standKey] = nil
			end
		end)
	end)

	stand.Destroying:Once(function()
		wiredStands[stand] = nil
	end)
end

local function ensureHitboxWired(stand: Instance, onPrompt: (Player) -> ())
	if wiredStands[stand] or stand:GetAttribute(WIRED_ATTR) == true then
		return
	end

	local function tryWire(): boolean
		local hitbox = findStandHitbox(stand)
		if hitbox then
			bindHitboxTouch(stand, hitbox, onPrompt)
			return wiredStands[stand] == true
		end
		return false
	end

	if tryWire() then
		return
	end

	local conn: RBXScriptConnection?
	conn = stand.DescendantAdded:Connect(function(desc)
		if desc.Name == "Hitbox" and desc:IsA("BasePart") then
			if tryWire() and conn then
				conn:Disconnect()
				conn = nil
			end
		end
	end)
	stand.Destroying:Once(function()
		if conn then
			conn:Disconnect()
		end
	end)
end

local function isStrawberryElephantStandName(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "elephant", 1, true) ~= nil
		and string.find(lower, "stand", 1, true) ~= nil
		and string.find(lower, "straw", 1, true) ~= nil
end

local function exclusiveProductForStand(standName: string): number?
	local direct = EXCLUSIVE_STAND_PRODUCTS[standName]
	if direct then
		return direct
	end
	if isStrawberryElephantStandName(standName) then
		return StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT
	end
	return nil
end

local function wireExclusiveStand(stand: Instance, productId: number)
	ensureHitboxWired(stand, function(plr: Player)
		if plr:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
			return
		end
		firePurchaseEffect(plr)
		MarketplaceService:PromptProductPurchase(plr, productId)
	end)
end

local function wirePackStand(stand: Instance, pack: typeof(StoreConfig.PACKS[1]))
	ensureHitboxWired(stand, function(plr: Player)
		promptPackPurchase(plr, pack)
	end)
end

local function tryWireStand(stand: Instance)
	if not stand:IsA("Model") and not stand:IsA("Folder") then
		return
	end

	local frameName = STAND_FRAME_NAMES[stand.Name]
	if frameName then
		local pack = packByFrameName[frameName]
		if pack then
			wirePackStand(stand, pack)
		else
			warn("[BoosterPackShowers] No pack config for frame:", frameName)
		end
		return
	end

	local productId = exclusiveProductForStand(stand.Name)
	if productId then
		wireExclusiveStand(stand, productId)
	end
end

local function wireShowersRoot(root: Instance)
	for standName, frameName in STAND_FRAME_NAMES do
		local stand = root:FindFirstChild(standName)
		if stand then
			tryWireStand(stand)
		else
			warn("[BoosterPackShowers] Stand not found:", standName, "under", root:GetFullName())
		end
	end

	for standName in EXCLUSIVE_STAND_PRODUCTS do
		local stand = root:FindFirstChild(standName)
		if stand then
			tryWireStand(stand)
		end
	end

	for _, child in root:GetChildren() do
		if exclusiveProductForStand(child.Name) and not STAND_FRAME_NAMES[child.Name] then
			tryWireStand(child)
		end
	end

	root.ChildAdded:Connect(function(child)
		task.defer(function()
			tryWireStand(child)
		end)
	end)
end

local hookedShowersRoot: Instance? = nil

local function hookShowersFolder(showers: Instance)
	if hookedShowersRoot == showers then
		return
	end
	hookedShowersRoot = showers
	wireShowersRoot(showers)
end

local function tryInit(): boolean
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return false
	end
	local showers = map:FindFirstChild(SHOWERS_FOLDER_NAME)
	if not showers then
		return false
	end
	hookShowersFolder(showers)
	return true
end

if not tryInit() then
	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 120)
		if not map then
			warn("[BoosterPackShowers] Workspace.Map missing")
			return
		end
		local showers = map:WaitForChild(SHOWERS_FOLDER_NAME, 120)
		if not showers then
			warn("[BoosterPackShowers] Map.Booster Pack Showers missing")
			return
		end
		hookShowersFolder(showers)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	touchCooldown[player] = nil
end)
