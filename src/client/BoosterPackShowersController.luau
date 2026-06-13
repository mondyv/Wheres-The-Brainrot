-- [ACTIVE] BoosterPackShowersController
--[[
	Client purchase prompts for Map.Booster Pack Showers stand hitboxes.
	Matches the store flow: rainbow PurchaseEffect + MarketplaceService prompt on the client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local player = Players.LocalPlayer

local REMOTE_FOLDER = "StoreRemotes"
local REMOTE_NAME = "BoosterShowerProductPrompt"

local BoosterPackShowersController = {}

local function onPromptProduct(productId: number, productKind: string?)
	if typeof(productId) ~= "number" then
		return
	end
	if productKind == "exclusive" and player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
		return
	end
	PurchasePrompt.promptProduct(productId)
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
		return
	end
	remote.OnClientEvent:Connect(function(productId: any, productKind: any)
		onPromptProduct(productId, if typeof(productKind) == "string" then productKind else nil)
	end)
end

return BoosterPackShowersController
