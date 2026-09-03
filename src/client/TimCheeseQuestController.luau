-- [ACTIVE] TimCheeseQuestController
--[[
	Tim Cheese quest HUD, claim dialogue, walk-by speech.
	Quests auto-start after tutorial once the starter lucky block is opened
	(quest appearance popup; no Tim fall cutscene). Falls back if they never open it.
]]

local ContextActionService = game:GetService("ContextActionService")
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
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))

local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local GameplayCutsceneGate = require(script.Parent.GameplayCutsceneGate)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local TopNotifController = require(script.Parent.TopNotifController)
local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local GamepadInput = require(script.Parent.GamepadInput)

local function setBushPromptsHiddenForIntro(hidden: boolean)
	-- Lazy require avoids circular load with BushHoldInteraction → TimCheeseQuestController.
	local ok, BushHoldInteraction = pcall(function()
		return require(script.Parent.BushHoldInteraction)
	end)
	if not ok or not BushHoldInteraction then
		warn("[TimCheeseQuestController] BushHoldInteraction require failed:", BushHoldInteraction)
		ProximityPromptEffects.hideBushSearch()
		return
	end
	BushHoldInteraction.setBushSearchLocked(hidden == true)
	if hidden then
		ProximityPromptEffects.hideBushSearch()
	end
end

local player = Players.LocalPlayer
local M = {}
local wired = false

local homePivot: CFrame? = nil
local timModel: Model? = nil
local questHitbox: BasePart? = nil
local introPlaying = false
local introStartedLocal = false -- never restart fall once begun (attribute can lag)
local introDialogueSkip = false
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
local questHudBaseRightPad = TutorialConfig.PANEL_RIGHT_PAD
local questHudBaseTop = TutorialConfig.PANEL_TOP_PAD
local questHudAnchorY = 0
local questHoverFlying = false
local questLayoutAccum = 0.0
local questLayoutConn: RBXScriptConnection? = nil
local QUEST_LAYOUT_HZ = if UserInputService.TouchEnabled then 2 else 8
local questHudSuppressed = false
local questHudCollapsed = false
local questAnimBusy = false
local questCollapseTween: Tween? = nil
local questArrowTween: Tween? = nil
local questPanelScaleTween: Tween? = nil
local questArrowBlendTween: Tween? = nil
local questArrowBlendValue: NumberValue? = nil
local questArrowFollowConn: RBXScriptConnection? = nil
local questHoverBang: ImageLabel? = nil
local questFloatWrap: GuiObject? = nil
local questBangPulseGen = 0
local promptLockedUntil = 0.0
local COLLAPSE_ARROW_IMAGE = "rbxassetid://128709527394819"
local COLLAPSE_ARROW_SIZE = 30
local questArrowBtn: ImageButton? = nil
local questArrowScale: UIScale? = nil
local questArrowPulseTween: Tween? = nil
local questParkedArrowY = 0
-- Same easing family as TutorialController panel open/hide.
local QUEST_PANEL_OPEN = TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local QUEST_PANEL_SWAP = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUEST_FLOAT_BOB = TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local QUEST_BANG_IDLE = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local QUEST_FLOAT_BOB_PX = 7
local QUEST_SLIDE_PX = 96
-- Distinct from Shop Stand (0.88–1.2) / Sell (deep) / Upgrade (1.2–1.55).
local TIM_VOICE_PITCH_MIN = 1.48
local TIM_VOICE_PITCH_MAX = 1.82
local TIM_LETTER_DELAY = 0.018
local TIM_LINE_HOLD = 0.55
local TIM_LINE_HOLD_SHAKE = 0.7
local INTRO_CUTSCENE_HIDE_OPTS = {
	keepScreenGuiNames = { "StandDialogueCutscene" },
	hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker" },
	hideMainChildNames = { "TimCheeseQuestHost" },
}
-- Space between quest ticket bottom and RandomBrainrot top (rest pose, not hover-scaled).
local QUEST_GAP_ABOVE_RB = 28
local QUEST_EDGE_SLIDE = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUEST_ARROW_EDGE_PAD = 8
local toggleQuestHudCollapsed: () -> ()
local layoutQuestHud: () -> ()
local placeArrowOnTicket: () -> ()
local placeArrowParked: () -> ()
local startArrowPulse: () -> ()
local stopArrowPulse: () -> ()
local stopExclaimPulse: () -> ()
local stopQuestDots: () -> ()
local recoverCollapseArrow: () -> ImageButton?
local refreshQuestHud: (opts: { skipRevealGate: boolean?, playAppear: boolean? }?) -> ()
local highlight: Highlight? = nil
local lastOutlineOn: boolean? = nil
local lastPromptAction: string? = nil
local lastFloatText: string? = nil
local lastPromptEnabled: boolean? = nil
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

local introMouseLookX = 0
local introMouseLookY = 0
local introTouchPanX = 0
local introTouchPanY = 0
local introTouchPanConn: RBXScriptConnection? = nil
local introJumpToken = 0
local introJumpBasePivot: CFrame? = nil
local introJumpActive = false

local function flatUnit(from: Vector3, to: Vector3): Vector3
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function resetIntroCameraLook()
	introMouseLookX = 0
	introMouseLookY = 0
	introTouchPanX = 0
	introTouchPanY = 0
end

local function bindIntroTouchPan()
	if introTouchPanConn then
		return
	end
	if not UserInputService.TouchEnabled then
		return
	end
	introTouchPanConn = UserInputService.TouchMoved:Connect(function(input, _processed)
		if not introPlaying or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		introTouchPanX = math.clamp(introTouchPanX + input.Delta.X * 0.004, -1, 1)
		introTouchPanY = math.clamp(introTouchPanY + input.Delta.Y * 0.004, -1, 1)
	end)
end

local function unbindIntroTouchPan()
	if introTouchPanConn then
		introTouchPanConn:Disconnect()
		introTouchPanConn = nil
	end
	introTouchPanX = 0
	introTouchPanY = 0
end

local function updateIntroCameraLook(dt: number, cam: Camera)
	local viewport = cam.ViewportSize
	local mouse = UserInputService:GetMouseLocation()
	local nx = ((mouse.X / math.max(viewport.X, 1)) - 0.5) * 2
	local ny = ((mouse.Y / math.max(viewport.Y, 1)) - 0.5) * 2
	nx = math.clamp(nx + introTouchPanX, -1, 1)
	ny = math.clamp(ny + introTouchPanY, -1, 1)
	local lookSmooth = math.min(dt * 7.5, 1)
	introMouseLookX += (nx - introMouseLookX) * lookSmooth
	introMouseLookY += (ny - introMouseLookY) * lookSmooth
end

type IntroCamOpts = {
	pullBack: number?,
	sideBase: number?,
	heightBase: number?,
}

local function computeIntroShoulderCamera(
	hrp: BasePart,
	focusPos: Vector3,
	phase: number,
	dt: number,
	cam: Camera,
	savedFov: number?,
	opts: IntroCamOpts?
): (CFrame, number)
	updateIntroCameraLook(dt, cam)

	local playerPos = hrp.Position + Vector3.new(0, 1.4, 0)
	local mid = playerPos:Lerp(focusPos, 0.52)
	local toFocus = flatUnit(playerPos, focusPos)
	local right = toFocus:Cross(Vector3.yAxis)
	if right.Magnitude < 0.05 then
		right = hrp.CFrame.RightVector
	else
		right = right.Unit
	end

	local pullBack = if opts and typeof(opts.pullBack) == "number" then opts.pullBack else 5.4
	local sideBase = if opts and typeof(opts.sideBase) == "number" then opts.sideBase else 3.4
	local heightBase = if opts and typeof(opts.heightBase) == "number" then opts.heightBase else 3.5

	local sidePull = sideBase + introMouseLookX * 3.8
	local height = heightBase - introMouseLookY * 1.5
	local pull = pullBack - math.abs(introMouseLookX) * 0.55

	local driftX = math.sin(phase * 0.85) * 0.42 + math.sin(phase * 1.65) * 0.14
	local driftY = math.sin(phase * 1.05) * 0.28 + math.cos(phase * 0.62) * 0.1
	local driftOrbit = math.sin(phase * 0.45) * 0.34

	local camPos = mid - toFocus * pull + right * (sidePull + driftOrbit) + Vector3.new(driftX, height + driftY, 0)
	local lookAt = focusPos
		+ right * (0.4 + introMouseLookX * 1.25)
		+ Vector3.new(0, -introMouseLookY * 0.7, 0)
		+ Vector3.new(math.sin(phase * 0.72) * 0.18, math.cos(phase * 0.58) * 0.12, 0)
	local goalCf = CFrame.lookAt(camPos, lookAt)
	local baseFov = savedFov or 60
	local goalFov = baseFov - 3 + math.abs(introMouseLookX) * 2.2 + math.abs(introMouseLookY) * 1.1 + math.sin(phase * 0.9) * 0.75

	return goalCf, goalFov
end

local function stopIntroTalkJump(model: Model?)
	introJumpActive = false
	introJumpToken += 1
	if model and model.Parent and introJumpBasePivot then
		pcall(function()
			model:PivotTo(introJumpBasePivot)
		end)
	end
	introJumpBasePivot = nil
end

local function startIntroTalkJump(model: Model)
	stopIntroTalkJump(model)
	introJumpActive = true
	introJumpToken += 1
	local token = introJumpToken
	introJumpBasePivot = model:GetPivot()
	task.spawn(function()
		while introJumpActive and token == introJumpToken and model.Parent do
			local base = introJumpBasePivot
			if not base then
				break
			end
			local up = base + Vector3.new(0, 0.45, 0)
			local t0 = os.clock()
			while introJumpActive and os.clock() - t0 < 0.11 and token == introJumpToken do
				local a = (os.clock() - t0) / 0.11
				model:PivotTo(base:Lerp(up, a))
				RunService.Heartbeat:Wait()
			end
			if not introJumpActive or token ~= introJumpToken then
				break
			end
			local t1 = os.clock()
			while introJumpActive and os.clock() - t1 < 0.11 and token == introJumpToken do
				local a = (os.clock() - t1) / 0.11
				model:PivotTo(up:Lerp(base, a))
				RunService.Heartbeat:Wait()
			end
			if not introJumpActive or token ~= introJumpToken then
				break
			end
			if introJumpBasePivot then
				model:PivotTo(introJumpBasePivot)
			end
			task.wait(0.07)
		end
		if introJumpActive and token == introJumpToken and model.Parent and introJumpBasePivot then
			pcall(function()
				model:PivotTo(introJumpBasePivot)
			end)
		end
	end)
end

local function fireQuestClaimCelebration()
	-- Same confetti + purchase SFX + camera shake as daily/tutorial claims.
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
		warn("[TimCheeseQuestController] celebratePurchase failed:", celebrateErr)
	end
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
	if on then
		if highlight and highlight.Parent then
			if highlight.Adornee ~= tim then
				highlight.Adornee = tim
			end
			lastOutlineOn = true
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
		lastOutlineOn = true
		return
	end
	if lastOutlineOn == false and not highlight then
		return
	end
	lastOutlineOn = false
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
end

local function ensureTalkPrompt(tim: Model)
	if talkPrompt and talkPrompt.Parent then
		return talkPrompt
	end
	-- Prompt instance changed — force next sync to re-apply action/enabled.
	lastPromptAction = nil
	lastPromptEnabled = nil
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
	local intro = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true or introStartedLocal
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local hasQuest = typeof(idx) == "number" and idx >= 1
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then completed else 0
	local allDone = doneCount >= TimCheeseQuestConfig.questCount()
	local needsVisit = intro and not hasQuest and not allDone and not ready
	local promptLocked = dialogueBusy
		or introPlaying
		or StandDialogueCutscene.isActive()
		or os.clock() < promptLockedUntil

	if intro and not introPlaying and not dialogueBusy and not StandDialogueCutscene.isActive() then
		ensureTalkPrompt(tim)
		if talkPrompt then
			local wantEnabled = not promptLocked
			local actionText = if ready
				then "Claim"
				elseif hasQuest then "Talk"
				elseif allDone then "Talk"
				elseif needsVisit then "Quests"
				else "Quests"
			if lastPromptEnabled ~= wantEnabled then
				lastPromptEnabled = wantEnabled
				talkPrompt.Enabled = wantEnabled
				if not wantEnabled then
					pcall(function()
						ProximityPromptEffects.forceHide(talkPrompt :: ProximityPrompt)
					end)
				end
			end
			if wantEnabled then
				talkPrompt.Style = Enum.ProximityPromptStyle.Custom
				talkPrompt:SetAttribute("CustomPromptFX", true)
				if lastPromptAction ~= actionText then
					lastPromptAction = actionText
					talkPrompt.ActionText = actionText
					-- Restyle only when the prompt text/state actually changes.
					pcall(function()
						ProximityPromptEffects.stylePrompt(talkPrompt)
					end)
				end
			end
		end
		setOutline(tim, (ready == true or needsVisit) and not promptLocked)
		local floatText = if ready
			then TimCheeseQuestConfig.READY_OVERHEAD
			elseif needsVisit then TimCheeseQuestConfig.VISIT_OVERHEAD
			elseif hasQuest then TimCheeseQuestConfig.HAS_QUEST_OVERHEAD
			else TimCheeseQuestConfig.NO_QUEST_OVERHEAD
		if lastFloatText ~= floatText then
			lastFloatText = floatText
			setQuestFloatVisible(tim, true, floatText)
		end
	elseif talkPrompt then
		if lastPromptEnabled ~= false then
			lastPromptEnabled = false
			talkPrompt.Enabled = false
			pcall(function()
				ProximityPromptEffects.forceHide(talkPrompt :: ProximityPrompt)
			end)
		end
		setOutline(tim, false)
	end
end

local function lockTalkPrompt(durationSec: number)
	promptLockedUntil = math.max(promptLockedUntil, os.clock() + math.max(0.1, durationSec))
	if talkPrompt and talkPrompt.Parent then
		talkPrompt.Enabled = false
		pcall(function()
			ProximityPromptEffects.forceHide(talkPrompt :: ProximityPrompt)
		end)
	end
end

local function ensureQuestHost(): Frame?
	-- Dedicated ScreenGui so shop panels / cutscenes under Main can't cover the tracker.
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not pg then
		return nil
	end
	local gui = questGui
	if not (gui and gui.Parent) then
		local existingGui = pg:FindFirstChild("TimCheeseQuestTracker")
		if existingGui and existingGui:IsA("ScreenGui") then
			gui = existingGui
		else
			gui = Instance.new("ScreenGui")
			gui.Name = "TimCheeseQuestTracker"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = 110
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.Enabled = false
			gui.Parent = pg
		end
		questGui = gui
	end
	gui.Enabled = questHudRevealed
		and not questHudSuppressed
		and not introPlaying
		and not dialogueBusy
		and not GameplayUiVisibility.isHidden()
	gui.DisplayOrder = math.max(gui.DisplayOrder, 110)
	gui.IgnoreGuiInset = true
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)

	-- Drop legacy host under Main so we don't double-draw a stretched leftover.
	local main = PlayerGuiMain.ensure(player)
	if main then
		local legacy = main:FindFirstChild("TimCheeseQuestHost")
		if legacy then
			legacy:Destroy()
		end
	end

	local existing = gui:FindFirstChild("TimCheeseQuestHost")
	if existing and existing:IsA("Frame") then
		questHost = existing
		return existing
	end
	local created = Instance.new("Frame")
	created.Name = "TimCheeseQuestHost"
	created.BackgroundTransparency = 1
	created.BorderSizePixel = 0
	created.Size = UDim2.fromScale(1, 1)
	created.Position = UDim2.fromScale(0, 0)
	created.AnchorPoint = Vector2.new(0, 0)
	created.ZIndex = 1
	created.ClipsDescendants = false
	created.Active = false
	created.Visible = true
	created.Parent = gui
	questHost = created
	return created
end

local function canShowQuestChrome(): boolean
	return questHudRevealed
		and not questHudSuppressed
		and not introPlaying
		and not dialogueBusy
		and not GameplayUiVisibility.isHidden()
end

local function syncQuestChromeVisibility()
	if not canShowQuestChrome() then
		stopArrowPulse()
		if questGui then
			questGui.Enabled = false
		end
		if questPanel then
			questPanel.Visible = false
		end
		if questArrowBtn then
			questArrowBtn.Visible = false
		end
		return
	end
	if questGui then
		questGui.Enabled = true
	end
	recoverCollapseArrow()
	if questArrowBtn then
		questArrowBtn.Visible = true
	end
	if questPanel then
		questPanel.Visible = true
		if questHudCollapsed then
			local ticket = questPanel:FindFirstChild("Ticket")
			if ticket and ticket:IsA("GuiObject") then
				ticket.Visible = false
			end
		end
	end
end

local function setQuestHudSuppressed(on: boolean)
	questHudSuppressed = on == true
	if questHudSuppressed then
		stopExclaimPulse()
		stopQuestDots()
		stopArrowPulse()
		if questGui then
			questGui.Enabled = false
		end
		if questPanel then
			questPanel.Visible = false
		end
		if questArrowBtn then
			questArrowBtn.Visible = false
		end
	else
		syncQuestChromeVisibility()
		if questHudRevealed then
			refreshQuestHud()
		end
	end
end

local function isQuestBlockingCutscene(): boolean
	if introPlaying or dialogueBusy then
		return true
	end
	if GameplayUiVisibility.isHidden() then
		return true
	end
	if StandDialogueCutscene.isActive() then
		return true
	end
	if FloatingClaimCutscene.isActive() then
		return true
	end
	if GameplayCutsceneGate.isAmbushOrChaseActive() then
		return true
	end
	return false
end

local function syncQuestHudCutsceneGate()
	if isQuestBlockingCutscene() then
		if not questHudSuppressed then
			setQuestHudSuppressed(true)
		else
			-- Keep chrome hard-off even if something re-enabled the ScreenGui.
			if questGui and questGui.Enabled then
				questGui.Enabled = false
			end
			if questArrowBtn then
				questArrowBtn.Visible = false
			end
			if questPanel then
				questPanel.Visible = false
			end
		end
		return
	end
	if questHudSuppressed then
		setQuestHudSuppressed(false)
	else
		syncQuestChromeVisibility()
	end
end

stopQuestDots = function()
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

stopExclaimPulse = function()
	questBangPulseGen += 1
	if questExclaimConn then
		questExclaimConn:Disconnect()
		questExclaimConn = nil
	end
	if questFloatWrap and questFloatWrap.Parent then
		questFloatWrap.Position = UDim2.fromOffset(0, 0)
	end
	if questHoverBang and questHoverBang.Parent then
		questHoverBang.Size = UDim2.fromOffset(28, 28)
		questHoverBang.Rotation = -10
		questHoverBang.Position = UDim2.fromOffset(0, -1)
	end
end

local function cacheHoverTargets()
	questHoverBang = nil
	questFloatWrap = nil
	if not questPanel then
		return
	end
	-- Bob the Ticket (includes arrow) so the whole quest card floats together.
	local ticket = questPanel:FindFirstChild("Ticket")
	if ticket and ticket:IsA("GuiObject") then
		questFloatWrap = ticket
	end
	local bang = questPanel:FindFirstChild("Exclaim", true)
	if bang and bang:IsA("ImageLabel") then
		questHoverBang = bang
	end
end

local function startExclaimPulse()
	stopExclaimPulse()
	cacheHoverTargets()
	if questAnimBusy or questHoverFlying or questHudCollapsed then
		return
	end
	local gen = questBangPulseGen
	local wrap = questFloatWrap
	local bang = questHoverBang

	-- Soft up/down on the whole ticket content (tween loop, same method as tutorial bang).
	if wrap then
		task.spawn(function()
			while gen == questBangPulseGen and wrap.Parent and not questHudCollapsed and not questAnimBusy do
				local up = TweenService:Create(wrap, QUEST_FLOAT_BOB, {
					Position = UDim2.fromOffset(0, -QUEST_FLOAT_BOB_PX),
				})
				up:Play()
				up.Completed:Wait()
				if gen ~= questBangPulseGen or not wrap.Parent then
					break
				end
				local down = TweenService:Create(wrap, QUEST_FLOAT_BOB, {
					Position = UDim2.fromOffset(0, 0),
				})
				down:Play()
				down.Completed:Wait()
			end
			if wrap.Parent then
				wrap.Position = UDim2.fromOffset(0, 0)
			end
		end)
	end

	-- Bang stays mostly still — tiny sway only.
	if bang then
		task.spawn(function()
			while gen == questBangPulseGen and bang.Parent and not questHudCollapsed and not questAnimBusy do
				local a = TweenService:Create(bang, QUEST_BANG_IDLE, { Rotation = -14 })
				a:Play()
				a.Completed:Wait()
				if gen ~= questBangPulseGen or not bang.Parent then
					break
				end
				local b = TweenService:Create(bang, QUEST_BANG_IDLE, { Rotation = -6 })
				b:Play()
				b.Completed:Wait()
			end
			if bang.Parent then
				bang.Size = UDim2.fromOffset(28, 28)
				bang.Rotation = -10
			end
		end)
	end
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

local function wireCollapseArrow(collapse: ImageButton)
	questArrowBtn = collapse
	questArrowScale = collapse:FindFirstChildOfClass("UIScale")
	if collapse:GetAttribute("QuestArrowWired") == true then
		return
	end
	collapse:SetAttribute("QuestArrowWired", true)
	if not questArrowScale then
		local arrowScale = Instance.new("UIScale")
		arrowScale.Name = "ArrowScale"
		arrowScale.Scale = 1
		arrowScale.Parent = collapse
		questArrowScale = arrowScale
	end
	local function setArrowHover(on: boolean)
		if questAnimBusy or not questArrowScale then
			return
		end
		stopArrowPulse()
		TweenService:Create(
			questArrowScale,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = if on then 1.14 else 1 }
		):Play()
		if not on then
			startArrowPulse()
		end
	end
	collapse.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		setArrowHover(true)
	end)
	collapse.MouseLeave:Connect(function()
		setArrowHover(false)
	end)
	collapse.Activated:Connect(function()
		UIInteractionSounds.playClick()
		toggleQuestHudCollapsed()
	end)
	GamepadInput.mountHint(collapse, Enum.KeyCode.DPadUp, false, { contrast = true })
end

recoverCollapseArrow = function(): ImageButton?
	if questArrowBtn and questArrowBtn.Parent then
		wireCollapseArrow(questArrowBtn)
		return questArrowBtn
	end
	local roots: { Instance? } = { questPanel, questHost, questGui }
	for _, root in roots do
		if root then
			local found = root:FindFirstChild("CollapseArrow", true)
			if found and found:IsA("ImageButton") then
				wireCollapseArrow(found)
				return found
			end
		end
	end
	local panel = questPanel
	local ticket = panel and panel:FindFirstChild("Ticket")
	if not (ticket and ticket:IsA("GuiObject")) then
		return nil
	end
	local collapse = Instance.new("ImageButton")
	collapse.Name = "CollapseArrow"
	collapse.BackgroundTransparency = 1
	collapse.BorderSizePixel = 0
	collapse.AnchorPoint = Vector2.new(1, 0)
	collapse.Position = UDim2.new(1, -4, 0, 4)
	collapse.Size = UDim2.fromOffset(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE)
	collapse.Image = COLLAPSE_ARROW_IMAGE
	collapse.ImageColor3 = Color3.fromRGB(255, 255, 255)
	collapse.ScaleType = Enum.ScaleType.Fit
	collapse.Rotation = 0
	collapse.ZIndex = 130
	collapse.AutoButtonColor = false
	collapse.Visible = canShowQuestChrome()
	collapse.Parent = ticket
	wireCollapseArrow(collapse)
	return collapse
end

local function ensureQuestHud(): GuiObject
	if questPanel and questPanel.Parent then
		if questPanel:GetAttribute("StudTicket") == true and questPanel:GetAttribute("HudLayout") == "phone_v1" then
			recoverCollapseArrow()
			cacheHoverTargets()
			return questPanel
		end
		questPanel:Destroy()
		questPanel = nil
	end
	local host = ensureQuestHost()
	assert(host, "TimCheeseQuestHost missing")

	-- Shell owns layout/collapse. Ticket is the cheese card.
	local shell = Instance.new("Frame")
	shell.Name = "ObjectivePanel"
	shell.BackgroundTransparency = 1
	shell.BorderSizePixel = 0
	shell.AnchorPoint = Vector2.new(1, 0)
	shell.Position = UDim2.new(1, -TutorialConfig.PANEL_RIGHT_PAD, 0, TutorialConfig.PANEL_TOP_PAD + 36)
	shell.Size = UDim2.fromOffset(TutorialConfig.PANEL_MIN_WIDTH, TutorialConfig.PANEL_HEIGHT)
	shell.AutomaticSize = Enum.AutomaticSize.Y
	shell:SetAttribute("StudTicket", true)
	shell:SetAttribute("HudLayout", "phone_v1")
	shell.Visible = false
	shell.ZIndex = 100
	shell.ClipsDescendants = false
	shell.Parent = host

	local ticketScale = Instance.new("UIScale")
	ticketScale.Name = "PanelScale"
	ticketScale.Scale = 1
	ticketScale.Parent = shell

	local hudMatchScale = Instance.new("UIScale")
	hudMatchScale.Name = "HudMatchScale"
	hudMatchScale.Scale = 1
	hudMatchScale.Parent = shell

	local hudMax = Instance.new("UISizeConstraint")
	hudMax.Name = "HudMaxSize"
	hudMax.MinSize = Vector2.new(140, 72)
	hudMax.MaxSize = Vector2.new(380, 180)
	hudMax.Parent = shell

	local ticket = Instance.new("ImageLabel")
	ticket.Name = "Ticket"
	ticket.Size = UDim2.new(1, 0, 0, 0)
	ticket.AutomaticSize = Enum.AutomaticSize.Y
	ticket.ZIndex = 100
	ticket.ClipsDescendants = false
	paintStudImage(ticket, Color3.fromRGB(255, 214, 74), 0.78)
	ticket.Parent = shell

	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 6)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Name = "TicketStroke"
	ticketStroke.Color = Color3.fromRGB(40, 28, 8)
	ticketStroke.Thickness = 2.5
	ticketStroke.Parent = ticket

	local floatWrap = Instance.new("Frame")
	floatWrap.Name = "FloatWrap"
	floatWrap.BackgroundTransparency = 1
	floatWrap.BorderSizePixel = 0
	floatWrap.Size = UDim2.new(1, 0, 0, 0)
	floatWrap.AutomaticSize = Enum.AutomaticSize.Y
	floatWrap.Position = UDim2.fromOffset(0, 0)
	floatWrap.ZIndex = 99
	floatWrap.Parent = ticket

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = floatWrap

	local inner = Instance.new("ImageLabel")
	inner.Name = "Inner"
	paintStudImage(inner, Color3.fromRGB(255, 244, 180), 0.82)
	inner.Size = UDim2.new(1, 0, 0, 0)
	inner.AutomaticSize = Enum.AutomaticSize.Y
	inner.ZIndex = 101
	inner.ClipsDescendants = true
	inner.Parent = floatWrap
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 4)
	innerCorner.Parent = inner
	local dash = Instance.new("UIStroke")
	dash.Name = "InnerStroke"
	dash.Color = Color3.fromRGB(180, 120, 30)
	dash.Thickness = 1.2
	dash.Transparency = 0.35
	dash.Parent = inner
	local innerPad = Instance.new("UIPadding")
	innerPad.PaddingTop = UDim.new(0, 5)
	innerPad.PaddingBottom = UDim.new(0, 5)
	innerPad.PaddingLeft = UDim.new(0, 7)
	innerPad.PaddingRight = UDim.new(0, 30)
	innerPad.Parent = inner
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = inner

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.LayoutOrder = 1
	header.ZIndex = 102
	header.Parent = inner

	local bang = Instance.new("ImageLabel")
	bang.Name = "Exclaim"
	bang.BackgroundTransparency = 1
	bang.Position = UDim2.fromOffset(0, -1)
	bang.Size = UDim2.fromOffset(28, 28)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.Rotation = -10
	bang.ZIndex = 103
	bang.Parent = header

	local stamp = Instance.new("TextLabel")
	stamp.Name = "Stamp"
	stamp.BackgroundTransparency = 1
	stamp.Position = UDim2.fromOffset(32, 0)
	stamp.Size = UDim2.new(1, -34, 0, 12)
	stamp.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	stamp.TextSize = 10
	stamp.TextColor3 = Color3.fromRGB(160, 40, 30)
	stamp.TextXAlignment = Enum.TextXAlignment.Left
	stamp.Text = "TIM CHEESE JOB"
	stamp.TextScaled = false
	stamp.TextWrapped = false
	stamp.TextTruncate = Enum.TextTruncate.AtEnd
	stamp.ZIndex = 103
	stamp.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(32, 12)
	title.Size = UDim2.new(1, -34, 0, 18)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 14
	title.TextColor3 = Color3.fromRGB(30, 24, 10)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.TextScaled = false
	title.TextWrapped = false
	title.Text = ""
	title.ZIndex = 103
	title.Parent = header
	UiFonts.applyDisplayLabel(title, 14, 11)

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 36)
	body.AutomaticSize = Enum.AutomaticSize.None
	body.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	body.TextSize = 12
	body.TextColor3 = Color3.fromRGB(55, 42, 18)
	body.TextWrapped = true
	body.TextScaled = false
	body.TextTruncate = Enum.TextTruncate.AtEnd
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.Text = ""
	body.LayoutOrder = 2
	body.ZIndex = 102
	body.Parent = inner

	local progressRow = Instance.new("Frame")
	progressRow.Name = "ProgressRow"
	progressRow.BackgroundTransparency = 1
	progressRow.Size = UDim2.new(1, 0, 0, 14)
	progressRow.LayoutOrder = 3
	progressRow.ZIndex = 102
	progressRow.Parent = inner

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Size = UDim2.new(1, -28, 1, 0)
	progress.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	progress.TextSize = 11
	progress.TextColor3 = Color3.fromRGB(40, 110, 40)
	progress.TextXAlignment = Enum.TextXAlignment.Left
	progress.TextScaled = false
	progress.TextWrapped = false
	progress.TextTruncate = Enum.TextTruncate.AtEnd
	progress.Text = ""
	progress.ZIndex = 103
	progress.Parent = progressRow

	local dots = Instance.new("TextLabel")
	dots.Name = "ObjectiveDots"
	dots.BackgroundTransparency = 1
	dots.AnchorPoint = Vector2.new(1, 0.5)
	dots.Position = UDim2.new(1, 0, 0.5, 0)
	dots.Size = UDim2.fromOffset(24, 14)
	dots.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	dots.TextSize = 11
	dots.TextColor3 = Color3.fromRGB(40, 110, 40)
	dots.TextXAlignment = Enum.TextXAlignment.Left
	dots.Text = ""
	dots.ZIndex = 103
	dots.Parent = progressRow

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, 0, 0, 7)
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
	payout.Size = UDim2.new(1, 0, 0, 20)
	payout.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	payout.TextSize = 11
	payout.TextColor3 = Color3.fromRGB(255, 220, 80)
	payout.TextScaled = false
	payout.TextWrapped = false
	payout.TextTruncate = Enum.TextTruncate.AtEnd
	payout.Text = ""
	payout.LayoutOrder = 5
	payout.ZIndex = 102
	payout.Parent = inner
	local payCorner = Instance.new("UICorner")
	payCorner.CornerRadius = UDim.new(0, 6)
	payCorner.Parent = payout

	-- Plain image arrow (no panel behind it). Lives on the ticket when open;
	-- when collapsed it reparents to the quest host and parks on the screen edge.
	local collapse = Instance.new("ImageButton")
	collapse.Name = "CollapseArrow"
	collapse.BackgroundTransparency = 1
	collapse.BorderSizePixel = 0
	collapse.AnchorPoint = Vector2.new(1, 0)
	collapse.Position = UDim2.new(1, -4, 0, 4)
	collapse.Size = UDim2.fromOffset(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE)
	collapse.Image = COLLAPSE_ARROW_IMAGE
	collapse.ImageColor3 = Color3.fromRGB(255, 255, 255)
	collapse.ScaleType = Enum.ScaleType.Fit
	collapse.Rotation = 0
	collapse.ZIndex = 130
	collapse.AutoButtonColor = false
	collapse.Parent = ticket
	local arrowScale = Instance.new("UIScale")
	arrowScale.Name = "ArrowScale"
	arrowScale.Scale = 1
	arrowScale.Parent = collapse

	questPanel = shell
	wireCollapseArrow(collapse)
	cacheHoverTargets()
	collapse.Visible = false
	return shell
end

local function expandedHudPosition(): UDim2
	local edge = math.max(questHudBaseRightPad, 10)
	return UDim2.new(1, -edge, 0, questHudBaseTop)
end

local function getPanelScale(): UIScale?
	if not questPanel then
		return nil
	end
	local sc = questPanel:FindFirstChild("PanelScale")
	if sc and sc:IsA("UIScale") then
		return sc
	end
	return nil
end

local function cancelCollapseTweens()
	if questCollapseTween then
		questCollapseTween:Cancel()
		questCollapseTween = nil
	end
	if questArrowTween then
		questArrowTween:Cancel()
		questArrowTween = nil
	end
	if questPanelScaleTween then
		questPanelScaleTween:Cancel()
		questPanelScaleTween = nil
	end
	if questArrowBlendTween then
		questArrowBlendTween:Cancel()
		questArrowBlendTween = nil
	end
	if questArrowFollowConn then
		questArrowFollowConn:Disconnect()
		questArrowFollowConn = nil
	end
	if questArrowBlendValue then
		questArrowBlendValue:Destroy()
		questArrowBlendValue = nil
	end
end

stopArrowPulse = function()
	if questArrowPulseTween then
		questArrowPulseTween:Cancel()
		questArrowPulseTween = nil
	end
	if questArrowScale then
		questArrowScale.Scale = 1
	end
end

startArrowPulse = function()
	stopArrowPulse()
	if not questArrowScale or questAnimBusy then
		return
	end
	local tw = TweenService:Create(
		questArrowScale,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.08 }
	)
	questArrowPulseTween = tw
	tw:Play()
end

placeArrowOnTicket = function()
	recoverCollapseArrow()
	if not questPanel or not questArrowBtn then
		return
	end
	local ticket = questPanel:FindFirstChild("Ticket")
	if not (ticket and ticket:IsA("GuiObject")) then
		return
	end
	questArrowBtn.Parent = ticket
	questArrowBtn.AnchorPoint = Vector2.new(1, 0)
	questArrowBtn.Position = UDim2.new(1, -4, 0, 4)
	questArrowBtn.Size = UDim2.fromOffset(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE)
	questArrowBtn.Rotation = 0
	questArrowBtn.ZIndex = 130
	questArrowBtn.Visible = canShowQuestChrome()
end

placeArrowParked = function()
	recoverCollapseArrow()
	if not questPanel or not questArrowBtn then
		return
	end
	local host = questPanel.Parent
	if not (host and host:IsA("GuiObject")) then
		return
	end
	questArrowBtn.Parent = host
	questArrowBtn.AnchorPoint = Vector2.new(1, 0)
	-- Locked to the ticket-arrow height captured on collapse — never snap to panel bottom pad.
	local y = questParkedArrowY
	if y == 0 then
		y = questHudBaseTop
	end
	questArrowBtn.Position = UDim2.new(1, -QUEST_ARROW_EDGE_PAD, 0, y)
	questArrowBtn.Size = UDim2.fromOffset(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE)
	questArrowBtn.Rotation = 180
	questArrowBtn.ZIndex = 200
	questArrowBtn.Visible = canShowQuestChrome()
end

local function arrowHostPosFromAbsolute(host: GuiObject, absPos: Vector2, absSize: Vector2): UDim2
	-- Convert AbsolutePosition (top-left) to host-local Position with AnchorPoint (1, 0).
	local right = absPos.X + absSize.X - host.AbsolutePosition.X
	local top = absPos.Y - host.AbsolutePosition.Y
	return UDim2.fromOffset(math.floor(right + 0.5), math.floor(top + 0.5))
end

local function ticketArrowHostGoal(): UDim2?
	if not questPanel or not questArrowBtn then
		return nil
	end
	local host = questPanel.Parent
	local ticket = questPanel:FindFirstChild("Ticket")
	if not (host and host:IsA("GuiObject") and ticket and ticket:IsA("GuiObject")) then
		return nil
	end
	-- Goal = ticket top-right inset, matching placeArrowOnTicket local (1,-4)/(0,4).
	local abs = Vector2.new(ticket.AbsolutePosition.X + ticket.AbsoluteSize.X - 4 - COLLAPSE_ARROW_SIZE, ticket.AbsolutePosition.Y + 4)
	return arrowHostPosFromAbsolute(host, abs, Vector2.new(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE))
end

local function freezePanelSize()
	if not questPanel then
		return
	end
	local abs = questPanel.AbsoluteSize
	questPanel.AutomaticSize = Enum.AutomaticSize.None
	questPanel.Size = UDim2.fromOffset(math.max(abs.X, 1), math.max(abs.Y, 1))
end

local function unfreezePanelAutoY(screenW: number?)
	if not questPanel then
		return
	end
	local w = screenW or math.max(questPanel.Size.X.Offset, 160)
	questPanel.Size = UDim2.fromOffset(w, TutorialConfig.PANEL_HEIGHT)
	questPanel.AutomaticSize = Enum.AutomaticSize.Y
end

local function panelHiddenOffset(panel: GuiObject): number
	local w = math.max(panel.AbsoluteSize.X, panel.Size.X.Offset, 160)
	return math.ceil(w) + 20
end

toggleQuestHudCollapsed = function()
	if not questPanel or questHoverFlying or questAnimBusy then
		return
	end
	if not canShowQuestChrome() then
		return
	end
	questHudCollapsed = not questHudCollapsed
	cancelCollapseTweens()
	stopArrowPulse()
	stopExclaimPulse()

	local panel = questPanel
	local arrow = questArrowBtn
	local panelScale = getPanelScale()
	if panelScale then
		panelScale.Scale = 1
	end
	local goal = expandedHudPosition()

	if questHudCollapsed then
		-- Pure edge slide: panel keeps size and glides off-screen to the right.
		questAnimBusy = true
		local host = panel.Parent
		freezePanelSize()
		local from = panel.Position
		local hiddenX = panelHiddenOffset(panel)
		-- If already near-hidden, nudge from left so the slide is always visible.
		if from.X.Offset >= hiddenX - 8 then
			from = UDim2.new(1, -math.max(questHudBaseRightPad, 10), 0, from.Y.Offset)
			panel.Position = from
		end
		local tuck = UDim2.new(1, hiddenX, 0, from.Y.Offset)

		-- Capture arrow height from the ticket corner BEFORE sliding, then park at that Y.
		placeArrowOnTicket()
		local parkedY = questHudBaseTop
		if arrow and host and host:IsA("GuiObject") then
			local startHost = ticketArrowHostGoal()
			if startHost then
				parkedY = startHost.Y.Offset
			else
				parkedY = math.floor(arrow.AbsolutePosition.Y - host.AbsolutePosition.Y + 0.5)
			end
			questParkedArrowY = parkedY
			arrow.Parent = host
			arrow.AnchorPoint = Vector2.new(1, 0)
			arrow.Position = startHost or UDim2.new(1, -QUEST_ARROW_EDGE_PAD, 0, parkedY)
			arrow.Size = UDim2.fromOffset(COLLAPSE_ARROW_SIZE, COLLAPSE_ARROW_SIZE)
			arrow.ZIndex = 200
			arrow.Visible = true
			arrow.Rotation = 0

			local parked = UDim2.new(1, -QUEST_ARROW_EDGE_PAD, 0, parkedY)
			local arrowTw = TweenService:Create(arrow, QUEST_EDGE_SLIDE, {
				Position = parked,
				Rotation = 180,
			})
			questArrowTween = arrowTw
			arrowTw:Play()
		else
			questParkedArrowY = parkedY
		end

		local tw = TweenService:Create(panel, QUEST_EDGE_SLIDE, { Position = tuck })
		questCollapseTween = tw
		tw.Completed:Connect(function(playbackState)
			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			if not questPanel or not questHudCollapsed then
				questAnimBusy = false
				return
			end
			local ticket = questPanel:FindFirstChild("Ticket")
			if ticket and ticket:IsA("GuiObject") then
				ticket.Visible = false
			end
			questPanel.Position = UDim2.new(1, panelHiddenOffset(questPanel), 0, from.Y.Offset)
			if panelScale then
				panelScale.Scale = 1
			end
			cancelCollapseTweens()
			placeArrowParked()
			questAnimBusy = false
			if canShowQuestChrome() then
				startArrowPulse()
			end
		end)
		tw:Play()
	else
		-- Expand: same size, slide in from past the right edge — no scale pop.
		questAnimBusy = true
		local ticket = panel:FindFirstChild("Ticket")
		if ticket and ticket:IsA("GuiObject") then
			ticket.Visible = true
		end
		local slideW = math.max(panel.Size.X.Offset, 160)
		if panel.AbsoluteSize.X > 4 then
			slideW = math.max(slideW, math.ceil(panel.AbsoluteSize.X))
		end
		panel.Visible = true
		panel.AnchorPoint = Vector2.new(1, questHudAnchorY)
		panel.AutomaticSize = Enum.AutomaticSize.None
		panel.Size = UDim2.fromOffset(slideW, math.max(panel.Size.Y.Offset, 80))
		local hiddenX = math.max(panelHiddenOffset(panel), slideW + 20)
		panel.Position = UDim2.new(1, hiddenX, 0, goal.Y.Offset)
		placeArrowOnTicket()
		if arrow then
			arrow.Visible = true
			arrow.Rotation = 180
			local arrowTw = TweenService:Create(arrow, QUEST_EDGE_SLIDE, { Rotation = 0 })
			questArrowTween = arrowTw
			arrowTw:Play()
		end
		local tw = TweenService:Create(panel, QUEST_EDGE_SLIDE, { Position = goal })
		questCollapseTween = tw
		tw.Completed:Connect(function(playbackState)
			if playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			if not questPanel or questHudCollapsed then
				questAnimBusy = false
				return
			end
			unfreezePanelAutoY(slideW)
			questAnimBusy = false
			layoutQuestHud()
			startExclaimPulse()
			if canShowQuestChrome() then
				startArrowPulse()
			end
		end)
		tw:Play()
	end
end

local function resolveRandomBrainrotHud(): GuiObject?
	local main = PlayerGuiMain.ensure(player)
	local sideUI = main and main:FindFirstChild("SideUI")
	local right = sideUI and sideUI:FindFirstChild("Right")
	local rb = right and right:FindFirstChild("RandomBrainrot")
	-- Prefer the frame slot (layout-stable). Activation is only a fallback —
	-- hover UIScale on Activation/frame must not pull the quest HUD around.
	if rb and rb:IsA("GuiObject") and rb.AbsoluteSize.Y > 4 then
		return rb
	end
	return nil
end

-- Undo hover UIScale so AbsolutePosition stays at the button's rest slot.
local function guiRestTopLeftAndSize(gui: GuiObject): (Vector2, Vector2)
	local scale = 1
	local uiScale = gui:FindFirstChildOfClass("UIScale")
	if uiScale and uiScale:IsA("UIScale") and uiScale.Scale > 0.01 then
		scale = uiScale.Scale
	end
	local absPos = gui.AbsolutePosition
	local absSize = gui.AbsoluteSize
	local ap = gui.AnchorPoint
	local restSize = Vector2.new(absSize.X / scale, absSize.Y / scale)
	local restPos = absPos
		+ Vector2.new(absSize.X * (1 - 1 / scale) * ap.X, absSize.Y * (1 - 1 / scale) * ap.Y)
	return restPos, restSize
end

local function isCompactQuestHud(): boolean
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return true
	end
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and preferred == Enum.PreferredInput.Touch then
		return true
	end
	local cam = Workspace.CurrentCamera
	return cam ~= nil and cam.ViewportSize.X < 700
end

local function fitQuestHudLabels(panel: GuiObject, compact: boolean, width: number, vh: number)
	local title = panel:FindFirstChild("Title", true)
	local body = panel:FindFirstChild("Body", true)
	local stamp = panel:FindFirstChild("Stamp", true)
	local progress = panel:FindFirstChild("Progress", true)
	local reward = panel:FindFirstChild("Reward", true)
	local bang = panel:FindFirstChild("Exclaim", true)
	local header = panel:FindFirstChild("Header", true)

	local titleSize = if compact then 12 else 14
	local bodySize = if compact then 10 else 12
	local bodyH = if compact then 32 else 40

	if header and header:IsA("GuiObject") then
		header.Size = UDim2.new(1, 0, 0, if compact then 26 else 30)
	end
	if bang and bang:IsA("GuiObject") then
		local side = if compact then 22 else 28
		bang.Size = UDim2.fromOffset(side, side)
	end
	if stamp and stamp:IsA("TextLabel") then
		stamp.TextScaled = false
		stamp.TextWrapped = false
		stamp.TextTruncate = Enum.TextTruncate.AtEnd
		stamp.TextSize = if compact then 9 else 10
		stamp.Size = UDim2.new(1, -34, 0, if compact then 11 else 12)
	end
	if title and title:IsA("TextLabel") then
		title.TextScaled = false
		title.TextWrapped = false
		title.TextTruncate = Enum.TextTruncate.AtEnd
		UiFonts.applyDisplayLabel(title, titleSize, math.max(9, titleSize - 3))
		title.Position = UDim2.fromOffset(32, if compact then 10 else 12)
		title.Size = UDim2.new(1, -34, 0, if compact then 15 else 18)
	end
	if body and body:IsA("TextLabel") then
		body.TextScaled = false
		body.TextWrapped = true
		body.TextTruncate = Enum.TextTruncate.AtEnd
		body.AutomaticSize = Enum.AutomaticSize.None
		body.TextYAlignment = Enum.TextYAlignment.Top
		body.TextSize = bodySize
		UiFonts.ensureTextSizeConstraint(body, bodySize, math.max(8, bodySize - 2))
		body.Size = UDim2.new(1, 0, 0, bodyH)
	end
	if progress and progress:IsA("TextLabel") then
		progress.TextScaled = false
		progress.TextWrapped = false
		progress.TextTruncate = Enum.TextTruncate.AtEnd
		progress.TextSize = if compact then 10 else 11
	end
	if reward and reward:IsA("TextLabel") then
		reward.TextScaled = false
		reward.TextWrapped = false
		reward.TextTruncate = Enum.TextTruncate.AtEnd
		reward.TextSize = if compact then 10 else 11
		reward.Size = UDim2.new(1, 0, 0, if compact then 18 else 20)
	end

	local cap = panel:FindFirstChild("HudMaxSize")
	if cap and cap:IsA("UISizeConstraint") then
		cap.MaxSize = Vector2.new(width + 4, math.floor(vh * (if compact then 0.26 else 0.30)))
	end
end

layoutQuestHud = function()
	local panel = questPanel
	if not panel then
		return
	end
	-- Don't build/position chrome before Tim has given a quest.
	if not questHudRevealed and not questAnimBusy then
		syncQuestChromeVisibility()
		return
	end
	local host = ensureQuestHost()
	if host and panel.Parent ~= host then
		panel.Parent = host
	end
	if questGui and canShowQuestChrome() then
		questGui.Enabled = true
		questGui.DisplayOrder = math.max(questGui.DisplayOrder, 110)
		questGui.IgnoreGuiInset = true
		pcall(function()
			(questGui :: any).ClipToDeviceSafeArea = false
		end)
		pcall(function()
			(questGui :: any).ScreenInsets = Enum.ScreenInsets.None
		end)
	elseif questGui then
		questGui.Enabled = false
	end

	local compact = isCompactQuestHud()
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	local vh = if cam then cam.ViewportSize.Y else 720
	local rightPad = TutorialConfig.PANEL_RIGHT_PAD
	local topPad = TutorialConfig.PANEL_TOP_PAD + 6
	local anchorY = 0
	local screenW: number
	local matchScale = 1

	if compact then
		local maxW = math.floor(vw * 0.72)
		screenW = math.clamp(maxW, 180, 260)
		matchScale = if vh < 700 then 0.88 else 0.92
	else
		screenW = math.clamp(math.floor(vw * 0.24), 290, 380)
		matchScale = 0.94
	end
	fitQuestHudLabels(panel, compact, screenW, vh)

	local rb = resolveRandomBrainrotHud()
	local usedRb = false
	if rb and host and host.AbsoluteSize.Y > 0 then
		local hp = host.AbsolutePosition
		local rbPos, rbSize = guiRestTopLeftAndSize(rb)
		local rbTop = rbPos.Y - hp.Y
		-- After mobile cutscenes AbsolutePosition can be 0 for a few frames — that parked
		-- a bottom-anchored panel above the screen. Only trust settled coords.
		if rbSize.Y > 8 and rbTop > 72 and rbTop < vh - 20 then
			local hostRight = hp.X + host.AbsoluteSize.X
			local rbRight = rbPos.X + rbSize.X
			rightPad = math.max(10, math.floor(hostRight - rbRight))
			anchorY = 1
			topPad = math.max(10, math.floor(rbTop - QUEST_GAP_ABOVE_RB))
			usedRb = true
		end
	end
	if not usedRb then
		if compact then
			-- Hang from top-right (tutorial-style) so the ticket can't leave the screen.
			rightPad = 10
			anchorY = 0
			topPad = 14
		else
			anchorY = 0
			rightPad = TutorialConfig.PANEL_RIGHT_PAD
			topPad = TutorialConfig.PANEL_TOP_PAD + 6
		end
	end

	-- Keep bottom-anchored panels on-screen even if RandomBrainrot jumps.
	if anchorY >= 0.5 then
		local estH = math.max(TutorialConfig.PANEL_HEIGHT * matchScale, 96)
		local minTop = math.floor(estH + 16)
		local maxTop = math.max(minTop, math.floor(vh - 16))
		topPad = math.clamp(math.floor(topPad), minTop, maxTop)
	end

	local hudScale = panel:FindFirstChild("HudMatchScale")
	if hudScale and hudScale:IsA("UIScale") then
		hudScale.Scale = matchScale
	end

	questHudBaseRightPad = rightPad
	questHudBaseTop = topPad
	questHudAnchorY = anchorY

	-- Never fight an in-flight collapse/expand tween.
	if questAnimBusy then
		return
	end

	panel.AnchorPoint = Vector2.new(1, anchorY)
	if questHudCollapsed then
		local ticket = panel:FindFirstChild("Ticket")
		if ticket and ticket:IsA("GuiObject") then
			ticket.Visible = false
		end
		-- Keep shell parked fully off-screen; arrow stays at captured ticket-top Y.
		local slideW = math.max(panel.Size.X.Offset, screenW, 160)
		panel.AutomaticSize = Enum.AutomaticSize.None
		panel.Size = UDim2.fromOffset(slideW, math.max(panel.Size.Y.Offset, 40))
		panel.Position = UDim2.new(1, slideW + 20, 0, topPad)
		placeArrowParked()
	else
		panel.Size = UDim2.fromOffset(screenW, TutorialConfig.PANEL_HEIGHT)
		panel.AutomaticSize = Enum.AutomaticSize.Y
		if not questHoverFlying then
			panel.Position = UDim2.new(1, -rightPad, 0, topPad)
		end
		local ticket = panel:FindFirstChild("Ticket")
		if ticket and ticket:IsA("GuiObject") then
			ticket.Visible = true
		end
		placeArrowOnTicket()
	end
	panel.ZIndex = 10
end

local function hudSlotPosition(): UDim2
	layoutQuestHud()
	return UDim2.new(1, -questHudBaseRightPad, 0, questHudBaseTop)
end

local function hudSlotAnchor(): Vector2
	layoutQuestHud()
	return Vector2.new(1, questHudAnchorY)
end

local function startQuestLayoutSync()
	if questLayoutConn then
		return
	end
	questLayoutAccum = 0
	questLayoutConn = RunService.Heartbeat:Connect(function(dt)
		if questAnimBusy or questHoverFlying or questHudCollapsed or not questPanel or not questPanel.Visible then
			return
		end
		questLayoutAccum += dt
		if questLayoutAccum < (1 / QUEST_LAYOUT_HZ) then
			return
		end
		questLayoutAccum = 0
		layoutQuestHud()
	end)
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
	return TimCheeseQuestConfig.formatProgressLabel(quest, p)
end

refreshQuestHud = function(opts: { skipRevealGate: boolean?, playAppear: boolean? }?)
	local skipGate = opts ~= nil and opts.skipRevealGate == true
	local playAppear = opts ~= nil and opts.playAppear == true
	if questHudSuppressed then
		-- Don't wipe a just-revealed panel while dialogue suppress is still on.
		if not skipGate then
			syncQuestChromeVisibility()
		end
		return
	end
	local idx = resolveActiveQuestIndex()
	local progressVal = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_PROGRESS_ATTR)
	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	if not idx then
		stopQuestDots()
		stopExclaimPulse()
		questHudRevealed = false
		syncQuestChromeVisibility()
		return
	end
	-- Gate: only after accept fly-in, or rejoin init that set questHudRevealed.
	-- Do NOT auto-reveal on server index — that raced the center→HUD fly.
	if not questHudRevealed and not skipGate then
		syncQuestChromeVisibility()
		return
	end

	local quest = TimCheeseQuestConfig.getQuest(idx)
	if not quest then
		return
	end
	local panel = ensureQuestHud()
	layoutQuestHud()
	local wasHidden = not panel.Visible
	syncQuestChromeVisibility()
	if not canShowQuestChrome() then
		return
	end
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
		body.Text = if ready then "Visit Tim Cheese to cash out!" else quest.description
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
		reward.Text = "★  " .. TimCheeseQuestConfig.formatRewardLabel(quest)
		reward.TextColor3 = Color3.fromRGB(255, 220, 80)
		reward.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
		reward.BackgroundTransparency = 0
	end

	startQuestDots()
	if not questHudCollapsed and not questAnimBusy then
		startArrowPulse()
	end
	if (wasHidden or playAppear) and questHudRevealed then
		local sc = panel:FindFirstChild("PanelScale")
		if sc and sc:IsA("UIScale") then
			sc.Scale = 0.7
			TweenService:Create(sc, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
end

local function ensureQuestHudVisibleAfterDialogue()
	local idx = resolveActiveQuestIndex()
	if not idx then
		refreshQuestHud()
		return
	end
	questHudRevealed = true
	questHudCollapsed = false
	questAnimBusy = false
	questHoverFlying = false
	refreshQuestHud({ skipRevealGate = true, playAppear = false })
	syncQuestChromeVisibility()
	layoutQuestHud()
	-- Mobile AbsolutePosition settles a beat after cutscene UI restore.
	task.delay(0.2, function()
		if not questHudRevealed or dialogueBusy or questHudSuppressed then
			return
		end
		layoutQuestHud()
		syncQuestChromeVisibility()
	end)
end

local function playQuestAcceptPopup(quest: TimCheeseQuestConfig.QuestDef)
	GameSoundEffects.playQuestPopUp()
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not pg then
		return
	end
	if acceptPopupGui then
		acceptPopupGui:Destroy()
		acceptPopupGui = nil
	end

	questHoverFlying = true
	stopExclaimPulse()

	-- Build HUD hidden first so we know the slot to fly into.
	ensureQuestHud()
	layoutQuestHud()
	if questPanel then
		questPanel.Visible = false
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TimCheeseQuestAccept"
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
	ticket.Position = UDim2.fromScale(0.5, 0.5)
	ticket.Size = UDim2.fromOffset(if isCompactQuestHud() then 270 else 390, 0)
	ticket.AutomaticSize = Enum.AutomaticSize.Y
	ticket.BackgroundColor3 = Color3.fromRGB(255, 214, 74)
	ticket.BackgroundTransparency = 0.08
	ticket.BorderSizePixel = 0
	ticket.Rotation = -4
	ticket.Parent = gui
	local ticketCorner = Instance.new("UICorner")
	ticketCorner.CornerRadius = UDim.new(0, 10)
	ticketCorner.Parent = ticket
	local ticketStroke = Instance.new("UIStroke")
	ticketStroke.Color = Color3.fromRGB(255, 236, 150)
	ticketStroke.Thickness = 3
	ticketStroke.Transparency = 0.15
	ticketStroke.Parent = ticket
	local ticketPad = Instance.new("UIPadding")
	ticketPad.PaddingTop = UDim.new(0, 10)
	ticketPad.PaddingBottom = UDim.new(0, 10)
	ticketPad.PaddingLeft = UDim.new(0, 10)
	ticketPad.PaddingRight = UDim.new(0, 10)
	ticketPad.Parent = ticket

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.BackgroundColor3 = Color3.fromRGB(255, 244, 180)
	inner.BackgroundTransparency = 0.12
	inner.BorderSizePixel = 0
	inner.Size = UDim2.new(1, 0, 0, 0)
	inner.AutomaticSize = Enum.AutomaticSize.Y
	inner.ClipsDescendants = true
	inner.Parent = ticket
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 7)
	innerCorner.Parent = inner
	local dash = Instance.new("UIStroke")
	dash.Color = Color3.fromRGB(255, 210, 80)
	dash.Thickness = 1.6
	dash.Transparency = 0.35
	dash.Parent = inner
	local innerPad = Instance.new("UIPadding")
	innerPad.PaddingTop = UDim.new(0, 8)
	innerPad.PaddingBottom = UDim.new(0, 8)
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
	header.Size = UDim2.new(1, 0, 0, 66)
	header.LayoutOrder = 1
	header.Parent = inner

	local bang = Instance.new("ImageLabel")
	bang.Name = "Bang"
	bang.BackgroundTransparency = 1
	bang.Position = UDim2.fromOffset(0, 4)
	bang.Size = UDim2.fromOffset(54, 54)
	bang.Image = TutorialConfig.EXCLAIM_IMAGE
	bang.Rotation = -10
	bang.Parent = header

	local stamp = Instance.new("TextLabel")
	stamp.BackgroundTransparency = 1
	stamp.Position = UDim2.fromOffset(62, 6)
	stamp.Size = UDim2.new(1, -70, 0, 22)
	stamp.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	stamp.TextSize = 18
	stamp.TextColor3 = Color3.fromRGB(160, 40, 30)
	stamp.TextXAlignment = Enum.TextXAlignment.Left
	stamp.Text = "JOB LOCKED IN"
	stamp.TextScaled = false
	stamp.TextWrapped = false
	stamp.TextTruncate = Enum.TextTruncate.AtEnd
	stamp.Rotation = 1
	stamp.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(62, 32)
	title.Size = UDim2.new(1, -70, 0, 28)
	title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(30, 24, 10)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.TextScaled = false
	title.TextWrapped = false
	title.Text = quest.title
	title.Parent = header
	UiFonts.applyDisplayLabel(title, if isCompactQuestHud() then 16 else 22, 12)

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, if isCompactQuestHud() then 40 else 52)
	body.AutomaticSize = Enum.AutomaticSize.None
	body.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	body.TextSize = if isCompactQuestHud() then 12 else 14
	body.TextColor3 = Color3.fromRGB(55, 42, 18)
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.TextScaled = false
	body.TextTruncate = Enum.TextTruncate.AtEnd
	body.Text = quest.description
	body.LayoutOrder = 2
	body.Parent = inner

	local payout = Instance.new("TextLabel")
	payout.BackgroundColor3 = Color3.fromRGB(40, 28, 8)
	payout.BackgroundTransparency = 0.25
	payout.Size = UDim2.new(1, 0, 0, 28)
	payout.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	payout.TextSize = 14
	payout.TextColor3 = Color3.fromRGB(255, 220, 80)
	payout.Text = "★  " .. TimCheeseQuestConfig.formatRewardLabel(quest)
	payout.LayoutOrder = 3
	payout.Parent = inner
	local payCorner = Instance.new("UICorner")
	payCorner.CornerRadius = UDim.new(0, 8)
	payCorner.Parent = payout
	local payPad = Instance.new("UIPadding")
	payPad.PaddingLeft = UDim.new(0, 8)
	payPad.PaddingRight = UDim.new(0, 8)
	payPad.Parent = payout

	local ticketScale = Instance.new("UIScale")
	ticketScale.Scale = 0.9
	ticketScale.Parent = ticket

	local mobile = isCompactQuestHud()
	local cam = Workspace.CurrentCamera
	local vw = if cam then cam.ViewportSize.X else 1280
	if mobile or vw < 700 then
		ticket.Size = UDim2.fromOffset(math.clamp(math.floor(vw * 0.88), 280, 360), 0)
	end

	local bangBobY = 0.0
	local bangT = 0.0
	local pulseConn = RunService.Heartbeat:Connect(function(dt)
		if not bang.Parent then
			return
		end
		bangT += dt
		local target = math.sin(bangT * 1.35) * 1.4
		local blend = math.min(1, dt * 6)
		bangBobY += (target - bangBobY) * blend
		bang.Position = UDim2.fromOffset(0, 4 + bangBobY)
	end)

	local enterInfo = TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(dim, TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.58 }):Play()
	TweenService:Create(ticketScale, enterInfo, { Scale = 1 }):Play()
	TweenService:Create(ticket, enterInfo, { Rotation = -2 }):Play()
	GameSoundEffects.playPurchase()

	task.wait(1.55)
	if not gui.Parent then
		pulseConn:Disconnect()
		questHoverFlying = false
		-- Popup got wiped (common on mobile UI restore) — still reveal the live HUD.
		questHudRevealed = true
		questAnimBusy = false
		refreshQuestHud({ skipRevealGate = true, playAppear = true })
		return
	end

	pulseConn:Disconnect()

	-- Build/measure HUD at final slot, park it inside the right border, then fly ticket in.
	questHudRevealed = true
	ensureQuestHud()
	layoutQuestHud()
	task.wait()
	layoutQuestHud()

	local panel = questPanel
	local slideW = 300
	local panelH = 110
	local topPad = questHudBaseTop
	local rightPad = questHudBaseRightPad
	local anchorY = questHudAnchorY
	if panel then
		local measuredW = math.max(panel.Size.X.Offset, 160)
		if panel.AbsoluteSize.X > 4 then
			measuredW = math.max(measuredW, math.ceil(panel.AbsoluteSize.X))
		end
		slideW = measuredW
		if panel.AbsoluteSize.Y > 4 then
			panelH = math.ceil(panel.AbsoluteSize.Y)
		else
			panelH = math.max(panel.Size.Y.Offset, TutorialConfig.PANEL_HEIGHT, 90)
		end
		questAnimBusy = true
		if questGui then
			questGui.Enabled = true
		end
		panel.Visible = true
		panel.AnchorPoint = Vector2.new(1, anchorY)
		panel.AutomaticSize = Enum.AutomaticSize.None
		panel.Size = UDim2.fromOffset(slideW, panelH)
		-- Park fully past the right edge ("inside" the border).
		panel.Position = UDim2.new(1, slideW + 36, 0, topPad)
		local ticketHud = panel:FindFirstChild("Ticket")
		if ticketHud and ticketHud:IsA("GuiObject") then
			ticketHud.Visible = true
		end
		if questArrowBtn then
			questArrowBtn.Visible = false
		end
	end

	-- Ticket flies into the border at the HUD's vertical center height.
	local midY = if anchorY >= 0.5 then topPad - panelH * 0.5 else topPad + panelH * 0.5
	local borderEntry = UDim2.new(1, 28, 0, midY)
	local flyInfo = TweenInfo.new(0.55, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
	TweenService:Create(dim, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(ticket, flyInfo, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = borderEntry,
		Rotation = 6,
	}):Play()
	TweenService:Create(ticketScale, flyInfo, { Scale = 0.28 }):Play()
	TweenService:Create(ticket, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 1,
	}):Play()
	for _, d in ticket:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			TweenService:Create(d, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			TweenService:Create(d, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				ImageTransparency = 1,
			}):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			}):Play()
		end
	end
	task.wait(0.56)

	if gui.Parent then
		gui:Destroy()
	end
	if acceptPopupGui == gui then
		acceptPopupGui = nil
	end

	-- HUD slides out of the border into its slot.
	questHoverFlying = false
	if panel and panel.Parent then
		local goal = UDim2.new(1, -rightPad, 0, topPad)
		local slideInfo = TweenInfo.new(0.48, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		if questArrowBtn then
			questArrowBtn.Visible = true
			questArrowBtn.Rotation = 180
			placeArrowOnTicket()
			TweenService:Create(questArrowBtn, slideInfo, { Rotation = 0 }):Play()
		end
		local tw = TweenService:Create(panel, slideInfo, { Position = goal })
		tw.Completed:Connect(function(playbackState)
			if playbackState ~= Enum.PlaybackState.Completed then
				questAnimBusy = false
				return
			end
			unfreezePanelAutoY(slideW)
			questAnimBusy = false
			refreshQuestHud({ skipRevealGate = true, playAppear = false })
			startExclaimPulse()
			if canShowQuestChrome() then
				startArrowPulse()
			end
		end)
		tw:Play()
	else
		questAnimBusy = false
		refreshQuestHud({ skipRevealGate = true, playAppear = false })
	end
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
	if typeof(quest.offerLine) == "string" and quest.offerLine ~= "" then
		return {
			{ text = quest.offerLine, shake = false },
			{ text = string.format("%s — %s", quest.title, quest.description), shake = false },
			{
				text = string.format("Reward: %s. You in?", TimCheeseQuestConfig.formatRewardLabel(quest)),
				shake = true,
			},
		}
	end
	local lead = if questIndex <= 1 then "Alright — first job's on the HOUSE!!" else "Fresh job just dropped. Listen up!!"
	return {
		{ text = lead, shake = true },
		{ text = string.format("%s — %s", quest.title, quest.description), shake = false },
		{
			text = string.format("Reward: %s. You in?", TimCheeseQuestConfig.formatRewardLabel(quest)),
			shake = true,
		},
	}
end

local function buildFirstOfferLines(): { { text: string, shake: boolean? } }
	return buildOfferLinesForIndex(1)
end

local function setTalkPromptEnabled(on: boolean)
	if talkPrompt and talkPrompt.Parent then
		talkPrompt.Enabled = on == true
		if on then
			pcall(function()
				ProximityPromptEffects.stylePrompt(talkPrompt :: ProximityPrompt)
			end)
		else
			pcall(function()
				ProximityPromptEffects.forceHide(talkPrompt :: ProximityPrompt)
			end)
		end
	end
end

local function acceptNextQuestAndShowHud(nextIndex: number)
	forcedQuestIndex = nextIndex
	questHudRevealed = false
	local acceptRF = getRF("AcceptQuest")
	local acceptedOk = false
	if acceptRF then
		local ok, result = pcall(function()
			return acceptRF:InvokeServer()
		end)
		acceptedOk = ok and result == true
		if not acceptedOk then
			task.wait(0.35)
			local ok2, result2 = pcall(function()
				return acceptRF:InvokeServer()
			end)
			acceptedOk = ok2 and result2 == true
			if not acceptedOk then
				warn("[TimCheeseQuestController] AcceptQuest rejected for quest", nextIndex, result2)
			end
		end
	else
		warn("[TimCheeseQuestController] AcceptQuest remote missing")
	end
	local q = TimCheeseQuestConfig.getQuest(nextIndex)
	if q then
		playQuestAcceptPopup(q)
	else
		questHudRevealed = true
		refreshQuestHud({ skipRevealGate = true, playAppear = false })
	end
	TopNotifController.showBroadcast("New quest from Tim Cheese!")
	return acceptedOk
end

local function resolveIntroLandCFrameNearPlayer(): CFrame?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end
	-- Land ahead of the player with room for a side / over-shoulder shot (not in the cam's face).
	local forward = hrp.CFrame.LookVector
	local right = hrp.CFrame.RightVector
	local flatDist = 16.5
	local side = 3.2
	local probe = hrp.Position + forward * flatDist + right * side + Vector3.new(0, 10, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = Workspace:Raycast(probe, Vector3.new(0, -42, 0), params)
	local ground = if hit then hit.Position else (hrp.Position + forward * flatDist + right * side)
	local landPos = Vector3.new(ground.X, ground.Y, ground.Z)
	return CFrame.lookAt(landPos, Vector3.new(hrp.Position.X, landPos.Y, hrp.Position.Z))
end

local function liftCloneToGround(clone: Model, groundY: number)
	local minY = math.huge
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local half = d.Size.Y * 0.5
			-- Conservative bottom using world AABB corners of the oriented part.
			local cf = d.CFrame
			local hs = d.Size * 0.5
			for _, ox in { -1, 1 } do
				for _, oy in { -1, 1 } do
					for _, oz in { -1, 1 } do
						local world = cf:PointToWorldSpace(Vector3.new(hs.X * ox, hs.Y * oy, hs.Z * oz))
						minY = math.min(minY, world.Y)
					end
				end
			end
			minY = math.min(minY, cf.Position.Y - half)
		end
	end
	if minY == math.huge then
		return
	end
	local lift = (groundY + 0.2) - minY
	if math.abs(lift) > 0.01 then
		clone:PivotTo(clone:GetPivot() + Vector3.new(0, lift, 0))
	end
end

local function speakOnHead(model: Model, message: string, holdSec: number?)
	if introDialogueSkip then
		return
	end
	local hold = if typeof(holdSec) == "number" then holdSec else TIM_LINE_HOLD
	local letterDelay = TIM_LETTER_DELAY
	startIntroTalkJump(model)
	StandDialogueCutscene.showWorldSpeech(model, message, {
		durationSec = hold,
		letterDelay = letterDelay,
		minDurationSec = 0,
		voicePitchMin = TIM_VOICE_PITCH_MIN,
		voicePitchMax = TIM_VOICE_PITCH_MAX,
		textSize = 20,
		billboardWidth = 380,
		billboardHeight = 88,
		studsOffset = Vector3.new(0, 1.05, 0),
	})
	local typeDur = #message * letterDelay + 0.08
	local t0 = os.clock()
	while os.clock() - t0 < typeDur do
		if introDialogueSkip then
			StandDialogueCutscene.cancelWorldSpeech()
			stopIntroTalkJump(model)
			return
		end
		task.wait()
	end
	stopIntroTalkJump(model)
	local holdLeft = hold + 0.08
	local t1 = os.clock()
	while os.clock() - t1 < holdLeft do
		if introDialogueSkip then
			StandDialogueCutscene.cancelWorldSpeech()
			return
		end
		task.wait()
	end
end

-- Tim fall cutscene disabled — quests start from post-tutorial delay instead.
function M.tryInterceptBushForIntro(_bush: Instance?): boolean
	return false
end

-- Reveal Tim + auto-accept first quest + quest appearance popup (no fall cutscene).
function M.beginQuestsWithoutAppearance()
	if introPlaying then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	local liveIdx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(liveIdx) == "number" and liveIdx >= 1 then
		introStartedLocal = true
		questHudRevealed = true
		local tim = resolveTim()
		if tim then
			revealTimForIntro(tim)
			ensureIdle(tim)
			setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
		end
		refreshQuestHud({ skipRevealGate = true, playAppear = false })
		syncPromptAndOutline()
		return
	end
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	if typeof(completed) == "number" and completed >= TimCheeseQuestConfig.questCount() then
		return
	end
	if introStartedLocal then
		return
	end
	introStartedLocal = true

	local tim = resolveTim()
	if tim then
		timModel = tim
		revealTimForIntro(tim)
		ensureIdle(tim)
		setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
	end

	local introRE = getRE("IntroDone")
	if introRE then
		introRE:FireServer()
	end

	acceptNextQuestAndShowHud(1)
	syncPromptAndOutline()
end

local postTutorialQuestToken = 0

local function waitForLuckyBlockOpenOrFallback(token: number)
	local opened = false
	local be = ReplicatedStorage:FindFirstChild("LuckyBlockOpenFinished")
	if not (be and be:IsA("BindableEvent")) then
		be = Instance.new("BindableEvent")
		be.Name = "LuckyBlockOpenFinished"
		be.Parent = ReplicatedStorage
	end
	local conn: RBXScriptConnection? = nil
	if be and be:IsA("BindableEvent") then
		conn = be.Event:Connect(function()
			opened = true
		end)
	end
	local fallback = TimCheeseQuestConfig.POST_TUTORIAL_LUCKY_OPEN_FALLBACK_SEC
	local started = os.clock()
	while os.clock() - started < fallback do
		if token ~= postTutorialQuestToken then
			if conn then
				conn:Disconnect()
			end
			return false
		end
		if opened then
			task.wait(TimCheeseQuestConfig.POST_TUTORIAL_AFTER_OPEN_SEC)
			if conn then
				conn:Disconnect()
			end
			return true
		end
		task.wait(0.12)
	end
	if conn then
		conn:Disconnect()
	end
	return true
end

local function schedulePostTutorialQuests()
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return
	end
	local liveIdx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(liveIdx) == "number" and liveIdx >= 1 then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true and introStartedLocal then
		-- Already past the first handoff.
		if questHudRevealed then
			return
		end
	end
	postTutorialQuestToken += 1
	local token = postTutorialQuestToken
	task.spawn(function()
		-- Let the starter lucky block reach the hotbar before we start listening.
		task.wait(TimCheeseQuestConfig.POST_TUTORIAL_QUEST_DELAY_SEC)
		if token ~= postTutorialQuestToken then
			return
		end
		if not waitForLuckyBlockOpenOrFallback(token) then
			return
		end
		if token ~= postTutorialQuestToken then
			return
		end
		if not player.Parent then
			return
		end
		M.beginQuestsWithoutAppearance()
	end)
end

function M.playIntroFall()
	-- Legacy entry point — redirect to non-cutscene quest start.
	M.beginQuestsWithoutAppearance()
end

function M.openTimDialogue()
	if dialogueBusy or introPlaying then
		return
	end
	local tim = timModel or resolveTim()
	if not tim then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) ~= true and not introStartedLocal then
		return
	end

	local timTalkRE = getRE("TimTalked")
	if timTalkRE then
		timTalkRE:FireServer()
	end

	local ready = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_READY_ATTR) == true
	local idx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	local hasQuest = typeof(idx) == "number" and idx >= 1
	local completed = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
	local doneCount = if typeof(completed) == "number" then completed else 0
	local claimedIndex = if hasQuest then math.floor(idx :: number) else 0

	-- Mid-mission: custom prompt → bubble only (no cutscene cam).
	if hasQuest and not ready then
		lockTalkPrompt(3.4)
		local lines = TimCheeseQuestConfig.IN_PROGRESS_LINES
		local msg = lines[math.random(1, #lines)]
		StandDialogueCutscene.showWorldSpeech(tim, msg, {
			durationSec = 1.4,
			letterDelay = TIM_LETTER_DELAY,
			minDurationSec = 0,
			voicePitchMin = TIM_VOICE_PITCH_MIN,
			voicePitchMax = TIM_VOICE_PITCH_MAX,
			textSize = 18,
			billboardWidth = 320,
			billboardHeight = 72,
		})
		task.delay(2.2, function()
			if not dialogueBusy and not introPlaying and not StandDialogueCutscene.isActive() then
				syncPromptAndOutline()
			end
		end)
		return
	end

	dialogueBusy = true
	setQuestHudSuppressed(true)
	lockTalkPrompt(0.5)
	setTalkPromptEnabled(false)
	setQuestFloatVisible(tim, false)
	setOutline(tim, false)

	if ready then
		local claimNow = StandDialogueCutscene.play({
			standName = "TimCheese",
			frameKey = "TimCheese",
			brainrotName = TimCheeseQuestConfig.IDLE_ANIM_NAME,
			enterLabel = "CLAIM",
			exitLabel = "LATER",
			lines = TimCheeseQuestConfig.COMPLETE_LINES,
			voicePitchMin = TIM_VOICE_PITCH_MIN,
			voicePitchMax = TIM_VOICE_PITCH_MAX,
		}, tim)
		if not claimNow then
			dialogueBusy = false
			setQuestHudSuppressed(false)
			syncPromptAndOutline()
			return
		end
		local claimRF = getRF("ClaimQuest")
		local ok, rewardLabel = false, nil :: any
		if claimRF then
			local invokeOk, a, b = pcall(function()
				return claimRF:InvokeServer()
			end)
			if invokeOk then
				ok = a == true
				rewardLabel = b
			end
		end
		forcedQuestIndex = nil
		if ok then
			fireQuestClaimCelebration()
			if typeof(rewardLabel) == "string" and rewardLabel ~= "" then
				TopNotifController.showBroadcast(rewardLabel)
			elseif typeof(rewardLabel) == "number" then
				TopNotifController.showBroadcast("+" .. BrainrotEconomy.formatCashShort(rewardLabel))
			end
		end
		-- Prefer the quest we just claimed (attribute may lag a frame).
		local nextIdx = claimedIndex + 1
		local completedAfter = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_COMPLETED_ATTR)
		if typeof(completedAfter) == "number" and completedAfter >= claimedIndex then
			nextIdx = math.floor(completedAfter) + 1
		end
		if nextIdx > TimCheeseQuestConfig.questCount() then
			for _, line in TimCheeseQuestConfig.ALL_DONE_LINES do
				speakOnHead(tim, line.text, TIM_LINE_HOLD_SHAKE)
			end
		else
			local offer = TimCheeseQuestConfig.getQuest(nextIdx)
			if offer then
				speakOnHead(tim, "Nice work!! Next job:", TIM_LINE_HOLD)
				speakOnHead(tim, string.format("%s — %s", offer.title, offer.description), 0.95)
				speakOnHead(tim, "Reward: " .. TimCheeseQuestConfig.formatRewardLabel(offer), TIM_LINE_HOLD)
			end
			acceptNextQuestAndShowHud(nextIdx)
		end
	elseif not hasQuest and doneCount < TimCheeseQuestConfig.questCount() then
		local nextIdx = math.floor(doneCount) + 1
		local offer = TimCheeseQuestConfig.getQuest(nextIdx)
		if offer then
			speakOnHead(tim, string.format("%s — %s", offer.title, offer.description), 0.95)
			speakOnHead(tim, "Reward: " .. TimCheeseQuestConfig.formatRewardLabel(offer), TIM_LINE_HOLD)
		end
		acceptNextQuestAndShowHud(nextIdx)
	end

	dialogueBusy = false
	setQuestHudSuppressed(false)
	restoreMovement()
	ensureQuestHudVisibleAfterDialogue()
	syncPromptAndOutline()
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
	StandDialogueCutscene.showWorldSpeech(tim, msg, { durationSec = 2.6, textSize = 18, billboardWidth = 320, billboardHeight = 72 })
	lockTalkPrompt(2.8)
end

local function applyHudFromAttributes()
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
		introStartedLocal = true
	end
	local liveIdx = player:GetAttribute(PlayerDataSchema.TIM_CHEESE_QUEST_INDEX_ATTR)
	if typeof(liveIdx) == "number" and liveIdx >= 1 then
		questHudRevealed = true
		refreshQuestHud()
		return
	end
	questHudRevealed = false
	syncQuestChromeVisibility()
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
		schedulePostTutorialQuests()
	end
end

local function applyWorldTimState(tim: Model)
	homePivot = tim:GetPivot()
	questHitbox = resolveHitbox()
	if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
		introStartedLocal = true
		ensureIdle(tim)
		revealTimForIntro(tim)
		setQuestFloatVisible(tim, true, TimCheeseQuestConfig.NO_QUEST_OVERHEAD)
		syncPromptAndOutline()
	else
		hideTimUntilIntro(tim)
		syncPromptAndOutline()
	end
end

function M.init()
	if wired then
		return
	end
	wired = true

	-- HUD must not wait for streamed Tim / map NPCs (phones often load him late).
	applyHudFromAttributes()

	player:GetAttributeChangedSignal(PlayerDataSchema.TUTORIAL_REPLAY_ATTR):Connect(function()
		introStartedLocal = false
		introPlaying = false
		forcedQuestIndex = nil
		questHudRevealed = false
		postTutorialQuestToken += 1
		dialogueBusy = false
		setQuestHudSuppressed(false)
		stopIntroTalkJump(timModel)
		local tim = timModel or resolveTim()
		if tim then
			hideTimUntilIntro(tim)
			setQuestFloatVisible(tim, false)
			setOutline(tim, false)
		end
		syncQuestChromeVisibility()
		syncPromptAndOutline()
	end)

	player:GetAttributeChangedSignal(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR):Connect(function()
		if player:GetAttribute(PlayerDataSchema.TIM_CHEESE_INTRO_ATTR) == true then
			introStartedLocal = true
			return
		end
		if introPlaying then
			return
		end
		introStartedLocal = false
		questHudRevealed = false
		forcedQuestIndex = nil
		local tim = timModel or resolveTim()
		if tim then
			hideTimUntilIntro(tim)
			setQuestFloatVisible(tim, false)
			setOutline(tim, false)
		end
		syncQuestChromeVisibility()
		syncPromptAndOutline()
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
			TopNotifController.showBroadcast("Quest completed! Go visit Tim Cheese")
		end
	end)
	player:GetAttributeChangedSignal(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR):Connect(function()
		syncPromptAndOutline()
		if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
			schedulePostTutorialQuests()
		end
	end)

	local viewportConn: RBXScriptConnection? = nil
	local function wireViewportLayout()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		local c = Workspace.CurrentCamera
		if not c then
			return
		end
		viewportConn = c:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if questPanel and questPanel.Visible and not questHoverFlying and questHudRevealed then
				layoutQuestHud()
			end
		end)
		if questHudRevealed then
			layoutQuestHud()
		else
			syncQuestChromeVisibility()
		end
	end
	wireViewportLayout()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(wireViewportLayout)
	startQuestLayoutSync()

	GameplayUiVisibility.onHidden(function()
		syncQuestHudCutsceneGate()
	end)
	GameplayUiVisibility.onRestored(function()
		syncQuestHudCutsceneGate()
	end)

	local accum = 0.0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < 0.2 then
			return
		end
		accum = 0
		tickWalkby()
		syncQuestHudCutsceneGate()
		syncPromptAndOutline()
	end)

	task.spawn(function()
		local deadline = os.clock() + 90
		while os.clock() < deadline do
			timModel = resolveTim()
			if timModel then
				break
			end
			task.wait(0.5)
		end
		if not timModel then
			warn("[TimCheeseQuestController] TimCheese missing")
			return
		end
		applyWorldTimState(timModel)
	end)

	ContextActionService:BindActionAtPriority(
		"TimCheeseQuestHudToggle",
		function(_name, state, _input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if dialogueBusy or introPlaying then
				return Enum.ContextActionResult.Pass
			end
			if GameplayCutsceneGate.isAmbushOrChaseActive() then
				return Enum.ContextActionResult.Pass
			end
			toggleQuestHudCollapsed()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.Default.Value,
		Enum.KeyCode.J,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.ButtonSelect
	)
end

return M
