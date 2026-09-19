-- Gears
-- Server entry for the workout kit. Creates remotes first so the shop doesn't
-- sit there dead for 30s waiting on a late require.
--
-- Put this Script in ServerScriptService (folder name doesn't matter).
-- GearService should sit in a sibling Modules folder, or next to this script.
--
-- Remotes (names are hardcoded — don't rename):
--   PurchaseGear, EquipGear, StartWorkout, StopWorkout,
--   ClaimWorkoutDoubleTap, SetEditedPower  (RemoteFunctions)
--   PrepareRobuxGear (RemoteEvent)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

if not script:IsDescendantOf(ServerScriptService) then
	warn("[Gears] This Script is in", script.Parent and script.Parent:GetFullName(), "— MOVE it to ServerScriptService or remotes/tools will not exist")
end

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
print("[Gears] remotes created under ReplicatedStorage.Remotes")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local WorkoutPower = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutPower"))
local WorkoutCompat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorkoutCompat"))

local function requireGearService(): any
	local found: { ModuleScript } = {}
	local function consider(inst: Instance?)
		if inst and inst:IsA("ModuleScript") then
			for _, already in found do
				if already == inst then
					return
				end
			end
			table.insert(found, inst)
		end
	end
	local modules = script.Parent:FindFirstChild("Modules")
	consider(modules and modules:FindFirstChild("GearService"))
	consider(script.Parent:FindFirstChild("GearService"))
	if #found > 1 then
		warn("[Gears] Extra GearService — delete ServerScriptService.GearService and keep Modules.GearService")
	end
	if found[1] then
		print("[Gears] loading", found[1]:GetFullName())
		return require(found[1])
	end
	error("[Gears] GearService missing — put the ModuleScript in ServerScriptService.Modules")
end

local gsOk, gsOrErr = pcall(requireGearService)
if not gsOk then
	warn("[Gears] GearService failed to load:", gsOrErr)
	return
end
local GearService = gsOrErr
print("[Gears] GearService loaded")
local PlayerDataService = WorkoutCompat.tryRequire(script.Parent:FindFirstChild("Modules"), "PlayerDataService")
	or WorkoutCompat.tryRequire(script.Parent, "PlayerDataService")
local AnalyticsFunnelService = WorkoutCompat.tryRequire(script.Parent:FindFirstChild("Modules"), "AnalyticsFunnelService")
	or WorkoutCompat.tryRequire(script.Parent, "AnalyticsFunnelService")
local WorkoutData = WorkoutCompat.tryRequire(script.Parent:FindFirstChild("Modules"), "WorkoutData")
	or WorkoutCompat.tryRequire(script.Parent, "WorkoutData")

local pendingRobuxGear: { [Player]: number } = {}

local function noteFirstGear(player: Player, gearId: number)
	if gearId ~= 1 then
		return
	end
	if AnalyticsFunnelService and typeof(AnalyticsFunnelService.logOnboardingId) == "function" then
		AnalyticsFunnelService.logOnboardingId(player, "bought_power", { allowSkip = true })
	end
end

local function saveWorkout(player: Player)
	if PlayerDataService and typeof(PlayerDataService.savePlayerData) == "function" then
		local saveOk, saveErr = pcall(function()
			PlayerDataService.savePlayerData(player)
		end)
		if not saveOk then
			warn("[Gears] save after purchase failed:", saveErr)
		end
		return
	end
	if WorkoutData and typeof(WorkoutData.savePlayer) == "function" then
		local saveOk, saveErr = pcall(function()
			WorkoutData.savePlayer(player)
		end)
		if not saveOk then
			warn("[Gears] WorkoutData save failed:", saveErr)
		end
	end
end

local function initPlayer(player: Player)
	if PlayerDataService and typeof(PlayerDataService.waitUntilLoaded) == "function" then
		PlayerDataService.waitUntilLoaded(player)
	elseif WorkoutData and typeof(WorkoutData.waitUntilLoaded) == "function" then
		WorkoutData.waitUntilLoaded(player)
	end
	WorkoutPower.initPlayerPower(player)
	-- Baseplate only. This game already sells Gear 1 for $0 in the shop.
	if not PlayerDataService and not GearService.owns(player, 1) then
		GearService.grantGear(player, 1, true)
	end
	GearService.ensureTools(player)
	if not PlayerDataService then
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local equipped = player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR)
		local gearId = if typeof(equipped) == "number" then math.floor(equipped) else 0
		local tool = GearService.findGearTool(player, gearId)
		if hum and tool then
			tool.RequiresHandle = false
			pcall(function()
				hum:EquipTool(tool)
			end)
			print("[WK-02] auto-equipped", tool.Name)
		end
	end
	print("[Gears] tools ready for", player.Name, "equipped", player:GetAttribute(GearConfig.EQUIPPED_GEAR_ATTR))
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
			saveWorkout(player)
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
		saveWorkout(player)
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
	saveWorkout(player)
	return true
end

prepareRobuxGearRE.OnServerEvent:Connect(function(player: Player, gearIdAny: any)
	if not RunService:IsStudio() then
		return
	end
	if ServerScriptService:FindFirstChild("EssentialsServer") then
		return
	end
	if typeof(gearIdAny) ~= "number" then
		return
	end
	local def = GearConfig.get(math.floor(gearIdAny))
	if def and def.robuxProductId then
		fulfillRobuxGear(player, def.id)
	end
end)

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
	local essentials = ServerScriptService:FindFirstChild("EssentialsServer")
	if not essentials then
		-- Sold kit / baseplate: own ProcessReceipt so Robux gears grant.
		MarketplaceService.ProcessReceipt = function(receiptInfo)
			local def = GearConfig.getByProductId(receiptInfo.ProductId)
			if not def then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if not player then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local ok = fulfillRobuxGear(player, def.id)
			if ok then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return
	end
	local handlerFolder = essentials:WaitForChild("ProductHandler", 30)
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
