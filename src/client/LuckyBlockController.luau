-- [ACTIVE] LuckyBlockController
--[[
	LuckyBlockController
	Client side of lucky block tools.

	On activate → LuckyBlockRoll. On LuckyBlockShakeStart → cinematic open:
	drop block → ground shake → burst → brainrot emerge/hover → hop to head → shrink in.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CutsceneConfig = require(Shared:WaitForChild("LuckyBlockCutsceneConfig"))
local MobileTouchGate = require(Shared:WaitForChild("MobileTouchGate"))

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local OtherVfxController = require(script.Parent.OtherVfxController)

local player = Players.LocalPlayer

local LOCK_ACTION = "LuckyBlockCutsceneMoveLock"
local GUI_NAME = "LuckyBlockCutscene"

local LuckyBlockController = {}

local rollRE: RemoteEvent? = nil
local shakeStartRE: RemoteEvent? = nil
local activeAuraSound: Sound? = nil
local cutsceneToken = 0

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
local hiddenTool: Tool? = nil
local hiddenToolTrans: { [BasePart]: number } = {}
local hiddenToolDecalTrans: { [Decal | Texture]: number } = {}
local keepToolHiddenConn: RBXScriptConnection? = nil

local function isLuckyBlockTool(tool: Instance): boolean
	return tool:IsA("Tool") and tool:GetAttribute("LuckyBlockTool") == true
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

local function restoreCamera()
	local cam = Workspace.CurrentCamera
	if cam then
		if savedCameraType then
			cam.CameraType = savedCameraType
		end
		if savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
		if savedFov then
			cam.FieldOfView = savedFov
		end
	end
	savedCameraType = nil
	savedCameraSubject = nil
	savedFov = nil
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

local function resolveGroundCf(hrp: BasePart): CFrame
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local probe = hrp.Position + flat * 4.2 + Vector3.new(0, 2.5, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local char = player.Character
	if char then
		params.FilterDescendantsInstances = { char }
	end
	local hit = Workspace:Raycast(probe, Vector3.new(0, -18, 0), params)
	local groundY = if hit then hit.Position.Y else (hrp.Position.Y - 3)
	local pos = Vector3.new(probe.X, groundY + 0.65, probe.Z)
	return CFrame.lookAt(pos, Vector3.new(hrp.Position.X, pos.Y, hrp.Position.Z))
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
			-- Clone may inherit hide modifiers — force fully visible on the floor prop.
			c.Transparency = 0
			c.LocalTransparencyModifier = 0
			c.Parent = model
			local offset = baseCf:ToObjectSpace(d.CFrame)
			c.CFrame = atCf * offset
			if d == handle then
				primary = c
			end
			for _, ch in c:GetChildren() do
				if ch:IsA("Decal") or ch:IsA("Texture") then
					ch.Transparency = 0
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

local function modelFocus(model: Model): Vector3
	local ok, boxCf, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(boxCf) == "CFrame" and typeof(boxSize) == "Vector3" then
		return boxCf.Position + Vector3.new(0, boxSize.Y * 0.05, 0)
	end
	return model:GetPivot().Position
end

local function startCinematicCamera(token: number)
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if not cam or not hrp then
		return
	end
	savedCameraType = cam.CameraType
	savedCameraSubject = cam.CameraSubject
	savedFov = cam.FieldOfView
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 52

	local blendFrom = cam.CFrame
	local blendT0 = os.clock()
	local blendDur = 0.55
	local phase = 0

	disconnect(cameraConn)
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if token ~= cutsceneToken then
			return
		end
		local liveCam = Workspace.CurrentCamera
		local liveHrp = getHRP()
		local hum = getHumanoid()
		if not liveCam or not liveHrp then
			return
		end
		if hum then
			hum:Move(Vector3.zero, false)
		end
		phase += dt

		local focus = liveHrp.Position + Vector3.new(0, 1.4, 0)
		if focusPart and focusPart.Parent then
			focus = focusPart.Position + Vector3.new(0, 0.9, 0)
		elseif blockModel and blockModel.Parent then
			focus = modelFocus(blockModel)
		end

		local right = liveHrp.CFrame.RightVector
		local back = -liveHrp.CFrame.LookVector
		local camPos = focus + right * 5.8 + Vector3.new(0, 3.6, 0) + back * 4.4
		-- Subtle orbit sway during shake/hover.
		local sway = math.sin(phase * 0.9) * 0.35
		camPos += right * sway
		local goal = CFrame.lookAt(camPos, focus + Vector3.new(0, 0.4, 0))

		local blendAlpha = math.clamp((os.clock() - blendT0) / blendDur, 0, 1)
		local eased = 1 - (1 - blendAlpha) ^ 3
		liveCam.CFrame = blendFrom:Lerp(goal, eased)
		if blendAlpha >= 1 then
			blendFrom = goal
			blendT0 = os.clock() - blendDur
		end
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
	disconnect(shakeConn)
	shakeConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			disconnect(shakeConn)
			shakeConn = nil
			return
		end
		local elapsed = os.clock() - t0
		local frac = math.clamp(elapsed / durationSec, 0, 1)
		local amp = 0.08 + frac * 0.42
		local t = elapsed * math.pi * 2 * 8.5
		local jx = math.sin(t * 1.13) * amp
		local jz = math.cos(t * 0.97) * amp * 0.85
		local jy = math.abs(math.sin(t * 1.7)) * amp * 0.35
		local tilt = math.sin(t) * math.rad(7 + frac * 14)
		model:PivotTo(baseCf * CFrame.new(jx, jy, jz) * CFrame.Angles(tilt * 0.55, tilt * 0.25, -tilt * 0.4))
		if elapsed >= durationSec then
			model:PivotTo(baseCf)
			disconnect(shakeConn)
			shakeConn = nil
		end
	end)
	waitToken(token, durationSec)
end

local function animateHover(model: Model, durationSec: number, token: number)
	local anchor = model:GetPivot().Position
	local _, baseYaw, _ = model:GetPivot():ToEulerAnglesYXZ()
	local t0 = os.clock()
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		focusPart = primary
	end
	disconnect(floatConn)
	floatConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			disconnect(floatConn)
			floatConn = nil
			return
		end
		local elapsed = os.clock() - t0
		local bob = math.sin(elapsed * 2.8) * 0.38
		local panX = math.sin(elapsed * 0.75) * 0.45
		local panZ = math.sin(elapsed * 0.62) * 0.45
		local yaw = baseYaw + elapsed * 0.55
		local tilt = math.sin(elapsed * 1.9) * 0.08
		local pos = anchor + Vector3.new(panX, 1.05 + bob, panZ)
		model:PivotTo(CFrame.new(pos) * CFrame.Angles(tilt * 0.35, yaw, tilt))
		if elapsed >= durationSec then
			disconnect(floatConn)
			floatConn = nil
		end
	end)
	waitToken(token, durationSec)
end

local function animateEmerge(model: Model, durationSec: number, token: number)
	local startCf = model:GetPivot()
	local goalCf = startCf * CFrame.new(0, 2.55, 0)
	local t0 = os.clock()
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		focusPart = primary
	end
	while os.clock() - t0 < durationSec do
		if token ~= cutsceneToken or not model.Parent then
			return
		end
		local alpha = math.clamp((os.clock() - t0) / durationSec, 0, 1)
		local eased = 1 - (1 - alpha) ^ 3
		model:PivotTo(startCf:Lerp(goalCf, eased))
		RunService.Heartbeat:Wait()
	end
	if model.Parent then
		model:PivotTo(goalCf)
	end
end

local function animateHopToHead(model: Model, durationSec: number, token: number)
	local char = player.Character
	if not char then
		return
	end
	local startPos = model:GetPivot().Position
	local startCf = model:GetPivot()
	local _, startYaw, _ = startCf:ToEulerAnglesYXZ()
	local startScale = 1
	pcall(function()
		startScale = model:GetScale()
	end)
	local t0 = os.clock()

	local function liveGoal(): Vector3
		local head = char:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			return head.Position + Vector3.new(0, head.Size.Y * 0.55 + 0.35, 0)
		end
		local hrp = getHRP()
		if hrp then
			return hrp.Position + Vector3.new(0, 2.85, 0)
		end
		return startPos + Vector3.new(0, 3, 0)
	end

	disconnect(hopConn)
	hopConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			disconnect(hopConn)
			hopConn = nil
			return
		end
		local alpha = math.clamp((os.clock() - t0) / durationSec, 0, 1)
		local e = 1 - (1 - alpha) ^ 3
		local goalPos = liveGoal()
		local along = startPos:Lerp(goalPos, e)
		local hopY = math.sin(alpha * math.pi) * 4.2
		local pos = along + Vector3.new(0, hopY, 0)
		local scaleMul = if alpha < 0.4 then (1 - (alpha / 0.4) * 0.28) else (0.72 + (1 - (1 - ((alpha - 0.4) / 0.6)) ^ 2) * 0.28)
		pcall(function()
			model:ScaleTo(startScale * scaleMul)
		end)
		local spin = startYaw + alpha * math.pi * 1.25
		model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, spin, math.sin(alpha * math.pi) * 0.12))
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			focusPart = primary
		end
		if alpha >= 1 then
			disconnect(hopConn)
			hopConn = nil
		end
	end)
	waitToken(token, durationSec)
end

local function animateShrinkAway(model: Model, durationSec: number, token: number)
	local startCf = model:GetPivot()
	local startScale = 1
	pcall(function()
		startScale = model:GetScale()
	end)
	local cam = Workspace.CurrentCamera
	local sinkTarget = startCf.Position + Vector3.new(0, -0.4, 0)
	if cam then
		-- Drift toward lower-center of view (inventory feel).
		sinkTarget = cam.CFrame:PointToWorldSpace(Vector3.new(0.35, -0.85, -2.2))
	end
	local t0 = os.clock()
	disconnect(shrinkConn)
	shrinkConn = RunService.Heartbeat:Connect(function()
		if token ~= cutsceneToken or not model.Parent then
			disconnect(shrinkConn)
			shrinkConn = nil
			return
		end
		local alpha = math.clamp((os.clock() - t0) / durationSec, 0, 1)
		local e = alpha * alpha
		local pos = startCf.Position:Lerp(sinkTarget, e)
		local spin = alpha * math.pi * 2.4
		pcall(function()
			model:ScaleTo(math.max(0.02, startScale * (1 - e * 0.97)))
		end)
		model:PivotTo(CFrame.new(pos) * CFrame.Angles(spin * 0.35, spin, spin * 0.2))
		if alpha >= 1 then
			disconnect(shrinkConn)
			shrinkConn = nil
		end
	end)
	waitToken(token, durationSec)
end

local function endCutscene(token: number)
	if token ~= cutsceneToken then
		return
	end
	stopAnimConns()
	stopAura()
	GameSoundEffects.stopLuckyBlockShake()
	destroyBlockModel()
	clearToolHideState()
	destroyLetterbox()
	restoreCamera()
	unlockMovement()
	GameplayUiVisibility.show()
end

local function runCutscene(payload: any)
	cutsceneToken += 1
	local token = cutsceneToken
	stopAnimConns()
	destroyBlockModel()

	local dropSec = if typeof(payload.dropSec) == "number" then payload.dropSec else CutsceneConfig.DROP_SEC
	local groundShakeSec = if typeof(payload.groundShakeSec) == "number"
		then payload.groundShakeSec
		else CutsceneConfig.GROUND_SHAKE_SEC

	local char = player.Character
	local hrp = getHRP()
	if not char or not hrp then
		return
	end

	local tool: Tool? = nil
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

	ensureLetterbox()
	GameplayUiVisibility.hide({
		keepScreenGuiNames = { GUI_NAME, "TutorialUiPointer" },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
	lockMovement()

	local groundCf = resolveGroundCf(hrp)
	faceToward(groundCf.Position)

	local handCf = hrp.CFrame * CFrame.new(0.6, 1.1, -1.1)
	if tool then
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

	startCinematicCamera(token)
	startAura()

	-- Drop to ground in front of the player.
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
			local eased = alpha * alpha
			local mid = startDrop:Lerp(groundCf, eased)
			local bounce = math.sin(alpha * math.pi) * 1.15 * (1 - alpha)
			dropModel:PivotTo(mid * CFrame.new(0, bounce, 0))
			local primary = dropModel.PrimaryPart or dropModel:FindFirstChildWhichIsA("BasePart", true)
			if primary then
				focusPart = primary
			end
			RunService.Heartbeat:Wait()
		end
		dropModel:PivotTo(groundCf)
	else
		if not waitToken(token, dropSec) then
			endCutscene(token)
			return
		end
	end

	-- Ground shake + camera rumble matching shake window.
	GameSoundEffects.playLuckyBlockShake(groundShakeSec)
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
	GameSoundEffects.playPurchaseShake()

	-- Burst.
	local burstAtPart = focusPart
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
		animateEmerge(reveal, CutsceneConfig.EMERGE_SEC, token)
		if token ~= cutsceneToken then
			endCutscene(token)
			return
		end
		animateHover(reveal, CutsceneConfig.HOVER_SEC, token)
		if token ~= cutsceneToken then
			endCutscene(token)
			return
		end
		animateHopToHead(reveal, CutsceneConfig.HOP_SEC, token)
		if token ~= cutsceneToken then
			endCutscene(token)
			return
		end
		animateShrinkAway(reveal, CutsceneConfig.SHRINK_SEC, token)
	else
		-- Fallback: wait out remaining cutscene time.
		local remain = CutsceneConfig.EMERGE_SEC
			+ CutsceneConfig.HOVER_SEC
			+ CutsceneConfig.HOP_SEC
			+ CutsceneConfig.SHRINK_SEC
		waitToken(token, remain)
	end

	-- Soft camera handoff before / as grant lands.
	waitToken(token, CutsceneConfig.CAM_RESTORE_SEC * 0.35)
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
			stopAnimConns()
			stopAura()
			GameSoundEffects.stopLuckyBlockShake()
			destroyBlockModel()
			clearToolHideState()
			destroyLetterbox()
			restoreCamera()
			unlockMovement()
			GameplayUiVisibility.show()
		end
	end)
end

local function bindTool(tool: Tool)
	if tool:GetAttribute("__LuckyBlockBound") == true then
		return
	end
	tool:SetAttribute("__LuckyBlockBound", true)
	tool.Activated:Connect(function()
		if tool:GetAttribute("LuckyBlockRolling") == true then
			return
		end
		if not rollRE then
			return
		end
		rollRE:FireServer(tool)
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
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("LuckyBlockRemotes", 60)
		if not folder then
			warn("[LuckyBlockController] LuckyBlockRemotes folder missing")
			return
		end
		rollRE = folder:WaitForChild("LuckyBlockRoll", 30) :: RemoteEvent?
		shakeStartRE = folder:WaitForChild("LuckyBlockShakeStart", 30) :: RemoteEvent?
		if shakeStartRE then
			shakeStartRE.OnClientEvent:Connect(handleShakeStart)
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
end

return LuckyBlockController
