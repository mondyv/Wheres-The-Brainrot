-- [ACTIVE] 0_PurchaseEffectBootstrap.server
--[[
	Creates purchase-effect remotes as early as possible so clients never stall waiting.
	ProductHandlerServer hooks these remotes when EssentialsServer init runs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_NAMES = { "PurchaseEffectShow", "ProductHandlerConfetti", "ProductHandlerPurchase" }

local function ensureEventsFolder(): Folder
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "EssentialAssets"
		assets.Parent = ReplicatedStorage
	end

	local events = assets:FindFirstChild("Events")
	if not events then
		events = Instance.new("Folder")
		events.Name = "Events"
		events.Parent = assets
	end

	return events :: Folder
end

local events = ensureEventsFolder()
for _, name in REMOTE_NAMES do
	if not events:FindFirstChild(name) then
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = events
	end
end
