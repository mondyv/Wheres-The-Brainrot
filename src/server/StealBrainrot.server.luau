--[[
	StealBrainrot.server
	Lets a player steal a brainrot sitting on ANOTHER player's stand.

	Flow:
	  1. Client (StealController) fires StealRequest with the target stand model.
	  2. If the thief has VIP free steals (FreeStealCount > 0), the steal happens
	     immediately for free (counter decremented).
	  3. Otherwise the matching rarity developer product is prompted. On a granted
	     receipt the pending steal is executed.

	Stealing = remove the brainrot from the victim's stand (via
	ServerStorage.StandInternal.StealBrainrotFromStand) and grant a copy to the
	thief through the existing BrainrotInternal.GrantBrainrotAndEquip path.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local Brainrots = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("Brainrots"))

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local STEAL_RANGE = 32

-- ── Remotes ─────────────────────────────────────────────────────────────────────

local function ensureRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "StoreRemotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = ensureRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local stealRequestRE = ensureRemoteEvent("StealRequest")

-- ── Internal bindable lookups ─────────────────────────────────────────────────

local function waitBindable(folderName: string, name: string, timeout: number?): BindableFunction?
	local deadline = os.clock() + (timeout or 30)
	repeat
		local folder = ServerStorage:FindFirstChild(folderName)
		local bf = folder and folder:FindFirstChild(name)
		if bf and bf:IsA("BindableFunction") then
			return bf
		end
		task.wait(0.2)
	until os.clock() >= deadline
	return nil
end

local function grantBrainrotToThief(thief: Player, stats: { [string]: any })
	local bf = waitBindable("BrainrotInternal", "GrantBrainrotAndEquip", 5)
	if not bf then
		return false
	end
	local ok = pcall(function()
		bf:Invoke(thief, {
			name = stats.name,
			rarity = stats.rarity,
			mutation = stats.mutation or "normal",
			level = if typeof(stats.level) == "number" then stats.level else 1,
			baseIncome = if typeof(stats.baseIncome) == "number" then stats.baseIncome else 0,
		}, { equip = false })
	end)
	return ok
end

local function fireThiefFeedback(thief: Player, stats: { [string]: any })
	local sfx = ReplicatedStorage:FindFirstChild("PlayBrainrotSFX")
	if sfx and sfx:IsA("RemoteEvent") and typeof(stats.name) == "string" then
		sfx:FireClient(thief, stats.name)
	end
	local dropFX = ReplicatedStorage:FindFirstChild("PlayHarvestDropFX")
	if dropFX and dropFX:IsA("RemoteEvent") and typeof(stats.rarity) == "string" then
		dropFX:FireClient(thief, stats.rarity)
	end
end

-- ── Validation ─────────────────────────────────────────────────────────────────

local function standHasBrainrot(stand: Instance): boolean
	return typeof(stand:GetAttribute("BrainrotName")) == "string"
end

local function standOwnerId(stand: Instance): number?
	local id = stand:GetAttribute("StandOwnerUserId")
	return if typeof(id) == "number" then id else nil
end

local function standWorldPosition(stand: Instance): Vector3?
	if stand:IsA("Model") then
		local ok, cf = pcall(function()
			return (stand :: Model):GetPivot()
		end)
		if ok then
			return cf.Position
		end
	end
	local part = stand:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position or nil
end

-- Returns the rarity of the brainrot on the stand, or nil.
local function standRarity(stand: Instance): string?
	local r = stand:GetAttribute("BrainrotRarity")
	return if typeof(r) == "string" then r else nil
end

local function canSteal(thief: Player, stand: Instance): boolean
	if not stand or not stand.Parent then
		return false
	end
	if not standHasBrainrot(stand) then
		return false
	end
	local owner = standOwnerId(stand)
	if owner == nil or owner == thief.UserId then
		return false -- can't steal from your own / unowned stands
	end
	local char = thief.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local standPos = standWorldPosition(stand)
	if hrp and standPos and (hrp.Position - standPos).Magnitude > STEAL_RANGE then
		return false
	end
	return true
end

-- ── Execution ────────────────────────────────────────────────────────────────

local function executeSteal(thief: Player, stand: Instance?, fallbackRarity: string?): boolean
	local stealBF = waitBindable("StandInternal", "StealBrainrotFromStand", 5)
	local stolen: any = nil
	if stealBF and stand then
		local ok, result = pcall(function()
			return stealBF:Invoke(stand, thief)
		end)
		if ok and typeof(result) == "table" then
			stolen = result
		end
	end

	if not stolen then
		-- Stand emptied before the steal resolved (e.g. paid purchase finished late).
		-- Grant a random brainrot of the rarity that was paid for so the purchase isn't wasted.
		local rarity = fallbackRarity
		if typeof(rarity) ~= "string" then
			return false
		end
		local pool = Brainrots.brainrotsOfRarity(rarity)
		if #pool == 0 then
			return false
		end
		local def = pool[math.random(1, #pool)]
		stolen = { name = def.name, rarity = def.rarity, mutation = "normal", level = 1, baseIncome = def.baseIncome }
	end

	local granted = grantBrainrotToThief(thief, stolen)
	if granted then
		fireThiefFeedback(thief, stolen)
	end
	return granted
end

-- ── Pending paid steals ─────────────────────────────────────────────────────────

type Pending = { stand: Instance, rarity: string }
local pendingSteal: { [Player]: Pending } = {}

local function rarityFromProductId(productId: number): string?
	for rarity, id in StoreConfig.STEAL_PRODUCT_BY_RARITY do
		if id == productId then
			return rarity
		end
	end
	return nil
end

-- ── Request handler ──────────────────────────────────────────────────────────────

stealRequestRE.OnServerEvent:Connect(function(thief: Player, standArg: any)
	if typeof(standArg) ~= "Instance" then
		return
	end
	local stand = standArg :: Instance
	if not canSteal(thief, stand) then
		warn("[Steal] request denied for", thief.Name, "stand:", stand and stand.Name, "(out of range / own / empty)")
		return
	end

	local freeSteals = thief:GetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT)
	warn("[Steal] request by", thief.Name, "freeSteals:", freeSteals, "rarity:", standRarity(stand))
	if typeof(freeSteals) == "number" and freeSteals > 0 then
		-- Free steal (VIP) — atomic.
		if executeSteal(thief, stand) then
			thief:SetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT, freeSteals - 1)
		else
			warn("[Steal] free steal execution failed for", thief.Name)
		end
		return
	end

	-- Paid steal — prompt the rarity-specific product.
	local rarity = standRarity(stand)
	if not rarity then
		warn("[Steal] no rarity on stand for", thief.Name)
		return
	end
	local productId = StoreConfig.STEAL_PRODUCT_BY_RARITY[rarity]
	if not productId then
		warn("[Steal] no steal product mapped for rarity:", rarity)
		return
	end
	pendingSteal[thief] = { stand = stand, rarity = rarity }
	MarketplaceService:PromptProductPurchase(thief, productId)
end)

Players.PlayerRemoving:Connect(function(player)
	pendingSteal[player] = nil
end)

-- ── Receipt registration ─────────────────────────────────────────────────────────

local function resolveProductHandlerServer(): any?
	local essentials = ServerScriptService:FindFirstChild("EssentialsServer")
	local folder = essentials and essentials:FindFirstChild("ProductHandler")
	local moduleScript = folder and folder:FindFirstChild("ProductHandlerServer")
	if not moduleScript then
		return nil
	end
	local ok, loaded = pcall(require, moduleScript)
	return ok and loaded or nil
end

local function registerStealReceipts()
	local PH = resolveProductHandlerServer()
	if not PH or typeof(PH.registerProductReceipt) ~= "function" then
		warn("[StealBrainrot] ProductHandlerServer.registerProductReceipt unavailable")
		return
	end
	for _, productId in StoreConfig.STEAL_PRODUCT_BY_RARITY do
		PH.registerProductReceipt(productId, function(thief, receiptInfo)
			local pending = pendingSteal[thief]
			local fallbackRarity = rarityFromProductId(receiptInfo.ProductId)
			pendingSteal[thief] = nil
			if pending and canSteal(thief, pending.stand) then
				executeSteal(thief, pending.stand, fallbackRarity)
			else
				-- Stand changed; still honor the purchase with a fallback grant.
				executeSteal(thief, nil, fallbackRarity)
			end
			return GRANTED
		end)
	end
end

registerStealReceipts()
