local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PurchaseEffectClient = require(ReplicatedStorage.EssentialsShared.PurchaseEffect.PurchaseEffectClient)

local PurchasePrompt = {}

function PurchasePrompt.promptGamePass(gamePassId: number)
	PurchaseEffectClient:show()
	MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, gamePassId)
end

function PurchasePrompt.promptProduct(productId: number)
	PurchaseEffectClient:show()
	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
end

return PurchasePrompt
