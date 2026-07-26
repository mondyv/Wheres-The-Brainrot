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
local BushFloatingClaimController = require(script.Parent.BushFloatingClaimController)
local CarryGate = require(script.Parent.CarryGate)
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local M = {}

local PANEL_OPEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PANEL_SWAP = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXCLAIM_PULSE = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local ARROW_BOB = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local CLICK_BOUNCE = TweenInfo.new(0.38, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local active = false
local stepIndex = 0
local gui: ScreenGui? = nil
local root: Frame? = nil
local panel: Frame? = nil
local exclaim: ImageLabel? = nil
local objectiveLabel: TextLabel? = nil
local panelScale: UIScale? = nil
local worldArrowBb: BillboardGui? = nil
local worldArrowImg: ImageLabel? = nil
local uiPointer: ImageLabel? = nil
local dimOverlay: Frame? = nil
local spotlightHole: Frame? = nil
local heartbeatConn: RBXScriptConnection? = nil
local attrConns: { RBXScriptConnection } = {}
local speakToken = 0
local completeRF: RemoteFunction? = nil
local upgradesFrame: Frame? = nil
local powerBuyButton: GuiObject? = nil
local lastLandCheck = 0
local claimSpotlightActive = false
local upgradeBaseLevel = 1
local layoutConn: RBXScriptConnection? = nil
local panelStroke: UIStroke? = nil

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

local function waitWhileStandTalking(token: number)
	while active and token == speakToken and StandDialogueCutscene.isActive() do
		task.wait(0.05)
	end
end

local function typeObjective(displayText: string)
	speakToken += 1
	local token = speakToken
	task.spawn(function()
		waitWhileStandTalking(token)
		if token ~= speakToken or not active or not objectiveLabel then
			return
		end
		StandDialogueCutscene.setVoicePitch(TutorialConfig.VOICE_PITCH_MIN, TutorialConfig.VOICE_PITCH_MAX)
		objectiveLabel.Text = ""
		for i = 1, #displayText do
			if token ~= speakToken or not active then
				return
			end
			if StandDialogueCutscene.isActive() then
				-- Stand dialogue owns Voice Gaster; finish text silently after it ends.
				waitWhileStandTalking(token)
				if token ~= speakToken or not active then
					return
				end
				if objectiveLabel then
					objectiveLabel.Text = displayText
				end
				return
			end
			local ch = string.sub(displayText, i, i)
			objectiveLabel.Text = string.sub(displayText, 1, i)
			if ch ~= " " and ch ~= "\n" then
				StandDialogueCutscene.playVoiceLetter()
			end
			task.wait(TutorialConfig.OBJECTIVE_TYPE_DELAY)
		end
		if token == speakToken and objectiveLabel then
			objectiveLabel.Text = displayText
		end
	end)
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

local function syncPanelToSideButtons()
	if not panel or not panel.Parent or not gui or not gui.Enabled then
		return
	end
	local sidePanel = resolveSideButtonPanel()
	if not sidePanel then
		return
	end
	local abs = sidePanel.AbsolutePosition
	local size = sidePanel.AbsoluteSize
	local panelHeight = panel.AbsoluteSize.Y
	if panelHeight < 8 then
		panelHeight = 58
	end
	local width = math.max(size.X, 240)
	local gap = TutorialConfig.PANEL_GAP_ABOVE_SIDE
	panel.Size = UDim2.fromOffset(width, 58)
	panel.Position = UDim2.fromOffset(abs.X, abs.Y - gap)
end

local function startLayoutSync()
	if layoutConn then
		layoutConn:Disconnect()
	end
	layoutConn = RunService.RenderStepped:Connect(function()
		if not active then
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

local function clearWorldArrow()
	if worldArrowBb then
		worldArrowBb:Destroy()
		worldArrowBb = nil
		worldArrowImg = nil
	end
end

local function clearUiPointer()
	if uiPointer then
		uiPointer:Destroy()
		uiPointer = nil
	end
end

local function clearSpotlight()
	claimSpotlightActive = false
	if dimOverlay then
		dimOverlay.Visible = false
	end
	if spotlightHole then
		spotlightHole.Visible = false
	end
end

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
	screen.DisplayOrder = 45
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
	panelFrame.Size = UDim2.fromOffset(280, 58)
	panelFrame.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
	panelFrame.BackgroundTransparency = 0.32
	panelFrame.BorderSizePixel = 0
	panelFrame.ClipsDescendants = false
	panelFrame.Parent = rootFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panelFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(8, 10, 14)
	stroke.Thickness = 1
	stroke.Transparency = 0.72
	stroke.Parent = panelFrame
	panelStroke = stroke

	local blurFake = Instance.new("Frame")
	blurFake.Name = "PanelSheen"
	blurFake.BackgroundColor3 = Color3.fromRGB(28, 32, 40)
	blurFake.BackgroundTransparency = 0.78
	blurFake.BorderSizePixel = 0
	blurFake.Size = UDim2.fromScale(1, 1)
	blurFake.ZIndex = 1
	blurFake.Parent = panelFrame
	local sheenCorner = Instance.new("UICorner")
	sheenCorner.CornerRadius = UDim.new(0, 12)
	sheenCorner.Parent = blurFake

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

	local label = Instance.new("TextLabel")
	label.Name = "ObjectiveText"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, 54, 0.5, 0)
	label.Size = UDim2.new(1, -64, 1, -10)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = true
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(245, 250, 255)
	label.Text = ""
	label.ZIndex = 3
	label.Parent = panelFrame
	UiFonts.applyButton(label)

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
	panelScale = scale
	dimOverlay = dim
	spotlightHole = hole

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
	gui.Enabled = true
	objectiveLabel.Text = ""
	syncPanelToSideButtons()
	if animateIn then
		panelScale.Scale = 0.82
		local pos = panel.Position
		panel.Position = UDim2.fromOffset(pos.X.Offset - 36, pos.Y.Offset)
		TweenService:Create(panelScale, PANEL_OPEN, { Scale = 1 }):Play()
		TweenService:Create(panel, PANEL_OPEN, {
			Position = UDim2.fromOffset(pos.X.Offset, pos.Y.Offset),
		}):Play()
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

	local bb = Instance.new("BillboardGui")
	bb.Name = "TutorialWorldArrow"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(64, 64)
	bb.StudsOffset = offset or arrowHeight()
	bb.MaxDistance = 400
	bb.Adornee = part
	bb.Parent = player:FindFirstChild("PlayerGui") or Workspace.CurrentCamera

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = TutorialConfig.WORLD_ARROW_IMAGE
	img.Rotation = TutorialConfig.WORLD_ARROW_ROTATION
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = bb

	worldArrowBb = bb
	worldArrowImg = img

	task.spawn(function()
		while worldArrowImg == img and img.Parent and active do
			local a = TweenService:Create(img, ARROW_BOB, {
				Position = UDim2.new(0, 0, 0, 6),
				Size = UDim2.fromScale(1.08, 1.08),
			})
			a:Play()
			a.Completed:Wait()
			if worldArrowImg ~= img then
				break
			end
			local b = TweenService:Create(img, ARROW_BOB, {
				Position = UDim2.new(0, 0, 0, -2),
				Size = UDim2.fromScale(1, 1),
			})
			b:Play()
			b.Completed:Wait()
		end
	end)
end

local function pointAtGui(target: GuiObject?)
	clearUiPointer()
	ensureGui()
	if not target or not root or not gui then
		return
	end

	-- Keep pointer above Main / billboards.
	gui.DisplayOrder = 120

	local pointer = Instance.new("ImageLabel")
	pointer.Name = "TutorialUiClick"
	pointer.BackgroundTransparency = 1
	pointer.Size = UDim2.fromOffset(56, 56)
	pointer.AnchorPoint = Vector2.new(0.15, 0.15)
	pointer.Image = TutorialConfig.UI_CLICK_IMAGE
	pointer.ScaleType = Enum.ScaleType.Fit
	pointer.ZIndex = 50
	pointer.Visible = false
	pointer.Parent = root
	uiPointer = pointer

	task.spawn(function()
		-- Wait a couple frames for AbsoluteSize to resolve (billboards / just-opened panels).
		for _ = 1, 8 do
			if not pointer.Parent or uiPointer ~= pointer or not active then
				return
			end
			if target.Parent and target.AbsoluteSize.X > 2 and target.AbsoluteSize.Y > 2 then
				break
			end
			task.wait()
		end

		while uiPointer == pointer and pointer.Parent and active and target.Parent do
			local abs = target.AbsolutePosition
			local size = target.AbsoluteSize
			if size.X < 2 or size.Y < 2 then
				pointer.Visible = false
				task.wait(0.1)
				continue
			end
			-- Tutorial ScreenGui uses IgnoreGuiInset; AbsolutePosition is already viewport-space.
			local px = abs.X + size.X * 0.78
			local py = abs.Y + size.Y * 0.62
			pointer.Visible = true
			pointer.Position = UDim2.fromOffset(px, py)
			local up = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = UDim2.fromOffset(64, 64),
				Rotation = -14,
			})
			up:Play()
			up.Completed:Wait()
			if uiPointer ~= pointer then
				break
			end
			local down = TweenService:Create(pointer, CLICK_BOUNCE, {
				Size = UDim2.fromOffset(56, 56),
				Rotation = 10,
			})
			down:Play()
			down.Completed:Wait()
			task.wait(0.04)
		end
	end)
end

local function pointAtAcceptOffer(acceptBtn: GuiObject?, acceptBb: BillboardGui?)
	-- Prefer the billboard root if the button hasn't laid out yet.
	if acceptBtn and acceptBtn.AbsoluteSize.X > 2 then
		pointAtGui(acceptBtn)
		return
	end
	if acceptBb then
		local rootGui = acceptBb:FindFirstChildWhichIsA("GuiObject")
		if rootGui then
			pointAtGui(rootGui)
			return
		end
	end
	if acceptBtn then
		pointAtGui(acceptBtn)
	end
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

local function resolveLand1SwingTarget(): BasePart?
	local best: BasePart? = nil
	local bestDist = math.huge
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	local land1 = lands and lands:FindFirstChild("Land1")
	local origin = Vector3.zero
	if land1 and land1:IsA("Model") then
		local ok, pivot = pcall(function()
			return (land1 :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			origin = (pivot :: CFrame).Position
		end
	end

	for _, inst in CollectionService:GetTagged("SwingTarget") do
		if inst:IsA("BasePart") then
			local land = LandResolver.resolveLandAtPosition(inst.Position)
			if land == 1 then
				local dist = (inst.Position - origin).Magnitude
				if dist < bestDist then
					bestDist = dist
					best = inst
				end
			end
		end
	end
	if best then
		return best
	end
	if land1 then
		for _, d in land1:GetDescendants() do
			if d:IsA("BasePart") and (d.Name == "SwingTarget" or d.Name == "SwingPart") then
				return d
			end
		end
	end
	return nil
end

local function resolveNearestBush(): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local origin = if hrp and hrp:IsA("BasePart") then hrp.Position else Vector3.zero
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, d in Workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") and CarryGate.isBushSearchPrompt(d) then
			local parent = d.Parent
			local part: BasePart? = nil
			if parent and parent:IsA("BasePart") then
				part = parent
			elseif parent then
				part = parent:FindFirstChildWhichIsA("BasePart", true)
			end
			if part then
				local dist = (part.Position - origin).Magnitude
				if dist < bestDist then
					bestDist = dist
					best = part
				end
			end
		end
	end
	return best
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

local function cacheUpgradesBuyButton()
	if powerBuyButton and powerBuyButton.Parent and powerBuyButton.AbsoluteSize.X > 2 then
		return powerBuyButton
	end
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
	if not row then
		-- Fallback: first row that looks like a power upgrade.
		if container then
			for _, ch in container:GetChildren() do
				if ch.Name:find("Power") then
					row = ch
					break
				end
			end
		end
	end
	if not row then
		return nil
	end
	local buyButtons = row:FindFirstChild("BuyButtons", true)
	local buy = buyButtons and buyButtons:FindFirstChild("Buy")
	local btn: GuiObject? = nil
	if buy and buy:IsA("GuiButton") then
		btn = buy
	elseif buy then
		local best: GuiButton? = nil
		local bestScore = -1
		for _, d in buy:GetDescendants() do
			if d:IsA("GuiButton") then
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
					local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
					local score = area + 1e6
					if score > bestScore then
						bestScore = score
						best = d
					end
				end
			end
		end
		btn = best or buy:FindFirstChildWhichIsA("GuiButton", true)
	end
	if not btn then
		btn = row:FindFirstChildWhichIsA("GuiButton", true)
	end
	if btn and btn:IsA("GuiObject") then
		powerBuyButton = btn
		return btn
	end
	return nil
end

local function currentStep(): TutorialConfig.StepDef?
	return TutorialConfig.STEPS[stepIndex]
end

local function refreshPointers()
	clearWorldArrow()
	clearUiPointer()
	clearSpotlight()
	local step = currentStep()
	if not step then
		return
	end
	if step.id == "visitUpgrade" then
		pointAtWorld(resolveUpgradeStandPart(), arrowHeight(1))
	elseif step.id == "buyPower" then
		local btn = cacheUpgradesBuyButton()
		if btn and upgradesFrame and upgradesFrame.Visible then
			task.defer(function()
				task.wait()
				if currentStep() and currentStep().id == "buyPower" then
					local again = cacheUpgradesBuyButton()
					if again then
						clearWorldArrow()
						pointAtGui(again)
					end
				end
			end)
			pointAtGui(btn)
		else
			pointAtWorld(resolveUpgradeStandPart(), arrowHeight(1))
		end
	elseif step.id == "swingLand1" then
		pointAtWorld(resolveLand1SwingTarget() or resolveUpgradeStandPart(), arrowHeight(2))
	elseif step.id == "searchBush" then
		pointAtWorld(resolveNearestBush(), arrowHeight())
	elseif step.id == "claimBrainrot" then
		local offer = BushFloatingClaimController.getActiveOfferUi()
		if offer and offer.acceptBtn then
			claimSpotlightActive = true
			if dimOverlay then
				dimOverlay.Visible = true
			end
			pointAtAcceptOffer(offer.acceptBtn, offer.acceptBb)
		end
	elseif step.id == "placeOnPlot" then
		pointAtWorld(resolvePlayerPlotStand(true), arrowHeight(1))
	elseif step.id == "upgradeBrainrot" then
		pointAtWorld(resolvePlacedStandUpgradeTarget(), arrowHeight(2.5))
	end
end

local function finishTutorial()
	if not active then
		return
	end
	active = false
	speakToken += 1
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
	fireConfettiAndShake()
	hidePanel()
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
	-- Use on-screen objective text for typewriter + voice (stand cadence).
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
		local step = currentStep()
		if not step then
			return
		end
		local now = os.clock()
		if step.id == "buyPower" then
			local btn = cacheUpgradesBuyButton()
			if btn and upgradesFrame and upgradesFrame.Visible then
				if not uiPointer then
					clearWorldArrow()
					pointAtGui(btn)
				end
			end
		elseif step.id == "swingLand1" and now - lastLandCheck > 0.35 then
			lastLandCheck = now
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local land = LandResolver.resolveLandAtPosition(hrp.Position)
				if land == 1 then
					completeCurrentIf("swingLand1")
				end
			end
		elseif step.id == "claimBrainrot" then
			local offer = BushFloatingClaimController.getActiveOfferUi()
			if offer and offer.acceptBtn then
				if not claimSpotlightActive then
					claimSpotlightActive = true
					if dimOverlay then
						dimOverlay.Visible = true
					end
				end
				if not uiPointer then
					pointAtAcceptOffer(offer.acceptBtn, offer.acceptBb)
				end
				if spotlightHole and uiPointer then
					local abs = offer.acceptBtn.AbsolutePosition
					local size = offer.acceptBtn.AbsoluteSize
					if size.X > 2 then
						local cx = abs.X + size.X * 0.5
						local cy = abs.Y + size.Y * 0.5
						spotlightHole.Visible = true
						spotlightHole.Position = UDim2.fromOffset(cx, cy)
						spotlightHole.Size = UDim2.fromOffset(math.max(size.X + 28, 110), math.max(size.Y + 20, 52))
					end
				end
			elseif claimSpotlightActive and not BushFloatingClaimController.hasActiveOffer() then
				clearSpotlight()
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
						task.defer(refreshPointers)
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
		BushFloatingClaimController.registerOfferHook(function(_model, ui)
			completeCurrentIf("searchBush")
			task.defer(function()
				local step = currentStep()
				if step and step.id == "claimBrainrot" then
					claimSpotlightActive = true
					if dimOverlay then
						dimOverlay.Visible = true
					end
					if ui and ui.acceptBtn then
						pointAtAcceptOffer(ui.acceptBtn, nil)
					else
						refreshPointers()
					end
				end
			end)
		end)
		BushFloatingClaimController.registerAcceptHook(function(_model)
			completeCurrentIf("claimBrainrot")
		end)
		BushFloatingClaimController.registerDeclineHook(function(_model)
			local step = currentStep()
			if step and step.id == "claimBrainrot" then
				clearSpotlight()
				clearUiPointer()
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
