-- [ACTIVE] ReviveService
--[[
	Revive flow (server module):
	• CharacterAutoLoads = false so Roblox's RespawnTime never holds decline/revive.
	• Tracks last good land while alive (death Y/ragdoll can miss hitboxes).
	• On death: store land + spawn CFrame, prompt client with that land's product.
	• Decline / timeout: clear pending and LoadCharacter immediately.
	• Dev product receipt: LoadCharacter / teleport onto that land's Spawn.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))

type PendingRevive = {
	land: number,
	productId: number,
	reviveCf: CFrame,
}

local pendingByPlayer: { [Player]: PendingRevive } = {}
local lastGoodLand: { [Player]: number } = {}
local lastGoodPos: { [Player]: Vector3 } = {}
local landTrackThreads: { [Player]: thread } = {}
local fulfillingByPlayer: { [Player]: boolean } = {}
local declineTimeoutThreads: { [Player]: thread } = {}
local loadingCharacter: { [Player]: boolean } = {}

local revivePromptRE: RemoteEvent
local reviveDeclinedRE: RemoteEvent
local reviveCompleteRE: RemoteEvent

local MIN_SANE_Y = -80

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local re = folder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = folder
	end
	return re :: RemoteEvent
end

local function cancelDeclineTimeout(player: Player)
	local th = declineTimeoutThreads[player]
	if th then
		task.cancel(th)
		declineTimeoutThreads[player] = nil
	end
end

local function clearPending(player: Player)
	cancelDeclineTimeout(player)
	pendingByPlayer[player] = nil
end

local function forceLoadCharacter(player: Player)
	if not player.Parent or loadingCharacter[player] then
		return
	end
	loadingCharacter[player] = true
	task.spawn(function()
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		loadingCharacter[player] = nil
		if not ok then
			warn("[ReviveService] LoadCharacter failed:", err)
			task.wait(0.2)
			if player.Parent then
				local ok2, err2 = pcall(function()
					player:LoadCharacter()
				end)
				if not ok2 then
					warn("[ReviveService] LoadCharacter retry failed:", err2)
				end
			end
		end
	end)
end

local function clearReviveSpawnAttrs(player: Player)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, nil)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, nil)
end

local function storeReviveSpawnAttrs(player: Player, spawnCf: CFrame)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_POS_ATTR, spawnCf.Position)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_LOOK_ATTR, spawnCf.LookVector)
	pcall(function()
		player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, spawnCf)
	end)
end

local function teleportCharacterToCFrame(character: Model, spawnCf: CFrame)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		hrp = character:WaitForChild("HumanoidRootPart", 8) :: BasePart?
	end
	if not hrp then
		return false
	end

	if character.PrimaryPart then
		character:PivotTo(spawnCf)
	else
		hrp.CFrame = spawnCf
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	return true
end

local function resolvePendingSpawn(pending: PendingRevive): CFrame
	local fresh = LandResolver.getSpawnCFrameForLand(pending.land)
	if fresh then
		return fresh
	end
	return pending.reviveCf
end

local function stopLandTracking(player: Player)
	local th = landTrackThreads[player]
	if th then
		task.cancel(th)
		landTrackThreads[player] = nil
	end
end

local function sampleLand(player: Player, character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local pos = hrp.Position
	if pos.Y < MIN_SANE_Y then
		return
	end
	local land = LandResolver.resolveLandAtPosition(pos)
	if typeof(land) == "number" and land >= 1 then
		lastGoodLand[player] = ReviveConfig.clampLand(land)
		lastGoodPos[player] = pos
	end
end

local function startLandTracking(player: Player, character: Model)
	stopLandTracking(player)
	sampleLand(player, character)
	local thread: thread
	thread = task.spawn(function()
		while player.Parent and character.Parent do
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				break
			end
			sampleLand(player, character)
			task.wait(0.35)
		end
		if landTrackThreads[player] == thread then
			landTrackThreads[player] = nil
		end
	end)
	landTrackThreads[player] = thread
end

local function finishDecline(player: Player)
	if fulfillingByPlayer[player] then
		return
	end
	-- Clear pending first so a mid-decline Died cannot open a second revive.
	clearPending(player)
	forceLoadCharacter(player)
end

local function applyTeleportWithRetries(player: Player, character: Model, spawnCf: CFrame)
	teleportCharacterToCFrame(character, spawnCf)
	task.spawn(function()
		for _ = 1, 10 do
			task.wait(0.2)
			if not player.Parent then
				return
			end
			local char = player.Character
			if not char or char ~= character or not char.Parent then
				return
			end
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				return
			end
			teleportCharacterToCFrame(char, spawnCf)
		end
		if player.Parent then
			clearReviveSpawnAttrs(player)
		end
		fulfillingByPlayer[player] = nil
	end)
end

local function fulfillRevivePurchase(player: Player): boolean
	local pending = pendingByPlayer[player]
	if not pending then
		return false
	end

	fulfillingByPlayer[player] = true
	local reviveCf = resolvePendingSpawn(pending)
	clearPending(player)
	storeReviveSpawnAttrs(player, reviveCf)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and character.Parent and humanoid and humanoid.Health > 0 then
		applyTeleportWithRetries(player, character, reviveCf)
		reviveCompleteRE:FireClient(player)
		return true
	end

	local conn: RBXScriptConnection? = nil
	local done = false
	conn = player.CharacterAdded:Connect(function(newChar)
		if done then
			return
		end
		done = true
		if conn then
			conn:Disconnect()
			conn = nil
		end
		task.defer(function()
			if player.Parent and newChar.Parent then
				applyTeleportWithRetries(player, newChar, reviveCf)
			else
				fulfillingByPlayer[player] = nil
			end
		end)
	end)

	forceLoadCharacter(player)
	reviveCompleteRE:FireClient(player)

	task.delay(12, function()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if fulfillingByPlayer[player] then
			fulfillingByPlayer[player] = nil
			if player.Parent then
				clearReviveSpawnAttrs(player)
			end
		end
	end)

	return true
end

local function resolveTutorialSoftRespawnCFrame(): CFrame?
	local map = workspace:FindFirstChild(TimCheeseQuestConfig.MAP_FOLDER_NAME)
		or workspace:FindFirstChild("Map")
	local root = map or workspace
	local hitbox = root:FindFirstChild(TimCheeseQuestConfig.QUEST_HITBOX_NAME, true)
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox.CFrame + Vector3.new(0, hitbox.Size.Y * 0.5 + 3, 0)
	end
	local trigger = root:FindFirstChild(TimCheeseQuestConfig.QUEST_TRIGGER_NAME, true)
	if trigger and trigger:IsA("BasePart") then
		return trigger.CFrame + Vector3.new(0, trigger.Size.Y * 0.5 + 3, 0)
	end
	local tim = root:FindFirstChild(TimCheeseQuestConfig.TIM_NAME, true)
	if tim and tim:IsA("Model") then
		return tim:GetPivot() + Vector3.new(0, 4, 0)
	end
	return nil
end

local function softRespawnAtTutorialHitbox(player: Player)
	clearPending(player)
	local spawnCf = resolveTutorialSoftRespawnCFrame()
	if spawnCf then
		storeReviveSpawnAttrs(player, spawnCf)
	else
		clearReviveSpawnAttrs(player)
	end
	forceLoadCharacter(player)
end

local function onHumanoidDied(player: Player, character: Model)
	if pendingByPlayer[player] then
		return
	end
	stopLandTracking(player)

	-- Tutorial swing practice: skip death panel, dump them at the quest hitbox.
	if
		player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true
		and player:GetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR) == true
	then
		softRespawnAtTutorialHitbox(player)
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local worldPos = if hrp then hrp.Position else Vector3.zero

	local land: number
	local tracked = lastGoodLand[player]
	if typeof(tracked) == "number" then
		land = tracked
		if hrp and worldPos.Y >= MIN_SANE_Y then
			local resolved = LandResolver.resolveLandAtPosition(worldPos)
			-- Prefer the higher of tracked vs death-pos resolve (covers walking into a new land).
			if typeof(resolved) == "number" and resolved > land then
				land = resolved
			end
		end
	else
		land = LandResolver.resolveLandAtPosition(worldPos)
	end

	land = ReviveConfig.clampLand(land)
	local tier = ReviveConfig.tierForLand(land)
	local reviveCf = LandResolver.getSpawnCFrameForLand(tier.land)
	if not reviveCf then
		local trackedPos = lastGoodPos[player]
		if typeof(trackedPos) == "Vector3" then
			reviveCf = CFrame.new(trackedPos + Vector3.new(0, 4, 0))
		elseif hrp then
			reviveCf = hrp.CFrame
		else
			reviveCf = CFrame.new(worldPos)
		end
		warn("[ReviveService] Land", tier.land, "Spawn missing — falling back to death/tracked CFrame")
	end

	pendingByPlayer[player] = {
		land = tier.land,
		productId = tier.productId,
		reviveCf = reviveCf,
	}

	revivePromptRE:FireClient(player, tier.land, tier.productId, ReviveConfig.COUNTDOWN_SECONDS)

	-- Server-side safety: if the client never declines, still respawn after countdown.
	cancelDeclineTimeout(player)
	declineTimeoutThreads[player] = task.delay(ReviveConfig.COUNTDOWN_SECONDS + 0.5, function()
		declineTimeoutThreads[player] = nil
		if pendingByPlayer[player] then
			finishDecline(player)
		end
	end)
end

local function hookCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	end
	if not humanoid then
		return
	end

	startLandTracking(player, character)

	humanoid.Died:Connect(function()
		local char = humanoid.Parent
		if char and char:IsA("Model") then
			onHumanoidDied(player, char)
		end
	end)
end

local charAddedConns: { [Player]: RBXScriptConnection } = {}

local function hookPlayer(player: Player)
	if charAddedConns[player] then
		return
	end
	charAddedConns[player] = player.CharacterAdded:Connect(function(character)
		hookCharacter(player, character)
	end)
	if player.Character then
		hookCharacter(player, player.Character)
	end
end

local ReviveService = {}

function ReviveService.processReceipt(receiptInfo): Enum.ProductPurchaseDecision?
	if not ReviveConfig.isReviveProduct(receiptInfo.ProductId) then
		return nil
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local pending = pendingByPlayer[player]
	if pending then
		-- Always revive to the land they died on, even if the client prompted
		-- the wrong (cheaper) product due to a stale UI race.
		if pending.productId ~= receiptInfo.ProductId then
			warn(
				"[ReviveService] product mismatch for",
				player.Name,
				"— pending land",
				pending.land,
				"product",
				pending.productId,
				"bought",
				receiptInfo.ProductId,
				"; fulfilling death land anyway"
			)
		end
	else
		local land = ReviveConfig.landForProductId(receiptInfo.ProductId)
		if not land then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local spawnCf = LandResolver.getSpawnCFrameForLand(land)
		if not spawnCf then
			warn("[ReviveService] purchase for land", land, "but Spawn missing")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		pendingByPlayer[player] = {
			land = land,
			productId = receiptInfo.ProductId,
			reviveCf = spawnCf,
		}
	end

	if fulfillRevivePurchase(player) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function ReviveService.init()
	-- Own respawns so decline/purchase isn't stuck behind Roblox RespawnTime (~5s).
	Players.CharacterAutoLoads = false

	revivePromptRE = ensureRemoteEvent("RevivePrompt")
	reviveDeclinedRE = ensureRemoteEvent("ReviveDeclined")
	reviveCompleteRE = ensureRemoteEvent("ReviveComplete")

	reviveDeclinedRE.OnServerEvent:Connect(function(player: Player)
		finishDecline(player)
	end)

	local function ensurePlayer(player: Player)
		hookPlayer(player)
		if not player.Character then
			forceLoadCharacter(player)
		end
	end

	Players.PlayerAdded:Connect(ensurePlayer)
	Players.PlayerRemoving:Connect(function(player)
		stopLandTracking(player)
		clearPending(player)
		clearReviveSpawnAttrs(player)
		fulfillingByPlayer[player] = nil
		loadingCharacter[player] = nil
		lastGoodLand[player] = nil
		lastGoodPos[player] = nil
		local conn = charAddedConns[player]
		if conn then
			conn:Disconnect()
			charAddedConns[player] = nil
		end
	end)

	for _, player in Players:GetPlayers() do
		ensurePlayer(player)
	end
end

return ReviveService
