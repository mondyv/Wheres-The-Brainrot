-- [ACTIVE] BoosterPackShowers.server
--[[
	Map.Booster Pack Showers — walking onto a stand Hitbox prompts that pack's dev product.
	Stand folders: Starter Stand, Mythic Stand, Godly Stand, Secret Stand, StrawberryElephantStand,
	Group Stand (Roblox community join UI always; one-time random rare brainrot on first claim).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local Brainrots = require(script.Parent:WaitForChild("Modules"):WaitForChild("Brainrots"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

local SHOWERS_FOLDER_NAME = "Booster Pack Showers"
local TOUCH_COOLDOWN_SEC = 3
local EXCLUSIVE_STAND_NAME = "StrawberryElephantStand"
local GROUP_STAND_NAME = StoreConfig.GROUP_STAND_NAME
local GROUP_ID = StoreConfig.GROUP_ID
local ZONE_POLL_SEC = 0.25
local PROMPT_REMOTE_FOLDER = "StoreRemotes"
local PROMPT_REMOTE_NAME = "BoosterShowerProductPrompt"
local GROUP_PROMPT_REMOTE_NAME = "GroupStandPrompt"
local GROUP_CLAIM_REMOTE_NAME = "GroupStandClaim"
local GROUP_LIKED_REMOTE_NAME = "GroupStandLiked"
local GROUP_MEMBERSHIP_RETRY_SEC = 8

local EXCLUSIVE_PRODUCT_ID = StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT
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
local wiredStands: { [Instance]: boolean } = {}
local wiredHitboxes: { [BasePart]: boolean } = {}
local claimInFlight: { [Player]: boolean } = {}
local promptProductRemote: RemoteEvent? = nil
local groupClaimRemote: RemoteFunction? = nil
local groupLikedRemote: RemoteEvent? = nil

local function ensureStoreRemote(name: string): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild(PROMPT_REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = PROMPT_REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild(name)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = name
		ev.Parent = folder
	end
	return ev :: RemoteEvent
end

local function ensureStoreRemoteFunction(name: string): RemoteFunction
	local folder = ReplicatedStorage:FindFirstChild(PROMPT_REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = PROMPT_REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

local function ensurePromptProductRemote(): RemoteEvent
	if promptProductRemote and promptProductRemote.Parent then
		return promptProductRemote
	end
	promptProductRemote = ensureStoreRemote(PROMPT_REMOTE_NAME)
	return promptProductRemote
end

local function ensureGroupClaimRemote(): RemoteFunction
	if groupClaimRemote and groupClaimRemote.Parent then
		return groupClaimRemote
	end
	groupClaimRemote = ensureStoreRemoteFunction(GROUP_CLAIM_REMOTE_NAME)
	return groupClaimRemote
end

local function ensureGroupLikedRemote(): RemoteEvent
	if groupLikedRemote and groupLikedRemote.Parent then
		return groupLikedRemote
	end
	groupLikedRemote = ensureStoreRemote(GROUP_LIKED_REMOTE_NAME)
	return groupLikedRemote
end

local function firePurchaseEffect(player: Player)
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local events = assets and assets:FindFirstChild("Events")
	local re = events and events:FindFirstChild("PurchaseEffectShow")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player)
	end
end

local function fireConfetti(player: Player)
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local events = assets and assets:FindFirstChild("Events")
	local re = events and events:FindFirstChild("ProductHandlerConfetti")
	if re and re:IsA("RemoteEvent") then
		re:FireClient(player)
	end
end

local function packRemaining(player: Player, pack: typeof(StoreConfig.PACKS[1])): number
	local bought = player:GetAttribute(pack.boughtAttr)
	local count = if typeof(bought) == "number" then bought else 0
	return math.max(0, StoreConfig.PACK_PURCHASE_LIMIT - count)
end

local function promptProductPurchase(player: Player, productId: number, context: string)
	local productKind = if string.find(context, "exclusive:", 1, true) then "exclusive" else "product"
	local remote = ensurePromptProductRemote()
	if remote then
		remote:FireClient(player, productId, productKind)
		return
	end
	firePurchaseEffect(player)
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	if not ok then
		warn("[BoosterPackShowers] PromptProductPurchase failed:", player.Name, productId, err)
	end
end

local function promptPackPurchase(player: Player, pack: typeof(StoreConfig.PACKS[1]))
	if packRemaining(player, pack) <= 0 then
		return
	end
	promptProductPurchase(player, pack.productId, "pack:" .. pack.frameName)
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
	for _, desc in stand:GetDescendants() do
		if desc:IsA("BasePart") and string.lower(desc.Name) == "hitbox" then
			return desc
		end
	end
	return nil
end

local function isOnCooldown(plr: Player, standKey: string): boolean
	local bucket = touchCooldown[plr]
	return bucket ~= nil and bucket[standKey] == true
end

local function setCooldown(plr: Player, standKey: string)
	if not touchCooldown[plr] then
		touchCooldown[plr] = {}
	end
	touchCooldown[plr][standKey] = true
	task.delay(TOUCH_COOLDOWN_SEC, function()
		if touchCooldown[plr] then
			touchCooldown[plr][standKey] = nil
		end
	end)
end

local function tryRunPrompt(plr: Player, standKey: string, onPrompt: (Player) -> (), _source: string): boolean
	if isOnCooldown(plr, standKey) then
		return false
	end
	setCooldown(plr, standKey)
	onPrompt(plr)
	return true
end

local function playerInsideHitbox(plr: Player, hitbox: BasePart): boolean
	local character = plr.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local cf = hitbox.CFrame
	local half = hitbox.Size * 0.5
	local padXZ = 2.5
	local localPos = cf:PointToObjectSpace(hrp.Position)

	if math.abs(localPos.X) > half.X + padXZ or math.abs(localPos.Z) > half.Z + padXZ then
		return false
	end

	-- Player often stands on the stand mesh above a thin floor hitbox.
	local yMin = -half.Y - 3
	local yMax = half.Y + 10
	return localPos.Y >= yMin and localPos.Y <= yMax
end

local function bindHitboxTouch(stand: Instance, hitbox: BasePart, onPrompt: (Player) -> ())
	if wiredStands[stand] then
		return
	end
	wiredStands[stand] = true
	stand:SetAttribute("_BoosterShowerHitboxWired", nil)

	hitbox.CanTouch = true
	hitbox.CanQuery = true
	local standKey = stand.Name

	hitbox.Touched:Connect(function(other: BasePart)
		if not other:IsA("BasePart") then
			return
		end
		local plr = playerFromTouchPart(other)
		if not plr then
			return
		end
		tryRunPrompt(plr, standKey, onPrompt, "Touched")
	end)

	stand.Destroying:Once(function()
		wiredStands[stand] = nil
	end)
end

local function bindZoneFallback(stand: Instance, hitbox: BasePart, onPrompt: (Player) -> ())
	if wiredHitboxes[hitbox] then
		return
	end
	wiredHitboxes[hitbox] = true
	local standKey = stand.Name
	task.spawn(function()
		while hitbox.Parent and stand.Parent do
			task.wait(ZONE_POLL_SEC)
			for _, plr in Players:GetPlayers() do
				if playerInsideHitbox(plr, hitbox) then
					tryRunPrompt(plr, standKey, onPrompt, "ZonePoll")
				end
			end
		end
	end)
end

local function ensureHitboxWired(stand: Instance, onPrompt: (Player) -> (), useZoneFallback: boolean?)
	if wiredStands[stand] then
		return true
	end

	local function tryWire(): boolean
		local hitbox = findStandHitbox(stand)
		if hitbox then
			bindHitboxTouch(stand, hitbox, onPrompt)
			if useZoneFallback then
				bindZoneFallback(stand, hitbox, onPrompt)
			end
			return wiredStands[stand] == true
		end
		return false
	end

	if tryWire() then
		return true
	end

	local conn: RBXScriptConnection?
	conn = stand.DescendantAdded:Connect(function(desc)
		if desc.Name == "Hitbox" and desc:IsA("BasePart") then
			if tryWire() and conn then
				conn:Disconnect()
				conn = nil
			end
		elseif string.lower(desc.Name) == "hitbox" and desc:IsA("BasePart") then
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
	return false
end

local function isStrawberryElephantStandName(name: string): boolean
	local lower = string.lower(name)
	return string.find(lower, "elephant", 1, true) ~= nil
		and string.find(lower, "stand", 1, true) ~= nil
		and string.find(lower, "straw", 1, true) ~= nil
end

local function exclusiveProductForStand(standName: string): number?
	if standName == EXCLUSIVE_STAND_NAME or isStrawberryElephantStandName(standName) then
		return EXCLUSIVE_PRODUCT_ID
	end
	return nil
end

local function wireExclusiveStand(stand: Instance, productId: number)
	ensureHitboxWired(stand, function(plr: Player)
		if plr:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
			return
		end
		promptProductPurchase(plr, productId, "exclusive:" .. stand.Name)
	end, true)
end

local function wirePackStand(stand: Instance, pack: typeof(StoreConfig.PACKS[1]))
	ensureHitboxWired(stand, function(plr: Player)
		promptPackPurchase(plr, pack)
	end, true)
end

local function wireGroupStand(stand: Instance)
	-- Client owns the stand charge timer and Frames["Free Rewards"] panel.
	wiredStands[stand] = true
end

local function waitForBrainrotGrantBF(timeoutSec: number?): BindableFunction?
	local deadline = os.clock() + (timeoutSec or 30)
	while os.clock() < deadline do
		local folder = ServerStorage:FindFirstChild("BrainrotInternal")
		local bf = folder and folder:FindFirstChild("GrantBrainrotAndEquip")
		if bf and bf:IsA("BindableFunction") then
			return bf
		end
		task.wait(0.25)
	end
	return nil
end

local function pickGroupRewardBrainrot(): typeof(Brainrots.BRAINROTS[1])?
	local named = Brainrots.getByName(StoreConfig.GROUP_REWARD_BRAINROT)
	if named then
		return named
	end
	local pool = Brainrots.brainrotsOfRarity("epic")
	if #pool == 0 then
		return nil
	end
	return pool[1]
end

local function playerIsInGroup(player: Player): boolean
	local ok, inGroup = pcall(function()
		return player:IsInGroup(GROUP_ID)
	end)
	if not ok then
		warn("[BoosterPackShowers] IsInGroup failed:", player.Name, inGroup)
		return false
	end
	return inGroup == true
end

local function waitUntilInGroup(player: Player, timeoutSec: number): boolean
	if playerIsInGroup(player) then
		return true
	end
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		task.wait(1)
		if not player.Parent then
			return false
		end
		if playerIsInGroup(player) then
			return true
		end
	end
	return false
end

local function grantGroupReward(player: Player): (boolean, string?)
	PlayerDataService.waitUntilLoaded(player)
	if not player.Parent then
		return false, "left"
	end
	if player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED) == true then
		return false, "already_claimed"
	end
	if claimInFlight[player] then
		return false, "busy"
	end
	claimInFlight[player] = true

	local ok, err = pcall(function()
		if player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_LIKED) ~= true then
			error("not_liked")
		end
		if not waitUntilInGroup(player, GROUP_MEMBERSHIP_RETRY_SEC) then
			error("not_in_group")
		end
		-- Re-check after membership wait (data load / parallel claim).
		if player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED) == true then
			error("already_claimed")
		end

		local pick = pickGroupRewardBrainrot()
		if not pick then
			error("no_epic_pool")
		end

		local grant = waitForBrainrotGrantBF(15)
		if not grant then
			error("grant_bindable_missing")
		end

		-- Lock claim before grant so double-fires can't award twice.
		player:SetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED, true)

		local grantedOk, granted = pcall(function()
			return grant:Invoke(player, {
				name = pick.name,
				rarity = pick.rarity,
				mutation = "normal",
				level = 1,
				baseIncome = pick.baseIncome,
				sourcePath = "GroupStand",
			}, { equip = true })
		end)
		if not grantedOk or granted ~= true then
			player:SetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED, false)
			error("grant_failed")
		end

		fireConfetti(player)
		if player:GetAttribute("PlayerDataLoaded") == true then
			PlayerDataService.savePlayerData(player)
		end
	end)

	claimInFlight[player] = nil
	if not ok then
		local msg = if typeof(err) == "string" then err else "claim_failed"
		if msg ~= "not_in_group" and msg ~= "already_claimed" and msg ~= "not_liked" then
			warn("[BoosterPackShowers] Group reward failed for", player.Name, msg)
		end
		return false, msg
	end
	return true, nil
end

local function tryWireStand(stand: Instance)
	if not stand:IsA("Model") and not stand:IsA("Folder") and not stand:IsA("BasePart") then
		return
	end
	if wiredStands[stand] then
		return
	end

	if stand.Name == GROUP_STAND_NAME then
		wireGroupStand(stand)
		return
	end

	local frameName = STAND_FRAME_NAMES[stand.Name]
	if frameName then
		local pack = packByFrameName[frameName]
		if pack then
			wirePackStand(stand, pack)
		end
		return
	end

	local productId = exclusiveProductForStand(stand.Name)
	if productId then
		wireExclusiveStand(stand, productId)
	end
end

local function wireShowersRoot(root: Instance)
	for standName in STAND_FRAME_NAMES do
		local stand = root:FindFirstChild(standName)
		if stand then
			tryWireStand(stand)
		end
	end

	local exclusiveStand = root:FindFirstChild(EXCLUSIVE_STAND_NAME)
	if exclusiveStand then
		tryWireStand(exclusiveStand)
	end

	local groupStand = root:FindFirstChild(GROUP_STAND_NAME)
	if groupStand then
		tryWireStand(groupStand)
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
local mapHooked = false

local function hookShowersFolder(showers: Instance)
	if hookedShowersRoot == showers then
		return
	end
	hookedShowersRoot = showers
	wireShowersRoot(showers)
end

local function hookMap(map: Instance)
	local showers = map:FindFirstChild(SHOWERS_FOLDER_NAME)
	if showers then
		hookShowersFolder(showers)
	end
	map.ChildAdded:Connect(function(child)
		if child.Name == SHOWERS_FOLDER_NAME then
			hookShowersFolder(child)
		end
	end)
end

local function ensureMapHooked()
	if mapHooked then
		return
	end
	local map = Workspace:FindFirstChild("Map")
	if map then
		mapHooked = true
		hookMap(map)
		return
	end
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Map" and not mapHooked then
			mapHooked = true
			hookMap(child)
		end
	end)
end

ensurePromptProductRemote()
ensureGroupLikedRemote().OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED) == true then
		return
	end
	player:SetAttribute(StoreConfig.ATTR.GROUP_REWARD_LIKED, true)
	if player:GetAttribute("PlayerDataLoaded") == true then
		pcall(function()
			PlayerDataService.savePlayerData(player)
		end)
	end
end)
ensureGroupClaimRemote().OnInvoke = function(player: Player): (boolean, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "invalid"
	end
	return grantGroupReward(player)
end

ensureMapHooked()
task.spawn(function()
	local map = Workspace:WaitForChild("Map", 120)
	if not map then
		warn("[BoosterPackShowers] Workspace.Map missing after 120s")
		return
	end
	if not mapHooked then
		mapHooked = true
		hookMap(map)
	end
	local showers = map:WaitForChild(SHOWERS_FOLDER_NAME, 120)
	if not showers then
		warn("[BoosterPackShowers] Booster Pack Showers missing after 120s")
		return
	end
	hookShowersFolder(showers)
end)

Players.PlayerRemoving:Connect(function(player)
	touchCooldown[player] = nil
	claimInFlight[player] = nil
end)
