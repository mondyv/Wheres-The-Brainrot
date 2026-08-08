-- [ACTIVE] ReturnTeleport.server
--[[
	Free return (no brainrots) via ReturnToPlot RemoteFunction → plot spawn.
	Paid return (carrying N brainrots) via Return 1–11 developer products → plot spawn, keep haul.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local PlotSpawnUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotSpawnUtil"))
local ReturnConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReturnConfig"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))
local WebTrapConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WebTrapConfig"))

local RETURN_COOLDOWN_SEC = 2.5
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

local lastReturnAt: { [Player]: number } = {}
local returnRF: RemoteFunction? = nil
local returnPaidRE: RemoteEvent? = nil

local function ensureReturnRemote(): RemoteFunction
	if returnRF and returnRF.Parent then
		return returnRF
	end
	local existing = ReplicatedStorage:FindFirstChild("ReturnToPlot")
	if existing and existing:IsA("RemoteFunction") then
		returnRF = existing
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = "ReturnToPlot"
	rf.Parent = ReplicatedStorage
	returnRF = rf
	return rf
end

local function ensurePaidRemote(): RemoteEvent
	if returnPaidRE and returnPaidRE.Parent then
		return returnPaidRE
	end
	local existing = ReplicatedStorage:FindFirstChild("ReturnPaidComplete")
	if existing and existing:IsA("RemoteEvent") then
		returnPaidRE = existing
		return existing
	end
	local re = Instance.new("RemoteEvent")
	re.Name = "ReturnPaidComplete"
	re.Parent = ReplicatedStorage
	returnPaidRE = re
	return re
end

local function countCarriedBrainrots(player: Player, character: Model): number
	local n = 0
	local attr = player:GetAttribute("BrainrotCarryCount")
	if typeof(attr) == "number" then
		n = math.floor(attr)
	end
	local models = 0
	for _, d in character:GetDescendants() do
		if d:IsA("Model") then
			local phase = d:GetAttribute("BrainrotCarryPhase")
			if phase == "Carried" or phase == "Floating" or phase == "Pop" then
				models += 1
			end
		elseif d:IsA("WeldConstraint") and d.Name == "BrainrotCarryWeld" then
			models = math.max(models, 1)
		end
	end
	return math.max(n, models)
end

local function cooldownOk(player: Player): boolean
	local now = os.clock()
	return (lastReturnAt[player] or 0) + RETURN_COOLDOWN_SEC <= now
end

local function notifyAfterPlotReturn(player: Player)
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	local bf = folder and folder:FindFirstChild("AfterPlotReturn")
	if bf and bf:IsA("BindableFunction") then
		local ok, err = pcall(function()
			(bf :: BindableFunction):Invoke(player)
		end)
		if not ok then
			warn("[ReturnTeleport] AfterPlotReturn failed:", err)
		end
	end
end

local function teleportHome(player: Player, character: Model): (boolean, string?)
	local spawnCf = PlotSpawnUtil.getAssignedPlotSpawnCFrame(player)
	if not spawnCf then
		return false, "Base not ready yet"
	end
	-- Stream + retries so return doesn't drop through an unstreamed floor.
	PlotSpawnUtil.streamAndTeleportWithRetries(player, character, spawnCf, true)
	lastReturnAt[player] = os.clock()
	return true, nil
end

local function isWebTrapped(player: Player): boolean
	return player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true
end

local function canFreeReturn(player: Player): (boolean, string?)
	local character = player.Character
	if not character then
		return false, "No character"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Cannot return right now"
	end

	if isWebTrapped(player) then
		return false, "You're stuck in a web"
	end

	if SafezoneUtil.isCharacterInSafezone(character) then
		return false, "Already in the safe zone"
	end

	if countCarriedBrainrots(player, character) > 0 then
		return false, "Use Return With Brainrot"
	end

	if not cooldownOk(player) then
		return false, "Please wait a moment"
	end

	if not PlotSpawnUtil.getAssignedPlotSpawnCFrame(player) then
		return false, "Base not ready yet"
	end

	return true, nil
end

local function onFreeReturnRequest(player: Player): (boolean, string?)
	local ok, reason = canFreeReturn(player)
	if not ok then
		return false, reason or "Cannot return"
	end
	local character = player.Character
	if not character then
		return false, "No character"
	end
	return teleportHome(player, character)
end

local function fulfillPaidReturn(player: Player, productId: number): boolean
	local expected = ReturnConfig.countForProductId(productId)
	if not expected then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	-- Stuck in web: do not teleport. NOT_PROCESSED lets Roblox retry after trap ends.
	if isWebTrapped(player) then
		return false
	end
	local carried = countCarriedBrainrots(player, character)
	if carried <= 0 then
		-- Purchase already went through — still send them home so they aren't stranded.
		warn("[ReturnTeleport] paid return with 0 carry models for", player.Name, "— teleporting anyway")
		local ok = select(1, teleportHome(player, character))
		if ok then
			notifyAfterPlotReturn(player)
			ensurePaidRemote():FireClient(player)
		end
		return ok
	end
	-- Prefer exact product tier, but still fulfill if haul count drifted by ±1 during prompt.
	local clamped = ReturnConfig.clampCount(carried)
	if clamped ~= expected and math.abs(clamped - expected) > 1 then
		warn("[ReturnTeleport] product/count mismatch for", player.Name, "product", productId, "carry", carried)
		-- Still teleport + deliver so Robux purchase isn't wasted.
	end
	local ok = select(1, teleportHome(player, character))
	if ok then
		notifyAfterPlotReturn(player)
		ensurePaidRemote():FireClient(player)
	end
	return ok
end

ensureReturnRemote().OnServerInvoke = onFreeReturnRequest
ensurePaidRemote()

do
	local ProductHandlerServer =
		require(ServerScriptService.EssentialsServer.ProductHandler.ProductHandlerServer)
	for count = 1, ReturnConfig.MAX_COUNT do
		local productId = ReturnConfig.PRODUCT_BY_COUNT[count]
		if typeof(productId) == "number" then
			ProductHandlerServer.registerProductReceipt(productId, function(player: Player, receiptInfo: any)
				local pid = if typeof(receiptInfo) == "table" then receiptInfo.ProductId else productId
				if fulfillPaidReturn(player, pid) then
					return GRANTED
				end
				return NOT_PROCESSED
			end)
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	lastReturnAt[player] = nil
end)
