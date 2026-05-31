local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PurchaseEffectConfig = require(script.Parent.PurchaseEffectConfig)
local EffectsController = require(script.Parent.Parent.EffectsController)

local PurchaseEffectClient = {}

local rainbow: ImageLabel?
local defaultFov: number?
local hideToken = 0
local initialized = false

local fadeInTween = TweenInfo.new(
	PurchaseEffectConfig.fadeInDuration,
	PurchaseEffectConfig.easingStyle,
	Enum.EasingDirection.Out
)
local fadeOutTween = TweenInfo.new(
	PurchaseEffectConfig.fadeOutDuration,
	PurchaseEffectConfig.easingStyle,
	Enum.EasingDirection.Out
)

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

local function waitForRemote(name: string): RemoteEvent?
	local events = findEventsFolder()
	if not events then
		events = ReplicatedStorage:WaitForChild("EssentialsAssets", 30)
		if events then
			events = events:WaitForChild("Events", 30)
		end
	end
	if not events then
		warn("[PurchaseEffect] Events folder missing under EssentialsAssets")
		return nil
	end
	return events:WaitForChild(name, 30) :: RemoteEvent?
end

function PurchaseEffectClient.ensureRainbow(self: PurchaseEffectClient)
	if rainbow then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local effectGui = playerGui:FindFirstChild("Purchasing")
	if not effectGui then
		effectGui = Instance.new("ScreenGui")
		effectGui.Name = "Purchasing"
		effectGui.ResetOnSpawn = false
		effectGui.Parent = playerGui
	end

	if effectGui:IsA("ScreenGui") then
		effectGui.ResetOnSpawn = false
		effectGui.IgnoreGuiInset = true
		effectGui.DisplayOrder = PurchaseEffectConfig.guiDisplayOrder
		effectGui.Enabled = true
	end

	rainbow = effectGui:FindFirstChild("Rainbow") :: ImageLabel?
	if not rainbow then
		local img = Instance.new("ImageLabel")
		img.Name = "Rainbow"
		img.Size = UDim2.fromScale(1, 1)
		img.Position = UDim2.fromScale(0, 0)
		img.BackgroundTransparency = 1
		img.ImageTransparency = 1
		img.Image = PurchaseEffectConfig.rainbowImage
		img.ScaleType = Enum.ScaleType.Crop
		img.ZIndex = 10
		img.Parent = effectGui
		rainbow = img
	end
end

function PurchaseEffectClient.show(self: PurchaseEffectClient)
	self:ensureRainbow()
	if not rainbow then
		return
	end

	hideToken += 1
	TweenService:Create(rainbow, fadeInTween, { ImageTransparency = 0 }):Play()

	local camera = workspace.CurrentCamera
	if camera then
		defaultFov = camera.FieldOfView
		local targetFov = math.clamp(defaultFov - PurchaseEffectConfig.fovBoost, 1, 120)
		TweenService:Create(camera, fadeInTween, { FieldOfView = targetFov }):Play()
	end
end

function PurchaseEffectClient.hide(self: PurchaseEffectClient, delaySeconds: number?)
	if not rainbow then
		return
	end

	local token = hideToken
	local delayTime = delaySeconds or 0
	if delayTime > 0 then
		task.delay(delayTime, function()
			if token ~= hideToken then
				return
			end
			self:hide()
		end)
		return
	end

	TweenService:Create(rainbow, fadeOutTween, { ImageTransparency = 1 }):Play()

	local camera = workspace.CurrentCamera
	if camera then
		TweenService:Create(camera, fadeOutTween, {
			FieldOfView = defaultFov or 70,
		}):Play()
	end
end

function PurchaseEffectClient.onPurchaseFinished(self: PurchaseEffectClient, wasPurchased: boolean, playConfetti: boolean?)
	if wasPurchased then
		if playConfetti ~= false then
			EffectsController.confetti(Players.LocalPlayer)
		end
		self:hide(PurchaseEffectConfig.displayDuration)
	else
		self:hide()
	end
end

function PurchaseEffectClient.init(self: PurchaseEffectClient)
	if initialized then
		return
	end
	initialized = true

	self:ensureRainbow()

	local effectRemote = waitForRemote("PurchaseEffectShow")
	if effectRemote then
		effectRemote.OnClientEvent:Connect(function()
			self:show()
		end)
	else
		warn("[PurchaseEffect] PurchaseEffectShow remote missing; rainbow will not appear before prompts")
	end

	local confettiRemote = waitForRemote("ProductHandlerConfetti")
	if confettiRemote then
		confettiRemote.OnClientEvent:Connect(function()
			EffectsController.confetti(Players.LocalPlayer)
		end)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _gamePassId, wasPurchased)
		if player == Players.LocalPlayer then
			self:onPurchaseFinished(wasPurchased)
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, wasPurchased)
		if userId == Players.LocalPlayer.UserId then
			-- Dev products celebrate via ProductHandlerConfetti from ProcessReceipt.
			self:onPurchaseFinished(wasPurchased, false)
		end
	end)
end

export type PurchaseEffectClient = typeof(PurchaseEffectClient) & {
	_remote: RemoteEvent?,
}

return PurchaseEffectClient :: PurchaseEffectClient
