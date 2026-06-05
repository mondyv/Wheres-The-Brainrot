-- [ACTIVE] BoosterPackShowers.server
--[[
	Map.Booster Pack Showers — walking onto a stand Hitbox prompts that pack's dev product.
	Stand folders: Starter Stand, Mythic Stand, Godly Stand, Secret Stand (each has Hitbox).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local SHOWERS_FOLDER_NAME = "Booster Pack Showers"
local TOUCH_COOLDOWN_SEC = 3

-- Studio stand folder name → StoreConfig.PACKS frameName
local STAND_FRAME_NAMES: { [string]: string } = {
	["Starter Stand"] = "StarterPack",
	["Mythic Stand"] = "MythicPack",
	["Godly Stand"] = "GodlyPack",
	["Secret Stand"] = "SecretPack",
}

local packByFrameName: { [string]: typeof(StoreConfig.PACKS[1]) } = {}
for _, pack in StoreConfig.PACKS do
	packByFrameName[pack.frameName] = pack
end

local touchCooldown: { [Player]: { [string]: boolean } } = {}

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

local function wireHitbox(standFolder: Instance, pack: typeof(StoreConfig.PACKS[1]))
	local hitbox = standFolder:FindFirstChild("Hitbox")
	if not hitbox or not hitbox:IsA("BasePart") then
		warn("[BoosterPackShowers] Hitbox missing on", standFolder:GetFullName())
		return
	end
	hitbox.CanTouch = true
	local standKey = standFolder.Name
	hitbox.Touched:Connect(function(other: BasePart)
		local character = other.Parent
		if not character then
			return
		end
		local plr = Players:GetPlayerFromCharacter(character)
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
		promptPackPurchase(plr, pack)
		task.delay(TOUCH_COOLDOWN_SEC, function()
			if touchCooldown[plr] then
				touchCooldown[plr][standKey] = nil
			end
		end)
	end)
end

local function wireShowersRoot(root: Instance)
	for standName, frameName in STAND_FRAME_NAMES do
		local pack = packByFrameName[frameName]
		if not pack then
			warn("[BoosterPackShowers] No pack config for frame:", frameName)
			continue
		end
		local stand = root:FindFirstChild(standName)
		if stand then
			wireHitbox(stand, pack)
		else
			warn("[BoosterPackShowers] Stand not found:", standName, "under", root:GetFullName())
		end
	end
end

local function tryInit()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return false
	end
	local showers = map:FindFirstChild(SHOWERS_FOLDER_NAME)
	if not showers then
		return false
	end
	wireShowersRoot(showers)
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
		wireShowersRoot(showers)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	touchCooldown[player] = nil
end)
