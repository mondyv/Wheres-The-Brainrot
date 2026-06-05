local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PurchaseEffectClient = require(ReplicatedStorage.EssentialsShared.PurchaseEffect.PurchaseEffectClient)
local PurchasePrompt = require(ReplicatedStorage.EssentialsShared.PurchasePrompt)

local ProductHandlerClient = {}

local REMOTE_WAIT_SEC = 8

local function findEventsFolder(): Instance?
	for _, folderName in { "EssentialAssets", "EssentialAssets" } do
		local assets = ReplicatedStorage:FindFirstChild(folderName)
		if assets then
			local events = assets:FindFirstChild("Events")
			if events then
				return events
			end
		end
	end
	return nil
end

function ProductHandlerClient.init(self: ProductHandlerClient)
	task.spawn(function()
		local events = findEventsFolder()
		if not events then
			local assets = ReplicatedStorage:WaitForChild("EssentialAssets", REMOTE_WAIT_SEC)
			if assets then
				events = assets:WaitForChild("Events", REMOTE_WAIT_SEC)
			end
		end
		if not events then
			warn("[ProductHandlerClient] Events folder missing")
			return
		end

		self._purchaseRemote = events:WaitForChild("ProductHandlerPurchase", REMOTE_WAIT_SEC) :: RemoteEvent?
		if not self._purchaseRemote then
			warn("[ProductHandlerClient] ProductHandlerPurchase remote missing")
		end
	end)
end

function ProductHandlerClient.bindButton(self: ProductHandlerClient, button: GuiButton, productName: string)
	button.Activated:Connect(function()
		PurchaseEffectClient:show()

		local remote = self._purchaseRemote
		if not remote then
			local events = findEventsFolder()
			remote = events and events:FindFirstChild("ProductHandlerPurchase") :: RemoteEvent?
		end
		if remote then
			remote:FireServer(productName)
		else
			warn("[ProductHandlerClient] Cannot purchase", productName, "— remote missing")
		end
	end)
end

function ProductHandlerClient.autoBindPurchaseButtons(self: ProductHandlerClient, root: Instance)
	for _, desc in root:GetDescendants() do
		if not desc:IsA("GuiButton") then
			continue
		end

		local productName = desc:GetAttribute("ProductHandler")
		if typeof(productName) == "string" and productName ~= "" then
			self:bindButton(desc, productName)
		end

		local gamePassId = desc:GetAttribute("GamePassId")
		if typeof(gamePassId) == "number" and gamePassId > 0 then
			desc.Activated:Connect(function()
				PurchasePrompt.promptGamePass(gamePassId)
			end)
		end
	end
end

export type ProductHandlerClient = typeof(ProductHandlerClient) & {
	_purchaseRemote: RemoteEvent?,
}

return ProductHandlerClient :: ProductHandlerClient
