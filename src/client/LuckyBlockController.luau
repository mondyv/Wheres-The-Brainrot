-- [ACTIVE] LuckyBlockController
--[[
	LuckyBlockController
	Client side of lucky block tools.

	On activate → LuckyBlockRoll. On LuckyBlockShakeStart → cinematic open:
	drop block → ground shake → burst → brainrot emerge/hover → hop to head → shrink in.
]]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CutsceneConfig = require(Shared:WaitForChild("LuckyBlockCutsceneConfig"))
local GearConfig = require(Shared:WaitForChild("GearConfig"))
local MobileTouchGate = require(Shared:WaitForChild("MobileTouchGate"))
local SafezoneUtil = require(Shared:WaitForChild("SafezoneUtil"))

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local CharacterWorldNotif = require(script.Parent.CharacterWorldNotif)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local OtherVfxController = require(script.Parent.OtherVfxController)
local TopNotifController = require(script.Parent.TopNotifController)
local GamepadInput = require(script.Parent.GamepadInput)

local player = Players.LocalPlayer

local LOCK_ACTION = "LuckyBlockCutsceneMoveLock"
local GUI_NAME = "LuckyBlockCutscene"

local OPEN_DENIED_MESSAGES = {
	"Can't open this here!",
	"Open lucky blocks at base!",
	"Head back to the safe zone!",
	"Not out here — open it at home!",
}

local LuckyBlockController = {}

local openedBindable: BindableEvent? = nil
local lastOpenedAt = -1e9

local function getOpenedBindable(): BindableEvent
	if openedBindable and openedBindable.Parent then
		return openedBindable
	end
	local existing = ReplicatedStorage:FindFirstChild("LuckyBlockOpenFinished")
	if existing and existing:IsA("BindableEvent") then
		openedBindable = existing
		return existing
	end
	local be = Instance.new("BindableEvent")
	be.Name = "LuckyBlockOpenFinished"
	be.Parent = ReplicatedStorage
	openedBindable = be
	return be
end

local function notifyLuckyBlockOpened()
	lastOpenedAt = os.clock()
	getOpenedBindable():Fire()
end

function LuckyBlockController.lastOpenedAt(): number
	return lastOpenedAt
end

local rollRE: RemoteEvent? = nil
local shakeStartRE: RemoteEvent? = nil
local denyRE: RemoteEvent? = nil
local activeAuraSound: Sound? = nil
local cutsceneToken = 0
local cutsceneRunning = false
local lastLocalDenyAt = 0

local cameraConn: RBXScriptConnection? = nil
local shakeConn: RBXScriptConnection? = nil
local floatConn: RBXScriptConnection? = nil
local hopConn: RBXScriptConnection? = nil
local shrinkConn: RBXScriptConnection? = nil
local revealWatchConn: RBXScriptConnection? = nil

local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov: number? = nil
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil
local cutsceneGui: ScreenGui? = nil
local letterTop: Frame? = nil
local letterBottom: Frame? = nil
local focusPart: BasePart? = nil
local blockModel: Model? = nil
local camShakeAmp = 0
local camShotFrom: Vector3? = nil
local camShotLook: Vector3? = nil
local camFovGoal = 64
local camPull = 1
local hiddenTool: Tool? = nil
local hiddenToolTrans: { [BasePart]: number } = {}
local hiddenToolDecalTrans: { [Decal | Texture]: number } = {}
local keepToolHiddenConn: RBXScriptConnection? = nil

local function isLuckyBlockTool(tool: Instance): boolean
	return tool:IsA("Tool") and tool:GetAttribute("LuckyBlockTool") == true
end

-- SoundService.SoundEffects["Luckyblock sfx"] child names.
local LUCKY_HOLD_SFX_BY_KIND: { [string]: string } = {
	["Starter Lucky Block"] = "Starter Block",
	["troll"] = "Troll Block",
	["neon"] = "Neon Block",
	["1"] = "Neon Block",
	["Mythic Lucky Block"] = "Mythic Block",
	["purple"] = "Hell Block",
	["yellow"] = "Yellow Block",
	["Godly Luckyblock"] = "Godly Block",
	["heart"] = "Heart Block",
	["chamber"] = "Galaxy Block",
	["rainbow"] = "Rainbow Block",
	["Secret Lucky Block"] = "Secret Block",
	["star"] = "Star Block",
	["ruby"] = "Ruby Block",
	["1 opposite"] = "Secret Block Mutated",
	["Star-Rainbow"] = "Secret Rainbow Block",
	["star rainbow"] = "Secret Rainbow Block",
}

local function resolveLuckyHoldSfxKey(tool: Tool): string?
	local kind = tool:GetAttribute("LuckyBlockKind")
	if typeof(kind) == "string" then
		local mapped = LUCKY_HOLD_SFX_BY_KIND[kind]
		if mapped then
			return mapped
		end
		local lower = string.lower(kind)
		for id, sfx in LUCKY_HOLD_SFX_BY_KIND do
			if string.lower(id) == lower then
				return sfx
			end
		end
	end
	-- "Troll Lucky Block" → "Troll Block"
	local name = tool.Name
	local stripped = string.gsub(name, " Lucky", "")
	if stripped ~= "" then
		return stripped
	end
	return nil
end

local function canOpenLuckyBlockInZone(): boolean
	local char = player.Character
	if not char then
		return false
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if SafezoneUtil.isCharacterInSafezone(char) then
		return true
	end
	if SafezoneUtil.isCharacterInToolbarZone(char) then
		return true
	end
	if SafezoneUtil.isCharacterInInventoryZone(char) then
		return true
	end
	if hrp and hrp:IsA("BasePart") and SafezoneUtil.isWorldPointInRedWall((hrp :: BasePart).Position) then
		return true
	end
	return false
end

local function showOpenDeniedNotif(message: string?)
	local now = os.clock()
	if now - lastLocalDenyAt < 1.05 then
		return
	end
	lastLocalDenyAt = now
	local msg = if typeof(message) == "string" and message ~= ""
		then message
		else OPEN_DENIED_MESSAGES[math.random(1, #OPEN_DENIED_MESSAGES)]
	TopNotifController.showError(msg)
	pcall(function()
		GameSoundEffects.playErrorNotif()
	end)
	CharacterWorldNotif.show(player.Character, msg, {
		color = Color3.fromRGB(255, 150, 120),
		offset = Vector3.new(2.4, 1.55, 0),
		lifetimeSec = 3.2,
		ellipsis = false,
		hideRankBadges = true,
	})
end

local function getHRP(): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

local function bushAuraTemplate(): Sound?
	local root = SoundService:FindFirstChild("SoundEffects")
	local aura = root and root:FindFirstChild("BushAura")
	if not aura then
		return nil
	end
	local s = aura:FindFirstChild("Secret/Godly Bush Aura")
	if s and s:IsA("Sound") then
		return s
	end
	return nil
end

local function stopAura()
	if activeAuraSound then
		pcall(function()
			activeAuraSound:Stop()
		end)
		activeAuraSound:Destroy()
		activeAuraSound = nil
	end
end

local function startAura()
	stopAura()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local template = bushAuraTemplate()
	if not template then
		return
	end
	local originalVolume = template.Volume
	local clone = template:Clone()
	local sfxGroup = ClientSFXVolume.getSoundGroup()
	if sfxGroup then
		clone.SoundGroup = sfxGroup
		clone.Volume = originalVolume
	else
		clone.Volume = originalVolume * ClientSFXVolume.getVolume()
	end
	clone.Looped = true
	clone.Parent = SoundService
	clone:Play()
	activeAuraSound = clone
end

local function disconnect(conn: RBXScriptConnection?)
	if conn then
		conn:Disconnect()
	end
end

local function stopAnimConns()
	disconnect(cameraConn)
	cameraConn = nil
	disconnect(shakeConn)
	shakeConn = nil
	disconnect(floatConn)
	floatConn = nil
	disconnect(hopConn)
	hopConn = nil
	disconnect(shrinkConn)
	shrinkConn = nil
	disconnect(revealWatchConn)
	revealWatchConn = nil
end

local function clearToolHideState()
	disconnect(keepToolHiddenConn)
	keepToolHiddenConn = nil
	if hiddenTool and hiddenTool.Parent then
		for part, t in hiddenToolTrans do
			if part.Parent then
				part.Transparency = t
				part.LocalTransparencyModifier = 0
			end
		end
		for d, t in hiddenToolDecalTrans do
			if d.Parent then
				d.Transparency = t
				if d:IsA("Decal") or d:IsA("Texture") then
					(d :: any).LocalTransparencyModifier = 0
				end
			end
		end
	end
	table.clear(hiddenToolTrans)
	table.clear(hiddenToolDecalTrans)
	hiddenTool = nil
end

local function forceHideToolVisual(tool: Tool)
	clearToolHideState()
	hiddenTool = tool
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			hiddenToolTrans[d] = d.Transparency
			d.Transparency = 1
			d.LocalTransparencyModifier = 1
		elseif d:IsA("Decal") or d:IsA("Texture") then
			hiddenToolDecalTrans[d] = d.Transparency
			d.Transparency = 1
			pcall(function()
				(d :: any).LocalTransparencyModifier = 1
			end)
		end
	end
	-- Keep re-applying — tool weld/replication can snap transparency back briefly.
	disconnect(keepToolHiddenConn)
	keepToolHiddenConn = RunService.Heartbeat:Connect(function()
		if not hiddenTool or not hiddenTool.Parent then
			disconnect(keepToolHiddenConn)
			keepToolHiddenConn = nil
			return
		end
		for part in hiddenToolTrans do
			if part.Parent then
				part.Transparency = 1
				part.LocalTransparencyModifier = 1
			end
		end
	end)
end

local function setToolHidden(tool: Tool?, hidden: boolean)
	if not tool then
		return
	end
	if hidden then
		forceHideToolVisual(tool)
	else
		clearToolHideState()
	end
end

local function destroyBlockModel()
	if blockModel and blockModel.Parent then
		blockModel:Destroy()
	end
	blockModel = nil
	focusPart = nil
end

local function lockMovement()
	local hum = getHumanoid()
	if hum then
		if savedWalkSpeed == nil then
			savedWalkSpeed = hum.WalkSpeed
			savedJumpPower = hum.JumpPower
			savedJumpHeight = hum.JumpHeight
			savedUseJumpPower = hum.UseJumpPower
			savedAutoRotate = hum.AutoRotate
		end
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
	end
	ContextActionService:BindAction(LOCK_ACTION, function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
end

local function unlockMovement()
	ContextActionService:UnbindAction(LOCK_ACTION)
	MobileTouchGate.ensureTouchControlsVisible(true)
	MobileTouchGate.restorePlayerMovement()
	local hum = getHumanoid()
	if hum then
		if savedWalkSpeed ~= nil then
			hum.WalkSpeed = savedWalkSpeed
		end
		if savedJumpPower ~= nil then
			hum.JumpPower = savedJumpPower
		end
		if savedJumpHeight ~= nil then
			hum.JumpHeight = savedJumpHeight
		end
		if savedUseJumpPower ~= nil then
			hum.UseJumpPower = savedUseJumpPower
		end
		if savedAutoRotate ~= nil then
			hum.AutoRotate = savedAutoRotate
		end
	end
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil
end

local function ensureLetterbox(): ScreenGui
	if cutsceneGui and cutsceneGui.Parent and letterTop and letterBottom then
		return cutsceneGui
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 945
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, 0, 0)
	top.Size = UDim2.new(1.2, 0, 0.12, 0)
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.new(0.5, 0, 1, 0)
	bottom.Size = UDim2.new(1.2, 0, 0.12, 0)
	bottom.Parent = gui

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	return gui
end

local function destroyLetterbox()
	if cutsceneGui then
		cutsceneGui:Destroy()
	end
	cutsceneGui = nil
	letterTop = nil
	letterBottom = nil
end

local function restoreGameplayCamera()
	stopAnimConns()
	camShakeAmp = 0
	camShotFrom = nil
	camShotLook = nil
	focusPart = nil

	local cam = Workspace.CurrentCamera
	local hum = getHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		if hum then
			cam.CameraSubject = hum
		end
		cam.FieldOfView = if typeof(savedFov) == "number" then savedFov else 70
	end
	savedCameraType = nil
	savedCameraSubject = nil
	savedFov = nil
end

local function restoreCamera()
	restoreGameplayCamera()
end

local function faceToward(target: Vector3)
	local hrp = getHRP()
	if not hrp then
		return
	end
	local flat = Vector3.new(target.X - hrp.Position.X, 0, target.Z - hrp.Position.Z)
	if flat.Magnitude < 0.05 then
		return
	end
	hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + flat.Unit)
end

local function resolveGroundCf(hrp: BasePart, nearPos: Vector3?): CFrame
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local probe = if typeof(nearPos) == "Vector3"
		then nearPos + Vector3.new(0, 2.5, 0)
		else hrp.Position + flat * 5.8 + Vector3.new(0, 2.5, 0)
	local fallbackY = if typeof(nearPos) == "Vector3" then nearPos.Y else hrp.Position.Y
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local char = player.Character
	if char then
		params.FilterDescendantsInstances = { char }
	end
	local hit = Workspace:Raycast(probe, Vector3.new(0, -18, 0), params)
	local groundY = if hit then hit.Position.Y else (fallbackY - 3)
	local pos = Vector3.new(probe.X, groundY + 0.65, probe.Z)
	return CFrame.lookAt(pos, Vector3.new(hrp.Position.X, pos.Y, hrp.Position.Z))
end

local function nudgePrimaryPartOntoGround(model: Model, groundCf: CFrame)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		return
	end
	local pivot = model:GetPivot()
	local halfY = primary.Size.Y * 0.5
	local bottomY = pivot.Position.Y - halfY
	local targetY = groundCf.Position.Y
	if bottomY < targetY - 0.05 then
		model:PivotTo(pivot + Vector3.new(0, targetY - bottomY + 0.05, 0))
	end
end

local function cloneToolAsWorldModel(tool: Tool, atCf: CFrame): Model?
	local model = Instance.new("Model")
	model.Name = "LuckyBlockCutsceneBlock"
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		model:Destroy()
		return nil
	end
	local baseCf = handle.CFrame
	local primary: BasePart? = nil
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			local c = d:Clone()
			c.Anchored = true
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.Massless = true
			-- Keep source transparency (invisible hitboxes stay invisible; don't force them opaque).
			local nameLower = string.lower(d.Name)
			local hidePart = d.Transparency >= 1
				or nameLower == "hitbox"
				or nameLower == "collision"
				or string.find(nameLower, "hitbox", 1, true) ~= nil
			c.Transparency = if hidePart then 1 else d.Transparency
			c.LocalTransparencyModifier = 0
			c.Parent = model
			local offset = baseCf:ToObjectSpace(d.CFrame)
			c.CFrame = atCf * offset
			if d == handle then
				primary = c
			end
			for _, ch in c:GetChildren() do
				if ch:IsA("BillboardGui") or ch:IsA("SurfaceGui") then
					ch:Destroy()
				elseif ch:IsA("Decal") or ch:IsA("Texture") then
					if c.Transparency >= 1 then
						ch.Transparency = 1
					end
					pcall(function()
						(ch :: any).LocalTransparencyModifier = 0
					end)
				end
			end
		end
	end
	if primary then
		model.PrimaryPart = primary
	elseif model:FindFirstChildWhichIsA("BasePart", true) then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not model.PrimaryPart then
		model:Destroy()
		return nil
	end
	model.Parent = Workspace
	return model
end

local function cloneTemplateAsWorldModel(blockKind: string, variant: string?, atCf: CFrame): Model?
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	local folder = root and root:FindFirstChild("lucky blocks")
	local searchRoot = folder or root
	if not searchRoot then
		return nil
	end
	local node: Instance? = searchRoot:FindFirstChild(blockKind)
	if not node then
		for _, d in ipairs(searchRoot:GetDescendants()) do
			if d.Name == blockKind then
				node = d
				break
			end
		end
	end
	if not node then
		return nil
	end
	local template: Model? = nil
	if typeof(variant) == "string" and variant ~= "" then
		local exact = node:FindFirstChild(variant)
		if exact and exact:IsA("Model") then
			template = exact
		end
	end
	if not template then
		if node:IsA("Model") then
			local child = node:FindFirstChildWhichIsA("Model", true)
			template = if child and child:IsA("Model") then child else (node :: Model)
		else
			template = node:FindFirstChildWhichIsA("Model", true)
		end
	end
	if not template then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "LuckyBlockCutsceneBlock"
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	if not clone.PrimaryPart then
		clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart", true)
	end
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	clone:PivotTo(atCf)
	clone.Parent = Workspace
	return clone
end

local function modelFocus(model: Model): Vector3
	local ok, boxCf, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(boxCf) == "CFrame" and typeof(boxSize) == "Vector3" then
		return boxCf.Position + Vector3.new(0, boxSize.Y * 0.05, 0)
	end
	return model:GetPivot().Position
end

local function pokemonShot(lookAt: Vector3, hrp: BasePart): (Vector3, Vector3)
	local away = Vector3.new(hrp.Position.X - lookAt.X, 0, hrp.Position.Z - lookAt.Z)
	if away.Magnitude < 1 then
		local look = hrp.CFrame.LookVector
		away = Vector3.new(look.X, 0, look.Z)
	end
	if away.Magnitude < 0.05 then
		away = Vector3.zAxis
	else
		away = away.Unit
	end
	local side = Vector3.new(-away.Z, 0, away.X)
	local pull = math.clamp(camPull, 1, 1.45)
	-- Three-quarter wide shot so the drop, burst, and reveal all read on screen.
	local from = lookAt + away * (14.8 * pull) + side * (6.4 * pull) + Vector3.new(0, 7.2 * pull, 0)
	return from, lookAt + Vector3.new(0, 1.85, 0)
end

local function startCinematicCamera(token: number, lookAt: Vector3)
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if not cam or not hrp then
		return
	end
	savedCameraType = cam.CameraType
	savedCameraSubject = cam.CameraSubject
	savedFov = cam.FieldOfView
	cam.CameraType = Enum.CameraType.Scriptable
	camFovGoal = 64
	cam.FieldOfView = 64

	local from, look = pokemonShot(lookAt, hrp)
	camShotFrom = from
	camShotLook = look

	local blendFrom = cam.CFrame
	local blendT0 = os.clock()
	local blendDur = 0.7
	local phase = 0

	disconnect(cameraConn)
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if token ~= cutsceneToken then
			return
		end
		local liveCam = Workspace.CurrentCamera
		local hum = getHumanoid()
		if not liveCam then
			return
		end
		if hum then
			hum:Move(Vector3.zero, false)
		end
		phase += dt

		local liveHrp = getHRP()
		local aim = lookAt
		if focusPart and focusPart.Parent then
			aim = focusPart.Position + Vector3.new(0, 1.35, 0)
		end
		local shotFrom, shotLook = from, look
		if liveHrp then
			shotFrom, shotLook = pokemonShot(aim, liveHrp)
		else
			shotLook = aim
		end
		camShotFrom = shotFrom
		camShotLook = shotLook

		local shake = Vector3.zero
		if camShakeAmp > 0.001 then
			local t = phase
			local amp = camShakeAmp
			shake = Vector3.new(
				(math.sin(t * 23.1) + math.sin(t * 41.7) * 0.45) * amp,
				(math.cos(t * 19.4) + math.sin(t * 53.2) * 0.35) * amp * 0.55,
				(math.sin(t * 17.8) + math.cos(t * 29.6) * 0.4) * amp * 0.4
			)
		end

		local goal = CFrame.lookAt(shotFrom + shake, shotLook)
		local blendAlpha = math.clamp((os.clock() - blendT0) / blendDur, 0, 1)
		local eased = 1 - (1 - blendAlpha) ^ 3
		if blendAlpha < 1 then
			liveCam.CFrame = blendFrom:Lerp(goal, eased)
		else
			liveCam.CFrame = goal
		end
		local fovNow = liveCam.FieldOfView
		liveCam.FieldOfView = fovNow + (camFovGoal - fovNow) * math.clamp(dt * 4.2, 0, 1)
	end)
end

local function waitToken(token: number, sec: number)
	local t0 = os.clock()
	while os.clock() - t0 < sec do
		if token ~= cutsceneToken then
			return false
		end
		task.wait(0.05)
	end
	return token == cutsceneToken
end

local function findRevealModel(): Model?
	local folder = Workspace:FindFirstChild(CutsceneConfig.REVEAL_FOLDER_NAME)
	if not folder then
		return nil
	end
	for _, c in folder:GetChildren() do
		if c:IsA("Model") and c:GetAttribute(CutsceneConfig.REVEAL_ATTR) == true then
			if c:GetAttribute(CutsceneConfig.OWNER_ATTR) == player.UserId then
				return c
			end
		end
	end
	return nil
end

local function waitForReveal(token: number, timeoutSec: number): Model?
	local existing = findRevealModel()
	if existing then
		return existing
	end
	local folder = Workspace:FindFirstChild(CutsceneConfig.REVEAL_FOLDER_NAME)
		or Workspace:WaitForChild(CutsceneConfig.REVEAL_FOLDER_NAME, timeoutSec)
	if not folder or token ~= cutsceneToken then
		return findRevealModel()
	end
	local found: Model? = nil
	local done = false
	disconnect(revealWatchConn)
	revealWatchConn = folder.ChildAdded:Connect(function(c)
		if done then
			return
		end
		if c:IsA("Model") and c:GetAttribute(CutsceneConfig.REVEAL_ATTR) == true then
			if c:GetAttribute(CutsceneConfig.OWNER_ATTR) == player.UserId then
				found = c
				done = true
			end
		end
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeoutSec do
		if token ~= cutsceneToken then
			break
		end
		local again = findRevealModel()
		if again then
			found = again
			done = true
			break
		end
		task.wait(0.05)
	end
	disconnect(revealWatchConn)
	revealWatchConn = nil
	return found
end

local function animateGroundShake(model: Model, durationSec: number, token: number)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		return
	end
	focusPart = primary
	local baseCf = model:GetPivot()
	local t0 = os.clock()
	camShakeAmp = 0.08
	disconnect(shakeConn)
	shakeConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			camShakeAmp = 0
			disconnect(shakeConn)
			shakeConn = nil
			return
		end
		local elapsed = os.clock() - t0
		local frac = math.clamp(elapsed / durationSec, 0, 1)
		local amp = 0.07 + frac * 0.28
		camShakeAmp = 0.05 + frac * 0.16
		local t = elapsed * math.pi * 2
		local jx = math.sin(t * 7.3) * amp + math.sin(t * 13.1) * amp * 0.35
		local jz = math.cos(t * 6.1) * amp * 0.85 + math.sin(t * 11.4) * amp * 0.28
		local jy = math.abs(math.sin(t * 9.2)) * amp * 0.32
		local tilt = math.sin(t * 5.4) * math.rad(5 + frac * 8)
		local roll = math.cos(t * 4.7) * math.rad(4 + frac * 6)
		local yaw = math.sin(t * 3.3) * math.rad(6 + frac * 4)
		model:PivotTo(baseCf * CFrame.new(jx, jy, jz) * CFrame.Angles(tilt, yaw, roll))
		if elapsed >= durationSec then
			model:PivotTo(baseCf)
			camShakeAmp = 0
			disconnect(shakeConn)
			shakeConn = nil
		end
	end)
	waitToken(token, durationSec)
	camShakeAmp = 0
end

local function spawnBurstDebris(at: Vector3)
	local ring = Instance.new("Part")
	ring.Name = "LuckyBlockBurstRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 210, 80)
	ring.Size = Vector3.new(0.35, 2.4, 2.4)
	ring.CFrame = CFrame.new(at + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, 18, 18),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.55)

	for i = 1, 48 do
		local chip = Instance.new("Part")
		chip.Name = "LuckyBlockBurstChip"
		local scale = 0.55 + math.random() * 1.35
		chip.Size = Vector3.new(0.7, 0.45, 0.9) * scale
		local roll = i % 4
		chip.Color = if roll == 0
			then Color3.fromRGB(255, 210, 80)
			elseif roll == 1 then Color3.fromRGB(255, 160, 40)
			elseif roll == 2 then Color3.fromRGB(90, 70, 40)
			else Color3.fromRGB(255, 240, 140)
		chip.Material = if roll == 2 then Enum.Material.Slate else Enum.Material.Neon
		chip.Anchored = true
		chip.CanCollide = false
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		local ang = math.rad(i * (360 / 48) + math.random() * 10)
		chip.CFrame = CFrame.new(at + Vector3.new(0, 0.4, 0))
		chip.Parent = Workspace
		local dir = Vector3.new(math.cos(ang), 0.55 + math.random() * 1.1, math.sin(ang)).Unit
		local goal = at + dir * (5 + math.random() * 10) + Vector3.new(0, 2 + math.random() * 5, 0)
		TweenService:Create(chip, TweenInfo.new(0.5 + math.random() * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(goal) * CFrame.Angles(math.random() * 5, math.random() * 5, math.random() * 5),
			Transparency = 1,
			Size = chip.Size * 0.15,
		}):Play()
		Debris:AddItem(chip, 1.0)
	end
end

local function spawnCollectSpark(at: Vector3)
	local spark = Instance.new("Part")
	spark.Name = "LuckyBlockCollectSpark"
	spark.Anchored = true
	spark.CanCollide = false
	spark.CanQuery = false
	spark.CanTouch = false
	spark.CastShadow = false
	spark.Material = Enum.Material.Neon
	spark.Color = Color3.fromRGB(255, 228, 120)
	spark.Size = Vector3.new(0.18, 0.18, 0.18)
	spark.Shape = Enum.PartType.Ball
	spark.CFrame = CFrame.new(at)
	spark.Parent = Workspace
	TweenService:Create(spark, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.04, 0.04, 0.04),
		Transparency = 1,
	}):Play()
	Debris:AddItem(spark, 0.35)
end

local function smootherstep(alpha: number): number
	local a = math.clamp(alpha, 0, 1)
	return a * a * a * (a * (a * 6 - 15) + 10)
end

local function headCarryCf(): CFrame?
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.CFrame * CFrame.new(0, head.Size.Y * 0.55 + 1.05, 0)
	end
	local hrp = getHRP()
	if hrp then
		return hrp.CFrame * CFrame.new(0, 2.35, 0)
	end
	return nil
end

-- One Heartbeat path: emerge → hover → hop → settle. Same bob wave the whole
-- time so phase handoffs never snap position or rotation.
local function animateRevealMotion(model: Model, token: number)
	local startCf = model:GetPivot()
	local startPos = startCf.Position
	local hoverHome = startPos + Vector3.new(0, 2.45, 0)
	local emergeSec = CutsceneConfig.EMERGE_SEC
	local hoverSec = CutsceneConfig.HOVER_SEC
	local hopSec = CutsceneConfig.HOP_SEC
	local settleSec = CutsceneConfig.SHRINK_SEC
	local hopAt = emergeSec + hoverSec
	local settleAt = hopAt + hopSec
	local total = settleAt + settleSec
	local bobHz = 3.35
	local bobAmp = 0.38

	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		focusPart = primary
	end

	local hopFrom: Vector3? = nil
	local hopVel = Vector3.zero
	local hopLanded = false
	local t0 = os.clock()
	local pull0 = camPull
	local fov0 = camFovGoal

	local function bobY(elapsed: number): number
		return math.sin(elapsed * bobHz) * bobAmp
	end

	disconnect(floatConn)
	disconnect(hopConn)
	disconnect(shrinkConn)
	floatConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			disconnect(floatConn)
			floatConn = nil
			return
		end
		local elapsed = os.clock() - t0
		local pos: Vector3
		local wag = math.sin(elapsed * 6.8) * 0.18
		local nod = math.sin(elapsed * 5.1) * 0.12
		local spin = CFrame.Angles(nod, elapsed * 1.15 + math.sin(elapsed * 2.4) * 0.35, wag)

		if elapsed < emergeSec then
			local a = smootherstep(elapsed / emergeSec)
			pos = startPos:Lerp(hoverHome, a)
			pos += Vector3.new(math.sin(elapsed * 7.2) * 0.12 * a, bobY(elapsed) * a, math.cos(elapsed * 5.6) * 0.1 * a)
			camPull = pull0 + (1.16 - pull0) * a
			camFovGoal = fov0 + (56 - fov0) * a
		elseif elapsed < hopAt then
			pos = hoverHome + Vector3.new(math.sin(elapsed * 7.2) * 0.14, bobY(elapsed), math.cos(elapsed * 5.6) * 0.12)
			camPull = 1.16
			camFovGoal = 56
		elseif elapsed < settleAt then
			if hopFrom == nil then
				hopFrom = model:GetPivot().Position
				local vy = bobHz * bobAmp * math.cos(hopAt * bobHz)
				hopVel = Vector3.new(0, vy, 0)
			end
			-- Linear hermite keeps hover velocity; bump has 0 slope at both ends.
			local a = math.clamp((elapsed - hopAt) / hopSec, 0, 1)
			local dest = headCarryCf()
			local p0 = hopFrom :: Vector3
			local p1 = if dest then dest.Position else p0
			local a2 = a * a
			local a3 = a2 * a
			local h00 = 2 * a3 - 3 * a2 + 1
			local h10 = a3 - 2 * a2 + a
			local h01 = -2 * a3 + 3 * a2
			pos = p0 * h00 + (hopVel * hopSec) * h10 + p1 * h01
			pos += Vector3.new(0, 22 * a2 * (1 - a) * (1 - a) * 2.8, 0)
			camPull = 1.16 - a * 0.04
			camFovGoal = 56 + a * 4
			if a > 0.9 and not hopLanded then
				hopLanded = true
				spawnCollectSpark(p1)
				GameSoundEffects.playCashGrab()
				camShakeAmp = 0.045
			end
			camShakeAmp *= 0.9
		else
			local dest = headCarryCf()
			pos = if dest then dest.Position else (hopFrom or hoverHome)
			camPull = 1.12
			camFovGoal = 60
			camShakeAmp *= 0.84
		end

		model:PivotTo(CFrame.new(pos) * startCf.Rotation * spin)
		if primary and primary.Parent then
			focusPart = primary
		end
		if elapsed >= total then
			disconnect(floatConn)
			floatConn = nil
		end
	end)

	while floatConn do
		if token ~= cutsceneToken then
			return
		end
		RunService.Heartbeat:Wait()
	end
	camShakeAmp = 0
	focusPart = nil
end

local function hideLuckyOpenHints()
	local function strip(root: Instance?)
		if not root then
			return
		end
		for _, d in root:GetDescendants() do
			if d.Name == "LuckyOpenHint" then
				d:Destroy()
			end
		end
	end
	strip(player.Character)
	strip(player:FindFirstChildOfClass("Backpack"))
end

local function endCutscene(token: number)
	if token ~= cutsceneToken then
		return
	end
	cutsceneToken += 1
	cutsceneRunning = false
	camShakeAmp = 0
	camPull = 1
	camShotFrom = nil
	camShotLook = nil
	focusPart = nil
	stopAnimConns()
	stopAura()
	GameSoundEffects.stopLuckyBlockShake()
	GameSoundEffects.stopLuckyBlockOpenSfx()
	destroyBlockModel()
	clearToolHideState()
	destroyLetterbox()
	restoreGameplayCamera()
	unlockMovement()
	GameplayUiVisibility.show()
end

local function runCutscene(payload: any)
	cutsceneToken += 1
	local token = cutsceneToken
	cutsceneRunning = true
	stopAnimConns()
	destroyBlockModel()
	hideLuckyOpenHints()
	camShakeAmp = 0
	camPull = 1
	camFovGoal = 64

	local dropSec = if typeof(payload.dropSec) == "number" then payload.dropSec else CutsceneConfig.DROP_SEC
	local groundShakeSec = if typeof(payload.groundShakeSec) == "number"
		then payload.groundShakeSec
		else CutsceneConfig.GROUND_SHAKE_SEC
	local worldDrop = payload.worldDrop == true
	local dropOrigin = if typeof(payload.dropOrigin) == "Vector3" then payload.dropOrigin else nil
	local blockKind = if typeof(payload.blockKind) == "string" then payload.blockKind else nil
	local blockVariant = if typeof(payload.blockVariant) == "string" then payload.blockVariant else nil

	local char = player.Character
	local hrp = getHRP()
	if not char or not hrp then
		return
	end

	if worldDrop then
		local label = if typeof(blockKind) == "string" then blockKind else "Lucky Block"
		local okCat, Catalog = pcall(function()
			return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
		end)
		if okCat and Catalog and typeof(Catalog.displayName) == "function" and typeof(blockKind) == "string" then
			label = Catalog.displayName(blockKind)
		end
		TopNotifController.showPersonal(label .. "!", "legendary", 3.2)
	end

	local tool: Tool? = nil
	if not worldDrop then
		for _, c in ipairs(char:GetChildren()) do
			if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
				tool = c
				break
			end
		end
		if not tool then
			local bp = player:FindFirstChildOfClass("Backpack")
			if bp then
				for _, c in ipairs(bp:GetChildren()) do
					if c:IsA("Tool") and c:GetAttribute("LuckyBlockTool") == true then
						tool = c
						break
					end
				end
			end
		end
	end

	ensureLetterbox()
	GameplayUiVisibility.hide({
		keepScreenGuiNames = { GUI_NAME, "TutorialUiPointer" },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
	lockMovement()

	local groundCf = resolveGroundCf(hrp, dropOrigin)
	faceToward(groundCf.Position)

	local handCf = hrp.CFrame * CFrame.new(0.6, 1.1, -1.1)
	if worldDrop and dropOrigin then
		handCf = CFrame.new(dropOrigin + Vector3.new(0, 7.5, 0))
	elseif tool then
		local handle = tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			handCf = handle.CFrame
		end
		-- Clone the visible tool FIRST, then hide / unequip so the hand is empty.
		blockModel = cloneToolAsWorldModel(tool, handCf)
		local hum = getHumanoid()
		if hum then
			pcall(function()
				hum:UnequipTools()
			end)
		end
		-- Tool may now be in Backpack — still hide so hotbar flash doesn't show it.
		forceHideToolVisual(tool)
	end

	if worldDrop and typeof(blockKind) == "string" then
		blockModel = cloneTemplateAsWorldModel(blockKind, blockVariant, handCf)
	end

	-- If clone failed, still don't leave a block in-hand for the cutscene.
	if not blockModel then
		local placeholder = Instance.new("Part")
		placeholder.Name = "LuckyBlockCutsceneBlock"
		placeholder.Anchored = true
		placeholder.CanCollide = false
		placeholder.CanQuery = false
		placeholder.CanTouch = false
		placeholder.Material = Enum.Material.Neon
		placeholder.Color = Color3.fromRGB(255, 210, 80)
		placeholder.Size = Vector3.new(2.2, 2.2, 2.2)
		placeholder.CFrame = handCf
		local model = Instance.new("Model")
		model.Name = "LuckyBlockCutsceneBlock"
		placeholder.Parent = model
		model.PrimaryPart = placeholder
		model.Parent = Workspace
		blockModel = model
	end

	startCinematicCamera(token, groundCf.Position)
	-- No looping Godly/angelic bush aura during this cutscene.

	-- Drop to ground in front of the player (or beside the bush for world drops).
	if blockModel and blockModel.Parent then
		local dropModel = blockModel
		local startDrop = handCf
		dropModel:PivotTo(startDrop)
		local t0 = os.clock()
		while os.clock() - t0 < dropSec do
			if token ~= cutsceneToken then
				endCutscene(token)
				return
			end
			local alpha = math.clamp((os.clock() - t0) / dropSec, 0, 1)
			local eased = alpha * alpha * (3 - 2 * alpha)
			local mid = startDrop:Lerp(groundCf, eased)
			local bounce = math.sin(alpha * math.pi) * 2.35 * (1 - alpha * 0.35)
			local wiggle = math.sin(alpha * math.pi * 5) * (1 - alpha) * 0.22
			local spin = CFrame.Angles(wiggle * 0.35, alpha * 1.15, -wiggle)
			dropModel:PivotTo(mid * CFrame.new(0, bounce, 0) * spin)
			local primary = dropModel.PrimaryPart or dropModel:FindFirstChildWhichIsA("BasePart", true)
			if primary then
				focusPart = primary
			end
			RunService.Heartbeat:Wait()
		end
		dropModel:PivotTo(groundCf)
		nudgePrimaryPartOntoGround(dropModel, groundCf)
		local primary = dropModel.PrimaryPart or dropModel:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			focusPart = primary
		end
	else
		if not waitToken(token, dropSec) then
			endCutscene(token)
			return
		end
	end

	-- Ground shake + 4s Block Open SFX (rumble, then open hit at the burst).
	GameSoundEffects.playLuckyBlockShake(groundShakeSec)
	GameSoundEffects.playLuckyBlockOpenSfx()
	if blockModel and blockModel.Parent then
		animateGroundShake(blockModel, groundShakeSec, token)
	else
		if not waitToken(token, groundShakeSec) then
			endCutscene(token)
			return
		end
	end
	if token ~= cutsceneToken then
		endCutscene(token)
		return
	end

	GameSoundEffects.stopLuckyBlockShake()
	stopAura()
	camShakeAmp = 0.22
	task.delay(0.28, function()
		if token == cutsceneToken then
			camShakeAmp = 0
		end
	end)
	camPull = 1.18
	camFovGoal = 60

	-- Burst.
	local burstAtPart = focusPart
	local burstPos = if burstAtPart and burstAtPart.Parent
		then burstAtPart.Position
		else groundCf.Position
	spawnBurstDebris(burstPos)
	if burstAtPart and burstAtPart.Parent then
		OtherVfxController.playLuckyBlockOpen(burstAtPart)
	else
		OtherVfxController.playLuckyBlockOpen(groundCf)
	end
	destroyBlockModel()

	local reveal = waitForReveal(token, CutsceneConfig.BURST_HOLD_SEC + 1.25)
	if token ~= cutsceneToken then
		endCutscene(token)
		return
	end

	if reveal and reveal.Parent then
		-- Place at ground focus if server spawned offset.
		local primary = reveal.PrimaryPart or reveal:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			focusPart = primary
		end
		-- Floating BrainrotHeader should already be on the reveal (server attach).
		animateRevealMotion(reveal, token)
		if token ~= cutsceneToken then
			endCutscene(token)
			return
		end
	else
		-- Fallback: wait out remaining cutscene time.
		local remain = CutsceneConfig.EMERGE_SEC
			+ CutsceneConfig.HOVER_SEC
			+ CutsceneConfig.HOP_SEC
			+ CutsceneConfig.SHRINK_SEC
		waitToken(token, remain)
	end

	notifyLuckyBlockOpened()
	endCutscene(token)
end

local function handleShakeStart(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	task.spawn(function()
		local ok, err = pcall(runCutscene, payload)
		if not ok then
			warn("[LuckyBlockController] cutscene error:", err)
			cutsceneToken += 1
			cutsceneRunning = false
			stopAnimConns()
			stopAura()
			GameSoundEffects.stopLuckyBlockShake()
			GameSoundEffects.stopLuckyBlockOpenSfx()
			destroyBlockModel()
			clearToolHideState()
			destroyLetterbox()
			restoreCamera()
			unlockMovement()
			GameplayUiVisibility.show()
		end
	end)
end

local function tryRollLuckyTool(tool: Tool)
	if tool:GetAttribute("LuckyBlockRolling") == true then
		return
	end
	if not canOpenLuckyBlockInZone() then
		showOpenDeniedNotif(nil)
		return
	end
	if not rollRE then
		return
	end
	rollRE:FireServer(tool)
end

local function syncLuckyOpenHint(tool: Tool, equipped: boolean)
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return
	end
	local gui = handle:FindFirstChild("LuckyOpenHint")
	if cutsceneRunning or not equipped then
		if gui then
			gui:Destroy()
		end
		return
	end
	if not (gui and gui:IsA("BillboardGui")) then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "LuckyOpenHint"
		billboard.Size = UDim2.fromOffset(120, 72)
		billboard.StudsOffset = Vector3.new(0, 2.2, 0)
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 32
		billboard.Parent = handle

		local tip = Instance.new("TextLabel")
		tip.Name = "Tip"
		tip.BackgroundTransparency = 1
		tip.Size = UDim2.new(1, 0, 0, 28)
		tip.Position = UDim2.fromOffset(0, 0)
		tip.Font = Enum.Font.GothamBold
		tip.TextSize = 14
		tip.TextColor3 = Color3.fromRGB(255, 255, 255)
		tip.TextStrokeTransparency = 0.4
		tip.Text = "Click to open"
		tip.Parent = billboard

		local ring = Instance.new("Frame")
		ring.Name = "AHost"
		ring.BackgroundTransparency = 1
		ring.AnchorPoint = Vector2.new(0.5, 1)
		ring.Position = UDim2.new(0.5, 0, 1, 0)
		ring.Size = UDim2.fromOffset(34, 34)
		ring.Parent = billboard
		GamepadInput.mountHint(ring, GamepadInput.ACCEPT, true)
		gui = billboard
	end
	local tip = gui:FindFirstChild("Tip")
	local usePad = GamepadInput.isPreferred()
	if tip and tip:IsA("TextLabel") then
		local token = GamepadInput.faceLabel(GamepadInput.ACCEPT)
		tip.Text = if usePad then ("Press " .. token .. " to open") else "Click to open"
	end
end

local function bindTool(tool: Tool)
	if tool:GetAttribute("__LuckyBlockBound") == true then
		return
	end
	tool:SetAttribute("__LuckyBlockBound", true)

	-- Hold-out SFX once per equip (not retriggerable by spam-equip within the gate).
	tool.Equipped:Connect(function()
		syncLuckyOpenHint(tool, true)
		if tool:GetAttribute("__LuckyHoldSfxPlayed") == true then
			return
		end
		tool:SetAttribute("__LuckyHoldSfxPlayed", true)
		local key = resolveLuckyHoldSfxKey(tool)
		if key then
			GameSoundEffects.playLuckyBlockHold(key)
		end
	end)
	tool.Unequipped:Connect(function()
		tool:SetAttribute("__LuckyHoldSfxPlayed", nil)
		syncLuckyOpenHint(tool, false)
	end)

	tool.Activated:Connect(function()
		tryRollLuckyTool(tool)
	end)
end

local function watchTool(tool: Instance)
	if not isLuckyBlockTool(tool) then
		return
	end
	bindTool(tool :: Tool)
end

local function watchContainer(container: Instance?)
	if not container then
		return
	end
	for _, c in ipairs(container:GetChildren()) do
		watchTool(c)
	end
	container.ChildAdded:Connect(watchTool)
end

local function bindToCharacter(char: Model)
	watchContainer(char)
end

local function bindToBackpack(bp: Instance)
	watchContainer(bp)
end

function LuckyBlockController.init()
	getOpenedBindable()
	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
	end)
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("LuckyBlockRemotes", 60)
		if not folder then
			warn("[LuckyBlockController] LuckyBlockRemotes folder missing")
			return
		end
		rollRE = folder:WaitForChild("LuckyBlockRoll", 30) :: RemoteEvent?
		shakeStartRE = folder:WaitForChild("LuckyBlockShakeStart", 30) :: RemoteEvent?
		denyRE = folder:WaitForChild("LuckyBlockDenied", 30) :: RemoteEvent?
		if shakeStartRE then
			shakeStartRE.OnClientEvent:Connect(handleShakeStart)
		end
		if denyRE then
			denyRE.OnClientEvent:Connect(function(message: any)
				showOpenDeniedNotif(if typeof(message) == "string" then message else nil)
			end)
		end
	end)

	if player.Character then
		bindToCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		cutsceneToken += 1
		stopAnimConns()
		stopAura()
		GameSoundEffects.stopLuckyBlockShake()
		GameSoundEffects.stopLuckyBlockOpenSfx()
		destroyBlockModel()
		clearToolHideState()
		destroyLetterbox()
		restoreCamera()
		unlockMovement()
		GameplayUiVisibility.show()
		bindToCharacter(char)
	end)

	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		bindToBackpack(bp)
	end
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			bindToBackpack(c)
		end
	end)

	ContextActionService:BindActionAtPriority(
		"LuckyBlockGamepadOpen",
		function(_name, state, _input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
				return Enum.ContextActionResult.Pass
			end
			local char = player.Character
			local tool = char and char:FindFirstChildOfClass("Tool")
			if not tool or not isLuckyBlockTool(tool) then
				return Enum.ContextActionResult.Pass
			end
			tryRollLuckyTool(tool)
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 20,
		Enum.KeyCode.ButtonA
	)
end

return LuckyBlockController
