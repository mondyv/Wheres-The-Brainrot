--[[
	Revive PopUP — death panel with 5s countdown, blur, HUD hide, sfx, and Robux revive.
--]]

local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local HUDController = require(script.Parent.HUDController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local player = Players.LocalPlayer

local REVIVE_FRAME_NAME = "Revive PopUP"
local BLUR_NAME = "ReviveBlur"
local BLUR_SIZE = 22

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local reviveFrame: Frame? = nil
local wiredFrame: Frame? = nil
local timerLabel: TextLabel? = nil
local reviveBtnHost: GuiObject? = nil
local declineBtnHost: GuiObject? = nil
local revivePriceLabel: TextLabel? = nil

local sessionActive = false
local countdownConn: RBXScriptConnection? = nil
local currentProductId: number? = nil
local currentLand: number? = nil

local blurEffect: BlurEffect? = nil
local earRingingSound: Sound? = nil
local bgmSounds: { Sound } = {}
local bgmSpeedBySound: { [Sound]: number } = {}

local hiddenHud: { { inst: GuiObject, wasVisible: boolean } } = {}
local priceLabelTemplate: string? = nil

local revivePromptRE: RemoteEvent? = nil
local reviveDeclinedRE: RemoteEvent? = nil
local reviveCompleteRE: RemoteEvent? = nil

local deathSfxTemplate: Sound? = nil
local earRingingTemplate: Sound? = nil

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

local function formatTimer(remainingSec: number): string
	local clamped = math.max(0, remainingSec)
	local secs = math.floor(clamped)
	local millis = math.floor((clamped - secs) * 100 + 0.5)
	if millis >= 100 then
		millis = 99
	end
	return string.format("%d:%02d", secs, millis)
end

local function setRegionalPrice(label: TextLabel, price: number)
	if not priceLabelTemplate then
		priceLabelTemplate = label.Text
	end
	local template = priceLabelTemplate
	label.Text = string.gsub(template, "%d+", tostring(price), 1)
end

local function refreshRegionalPrice(productId: number)
	if not revivePriceLabel then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
			if revivePriceLabel and revivePriceLabel.Parent then
				setRegionalPrice(revivePriceLabel, info.PriceInRobux)
			end
		elseif currentLand then
			if revivePriceLabel and revivePriceLabel.Parent then
				setRegionalPrice(revivePriceLabel, ReviveConfig.defaultPriceForLand(currentLand))
			end
		end
	end)
end

local function collectBgmSounds()
	table.clear(bgmSounds)
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	if not bg then
		return
	end
	local sg = bg:FindFirstChild("SoundGroup")
	if not sg then
		return
	end
	for _, c in sg:GetChildren() do
		if c:IsA("Sound") then
			table.insert(bgmSounds, c)
		end
	end
end

local function setBgmSlowed(slowed: boolean)
	for _, s in bgmSounds do
		if s.Parent then
			if slowed then
				if bgmSpeedBySound[s] == nil then
					bgmSpeedBySound[s] = s.PlaybackSpeed
				end
				s.PlaybackSpeed = ReviveConfig.BGM_PLAYBACK_SPEED
			else
				local prev = bgmSpeedBySound[s]
				s.PlaybackSpeed = if typeof(prev) == "number" then prev else 1
				bgmSpeedBySound[s] = nil
			end
		end
	end
end

local function playDeathSfx()
	if not deathSfxTemplate then
		return
	end
	local clone = deathSfxTemplate:Clone()
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

local function stopEarRinging()
	if earRingingSound then
		earRingingSound:Stop()
		earRingingSound:Destroy()
		earRingingSound = nil
	end
end

local function startEarRinging()
	stopEarRinging()
	if not earRingingTemplate then
		return
	end
	local clone = earRingingTemplate:Clone()
	clone.Looped = true
	clone.Parent = SoundService
	clone:Play()
	earRingingSound = clone
end

local function showBlur()
	if blurEffect and blurEffect.Parent then
		return
	end
	local existing = Lighting:FindFirstChild(BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		blurEffect = existing
	else
		local blur = Instance.new("BlurEffect")
		blur.Name = BLUR_NAME
		blur.Size = 0
		blur.Parent = Lighting
		blurEffect = blur
	end
	TweenService:Create(blurEffect :: BlurEffect, FADE_TWEEN, { Size = BLUR_SIZE }):Play()
end

local function hideBlur()
	if not blurEffect or not blurEffect.Parent then
		return
	end
	local blur = blurEffect
	local tween = TweenService:Create(blur, FADE_TWEEN, { Size = 0 })
	tween.Completed:Once(function()
		if blur.Parent then
			blur:Destroy()
		end
		if blurEffect == blur then
			blurEffect = nil
		end
	end)
	tween:Play()
end

local function resolveMainGui(): ScreenGui?
	local ok, main = pcall(function()
		return PlayerGuiMain.ensure(player)
	end)
	if ok and main and main:IsA("ScreenGui") then
		return main
	end
	return nil
end

local function hideGameplayHud(main: ScreenGui)
	table.clear(hiddenHud)
	HUDController.closeCurrentFrame()

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		local gui = sideUI :: GuiObject
		table.insert(hiddenHud, { inst = gui, wasVisible = gui.Visible })
		gui.Visible = false
	end

	local frames = main:FindFirstChild("Frames")
	if frames then
		for _, ch in frames:GetChildren() do
			if ch:IsA("GuiObject") and ch.Name ~= REVIVE_FRAME_NAME then
				local gui = ch :: GuiObject
				table.insert(hiddenHud, { inst = gui, wasVisible = gui.Visible })
				gui.Visible = false
			end
		end
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	local clock = if playerGui then playerGui:FindFirstChild("ClockImage") else nil
	if not clock then
		clock = StarterGui:FindFirstChild("ClockImage")
	end
	if clock and clock:IsA("GuiObject") then
		local gui = clock :: GuiObject
		table.insert(hiddenHud, { inst = gui, wasVisible = gui.Visible })
		gui.Visible = false
	end
end

local function restoreGameplayHud()
	for _, entry in hiddenHud do
		if entry.inst.Parent then
			entry.inst.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenHud)
end

local function cancelCountdown()
	if countdownConn then
		countdownConn:Disconnect()
		countdownConn = nil
	end
end

local function animatePanelIn(frame: Frame)
	local scale = getOrAddUIScale(frame)
	scale.Scale = 0.78
	frame.Visible = true
	TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()

	for _, childName in { "Revive Button", "Decline Button", "Timer" } do
		local child = frame:FindFirstChild(childName)
		if child and child:IsA("GuiObject") then
			local g = child :: GuiObject
			if g:IsA("TextLabel") or g:IsA("TextButton") then
				(g :: any).TextTransparency = 1
				TweenService:Create(g, FADE_TWEEN, { TextTransparency = 0 }):Play()
			elseif g:IsA("ImageLabel") or g:IsA("ImageButton") then
				(g :: any).ImageTransparency = 1
				TweenService:Create(g, FADE_TWEEN, { ImageTransparency = 0 }):Play()
			end
		end
	end
end

local function animatePanelOut(frame: Frame, onDone: () -> ())
	local scale = getOrAddUIScale(frame)
	local tween = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
	tween.Completed:Once(function()
		frame.Visible = false
		scale.Scale = 1
		onDone()
	end)
	tween:Play()
end

local function wireReviveButton(host: GuiObject, onClick: () -> ())
	local scale = getOrAddUIScale(host)
	local clickBtn = host:FindFirstChild("__ReviveClick") :: TextButton?
	if not clickBtn then
		clickBtn = Instance.new("TextButton")
		clickBtn.Name = "__ReviveClick"
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 100
		clickBtn.Parent = host
	end
	clickBtn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
	clickBtn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
	clickBtn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
	end)
	clickBtn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
	end)
	clickBtn.Activated:Connect(onClick)
end

local function wireDeclineButton(host: GuiObject, onClick: () -> ())
	local scale = getOrAddUIScale(host)
	local clickBtn = host:FindFirstChild("__DeclineClick") :: TextButton?
	if not clickBtn then
		clickBtn = Instance.new("TextButton")
		clickBtn.Name = "__DeclineClick"
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 100
		clickBtn.Parent = host
	end
	clickBtn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.05 }):Play()
	end)
	clickBtn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
	clickBtn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.95 }):Play()
	end)
	clickBtn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.05 }):Play()
	end)
	clickBtn.Activated:Connect(onClick)
end

local function cleanupReviveSession()
	cancelCountdown()
	stopEarRinging()
	setBgmSlowed(false)
	hideBlur()
	restoreGameplayHud()
	sessionActive = false
	currentProductId = nil
	currentLand = nil
end

local function closeRevivePanel(declined: boolean)
	if not sessionActive or not reviveFrame then
		return
	end
	sessionActive = false
	cancelCountdown()

	local frame = reviveFrame
	animatePanelOut(frame, function()
		cleanupReviveSession()
	end)

	if declined and reviveDeclinedRE then
		reviveDeclinedRE:FireServer()
	end
end

local function startCountdown(duration: number)
	cancelCountdown()
	local endAt = os.clock() + duration
	if timerLabel then
		timerLabel.Text = formatTimer(duration)
	end
	countdownConn = RunService.Heartbeat:Connect(function()
		if not sessionActive then
			return
		end
		local remaining = endAt - os.clock()
		if timerLabel and timerLabel.Parent then
			timerLabel.Text = formatTimer(remaining)
		end
		if remaining <= 0 then
			closeRevivePanel(true)
		end
	end)
end

local function tryRevivePurchase()
	if not sessionActive or not currentProductId then
		return
	end
	pcall(function()
		MarketplaceService:PromptProductPurchase(player, currentProductId)
	end)
end

local function bindReviveFrame(frame: Frame)
	if wiredFrame == frame then
		return
	end
	wiredFrame = frame
	reviveFrame = frame

	timerLabel = frame:FindFirstChild("Timer") :: TextLabel?
	local reviveBtn = frame:FindFirstChild("Revive Button")
	local declineBtn = frame:FindFirstChild("Decline Button")
	reviveBtnHost = if reviveBtn and reviveBtn:IsA("GuiObject") then reviveBtn else nil
	declineBtnHost = if declineBtn and declineBtn:IsA("GuiObject") then declineBtn else nil

	if reviveBtnHost then
		local nameLabel = reviveBtnHost:FindFirstChild("Name")
		if nameLabel and nameLabel:IsA("TextLabel") then
			revivePriceLabel = nameLabel
			if not priceLabelTemplate then
				priceLabelTemplate = nameLabel.Text
			end
		end
		wireReviveButton(reviveBtnHost, tryRevivePurchase)
	end
	if declineBtnHost then
		wireDeclineButton(declineBtnHost, function()
			closeRevivePanel(true)
		end)
	end
end

local function resolveReviveFrame(main: ScreenGui): Frame?
	local frames = main:FindFirstChild("Frames")
	if not frames then
		return nil
	end
	local frame = frames:FindFirstChild(REVIVE_FRAME_NAME)
	if frame and frame:IsA("Frame") then
		bindReviveFrame(frame)
		return frame
	end
	return nil
end

local function openRevivePanel(land: number, productId: number, countdownSec: number)
	if sessionActive then
		return
	end

	local main = resolveMainGui()
	if not main then
		warn("[ReviveController] Main ScreenGui missing in PlayerGui")
		return
	end

	local frame = resolveReviveFrame(main)
	if not frame then
		warn("[ReviveController] Revive PopUP frame missing under Main.Frames")
		return
	end

	main.Enabled = true
	local loading = main.Parent and (main.Parent :: Instance):FindFirstChild("LoadingScreen")
	if loading and loading:IsA("ScreenGui") then
		loading.Enabled = false
	end

	sessionActive = true
	currentLand = land
	currentProductId = productId

	frame.Active = false
	hideGameplayHud(main)
	showBlur()
	collectBgmSounds()
	setBgmSlowed(true)
	startEarRinging()
	refreshRegionalPrice(productId)
	animatePanelIn(frame)
	startCountdown(countdownSec)
end

local function resolveSoundTemplates()
	local deathFolder = SoundService:FindFirstChild("Death")
	local deathGroup = deathFolder and deathFolder:FindFirstChild("SoundGroup")
	if deathGroup then
		local deathSfx = deathGroup:FindFirstChild("Death SFX")
		if deathSfx and deathSfx:IsA("Sound") then
			deathSfxTemplate = deathSfx
		end
		local ear = deathGroup:FindFirstChild("Ear Ringing")
		if ear and ear:IsA("Sound") then
			earRingingTemplate = ear
		end
	end
end

local function hookCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	end
	if not humanoid then
		return
	end
	humanoid.Died:Connect(function()
		playDeathSfx()
	end)
end

local ReviveController = {}

function ReviveController.init()
	resolveSoundTemplates()

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 60)
	revivePromptRE = remotes:WaitForChild("RevivePrompt", 30) :: RemoteEvent
	reviveDeclinedRE = remotes:WaitForChild("ReviveDeclined", 30) :: RemoteEvent
	reviveCompleteRE = remotes:WaitForChild("ReviveComplete", 30) :: RemoteEvent

	revivePromptRE.OnClientEvent:Connect(function(land: number, productId: number, countdownSec: number?)
		local duration = if typeof(countdownSec) == "number" then countdownSec else ReviveConfig.COUNTDOWN_SECONDS
		openRevivePanel(land, productId, duration)
	end)

	reviveCompleteRE.OnClientEvent:Connect(function()
		if sessionActive then
			sessionActive = false
			cancelCountdown()
			if reviveFrame then
				reviveFrame.Visible = false
			end
			cleanupReviveSession()
		end
	end)

	task.spawn(function()
		local main = PlayerGuiMain.ensure(player)
		local frame = resolveReviveFrame(main)
		if not frame then
			warn("[ReviveController] Revive PopUP frame missing at init")
			return
		end
		frame.Visible = false
		frame.Active = false
	end)

	player.CharacterAdded:Connect(function(character)
		hookCharacter(character)
	end)

	if player.Character then
		hookCharacter(player.Character)
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, wasPurchased: boolean)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if ReviveConfig.isReviveProduct(productId) and sessionActive then
			sessionActive = false
			cancelCountdown()
			if reviveFrame then
				reviveFrame.Visible = false
			end
			cleanupReviveSession()
		end
	end)
end

return ReviveController
