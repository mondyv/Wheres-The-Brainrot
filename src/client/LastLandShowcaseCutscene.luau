-- [ACTIVE] LastLandShowcaseCutscene
--[[
	~7s cinematic after tutorial: First Gate → elephant head → Gate2 → portal.
	HUD hides, letterbox, title card. Streams Last land before the camera moves.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

local M = {}

local GUI_NAME = "LastLandShowcaseCutscene"
local LOCK_ACTION = "LastLandShowcaseLock"
local TOTAL_SEC = 7.05
local ATTR = {
	firstGate = "LastLandShowcase_FirstGate",
	elephant = "LastLandShowcase_Elephant",
	gate2 = "LastLandShowcase_Gate2",
	portal = "LastLandShowcase_Portal",
	firstGateLook = "LastLandShowcase_FirstGateLook",
	elephantLook = "LastLandShowcase_ElephantLook",
	gate2Look = "LastLandShowcase_Gate2Look",
	portalLook = "LastLandShowcase_PortalLook",
}

local active = false
local cutsceneToken = 0
local renderConn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil
local jumpConn: RBXScriptConnection? = nil
local cutsceneGui: ScreenGui? = nil
local doneEvent: BindableEvent? = nil
local hudHidden = false

local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov: number? = nil
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

type Shot = {
	t0: number,
	t1: number,
	a: CFrame,
	b: CFrame,
	fov0: number,
	fov1: number,
}

local function warnErr(context: string, err: any)
	warn("[LastLandShowcaseCutscene]", context, err)
end

function M.isActive(): boolean
	return active
end

local function findChildCI(parent: Instance, aliases: { string }): Instance?
	local want: { [string]: boolean } = {}
	for _, name in aliases do
		want[string.lower(name)] = true
	end
	for _, child in parent:GetChildren() do
		if want[string.lower(child.Name)] then
			return child
		end
	end
	return nil
end

local function findDescendantCI(parent: Instance, aliases: { string }): Instance?
	local want: { [string]: boolean } = {}
	for _, name in aliases do
		want[string.lower(name)] = true
	end
	if want[string.lower(parent.Name)] then
		return parent
	end
	for _, d in parent:GetDescendants() do
		if want[string.lower(d.Name)] then
			return d
		end
	end
	return nil
end

local function instanceCFrame(inst: Instance?): CFrame?
	if not inst or not inst.Parent then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	if inst:IsA("Model") then
		local ok, pivot = pcall(function()
			return (inst :: Model):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot
		end
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.CFrame else nil
end

local function attrCFrame(posName: string, lookName: string): CFrame?
	local pos = ReplicatedStorage:GetAttribute(posName)
	if typeof(pos) ~= "Vector3" then
		return nil
	end
	local look = ReplicatedStorage:GetAttribute(lookName)
	if typeof(look) == "Vector3" and look.Magnitude > 0.05 then
		return CFrame.lookAt(pos, pos + look.Unit)
	end
	return CFrame.new(pos)
end

local function resolveLastLand(): Instance?
	local map = Workspace:FindFirstChild("Map")
	local lands = map and map:FindFirstChild("Lands")
	if not lands then
		return nil
	end
	return findChildCI(lands, { "Last land", "Last Land", "LastLand" })
end

local function resolveTargets(): { firstGate: CFrame?, elephant: CFrame?, gate2: CFrame?, portal: CFrame? }
	local lastLand = resolveLastLand()
	local firstGate: CFrame? = nil
	local elephant: CFrame? = nil
	local gate2: CFrame? = nil
	local portal: CFrame? = nil
	if lastLand then
		firstGate = instanceCFrame(findDescendantCI(lastLand, { "First Gate", "FirstGate", "first gate" }))
		local temple = findChildCI(lastLand, { "Temple" })
		if temple then
			elephant = instanceCFrame(findDescendantCI(temple, {
				"Elephand HEad",
				"Elephand Head",
				"Elephant Head",
				"Elephant HEad",
				"ElephandHEad",
			}))
			gate2 = instanceCFrame(findDescendantCI(temple, { "Gate2", "Gate 2", "gate2" }))
		end
		if not elephant then
			elephant = instanceCFrame(findDescendantCI(lastLand, {
				"Elephand HEad",
				"Elephand Head",
				"Elephant Head",
			}))
		end
		if not gate2 then
			gate2 = instanceCFrame(findDescendantCI(lastLand, { "Gate2", "Gate 2" }))
		end
		portal = instanceCFrame(findDescendantCI(lastLand, { "portal 1", "Portal 1", "Portal1", "portal1" }))
	end
	firstGate = firstGate or attrCFrame(ATTR.firstGate, ATTR.firstGateLook)
	elephant = elephant or attrCFrame(ATTR.elephant, ATTR.elephantLook)
	gate2 = gate2 or attrCFrame(ATTR.gate2, ATTR.gate2Look)
	portal = portal or attrCFrame(ATTR.portal, ATTR.portalLook)
	return {
		firstGate = firstGate,
		elephant = elephant,
		gate2 = gate2,
		portal = portal,
	}
end

local function lookShot(focus: CFrame, back: number, height: number, side: number, lookHeight: number): CFrame
	local origin = focus.Position
	local flat = Vector3.new(focus.LookVector.X, 0, focus.LookVector.Z)
	if flat.Magnitude < 0.08 then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end
	local right = flat:Cross(Vector3.yAxis)
	if right.Magnitude < 0.08 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end
	local pos = origin - flat * back + Vector3.yAxis * height + right * side
	return CFrame.lookAt(pos, origin + Vector3.yAxis * lookHeight)
end

local function smootherstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function getHRP(): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function streamAround(pos: Vector3)
	local ok, err = pcall(function()
		player:RequestStreamAroundAsync(pos, 5)
	end)
	if not ok then
		warnErr("RequestStreamAroundAsync", err)
	end
end

local function waitForTargets(): { firstGate: CFrame?, elephant: CFrame?, gate2: CFrame?, portal: CFrame? }
	for _, name in { ATTR.firstGate, ATTR.elephant, ATTR.gate2, ATTR.portal } do
		local pos = ReplicatedStorage:GetAttribute(name)
		if typeof(pos) == "Vector3" then
			streamAround(pos)
		end
	end
	local first = resolveTargets()
	if first.firstGate then
		streamAround(first.firstGate.Position)
	end
	if first.portal then
		streamAround(first.portal.Position)
	end
	if first.elephant then
		streamAround(first.elephant.Position)
	end
	if first.gate2 then
		streamAround(first.gate2.Position)
	end
	local t0 = os.clock()
	while os.clock() - t0 < 2.2 do
		local got = resolveTargets()
		local n = 0
		if got.firstGate then
			n += 1
		end
		if got.elephant then
			n += 1
		end
		if got.gate2 then
			n += 1
		end
		if got.portal then
			n += 1
		end
		if n >= 3 then
			return got
		end
		task.wait(0.2)
	end
	return resolveTargets()
end

local function buildShots(targets: { firstGate: CFrame?, elephant: CFrame?, gate2: CFrame?, portal: CFrame? }): { Shot }
	local shots: { Shot } = {}
	local gate = targets.firstGate
	local head = targets.elephant
	local g2 = targets.gate2
	local portal = targets.portal
	if gate then
		table.insert(shots, {
			t0 = 0,
			t1 = 1.55,
			a = lookShot(gate, 92, 38, -18, 10),
			b = lookShot(gate, 36, 14, -4, 6),
			fov0 = 74,
			fov1 = 58,
		})
	end
	if head then
		table.insert(shots, {
			t0 = 1.55,
			t1 = 3.1,
			a = lookShot(head, 42, 4, 22, 18),
			b = lookShot(head, 28, 16, -8, 22),
			fov0 = 56,
			fov1 = 48,
		})
	end
	if g2 and portal then
		table.insert(shots, {
			t0 = 3.1,
			t1 = 4.55,
			a = lookShot(g2, 34, 10, 10, 5),
			b = lookShot(g2, 8, 6, 0, 3),
			fov0 = 64,
			fov1 = 70,
		})
		table.insert(shots, {
			t0 = 4.55,
			t1 = TOTAL_SEC,
			a = lookShot(portal, 48, 12, 6, 4),
			b = lookShot(portal, 16, 5, 0, 2),
			fov0 = 68,
			fov1 = 46,
		})
	elseif g2 then
		table.insert(shots, {
			t0 = 3.1,
			t1 = TOTAL_SEC,
			a = lookShot(g2, 40, 12, 8, 5),
			b = lookShot(g2, 12, 6, 0, 3),
			fov0 = 64,
			fov1 = 50,
		})
	elseif portal then
		table.insert(shots, {
			t0 = 3.1,
			t1 = TOTAL_SEC,
			a = lookShot(portal, 56, 16, 10, 5),
			b = lookShot(portal, 16, 5, 0, 2),
			fov0 = 70,
			fov1 = 46,
		})
	end
	return shots
end

local function ensureGui(): (ScreenGui, Frame, Frame, Frame, TextLabel, TextLabel, UIScale)
	if cutsceneGui and cutsceneGui.Parent then
		local fade = cutsceneGui:FindFirstChild("Fade")
		local top = cutsceneGui:FindFirstChild("LetterTop")
		local bottom = cutsceneGui:FindFirstChild("LetterBottom")
		local title = cutsceneGui:FindFirstChild("Title")
		local sub = cutsceneGui:FindFirstChild("Subtitle")
		local scale = title and title:FindFirstChild("PopScale")
		if
			fade
			and fade:IsA("Frame")
			and top
			and top:IsA("Frame")
			and bottom
			and bottom:IsA("Frame")
			and title
			and title:IsA("TextLabel")
			and sub
			and sub:IsA("TextLabel")
			and scale
			and scale:IsA("UIScale")
		then
			return cutsceneGui, fade, top, bottom, title, sub, scale
		end
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
		cutsceneGui = nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 960
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true

	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Size = UDim2.fromScale(1, 1)
	fade.ZIndex = 40
	fade.Active = false

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.fromScale(0.5, 0)
	top.Size = UDim2.new(1, 0, 0, 0)
	top.ZIndex = 30
	top.Active = false

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.fromScale(0.5, 1)
	bottom.Size = UDim2.new(1, 0, 0, 0)
	bottom.ZIndex = 30
	bottom.Active = false

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.new(0.5, 0, 0.78, 0)
	title.Size = UDim2.new(0.86, 0, 0, 54)
	title.Text = "A NEW WORLD AWAITS"
	title.TextColor3 = Color3.fromRGB(255, 226, 132)
	title.TextStrokeColor3 = Color3.fromRGB(18, 10, 4)
	title.TextStrokeTransparency = 0.15
	title.TextTransparency = 1
	title.TextScaled = true
	title.ZIndex = 50
	UiFonts.applyDisplay(title)
	local titleConstraint = Instance.new("UITextSizeConstraint")
	titleConstraint.MaxTextSize = 42
	titleConstraint.MinTextSize = 18
	titleConstraint.Parent = title
	local pop = Instance.new("UIScale")
	pop.Name = "PopScale"
	pop.Scale = 0.86
	pop.Parent = title

	local sub = Instance.new("TextLabel")
	sub.Name = "Subtitle"
	sub.BackgroundTransparency = 1
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.new(0.5, 0, 0.78, 28)
	sub.Size = UDim2.new(0.7, 0, 0, 28)
	sub.Text = "The last land"
	sub.TextColor3 = Color3.fromRGB(255, 244, 210)
	sub.TextStrokeColor3 = Color3.fromRGB(10, 6, 4)
	sub.TextStrokeTransparency = 0.35
	sub.TextTransparency = 1
	sub.TextScaled = true
	sub.ZIndex = 50
	UiFonts.applyBody(sub)
	local subConstraint = Instance.new("UITextSizeConstraint")
	subConstraint.MaxTextSize = 18
	subConstraint.MinTextSize = 10
	subConstraint.Parent = sub

	fade.Parent = gui
	top.Parent = gui
	bottom.Parent = gui
	title.Parent = gui
	sub.Parent = gui
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 8)
	gui.Parent = pg

	cutsceneGui = gui
	return gui, fade, top, bottom, title, sub, pop
end

local function lockMovement()
	local hum = getHumanoid()
	if hum then
		savedWalkSpeed = hum.WalkSpeed
		savedJumpPower = hum.JumpPower
		savedJumpHeight = hum.JumpHeight
		savedUseJumpPower = hum.UseJumpPower
		savedAutoRotate = hum.AutoRotate
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.JumpHeight = 0
		hum.Jump = false
		hum.AutoRotate = false
	end
	local okHold, hold = pcall(function()
		return require(script.Parent.BushHoldInteraction)
	end)
	if okHold and hold and typeof(hold.setBushSearchLocked) == "function" then
		hold.setBushSearchLocked(true)
	elseif not okHold then
		warnErr("BushHoldInteraction", hold)
	end
	ContextActionService:BindActionAtPriority(
		LOCK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		100000,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump
	)
	if jumpConn then
		jumpConn:Disconnect()
		jumpConn = nil
	end
	jumpConn = RunService.Heartbeat:Connect(function()
		if not active then
			return
		end
		local h = getHumanoid()
		if not h then
			return
		end
		h.Jump = false
		h.WalkSpeed = 0
		h:Move(Vector3.zero, false)
	end)
end

local function unlockMovement()
	if jumpConn then
		jumpConn:Disconnect()
		jumpConn = nil
	end
	pcall(function()
		ContextActionService:UnbindAction(LOCK_ACTION)
	end)
	local okHold, hold = pcall(function()
		return require(script.Parent.BushHoldInteraction)
	end)
	if okHold and hold and typeof(hold.setBushSearchLocked) == "function" then
		hold.setBushSearchLocked(false)
	elseif not okHold then
		warnErr("BushHoldInteraction unlock", hold)
	end
	local hum = getHumanoid()
	if hum then
		if typeof(savedWalkSpeed) == "number" and savedWalkSpeed > 0 then
			hum.WalkSpeed = savedWalkSpeed
		elseif hum.WalkSpeed <= 0 then
			hum.WalkSpeed = 16
		end
		if typeof(savedUseJumpPower) == "boolean" then
			hum.UseJumpPower = savedUseJumpPower
		end
		if typeof(savedJumpPower) == "number" then
			hum.JumpPower = if savedJumpPower > 0 then savedJumpPower else 50
		end
		if typeof(savedJumpHeight) == "number" then
			hum.JumpHeight = if savedJumpHeight > 0 then savedJumpHeight else 7.2
		end
		if typeof(savedAutoRotate) == "boolean" then
			hum.AutoRotate = savedAutoRotate
		else
			hum.AutoRotate = true
		end
	end
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil
	pcall(function()
		MobileTouchGate.ensureTouchControlsVisible(true)
		MobileTouchGate.restorePlayerMovement()
	end)
end

local function restoreCamera()
	local cam = Workspace.CurrentCamera
	local hum = getHumanoid()
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		if savedFov then
			cam.FieldOfView = savedFov
		end
		if hum then
			cam.CameraSubject = hum
		elseif savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
	end
	savedCameraType = nil
	savedCameraSubject = nil
	savedFov = nil
end

local function stopConns()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if inputConn then
		inputConn:Disconnect()
		inputConn = nil
	end
end

local function finish()
	if not active then
		return
	end
	active = false
	cutsceneToken += 1
	stopConns()
	unlockMovement()
	restoreCamera()
	if hudHidden then
		GameplayUiVisibility.show({ flourish = true })
		hudHidden = false
	end
	if cutsceneGui then
		cutsceneGui.Enabled = false
		cutsceneGui:Destroy()
		cutsceneGui = nil
	end
	local ev = doneEvent
	if ev then
		ev:Fire()
	end
end

local function titleAlpha(t: number): number
	if t < 4.75 then
		return 0
	end
	if t < 5.15 then
		return smootherstep((t - 4.75) / 0.4)
	end
	if t < 6.45 then
		return 1
	end
	if t < 6.95 then
		return 1 - smootherstep((t - 6.45) / 0.5)
	end
	return 0
end

local function fadeAlpha(t: number): number
	if t < 0.28 then
		return 1 - smootherstep(t / 0.28)
	end
	if t >= 1.48 and t < 1.64 then
		return math.sin(((t - 1.48) / 0.16) * math.pi)
	end
	if t >= 3.02 and t < 3.18 then
		return math.sin(((t - 3.02) / 0.16) * math.pi)
	end
	if t > TOTAL_SEC - 0.42 then
		return smootherstep((t - (TOTAL_SEC - 0.42)) / 0.42)
	end
	return 0
end

local function letterboxAlpha(t: number): number
	if t < 0.34 then
		return smootherstep(t / 0.34)
	end
	if t > TOTAL_SEC - 0.4 then
		return 1 - smootherstep((t - (TOTAL_SEC - 0.4)) / 0.4)
	end
	return 1
end

function M.play(): boolean
	if active then
		return false
	end
	local targets = waitForTargets()
	local shots = buildShots(targets)
	if #shots == 0 then
		return false
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end

	active = true
	cutsceneToken += 1
	local token = cutsceneToken
	savedCameraType = cam.CameraType
	savedCameraSubject = cam.CameraSubject
	savedFov = cam.FieldOfView
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil

	GameplayUiVisibility.hide({
		keepScreenGuiNames = { GUI_NAME },
		hideScreenGuiNames = { "TimCheeseQuestHud", "TimCheeseQuestTracker" },
		hideMainChildNames = { "TimCheeseQuestHost" },
	})
	hudHidden = true
	lockMovement()

	local gui, fade, top, bottom, title, sub, pop = ensureGui()
	gui.Enabled = true
	pcall(function()
		GameSoundEffects.playQuestPopUp()
	end)

	local ev = Instance.new("BindableEvent")
	doneEvent = ev
	local started = os.clock()
	local titleStinger = false

	inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or token ~= cutsceneToken then
			return
		end
		if os.clock() - started < 0.45 then
			return
		end
		local skip = input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space
			or input.KeyCode == Enum.KeyCode.ButtonA
		if skip then
			finish()
		end
	end)

	task.delay(TOTAL_SEC + 1.25, function()
		if token == cutsceneToken and active then
			finish()
		end
	end)

	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	renderConn = RunService.RenderStepped:Connect(function()
		if token ~= cutsceneToken then
			return
		end
		local t = os.clock() - started
		if t >= TOTAL_SEC then
			finish()
			return
		end
		local liveCam = Workspace.CurrentCamera
		if not liveCam then
			return
		end
		local shot = shots[#shots]
		for _, s in shots do
			if t >= s.t0 and t <= s.t1 then
				shot = s
				break
			end
		end
		local span = math.max(shot.t1 - shot.t0, 0.05)
		local u = smootherstep((t - shot.t0) / span)
		liveCam.CFrame = shot.a:Lerp(shot.b, u)
		liveCam.FieldOfView = shot.fov0 + (shot.fov1 - shot.fov0) * u

		local box = letterboxAlpha(t)
		top.Size = UDim2.new(1, 0, 0.118 * box, 0)
		bottom.Size = UDim2.new(1, 0, 0.118 * box, 0)
		fade.BackgroundTransparency = 1 - fadeAlpha(t)

		local ta = titleAlpha(t)
		if ta > 0.12 and not titleStinger then
			titleStinger = true
			pcall(function()
				GameSoundEffects.playLevelUp()
			end)
		end
		title.TextTransparency = 1 - ta
		title.TextStrokeTransparency = 0.15 + (1 - ta) * 0.7
		pop.Scale = 0.86 + ta * 0.16
		sub.TextTransparency = 1 - ta * 0.88
		sub.TextStrokeTransparency = 0.35 + (1 - ta) * 0.55
	end)

	ev.Event:Wait()
	if doneEvent == ev then
		doneEvent = nil
	end
	ev:Destroy()
	return true
end

function M.init()
end

return M
