-- [ACTIVE] PurchaseEffectClient
--[[
	Fullscreen rainbow overlay while a Marketplace purchase prompt is open.
	Hides SideUI chrome for the prompt, then restores it when finished.
]]

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
local activeRainbowTween: Tween? = nil
local activeFovTween: Tween? = nil
local hiddenSideUI: GuiObject? = nil
local sideUIWasVisible = false

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

local function cancelActiveTweens()
	if activeRainbowTween then
		activeRainbowTween:Cancel()
		activeRainbowTween = nil
	end
	if activeFovTween then
		activeFovTween:Cancel()
		activeFovTween = nil
	end
end

local function setPurchasingGuiEnabled(enabled: boolean)
	if not rainbow then
		return
	end
	local effectGui = rainbow.Parent
	if effectGui and effectGui:IsA("ScreenGui") then
		effectGui.Enabled = enabled
	end
end

local function ensureMainGuiEnabled()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
	end
end

local function restoreCameraFov(instant: boolean)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local target = defaultFov or 70
	if instant then
		camera.FieldOfView = target
		return
	end
	activeFovTween = TweenService:Create(camera, fadeOutTween, { FieldOfView = target })
	activeFovTween:Play()
end

local function hideSideHud()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local main = playerGui and playerGui:FindFirstChild("Main")
	local sideUI = main and main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		hiddenSideUI = sideUI
		sideUIWasVisible = sideUI.Visible
		sideUI.Visible = false
	end
end

local function restoreSideHud()
	local side = hiddenSideUI
	hiddenSideUI = nil
	if side and side.Parent then
		side.Visible = sideUIWasVisible or true
		local scale = side:FindFirstChildOfClass("UIScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Parent = side
		end
		scale.Scale = 0.96
		TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end
end

local function beginPurchaseOverlay()
	purchaseUiActive = true
	setCoreGuisVisible(false)
	hideSideHud()
	setPurchasingGuiEnabled(true)
end

local function endPurchaseOverlay()
	purchaseUiActive = false
	setPurchasingGuiEnabled(false)
	setCoreGuisVisible(true)
	restoreSideHud()
	-- Safety: never leave the core HUD ScreenGui disabled after a prompt.
	ensureMainGuiEnabled()
end

local function sanitizePurchasingChildren(effectGui: Instance)
	-- Studio place file ships Purchasing.Loading + Purchasing.Main overlays that sit above
	-- HUD frames (DisplayOrder 10000) and eat clicks. Only Rainbow is used for the effect.
	for _, child in effectGui:GetChildren() do
		if child.Name == "Rainbow" then
			continue
		end
		if child:IsA("GuiObject") then
			child.Visible = false
			child.Active = false
		elseif child:IsA("LayerCollector") then
			-- nested ScreenGui unlikely, but disable if present
			(child :: LayerCollector).Enabled = false
		end
	end
end

function PurchaseEffectClient.ensureRainbow(self: PurchaseEffectClient)
	if rainbow and rainbow.Parent then
		sanitizePurchasingChildren(rainbow.Parent)
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
		effectGui.Enabled = false
	end

	sanitizePurchasingChildren(effectGui)

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
		img.Active = false
		img.Parent = effectGui
		rainbow = img
	else
		rainbow.Active = false
		rainbow.Visible = true
	end
end

function PurchaseEffectClient.show(self: PurchaseEffectClient)
	self:init()
	self:ensureRainbow()
	if not rainbow then
		return
	end

	cancelActiveTweens()
	beginPurchaseOverlay()

	hideToken += 1
	activeRainbowTween = TweenService:Create(rainbow, fadeInTween, { ImageTransparency = 0 })
	activeRainbowTween:Play()

	local camera = workspace.CurrentCamera
	if camera then
		defaultFov = camera.FieldOfView
		local targetFov = math.clamp(defaultFov + PurchaseEffectConfig.fovBoost, 1, 120)
		activeFovTween = TweenService:Create(camera, fadeInTween, { FieldOfView = targetFov })
		activeFovTween:Play()
	end
end

function PurchaseEffectClient.hide(self: PurchaseEffectClient, delaySeconds: number?, onHidden: (() -> ())?)
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

	cancelActiveTweens()
	hideToken += 1
	local finishToken = hideToken

	-- Restore HUD immediately. Only keep Purchasing up while a visible rainbow is fading out.
	endPurchaseOverlay()

	local needsFade = rainbow ~= nil and rainbow.ImageTransparency < 0.99
	if needsFade and rainbow then
		setPurchasingGuiEnabled(true)
		activeRainbowTween = TweenService:Create(rainbow, fadeOutTween, { ImageTransparency = 1 })
		activeRainbowTween:Play()
		local tween = activeRainbowTween
		tween.Completed:Once(function()
			if finishToken ~= hideToken then
				return
			end
			if rainbow then
				rainbow.ImageTransparency = 1
			end
			setPurchasingGuiEnabled(false)
			ensureMainGuiEnabled()
			if onHidden then
				onHidden()
			end
		end)
	else
		setPurchasingGuiEnabled(false)
		ensureMainGuiEnabled()
		if onHidden then
			onHidden()
		end
	end

	restoreCameraFov(false)
end

function PurchaseEffectClient.forceHide(self: PurchaseEffectClient)
	cancelActiveTweens()
	hideToken += 1
	if rainbow then
		rainbow.ImageTransparency = 1
	end
	restoreCameraFov(true)
	endPurchaseOverlay()
end

local function runPurchaseCelebration()
	EffectsController.celebratePurchase(Players.LocalPlayer)
end

function PurchaseEffectClient.onPurchaseFinished(self: PurchaseEffectClient, wasPurchased: boolean)
	if wasPurchased then
		self:hide(nil, runPurchaseCelebration)
	else
		self:forceHide()
	end
end

function PurchaseEffectClient.init(self: PurchaseEffectClient)
	if initialized then
		return
	end
	initialized = true

	self:ensureRainbow()
	-- Join/load can leave StarterGui.Purchasing Enabled; clear before any prompt.
	self:forceHide()

	bindRemoteAsync("PurchaseEffectShow", function()
		self:show()
	end)

	bindRemoteAsync("ProductHandlerConfetti", function()
		if purchaseUiActive or (rainbow and rainbow.ImageTransparency < 0.99) then
			return
		end
		self:hide(nil, runPurchaseCelebration)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _gamePassId, wasPurchased)
		if player == Players.LocalPlayer then
			self:onPurchaseFinished(wasPurchased == true)
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, wasPurchased)
		if userId == Players.LocalPlayer.UserId then
			self:onPurchaseFinished(wasPurchased == true)
		end
	end)
end

export type PurchaseEffectClient = typeof(PurchaseEffectClient) & {
	_remote: RemoteEvent?,
}

return PurchaseEffectClient :: PurchaseEffectClient
