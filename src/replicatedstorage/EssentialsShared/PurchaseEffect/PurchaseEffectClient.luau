-- [ACTIVE] PurchaseEffectClient
local MarketplaceService = game:GetService("MarketplaceService")
local StarterGui = game:GetService("StarterGui")
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
local purchaseUiActive = false
local savedGuiStates: { [ScreenGui]: boolean }? = nil
local playerGuiChildConn: RBXScriptConnection? = nil

local CORE_GUIS_TO_HIDE: { Enum.CoreGuiType } = {
	Enum.CoreGuiType.Chat,
	Enum.CoreGuiType.PlayerList,
}

local fadeInTween =
	TweenInfo.new(PurchaseEffectConfig.fadeInDuration, PurchaseEffectConfig.easingStyle, Enum.EasingDirection.Out)
local fadeOutTween =
	TweenInfo.new(PurchaseEffectConfig.fadeOutDuration, PurchaseEffectConfig.easingStyle, Enum.EasingDirection.In)

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

local function waitForRemote(name: string): RemoteEvent?
	local events = findEventsFolder()
	if not events then
		local assets = ReplicatedStorage:WaitForChild("EssentialAssets", REMOTE_WAIT_SEC)
		if assets then
			events = assets:WaitForChild("Events", REMOTE_WAIT_SEC)
		end
	end
	if not events then
		return nil
	end
	return events:WaitForChild(name, REMOTE_WAIT_SEC) :: RemoteEvent?
end

local function bindRemoteAsync(name: string, handler: () -> ())
	task.spawn(function()
		local remote = waitForRemote(name)
		if remote then
			remote.OnClientEvent:Connect(handler)
		else
			warn("[PurchaseEffect]", name, "remote missing — is EssentialsServer running?")
		end
	end)
end

local function setCoreGuisVisible(visible: boolean)
	for _, coreType in CORE_GUIS_TO_HIDE do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(coreType, visible)
		end)
	end
end

local function isPurchaseGui(name: string): boolean
	return name == "Purchasing"
end

local function enterPurchaseUiIsolation()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	purchaseUiActive = true
	setCoreGuisVisible(false)

	if not savedGuiStates then
		savedGuiStates = {}
		for _, child in playerGui:GetChildren() do
			if child:IsA("ScreenGui") then
				savedGuiStates[child] = child.Enabled
			end
		end
	end

	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") then
			child.Enabled = isPurchaseGui(child.Name)
		end
	end

	if not playerGuiChildConn then
		playerGuiChildConn = playerGui.ChildAdded:Connect(function(child)
			if not purchaseUiActive then
				return
			end
			if child:IsA("ScreenGui") and not isPurchaseGui(child.Name) then
				if savedGuiStates then
					savedGuiStates[child] = child.Enabled
				end
				child.Enabled = false
			end
		end)
	end
end

local function exitPurchaseUiIsolation()
	purchaseUiActive = false

	if playerGuiChildConn then
		playerGuiChildConn:Disconnect()
		playerGuiChildConn = nil
	end

	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if savedGuiStates then
		for gui, wasEnabled in savedGuiStates do
			if gui.Parent and not isPurchaseGui(gui.Name) then
				gui.Enabled = wasEnabled
			end
		end
		savedGuiStates = nil
	end

	setCoreGuisVisible(true)

	if playerGui then
		local purchasing = playerGui:FindFirstChild("Purchasing")
		if purchasing and purchasing:IsA("ScreenGui") then
			purchasing.Enabled = true
		end
	end
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

	enterPurchaseUiIsolation()

	local effectGui = rainbow.Parent
	if effectGui and effectGui:IsA("ScreenGui") then
		effectGui.Enabled = true
	end

	hideToken += 1
	TweenService:Create(rainbow, fadeInTween, { ImageTransparency = 0 }):Play()

	local camera = workspace.CurrentCamera
	if camera then
		defaultFov = camera.FieldOfView
		local targetFov = math.clamp(defaultFov + PurchaseEffectConfig.fovBoost, 1, 120)
		TweenService:Create(camera, fadeInTween, { FieldOfView = targetFov }):Play()
	end
end

function PurchaseEffectClient.hide(self: PurchaseEffectClient, delaySeconds: number?, onHidden: (() -> ())?)
	if not rainbow then
		exitPurchaseUiIsolation()
		if onHidden then
			onHidden()
		end
		return
	end

	local token = hideToken
	local delayTime = delaySeconds or 0
	if delayTime > 0 then
		task.delay(delayTime, function()
			if token ~= hideToken then
				return
			end
			self:hide(nil, onHidden)
		end)
		return
	end

	local tween = TweenService:Create(rainbow, fadeOutTween, { ImageTransparency = 1 })
	tween:Play()

	local camera = workspace.CurrentCamera
	if camera then
		TweenService:Create(camera, fadeOutTween, {
			FieldOfView = defaultFov or 70,
		}):Play()
	end

	exitPurchaseUiIsolation()

	if onHidden then
		tween.Completed:Once(function()
			if token == hideToken then
				onHidden()
			end
		end)
	end
end

local function runPurchaseCelebration()
	EffectsController.celebratePurchase(Players.LocalPlayer)
end

function PurchaseEffectClient.onPurchaseFinished(self: PurchaseEffectClient, wasPurchased: boolean)
	if wasPurchased then
		self:hide(nil, runPurchaseCelebration)
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

	bindRemoteAsync("PurchaseEffectShow", function()
		self:show()
	end)

	bindRemoteAsync("ProductHandlerConfetti", function()
		-- Client-initiated purchases already celebrate via PromptProductPurchaseFinished
		-- after the rainbow fades; only run confetti here when no rainbow was showing.
		local rainbowVisible = rainbow and rainbow.ImageTransparency < 0.99
		if rainbowVisible then
			self:hide()
		else
			self:hide(nil, runPurchaseCelebration)
		end
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _gamePassId, wasPurchased)
		if player == Players.LocalPlayer then
			self:onPurchaseFinished(wasPurchased)
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, wasPurchased)
		if userId == Players.LocalPlayer.UserId then
			self:onPurchaseFinished(wasPurchased)
		end
	end)
end

export type PurchaseEffectClient = typeof(PurchaseEffectClient) & {
	_remote: RemoteEvent?,
}

return PurchaseEffectClient :: PurchaseEffectClient
