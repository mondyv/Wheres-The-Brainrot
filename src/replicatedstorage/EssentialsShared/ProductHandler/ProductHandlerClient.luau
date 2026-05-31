local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductHandlerClient = {}

local function findEventsFolder(): Instance?
	for _, folderName in { "EssentialsAssets", "EssentialAssets" } do
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
	local events = findEventsFolder()
	if not events then
		local assets = ReplicatedStorage:WaitForChild("EssentialsAssets", 30)
		events = assets and assets:WaitForChild("Events", 30)
	end
	if not events then
		warn("[ProductHandlerClient] Events folder missing")
		return
	end

	self._purchaseRemote = events:WaitForChild("ProductHandlerPurchase", 30) :: RemoteEvent?
end

function ProductHandlerClient.bindButton(self: ProductHandlerClient, button: GuiButton, productName: string)
	if not self._purchaseRemote then
		warn("[ProductHandlerClient] Cannot bind button; purchase remote missing")
		return
	end

	button.Activated:Connect(function()
		self._purchaseRemote:FireServer(productName)
	end)
end

export type ProductHandlerClient = typeof(ProductHandlerClient) & {
	_purchaseRemote: RemoteEvent?,
}

return ProductHandlerClient :: ProductHandlerClient
