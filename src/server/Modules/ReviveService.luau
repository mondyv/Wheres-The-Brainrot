--[[
	Revive flow (server module):
	• On death: store death CFrame + land, prompt client, respawn at plot immediately.
	• Decline / timeout: clear pending (player already alive at plot).
	• Dev product receipt: teleport back to death location.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

type PendingRevive = {
	cframe: CFrame,
	land: number,
	productId: number,
}

local pendingByPlayer: { [Player]: PendingRevive } = {}

local revivePromptRE: RemoteEvent
local reviveDeclinedRE: RemoteEvent
local reviveCompleteRE: RemoteEvent

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

local function clearPending(player: Player)
	pendingByPlayer[player] = nil
end

local function teleportCharacterToCFrame(character: Model, spawnCf: CFrame): boolean
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

local function respawnAtPlot(player: Player)
	player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, nil)
	player:LoadCharacter()
end

local function finishDecline(player: Player)
	clearPending(player)
end

local function fulfillRevivePurchase(player: Player): boolean
	local pending = pendingByPlayer[player]
	if not pending then
		return false
	end

	local cf = pending.cframe
	clearPending(player)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 then
		teleportCharacterToCFrame(character, cf)
	else
		player:SetAttribute(ReviveConfig.REVIVE_SPAWN_ATTR, cf)
		player:LoadCharacter()
	end

	reviveCompleteRE:FireClient(player)
	return true
end

local function onHumanoidDied(player: Player, character: Model)
	if pendingByPlayer[player] then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local deathCf = if hrp then hrp.CFrame else CFrame.new()
	local land = if hrp then LandResolver.resolveLandAtPosition(hrp.Position) else 1
	local tier = ReviveConfig.tierForLand(land)

	pendingByPlayer[player] = {
		cframe = deathCf,
		land = tier.land,
		productId = tier.productId,
	}

	revivePromptRE:FireClient(player, tier.land, tier.productId, ReviveConfig.COUNTDOWN_SECONDS)
	respawnAtPlot(player)
end

local function hookCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	end
	if not humanoid then
		return
	end

	humanoid.Died:Connect(function()
		local char = humanoid.Parent
		if char and char:IsA("Model") then
			onHumanoidDied(player, char)
		end
	end)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
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
	if not pending then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if pending.productId ~= receiptInfo.ProductId then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if fulfillRevivePurchase(player) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function ReviveService.init()
	revivePromptRE = ensureRemoteEvent("RevivePrompt")
	reviveDeclinedRE = ensureRemoteEvent("ReviveDeclined")
	reviveCompleteRE = ensureRemoteEvent("ReviveComplete")

	reviveDeclinedRE.OnServerEvent:Connect(function(player: Player)
		finishDecline(player)
	end)

	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(player)
		clearPending(player)
	end)

	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
end

return ReviveService
