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
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))

local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local TopNotifController = require(script.Parent.TopNotifController)
local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

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
local questGui: ScreenGui? = nil -- persistent tracker ScreenGui
local questHost: Frame? = nil -- root under questGui
local questPanel: GuiObject? = nil
local forcedQuestIndex: number? = nil
local acceptPopupGui: ScreenGui? = nil
local questDotsConn: RBXScriptConnection? = nil
local questDotsPhase = 0.0
local questExclaimConn: RBXScriptConnection? = nil
local questHudRevealed = false
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
			-- Harder kick at the start, then rumble out.
			local punch = 1 + (fade * fade) * 1.35
			hum.CameraOffset = Vector3.new(
				math.sin(t * 52) * amp * fade * punch,
				math.cos(t * 41) * amp * 0.75 * fade * punch,
				math.sin(t * 29) * amp * 0.25 * fade
			)
			RunService.RenderStepped:Wait()
		end
		if hum.Parent then
			hum.CameraOffset = Vector3.zero
		end
	end)
end

local function landImpactShake(cam: Camera?)
	pulseCameraShake(1.15, 1.85)
	if not cam then
		return
	end
	local startFov = cam.FieldOfView
	local punchFov = math.clamp(startFov + 9, 55, 85)
	cam.FieldOfView = punchFov
	TweenService:Create(cam, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FieldOfView = startFov,
	}):Play()
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
	ring.Size = Vector3.new(0.4, 3, 3)
	ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 24, 24),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)

	-- Second dust ring
	local ring2 = ring:Clone()
	ring2.Size = Vector3.new(0.25, 2, 2)
	ring2.Color = Color3.fromRGB(40, 110, 45)
	ring2.Parent = Workspace
	TweenService:Create(ring2, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, 32, 32),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring2, 0.75)

	for i = 1, 72 do
		local chip = Instance.new("Part")
		chip.Name = "TimLandingChip"
		local scale = 0.85 + math.random() * 2.1
		chip.Size = Vector3.new(0.9, 0.55, 1.15) * scale
		local roll = i % 5
		chip.Color = if roll == 0
			then Color3.fromRGB(48, 140, 52)
			elseif roll == 1 then Color3.fromRGB(90, 70, 40)
			elseif roll == 2 then Color3.fromRGB(70, 175, 65)
			else ROCK_GREEN
		chip.Material = if roll == 1 then Enum.Material.Slate else Enum.Material.Grass
		chip.Anchored = true
		chip.CanCollide = false
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		local ang = math.rad(i * (360 / 72) + math.random() * 8)
		chip.CFrame = CFrame.new(pos + Vector3.new(0, 0.35, 0)) * CFrame.Angles(ang, ang * 0.5, 0)
		chip.Parent = Workspace
		local dir = Vector3.new(math.cos(ang), 0.45 + math.random() * 0.95, math.sin(ang)).Unit
		local goal = pos + dir * (6 + math.random() * 12) + Vector3.new(0, 2 + math.random() * 4.5, 0)
		TweenService:Create(chip, TweenInfo.new(0.55 + math.random() * 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(goal) * CFrame.Angles(math.random() * 4, math.random() * 4, math.random() * 4),
			Transparency = 1,
			Size = chip.Size * 0.2,
		}):Play()
		Debris:AddItem(chip, 1.05)
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
		existing.Style = Enum.ProximityPromptStyle.Custom
		existing:SetAttribute("CustomPromptFX", true)
		pcall(function()
			ProximityPromptEffects.stylePrompt(existing)
		end)
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
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("CustomPromptFX", true)
	prompt.Parent = part
	talkPrompt = prompt
	pcall(function()
		ProximityPromptEffects.stylePrompt(prompt)
	end)
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
			-- Keep prompt up mid-mission so players can check in (world speech, no cutscene).
			talkPrompt.Enabled = true
			if ready then
				talkPrompt.ActionText = "Claim"
			elseif hasQuest then
				talkPrompt.ActionText = "Talk"
			elseif allDone then
				talkPrompt.ActionText = "Talk"
			else
				talkPrompt.ActionText = "Quests"
			end
		end
		setOutline(tim, ready == true)
		if ready then
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.READY_OVERHEAD)
		elseif hasQuest then
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.HAS_QUEST_OVERHEAD)
		else
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
		end
	end
end

local function ensureQuestHost(): Frame?
	-- Same placement as tutorial objective: under PlayerGui.Main so it sits on the HUD.
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return nil
	end
	if main:IsA("ScreenGui") then
		questGui = main
		main.Enabled = true
	end
	local existing = main:FindFirstChild("TimCheeseQuestHost")
	if existing and existing:IsA("Frame") then
		questHost = existing
		existing.Visible = true
		return existing
	end
	local created = Instance.new("Frame")
	created.Name = "TimCheeseQuestHost"
	created.BackgroundTransparency = 1
	created.BorderSizePixel = 0
	created.Size = UDim2.fromScale(1, 1)
	created.Position = UDim2.fromScale(0, 0)
	created.AnchorPoint = Vector2.new(0, 0)
	created.ZIndex = 90
	created.ClipsDescendants = false
	created.Active = false
	created.Visible = true
	created.Parent = main
	questHost = created
	return created
end

local function stopQuestDots()
	if questDotsConn then
		questDotsConn:Disconnect()
		questDotsConn = nil
	end
	questDotsPhase = 0
	if questPanel then
		local dots = questPanel:FindFirstChild("ObjectiveDots", true)
		if dots and dots:IsA("TextLabel") then
			dots.Text = ""
		end
	end
end

local function stopExclaimPulse()
	if questExclaimConn then
		questExclaimConn:Disconnect()
		questExclaimConn = nil
	end
end

local function startExclaimPulse()
	stopExclaimPulse()
	questExclaimConn = RunService.RenderStepped:Connect(function()
		if not questPanel or not questPanel.Visible or not questPanel.Parent then
			return
		end
		local bang = questPanel:FindFirstChild("Exclaim", true)
		if not (bang and bang:IsA("ImageLabel")) then
			return
		end
		local t = os.clock()
		local sc = bang:FindFirstChild("BangScale")
		if sc and sc:IsA("UIScale") then
			sc.Scale = 1
		end
		bang.Rotation = -10
		bang.ImageTransparency = 0
		-- Soft vertical hover only.
		bang.Position = UDim2.fromOffset(0, -2 + math.sin(t * 2.2) * 2)
	end)
end

local function startQuestDots()
	stopQuestDots()
	startExclaimPulse()
	questDotsConn = RunService.Heartbeat:Connect(function(dt)
		if not questPanel or not questPanel.Visible or not questPanel.Parent then
			return
		end
		local dots = questPanel:FindFirstChild("ObjectiveDots", true)
		if not (dots and dots:IsA("TextLabel")) then
			return
		end
		questDotsPhase += dt
		local step = math.floor(questDotsPhase * 2.2) % 4
		dots.Text = string.rep(".", step)
	end)
end

-- Stud tile baked onto ImageLabels. Never use Scale Y overlays inside AutomaticSize
-- frames — that stretches the panel to the full screen.
local function paintStudImage(label: ImageLabel, color: Color3, imageTransparency: number)
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0
	label.BorderSizePixel = 0
	label.Image = TimCheeseQuestConfig.STUD_TEXTURE
	label.ImageColor3 = Color3.fromRGB(120, 80, 20)
	label.ImageTransparency = imageTransparency
	label.ScaleType = Enum.ScaleType.Tile
	label.TileSize = UDim2.fromOffset(28, 28)
end

-- Safe on fixed-height parents only (e.g. progress bar).
local function addStudOverlay(parent: GuiObject, z: number, transparency: number?)
	local existing = parent:FindFirstChild("StudOverlay")
	if existing then
		existing:Destroy()
	end
	local studs = Instance.new("ImageLabel")
	studs.Name = "StudOverlay"
	studs.BackgroundTransparency = 1
	studs.BorderSizePixel = 0
	studs.Size = UDim2.fromScale(1, 1)
	studs.Position = UDim2.fromScale(0, 0)
	studs.Image = TimCheeseQuestConfig.STUD_TEXTURE
	studs.ImageColor3 = Color3.fromRGB(120, 80, 20)
	studs.ImageTransparency = if typeof(transparency) == "number" then transparency else 0.72
	studs.ScaleType = Enum.ScaleType.Tile
	studs.TileSize = UDim2.fromOffset(28, 28)
	studs.ZIndex = z
	studs.Parent = parent
	return studs
end

local function ensureQuestHud(): GuiObject
	if questPanel and questPanel.Parent then
		if questPanel:GetAttribute("StudTicket") == true then
			return questPanel
		end
		questPanel:Destroy()
		questPanel = nil
	end
	local host = ensureQuestHost()
	assert(host, "TimCheeseQuestHost missing")

	local ticket = Instance.new("ImageLabel")
	ticket.Name = "ObjectivePanel"
	ticket.AnchorPoint = Vector2.new(1, 0)
	ticket.Position = UDim2.new(1, -TutorialConfig.PANEL_RIGHT_PAD, 0, TutorialConfig.PANEL_TOP_PAD + 36)
	ticket.Size = UDim2.fromOffset(300, 0)
	ticket.AutomaticSize = Enum.AutomaticSize.Y
	paintStudImage(ticket, Color3.fromRGB(255, 214, 74), 0.78)
	ticket:SetAttribute("StudTicket", true)
	ticket.Visible = false
	ticket.ZIndex = 100
	ticket.ClipsDescendants = true
	ticket.Parent = host

	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 6)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Name = "TicketStroke"
	ticketStroke.Color = Color3.fromRGB(40, 28, 8)
	ticketStroke.Thickness = 3.5
	ticketStroke.Parent = ticket
	local ticketScale = Instance.new("UIScale")
	ticketScale.Name = "PanelScale"
	ticketScale.Scale = 1
	ticketScale.Parent = ticket

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = ticket

	local inner = Instance.new("ImageLabel")
	inner.Name = "Inner"
	paintStudImage(inner, Color3.fromRGB(255, 244, 180), 0.82)
	inner.Size = UDim2.new(1, 0, 0, 0)
	inner.AutomaticSize = Enum.AutomaticSize.Y
	inner.ZIndex = 101
	inner.ClipsDescendants = true
	inner.Parent = ticket
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 4)
	innerCorner.Parent = inner
	local dash = Instance.new("UIStroke")
	dash.Name = "InnerStroke"
	dash.Color = Color3.fromRGB(180, 120, 30)
	dash.Thickness = 1.5
	dash.Transparency = 0.35
	dash.Parent = inner
	local innerPad = Instance.new("UIPadding")
	innerPad.PaddingTop = UDim.new(0, 10)
	innerPad.PaddingBottom = UDim.new(0, 10)
	innerPad.PaddingLeft = UDim.new(0, 10)
	innerPad.PaddingRight = UDim.new(0, 10)
	innerPad.Parent = inner
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = inner

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 40)
	header.LayoutOrder = 1
	header.ZIndex = 102
	header.Parent = inner

	local bang = Instance.new("ImageLabel")
	bang.Name = "Exclaim"
	bang.BackgroundTransparency = 1
	bang.Position = UDim2.fromOffset(0, -2)
	bang.Size = UDim2.fromOffset(36, 36)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.Rotation = -10
	bang.ZIndex = 103
	bang.Parent = header

	local stamp = Instance.new("TextLabel")
	stamp.Name = "Stamp"
	stamp.BackgroundTransparency = 1
	stamp.Position = UDim2.fromOffset(42, 0)
	stamp.Size = UDim2.new(1, -42, 0, 16)
	stamp.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	stamp.TextSize = 12
	stamp.TextColor3 = Color3.fromRGB(160, 40, 30)
	stamp.TextXAlignment = Enum.TextXAlignment.Left
	stamp.Text = "TIM CHEESE JOB"
	stamp.ZIndex = 103
	stamp.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(42, 16)
	title.Size = UDim2.new(1, -42, 0, 22)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 16
	title.TextColor3 = Color3.fromRGB(30, 24, 10)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = ""
	title.ZIndex = 103
	title.Parent = header
	UiFonts.applyDisplayLabel(title, 16, 13)

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	body.TextSize = 13
	body.TextColor3 = Color3.fromRGB(55, 42, 18)
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.Text = ""
	body.LayoutOrder = 2
	body.ZIndex = 102
	body.Parent = inner

	local progressRow = Instance.new("Frame")
	progressRow.Name = "ProgressRow"
	progressRow.BackgroundTransparency = 1
	progressRow.Size = UDim2.new(1, 0, 0, 18)
	progressRow.LayoutOrder = 3
	progressRow.ZIndex = 102
	progressRow.Parent = inner

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Size = UDim2.new(1, -30, 1, 0)
	progress.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	progress.TextSize = 13
	progress.TextColor3 = Color3.fromRGB(40, 110, 40)
	progress.TextXAlignment = Enum.TextXAlignment.Left
	progress.Text = ""
	progress.ZIndex = 103
	progress.Parent = progressRow

	local dots = Instance.new("TextLabel")
	dots.Name = "ObjectiveDots"
	dots.BackgroundTransparency = 1
	dots.AnchorPoint = Vector2.new(1, 0.5)
	dots.Position = UDim2.new(1, 0, 0.5, 0)
	dots.Size = UDim2.fromOffset(26, 16)
	dots.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	dots.TextSize = 13
	dots.TextColor3 = Color3.fromRGB(40, 110, 40)
	dots.TextXAlignment = Enum.TextXAlignment.Left
	dots.Text = ""
	dots.ZIndex = 103
	dots.Parent = progressRow

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, 0, 0, 10)
	barBg.BackgroundColor3 = Color3.fromRGB(210, 170, 70)
	barBg.BackgroundTransparency = 0
	barBg.BorderSizePixel = 0
	barBg.LayoutOrder = 4
	barBg.ZIndex = 102
	barBg.ClipsDescendants = true
	barBg.Parent = inner
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = barBg
	addStudOverlay(barBg, 102, 0.55)
	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
	barFill.BorderSizePixel = 0
	barFill.ZIndex = 104
	barFill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill
	addStudOverlay(barFill, 104, 0.65)

	local payout = Instance.new("TextLabel")
	payout.Name = "Reward"
	payout.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
	payout.BackgroundTransparency = 0
	payout.Size = UDim2.new(1, 0, 0, 26)
	payout.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	payout.TextSize = 13
	payout.TextColor3 = Color3.fromRGB(255, 220, 80)
	payout.Text = ""
	payout.LayoutOrder = 5
	payout.ZIndex = 102
	payout.Parent = inner
	local payCorner = Instance.new("UICorner")
	payCorner.CornerRadius = UDim.new(0, 8)
	payCorner.Parent = payout

	questPanel = ticket
	return ticket
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
	local rightPad = TutorialConfig.PANEL_RIGHT_PAD
	-- PC: sit lower than tutorial so it doesn't crowd the top chrome.
	local topPad = TutorialConfig.PANEL_TOP_PAD + insetY + 58
	local screenW: number
	if mobile or vw < 700 then
		local maxW = math.floor(vw * TutorialConfig.PANEL_MOBILE_MAX_WIDTH_FRAC)
		screenW = math.clamp(maxW, TutorialConfig.PANEL_MOBILE_MIN_WIDTH, TutorialConfig.PANEL_MOBILE_MAX_WIDTH)
		topPad = insetY + 18
		rightPad = 10
	else
		local maxW = math.floor(vw * TutorialConfig.PANEL_MAX_WIDTH_FRAC)
		maxW = math.clamp(maxW, TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_MAX_WIDTH)
		screenW = math.clamp(maxW, TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_MAX_WIDTH)
	end
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Size = UDim2.fromOffset(screenW, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Position = UDim2.new(1, -rightPad, 0, topPad)
	panel.ZIndex = 100
end

local function hudSlotPosition(): UDim2
	layoutQuestHud()
	if questPanel then
		return questPanel.Position
	end
	local insetY = GuiService:GetGuiInset().Y
	return UDim2.new(1, -TutorialConfig.PANEL_RIGHT_PAD, 0, TutorialConfig.PANEL_TOP_PAD + insetY + 58)
end

local function resolveActiveQuestIndex(): number?
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(idx) == "number" and idx >= 1 then
		forcedQuestIndex = nil
		return math.floor(idx)
	end
	if typeof(forcedQuestIndex) == "number" and forcedQuestIndex >= 1 then
		return forcedQuestIndex
	end
	return nil
end

local function formatQuestProgress(quest: TimCheeseQuestConfig.QuestDef, p: number): string
	if quest.kind == "place_stands" or quest.kind == "harvest" then
		return string.format("%d / %d", math.floor(p), quest.target)
	elseif quest.kind == "income" then
		return string.format("%s/s  goal %s/s", BrainrotEconomy.formatCashShort(p), BrainrotEconomy.formatCashShort(quest.target))
	else
		return string.format("%s / %s", BrainrotEconomy.formatCashShort(p), BrainrotEconomy.formatCashShort(quest.target))
	end
end

local function refreshQuestHud(opts: { skipRevealGate: boolean?, playAppear: boolean? }?)
	local idx = resolveActiveQuestIndex()
	local progressVal = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	local skipGate = opts ~= nil and opts.skipRevealGate == true
	local playAppear = opts ~= nil and opts.playAppear == true
	if not idx then
		stopQuestDots()
		stopExclaimPulse()
		questHudRevealed = false
		if questPanel then
			questPanel.Visible = false
		end
		return
	end
	-- Gate: only after accept fly-in, or rejoin init that set questHudRevealed.
	-- Do NOT auto-reveal on server index — that raced the center→HUD fly.
	if not questHudRevealed and not skipGate then
		return
	end

	local quest = TimCheeseQuestConfig.getQuest(idx)
	if not quest then
		return
	end
	local panel = ensureQuestHud()
	layoutQuestHud()
	local wasHidden = not panel.Visible
	panel.Visible = true

	local p = if typeof(progressVal) == "number" then progressVal else 0
	local title = panel:FindFirstChild("Title", true)
	local body = panel:FindFirstChild("Body", true)
	local progress = panel:FindFirstChild("Progress", true)
	local barBg = panel:FindFirstChild("BarBg", true)
	local reward = panel:FindFirstChild("Reward", true)
	local stamp = panel:FindFirstChild("Stamp", true)

	if stamp and stamp:IsA("TextLabel") then
		stamp.Text = if ready then "READY TO CLAIM" else "TIM CHEESE JOB"
		stamp.TextColor3 = if ready then Color3.fromRGB(30, 120, 50) else Color3.fromRGB(160, 40, 30)
	end
	if title and title:IsA("TextLabel") then
		title.Text = quest.title
		title.TextColor3 = Color3.fromRGB(30, 24, 10)
	end
	if body and body:IsA("TextLabel") then
		body.Text = if ready then "Talk to Tim Cheese to cash out!" else quest.description
		body.TextColor3 = Color3.fromRGB(55, 42, 18)
	end
	if progress and progress:IsA("TextLabel") then
		progress.Text = if ready then "COMPLETE" elseif quest.showBar then formatQuestProgress(quest, p) else "In progress"
		progress.TextColor3 = Color3.fromRGB(40, 110, 40)
		progress.Visible = true
	end
	if barBg and barBg:IsA("Frame") then
		barBg.Visible = quest.showBar == true and not ready
		local fill = barBg:FindFirstChild("BarFill")
		if fill and fill:IsA("Frame") then
			local alpha = math.clamp(p / math.max(quest.target, 1), 0, 1)
			local goal = UDim2.new(alpha, 0, 1, 0)
			if wasHidden then
				fill.Size = goal
			else
				TweenService:Create(fill, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = goal }):Play()
			end
		end
	end
	if reward and reward:IsA("TextLabel") then
		reward.Text = "★  " .. BrainrotEconomy.formatCashShort(quest.rewardCash)
		reward.TextColor3 = Color3.fromRGB(255, 220, 80)
		reward.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
		reward.BackgroundTransparency = 0
	end

	startQuestDots()
	if (wasHidden or playAppear) and questHudRevealed then
		local sc = panel:FindFirstChild("PanelScale")
		if sc and sc:IsA("UIScale") then
			sc.Scale = 0.7
			TweenService:Create(sc, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
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

	-- Build HUD hidden first so we know the slot to fly into.
	ensureQuestHud()
	layoutQuestHud()
	if questPanel then
		questPanel.Visible = false
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TimCheeseQuestHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 120
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg
	acceptPopupGui = gui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(12, 18, 10)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = gui

	local ticket = Instance.new("Frame")
	ticket.Name = "CheeseTicket"
	ticket.AnchorPoint = Vector2.new(0.5, 0.5)
	ticket.Position = UDim2.fromScale(0.5, 0.46)
	ticket.Size = UDim2.fromOffset(390, 168)
	ticket.BackgroundColor3 = Color3.fromRGB(255, 214, 74)
	ticket.BackgroundTransparency = 0.08
	ticket.BorderSizePixel = 0
	ticket.Rotation = -7
	ticket.Parent = gui
	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 10)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Color = Color3.fromRGB(255, 236, 150)
	ticketStroke.Thickness = 3
	ticketStroke.Transparency = 0.15
	ticketStroke.Parent = ticket

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.BackgroundColor3 = Color3.fromRGB(255, 244, 180)
	inner.BackgroundTransparency = 0.12
	inner.BorderSizePixel = 0
	inner.Position = UDim2.fromOffset(10, 10)
	inner.Size = UDim2.new(1, -20, 1, -20)
	inner.Parent = ticket
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 7)
	innerCorner.Parent = inner
	local dash = Instance.new("UIStroke")
	dash.Color = Color3.fromRGB(255, 210, 80)
	dash.Thickness = 1.6
	dash.Transparency = 0.35
	dash.Parent = inner

	local bang = Instance.new("ImageLabel")
	bang.Name = "Bang"
	bang.BackgroundTransparency = 1
	bang.Position = UDim2.fromOffset(10, 18)
	bang.Size = UDim2.fromOffset(54, 54)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.Rotation = -12
	bang.Parent = inner
	local bangScale = Instance.new("UIScale")
	bangScale.Scale = 1
	bangScale.Parent = bang

	local stamp = Instance.new("TextLabel")
	stamp.BackgroundTransparency = 1
	stamp.Position = UDim2.fromOffset(70, 12)
	stamp.Size = UDim2.new(1, -84, 0, 22)
	stamp.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	stamp.TextSize = 18
	stamp.TextColor3 = Color3.fromRGB(160, 40, 30)
	stamp.TextXAlignment = Enum.TextXAlignment.Left
	stamp.Text = "JOB LOCKED IN"
	stamp.Rotation = 1
	stamp.Parent = inner

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(70, 38)
	title.Size = UDim2.new(1, -84, 0, 28)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(30, 24, 10)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = quest.title
	title.Parent = inner
	UiFonts.applyDisplayLabel(title, 22, 16)

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, 78)
	body.Size = UDim2.new(1, -32, 0, 40)
	body.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	body.TextSize = 14
	body.TextColor3 = Color3.fromRGB(55, 42, 18)
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.Text = quest.description
	body.Parent = inner

	local payout = Instance.new("TextLabel")
	payout.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
	payout.BackgroundTransparency = 0.25
	payout.AnchorPoint = Vector2.new(1, 1)
	payout.Position = UDim2.new(1, -10, 1, -10)
	payout.Size = UDim2.fromOffset(128, 28)
	payout.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	payout.TextSize = 14
	payout.TextColor3 = Color3.fromRGB(255, 220, 80)
	payout.Text = "★  " .. BrainrotEconomy.formatCashShort(quest.rewardCash)
	payout.Parent = inner
	local payCorner = Instance.new("UICorner")
	payCorner.CornerRadius = UDim.new(0, 8)
	payCorner.Parent = payout

	local ticketScale = Instance.new("UIScale")
	ticketScale.Scale = 0.55
	ticketScale.Parent = ticket

	local mobile = UserInputService.TouchEnabled
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	if mobile or vw < 700 then
		ticket.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.88), 280, 360), 168)
	end

	-- Pulse bang while centered.
	local pulseToken = 0
	pulseToken += 1
	local myPulse = pulseToken
	task.spawn(function()
		while myPulse == pulseToken and bang.Parent do
			local t = os.clock()
			bangScale.Scale = 1
			bang.Rotation = -12
			bang.Position = UDim2.fromOffset(10, 18 + math.sin(t * 2.2) * 2.5)
			RunService.RenderStepped:Wait()
		end
	end)

	TweenService:Create(dim, TweenInfo.new(0.18), { BackgroundTransparency = 0.55 }):Play()
	TweenService:Create(ticketScale, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(ticket, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = -3 }):Play()
	GameSoundEffects.playPurchase()

	task.wait(1.85)
	if not gui.Parent then
		return
	end

	-- Fly into HUD slot (stays solid cheese ticket).
	pulseToken += 1
	local slot = hudSlotPosition()
	local flyInfo = TweenInfo.new(0.58, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	TweenService:Create(dim, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(ticket, flyInfo, {
		AnchorPoint = Vector2.new(1, 0),
		Position = slot,
		Rotation = 0,
	}):Play()
	TweenService:Create(ticketScale, flyInfo, { Scale = 0.42 }):Play()
	task.wait(0.6)

	if gui.Parent then
		gui:Destroy()
	end
	if acceptPopupGui == gui then
		acceptPopupGui = nil
	end

	questHudRevealed = true
	refreshQuestHud({ skipRevealGate = true, playAppear = true })
end

local function safeScaleTo(model: Model, scale: number)
	pcall(function()
		model:ScaleTo(scale)
	end)
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
	safeScaleTo(clone, 2.65)
	clone:PivotTo(CFrame.new(start) * rotOnly)
	-- Idle plays through fall + talk (TimCheese brainrot anim).
	ensureIdle(clone)

	local cam = Workspace.CurrentCamera
	local savedType = cam and cam.CameraType
	local savedSubject = cam and cam.CameraSubject
	local savedFov = cam and cam.FieldOfView
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = 58
	end

	local alpha = Instance.new("NumberValue")
	alpha.Value = 0
	local tween = TweenService:Create(
		alpha,
		TweenInfo.new(TimCheeseQuestConfig.FALL_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Value = 1 }
	)
	-- Farther worm's-eye — see the whole zip fall.
	local camPos = Vector3.new(land.X + 18, land.Y + 2.8, land.Z + 20)
	local lastScale = 2.65
	local conn = RunService.RenderStepped:Connect(function()
		local t = alpha.Value
		local y = start.Y + (land.Y - start.Y) * (t * t)
		local pos = Vector3.new(land.X, y, land.Z)
		local sway = math.sin(t * 28) * (1 - t) * 1.1
		-- Pokemon-style: oversized spin that shrinks into place.
		local scale = 2.65 - (1.65 * t)
		if math.abs(scale - lastScale) > 0.03 then
			safeScaleTo(clone, scale)
			lastScale = scale
		end
		local spin = CFrame.Angles(
			math.rad(math.sin(t * 18) * 35 * (1 - t)),
			math.rad(t * 720),
			math.rad(math.cos(t * 14) * 28 * (1 - t))
		)
		if clone.Parent then
			clone:PivotTo(CFrame.new(pos + Vector3.new(sway, 0, 0)) * rotOnly * spin)
		end
		if cam then
			cam.CFrame = CFrame.lookAt(camPos, pos + Vector3.new(0, 2.2, 0))
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
	safeScaleTo(clone, 1)
	if clone.Parent then
		clone:PivotTo(landCf)
	end
	spawnLandingDebris(land, clone)
	GameSoundEffects.playGroundSmash(1)
	landImpactShake(cam)
	ensureIdle(clone)
	setBgmSlowed(false)

	-- Beat to land / settle before he starts talking.
	task.wait(1.0)

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
		-- Optimistic: keep tracker up even if attribute replication lags.
		forcedQuestIndex = 1
		local rf = getRF("AcceptQuest")
		if rf then
			local ok, result = pcall(function()
				return rf:InvokeServer()
			end)
			if not ok then
				warn("[TimCheeseQuestController] AcceptQuest error:", result)
			elseif result ~= true then
				warn("[TimCheeseQuestController] AcceptQuest rejected")
			end
		else
			warn("[TimCheeseQuestController] AcceptQuest remote missing")
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
		forcedQuestIndex = forcedQuestIndex or 1
		questHudRevealed = false
		local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex)
		if q then
			-- Center ticket → flies into right HUD slot.
			playQuestAcceptPopup(q)
		else
			questHudRevealed = true
			refreshQuestHud({ skipRevealGate = true, playAppear = true })
		end
		waitForQuestHud(3)
		refreshQuestHud()
		TopNotifController.showBroadcast("New quest from Tim Cheese!")
	end
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

	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local hasQuest = typeof(idx) == "number" and idx >= 1
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then completed else 0

	-- Mid-mission: custom prompt → bubble only (no cutscene cam).
	if hasQuest and not ready then
		local lines = TimCheeseQuestConfig.IN_PROGRESS_LINES
		local msg = lines[math.random(1, #lines)]
		StandDialogueCutscene.showWorldSpeech(tim, msg, {
			durationSec = 2.8,
			voicePitchMin = 0.92,
			voicePitchMax = 1.12,
		})
		return
	end

	dialogueBusy = true
	setQuestFloatVisible(tim, false)
	setOutline(tim, false)

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
		forcedQuestIndex = nil
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
				forcedQuestIndex = doneAfter + 1
				questHudRevealed = false
				local acceptRF = getRF("AcceptQuest")
				if acceptRF then
					pcall(function()
						return acceptRF:InvokeServer()
					end)
				end
				local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex)
				if q then
					playQuestAcceptPopup(q)
				end
				TopNotifController.showBroadcast("New quest from Tim Cheese!")
				waitForQuestHud(3)
				refreshQuestHud()
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
			forcedQuestIndex = doneCount + 1
			questHudRevealed = false
			local acceptRF = getRF("AcceptQuest")
			if acceptRF then
				pcall(function()
					return acceptRF:InvokeServer()
				end)
			end
			local q = TimCheeseQuestConfig.getQuest(forcedQuestIndex)
			if q then
				playQuestAcceptPopup(q)
			end
			TopNotifController.showBroadcast("New quest from Tim Cheese!")
			waitForQuestHud(3)
			refreshQuestHud()
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
			local liveIdx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
			if typeof(liveIdx) == "number" and liveIdx >= 1 then
				questHudRevealed = true
			end
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
