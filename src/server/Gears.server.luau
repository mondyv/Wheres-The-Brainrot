-- [ACTIVE] Gears.server
-- Cash/Robux gear purchases, equip, workout start/stop remotes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Publish remotes before requiring modules. Shop / workout clients wait on these
-- names; if they are created after a long require chain, Buy looks dead for ~30s.
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function ensureRF(name: string): RemoteFunction
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = remotesFolder
	return rf
end

local function ensureRE(name: string): RemoteEvent
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = remotesFolder
	return re
end

local purchaseGearFn = ensureRF("PurchaseGear")
local equipGearFn = ensureRF("EquipGear")
local startWorkoutFn = ensureRF("StartWorkout")
local stopWorkoutFn = ensureRF("StopWorkout")
local claimDoubleTapFn = ensureRF("ClaimWorkoutDoubleTap")
local setPowerFn = ensureRF("SetEditedPower")
local prepareRobuxGearRE = ensureRE("PrepareRobuxGear")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local GearService = require(script.Parent:WaitForChild("Modules"):WaitForChild("GearService"))
local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local AnalyticsFunnelService = require(script.Parent:WaitForChild("Modules"):WaitForChild("AnalyticsFunnelService"))

local pendingRobuxGear: { [Player]: number } = {}

local function noteFirstGear(player: Player, gearId: number)
	if gearId ~= 1 then
		return
	end
	AnalyticsFunnelService.logOnboardingId(player, "bought_power", { allowSkip = true })
end

local function initPlayer(player: Player)
	PlayerDataService.waitUntilLoaded(player)
	WorkoutPower.initPlayerPower(player)
	GearService.ensureTools(player)
end

GearService.init()

Players.PlayerAdded:Connect(initPlayer)
for _, p in Players:GetPlayers() do
	task.defer(function()
		initPlayer(p)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	pendingRobuxGear[player] = nil
end)

purchaseGearFn.OnServerInvoke = function(player: Player, gearIdAny: any): (boolean, string?)
	if typeof(gearIdAny) ~= "number" then
		return false, "Invalid"
	end
	local gearId = math.floor(gearIdAny)
	local ok, err = GearService.purchaseCash(player, gearId)
	if ok then
		noteFirstGear(player, gearId)
		task.spawn(function()
			local saveOk, saveErr = pcall(function()
				PlayerDataService.savePlayerData(player)
			end)
			if not saveOk then
				warn("[Gears] save after purchase failed:", saveErr)
			end
		end)
	end
	return ok, err
end

equipGearFn.OnServerInvoke = function(player: Player, gearIdAny: any): (boolean, string?)
	if typeof(gearIdAny) ~= "number" then
		return false, "Invalid"
	end
	return GearService.equipGear(player, math.floor(gearIdAny))
end

startWorkoutFn.OnServerInvoke = function(player: Player, gearIdAny: any): (boolean, string?)
	local gearId = gearIdAny
	if typeof(gearId) ~= "number" then
		local equipped = player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR)
		if typeof(equipped) == "number" and equipped > 0 then
			gearId = equipped
		else
			return false, "No gear"
		end
	end
	return GearService.startWorkout(player, math.floor(gearId :: number))
end

stopWorkoutFn.OnServerInvoke = function(player: Player): boolean
	GearService.stopWorkout(player)
	return true
end

claimDoubleTapFn.OnServerInvoke = function(player: Player, hitAny: any): number
	if hitAny == false then
		return GearService.resetWorkoutCombo(player)
	end
	return GearService.claimWorkoutDoubleTap(player)
end

setPowerFn.OnServerInvoke = function(player: Player, amountAny: any, editedAny: any): (boolean, string?)
	if typeof(amountAny) ~= "number" then
		return false, "Invalid"
	end
	local maxP = WorkoutPower.readPowerMax(player)
	local amount = math.clamp(math.floor(amountAny), 0, math.floor(maxP))
	-- Full max clears (Edited); anything lower keeps the nerf.
	local markEdited = amount < math.floor(maxP)
	if editedAny == false then
		markEdited = false
	end
	WorkoutPower.setPower(player, amount, markEdited)
	task.spawn(function()
		local saveOk, saveErr = pcall(function()
			PlayerDataService.savePlayerData(player)
		end)
		if not saveOk then
			warn("[Gears] save after set power failed:", saveErr)
		end
	end)
	return true, nil
end

prepareRobuxGearRE.OnServerEvent:Connect(function(player: Player, gearIdAny: any)
	if typeof(gearIdAny) ~= "number" then
		return
	end
	local def = GearConfig.get(math.floor(gearIdAny))
	if def and def.robuxProductId then
		pendingRobuxGear[player] = def.id
	end
end)

local function fulfillRobuxGear(player: Player, gearId: number?): boolean
	local id = gearId or pendingRobuxGear[player]
	pendingRobuxGear[player] = nil
	if typeof(id) ~= "number" then
		return false
	end
	-- No progression locks — Robux only grants the purchased gear.
	-- Auto-equip swaps the hotbar tool; does not put it in the character's hand.
	GearService.grantGear(player, id, true)
	noteFirstGear(player, id)
	pcall(function()
		PlayerDataService.savePlayerData(player)
	end)
	return true
end

local function ensureInternalFolder(): Folder
	local existing = ServerStorage:FindFirstChild("GameInternal")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "GameInternal"
	folder.Parent = ServerStorage
	return folder
end

local fulfillBF = ensureInternalFolder():FindFirstChild("FulfillRobuxGear")
if not fulfillBF then
	fulfillBF = Instance.new("BindableFunction")
	fulfillBF.Name = "FulfillRobuxGear"
	fulfillBF.Parent = ensureInternalFolder()
end
(fulfillBF :: BindableFunction).OnInvoke = function(playerArg: any, gearIdArg: any): any
	if typeof(playerArg) ~= "Instance" or not (playerArg :: Instance):IsA("Player") then
		return false
	end
	local gearId = if typeof(gearIdArg) == "number" then math.floor(gearIdArg) else nil
	return fulfillRobuxGear(playerArg :: Player, gearId)
end

task.spawn(function()
	local essentials = ServerScriptService:WaitForChild("EssentialsServer", 120)
	local handlerFolder = essentials and essentials:WaitForChild("ProductHandler", 30)
	local moduleScript = handlerFolder and handlerFolder:WaitForChild("ProductHandlerServer", 30)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("[Gears] ProductHandlerServer unavailable; gear Robux products not registered")
		return
	end
	local okRequire, ProductHandlerServer = pcall(require, moduleScript)
	if not okRequire or typeof(ProductHandlerServer) ~= "table" then
		warn("[Gears] ProductHandlerServer require failed:", ProductHandlerServer)
		return
	end
	if typeof(ProductHandlerServer.registerProductReceipt) ~= "function" then
		warn("[Gears] registerProductReceipt missing")
		return
	end
	for _, productId in GearConfig.allProductIds() do
		local def = GearConfig.getByProductId(productId)
		if def then
			ProductHandlerServer.registerProductReceipt(productId, function(player: Player)
				local ok = fulfillRobuxGear(player, def.id)
				return if ok
					then Enum.ProductPurchaseDecision.PurchaseGranted
					else Enum.ProductPurchaseDecision.NotProcessedYet
			end)
		end
	end
end)
