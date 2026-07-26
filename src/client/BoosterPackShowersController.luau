-- [ACTIVE] BoosterPackShowersController
--[[
	Client purchase prompts for Map.Booster Pack Showers stand hitboxes.
	Matches the store flow: rainbow PurchaseEffect + MarketplaceService prompt on the client.
	Group Stand: rainbow + GroupService:PromptJoinAsync, then claim one-time rare reward.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local PurchaseEffectClient =
	require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchaseEffect"):WaitForChild("PurchaseEffectClient"))

local player = Players.LocalPlayer

local REMOTE_FOLDER = "StoreRemotes"
local REMOTE_NAME = "BoosterShowerProductPrompt"
local GROUP_PROMPT_REMOTE_NAME = "GroupStandPrompt"
local GROUP_CLAIM_REMOTE_NAME = "GroupStandClaim"

local BoosterPackShowersController = {}

local groupPromptBusy = false

local function onPromptProduct(productId: number, productKind: string?)
	if typeof(productId) ~= "number" then
		return
	end
	if productKind == "exclusive" and player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
		return
	end
	PurchasePrompt.promptProduct(productId)
end

local function claimGroupReward()
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
	local claimRemote = folder and folder:FindFirstChild(GROUP_CLAIM_REMOTE_NAME)
	if claimRemote and claimRemote:IsA("RemoteEvent") then
		claimRemote:FireServer()
	end
end

local function onPromptGroupJoin(groupId: number)
	if typeof(groupId) ~= "number" then
		return
	end
	if player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED) == true then
		return
	end
	if groupPromptBusy then
		return
	end
	groupPromptBusy = true

	PurchaseEffectClient:init()
	PurchaseEffectClient:show()

	local success, result = pcall(function()
		return GroupService:PromptJoinAsync(groupId)
	end)

	PurchaseEffectClient:forceHide()
	groupPromptBusy = false

	if not success then
		warn("[BoosterPackShowersController] PromptJoinAsync failed:", result)
		return
	end

	-- Joined now, or already a member who hasn't claimed yet.
	if result == Enum.GroupMembershipStatus.Joined or result == Enum.GroupMembershipStatus.AlreadyMember then
		claimGroupReward()
	end
end

function BoosterPackShowersController.init()
	local folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER, 120)
	if not folder then
		warn("[BoosterPackShowersController] StoreRemotes folder missing")
		return
	end

	local remote = folder:WaitForChild(REMOTE_NAME, 120)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[BoosterPackShowersController]", REMOTE_NAME, "remote missing")
	else
		remote.OnClientEvent:Connect(function(productId: any, productKind: any)
			onPromptProduct(productId, if typeof(productKind) == "string" then productKind else nil)
		end)
	end

	local groupPrompt = folder:WaitForChild(GROUP_PROMPT_REMOTE_NAME, 120)
	if not groupPrompt or not groupPrompt:IsA("RemoteEvent") then
		warn("[BoosterPackShowersController]", GROUP_PROMPT_REMOTE_NAME, "remote missing")
	else
		groupPrompt.OnClientEvent:Connect(function(groupId: any)
			onPromptGroupJoin(if typeof(groupId) == "number" then groupId else StoreConfig.GROUP_ID)
		end)
	end
end

return BoosterPackShowersController
