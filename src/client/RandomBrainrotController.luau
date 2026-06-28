--// < Made by: MikePlayz163 >

-->> || Services || <<--

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-->> || Variables || <<--

local Player = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait() :: Player
local _Character = Player.Character or Player.CharacterAdded:Wait() :: Model

local activationUiWired = false

-->> || Modules || <<--

local EssentialsShared = ReplicatedStorage:WaitForChild("EssentialsShared") :: Folder
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Prompter = require(EssentialsShared.PurchasePrompt)
local Effects = require(EssentialsShared.EffectsController)

local BrainrotsConfig = require(Shared.BrainrotsConfig)
local StoreConfig = require(Shared.StoreConfig)

local HUDController = require(script.Parent.HUDController)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local Maid = require(Packages.Maid)
local Promise = require(Packages.Promise)

-->> || Types || <<--

export type Controller = {
	Cleanup: (self: Controller) -> (),
	Render: (self: Controller, deltaTime: number) -> (),
	Setup: (self: Controller) -> (),
	Init: (self: Controller) -> (),
}

type InternalController = Controller & {

	-->> Internal Variables!!!

	_CONFIG: {
		debugMode: boolean,
		renderInterval: number?,

		imageryRotation: number,
		_passedTime: number,

		productId: number,
		textTemplate: string,

		awaitInterval: number,
	},

	_RUNNING: boolean,

	_SETUP_COMPLETE: boolean,
	_SETUP_PROMISE: any?,

	-->> Internal Methods

	_logger: (self: InternalController, message: string, type: "info" | "warn" | "error"?) -> (boolean, string?),
	_celebrate: (self: InternalController) -> any?,
	_linkButtons: (self: InternalController) -> boolean?,

	_locateEventsFolder: (self: InternalController) -> Instance?,
	_bindRemoteAsync: (self: InternalController, name: string, handler: () -> ()) -> (),
	_awaitRemote: (self: InternalController, id: number) -> RemoteEvent?,

	_getProductInfo: (self: InternalController, id: number, type: Enum.InfoType) -> ProductInfo?,
	_trackPurchase: (self: InternalController) -> (),

	_preloadImagery: (self: InternalController, id: string) -> boolean?,
	_obtainNextImagery: (self: InternalController) -> string?,
	_updateImagery: (self: InternalController) -> boolean?,
}

type ProductInfo = {
	Name: string,
	Description: string,

	PriceInRobux: number,
	ProductId: number,

	ProductType: string,
}

-->> || Configuration || <<--

local _CONFIG = {
	debugMode = false,
	renderInterval = 1 / 12,

	imageryRotation = 2,
	_passedTime = 0,

	productId = 3604806744,
	textTemplate = " AMOUNT",

	awaitInterval = 8,
}

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function highlightOn(host: GuiObject): GuiObject?
	local decor = host:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local on = highlight and highlight:FindFirstChild("On")
	if on and on:IsA("GuiObject") then
		return on :: GuiObject
	end
	return nil
end

local function resolveRandomBrainrotUi(): (ImageButton, Instance, Instance)
	local gui = PlayerGuiMain.ensure(Player)
	local activation = gui:WaitForChild("SideUI")
		:WaitForChild("Right")
		:WaitForChild("RandomBrainrot")
		:WaitForChild("Activation") :: ImageButton
	local storePack = gui:WaitForChild("Frames")
		:WaitForChild("Store")
		:WaitForChild("StoreFrame")
		:WaitForChild("Container")
		:WaitForChild("RandomBrainrot")
	return activation, activation.Chances, storePack
end

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

local function ensureClickButton(host: GuiObject): GuiButton
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local existing = host:FindFirstChild("_HudClick")
	if existing and existing:IsA("GuiButton") then
		return existing :: GuiButton
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_HudClick"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 50
	btn.Active = true
	btn.AutoButtonColor = false
	btn.Parent = host
	return btn
end

local function passthroughActivationChildren(activation: GuiObject, chancesHost: Instance?)
	for _, child in activation:GetDescendants() do
		if chancesHost and (child == chancesHost or child:IsDescendantOf(chancesHost)) then
			continue
		end
		if child:IsA("GuiObject") and not child:IsA("GuiButton") then
			child.Active = false
		end
	end
end

local function wireActivationHover(
	activation: ImageButton,
	chancesHost: Instance,
	onActivated: () -> (),
	maid: any
)
	if activationUiWired then
		return
	end
	activationUiWired = true

	activation.Active = true
	if activation:IsA("ImageButton") then
		activation.AutoButtonColor = false
	end

	passthroughActivationChildren(activation, chancesHost)

	local frame = activation.Parent
	local frameScale = if frame and frame:IsA("GuiObject") then getOrAddUIScale(frame :: GuiObject) else nil

	local icon = activation:FindFirstChild("Icon")
	local tiltTarget: GuiObject = if icon and icon:IsA("GuiObject") then icon :: GuiObject else activation
	local onHighlight = highlightOn(activation)
	if onHighlight then
		onHighlight.Visible = false
	end

	UIButtonEffects.wireTiltHoverButton(activation, onActivated, activation, tiltTarget, true)

	maid:GiveTask(activation.MouseEnter:Connect(function()
		if onHighlight then
			onHighlight.Visible = true
		end
		if frameScale then
			TweenService:Create(frameScale, HOVER_TWEEN, { Scale = 1.02 }):Play()
		end
	end))
	maid:GiveTask(activation.MouseLeave:Connect(function()
		if onHighlight then
			onHighlight.Visible = false
		end
		if frameScale then
			TweenService:Create(frameScale, HOVER_TWEEN, { Scale = 1 }):Play()
		end
	end))
end

-->> || Main ~ Utilities || <<--

local Main = {} :: InternalController
Main.__index = Main

Main._CONFIG = _CONFIG
Main._MAID = Maid.new()

Main._RUNNING = false
Main._SETUP_COMPLETE = false
Main._SETUP_PROMISE = nil

-->> || Private ~ API || <<--

function Main:_logger(message: string, type: "info" | "warn" | "error"?): (boolean, string?)
	if not message then
		return false, "No message was provided."
	end

	if not type then
		type = "info"
	end

	local function obtainScriptInfo()
		local traceback = debug.traceback()
		local pattern = "([^\n]+):(%d+)"
		local count = 0
		for source, line in string.gmatch(traceback, pattern) do
			count = count + 1
			if count == 4 then
				source = source:match("([^%.]+)$") or source
				return source, tonumber(line) or 0
			end
		end
		return "Unknown", 0
	end

	local function log(level, message, bypassStudioCheck, ...)
		local scriptName, lineNumber = obtainScriptInfo()
		local formattedMessage =
			string.format("[%s] [%s:%d] %s", level, scriptName, lineNumber, string.format(message, ...))

		if level == "ERROR" or level == "WARN" or bypassStudioCheck or RunService:IsStudio() then
			if level == "ERROR" or level == "WARN" then
				warn(formattedMessage)
			else
				print(formattedMessage)
			end
		end
	end

	if type == "info" then
		log("INFO", message, false)
	elseif type == "warn" then
		log("WARN", message, true)
	else
		log("ERROR", message, true)
	end

	return true
end

function Main:_locateEventsFolder(): Instance?
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

function Main:_awaitRemote(name: string): RemoteEvent?
	local events = self:_locateEventsFolder()
	if not events then
		local assets = ReplicatedStorage:WaitForChild("EssentialAssets", self._CONFIG.awaitInterval)
		if assets then
			events = assets:WaitForChild("Events", self._CONFIG.awaitInterval)
		end
	end

	if not events then
		return nil
	end

	return events:WaitForChild(name, self._CONFIG.awaitInterval) :: RemoteEvent?
end

function Main:_bindRemoteAsync(name: string, handler: () -> ())
	task.spawn(function()
		local remote = self:_awaitRemote(name)

		if remote then
			remote.OnClientEvent:Connect(handler)
		else
			warn(`[{script.Name}]`, name, "remote missing — is EssentialsServer running?")
		end
	end)
end

function Main:_getProductInfo(id: number, type: Enum.InfoType?)
	if not id then
		self:_logger("Provided ID is of type 'nil'.", "warn")
		return
	end

	if not type then
		self:_logger("Provided Type is of type 'nil', using fallback option.", "info")
	end

	return Promise.try(function()
		return MarketplaceService:GetProductInfoAsync(id, type or Enum.InfoType.Product)
	end)
end

function Main:_celebrate(): any
	return Effects.celebratePurchase(Player)
end

function Main:_linkButtons(): boolean
	local activation, chancesHost, storePack = resolveRandomBrainrotUi()

	self:_getProductInfo(self._CONFIG.productId, Enum.InfoType.Product)
		:andThen(function(info: ProductInfo)
			if not info then
				self:_logger("Provided Info was deemed 'nil'.")
				return
			end

			local priceLabel = activation:FindFirstChild("Price")
			if priceLabel and priceLabel:IsA("TextLabel") then
				priceLabel.Text = self._CONFIG.textTemplate:gsub("AMOUNT", info.PriceInRobux)
			end

			for _, label in storePack:GetDescendants() do
				if not label:IsA("TextLabel") and label.Name ~= "Price" then
					continue
				end

				if label:IsA("TextLabel") and label.Name == "Price" then
					label.Text = tostring(info.PriceInRobux)
					break
				end
			end
		end)
		:catch(function(issue)
			self:_logger(
				`Failed to obtain info for product: '{tostring(self._CONFIG.productId)}' | Generated issue: {tostring(
					issue
				)}`
			)
			return
		end)

	wireActivationHover(activation, chancesHost, function()
		Prompter.promptProduct(StoreConfig.PRODUCT.RANDOM_BRAINROT)
	end, self._MAID)

	local chancesBtn = ensureClickButton(chancesHost :: GuiObject)
	UIButtonEffects.wireScaleButtonAnim(chancesBtn, function()
		local current = HUDController.getCurrentFrame()

		if current and current.Name == "Chances" then
			HUDController.closeFrameByName("Chances")
		else
			HUDController.openFrameByName("Chances")
		end
	end)

	return true
end

function Main:_obtainNextImagery()
	local brainrots = BrainrotsConfig:GetAllSorted()
	if #brainrots <= 0 then
		return nil
	end

	local randomSel = brainrots[math.random(1, #brainrots)]
	if not randomSel then
		return nil
	end

	local icons = randomSel.icons
	if typeof(icons) == "table" then
		local icon = icons.Normal
		if typeof(icon) == "string" and icon ~= "" then
			return icon
		end
	end

	local name = randomSel.name
	if typeof(name) == "string" and name ~= "" then
		local fallback = BrainrotsConfig:GetNormalIcon(name)
		if typeof(fallback) == "string" and fallback ~= "" then
			return fallback
		end
	end

	return nil
end

function Main:_preloadImagery(id: string)
	if not id then
		return nil
	end

	if typeof(id) ~= "string" then
		return nil
	end

	local activation = resolveRandomBrainrotUi()
	local _asset = Instance.new("ImageLabel")
	_asset.Name = "TEMP_ASSET"
	_asset.Parent = activation
	_asset.ImageTransparency = 1
	_asset.BackgroundTransparency = 1
	_asset.Visible = true
	_asset.Image = id

	local success, err = pcall(function()
		return ContentProvider:PreloadAsync({ _asset })
	end)

	if not success then
		warn("[RandomBrainrotController] preload error:", err)
	end
	if success then
		task.wait(0.1)
		_asset:Destroy()
	end

	return true
end

function Main:_updateImagery()
	local activation, _, storePack = resolveRandomBrainrotUi()
	local imagery = activation:FindFirstChild("Icon")
	if not imagery or not imagery:IsA("ImageLabel") then
		return nil
	end

	local imagery_2 = storePack:FindFirstChild("Icon")
	if not imagery_2 or not imagery_2:IsA("ImageLabel") then
		return nil
	end

	local nextImage = self:_obtainNextImagery()
	if not nextImage then
		return nil
	end

	if not self:_preloadImagery(nextImage) then
		return nil
	end

	imagery.Image = nextImage
	imagery_2.Image = nextImage

	return true
end

function Main:_trackPurchase()
	self:_bindRemoteAsync("OnPurchase", function()
		if HUDController.getCurrentFrame() ~= nil then
			HUDController.closeCurrentFrame()
		end
	end)
end

-->> || Public ~ API || <<--

function Main:Render(deltaTime: number)
	if not self._RUNNING then
		return
	end

	if not self._SETUP_COMPLETE then
		return
	end

	self._CONFIG._passedTime += deltaTime

	if self._CONFIG._passedTime >= self._CONFIG.imageryRotation then
		self._CONFIG._passedTime -= self._CONFIG.imageryRotation

		self:_updateImagery()
	end

	return
end

function Main:Setup()
	if self._SETUP_COMPLETE then
		return Promise.resolve()
	end

	if self._SETUP_PROMISE then
		return self._SETUP_PROMISE
	end

	self._SETUP_PROMISE = Promise.try(function()
		PlayerGuiMain.ensure(Player)
		self:_linkButtons()
		self:_trackPurchase()
		self:_updateImagery()

		self._SETUP_COMPLETE = true
	end)
		:catch(function(issue)
			self:_logger(`Failed to setup environment client, generated issue: {tostring(issue)}`, "warn")
		end)
		:finally(function()
			self._SETUP_PROMISE = nil
		end)

	return self._SETUP_PROMISE
end

function Main:Cleanup() -->> only in specifc situations
	self._RUNNING = false
	self._SETUP_COMPLETE = false

	self._MAID:DoCleaning()
	self._MAID = Maid.new()
end

function Main:Init()
	return Promise.try(function()
		return self:Setup()
	end)
		:andThen(function()
			if self._RUNNING then
				return
			end

			self._RUNNING = true

			self._MAID:GiveTask(RunService.RenderStepped:Connect(function(deltaTime)
				if not self._RUNNING then
					return
				end

				self:Render(deltaTime)
			end))
		end)
		:catch(function(issue)
			self:_logger(`Failed to initialize environment client, generated issue: {tostring(issue)}`, "warn")
		end)
end

return Main :: Controller
