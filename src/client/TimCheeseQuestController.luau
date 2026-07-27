-- [ACTIVE] TimCheeseQuestController
--[[
	Tim Cheese intro fall cutscene, quest HUD, claim dialogue, walk-by speech.
]]

local Debris = game:GetService("Debris")
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
		if hiddenPartMods[d] == nil then
			hiddenPartMods[d] = d.LocalTransparencyModifier
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
	for part, prev in hiddenPartMods do
		if part.Parent then
			part.LocalTransparencyModifier = prev
		end
	end
	table.clear(hiddenPartMods)
	for _, d in tim:GetDescendants() do
		if d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = 0
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = true
		elseif d:IsA("Highlight") then
			d.Enabled = true
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
	if idleTrack and idleTrack.IsPlaying then
		return
	end
	StandDialogueCutscene.ensureIdleAnimation(tim, TimCheeseQuestConfig.IDLE_ANIM_NAME)
	local controller = tim:FindFirstChildOfClass("AnimationController")
	local animator = controller and controller:FindFirstChildOfClass("Animator")
	if not animator then
		local hum = tim:FindFirstChildOfClass("Humanoid")
		animator = hum and hum:FindFirstChildOfClass("Animator")
	end
	if not animator then
		return
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
		elseif hasQuest then
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.HAS_QUEST_OVERHEAD)
		elseif not allDone then
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
		else
			setQuestFloatVisible(tim, true, "Tim Cheese")
		end
	end
end

local function ensureQuestHud(): ScreenGui
	if questGui and questGui.Parent then
		return questGui
	end
	local pg = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "TimCheeseQuestHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 82
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local panel = Instance.new("Frame")
	panel.Name = "ObjectivePanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -18, 0, 72)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 22)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 220, 80)
	stroke.Thickness = 2
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 22)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 18
	title.TextColor3 = Color3.fromRGB(255, 230, 90)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "TIM CHEESE QUEST"
	title.LayoutOrder = 1
	title.Parent = panel
	UiFonts.applyDisplayLabel(title, 18, 14)

	local desc = Instance.new("TextLabel")
	desc.Name = "Description"
	desc.BackgroundTransparency = 1
	desc.Size = UDim2.new(1, 0, 0, 0)
	desc.AutomaticSize = Enum.AutomaticSize.Y
	desc.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	desc.TextSize = 15
	desc.TextColor3 = Color3.fromRGB(245, 245, 245)
	desc.TextWrapped = true
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.LayoutOrder = 2
	desc.Parent = panel

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Size = UDim2.new(1, 0, 0, 18)
	progress.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	progress.TextSize = 14
	progress.TextColor3 = Color3.fromRGB(180, 255, 160)
	progress.TextXAlignment = Enum.TextXAlignment.Left
	progress.LayoutOrder = 3
	progress.Parent = panel

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, 0, 0, 10)
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
	barFill.BackgroundColor3 = Color3.fromRGB(90, 220, 110)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	local reward = Instance.new("TextLabel")
	reward.Name = "Reward"
	reward.BackgroundTransparency = 1
	reward.Size = UDim2.new(1, 0, 0, 18)
	reward.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	reward.TextSize = 14
	reward.TextColor3 = Color3.fromRGB(120, 255, 160)
	reward.TextXAlignment = Enum.TextXAlignment.Left
	reward.LayoutOrder = 5
	reward.Parent = panel

	gui.Parent = pg
	questGui = gui
	return gui
end

local function layoutQuestHud()
	local gui = questGui
	if not gui then
		return
	end
	local panel = gui:FindFirstChild("ObjectivePanel")
	if not (panel and panel:IsA("Frame")) then
		return
	end
	local mobile = UserInputService.TouchEnabled
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	if mobile or vw < 700 then
		panel.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.72), 180, 260), 0)
		panel.Position = UDim2.new(1, -12, 0, 64)
	else
		panel.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.28), 360, 480), 0)
		panel.Position = UDim2.new(1, -22, 0, 76)
	end
end

local function refreshQuestHud()
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local progressVal = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	if typeof(idx) ~= "number" or idx < 1 then
		if questGui then
			questGui.Enabled = false
		end
		return
	end
	local quest = TimCheeseQuestConfig.getQuest(math.floor(idx))
	if not quest then
		return
	end
	local gui = ensureQuestHud()
	gui.Enabled = true
	layoutQuestHud()
	local panel = gui:FindFirstChild("ObjectivePanel")
	if not panel then
		return
	end
	local desc = panel:FindFirstChild("Description")
	local progress = panel:FindFirstChild("Progress")
	local reward = panel:FindFirstChild("Reward")
	local barBg = panel:FindFirstChild("BarBg")
	local p = if typeof(progressVal) == "number" then progressVal else 0
	if desc and desc:IsA("TextLabel") then
		desc.Text = if ready then "Quest completed! Go see Tim Cheese." else quest.description
	end
	if progress and progress:IsA("TextLabel") then
		if quest.showBar then
			progress.Text = string.format("%s  %s / %s", quest.title, BrainrotEconomy.formatCashShort(p):gsub("%$", ""), BrainrotEconomy.formatCashShort(quest.target):gsub("%$", ""))
			if quest.kind == "place_stands" or quest.kind == "harvest" then
				progress.Text = string.format("%s  %d / %d", quest.title, math.floor(p), quest.target)
			elseif quest.kind == "income" then
				progress.Text = string.format("%s  %s/s", quest.title, BrainrotEconomy.formatCashShort(p))
			else
				progress.Text = string.format("%s  %s", quest.title, BrainrotEconomy.formatCashShort(p))
			end
		else
			progress.Text = quest.title
		end
	end
	if reward and reward:IsA("TextLabel") then
		reward.Text = "Reward: " .. BrainrotEconomy.formatCashShort(quest.rewardCash)
	end
	if barBg and barBg:IsA("Frame") then
		barBg.Visible = quest.showBar == true
		local fill = barBg:FindFirstChild("BarFill")
		if fill and fill:IsA("Frame") then
			local alpha = math.clamp(p / math.max(quest.target, 1), 0, 1)
			fill.Size = UDim2.new(alpha, 0, 1, 0)
		end
	end
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
		hum.WalkSpeed = 16
		hum.UseJumpPower = true
		hum.JumpPower = 50
	end
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

	local land = landCf.Position
	local start = land + Vector3.new(0, TimCheeseQuestConfig.DROP_HEIGHT, 0)
	local rotOnly = landCf - landCf.Position
	clone:PivotTo(CFrame.new(start) * rotOnly)

	local cam = Workspace.CurrentCamera
	local savedType = cam and cam.CameraType
	local savedSubject = cam and cam.CameraSubject
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	-- Fire early so zone poll / Touched can't restart while attribute replicates.
	local introRE = getRE("IntroDone")
	if introRE then
		introRE:FireServer()
	end

	local alpha = Instance.new("NumberValue")
	alpha.Value = 0
	local tween = TweenService:Create(
		alpha,
		TweenInfo.new(TimCheeseQuestConfig.FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Value = 1 }
	)
	local conn = RunService.RenderStepped:Connect(function()
		local t = alpha.Value
		local y = start.Y + (land.Y - start.Y) * (t * t)
		local pos = Vector3.new(land.X, y, land.Z)
		local sway = math.sin(t * 22) * (1 - t) * 1.6
		if clone.Parent then
			clone:PivotTo(CFrame.new(pos + Vector3.new(sway, 0, 0)) * rotOnly)
		end
		if cam then
			-- Worm's-eye: camera near the landing pad looking UP at Tim.
			local camPos = Vector3.new(land.X + 11, land.Y + 2.5, land.Z + 13)
			cam.CFrame = CFrame.lookAt(camPos, pos + Vector3.new(0, 1.5, 0))
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
	pulseCameraShake(0.85, 0.95)
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

	-- After intro talk, offer first quest (accept/decline).
	local accepted = StandDialogueCutscene.play({
		standName = "TimCheese",
		frameKey = "TimCheese",
		brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
		enterLabel = "ACCEPT QUEST",
		exitLabel = "DECLINE",
		lines = TimCheeseQuestConfig.OFFER_LINES,
		voicePitchMin = 0.92,
		voicePitchMax = 1.12,
	}, clone)

	if accepted then
		local rf = getRF("AcceptQuest")
		if rf then
			pcall(function()
				rf:InvokeServer()
			end)
		end
		TopNotifController.showBroadcast("New quest from Tim Cheese!")
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
	revealTimForIntro(tim)
	ensureIdle(tim)

	if cam then
		cam.CameraType = savedType or Enum.CameraType.Custom
		cam.CameraSubject = savedSubject
	end

	GameplayUiVisibility.show()
	lockMovement(false)
	introPlaying = false
	setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
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
				lines = TimCheeseQuestConfig.OFFER_LINES,
				voicePitchMin = 0.92,
				voicePitchMax = 1.12,
			}, tim)
			if wantAnother then
				local acceptRF = getRF("AcceptQuest")
				if acceptRF then
					pcall(function()
						acceptRF:InvokeServer()
					end)
				end
				TopNotifController.showBroadcast("New quest from Tim Cheese!")
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
			lines = TimCheeseQuestConfig.OFFER_LINES,
			voicePitchMin = 0.92,
			voicePitchMax = 1.12,
		}, tim)
		if want then
			local acceptRF = getRF("AcceptQuest")
			if acceptRF then
				pcall(function()
					acceptRF:InvokeServer()
				end)
			end
			TopNotifController.showBroadcast("New quest from Tim Cheese!")
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
