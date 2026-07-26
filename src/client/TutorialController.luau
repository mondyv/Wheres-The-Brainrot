-- [ACTIVE] TutorialController
--[[
	First-join objective HUD: left-side panel, world/UI pointers, step machine.
	Persists completion via PlayerDataService (TutorialCompleted attribute).
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
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
local root: Frame? = nil
local panel: Frame? = nil
local exclaim: ImageLabel? = nil
local objectiveLabel: TextLabel? = nil
local dotsLabel: TextLabel? = nil
local panelScale: UIScale? = nil
local worldArrowBb: BillboardGui? = nil
local worldArrowImg: ImageLabel? = nil
local arrowAnimConn: RBXScriptConnection? = nil
local uiPointer: ImageLabel? = nil
local pointerGui: ScreenGui? = nil
local pointerRoot: Frame? = nil
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
local upgradesFrame: Frame? = nil
local powerBuyButton: GuiObject? = nil
local lastLandCheck = 0
local claimSpotlightActive = false
local upgradeBaseLevel = 1
local layoutConn: RBXScriptConnection? = nil
local panelStroke: UIStroke? = nil
local chromeSuppressed = false
local vineCache: { BasePart } = {}
local vineCacheAt = 0
local lastPointerRefresh = 0
local pendingPointerRefresh = false

local lockedBushPart: BasePart? = nil
local lockedBushRoot: Instance? = nil
local uiPointerStroke: UIStroke? = nil
local uiPointerHost: GuiObject? = nil

local clearWorldArrow: () -> ()
local clearUiPointer: () -> ()
local clearSpotlight: () -> ()
local syncPanelToSideButtons: () -> ()
local refreshPointers: () -> ()
local stopObjectiveDots: () -> ()
local startObjectiveDots: (string) -> ()

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

local function shouldHideQuestPanel(): boolean
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
			-- Quest panel stays on TutorialObjective ScreenGui (synced above Lef1).
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

local function resolveSideButtonPanel(): GuiObject?
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main and main:FindFirstChild("SideUI")
	if not sideUI then
		return nil
	end
	local lef1 = sideUI:FindFirstChild("Lef1") or sideUI:FindFirstChild("Left1")
	if lef1 and lef1:IsA("GuiObject") then
		return lef1
	end
	return nil
end

local function syncPanelToSideButtonsImpl()
	if not panel or not root or chromeSuppressed then
		return
	end
	local lef1 = resolveSideButtonPanel()
	if not lef1 then
		return
	end

	if panel.Parent ~= root then
		panel.Parent = root
	end
	if gui then
		gui.Enabled = true
	end

	local gap = TutorialConfig.PANEL_GAP_ABOVE_SIDE
	local height = TutorialConfig.PANEL_HEIGHT
	local leftPad = TutorialConfig.PANEL_LEFT_PAD
	local ap = lef1.AbsolutePosition

	-- Use the highest visible chrome under Lef1 (icons / NEW badges) as the top edge.
	local topY = ap.Y
	local function consider(obj: GuiObject)
		if not obj.Visible or obj.AbsoluteSize.X < 2 or obj.AbsoluteSize.Y < 2 then
			return
		end
		topY = math.min(topY, obj.AbsolutePosition.Y)
	end
	consider(lef1)
	for _, d in lef1:GetDescendants() do
		if d:IsA("GuiObject") then
			consider(d)
		end
	end

	local textW = 0
	if objectiveLabel and objectiveLabel.Text ~= "" then
		textW = objectiveLabel.TextBounds.X
	end
	-- bang + text + dots reserve + horizontal padding
	local contentW = 54 + textW + 40 + 28
	local width = math.max(TutorialConfig.PANEL_MIN_WIDTH, contentW)

	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Size = UDim2.fromOffset(width, height)
	panel.Position = UDim2.fromOffset(ap.X + leftPad, topY - gap)
	panel.ZIndex = 50
	panel.Visible = active and not chromeSuppressed
end
syncPanelToSideButtons = syncPanelToSideButtonsImpl

local function startLayoutSync()
	if layoutConn then
		layoutConn:Disconnect()
	end
	layoutConn = RunService.RenderStepped:Connect(function()
		if not active or chromeSuppressed then
			return
		end
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
	uiPointerHost = nil
	uiPointerForced = false
	if pointerGui then
		pointerGui.Enabled = false
	end
end
clearUiPointer = clearUiPointerImpl

local function ensurePointerGui()
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
	pointerRoot = rootFrame
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
	claimSpotlightActive = false
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
	panelFrame.AnchorPoint = Vector2.new(0, 1)
	panelFrame.Position = UDim2.new(0, 18, 0, 200)
	panelFrame.Size = UDim2.fromOffset(TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_HEIGHT)
	panelFrame.BackgroundColor3 = Color3.fromRGB(36, 40, 52)
	panelFrame.BackgroundTransparency = 0.22
	panelFrame.BorderSizePixel = 0
	panelFrame.ClipsDescendants = false
	panelFrame.Parent = rootFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panelFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(12, 14, 18)
	stroke.Thickness = 1.6
	stroke.Transparency = 0.35
	stroke.Parent = panelFrame
	panelStroke = stroke

	local blurFake = Instance.new("Frame")
	blurFake.Name = "PanelSheen"
	blurFake.BackgroundColor3 = Color3.fromRGB(48, 54, 68)
	blurFake.BackgroundTransparency = 0.55
	blurFake.BorderSizePixel = 0
	blurFake.Size = UDim2.fromScale(1, 1)
	blurFake.ZIndex = 1
	blurFake.Parent = panelFrame
	local sheenCorner = Instance.new("UICorner")
	sheenCorner.CornerRadius = UDim.new(0, 12)
	sheenCorner.Parent = blurFake

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panelFrame

	local scale = Instance.new("UIScale")
	scale.Name = "ObjectiveScale"
	scale.Scale = 0.86
	scale.Parent = panelFrame

	local bang = Instance.new("ImageLabel")
	bang.Name = "Exclaim"
	bang.BackgroundTransparency = 1
	bang.AnchorPoint = Vector2.new(0, 0.5)
	bang.Position = UDim2.new(0, 10, 0.5, 0)
	bang.Size = UDim2.fromOffset(40, 40)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.ScaleType = Enum.ScaleType.Fit
	bang.ZIndex = 3
	bang.Parent = panelFrame

	local textRow = Instance.new("Frame")
	textRow.Name = "TextRow"
	textRow.BackgroundTransparency = 1
	textRow.AnchorPoint = Vector2.new(0, 0.5)
	textRow.Position = UDim2.new(0, 54, 0.5, 0)
	textRow.Size = UDim2.new(1, -64, 1, -10)
	textRow.ClipsDescendants = false
	textRow.ZIndex = 3
	textRow.Parent = panelFrame

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 0)
	rowLayout.Parent = textRow

	local label = Instance.new("TextLabel")
	label.Name = "ObjectiveText"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.new(0, 0, 1, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.None
	label.TextSize = 15
	label.TextColor3 = Color3.fromRGB(245, 250, 255)
	label.Text = ""
	label.LayoutOrder = 1
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
	dots.Size = UDim2.fromOffset(34, 40)
	dots.TextXAlignment = Enum.TextXAlignment.Left
	dots.TextYAlignment = Enum.TextYAlignment.Center
	dots.TextWrapped = false
	dots.TextSize = 15
	dots.TextColor3 = Color3.fromRGB(245, 250, 255)
	dots.Text = ""
	dots.LayoutOrder = 2
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
	root = rootFrame
	panel = panelFrame
	exclaim = bang
	objectiveLabel = label
	dotsLabel = dots
	panelScale = scale
	dimOverlay = dim
	spotlightHole = hole

	-- Move onto SideUI immediately so resize stays correct.
	syncPanelToSideButtons()

	task.spawn(function()
		while active and bang.Parent do
			local up = TweenService:Create(bang, EXCLAIM_PULSE, {
				Size = UDim2.fromOffset(48, 48),
				Rotation = -8,
			})
			up:Play()
			up.Completed:Wait()
			if not bang.Parent or not active then
				break
			end
			local down = TweenService:Create(bang, EXCLAIM_PULSE, {
				Size = UDim2.fromOffset(42, 42),
				Rotation = 8,
			})
			down:Play()
			down.Completed:Wait()
		end
		if bang.Parent then
			bang.Rotation = 0
			bang.Size = UDim2.fromOffset(42, 42)
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
	gui.Enabled = true
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
	if not gui or not panel or not panelScale then
		return
	end
	local s = panelScale
	local p = panel
	local g = gui
	local pos = p.Position
	TweenService:Create(s, PANEL_SWAP, { Scale = 0.8 }):Play()
	local tw = TweenService:Create(p, PANEL_SWAP, {
		Position = UDim2.fromOffset(pos.X.Offset - 80, pos.Y.Offset),
	})
	tw:Play()
	tw.Completed:Once(function()
		if g then
			g.Enabled = false
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
	local bb = Instance.new("BillboardGui")
	bb.Name = "TutorialWorldArrow"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(78, 78)
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

local function pointAtGui(target: GuiObject?, force: boolean?)
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

	-- Prefer the cash Buy chip so stroke/hand sit on the green $ button, not a tiny child.
	local attachHost = target
	local buyAncestor = target:FindFirstAncestor("Buy")
	if buyAncestor and buyAncestor:IsA("GuiObject") then
		attachHost = buyAncestor
	elseif target.Name == "Buy" and target:IsA("GuiObject") then
		attachHost = target
	end

	local stroke = Instance.new("UIStroke")
	stroke.Name = "TutorialTargetStroke"
	stroke.Color = Color3.fromRGB(255, 230, 90)
	stroke.Thickness = 2.6
	stroke.Transparency = 0.1
	stroke.Parent = attachHost
	uiPointerStroke = stroke

	local pointer = Instance.new("ImageLabel")
	pointer.Name = "TutorialUiClick"
	pointer.BackgroundTransparency = 1
	pointer.Size = UDim2.fromOffset(46, 46)
	pointer.AnchorPoint = Vector2.new(0.2, 0.15)
	pointer.Image = TutorialConfig.UI_CLICK_IMAGE
	pointer.ScaleType = Enum.ScaleType.Fit
	pointer.Active = false
	pointer.ZIndex = math.max(attachHost.ZIndex + 40, 80)

	local underBb = target:FindFirstAncestorOfClass("BillboardGui")
	if underBb then
		pointer.Position = UDim2.new(0.55, 0, 0.55, 0)
		pointer.Parent = target
	else
		-- Fingertip on lower-right of the buy chip (price text stays readable).
		pointer.Position = UDim2.new(1, -8, 1, -6)
		pointer.Parent = attachHost
	end
	uiPointer = pointer

	task.spawn(function()
		while uiPointer == pointer and pointer.Parent and active and target.Parent do
			if chromeSuppressed and not uiPointerForced and not isClaimCutscene() then
				break
			end
			local up = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = UDim2.fromOffset(54, 54),
				Rotation = -10,
			})
			up:Play()
			up.Completed:Wait()
			if uiPointer ~= pointer then
				break
			end
			local down = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = UDim2.fromOffset(46, 46),
				Rotation = 6,
			})
			down:Play()
			down.Completed:Wait()
			task.wait(0.04)
		end
	end)
end

local function resolveUpgradeStandPart(): BasePart?
	local map = Workspace:FindFirstChild("Map")
	local stands = map and map:FindFirstChild("UIStands")
	local upgrade = stands and stands:FindFirstChild("Upgrade Stand")
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
	refreshVineCache()
	local origin = playerOrigin()
	local aim = land1Aim()
	local toAim = aim - origin
	local aimDir = if toAim.Magnitude > 1 then toAim.Unit else Vector3.new(0, 0, -1)

	local best: BasePart? = nil
	local bestScore = math.huge

	for _, part in vineCache do
		if not part.Parent then
			continue
		end
		local offset = part.Position - origin
		local dist = offset.Magnitude
		if dist < 6 or dist > 220 then
			continue
		end
		local toward = offset:Dot(aimDir)
		-- Prefer vines ahead toward Land 1, not behind the player.
		if toward < -8 then
			continue
		end
		local land = LandResolver.resolveLandAtPosition(part.Position)
		local landBonus = if land == 1 then 0 else 35
		local score = dist + landBonus + (part.Position - aim).Magnitude * 0.15
		if score < bestScore then
			bestScore = score
			best = part
		end
	end

	if best then
		return best
	end

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
	return best
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
		local map = Workspace:FindFirstChild("Map")
		if map then
			for _, d in map:GetDescendants() do
				if d:IsA("ProximityPrompt") and CarryGate.isBushSearchPrompt(d) then
					local rootBush = BushRootUtil.resolveBushRootFromPrompt(d)
					if rootBush then
						considerBush(rootBush)
					end
				end
			end
		end
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
	powerBuyButton = nil
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return nil
	end
	local frames = main:FindFirstChild("Frames")
	local upgrades = frames and frames:FindFirstChild("Upgrades")
	if upgrades and upgrades:IsA("Frame") then
		upgradesFrame = upgrades
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
		powerBuyButton = btn
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

	-- Claim cutscene: Accept/Decline icons are enough — no click overlay.
	if step.id == "claimBrainrot" or isClaimCutscene() then
		clearWorldArrow()
		clearSpotlight()
		clearUiPointer()
		return
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

	if step.id == "visitUpgrade" then
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
			pointAtWorld(resolveUpgradeStandPart(), arrowHeight(4))
		end
	elseif step.id == "swingLand1" then
		pointAtWorld(resolveLand1SwingTarget(), arrowHeight(3))
	elseif step.id == "searchBush" then
		if not keepWorld then
			pointAtWorld(resolveNearestBush(), arrowHeight(2))
		end
	elseif step.id == "placeOnPlot" then
		clearLockedBush()
		pointAtWorld(resolvePlayerPlotStand(true), arrowHeight(3))
	elseif step.id == "upgradeBrainrot" then
		pointAtWorld(resolvePlacedStandUpgradeTarget(), arrowHeight(4))
	end
end
refreshPointers = refreshPointersImpl

local function finishTutorial()
	if not active then
		return
	end
	active = false
	speakToken += 1
	stopObjectiveDots()
	clearWorldArrow()
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
	local celebrate = if opts and opts.celebrate == false then false else true
	local first = stepIndex == 0
	if celebrate and stepIndex > 0 and index > stepIndex then
		fireConfettiAndShake()
	end
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
	elseif step.id ~= "claimBrainrot" then
		clearLockedBush()
	end
	showPanel(step.text, first)
	refreshPointers()
end

local function completeCurrentIf(id: TutorialConfig.StepId)
	local step = currentStep()
	if not step or step.id ~= id then
		return
	end
	advanceTo(stepIndex + 1)
end

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
					if CarryGate.isCarryingOnHead() then
						completeCurrentIf("claimBrainrot")
					end
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
		end

		local step = currentStep()
		if not step then
			return
		end
		local now = os.clock()

		-- Periodically re-aim world arrows only when missing (don't retarget bushes).
		if now - lastPointerRefresh > 1.25 then
			lastPointerRefresh = now
			if step.id == "swingLand1" or step.id == "visitUpgrade" or step.id == "placeOnPlot" or step.id == "upgradeBrainrot" then
				if not worldArrowBb and not uiPointer then
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
				if btn and isGuiTreeVisible(btn) and not uiPointer then
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
			elseif not worldArrowBb then
				refreshPointers()
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

	local main = PlayerGuiMain.ensure(player)
	if main then
		local frames = main:FindFirstChild("Frames")
		local upgrades = frames and frames:FindFirstChild("Upgrades")
		if upgrades and upgrades:IsA("GuiObject") then
			upgradesFrame = upgrades :: Frame
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
	speakToken += 1
	stopObjectiveDots()
	clearWorldArrow()
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
		BushFloatingClaimController.registerOfferHook(function(_model, _ui)
			completeCurrentIf("searchBush")
			-- Claim cutscene owns the quest chrome.
			setChromeSuppressed(true)
			clearUiPointer()
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
