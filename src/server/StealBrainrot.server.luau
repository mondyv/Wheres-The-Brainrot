-- [ACTIVE] StealBrainrot.server
--[[
	StealBrainrot.server
	Lets a player steal a brainrot sitting on ANOTHER player's stand.

	Flow:
	  1. Client (StealController) fires StealRequest with the target stand model.
	  2. If the thief has VIP free steals (FreeStealCount > 0), the steal happens
	     immediately for free (counter decremented).
	  3. Otherwise the matching rarity developer product is prompted on the client
	     (PurchasePrompt / rainbow). On a granted receipt the pending steal runs.

	Stealing = remove the brainrot from the victim's stand (via
	ServerStorage.StandInternal.StealBrainrotFromStand) and grant a copy to the
	thief through BrainrotInternal.GrantBrainrotAndEquip.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local Brainrots = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("Brainrots"))

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local STEAL_RANGE = 32

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
local stealPromptProductRE = ensureRemoteEvent("StealPromptProduct")
local stealSuccessRE = ensureRemoteEvent("StealSuccess")
local stealFailedRE = ensureRemoteEvent("StealFailed")

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

local function grantBrainrotToThief(thief: Player, stats: { [string]: any }): boolean
	local bf = waitBindable("BrainrotInternal", "GrantBrainrotAndEquip", 5)
	if not bf then
		warn("[Steal] GrantBrainrotAndEquip missing")
		return false
	end
	local ok = pcall(function()
		bf:Invoke(thief, {
			name = stats.name,
			rarity = stats.rarity,
			mutation = stats.mutation or "normal",
			level = if typeof(stats.level) == "number" then stats.level else 1,
			baseIncome = if typeof(stats.baseIncome) == "number" then stats.baseIncome else 0,
		}, { equip = true })
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
	if stealSuccessRE then
		stealSuccessRE:FireClient(thief, {
			name = stats.name,
			rarity = stats.rarity,
		})
	end
end

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

local function standRarity(stand: Instance): string?
	local name = stand:GetAttribute("BrainrotName")
	if typeof(name) == "string" and name ~= "" then
		local def = Brainrots.getByName(name)
		if def and typeof(def.rarity) == "string" and def.rarity ~= "" then
			return Brainrots.normalizeRarityId(def.rarity)
		end
	end
	local r = stand:GetAttribute("BrainrotRarity")
	if typeof(r) == "string" and r ~= "" then
		return Brainrots.normalizeRarityId(r)
	end
	return nil
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
		return false
	end
	local char = thief.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local standPos = standWorldPosition(stand)
	if hrp and standPos and (hrp.Position - standPos).Magnitude > STEAL_RANGE then
		return false
	end
	return true
end

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
		local rarity = fallbackRarity
		if typeof(rarity) ~= "string" then
			return false
		end
		local normalized = StoreConfig.normalizeStealRarity(rarity)
		local pool = Brainrots.brainrotsOfRarity(normalized)
		if #pool == 0 then
			pool = Brainrots.brainrotsOfRarity(rarity)
		end
		if #pool == 0 then
			return false
		end
		local def = pool[math.random(1, #pool)]
		stolen = {
			name = def.name,
			rarity = def.rarity,
			mutation = "normal",
			level = 1,
			baseIncome = def.baseIncome,
		}
	end

	local granted = grantBrainrotToThief(thief, stolen)
	if granted then
		fireThiefFeedback(thief, stolen)
		local timEvt = ServerStorage:FindFirstChild("TimCheeseStealSuccess")
		if timEvt and timEvt:IsA("BindableEvent") then
			timEvt:Fire(thief)
		end
	end
	return granted
end

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

stealRequestRE.OnServerEvent:Connect(function(thief: Player, standArg: any)
	if typeof(standArg) ~= "Instance" then
		return
	end
	local stand = standArg :: Instance
	if not canSteal(thief, stand) then
		return
	end

	local freeSteals = thief:GetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT)
	if typeof(freeSteals) == "number" and freeSteals > 0 then
		if executeSteal(thief, stand) then
			thief:SetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT, freeSteals - 1)
		end
		return
	end

	local rarity = standRarity(stand)
	if not rarity then
		warn("[Steal] stand missing BrainrotRarity / catalog rarity")
		stealFailedRE:FireClient(thief, "Can't steal this brainrot right now.")
		return
	end
	local productId = StoreConfig.getStealProductId(rarity)
	if not productId then
		warn("[Steal] no steal product for rarity:", rarity)
		stealFailedRE:FireClient(
			thief,
			string.format("Steal product missing for %s — create it in Creator Dashboard.", rarity)
		)
		return
	end
	pendingSteal[thief] = { stand = stand, rarity = StoreConfig.normalizeStealRarity(rarity) }
	stealPromptProductRE:FireClient(thief, productId)
end)

Players.PlayerRemoving:Connect(function(player)
	pendingSteal[player] = nil
end)

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

local function registerStealReceipts(): boolean
	local PH = resolveProductHandlerServer()
	if not PH or typeof(PH.registerProductReceipt) ~= "function" then
		return false
	end
	for _, productId in StoreConfig.STEAL_PRODUCT_BY_RARITY do
		PH.registerProductReceipt(productId, function(thief, receiptInfo)
			local pending = pendingSteal[thief]
			local fallbackRarity = rarityFromProductId(receiptInfo.ProductId)
			pendingSteal[thief] = nil
			if pending and canSteal(thief, pending.stand) then
				executeSteal(thief, pending.stand, fallbackRarity or pending.rarity)
			else
				executeSteal(thief, nil, fallbackRarity)
			end
			return GRANTED
		end)
	end
	return true
end

task.spawn(function()
	for _ = 1, 40 do
		if registerStealReceipts() then
			return
		end
		task.wait(0.5)
	end
	warn("[StealBrainrot] ProductHandlerServer.registerProductReceipt unavailable")
end)
