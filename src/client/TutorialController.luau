-- [ACTIVE] TutorialController
--[[
	First-join objective HUD: right-side panel, world/UI pointers, step machine.
	Persists completion via PlayerDataService (TutorialCompleted attribute).
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local HUDController = require(script.Parent.HUDController)
local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)
local BushSpiderEncounterController = require(script.Parent.BushSpiderEncounterController)
local CarryGate = require(script.Parent.CarryGate)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local TopNotifController = require(script.Parent.TopNotifController)
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local player = Players.LocalPlayer

local M = {}

local PANEL_OPEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PANEL_SWAP = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXCLAIM_PULSE = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local ARROW_BOB_HZ = 1.15
local ARROW_BOB_AMP = 2.35
local ARROW_SQUASH_AMP = 0.1
local CLICK_BOUNCE = TweenInfo.new(0.38, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local active = false
local stepIndex = 0
local gui: ScreenGui? = nil
local _questRoot: Frame? = nil
local panel: Frame? = nil
local _exclaim: ImageLabel? = nil
local objectiveLabel: TextLabel? = nil
local dotsLabel: TextLabel? = nil
local panelScale: UIScale? = nil
local hudMatchScale: UIScale? = nil
local worldArrowBb: BillboardGui? = nil
local worldArrowImg: ImageLabel? = nil
local arrowAnimConn: RBXScriptConnection? = nil
local worldHighlight: Highlight? = nil
local worldOutlineBox: SelectionBox? = nil
local uiPointer: ImageLabel? = nil
local uiPointerBb: BillboardGui? = nil
local pointerGui: ScreenGui? = nil
local _pointerRoot: Frame? = nil
local uiPointerFollowConn: RBXScriptConnection? = nil
local uiPointerForced = false
local dimOverlay: Frame? = nil
local spotlightHole: Frame? = nil
local heartbeatConn: RBXScriptConnection? = nil
local attrConns: { RBXScriptConnection } = {}
local speakToken = 0
local objectiveBaseText = ""
local dotsConn: RBXScriptConnection? = nil
local dotsPhase = 0
local completeRF: RemoteFunction? = nil
local grantCashRF: RemoteFunction? = nil
local _upgradesFrame: Frame? = nil
local _powerBuyButton: GuiObject? = nil
local lastLandCheck = 0
local _claimSpotlightActive = false
local upgradeBaseLevel = 1
local layoutConn: RBXScriptConnection? = nil
local _panelStroke: UIStroke? = nil
local chromeSuppressed = false
local _questHost: Frame? = nil
local vineCache: { BasePart } = {}
local vineCacheAt = 0
local lastPointerRefresh = 0
local pendingPointerRefresh = false
local grantCashPlayed = false
local pendingCelebrate = false
local finishCelebrated = false

local lockedBushPart: BasePart? = nil
local lockedBushRoot: Instance? = nil
local lockedSwingPart: BasePart? = nil
local uiPointerStroke: UIStroke? = nil
local uiPointerHost: GuiObject? = nil

-- Mid-step confetti disabled — only fire once when the tutorial finishes.
local CELEBRATE_AFTER_STEP: { [string]: boolean } = {}

local clearWorldArrow: () -> ()
local clearUiPointer: () -> ()
local clearSpotlight: () -> ()
local syncPanelToSideButtons: () -> ()
local refreshPointers: () -> ()
local stopObjectiveDots: () -> ()
local startObjectiveDots: (string) -> ()
local completeCurrentIf: (TutorialConfig.StepId) -> ()

local function currentStep(): TutorialConfig.StepDef?
	return TutorialConfig.STEPS[stepIndex]
end

local function isDialogueOrSpiderCutscene(): boolean
	return StandDialogueCutscene.isActive() or BushSpiderEncounterController.isActive()
end

local function isClaimCutscene(): boolean
	return FloatingClaimCutscene.isActive()
end

-- True cutscenes only — NOT GameplayUiVisibility.isHidden() (panels also hide HUD).
local function isCutsceneBusy(): boolean
	return isDialogueOrSpiderCutscene() or isClaimCutscene()
end

local function _shouldHideQuestPanel(): boolean
	return isCutsceneBusy()
end

local function setChromeSuppressed(suppressed: boolean)
	if chromeSuppressed == suppressed then
		return
	end
	chromeSuppressed = suppressed
	if suppressed then
		speakToken += 1
		stopObjectiveDots()
		if clearWorldArrow then
			clearWorldArrow()
		end
		if clearUiPointer then
			clearUiPointer()
		end
		if clearSpotlight then
			clearSpotlight()
		end
		if panel then
			panel.Visible = false
		end
		if gui then
			-- Quest panel lives under Main.TutorialQuestHost (right side).
			gui.Enabled = false
		end
	elseif active then
		if panel then
			panel.Visible = true
		end
		if gui then
			gui.Enabled = true
		end
		pendingPointerRefresh = true
		local step = currentStep()
		local text = if step then step.text elseif objectiveBaseText ~= "" then objectiveBaseText else nil
		if text then
			objectiveBaseText = text
			if objectiveLabel then
				objectiveLabel.Text = text
			end
			startObjectiveDots(text)
		end
	end
end

local function getCompleteRemote(): RemoteFunction?
	if completeRF and completeRF.Parent then
		return completeRF
	end
	local folder = ReplicatedStorage:FindFirstChild("TutorialRemotes")
	local rf = folder and folder:FindFirstChild("CompleteTutorial")
	if rf and rf:IsA("RemoteFunction") then
		completeRF = rf
		return rf
	end
	return nil
end

local function getGrantCashRemote(): RemoteFunction?
	if grantCashRF and grantCashRF.Parent then
		return grantCashRF
	end
	local folder = ReplicatedStorage:FindFirstChild("TutorialRemotes")
	local rf = folder and folder:FindFirstChild("GrantTutorialCash")
	if rf and rf:IsA("RemoteFunction") then
		grantCashRF = rf
		return rf
	end
	return nil
end

local function findCashAmountLabel(): TextLabel?
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main and main:FindFirstChild("SideUI")
	local counters = sideUI and sideUI:FindFirstChild("Counters")
	local cash = counters and counters:FindFirstChild("Cash")
	local amount = cash and cash:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then
		return amount
	end
	return nil
end

local function playStarterCashFx(amount: number)
	local cashLabel = findCashAmountLabel()
	local host: GuiObject? = cashLabel and cashLabel.Parent :: GuiObject?
	if not host then
		local main = PlayerGuiMain.ensure(player)
		host = main
	end
	if not host then
		return
	end

	GameSoundEffects.playCashGrab()

	local popup = Instance.new("TextLabel")
	popup.Name = "TutorialCashPopup"
	popup.BackgroundTransparency = 1
	popup.Size = UDim2.fromOffset(160, 40)
	popup.AnchorPoint = Vector2.new(0.5, 1)
	if cashLabel then
		local mid = cashLabel.AbsolutePosition + cashLabel.AbsoluteSize * 0.5
		local hp = host.AbsolutePosition
		popup.Position = UDim2.fromOffset(mid.X - hp.X, mid.Y - hp.Y - 6)
	else
		popup.Position = UDim2.new(0.5, 0, 0.2, 0)
	end
	popup.Text = ("+$%d"):format(amount)
	popup.TextSize = 28
	popup.Font = Enum.Font.GothamBold
	popup.TextColor3 = Color3.fromRGB(90, 255, 140)
	popup.TextStrokeTransparency = 0.35
	popup.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	popup.ZIndex = 200
	popup.Parent = host

	local scale = Instance.new("UIScale")
	scale.Scale = 0.55
	scale.Parent = popup

	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.15 }):Play()
	TweenService:Create(
		popup,
		TweenInfo.new(1.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Position = popup.Position + UDim2.fromOffset(0, -54),
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}
	):Play()

	if cashLabel then
		local sc = cashLabel:FindFirstChildOfClass("UIScale")
		if not sc then
			sc = Instance.new("UIScale")
			sc.Scale = 1
			sc.Parent = cashLabel
		end
		local base = cashLabel.TextColor3
		cashLabel.TextColor3 = Color3.fromRGB(110, 255, 150)
		sc.Scale = 1.22
		TweenService:Create(sc, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(
			cashLabel,
			TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = base }
		):Play()
	end

	task.delay(1.25, function()
		if popup.Parent then
			popup:Destroy()
		end
	end)
end

local function runGrantCashStep()
	if grantCashPlayed then
		return
	end
	grantCashPlayed = true
	local amount = TutorialConfig.STARTER_CASH
	local rf = getGrantCashRemote()
	if rf then
		local ok, result = pcall(function()
			local grantedOk, grantedAmt = rf:InvokeServer()
			return { ok = grantedOk == true, amount = grantedAmt }
		end)
		if not ok then
			warn("[TutorialController] GrantTutorialCash failed:", result)
		elseif typeof(result) == "table" then
			local pack = result :: { ok: boolean, amount: any }
			if pack.ok and typeof(pack.amount) == "number" and pack.amount > 0 then
				amount = pack.amount
			end
		end
	end
	playStarterCashFx(amount)
	task.wait(1.35)
	if active and currentStep() and currentStep().id == "grantCash" then
		completeCurrentIf("grantCash")
	end
end

local function fireConfettiAndShake()
	GameSoundEffects.playPurchaseShake()
	local essentials = ReplicatedStorage:FindFirstChild("EssentialsShared")
	if not essentials then
		return
	end
	local ok, mod = pcall(require, essentials:FindFirstChild("EffectsController"))
	if not ok or not mod or typeof(mod.celebratePurchase) ~= "function" then
		return
	end
	local celebrateOk, celebrateErr = pcall(function()
		mod.celebratePurchase(player)
	end)
	if not celebrateOk then
		warn("[TutorialController] celebratePurchase failed:", celebrateErr)
	end
end

local function isHudPanelBlocking(): boolean
	local frame = HUDController.getCurrentFrame()
	return frame ~= nil and frame.Parent ~= nil and frame.Visible == true
end

local function isCelebrateBlocked(): boolean
	return isCutsceneBusy() or isHudPanelBlocking()
end

local function tryFlushPendingCelebrate()
	if not pendingCelebrate or not active then
		return
	end
	if isCelebrateBlocked() then
		return
	end
	pendingCelebrate = false
	fireConfettiAndShake()
end

local function requestCelebrate()
	if isCelebrateBlocked() then
		pendingCelebrate = true
		return
	end
	pendingCelebrate = false
	fireConfettiAndShake()
end

local function stopObjectiveDotsImpl()
	if dotsConn then
		dotsConn:Disconnect()
		dotsConn = nil
	end
	dotsPhase = 0
	if dotsLabel then
		dotsLabel.Text = ""
	end
end
stopObjectiveDots = stopObjectiveDotsImpl

local function startObjectiveDotsImpl(baseText: string)
	stopObjectiveDots()
	objectiveBaseText = baseText
	if not objectiveLabel or not active then
		return
	end
	objectiveLabel.Text = baseText
	if dotsLabel then
		dotsLabel.Text = ""
		dotsLabel.Visible = true
	end
	dotsConn = RunService.Heartbeat:Connect(function(dt)
		if not active or chromeSuppressed or not dotsLabel or not dotsLabel.Parent then
			return
		end
		dotsPhase += dt
		local step = math.floor(dotsPhase * 2.2) % 4
		dotsLabel.Text = if step == 0 then "" elseif step == 1 then "." elseif step == 2 then ".." else "..."
	end)
end
startObjectiveDots = startObjectiveDotsImpl

local function typeObjective(displayText: string)
	speakToken += 1
	stopObjectiveDots()
	objectiveBaseText = displayText
	if dotsLabel then
		dotsLabel.Text = ""
	end
	if not active or not objectiveLabel then
		return
	end
	objectiveLabel.Text = displayText
	if not chromeSuppressed then
		startObjectiveDots(displayText)
	end
end

local function viewportSize(): Vector2
	local cam = Workspace.CurrentCamera
	if cam then
		return cam.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function ensureQuestHost(): Frame?
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return nil
	end
	local existing = main:FindFirstChild("TutorialQuestHost")
	if existing and existing:IsA("Frame") then
		_questHost = existing
		return existing
	end
	local host = Instance.new("Frame")
	host.Name = "TutorialQuestHost"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = UDim2.fromScale(1, 1)
	host.Position = UDim2.fromScale(0, 0)
	host.AnchorPoint = Vector2.new(0, 0)
	host.ZIndex = 80
	host.ClipsDescendants = false
	host.Active = false
	host.Parent = main
	_questHost = host
	return host
end

local function isHudPanelOpen(): boolean
	local frame = HUDController.getCurrentFrame()
	return frame ~= nil and frame.Parent ~= nil and frame.Visible == true
end

local function isMobileUi(): boolean
	return UserInputService.TouchEnabled
end

local function resolveRandomBrainrotHud(): GuiObject?
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main and main:FindFirstChild("SideUI")
	local right = sideUI and sideUI:FindFirstChild("Right")
	local rb = right and right:FindFirstChild("RandomBrainrot")
	if not rb then
		return nil
	end
	local activation = rb:FindFirstChild("Activation")
	if activation and activation:IsA("GuiObject") and activation.AbsoluteSize.Y > 0 then
		return activation
	end
	if rb:IsA("GuiObject") and rb.AbsoluteSize.Y > 0 then
		return rb
	end
	return nil
end

local function hostTopInset(host: Frame): number
	local screen = host:FindFirstAncestorOfClass("ScreenGui")
	if screen and screen.IgnoreGuiInset then
		return GuiService:GetGuiInset().Y
	end
	return 0
end

local function syncPanelToSideButtonsImpl()
	if not panel or chromeSuppressed then
		return
	end
	if isHudPanelOpen() then
		panel.Visible = false
		return
	end
	local host = ensureQuestHost()
	if not host then
		return
	end

	if panel.Parent ~= host then
		panel.Parent = host
	end

	local vp = viewportSize()
	local mobile = isMobileUi() or vp.X < 700
	local insetY = hostTopInset(host)
	local rightPad = TutorialConfig.PANEL_RIGHT_PAD
	local topPad = TutorialConfig.PANEL_TOP_PAD + insetY
	local screenW: number
	local matchScale = 1
	local anchorY = 0 -- top of panel

	if mobile then
		local maxW = math.floor(vp.X * TutorialConfig.PANEL_MOBILE_MAX_WIDTH_FRAC)
		screenW = math.clamp(maxW, TutorialConfig.PANEL_MOBILE_MIN_WIDTH, TutorialConfig.PANEL_MOBILE_MAX_WIDTH)
		matchScale = TutorialConfig.PANEL_MOBILE_SCALE
		-- Sit ABOVE RandomBrainrot on the right (not below — that pushed it to the bottom).
		local rb = resolveRandomBrainrotHud()
		if rb then
			local hp = host.AbsolutePosition
			local rbTop = rb.AbsolutePosition.Y - hp.Y
			local hostRight = hp.X + host.AbsoluteSize.X
			local rbRight = rb.AbsolutePosition.X + rb.AbsoluteSize.X
			rightPad = math.max(8, hostRight - rbRight)
			-- Anchor bottom of panel just above RandomBrainrot.
			anchorY = 1
			topPad = math.max(insetY + 10, rbTop - TutorialConfig.PANEL_MOBILE_GAP_ABOVE_RIGHT)
		else
			topPad = insetY + 14
			rightPad = 10
			anchorY = 0
		end
	else
		local maxW = math.floor(vp.X * TutorialConfig.PANEL_MAX_WIDTH_FRAC)
		maxW = math.clamp(maxW, TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_MAX_WIDTH)
		screenW = math.clamp(maxW, TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_MAX_WIDTH)
		matchScale = TutorialConfig.PANEL_PC_SCALE
		topPad = TutorialConfig.PANEL_TOP_PAD + insetY
		rightPad = TutorialConfig.PANEL_RIGHT_PAD
		anchorY = 0
	end

	panel.AnchorPoint = Vector2.new(1, anchorY)
	panel.Size = UDim2.fromOffset(screenW, TutorialConfig.PANEL_HEIGHT)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Position = UDim2.new(1, -rightPad, 0, topPad)
	if hudMatchScale then
		hudMatchScale.Scale = matchScale
	end
	panel.ZIndex = 100
	panel.Visible = active and not chromeSuppressed
end
syncPanelToSideButtons = syncPanelToSideButtonsImpl

local layoutSyncAccum = 0.0
local LAYOUT_SYNC_HZ = 10

local function startLayoutSync()
	if layoutConn then
		layoutConn:Disconnect()
	end
	layoutSyncAccum = 0
	-- Throttled — writing Size/Position every RenderStepped can starve Studio/CorePackages.
	layoutConn = RunService.Heartbeat:Connect(function(dt)
		if not active or chromeSuppressed then
			return
		end
		layoutSyncAccum += dt
		if layoutSyncAccum < (1 / LAYOUT_SYNC_HZ) then
			return
		end
		layoutSyncAccum = 0
		syncPanelToSideButtons()
	end)
end

local function stopLayoutSync()
	if layoutConn then
		layoutConn:Disconnect()
		layoutConn = nil
	end
end

local function clearWorldArrowImpl()
	if arrowAnimConn then
		arrowAnimConn:Disconnect()
		arrowAnimConn = nil
	end
	if worldArrowBb then
		worldArrowBb:Destroy()
		worldArrowBb = nil
		worldArrowImg = nil
	end
end
clearWorldArrow = clearWorldArrowImpl

local function clearWorldHighlight()
	if worldHighlight then
		worldHighlight:Destroy()
		worldHighlight = nil
	end
	if worldOutlineBox then
		worldOutlineBox:Destroy()
		worldOutlineBox = nil
	end
end

local function resolveOutlineFloorPart(root: Instance): BasePart?
	local story1 = PlotPaths.firstStoryFolder(root)
	local floor = story1 and (story1:FindFirstChild("Floor") or story1:FindFirstChild("floor"))
	if floor and floor:IsA("BasePart") then
		return floor
	end
	if floor then
		local part = floor:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
	end
	if root:IsA("BasePart") then
		return root
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function outlineWorld(adornee: Instance?)
	clearWorldHighlight()
	if not adornee or not adornee.Parent then
		return
	end

	-- Full plot models are too large for Highlight (often invisible). Use a thick
	-- SelectionBox on the floor pad instead — same approach as PlotOutlineController.
	local useBox = PlotPaths.isPlotRoot(adornee)
		or (adornee:IsA("Model") and adornee:FindFirstChild("1 Story") ~= nil)
		or (adornee:IsA("Model") and adornee:FindFirstChild("1st Story") ~= nil)

	if useBox then
		local floorPart = resolveOutlineFloorPart(adornee)
		if not floorPart then
			return
		end
		local box = Instance.new("SelectionBox")
		box.Name = "TutorialWorldOutlineBox"
		box.Color3 = Color3.fromRGB(255, 236, 70)
		box.SurfaceColor3 = Color3.fromRGB(255, 236, 70)
		box.SurfaceTransparency = 0.85
		box.LineThickness = 0.18
		box.Transparency = 0.05
		box.Visible = true
		box.Adornee = floorPart
		box.Parent = Workspace.CurrentCamera or adornee
		worldOutlineBox = box
		return
	end

	local hl = Instance.new("Highlight")
	hl.Name = "TutorialWorldOutline"
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0.05
	hl.OutlineColor = Color3.fromRGB(255, 236, 70)
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = adornee
	hl.Parent = Workspace.CurrentCamera or adornee
	worldHighlight = hl
end

local function clearUiPointerImpl()
	if uiPointerFollowConn then
		uiPointerFollowConn:Disconnect()
		uiPointerFollowConn = nil
	end
	if uiPointerStroke then
		uiPointerStroke:Destroy()
		uiPointerStroke = nil
	end
	if uiPointer then
		uiPointer:Destroy()
		uiPointer = nil
	end
	if uiPointerBb then
		uiPointerBb:Destroy()
		uiPointerBb = nil
	end
	uiPointerHost = nil
	uiPointerForced = false
	if pointerGui then
		pointerGui.Enabled = false
	end
end
clearUiPointer = clearUiPointerImpl

local function _ensurePointerGui()
	if pointerGui and pointerGui.Parent then
		return
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		pg = player:WaitForChild("PlayerGui", 10) :: PlayerGui?
	end
	if not pg then
		return
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "TutorialUiPointer"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 130
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "Root"
	rootFrame.BackgroundTransparency = 1
	rootFrame.Size = UDim2.fromScale(1, 1)
	rootFrame.Parent = screen

	screen.Parent = pg
	pointerGui = screen
	_pointerRoot = rootFrame
end

local function isGuiTreeVisible(obj: GuiObject): boolean
	local cur: Instance? = obj
	while cur do
		if cur:IsA("LayerCollector") then
			return (cur :: LayerCollector).Enabled
		end
		if cur:IsA("GuiObject") and not (cur :: GuiObject).Visible then
			return false
		end
		cur = cur.Parent
	end
	return false
end

local function bushHasBrainrotLoot(bush: Instance): boolean
	if bush:GetAttribute("HasHiddenBrainrot") ~= true then
		return false
	end
	if bush:GetAttribute("BushOnCooldown") == true then
		return false
	end
	if bush:GetAttribute("BushLootPhase") == "cooldown" then
		return false
	end
	return true
end

local function clearSpotlightImpl()
	_claimSpotlightActive = false
	if dimOverlay then
		dimOverlay.Visible = false
	end
	if spotlightHole then
		spotlightHole.Visible = false
	end
end
clearSpotlight = clearSpotlightImpl

local function ensureGui()
	if gui and gui.Parent then
		return
	end
	local pg = player:WaitForChild("PlayerGui", 30)
	if not pg then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "TutorialObjective"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 80
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "Root"
	rootFrame.BackgroundTransparency = 1
	rootFrame.Size = UDim2.fromScale(1, 1)
	rootFrame.Parent = screen

	local panelFrame = Instance.new("Frame")
	panelFrame.Name = "ObjectivePanel"
	panelFrame.AnchorPoint = Vector2.new(1, 0)
	panelFrame.Position = UDim2.new(1, -TutorialConfig.PANEL_RIGHT_PAD, 0, TutorialConfig.PANEL_TOP_PAD)
	panelFrame.Size = UDim2.fromOffset(TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_HEIGHT)
	panelFrame.AutomaticSize = Enum.AutomaticSize.Y
	panelFrame.BackgroundColor3 = Color3.fromRGB(22, 26, 34)
	panelFrame.BackgroundTransparency = 0.35
	panelFrame.BorderSizePixel = 0
	panelFrame.ClipsDescendants = false
	panelFrame.Parent = rootFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panelFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.82
	stroke.Parent = panelFrame
	_panelStroke = stroke

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = panelFrame

	local scale = Instance.new("UIScale")
	scale.Name = "ObjectiveScale"
	scale.Scale = 1
	scale.Parent = panelFrame

	local matchScale = Instance.new("UIScale")
	matchScale.Name = "HudMatchScale"
	matchScale.Scale = 1
	matchScale.Parent = panelFrame

	local bang = Instance.new("ImageLabel")
	bang.Name = "Exclaim"
	bang.BackgroundTransparency = 1
	bang.AnchorPoint = Vector2.new(0, 0)
	bang.Position = UDim2.new(0, 6, 0, 4)
	bang.Size = UDim2.fromOffset(36, 36)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.ScaleType = Enum.ScaleType.Fit
	bang.ZIndex = 3
	bang.Parent = panelFrame

	local textRow = Instance.new("Frame")
	textRow.Name = "TextRow"
	textRow.BackgroundTransparency = 1
	textRow.AnchorPoint = Vector2.new(0, 0)
	textRow.Position = UDim2.new(0, 46, 0, 2)
	textRow.Size = UDim2.new(1, -52, 0, 0)
	textRow.AutomaticSize = Enum.AutomaticSize.Y
	textRow.ClipsDescendants = false
	textRow.ZIndex = 3
	textRow.Parent = panelFrame

	local label = Instance.new("TextLabel")
	label.Name = "ObjectiveText"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.new(1, -28, 0, 0)
	label.Position = UDim2.fromOffset(0, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.TextTruncate = Enum.TextTruncate.None
	label.TextSize = 17
	label.TextColor3 = Color3.fromRGB(245, 250, 255)
	label.Text = ""
	label.ZIndex = 3
	label.Parent = textRow
	UiFonts.applyBody(label)
	local boldOk, boldFace = pcall(function()
		return Font.new(label.FontFace.Family, Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	end)
	if boldOk and typeof(boldFace) == "Font" then
		label.FontFace = boldFace
	end
	label.TextStrokeTransparency = 0.25
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)

	local dots = Instance.new("TextLabel")
	dots.Name = "ObjectiveDots"
	dots.BackgroundTransparency = 1
	dots.AnchorPoint = Vector2.new(1, 0)
	dots.Position = UDim2.new(1, 0, 0, 0)
	dots.Size = UDim2.fromOffset(26, 20)
	dots.TextXAlignment = Enum.TextXAlignment.Left
	dots.TextYAlignment = Enum.TextYAlignment.Top
	dots.TextWrapped = false
	dots.TextSize = 17
	dots.TextColor3 = Color3.fromRGB(245, 250, 255)
	dots.Text = ""
	dots.ZIndex = 3
	dots.Parent = textRow
	UiFonts.applyBody(dots)
	if boldOk and typeof(boldFace) == "Font" then
		dots.FontFace = boldFace
	end
	dots.TextStrokeTransparency = 0.25
	dots.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)

	local dim = Instance.new("Frame")
	dim.Name = "ClaimDim"
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Visible = false
	dim.ZIndex = 1
	dim.Active = false
	dim.Parent = rootFrame

	local hole = Instance.new("Frame")
	hole.Name = "SpotlightHole"
	hole.AnchorPoint = Vector2.new(0.5, 0.5)
	hole.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	hole.BackgroundTransparency = 0.55
	hole.BorderSizePixel = 0
	hole.Size = UDim2.fromOffset(120, 56)
	hole.Visible = false
	hole.ZIndex = 2
	hole.Parent = rootFrame
	local holeCorner = Instance.new("UICorner")
	holeCorner.CornerRadius = UDim.new(0, 12)
	holeCorner.Parent = hole
	local holeStroke = Instance.new("UIStroke")
	holeStroke.Color = Color3.fromRGB(8, 10, 14)
	holeStroke.Thickness = 1
	holeStroke.Transparency = 0.7
	holeStroke.Parent = hole

	screen.Parent = pg
	gui = screen
	_questRoot = rootFrame
	panel = panelFrame
	_exclaim = bang
	objectiveLabel = label
	dotsLabel = dots
	panelScale = scale
	hudMatchScale = matchScale
	dimOverlay = dim
	spotlightHole = hole

	-- Parent under Main host so resize stays glued on the right.
	syncPanelToSideButtons()

	task.spawn(function()
		while active and bang.Parent do
			local up = TweenService:Create(bang, EXCLAIM_PULSE, {
				Size = UDim2.fromOffset(40, 40),
				Rotation = -8,
			})
			up:Play()
			up.Completed:Wait()
			if not bang.Parent or not active then
				break
			end
			local down = TweenService:Create(bang, EXCLAIM_PULSE, {
				Size = UDim2.fromOffset(34, 34),
				Rotation = 8,
			})
			down:Play()
			down.Completed:Wait()
		end
		if bang.Parent then
			bang.Rotation = 0
			bang.Size = UDim2.fromOffset(36, 36)
		end
	end)
end

local function showPanel(text: string, animateIn: boolean)
	ensureGui()
	if not gui or not panel or not objectiveLabel or not panelScale then
		return
	end
	objectiveBaseText = text
	if isCutsceneBusy() then
		setChromeSuppressed(true)
		objectiveLabel.Text = text
		return
	end
	setChromeSuppressed(false)
	if gui then
		gui.Enabled = true
	end
	objectiveLabel.Text = ""
	syncPanelToSideButtons()
	if animateIn then
		panelScale.Scale = 0.82
		TweenService:Create(panelScale, PANEL_OPEN, { Scale = 1 }):Play()
	else
		panelScale.Scale = 0.92
		TweenService:Create(panelScale, PANEL_SWAP, { Scale = 1 }):Play()
	end
	typeObjective(text)
end

local function hidePanel()
	if not panel or not panelScale then
		return
	end
	local s = panelScale
	local p = panel
	local g = gui
	TweenService:Create(s, PANEL_SWAP, { Scale = 0.8 }):Play()
	local tw = TweenService:Create(p, PANEL_SWAP, {
		Position = UDim2.new(1, p.Position.X.Offset + 90, 0, p.Position.Y.Offset),
	})
	tw:Play()
	tw.Completed:Once(function()
		if g then
			g.Enabled = false
		end
		if p then
			p.Visible = false
		end
	end)
end

local function arrowHeight(extra: number?): Vector3
	return Vector3.new(0, TutorialConfig.WORLD_ARROW_HEIGHT + (extra or 0), 0)
end

local function pointAtWorld(adornee: Instance?, offset: Vector3?)
	clearWorldArrow()
	if chromeSuppressed or isCutsceneBusy() then
		return
	end
	if not adornee then
		return
	end
	local part: BasePart? = nil
	if adornee:IsA("BasePart") then
		part = adornee
	elseif adornee:IsA("Model") then
		part = adornee.PrimaryPart or adornee:FindFirstChildWhichIsA("BasePart", true)
	end
	if not part then
		return
	end

	local baseOffset = offset or arrowHeight()
	local arrowPx = TutorialConfig.WORLD_ARROW_SIZE
	local bb = Instance.new("BillboardGui")
	bb.Name = "TutorialWorldArrow"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(arrowPx, arrowPx)
	bb.StudsOffset = baseOffset
	bb.MaxDistance = 500
	bb.Adornee = part
	bb.Parent = player:FindFirstChild("PlayerGui") or Workspace.CurrentCamera

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 1)
	img.Position = UDim2.fromScale(0.5, 1)
	img.Size = UDim2.fromScale(1, 1)
	img.Image = TutorialConfig.WORLD_ARROW_IMAGE
	img.Rotation = TutorialConfig.WORLD_ARROW_ROTATION
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = bb

	worldArrowBb = bb
	worldArrowImg = img

	-- Continuous sine bob — no tween loop seams / pause between cycles.
	local phase = 0
	arrowAnimConn = RunService.RenderStepped:Connect(function(dt)
		if worldArrowImg ~= img or not img.Parent or not active or chromeSuppressed then
			return
		end
		phase += dt * ARROW_BOB_HZ * math.pi * 2
		local wave = math.sin(phase)
		-- Soft land bias: spend a bit longer near the bottom without stopping.
		local t = wave * 0.5 + 0.5 -- 0 at bottom of sine trough... actually 0 when sin=-1
		-- Remap so 0 = apex (high), 1 = ground (low), with ease toward ground.
		local ground = t * t
		local y = ARROW_BOB_AMP * (1 - ground)
		bb.StudsOffset = baseOffset + Vector3.new(0, y, 0)
		local wide = 1 + ground * ARROW_SQUASH_AMP
		local tall = 1 - ground * (ARROW_SQUASH_AMP * 0.85)
		img.Size = UDim2.fromScale(wide, tall)
	end)
end

local function pointAtGui(target: GuiObject?, force: boolean?, strokeOnly: boolean?)
	clearUiPointer()
	local allow = force == true or (not chromeSuppressed and not isCutsceneBusy())
	if not allow then
		return
	end
	if not target or not target.Parent then
		return
	end

	uiPointerForced = force == true
	uiPointerHost = target

	-- Prefer the Buy / Upgrade host so stroke + hand sit on the real clickable.
	local attachHost = target
	local buyAncestor = target:FindFirstAncestor("Buy")
	if buyAncestor and buyAncestor:IsA("GuiObject") then
		attachHost = buyAncestor
	elseif target.Name == "Buy" and target:IsA("GuiObject") then
		attachHost = target
	elseif target.Name == "__UpgradeOverlay" then
		-- Brainrot stand: overlay is full-size; outline the Upgrade parent, hand on overlay.
		local upgradeParent = target.Parent
		if upgradeParent and upgradeParent:IsA("GuiObject") then
			attachHost = upgradeParent
		end
	elseif target.Name == "Upgrade" and target:IsA("GuiObject") then
		attachHost = target
	else
		local upgradeAncestor = target:FindFirstAncestor("Upgrade")
		if upgradeAncestor and upgradeAncestor:IsA("GuiObject") then
			attachHost = upgradeAncestor
		end
	end

	local stroke = Instance.new("UIStroke")
	stroke.Name = "TutorialTargetStroke"
	stroke.Color = Color3.fromRGB(255, 236, 70)
	stroke.Thickness = 4.5
	stroke.Transparency = 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = attachHost
	uiPointerStroke = stroke

	if strokeOnly == true then
		return
	end

	local pointer = Instance.new("ImageLabel")
	pointer.Name = "TutorialUiClick"
	pointer.BackgroundTransparency = 1
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Position = UDim2.fromScale(0.5, 0.5)
	pointer.Image = TutorialConfig.UI_CLICK_IMAGE
	pointer.ScaleType = Enum.ScaleType.Fit
	pointer.Active = false

	local underBb = target:FindFirstAncestorOfClass("BillboardGui")
	local underSurface = target:FindFirstAncestorOfClass("SurfaceGui")
	local clickSize = TutorialConfig.UI_CLICK_SIZE
	local clickSizeUp = clickSize + 10
	if underBb or underSurface then
		clickSize = if isMobileUi()
			then TutorialConfig.UI_CLICK_SIZE_SURFACE_MOBILE
			else TutorialConfig.UI_CLICK_SIZE_SURFACE
		clickSizeUp = clickSize + 10
	end
	pointer.Size = UDim2.fromOffset(clickSize, clickSize)

	-- SurfaceGui text (Cost / Level) often paints over in-gui images no matter the ZIndex.
	-- Use an AlwaysOnTop Billboard for stand upgrade so the click hand is never buried.
	if underSurface then
		local adornee: Instance? = underSurface.Adornee
		if not adornee and underSurface.Parent and underSurface.Parent:IsA("BasePart") then
			adornee = underSurface.Parent
		end
		if adornee then
			local bb = Instance.new("BillboardGui")
			bb.Name = "TutorialUiClickBillboard"
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.Size = UDim2.fromOffset(clickSize + 16, clickSize + 16)
			bb.StudsOffset = Vector3.new(0, 0.15, 0)
			bb.MaxDistance = 120
			bb.Adornee = adornee
			local pg = player:FindFirstChildOfClass("PlayerGui")
			bb.Parent = pg or underSurface
			pointer.Size = UDim2.fromScale(1, 1)
			pointer.ZIndex = 10
			pointer.Parent = bb
			uiPointerBb = bb
			uiPointer = pointer
		else
			pointer.ZIndex = 200000
			pointer.Parent = attachHost
			uiPointer = pointer
		end
	else
		local standOverlay = attachHost:FindFirstChild("__UpgradeOverlay")
		if standOverlay and standOverlay:IsA("GuiObject") then
			pointer.ZIndex = 200000
			pointer.Parent = standOverlay
		else
			pointer.ZIndex = math.max(attachHost.ZIndex + 500, 1000)
			pointer.Parent = attachHost
		end
		uiPointer = pointer
	end

	task.spawn(function()
		while uiPointer == pointer and pointer.Parent and active and target.Parent do
			if chromeSuppressed and not uiPointerForced and not isClaimCutscene() then
				break
			end
			local up = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = if uiPointerBb
					then UDim2.fromScale(1.12, 1.12)
					else UDim2.fromOffset(clickSizeUp, clickSizeUp),
				Rotation = -12,
			})
			up:Play()
			up.Completed:Wait()
			if uiPointer ~= pointer then
				break
			end
			local down = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = if uiPointerBb
					then UDim2.fromScale(1, 1)
					else UDim2.fromOffset(clickSize, clickSize),
				Rotation = 8,
			})
			down:Play()
			down.Completed:Wait()
			task.wait(0.04)
		end
	end)
end

local function resolveUpgradeStandModel(): Instance?
	local map = Workspace:FindFirstChild("Map")
	local stands = map and map:FindFirstChild("UIStands")
	return stands and stands:FindFirstChild("Upgrade Stand")
end

local function resolveUpgradeStandPart(): BasePart?
	local upgrade = resolveUpgradeStandModel()
	if not upgrade then
		return nil
	end
	local hitbox = upgrade:FindFirstChild("UpgradePadHitbox")
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox
	end
	return upgrade:FindFirstChildWhichIsA("BasePart", true)
end

local function playerOrigin(): Vector3
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if plot and plot:IsA("Model") then
		local ok, pivot = pcall(function()
			return (plot :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return (pivot :: CFrame).Position
		end
	end
	return Vector3.zero
end

local function land1Aim(): Vector3
	local spawnCf = LandResolver.getSpawnCFrameForLand(1)
	if spawnCf then
		return spawnCf.Position
	end
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	local land1 = lands and lands:FindFirstChild("Land1")
	if land1 and land1:IsA("Model") then
		local ok, pivot = pcall(function()
			return (land1 :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return (pivot :: CFrame).Position
		end
	end
	return Vector3.zero
end

local function refreshVineCache()
	if os.clock() - vineCacheAt < 2.5 and #vineCache > 0 then
		return
	end
	vineCacheAt = os.clock()
	table.clear(vineCache)

	for _, inst in CollectionService:GetTagged("SwingTarget") do
		if inst:IsA("BasePart") and inst.Parent then
			table.insert(vineCache, inst)
		end
	end

	if #vineCache > 0 then
		return
	end

	-- Tags often missing in Studio — fall back to named parts under Map.Vine (capped).
	local map = Workspace:FindFirstChild("Map")
	local vine = map and map:FindFirstChild("Vine")
	if not vine then
		return
	end
	local count = 0
	for _, d in vine:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "SwingTarget" or d.Name == "SwingPart") then
			table.insert(vineCache, d)
			count += 1
			if count >= 100 then
				break
			end
		end
	end
end

local function resolveLand1SwingTarget(): BasePart?
	-- Stick to one middle vine so the arrow doesn't jump between targets.
	if lockedSwingPart and lockedSwingPart.Parent then
		return lockedSwingPart
	end
	lockedSwingPart = nil

	refreshVineCache()
	local origin = playerOrigin()
	local aim = land1Aim()
	local toAim = aim - origin
	local aimDir = if toAim.Magnitude > 1 then toAim.Unit else Vector3.new(0, 0, -1)
	local right = aimDir:Cross(Vector3.yAxis)
	if right.Magnitude < 0.05 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	local best: BasePart? = nil
	local bestScore = math.huge

	for _, part in vineCache do
		if not part.Parent then
			continue
		end
		local offset = part.Position - origin
		local dist = offset.Magnitude
		if dist < 8 or dist > 200 then
			continue
		end
		local along = offset:Dot(aimDir)
		-- Must be ahead toward Land 1.
		if along < 6 then
			continue
		end
		local land = LandResolver.resolveLandAtPosition(part.Position)
		-- Prefer vines still near spawn / between spawn and Land 1 (not already on Land 1 deep).
		local landPenalty = if land == 1 then 55 else 0
		local lateral = math.abs(offset:Dot(right))
		-- Middle vine = low lateral offset from the spawn→Land1 corridor.
		local score = lateral * 2.8 + dist * 0.2 + landPenalty + (part.Position - aim).Magnitude * 0.05
		if score < bestScore then
			bestScore = score
			best = part
		end
	end

	if not best then
		-- Absolute nearest vine as last resort
		bestScore = math.huge
		for _, part in vineCache do
			if part.Parent then
				local dist = (part.Position - origin).Magnitude
				if dist < bestScore then
					bestScore = dist
					best = part
				end
			end
		end
	end

	lockedSwingPart = best
	return best
end

local function clearLockedSwing()
	lockedSwingPart = nil
end

local function resolveNearestBush(): BasePart?
	-- Stick to one bush so the arrow doesn't teleport between targets.
	if lockedBushPart and lockedBushPart.Parent then
		if lockedBushRoot and lockedBushRoot.Parent and bushHasBrainrotLoot(lockedBushRoot) then
			return lockedBushPart
		end
	end
	lockedBushPart = nil
	lockedBushRoot = nil

	local origin = playerOrigin()
	local bestPart: BasePart? = nil
	local bestRoot: Instance? = nil
	local bestScore = math.huge

	local function considerBush(bush: Instance)
		if not bushHasBrainrotLoot(bush) then
			return
		end
		local focus = BushRootUtil.focusWorldPosition(bush)
		if not focus then
			return
		end
		local land = LandResolver.resolveLandAtPosition(focus)
		local dist = (focus - origin).Magnitude
		if dist > 220 then
			return
		end
		local score = dist + (if land == 1 then 0 else 80)
		if score >= bestScore then
			return
		end
		local anchor = BushRootUtil.ensurePromptAnchorPart(bush)
		local part = anchor
		if not part then
			if bush:IsA("BasePart") then
				part = bush
			else
				part = bush:FindFirstChildWhichIsA("BasePart", true)
			end
		end
		if part then
			bestScore = score
			bestPart = part
			bestRoot = bush
		end
	end

	BushHoldInteraction.forEachRegisteredBush(considerBush)

	if not bestPart then
		-- Avoid Map:GetDescendants() (sync timeout). Prefer registered bushes only.
		warn("[TutorialController] No bush in registry for searchBush pointer")
	end

	if bestPart and bestRoot then
		lockedBushPart = bestPart
		lockedBushRoot = bestRoot
	end
	return bestPart
end

local function clearLockedBush()
	lockedBushPart = nil
	lockedBushRoot = nil
end

local function resolvePlayerPlotStand(preferEmpty: boolean?): BasePart?
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return nil
	end
	local emptyPart: BasePart? = nil
	local filledPart: BasePart? = nil
	for _, d in plot:GetDescendants() do
		if d:IsA("Model") and (d:HasTag("BrainrotStand") or d:GetAttribute("BrainrotStand") == true) then
			local ownerId = d:GetAttribute("StandOwnerUserId")
			if ownerId ~= nil and ownerId ~= player.UserId then
				continue
			end
			local part = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart", true)
			if not part then
				continue
			end
			if d:GetAttribute("BrainrotName") == nil then
				if not emptyPart then
					emptyPart = part
				end
			elseif not filledPart then
				filledPart = part
			end
		end
	end
	if preferEmpty == false then
		return filledPart or emptyPart
	end
	return emptyPart or filledPart
end

local function resolvePlayerBaseTarget(): BasePart?
	local stand = resolvePlayerPlotStand(true)
	if stand then
		return stand
	end
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return nil
	end
	local slot = player:GetAttribute("AssignedPlotSlot")
	if typeof(slot) == "number" then
		local folder = PlotPaths.findSpawnAndBasesFolder()
		local pos = folder and folder:FindFirstChild("BasePOSPart" .. tostring(math.floor(slot)))
		if pos and pos:IsA("BasePart") then
			return pos
		end
	end
	if plot:IsA("Model") then
		local ok, pivot = pcall(function()
			return (plot :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			-- Prefer a part near the plot pivot so we never aim at a random far descendant.
			local best: BasePart? = nil
			local bestDist = math.huge
			local origin = (pivot :: CFrame).Position
			for _, d in plot:GetDescendants() do
				if d:IsA("BasePart") then
					local dist = (d.Position - origin).Magnitude
					if dist < bestDist then
						bestDist = dist
						best = d
					end
				end
			end
			if best then
				return best
			end
		end
	end
	return plot:FindFirstChildWhichIsA("BasePart", true)
end

local function isPlayerAtOwnBase(): boolean
	-- Must be near THIS player's plot — shared safezone alone is not enough in multiplayer.
	local origin = playerOrigin()
	local target = resolvePlayerBaseTarget()
	if target and (origin - target.Position).Magnitude <= TutorialConfig.GO_TO_BASE_DIST then
		return true
	end
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return false
	end
	local pivotPos: Vector3? = nil
	if plot:IsA("Model") then
		local ok, pivot = pcall(function()
			return (plot :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			pivotPos = (pivot :: CFrame).Position
		end
	end
	if not pivotPos then
		local part = plot:FindFirstChildWhichIsA("BasePart", true)
		pivotPos = if part then part.Position else nil
	end
	if not pivotPos then
		return false
	end
	local char = player.Character
	if not (char and SafezoneUtil.isCharacterInSafezone(char)) then
		return false
	end
	return (origin - pivotPos).Magnitude <= TutorialConfig.GO_TO_BASE_DIST * 1.35
end

local function resolvePlacedStandUpgradeTarget(): Instance?
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return nil
	end
	for _, d in plot:GetDescendants() do
		if d:IsA("Model") and (d:HasTag("BrainrotStand") or d:GetAttribute("BrainrotStand") == true) then
			local ownerId = d:GetAttribute("StandOwnerUserId")
			if ownerId ~= nil and ownerId ~= player.UserId then
				continue
			end
			if typeof(d:GetAttribute("BrainrotName")) ~= "string" then
				continue
			end
			local levelPanel = d:FindFirstChild("LevelPanel")
			local level = levelPanel and levelPanel:FindFirstChild("Level")
			if level and level:IsA("BasePart") then
				return level
			end
			if levelPanel and levelPanel:IsA("BasePart") then
				return levelPanel
			end
			return d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart", true)
		end
	end
	return nil
end

local function resolveStandUpgradeButton(): GuiObject?
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return nil
	end
	for _, d in plot:GetDescendants() do
		if not d:IsA("Model") then
			continue
		end
		if not (d:HasTag("BrainrotStand") or d:GetAttribute("BrainrotStand") == true) then
			continue
		end
		local ownerId = d:GetAttribute("StandOwnerUserId")
		if ownerId ~= nil and ownerId ~= player.UserId then
			continue
		end
		if typeof(d:GetAttribute("BrainrotName")) ~= "string" then
			continue
		end
		local levelPanel = d:FindFirstChild("LevelPanel")
		local level = levelPanel and levelPanel:FindFirstChild("Level")
		local sg = level and level:FindFirstChild("SurfaceGui")
		local frame = sg and sg:FindFirstChild("Frame")
		local upgrade = frame and frame:FindFirstChild("Upgrade")
		if not upgrade or not upgrade:IsA("GuiObject") then
			continue
		end
		-- Prefer the Upgrade frame so outline wraps the whole button; click hand
		-- is parented above __UpgradeOverlay inside pointAtGui.
		return upgrade :: GuiObject
	end
	return nil
end

local function readPlacedBrainrotLevel(): number
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return 1
	end
	for _, d in plot:GetDescendants() do
		if d:IsA("Model") and (d:HasTag("BrainrotStand") or d:GetAttribute("BrainrotStand") == true) then
			local ownerId = d:GetAttribute("StandOwnerUserId")
			if ownerId ~= nil and ownerId ~= player.UserId then
				continue
			end
			if typeof(d:GetAttribute("BrainrotName")) == "string" then
				local lvl = d:GetAttribute("BrainrotLevel")
				if typeof(lvl) == "number" then
					return math.max(1, math.floor(lvl))
				end
				return 1
			end
		end
	end
	return 1
end

local function isDisallowedTutorialButton(obj: Instance): boolean
	local cur: Instance? = obj
	while cur do
		local name = string.lower(cur.Name)
		if name == "close" or name == "x" or name == "buyrobux" or name == "skip" then
			return true
		end
		if name == "buybuttons" or name == "power10" or name == "container" then
			break
		end
		cur = cur.Parent
	end
	return false
end

local function cacheUpgradesBuyButton()
	_powerBuyButton = nil
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return nil
	end
	local frames = main:FindFirstChild("Frames")
	local upgrades = frames and frames:FindFirstChild("Upgrades")
	if upgrades and upgrades:IsA("Frame") then
		_upgradesFrame = upgrades
	end
	if not upgrades then
		return nil
	end
	local container = upgrades:FindFirstChild("Container") or upgrades:FindFirstChild("Container", true)
	local row = (container and container:FindFirstChild("Power10")) or upgrades:FindFirstChild("Power10", true)
	if not row and container then
		for _, ch in container:GetChildren() do
			if typeof(ch.Name) == "string" and string.find(string.lower(ch.Name), "power", 1, true) then
				row = ch
				break
			end
		end
	end
	if not row then
		return nil
	end
	local buyButtons = row:FindFirstChild("BuyButtons") or row:FindFirstChild("BuyButtons", true)
	if not buyButtons then
		return nil
	end
	-- Cash buy only (never BuyRobux / Close).
	local buy = buyButtons:FindFirstChild("Buy")
	if not buy then
		return nil
	end

	local btn: GuiObject? = nil
	if buy:IsA("GuiButton") and not isDisallowedTutorialButton(buy) then
		btn = buy
	else
		local best: GuiButton? = nil
		local bestScore = -1
		for _, d in buy:GetDescendants() do
			if d:IsA("GuiButton") and not isDisallowedTutorialButton(d) then
				local underDecor = false
				local p: Instance? = d.Parent
				while p and p ~= buy do
					if p.Name == "Decor" then
						underDecor = true
						break
					end
					p = p.Parent
				end
				if not underDecor then
					local area = math.max(d.AbsoluteSize.X * d.AbsoluteSize.Y, 1)
					local score = area + (if d:IsA("ImageButton") or d:IsA("TextButton") then 1e6 else 0)
					if score > bestScore then
						bestScore = score
						best = d
					end
				end
			end
		end
		btn = best
		if not btn and buy:IsA("GuiObject") then
			btn = buy
		end
	end
	if btn and btn:IsA("GuiObject") and not isDisallowedTutorialButton(btn) then
		_powerBuyButton = btn
		return btn
	end
	return nil
end

local function refreshPointersImpl()
	if not active then
		return
	end
	local step = currentStep()
	if not step then
		return
	end

	-- Claim step: outline + click the Accept icon (cutscene suppresses normal pointers).
	if step.id == "claimBrainrot" or isClaimCutscene() then
		clearWorldArrow()
		clearWorldHighlight()
		clearSpotlight()
		local offer = BushFloatingClaimController.getActiveOfferUi()
		if offer and offer.acceptBtn then
			if uiPointerHost ~= offer.acceptBtn or not uiPointer or not uiPointer.Parent then
				pointAtGui(offer.acceptBtn, true)
			end
		else
			clearUiPointer()
		end
		return
	end

	-- Upgrade stand dialogue: outline the Enter/Upgrade choice button.
	if step.id == "visitUpgrade" and StandDialogueCutscene.isActive() then
		local enterBtn = StandDialogueCutscene.getEnterChoiceButton()
		if enterBtn then
			clearWorldArrow()
			outlineWorld(resolveUpgradeStandModel())
			if uiPointerHost ~= enterBtn or not uiPointer or not uiPointer.Parent then
				pointAtGui(enterBtn, true)
			end
			return
		end
	end

	if chromeSuppressed or isCutsceneBusy() then
		return
	end

	-- Keep existing world arrow if still valid for locked bush / same step.
	local keepWorld = false
	if step.id == "searchBush" and worldArrowBb and lockedBushPart and lockedBushPart.Parent then
		if lockedBushRoot and lockedBushRoot.Parent and bushHasBrainrotLoot(lockedBushRoot) then
			keepWorld = true
		else
			clearLockedBush()
			clearWorldArrow()
		end
	end

	if not keepWorld then
		clearWorldArrow()
	end
	clearUiPointer()
	clearSpotlight()
	clearWorldHighlight()

	if step.id == "visitUpgrade" then
		outlineWorld(resolveUpgradeStandModel())
		pointAtWorld(resolveUpgradeStandPart(), arrowHeight(4))
	elseif step.id == "buyPower" then
		local btn = cacheUpgradesBuyButton()
		if btn and isGuiTreeVisible(btn) then
			pointAtGui(btn)
			task.defer(function()
				task.wait(0.2)
				if not active or chromeSuppressed or isCutsceneBusy() then
					return
				end
				local cur = currentStep()
				if cur and cur.id == "buyPower" and not uiPointer then
					local again = cacheUpgradesBuyButton()
					if again and isGuiTreeVisible(again) then
						pointAtGui(again)
					end
				end
			end)
		else
			outlineWorld(resolveUpgradeStandModel())
			pointAtWorld(resolveUpgradeStandPart(), arrowHeight(4))
		end
	elseif step.id == "swingLand1" then
		if not (lockedSwingPart and lockedSwingPart.Parent and worldArrowBb) then
			pointAtWorld(resolveLand1SwingTarget(), arrowHeight(3))
		end
		if lockedSwingPart then
			outlineWorld(lockedSwingPart)
		end
	elseif step.id == "searchBush" then
		if not keepWorld then
			pointAtWorld(resolveNearestBush(), arrowHeight(2))
		end
		local bushAdornee = lockedBushRoot or lockedBushPart
		if bushAdornee then
			outlineWorld(bushAdornee)
		end
	elseif step.id == "goToBase" then
		clearLockedBush()
		pointAtWorld(resolvePlayerBaseTarget(), arrowHeight(4))
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot then
			outlineWorld(plot)
		end
	elseif step.id == "placeOnPlot" then
		clearLockedBush()
		pointAtWorld(resolvePlayerPlotStand(true), arrowHeight(3))
		local plot = PlotPaths.findPlotForAssignedSlot(player)
		if plot then
			outlineWorld(plot)
		end
	elseif step.id == "upgradeBrainrot" then
		pointAtWorld(resolvePlacedStandUpgradeTarget(), arrowHeight(4))
		local upgradeBtn = resolveStandUpgradeButton()
		if upgradeBtn then
			pointAtGui(upgradeBtn)
		end
	end
end
refreshPointers = refreshPointersImpl

local function finishTutorial()
	if not active then
		return
	end
	active = false
	pendingCelebrate = false
	speakToken += 1
	stopObjectiveDots()
	clearWorldArrow()
	clearWorldHighlight()
	clearUiPointer()
	clearSpotlight()
	stopLayoutSync()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	for _, conn in attrConns do
		conn:Disconnect()
	end
	table.clear(attrConns)
	hidePanel()
	if not finishCelebrated then
		finishCelebrated = true
		fireConfettiAndShake()
	end
	task.defer(function()
		TopNotifController.showBroadcast("Tutorial completed!")
	end)
	local rf = getCompleteRemote()
	if rf then
		task.spawn(function()
			local ok, err = pcall(function()
				rf:InvokeServer()
			end)
			if not ok then
				warn("[TutorialController] CompleteTutorial failed:", err)
			end
		end)
	else
		player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, true)
	end
end

local function stepIndexById(id: TutorialConfig.StepId): number?
	for i, step in TutorialConfig.STEPS do
		if step.id == id then
			return i
		end
	end
	return nil
end

local function advanceTo(index: number, opts: { celebrate: boolean? }?)
	if not active then
		return
	end
	if index > #TutorialConfig.STEPS then
		finishTutorial()
		return
	end
	local first = stepIndex == 0
	stepIndex = index
	local step = TutorialConfig.STEPS[stepIndex]
	if not step then
		finishTutorial()
		return
	end
	if step.id == "upgradeBrainrot" then
		upgradeBaseLevel = readPlacedBrainrotLevel()
	end
	if step.id == "searchBush" then
		clearLockedBush()
		clearLockedSwing()
	elseif step.id == "swingLand1" then
		clearLockedSwing()
	elseif step.id ~= "claimBrainrot" then
		clearLockedBush()
	end
	showPanel(step.text, first)
	refreshPointers()
	if step.id == "grantCash" then
		task.spawn(function()
			runGrantCashStep()
		end)
	end
end

local function completeCurrentIfImpl(id: TutorialConfig.StepId)
	local step = currentStep()
	if not step or step.id ~= id then
		return
	end
	advanceTo(stepIndex + 1)
end
completeCurrentIf = completeCurrentIfImpl

local function goToStep(id: TutorialConfig.StepId, celebrate: boolean?)
	local index = stepIndexById(id)
	if not index then
		return
	end
	advanceTo(index, { celebrate = celebrate == true })
end

local function watchStepProgress()
	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not active then
			return
		end

		local busy = isCutsceneBusy()
		if busy then
			setChromeSuppressed(true)
			-- Still advance bush/claim steps while claim cutscene hides the quest bar.
			local stepBusy = currentStep()
			if stepBusy then
				if stepBusy.id == "searchBush" then
					if BushFloatingClaimController.getActiveOfferUi() or CarryGate.isCarrying() then
						completeCurrentIf("searchBush")
					end
				elseif stepBusy.id == "claimBrainrot" then
					refreshPointers()
					if CarryGate.isCarryingOnHead() then
						completeCurrentIf("claimBrainrot")
					end
				elseif stepBusy.id == "visitUpgrade" then
					-- Outline Upgrade choice when dialogue buttons appear.
					refreshPointers()
				end
			end
			return
		elseif chromeSuppressed or pendingPointerRefresh then
			setChromeSuppressed(false)
			pendingPointerRefresh = false
			if gui and panel then
				gui.Enabled = true
				syncPanelToSideButtons()
			end
			refreshPointers()
			tryFlushPendingCelebrate()
		elseif pendingCelebrate then
			tryFlushPendingCelebrate()
		end

		local step = currentStep()
		if not step then
			return
		end
		local now = os.clock()

		-- Periodically re-aim world arrows only when missing (don't retarget bushes).
		if now - lastPointerRefresh > 1.25 then
			lastPointerRefresh = now
			if step.id == "swingLand1" or step.id == "visitUpgrade" or step.id == "placeOnPlot" or step.id == "goToBase" then
				if not worldArrowBb and not uiPointer then
					refreshPointers()
				end
			elseif step.id == "upgradeBrainrot" then
				if not worldArrowBb or not uiPointer then
					refreshPointers()
				end
			elseif step.id == "searchBush" then
				if lockedBushRoot and not bushHasBrainrotLoot(lockedBushRoot) then
					clearLockedBush()
					clearWorldArrow()
				end
				if not worldArrowBb then
					refreshPointers()
				end
			elseif step.id == "buyPower" then
				local btn = cacheUpgradesBuyButton()
				if btn and isGuiTreeVisible(btn) and not uiPointerStroke then
					refreshPointers()
				end
			end
		end

		if step.id == "buyPower" then
			local btn = cacheUpgradesBuyButton()
			if btn and isGuiTreeVisible(btn) then
				if not uiPointer or uiPointerHost ~= btn then
					clearWorldArrow()
					pointAtGui(btn)
				end
			elseif not worldArrowBb then
				pointAtWorld(resolveUpgradeStandPart(), arrowHeight(4))
			end
		elseif step.id == "swingLand1" and now - lastLandCheck > 0.35 then
			lastLandCheck = now
			if not worldArrowBb then
				refreshPointers()
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local land = LandResolver.resolveLandAtPosition(hrp.Position)
				if land == 1 then
					clearLockedSwing()
					completeCurrentIf("swingLand1")
				end
			end
		elseif step.id == "searchBush" and now - lastLandCheck > 0.5 then
			lastLandCheck = now
			if BushFloatingClaimController.getActiveOfferUi() or CarryGate.isCarrying() then
				completeCurrentIf("searchBush")
				return
			end
			if lockedBushRoot and not bushHasBrainrotLoot(lockedBushRoot) then
				clearLockedBush()
				clearWorldArrow()
			end
			if not worldArrowBb then
				refreshPointers()
			end
		elseif step.id == "claimBrainrot" and now - lastLandCheck > 0.35 then
			lastLandCheck = now
			if CarryGate.isCarryingOnHead() then
				completeCurrentIf("claimBrainrot")
			end
		elseif step.id == "goToBase" and now - lastLandCheck > 0.35 then
			lastLandCheck = now
			if isPlayerAtOwnBase() then
				completeCurrentIf("goToBase")
			elseif not worldArrowBb then
				refreshPointers()
			end
		elseif step.id == "placeOnPlot" and now - lastLandCheck > 0.4 then
			lastLandCheck = now
			local plot = PlotPaths.findPlotForAssignedSlot(player)
			if plot then
				for _, d in plot:GetDescendants() do
					if d:IsA("Model") and typeof(d:GetAttribute("BrainrotName")) == "string" then
						local ownerId = d:GetAttribute("StandOwnerUserId")
						if ownerId == nil or ownerId == player.UserId then
							completeCurrentIf("placeOnPlot")
							return
						end
					end
				end
			end
		elseif step.id == "upgradeBrainrot" and now - lastLandCheck > 0.35 then
			lastLandCheck = now
			local lvl = readPlacedBrainrotLevel()
			if lvl > upgradeBaseLevel then
				completeCurrentIf("upgradeBrainrot")
			else
				local upgradeBtn = resolveStandUpgradeButton()
				if upgradeBtn and (not uiPointer or not uiPointer.Parent) then
					pointAtGui(upgradeBtn)
				elseif not worldArrowBb then
					refreshPointers()
				end
			end
		end
	end)
end

local function bindGameplayHooks()
	for _, conn in attrConns do
		conn:Disconnect()
	end
	table.clear(attrConns)

	table.insert(
		attrConns,
		player:GetAttributeChangedSignal(SwingUpgrades.POWER_LEVEL_ATTR):Connect(function()
			local lvl = player:GetAttribute(SwingUpgrades.POWER_LEVEL_ATTR)
			if typeof(lvl) == "number" and lvl > 0 then
				completeCurrentIf("buyPower")
			end
		end)
	)

	-- Plot slot can assign after tutorial starts — retarget arrows to YOUR Plot_N.
	table.insert(
		attrConns,
		player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
			local step = currentStep()
			if not step then
				return
			end
			if step.id == "goToBase" or step.id == "placeOnPlot" or step.id == "upgradeBrainrot" then
				refreshPointers()
			end
		end)
	)

	local main = PlayerGuiMain.ensure(player)
	if main then
		local frames = main:FindFirstChild("Frames")
		local upgrades = frames and frames:FindFirstChild("Upgrades")
		if upgrades and upgrades:IsA("GuiObject") then
			_upgradesFrame = upgrades :: Frame
			table.insert(
				attrConns,
				upgrades:GetPropertyChangedSignal("Visible"):Connect(function()
					if upgrades.Visible then
						completeCurrentIf("visitUpgrade")
						task.defer(function()
							task.wait(0.2)
							if currentStep() and currentStep().id == "buyPower" then
								refreshPointers()
							end
						end)
					end
				end)
			)
		end
	end

	-- Pad visit fallback if dialogue is skipped
	task.spawn(function()
		local pad = resolveUpgradeStandPart()
		if not pad then
			return
		end
		while active do
			local step = currentStep()
			if step and step.id == "visitUpgrade" then
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					local localPt = pad.CFrame:PointToObjectSpace(hrp.Position)
					local half = pad.Size * 0.5 + Vector3.new(2, 4, 2)
					if math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z then
						completeCurrentIf("visitUpgrade")
					end
				end
			end
			task.wait(0.25)
		end
	end)
end

function M.start(force: boolean?)
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true and not force then
		return
	end
	if active then
		return
	end
	active = true
	stepIndex = 0
	grantCashPlayed = false
	pendingCelebrate = false
	finishCelebrated = false
	ensureGui()
	startLayoutSync()
	bindGameplayHooks()
	watchStepProgress()
	advanceTo(1)
end

function M.stop()
	if not active then
		return
	end
	active = false
	pendingCelebrate = false
	speakToken += 1
	stopObjectiveDots()
	clearWorldArrow()
	clearWorldHighlight()
	clearUiPointer()
	clearSpotlight()
	stopLayoutSync()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	for _, conn in attrConns do
		conn:Disconnect()
	end
	table.clear(attrConns)
	hidePanel()
end

function M.init()
	local hooksBound = false
	local function bindOfferHooksOnce()
		if hooksBound then
			return
		end
		hooksBound = true
		BushFloatingClaimController.registerOfferHook(function(_model, ui)
			completeCurrentIf("searchBush")
			-- Claim cutscene owns the quest chrome; still point at Accept.
			setChromeSuppressed(true)
			task.defer(function()
				local step = currentStep()
				if not active then
					return
				end
				if step and step.id == "claimBrainrot" and ui and ui.acceptBtn then
					pointAtGui(ui.acceptBtn, true)
				end
			end)
		end)
		BushFloatingClaimController.registerAcceptHook(function(_model)
			completeCurrentIf("searchBush")
			completeCurrentIf("claimBrainrot")
		end)
		BushFloatingClaimController.registerDeclineHook(function(_model)
			local step = currentStep()
			if step and step.id == "claimBrainrot" then
				clearSpotlight()
				clearUiPointer()
				clearLockedBush()
				goToStep("searchBush", false)
			end
		end)
	end

	task.spawn(function()
		while player.Parent and player:GetAttribute(PlayerDataSchema.LOADED_ATTR) ~= true do
			player:GetAttributeChangedSignal(PlayerDataSchema.LOADED_ATTR):Wait()
		end
		if not player.Parent then
			return
		end

		task.wait(1.25)
		bindOfferHooksOnce()

		GameplayUiVisibility.onRestored(function()
			if not active then
				return
			end
			pendingPointerRefresh = true
			tryFlushPendingCelebrate()
		end)

		player:GetAttributeChangedSignal(PlayerDataSchema.TUTORIAL_REPLAY_ATTR):Connect(function()
			M.stop()
			task.wait(0.15)
			M.start(true)
		end)

		if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
			M.start(false)
		end
	end)
end

return M
