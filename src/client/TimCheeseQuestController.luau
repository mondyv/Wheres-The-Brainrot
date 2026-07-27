-- [ACTIVE] TimCheeseQuestController
--[[
	Tim Cheese intro fall cutscene, quest HUD, claim dialogue, walk-by speech.
]]

local Debris = game:GetService("Debris")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TimCheeseQuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TimCheeseQuestConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local TopNotifController = require(script.Parent.TopNotifController)
local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer
local M = {}
local wired = false

local homePivot: CFrame? = nil
local timModel: Model? = nil
local questHitbox: BasePart? = nil
local introPlaying = false
local introStartedLocal = false -- never restart fall once begun (attribute can lag)
local dialogueBusy = false
local lastWalkbyAt = 0.0
local questGui: ScreenGui? = nil
local questHost: Frame? = nil
local questPanel: Frame? = nil
local forcedQuestIndex: number? = nil
local acceptPopupGui: ScreenGui? = nil
local highlight: Highlight? = nil
local talkPrompt: ProximityPrompt? = nil
local idleTrack: AnimationTrack? = nil
local bgmSaved: { [Sound]: number } = {}
local hiddenPartMods: { [BasePart]: number } = {}
local hideKeepConn: RBXScriptConnection? = nil
local hideDescConn: RBXScriptConnection? = nil
local timHiddenPending = false
local ROCK_GREEN = Color3.fromRGB(62, 168, 58)

local function remotesFolder(): Folder?
	return ReplicatedStorage:FindFirstChild("TimCheeseQuestRemotes") :: Folder?
end

local function getRE(name: string): RemoteEvent?
	local folder = remotesFolder()
	local ev = folder and folder:FindFirstChild(name)
	return if ev and ev:IsA("RemoteEvent") then ev else nil
end

local function getRF(name: string): RemoteFunction?
	local folder = remotesFolder()
	local rf = folder and folder:FindFirstChild(name)
	return if rf and rf:IsA("RemoteFunction") then rf else nil
end

local function findShowers(): Instance?
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild(TimCheeseQuestConfig.MAP_FOLDER_NAME)
end

local function resolveTim(): Model?
	local folder = findShowers()
	local tim = folder and folder:FindFirstChild(TimCheeseQuestConfig.TIM_NAME)
	if tim and tim:IsA("Model") then
		return tim
	end
	return nil
end

local function resolveHitbox(): BasePart?
	local folder = findShowers()
	local trigger = folder and folder:FindFirstChild(TimCheeseQuestConfig.QUEST_TRIGGER_NAME)
	local box = trigger and trigger:FindFirstChild(TimCheeseQuestConfig.QUEST_HITBOX_NAME)
	if box and box:IsA("BasePart") then
		return box
	end
	if trigger and trigger:IsA("BasePart") then
		return trigger
	end
	return nil
end

local function setQuestFloatVisible(tim: Model, visible: boolean, text: string?)
	local floatUi = tim:FindFirstChild(TimCheeseQuestConfig.QUEST_FLOAT_UI_NAME)
	if not floatUi then
		return
	end
	for _, d in floatUi:GetDescendants() do
		if d:IsA("BillboardGui") then
			d.Enabled = visible
			if text then
				local req = d:FindFirstChild("Requirement")
				if req and req:IsA("TextLabel") then
					req.Text = text
				elseif req then
					local label = req:FindFirstChildWhichIsA("TextLabel")
					if label then
						label.Text = text
					end
				end
			end
		end
	end
end

local function applyHideToInstance(d: Instance)
	if d:IsA("BasePart") then
		-- Always restore to 0 later (re-hide must not snapshot LTM=1).
		if hiddenPartMods[d] == nil then
			hiddenPartMods[d] = 0
		end
		d.LocalTransparencyModifier = 1
	elseif d:IsA("Decal") or d:IsA("Texture") then
		d.Transparency = 1
	elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
		d.Enabled = false
	elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
		d.Enabled = false
	elseif d:IsA("Highlight") then
		d.Enabled = false
	end
end

-- Local-only hide until intro finishes (re-applied so streaming/descendants stay gone).
local function hideTimUntilIntro(tim: Model)
	timHiddenPending = true
	table.clear(hiddenPartMods)
	for _, d in tim:GetDescendants() do
		applyHideToInstance(d)
	end
	setQuestFloatVisible(tim, false)

	if hideDescConn then
		hideDescConn:Disconnect()
		hideDescConn = nil
	end
	hideDescConn = tim.DescendantAdded:Connect(function(d)
		if timHiddenPending then
			applyHideToInstance(d)
		end
	end)

	if hideKeepConn then
		hideKeepConn:Disconnect()
		hideKeepConn = nil
	end
	hideKeepConn = RunService.Heartbeat:Connect(function()
		if not timHiddenPending or not tim.Parent then
			return
		end
		for _, d in tim:GetDescendants() do
			if d:IsA("BasePart") and d.LocalTransparencyModifier < 1 then
				if hiddenPartMods[d] == nil then
					hiddenPartMods[d] = d.LocalTransparencyModifier
				end
				d.LocalTransparencyModifier = 1
			elseif (d:IsA("BillboardGui") or d:IsA("SurfaceGui")) and d.Enabled then
				d.Enabled = false
			end
		end
	end)
end

local function revealTimForIntro(tim: Model)
	timHiddenPending = false
	if hideKeepConn then
		hideKeepConn:Disconnect()
		hideKeepConn = nil
	end
	if hideDescConn then
		hideDescConn:Disconnect()
		hideDescConn = nil
	end
	table.clear(hiddenPartMods)
	-- Force visible — never trust saved LTM (re-hide could have stored 1).
	for _, d in tim:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
		elseif d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = 0
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = true
		elseif d:IsA("Highlight") then
			d.Enabled = true
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			-- float UI toggled separately
		end
	end
end

-- Server-owned Tim can't be PivotTo'd reliably — fall/dialogue uses a local clone.
local function makeIntroClone(tim: Model, landCf: CFrame): Model?
	local ok, clone = pcall(function()
		return tim:Clone()
	end)
	if not ok or not clone or not clone:IsA("Model") then
		warn("[TimCheeseQuestController] clone failed:", clone)
		return nil
	end
	clone.Name = "TimCheeseIntroClone"
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.LocalTransparencyModifier = 0
		elseif d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = 0
		elseif d:IsA("ProximityPrompt") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			d.Enabled = false
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = true
		end
	end
	local floatUi = clone:FindFirstChild(TimCheeseQuestConfig.QUEST_FLOAT_UI_NAME)
	if floatUi then
		floatUi:Destroy()
	end
	clone:PivotTo(landCf)
	clone.Parent = Workspace
	return clone
end

local function playWindLoop(): Sound?
	local root = SoundService:FindFirstChild("SoundEffects")
	local template = root and (root:FindFirstChild("Wind Loop") or root:FindFirstChild("Wind"))
	if not (template and template:IsA("Sound")) then
		return nil
	end
	local s = template:Clone()
	s.Looped = true
	s.SoundGroup = ClientSFXVolume.getSoundGroup()
	s.Parent = SoundService
	s:Play()
	return s
end

local function setBgmSlowed(on: boolean)
	local root = SoundService:FindFirstChild("BackgroundMusic")
	if not root then
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Sound") then
			if on then
				if bgmSaved[d] == nil then
					bgmSaved[d] = d.PlaybackSpeed
				end
				TweenService:Create(d, TweenInfo.new(0.45), { PlaybackSpeed = 0.72 }):Play()
			else
				local prev = bgmSaved[d]
				if typeof(prev) == "number" then
					TweenService:Create(d, TweenInfo.new(0.55), { PlaybackSpeed = prev }):Play()
				end
				bgmSaved[d] = nil
			end
		end
	end
end

local function pulseCameraShake(duration: number, amp: number)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local endAt = os.clock() + duration
	task.spawn(function()
		while os.clock() < endAt do
			local t = os.clock()
			local fade = math.clamp((endAt - t) / duration, 0, 1)
			hum.CameraOffset = Vector3.new(
				math.sin(t * 38) * amp * fade,
				math.cos(t * 31) * amp * 0.55 * fade,
				0
			)
			RunService.RenderStepped:Wait()
		end
		if hum.Parent then
			hum.CameraOffset = Vector3.zero
		end
	end)
end

local function spawnLandingDebris(landingPos: Vector3, tim: Model)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { tim }
	local hit = Workspace:Raycast(landingPos + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), params)
	local pos = if hit then hit.Position else landingPos

	local ring = Instance.new("Part")
	ring.Name = "TimImpactRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Grass
	ring.Color = ROCK_GREEN
	ring.Size = Vector3.new(0.35, 2.5, 2.5)
	ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 18, 18),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.55)

	for i = 1, 36 do
		local chip = Instance.new("Part")
		chip.Name = "TimLandingChip"
		local scale = 1.1 + math.random() * 1.6
		chip.Size = Vector3.new(0.85, 0.55, 1.05) * scale
		chip.Color = if i % 3 == 0 then Color3.fromRGB(48, 140, 52) else ROCK_GREEN
		chip.Material = Enum.Material.Grass
		chip.Anchored = true
		chip.CanCollide = false
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		local ang = math.rad(i * (360 / 36))
		chip.CFrame = CFrame.new(pos + Vector3.new(0, 0.4, 0)) * CFrame.Angles(ang, ang * 0.4, 0)
		chip.Parent = Workspace
		local dir = Vector3.new(math.cos(ang), 0.55 + math.random() * 0.7, math.sin(ang)).Unit
		local goal = pos + dir * (7 + math.random() * 8) + Vector3.new(0, 2.5 + math.random() * 2, 0)
		TweenService:Create(chip, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(goal) * CFrame.Angles(math.random() * 2, math.random() * 2, math.random() * 2),
			Transparency = 1,
			Size = chip.Size * 0.25,
		}):Play()
		Debris:AddItem(chip, 0.85)
	end
end

local function ensureIdle(tim: Model)
	StandDialogueCutscene.ensureIdleAnimation(tim, TimCheeseQuestConfig.IDLE_ANIM_NAME)
	if idleTrack and idleTrack.IsPlaying then
		return
	end
	local controller = tim:FindFirstChildOfClass("AnimationController")
	if not controller then
		controller = Instance.new("AnimationController")
		controller.Name = "AnimationController"
		controller.Parent = tim
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		local hum = tim:FindFirstChildOfClass("Humanoid")
		animator = hum and hum:FindFirstChildOfClass("Animator")
	end
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	for _, d in tim:GetDescendants() do
		if d:IsA("Animation") then
			local ok, track = pcall(function()
				return (animator :: Animator):LoadAnimation(d)
			end)
			if ok and track then
				idleTrack = track
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Idle
				track:Play(0.2)
				return
			end
		end
	end
end

local function setOutline(tim: Model, on: boolean)
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if not on then
		return
	end
	local hl = Instance.new("Highlight")
	hl.Name = "TimCheeseQuestOutline"
	hl.FillColor = Color3.fromRGB(255, 236, 70)
	hl.OutlineColor = Color3.fromRGB(255, 236, 70)
	hl.FillTransparency = 0.72
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = tim
	hl.Parent = Workspace
	highlight = hl
end

local function ensureTalkPrompt(tim: Model)
	if talkPrompt and talkPrompt.Parent then
		return talkPrompt
	end
	local part = tim.PrimaryPart or tim:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		return nil
	end
	local existing = part:FindFirstChild("TimCheeseTalkPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		talkPrompt = existing
		return existing
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TimCheeseTalkPrompt"
	prompt.ActionText = "Talk"
	prompt.ObjectText = "Tim Cheese"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = part
	talkPrompt = prompt
	prompt.Triggered:Connect(function(who)
		if who ~= player then
			return
		end
		task.spawn(M.openTimDialogue)
	end)
	return prompt
end

local function syncPromptAndOutline()
	local tim = timModel or resolveTim()
	if not tim then
		return
	end
	timModel = tim
	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	local intro = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local hasQuest = typeof(idx) == "number" and idx >= 1
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then completed else 0
	local allDone = doneCount >= TimCheeseQuestConfig.questCount()

	if intro and not introPlaying and not dialogueBusy then
		ensureTalkPrompt(tim)
		if talkPrompt then
			talkPrompt.Enabled = ready or (not hasQuest and not allDone) or allDone
			talkPrompt.ActionText = if ready then "Claim" elseif allDone then "Talk" else "Quests"
		end
		setOutline(tim, ready == true)
		if ready then
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.READY_OVERHEAD)
		else
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
		end
	end
end

local function ensureQuestHost(): Frame?
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return nil
	end
	local existing = main:FindFirstChild("TimCheeseQuestHost")
	if existing and existing:IsA("Frame") then
		questHost = existing
		return existing
	end
	local host = Instance.new("Frame")
	host.Name = "TimCheeseQuestHost"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = UDim2.fromScale(1, 1)
	host.Position = UDim2.fromScale(0, 0)
	host.ZIndex = 85
	host.ClipsDescendants = false
	host.Active = false
	host.Parent = main
	questHost = host
	return host
end

local function ensureQuestHud(): Frame
	if questPanel and questPanel.Parent then
		return questPanel
	end
	local host = ensureQuestHost()
	assert(host, "TimCheeseQuestHost missing")

	local panel = Instance.new("Frame")
	panel.Name = "ObjectivePanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -18, 0, 72)
	panel.Size = UDim2.fromOffset(280, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(22, 26, 34)
	panel.BackgroundTransparency = 0.28
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 100
	panel.Parent = host

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 220, 80)
	stroke.Thickness = 1.6
	stroke.Transparency = 0.25
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Name = "PanelScale"
	scale.Scale = 1
	scale.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 20)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 16
	title.TextColor3 = Color3.fromRGB(255, 230, 90)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "TIM CHEESE QUEST"
	title.LayoutOrder = 1
	title.Parent = panel
	UiFonts.applyDisplayLabel(title, 16, 13)

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	body.TextSize = 14
	body.TextColor3 = Color3.fromRGB(245, 245, 245)
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.LayoutOrder = 2
	body.Parent = panel

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Size = UDim2.new(1, 0, 0, 16)
	progress.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	progress.TextSize = 13
	progress.TextColor3 = Color3.fromRGB(180, 255, 160)
	progress.TextXAlignment = Enum.TextXAlignment.Left
	progress.LayoutOrder = 3
	progress.Parent = panel

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, 0, 0, 8)
	barBg.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
	barBg.BorderSizePixel = 0
	barBg.LayoutOrder = 4
	barBg.Parent = panel
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = barBg
	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(255, 210, 70)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	questPanel = panel
	return panel
end

local function layoutQuestHud()
	local panel = questPanel
	if not panel then
		return
	end
	local host = ensureQuestHost()
	if host and panel.Parent ~= host then
		panel.Parent = host
	end
	local mobile = UserInputService.TouchEnabled
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	local insetY = GuiService:GetGuiInset().Y
	if mobile or vw < 700 then
		panel.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.72), 180, 260), 0)
		panel.Position = UDim2.new(1, -12, 0, 14 + insetY)
	else
		panel.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.22), 260, 340), 0)
		panel.Position = UDim2.new(1, -18, 0, 18 + insetY)
	end
end

local function resolveActiveQuestIndex(): number?
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) == "number" and idx >= 1 then
		if forcedQuestIndex and math.floor(idx) == forcedQuestIndex then
			forcedQuestIndex = nil
		end
		return math.floor(idx)
	end
	if typeof(forcedQuestIndex) == "number" and forcedQuestIndex >= 1 then
		return forcedQuestIndex
	end
	return nil
end

local function formatQuestBody(quest: TimCheeseQuestConfig.QuestDef, ready: boolean): string
	if ready then
		return "Quest completed! Go see Tim Cheese to claim."
	end
	return string.format("%s — %s  ·  Reward %s", quest.title, quest.description, BrainrotEconomy.formatCashShort(quest.rewardCash))
end

local function formatQuestProgress(quest: TimCheeseQuestConfig.QuestDef, p: number): string
	if quest.kind == "place_stands" or quest.kind == "harvest" then
		return string.format("%d / %d", math.floor(p), quest.target)
	elseif quest.kind == "income" then
		return string.format("%s/s", BrainrotEconomy.formatCashShort(p))
	else
		return string.format("%s / %s", BrainrotEconomy.formatCashShort(p), BrainrotEconomy.formatCashShort(quest.target))
	end
end

local function refreshQuestHud()
	local idx = resolveActiveQuestIndex()
	local progressVal = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	if not idx then
		if questPanel then
			questPanel.Visible = false
		end
		return
	end
	local quest = TimCheeseQuestConfig.getQuest(idx)
	if not quest then
		return
	end
	local panel = ensureQuestHud()
	layoutQuestHud()
	panel.Visible = true
	local body = panel:FindFirstChild("Body")
	local progress = panel:FindFirstChild("Progress")
	local barBg = panel:FindFirstChild("BarBg")
	local p = if typeof(progressVal) == "number" then progressVal else 0
	if body and body:IsA("TextLabel") then
		body.Text = formatQuestBody(quest, ready)
	end
	if progress and progress:IsA("TextLabel") then
		progress.Text = if quest.showBar then formatQuestProgress(quest, p) else quest.title
		progress.Visible = quest.showBar == true or ready
	end
	if barBg and barBg:IsA("Frame") then
		barBg.Visible = quest.showBar == true and not ready
		local fill = barBg:FindFirstChild("BarFill")
		if fill and fill:IsA("Frame") then
			local alpha = math.clamp(p / math.max(quest.target, 1), 0, 1)
			fill.Size = UDim2.new(alpha, 0, 1, 0)
		end
	end
end

local function playQuestAcceptPopup(quest: TimCheeseQuestConfig.QuestDef)
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not pg then
		return
	end
	if acceptPopupGui then
		acceptPopupGui:Destroy()
		acceptPopupGui = nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TimCheeseQuestHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 120
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg
	acceptPopupGui = gui
	questGui = gui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(8, 6, 12)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "AcceptCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.48)
	card.Size = UDim2.fromOffset(420, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Color3.fromRGB(24, 20, 14)
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.Parent = gui
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 16)
	cardCorner.Parent = card
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(255, 210, 70)
	cardStroke.Thickness = 2.2
	cardStroke.Parent = card
	local cardPad = Instance.new("UIPadding")
	cardPad.PaddingTop = UDim.new(0, 22)
	cardPad.PaddingBottom = UDim.new(0, 22)
	cardPad.PaddingLeft = UDim.new(0, 24)
	cardPad.PaddingRight = UDim.new(0, 24)
	cardPad.Parent = card
	local cardLayout = Instance.new("UIListLayout")
	cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardLayout.Padding = UDim.new(0, 10)
	cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardLayout.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Scale = 0.72
	cardScale.Parent = card

	local eyebrow = Instance.new("TextLabel")
	eyebrow.BackgroundTransparency = 1
	eyebrow.Size = UDim2.new(1, 0, 0, 18)
	eyebrow.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	eyebrow.TextSize = 13
	eyebrow.TextColor3 = Color3.fromRGB(255, 220, 90)
	eyebrow.Text = "QUEST ACCEPTED"
	eyebrow.LayoutOrder = 1
	eyebrow.Parent = card

	local headline = Instance.new("TextLabel")
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, 0, 0, 28)
	headline.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	headline.TextSize = 24
	headline.TextColor3 = Color3.new(1, 1, 1)
	headline.Text = quest.title
	headline.LayoutOrder = 2
	headline.Parent = card
	UiFonts.applyDisplayLabel(headline, 24, 18)

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Size = UDim2.new(1, 0, 0, 0)
	info.AutomaticSize = Enum.AutomaticSize.Y
	info.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	info.TextSize = 16
	info.TextColor3 = Color3.fromRGB(235, 230, 220)
	info.TextWrapped = true
	info.Text = string.format("%s\nReward: %s", quest.description, BrainrotEconomy.formatCashShort(quest.rewardCash))
	info.LayoutOrder = 3
	info.Parent = card

	local mobile = UserInputService.TouchEnabled
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	if mobile or vw < 700 then
		card.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.86), 260, 360), 0)
	end

	TweenService:Create(dim, TweenInfo.new(0.22), { BackgroundTransparency = 0.45 }):Play()
	TweenService:Create(cardScale, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	GameSoundEffects.playPurchase()

	task.wait(2.35)
	if not gui.Parent then
		return
	end
	TweenService:Create(dim, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(cardScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.86 }):Play()
	task.wait(0.22)
	if gui.Parent then
		gui:Destroy()
	end
	if acceptPopupGui == gui then
		acceptPopupGui = nil
		questGui = nil
	end
end

Size = UDim2.new(alpha, 0, 1, 0)
		end
	end
end

local function restoreMovement()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
	if typeof(base) ~= "number" or base <= 0 then
		base = 16
	end
	local slowOn = player:GetAttribute("SlowWalkEnabled") == true
	hum.WalkSpeed = (base :: number) * (if slowOn then 0.8 else 1.15)
	hum.UseJumpPower = true
	hum.JumpPower = 50
	hum.JumpHeight = 7.2
	hum.AutoRotate = true
end

local function lockMovement(on: boolean)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if on then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
	else
		restoreMovement()
	end
end

local function placePlayerNearTim(landCf: CFrame)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	local land = landCf.Position
	-- Stand close on Tim's front-right so dialogue cam frames his face.
	local standPos = land + landCf.RightVector * 3.2 + landCf.LookVector * 4.2 + Vector3.new(0, 3, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = Workspace:Raycast(standPos + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), params)
	if hit then
		standPos = Vector3.new(standPos.X, hit.Position.Y + 3, standPos.Z)
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.CFrame = CFrame.lookAt(standPos, Vector3.new(land.X, standPos.Y, land.Z))
end

local function waitForQuestHud(timeoutSec: number)
	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
		if typeof(idx) == "number" and idx >= 1 then
			refreshQuestHud()
			return true
		end
		task.wait(0.05)
	end
	refreshQuestHud()
	return false
end

local function buildOfferLinesForIndex(questIndex: number): { { text: string, shake: boolean? } }
	local quest = TimCheeseQuestConfig.getQuest(questIndex)
	if not quest then
		return TimCheeseQuestConfig.OFFER_LINES
	end
	local lead = if questIndex <= 1 then "Alright — first job's on the HOUSE!!" else "Fresh job just dropped. Listen up!!"
	return {
		{ text = lead, shake = true },
		{ text = string.format("%s — %s", quest.title, quest.description), shake = false },
		{
			text = string.format("Reward: %s. You in?", BrainrotEconomy.formatCashShort(quest.rewardCash)),
			shake = true,
		},
	}
end

local function buildFirstOfferLines(): { { text: string, shake: boolean? } }
	return buildOfferLinesForIndex(1)
end

function M.playIntroFall()
	if introPlaying or introStartedLocal then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
		introStartedLocal = true
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	local tim = resolveTim()
	if not tim then
		return
	end
	timModel = tim
	-- Always use Studio landing pose saved at init — never re-capture mid-fall.
	if not homePivot then
		homePivot = tim:GetPivot()
	end
	introStartedLocal = true
	introPlaying = true

	-- Keep shared world Tim invisible; animate a local clone (server PivotTo snaps otherwise).
	hideTimUntilIntro(tim)
	setQuestFloatVisible(tim, false)

	local landCf = homePivot
	local clone = makeIntroClone(tim, landCf)
	if not clone then
		introPlaying = false
		introStartedLocal = false
		return
	end

	GameplayUiVisibility.hide({ keepScreenGuiNames = { "TimCheeseQuestHud", "StandDialogueCutscene" } })
	lockMovement(true)
	setBgmSlowed(true)
	local wind = playWindLoop()

	-- Near Tim so dialogue framing stays close after the fall.
	placePlayerNearTim(landCf)

	local land = landCf.Position
	local start = land + Vector3.new(0, TimCheeseQuestConfig.DROP_HEIGHT, 0)
	local rotOnly = landCf - landCf.Position
	clone:PivotTo(CFrame.new(start) * rotOnly)
	-- Idle plays through fall + talk (TimCheese brainrot anim).
	ensureIdle(clone)

	local cam = Workspace.CurrentCamera
	local savedType = cam and cam.CameraType
	local savedSubject = cam and cam.CameraSubject
	local savedFov = cam and cam.FieldOfView
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = 62
	end

	local alpha = Instance.new("NumberValue")
	alpha.Value = 0
	local tween = TweenService:Create(
		alpha,
		TweenInfo.new(TimCheeseQuestConfig.FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Value = 1 }
	)
	-- Fixed worm's-eye pad cam — look UP at Tim, don't chase him.
	local camPos = Vector3.new(land.X + 7, land.Y + 1.15, land.Z + 8)
	local conn = RunService.RenderStepped:Connect(function()
		local t = alpha.Value
		local y = start.Y + (land.Y - start.Y) * (t * t)
		local pos = Vector3.new(land.X, y, land.Z)
		local sway = math.sin(t * 28) * (1 - t) * 0.85
		if clone.Parent then
			clone:PivotTo(CFrame.new(pos + Vector3.new(sway, 0, 0)) * rotOnly)
		end
		if cam then
			cam.CFrame = CFrame.lookAt(camPos, pos + Vector3.new(0, 1.2, 0))
		end
	end)
	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	alpha:Destroy()

	if wind then
		wind:Stop()
		wind:Destroy()
	end
	if clone.Parent then
		clone:PivotTo(landCf)
	end
	spawnLandingDebris(land, clone)
	GameSoundEffects.playGroundSmash(1.45)
	pulseCameraShake(0.55, 0.7)
	ensureIdle(clone)
	setBgmSlowed(false)

	StandDialogueCutscene.play({
		standName = "TimCheese",
		frameKey = "TimCheese",
		brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
		enterLabel = "LET'S GO",
		exitLabel = "COOL",
		lines = TimCheeseQuestConfig.INTRO_LINES,
		voicePitchMin = 0.92,
		voicePitchMax = 1.12,
	}, clone)

	-- Offer first quest with title / goal / reward before Accept.
	local accepted = StandDialogueCutscene.play({
		standName = "TimCheese",
		frameKey = "TimCheese",
		brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
		enterLabel = "ACCEPT QUEST",
		exitLabel = "DECLINE",
		lines = buildFirstOfferLines(),
		voicePitchMin = 0.92,
		voicePitchMax = 1.12,
	}, clone)

	-- Mark intro done after dialogue (not at fall start — that raced AcceptQuest).
	local introRE = getRE("IntroDone")
	if introRE then
		introRE:FireServer()
	end

	if accepted then
		local rf = getRF("AcceptQuest")
		local acceptOk = false
		if rf then
			local ok, result = pcall(function()
				return rf:InvokeServer()
			end)
			if not ok then
				warn("[TimCheeseQuestController] AcceptQuest error:", result)
			elseif result ~= true then
				warn("[TimCheeseQuestController] AcceptQuest rejected")
			else
				acceptOk = true
			end
		end
		if acceptOk then
			forcedQuestIndex = 1
		end
	else
		StandDialogueCutscene.play({
			standName = "TimCheese",
			frameKey = "TimCheese",
			brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
			enterLabel = "OK",
			exitLabel = "BYE",
			lines = TimCheeseQuestConfig.DECLINE_LINES,
			voicePitchMin = 0.92,
			voicePitchMax = 1.12,
		}, clone)
	end

	if clone.Parent then
		clone:Destroy()
	end
	idleTrack = nil
	revealTimForIntro(tim)
	ensureIdle(tim)

	if cam then
		cam.CameraType = savedType or Enum.CameraType.Custom
		cam.CameraSubject = savedSubject
		if typeof(savedFov) == "number" then
			cam.FieldOfView = savedFov
		end
	end

	GameplayUiVisibility.show({ instant = true })
	lockMovement(false)
	introPlaying = false
	setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)

	if accepted then
		local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex or 1)
		if q then
			playQuestAcceptPopup(q)
		end
		waitForQuestHud(2.5)
		TopNotifController.showBroadcast("New quest from Tim Cheese!")
	end
	refreshQuestHud()
	syncPromptAndOutline()
end

function M.openTimDialogue()
	if dialogueBusy or introPlaying then
		return
	end
	local tim = timModel or resolveTim()
	if not tim then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) ~= true then
		return
	end
	dialogueBusy = true
	setQuestFloatVisible(tim, false)
	setOutline(tim, false)

	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local hasQuest = typeof(idx) == "number" and idx >= 1
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then completed else 0

	if ready then
		local claimNow = StandDialogueCutscene.play({
			standName = "TimCheese",
			frameName = "TimCheese",
			brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
			enterLabel = "CLAIM",
			exitLabel = "LATER",
			lines = TimCheeseQuestConfig.COMPLETE_LINES,
			voicePitchMin = 0.92,
			voicePitchMax = 1.12,
		}, tim)
		if not claimNow then
			dialogueBusy = false
			syncPromptAndOutline()
			return
		end
		local claimRF = getRF("ClaimQuest")
		local ok, reward = false, nil
		if claimRF then
			local invokeOk, a, b = pcall(function()
				return claimRF:InvokeServer()
			end)
			if invokeOk then
				ok = a == true
				reward = b
			end
		end
		if ok and typeof(reward) == "number" then
			TopNotifController.showBroadcast("+" .. BrainrotEconomy.formatCashShort(reward))
		end
		local completedAfter = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
		local doneAfter = if typeof(completedAfter) == "number" then completedAfter else doneCount + 1
		if doneAfter >= TimCheeseQuestConfig.questCount() then
			StandDialogueCutscene.play({
				standName = "TimCheese",
				frameName = "TimCheese",
				brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
				enterLabel = "OK",
				exitLabel = "BYE",
				lines = TimCheeseQuestConfig.ALL_DONE_LINES,
				voicePitchMin = 0.92,
				voicePitchMax = 1.12,
			}, tim)
		else
			local wantAnother = StandDialogueCutscene.play({
				standName = "TimCheese",
				frameName = "TimCheese",
				brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
				enterLabel = "ACCEPT QUEST",
				exitLabel = "DECLINE",
				lines = buildOfferLinesForIndex(doneAfter + 1),
				voicePitchMin = 0.92,
				voicePitchMax = 1.12,
			}, tim)
			if wantAnother then
				local acceptRF = getRF("AcceptQuest")
				local acceptOk = false
				if acceptRF then
					local ok, result = pcall(function()
						return acceptRF:InvokeServer()
					end)
					acceptOk = ok and result == true
				end
				if acceptOk then
					forcedQuestIndex = doneAfter + 1
					local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex)
					if q then
						playQuestAcceptPopup(q)
					end
				end
				TopNotifController.showBroadcast("New quest from Tim Cheese!")
				waitForQuestHud(2.5)
			else
				StandDialogueCutscene.play({
					standName = "TimCheese",
					frameName = "TimCheese",
					brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
					enterLabel = "OK",
					exitLabel = "BYE",
					lines = TimCheeseQuestConfig.DECLINE_LINES,
					voicePitchMin = 0.92,
					voicePitchMax = 1.12,
				}, tim)
			end
		end
	elseif not hasQuest and doneCount < TimCheeseQuestConfig.questCount() then
		local want = StandDialogueCutscene.play({
			standName = "TimCheese",
			frameName = "TimCheese",
			brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
			enterLabel = "ACCEPT QUEST",
			exitLabel = "DECLINE",
			lines = buildOfferLinesForIndex(doneCount + 1),
			voicePitchMin = 0.92,
			voicePitchMax = 1.12,
		}, tim)
		if want then
			local acceptRF = getRF("AcceptQuest")
			local acceptOk = false
			if acceptRF then
				local ok, result = pcall(function()
					return acceptRF:InvokeServer()
				end)
				acceptOk = ok and result == true
			end
			if acceptOk then
				forcedQuestIndex = doneCount + 1
				local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex)
				if q then
					playQuestAcceptPopup(q)
				end
			end
			TopNotifController.showBroadcast("New quest from Tim Cheese!")
			waitForQuestHud(2.5)
		else
			StandDialogueCutscene.play({
				standName = "TimCheese",
				frameName = "TimCheese",
				brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
				enterLabel = "OK",
				exitLabel = "BYE",
				lines = TimCheeseQuestConfig.DECLINE_LINES,
				voicePitchMin = 0.92,
				voicePitchMax = 1.12,
			}, tim)
		end
	else
		StandDialogueCutscene.showWorldSpeech(tim, "Keep grinding that quest!", { durationSec = 2.4 })
	end

	dialogueBusy = false
	restoreMovement()
	refreshQuestHud()
	syncPromptAndOutline()
end

local function onHitboxTouched(other: BasePart)
	if introPlaying or introStartedLocal then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	local char = player.Character
	if not char or not other:IsDescendantOf(char) then
		return
	end
	task.spawn(M.playIntroFall)
end

local function tickWalkby()
	if introPlaying or dialogueBusy then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) ~= true then
		return
	end
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) == "number" and idx >= 1 then
		return
	end
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	if typeof(completed) == "number" and completed >= TimCheeseQuestConfig.questCount() then
		return
	end
	local tim = timModel or resolveTim()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not tim or not hrp or not hrp:IsA("BasePart") then
		return
	end
	local dist = (tim:GetPivot().Position - hrp.Position).Magnitude
	if dist > 18 then
		return
	end
	if os.clock() - lastWalkbyAt < TimCheeseQuestConfig.WALKBY_COOLDOWN_SEC then
		return
	end
	lastWalkbyAt = os.clock()
	local lines = TimCheeseQuestConfig.WALKBY_LINES
	local msg = lines[math.random(1, #lines)]
	StandDialogueCutscene.showWorldSpeech(tim, msg, { durationSec = 2.6 })
end

function M.init()
	if wired then
		return
	end
	wired = true

	task.spawn(function()
		local deadline = os.clock() + 90
		while os.clock() < deadline do
			timModel = resolveTim()
			questHitbox = resolveHitbox()
			if timModel and questHitbox then
				break
			end
			task.wait(0.5)
		end
		if not timModel or not questHitbox then
			warn("[TimCheeseQuestController] TimCheese / QuestHitbox missing")
			return
		end
		homePivot = timModel:GetPivot()
		questHitbox.Touched:Connect(onHitboxTouched)

		-- Zone poll fallback (Touched misses idle stands).
		task.spawn(function()
			while questHitbox and questHitbox.Parent do
				task.wait(0.35)
				if introStartedLocal or introPlaying then
					continue
				end
				if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
					continue
				end
				if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
					continue
				end
				local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					local localPt = questHitbox.CFrame:PointToObjectSpace(hrp.Position)
					local half = questHitbox.Size * 0.5
					if math.abs(localPt.X) <= half.X + 2 and math.abs(localPt.Z) <= half.Z + 2 and math.abs(localPt.Y) <= half.Y + 8 then
						task.spawn(M.playIntroFall)
					end
				end
			end
		end)

		if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
			introStartedLocal = true
			ensureIdle(timModel)
			setQuestFloatVisible(timModel, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
			syncPromptAndOutline()
			refreshQuestHud()
		else
			-- Invisible + parked until they enter the hitbox (tutorial done or not).
			hideTimUntilIntro(timModel)
		end

		player:GetAttributeChangedSignal(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR):Connect(function()
			if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
				introStartedLocal = true
			end
		end)

		player:GetAttributeChangedSignal(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR):Connect(function()
			refreshQuestHud()
			syncPromptAndOutline()
		end)
		player:GetAttributeChangedSignal(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR):Connect(refreshQuestHud)
		player:GetAttributeChangedSignal(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR):Connect(function()
			refreshQuestHud()
			syncPromptAndOutline()
			if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true then
				TopNotifController.showBroadcast("Quest completed! Go see Tim Cheese")
			end
		end)
		player:GetAttributeChangedSignal(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR):Connect(function()
			syncPromptAndOutline()
		end)

		local accum = 0.0
		RunService.Heartbeat:Connect(function(dt)
			accum += dt
			if accum < 1.1 then
				return
			end
			accum = 0
			tickWalkby()
			layoutQuestHud()
		end)
	end)
end

return M
