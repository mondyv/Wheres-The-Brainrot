-- [ACTIVE] ReviveController
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
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local ReviveConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReviveConfig"))

local player = Players.LocalPlayer

local REVIVE_FRAME_NAME = "Revive PopUP"
local BLUR_NAME = "ReviveBlur"
local BLUR_SIZE = 32
local DIM_GUI_NAME = "ReviveDim"
local DIM_COLOR = Color3.fromRGB(0, 0, 0)
local DIM_TRANSPARENCY = 0.38

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local revivePanel: GuiObject? = nil
local wiredPanel: GuiObject? = nil
local timerLabel: TextLabel? = nil
local reviveBtnHost: GuiObject? = nil
local declineBtnHost: GuiObject? = nil
local revivePriceLabel: TextLabel? = nil

local sessionActive = false
local purchasePromptOpen = false
local countdownConn: RBXScriptConnection? = nil
local currentProductId: number? = nil
local currentLand: number? = nil

local blurEffect: BlurEffect? = nil
local dimGui: ScreenGui? = nil
local dimFrame: Frame? = nil
local earRingingSound: Sound? = nil
local bgmSounds: { Sound } = {}
local bgmSpeedBySound: { [Sound]: number } = {}
local bgmSpeedTweens: { [Sound]: Tween } = {}

local hiddenHud: { { inst: GuiObject, wasVisible: boolean } } = {}
local hudRestoredCallbacks: { () -> () } = {}
local priceLabelTemplate: string? = nil

local reviveDeclinedRE: RemoteEvent? = nil
local reviveCompleteRE: RemoteEvent? = nil

local deathSfxTemplate: Sound? = nil
local earRingingTemplate: Sound? = nil
local deathSoundGroup: SoundGroup? = nil

local DEFAULT_DEATH_SOUND_IDS = {
	"rbxasset://sounds/uuhhh.mp3",
	"rbxasset://sounds/snap.mp3",
	"rbxasset://sounds/bass.mp3",
}

local function isDefaultRobloxDeathSound(sound: Sound): boolean
	local id = string.lower(sound.SoundId)
	for _, defaultId in DEFAULT_DEATH_SOUND_IDS do
		if id == defaultId or string.find(id, "uuhhh", 1, true) then
			return true
		end
	end
	local n = string.lower(sound.Name)
	return n == "died" or n == "death" or n == "oof"
end

local function muteDefaultDeathSound(sound: Sound)
	if not isDefaultRobloxDeathSound(sound) then
		return
	end
	sound.Volume = 0
	sound:Stop()
	sound:Destroy()
end

local function stopRobloxOofSounds()
	for _, inst in SoundService:GetDescendants() do
		if inst:IsA("Sound") and isDefaultRobloxDeathSound(inst) then
			inst:Stop()
			inst:Destroy()
		end
	end
end

local function suppressDefaultDeathSounds(character: Model)
	for _, desc in character:GetDescendants() do
		if desc:IsA("Sound") then
			muteDefaultDeathSound(desc)
		end
	end
	character.DescendantAdded:Connect(function(desc)
		if desc:IsA("Sound") then
			muteDefaultDeathSound(desc)
		end
	end)
end

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
	local function addSoundsFrom(parent: Instance)
		for _, c in parent:GetChildren() do
			if c:IsA("Sound") then
				table.insert(bgmSounds, c)
			end
		end
	end
	addSoundsFrom(sg)
	for _, folderName in { "WhenHolding", "Safezone" } do
		local folder = sg:FindFirstChild(folderName)
		if folder then
			addSoundsFrom(folder)
		end
	end
end

local function bgmSlowFadeTween(): TweenInfo
	return TweenInfo.new(ReviveConfig.BGM_SLOW_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

local function setBgmSlowed(slowed: boolean)
	for _, s in bgmSounds do
		if not s.Parent then
			continue
		end
		local existing = bgmSpeedTweens[s]
		if existing then
			existing:Cancel()
			bgmSpeedTweens[s] = nil
		end
		if slowed then
			if bgmSpeedBySound[s] == nil then
				bgmSpeedBySound[s] = s.PlaybackSpeed
			end
			local tween = TweenService:Create(s, bgmSlowFadeTween(), {
				PlaybackSpeed = ReviveConfig.BGM_PLAYBACK_SPEED,
			})
			bgmSpeedTweens[s] = tween
			tween:Play()
		else
			local prev = bgmSpeedBySound[s]
			local target = if typeof(prev) == "number" then prev else 1
			bgmSpeedBySound[s] = nil
			local tween = TweenService:Create(s, bgmSlowFadeTween(), { PlaybackSpeed = target })
			bgmSpeedTweens[s] = tween
			tween.Completed:Once(function()
				if bgmSpeedTweens[s] == tween then
					bgmSpeedTweens[s] = nil
				end
			end)
			tween:Play()
		end
	end
end

local function playDeathSfx()
	stopRobloxOofSounds()
	if not deathSfxTemplate then
		return
	end
	local clone = deathSfxTemplate:Clone()
	if deathSoundGroup and deathSoundGroup.Parent then
		clone.SoundGroup = deathSoundGroup
		clone.Parent = deathSoundGroup
	else
		clone.Parent = SoundService
	end
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
	if deathSoundGroup and deathSoundGroup.Parent then
		clone.SoundGroup = deathSoundGroup
		clone.Parent = deathSoundGroup
	else
		clone.Parent = SoundService
	end
	clone:Play()
	earRingingSound = clone
end

local function showReviveBackdrop()
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

	local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild(DIM_GUI_NAME)
	if not gui or not gui:IsA("ScreenGui") then
		gui = Instance.new("ScreenGui")
		gui.Name = DIM_GUI_NAME
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 49
		gui.IgnoreGuiInset = true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui

		local frame = Instance.new("Frame")
		frame.Name = "Dim"
		frame.Size = UDim2.fromScale(1, 1)
		frame.Position = UDim2.fromScale(0, 0)
		frame.BackgroundColor3 = DIM_COLOR
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.ZIndex = 1
		frame.Parent = gui
		dimFrame = frame
	end

	dimGui = gui :: ScreenGui
	gui.Enabled = true
	local frame = dimFrame or gui:FindFirstChild("Dim")
	if frame and frame:IsA("Frame") then
		dimFrame = frame
		TweenService:Create(frame, FADE_TWEEN, { BackgroundTransparency = DIM_TRANSPARENCY }):Play()
	end
end

local function hideReviveBackdrop()
	if blurEffect and blurEffect.Parent then
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
	elseif Lighting:FindFirstChild(BLUR_NAME) then
		local blur = Lighting:FindFirstChild(BLUR_NAME)
		if blur and blur:IsA("BlurEffect") then
			blur:Destroy()
		end
		blurEffect = nil
	end

	if dimFrame and dimFrame.Parent then
		local frame = dimFrame
		local tween = TweenService:Create(frame, FADE_TWEEN, { BackgroundTransparency = 1 })
		tween.Completed:Once(function()
			if dimGui and dimGui.Parent then
				dimGui.Enabled = false
			end
		end)
		tween:Play()
	elseif dimGui and dimGui.Parent then
		dimGui.Enabled = false
	end
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
	if #hiddenHud > 0 then
		return
	end

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
		if frames:IsA("GuiObject") then
			(frames :: GuiObject).Visible = true
		end
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

	local main = resolveMainGui()
	if main then
		main.Enabled = true
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Visible = true
		end
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		for _, ch in playerGui:GetChildren() do
			if ch:IsA("ScreenGui") and (ch.Name == "Hud" or ch.Name == "Main") then
				ch.Enabled = true
			end
		end
	end
end

local function fireHudRestoredCallbacks()
	for _, fn in hudRestoredCallbacks do
		pcall(fn)
	end
end

local function refreshGameplayHudAfterRevive()
	restoreGameplayHud()
	fireHudRestoredCallbacks()
end

local function cancelCountdown()
	if countdownConn then
		countdownConn:Disconnect()
		countdownConn = nil
	end
end

local function animatePanelIn(panel: GuiObject)
	local scale = getOrAddUIScale(panel)
	scale.Scale = 0.78
	panel.Visible = true
	TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
end

local function animatePanelOut(panel: GuiObject, onDone: () -> ())
	local scale = getOrAddUIScale(panel)
	local tween = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
	tween.Completed:Once(function()
		panel.Visible = false
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
	hideReviveBackdrop()
	refreshGameplayHudAfterRevive()
	sessionActive = false
	currentProductId = nil
	currentLand = nil
end

local function closeRevivePanel(declined: boolean)
	if not sessionActive or not revivePanel then
		return
	end
	sessionActive = false
	cancelCountdown()

	local panel = revivePanel
	animatePanelOut(panel, function()
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
		if remaining <= 0 and not purchasePromptOpen then
			closeRevivePanel(true)
		end
	end)
end

local function tryRevivePurchase()
	if not sessionActive or not currentProductId then
		return
	end
	purchasePromptOpen = true
	pcall(function()
		PurchasePrompt.promptProduct(currentProductId)
	end)
end

local function bindRevivePanel(panel: GuiObject)
	if wiredPanel == panel then
		return
	end
	wiredPanel = panel
	revivePanel = panel

	timerLabel = panel:FindFirstChild("Timer", true) :: TextLabel?
	local reviveBtn = panel:FindFirstChild("Revive Button", true)
	local declineBtn = panel:FindFirstChild("Decline Button", true)
	reviveBtnHost = if reviveBtn and reviveBtn:IsA("GuiObject") then reviveBtn else nil
	declineBtnHost = if declineBtn and declineBtn:IsA("GuiObject") then declineBtn else nil

	if reviveBtnHost then
		local nameLabel = reviveBtnHost:FindFirstChild("Name", true)
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

local function resolveRevivePanel(main: ScreenGui): GuiObject?
	local frames = main:FindFirstChild("Frames")
	if not frames then
		warn("[ReviveController] Main.Frames missing")
		return nil
	end
	if frames:IsA("GuiObject") then
		(frames :: GuiObject).Visible = true
	end

	local panel = frames:FindFirstChild(REVIVE_FRAME_NAME)
	if not panel then
		warn("[ReviveController] Revive PopUP not found under Main.Frames")
		return nil
	end
	if not panel:IsA("GuiObject") then
		warn("[ReviveController] Revive PopUP is not a GuiObject:", panel.ClassName)
		return nil
	end

	bindRevivePanel(panel :: GuiObject)
	return panel :: GuiObject
end

local function openRevivePanel(land: number, productId: number, countdownSec: number)
	if sessionActive then
		return
	end
	sessionActive = true

	local main = resolveMainGui()
	if not main then
		warn("[ReviveController] Main ScreenGui missing in PlayerGui")
		sessionActive = false
		return
	end

	local panel = resolveRevivePanel(main)
	if not panel then
		sessionActive = false
		return
	end

	main.Enabled = true
	if main.DisplayOrder < 50 then
		main.DisplayOrder = 50
	end

	local playerGui = main.Parent
	if playerGui then
		local loading = playerGui:FindFirstChild("LoadingScreen")
		if loading and loading:IsA("ScreenGui") then
			loading.Enabled = false
		end
	end

	currentLand = land
	currentProductId = productId

	panel.Visible = true
	panel.ZIndex = math.max(panel.ZIndex, 20)
	if panel:IsA("GuiObject") then
		(panel :: GuiObject).Active = false
	end

	hideGameplayHud(main)
	showReviveBackdrop()
	collectBgmSounds()
	setBgmSlowed(true)
	if not earRingingSound then
		startEarRinging()
	end
	refreshRegionalPrice(productId)
	animatePanelIn(panel)
	startCountdown(countdownSec)
end

local function resolveSoundTemplates()
	local deathFolder = SoundService:FindFirstChild("Death")
	local deathGroup = deathFolder and deathFolder:FindFirstChild("SoundGroup")
	if deathGroup and deathGroup:IsA("SoundGroup") then
		deathSoundGroup = deathGroup
	end
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

local function onLocalDeath(character: Model)
	stopRobloxOofSounds()
	playDeathSfx()
	startEarRinging()

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local land = if hrp then LandResolver.resolveLandAtPosition(hrp.Position) else 1
	local tier = ReviveConfig.tierForLand(land)
	openRevivePanel(tier.land, tier.productId, ReviveConfig.COUNTDOWN_SECONDS)
end

local function hookCharacter(character: Model)
	suppressDefaultDeathSounds(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	end
	if not humanoid then
		return
	end
	humanoid.Died:Connect(function()
		stopRobloxOofSounds()
		task.defer(stopRobloxOofSounds)
		onLocalDeath(character)
	end)
end

local ReviveController = {}

function ReviveController.registerHudRestoredCallback(fn: () -> ())
	table.insert(hudRestoredCallbacks, fn)
end

function ReviveController.init()
	resolveSoundTemplates()

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 60)
	local revivePromptRE = remotes:WaitForChild("RevivePrompt", 30) :: RemoteEvent
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
			if revivePanel then
				revivePanel.Visible = false
			end
			cleanupReviveSession()
		end
	end)

	task.spawn(function()
		local main = resolveMainGui()
		if not main then
			warn("[ReviveController] Could not resolve Main at init")
			return
		end
		local panel = resolveRevivePanel(main)
		if panel then
			panel.Visible = false
		end
	end)

	player.CharacterAdded:Connect(function(character)
		hookCharacter(character)
	end)

	if player.Character then
		hookCharacter(player.Character)
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, wasPurchased: boolean)
		if userId ~= player.UserId then
			return
		end
		if ReviveConfig.isReviveProduct(productId) then
			purchasePromptOpen = false
		end
		if not wasPurchased or not ReviveConfig.isReviveProduct(productId) or not sessionActive then
			return
		end
		-- Server ReviveComplete closes the panel after teleport.
	end)
end

return ReviveController
