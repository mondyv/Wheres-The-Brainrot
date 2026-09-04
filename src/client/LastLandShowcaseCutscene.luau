-- [ACTIVE] LastLandShowcaseCutscene
--[[
	Plays ServerStorage["Last Land Camera"] (mirrored to ReplicatedStorage)
	after tutorial: Moon Frames + FOV, then a longer last-frame breathe on the portal.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

local M = {}

local GUI_NAME = "LastLandShowcaseCutscene"
local LOCK_ACTION = "LastLandShowcaseLock"
local EXPORT_NAME = "Last Land Camera"
local HOLD_LAST_SEC = 3.35
local PLAYBACK_SCALE = 1.42
local FADE_TO_BLACK_SEC = 0.55
local BLACK_HOLD_SEC = 0.3
local FADE_IN_SEC = 0.85
local TITLE_LEAD_SEC = 0.45
local RETURN_SEC = 0.2

type MoonTrack = {
	frames: { CFrame },
	fov: { number },
	fps: number,
	clipSec: number,
	totalSec: number,
}

local active = false
local cutsceneToken = 0
local renderConn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil
local jumpConn: RBXScriptConnection? = nil
local fadeTweenConn: RBXScriptConnection? = nil
local cutsceneGui: ScreenGui? = nil
local doneEvent: BindableEvent? = nil
local hudHidden = false
local extraDisabledGuis: { ScreenGui } = {}
local extraHiddenHud: { GuiObject } = {}

local savedCameraType: Enum.CameraType? = nil
local savedCameraSubject: Instance? = nil
local savedFov: number? = nil
local savedWalkSpeed: number? = nil
local savedJumpPower: number? = nil
local savedJumpHeight: number? = nil
local savedUseJumpPower: boolean? = nil
local savedAutoRotate: boolean? = nil

local function warnErr(context: string, err: any)
	warn("[LastLandShowcaseCutscene]", context, err)
end

function M.isActive(): boolean
	return active
end

local function frameIndexFromName(name: string): number?
	local direct = tonumber(name)
	if direct then
		return direct
	end
	local digits = string.match(name, "%d+")
	return if digits then tonumber(digits) else nil
end

local function cframeFromFrameFolder(frameFolder: Instance): CFrame?
	if frameFolder:IsA("CFrameValue") then
		return frameFolder.Value
	end
	local attr = frameFolder:GetAttribute("CFrame")
	if typeof(attr) == "CFrame" then
		return attr
	end
	for _, name in { "CFrame", "CF", "Value" } do
		local ch = frameFolder:FindFirstChild(name)
		if ch and ch:IsA("CFrameValue") then
			return ch.Value
		end
	end
	for _, desc in frameFolder:GetDescendants() do
		if desc:IsA("CFrameValue") then
			return desc.Value
		end
	end
	return nil
end

local function numberFromFovFolder(folder: Instance): number?
	if folder:IsA("NumberValue") or folder:IsA("IntValue") then
		return folder.Value
	end
	local attr = folder:GetAttribute("Value") or folder:GetAttribute("FOV")
	if typeof(attr) == "number" then
		return attr
	end
	for _, desc in folder:GetDescendants() do
		if desc:IsA("NumberValue") or desc:IsA("IntValue") then
			return desc.Value
		end
	end
	return nil
end

local function parseNumberedCFrames(framesFolder: Instance): { CFrame }
	local keyed: { { sortKey: number, cf: CFrame } } = {}
	for _, child in framesFolder:GetChildren() do
		local idx = frameIndexFromName(child.Name)
		if idx == nil then
			continue
		end
		local cf = cframeFromFrameFolder(child)
		if cf then
			table.insert(keyed, { sortKey = idx, cf = cf })
		end
	end
	table.sort(keyed, function(a, b)
		return a.sortKey < b.sortKey
	end)
	local frames: { CFrame } = {}
	for _, item in ipairs(keyed) do
		table.insert(frames, item.cf)
	end
	return frames
end

local function parseNumberedFov(fovFolder: Instance?, frameCount: number, defaultFov: number): { number }
	local fovs = table.create(frameCount, defaultFov)
	if not fovFolder or frameCount <= 0 then
		return fovs
	end
	for _, child in fovFolder:GetChildren() do
		local idx = frameIndexFromName(child.Name)
		local value = numberFromFovFolder(child)
		if idx ~= nil and typeof(value) == "number" then
			local slot = idx
			if slot >= 0 and slot < frameCount then
				slot += 1
			end
			if slot >= 1 and slot <= frameCount then
				fovs[slot] = value
			end
		end
	end
	for i = 2, frameCount do
		if fovs[i] == defaultFov then
			fovs[i] = fovs[i - 1]
		end
	end
	return fovs
end

local function readReferenceCFrame(settings: Instance?): CFrame?
	if not settings then
		return nil
	end
	local ref = settings:FindFirstChild("Reference")
	if not ref then
		return nil
	end
	if ref:IsA("Camera") then
		return ref.CFrame
	end
	if ref:IsA("CFrameValue") then
		return ref.Value
	end
	if ref:IsA("ObjectValue") and ref.Value then
		local val = ref.Value
		if val:IsA("Camera") then
			return val.CFrame
		end
		if val:IsA("BasePart") then
			return val.CFrame
		end
	end
	local cam = ref:FindFirstChildWhichIsA("Camera", true)
	return if cam then cam.CFrame else nil
end

local function readSettingNumber(settings: Instance?, names: { string }): number?
	if not settings then
		return nil
	end
	for _, name in names do
		local ch = settings:FindFirstChild(name)
		if ch and (ch:IsA("NumberValue") or ch:IsA("IntValue")) then
			return ch.Value
		end
	end
	for _, desc in settings:GetDescendants() do
		if desc:IsA("NumberValue") or desc:IsA("IntValue") then
			local lower = string.lower(desc.Name)
			for _, name in names do
				if lower == string.lower(name) then
					return desc.Value
				end
			end
		end
	end
	return nil
end

local function framesHaveMotion(frames: { CFrame }): boolean
	if #frames < 2 then
		return false
	end
	local first = frames[1]
	for i = 2, #frames do
		local cf = frames[i]
		if (cf.Position - first.Position).Magnitude > 0.35 then
			return true
		end
		if cf.LookVector:Dot(first.LookVector) < 0.998 then
			return true
		end
	end
	return false
end

local function normalizeFrames(frames: { CFrame }, refCf: CFrame?): { CFrame }
	if #frames == 0 then
		return frames
	end
	local maxPos = 0
	for _, cf in frames do
		maxPos = math.max(maxPos, cf.Position.Magnitude)
	end
	if maxPos < 120 and refCf and refCf.Position.Magnitude > 50 then
		local out: { CFrame } = table.create(#frames)
		for i, cf in ipairs(frames) do
			out[i] = refCf * cf
		end
		if framesHaveMotion(out) then
			return out
		end
	end
	return frames
end

local function loadMoonTrack(export: Instance): MoonTrack?
	local framesFolder = export:FindFirstChild("Frames")
	if not framesFolder then
		return nil
	end
	local frames = parseNumberedCFrames(framesFolder)
	if #frames < 2 then
		return nil
	end
	local settings = export:FindFirstChild("Settings")
	frames = normalizeFrames(frames, readReferenceCFrame(settings))
	if not framesHaveMotion(frames) then
		return nil
	end
	local fps = readSettingNumber(settings, { "FPS", "Framerate", "FrameRate", "fps" }) or 60
	fps = math.clamp(fps, 12, 120)
	local defaultFov = 70
	local refCam = settings and settings:FindFirstChildWhichIsA("Camera", true)
	if refCam then
		defaultFov = refCam.FieldOfView
	end
	local fovs = parseNumberedFov(export:FindFirstChild("FOV"), #frames, defaultFov)
	local clipSec = ((#frames - 1) / fps) * PLAYBACK_SCALE
	return {
		frames = frames,
		fov = fovs,
		fps = fps,
		clipSec = clipSec,
		totalSec = clipSec + HOLD_LAST_SEC,
	}
end

local function sampleTrack(track: MoonTrack, elapsed: number): (CFrame, number, boolean)
	local count = #track.frames
	local clip = track.clipSec
	if elapsed >= clip then
		return track.frames[count], track.fov[count], true
	end
	local t = math.clamp(elapsed / clip, 0, 1)
	local framePos = t * (count - 1)
	local idx0 = math.clamp(math.floor(framePos), 0, count - 1)
	local idx1 = math.min(idx0 + 1, count - 1)
	local alpha = framePos - idx0
	-- Ease the last stretch so it settles on the portal instead of slamming.
	if t > 0.82 then
		local tail = (t - 0.82) / 0.18
		alpha = alpha + (1 - alpha) * (tail * tail * (3 - 2 * tail)) * 0.35
	end
	local cf = track.frames[idx0 + 1]:Lerp(track.frames[idx1 + 1], math.clamp(alpha, 0, 1))
	local fov = track.fov[idx0 + 1] + (track.fov[idx1 + 1] - track.fov[idx0 + 1]) * math.clamp(alpha, 0, 1)
	return cf, fov, false
end

local function breathe(cf: CFrame, holdAge: number): CFrame
	local s = math.sin(holdAge * 1.05)
	local c = math.cos(holdAge * 0.68)
	local pos = cf.Position + cf.UpVector * (s * 0.55) + cf.RightVector * (c * 0.32)
	local at = pos + cf.LookVector + cf.RightVector * (s * 0.018) + cf.UpVector * (c * 0.014)
	return CFrame.lookAt(pos, at)
end

local function gameplayCameraCFrame(): CFrame?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local pos = hrp.Position - look * 12.5 + Vector3.new(0, 5.4, 0)
	return CFrame.lookAt(pos, hrp.Position + Vector3.new(0, 1.5, 0))
end

local function waitForExport(): Instance?
	local existing = ReplicatedStorage:FindFirstChild(EXPORT_NAME)
	if existing then
		return existing
	end
	local found = ReplicatedStorage:WaitForChild(EXPORT_NAME, 4)
	return found
end

local function streamAround(pos: Vector3)
	task.spawn(function()
		local ok, err = pcall(function()
			player:RequestStreamAroundAsync(pos, 3)
		end)
		if not ok then
			warnErr("RequestStreamAroundAsync", err)
		end
	end)
end

local function getHumanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function restoreGameplayLocomotion()
	local hum = getHumanoid()
	if not hum then
		return
	end
	local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
	if typeof(base) ~= "number" or base <= 0 then
		base = 16
	end
	local slowOn = player:GetAttribute("SlowWalkEnabled") == true
	hum.WalkSpeed = (base :: number) * (if slowOn then 0.8 else 1.15)
	hum.AutoRotate = true
	hum.Jump = false
	hum.PlatformStand = false
	if hum.UseJumpPower then
		hum.JumpPower = 50
	end
	if hum.JumpHeight <= 0 then
		hum.JumpHeight = 7.2
	end
end

local function stopWorkoutIfActive()
	if player:GetAttribute("WorkoutActive") ~= true then
		return
	end
	-- Unequip fires WorkoutController.onUnequip without requiring that huge module here.
	local hum = getHumanoid()
	if hum then
		hum:UnequipTools()
	end
end

local function lockMovement()
	local hum = getHumanoid()
	if hum then
		if hum.WalkSpeed > 0.05 then
			savedWalkSpeed = hum.WalkSpeed
		elseif savedWalkSpeed == nil then
			local base = hum:GetAttribute("BrainrotBaseWalkSpeed")
			if typeof(base) == "number" and base > 0 then
				local slowOn = player:GetAttribute("SlowWalkEnabled") == true
				savedWalkSpeed = (base :: number) * (if slowOn then 0.8 else 1.15)
			else
				savedWalkSpeed = 16 * 1.15
			end
		end
		if hum.JumpPower > 0 then
			savedJumpPower = hum.JumpPower
		elseif savedJumpPower == nil then
			savedJumpPower = 50
		end
		if hum.JumpHeight > 0 then
			savedJumpHeight = hum.JumpHeight
		elseif savedJumpHeight == nil then
			savedJumpHeight = 7.2
		end
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
	restoreGameplayLocomotion()
	local hum = getHumanoid()
	if hum then
		if typeof(savedUseJumpPower) == "boolean" then
			hum.UseJumpPower = savedUseJumpPower
		end
		if typeof(savedJumpPower) == "number" and savedJumpPower > 0 then
			hum.JumpPower = savedJumpPower
		end
		if typeof(savedJumpHeight) == "number" and savedJumpHeight > 0 then
			hum.JumpHeight = savedJumpHeight
		end
		if typeof(savedAutoRotate) == "boolean" then
			hum.AutoRotate = savedAutoRotate
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

local function beginFastReturnToCharacter()
	local cam = Workspace.CurrentCamera
	local from = if cam then cam.CFrame else nil
	local startFov = if cam then cam.FieldOfView else 70
	local goalFov = savedFov or 70
	local t0 = os.clock()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if not cam or not from then
		restoreCamera()
		return
	end
	renderConn = RunService.RenderStepped:Connect(function()
		local live = Workspace.CurrentCamera
		if not live then
			return
		end
		local u = math.clamp((os.clock() - t0) / RETURN_SEC, 0, 1)
		local eased = 1 - (1 - u) * (1 - u)
		local goal = gameplayCameraCFrame() or from
		live.CameraType = Enum.CameraType.Scriptable
		live.CFrame = from:Lerp(goal, eased)
		live.FieldOfView = startFov + (goalFov - startFov) * eased
		if u >= 1 then
			if renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
			restoreCamera()
		end
	end)
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
	if fadeTweenConn then
		fadeTweenConn:Disconnect()
		fadeTweenConn = nil
	end
end

local function forceHideOtherGuis()
	table.clear(extraDisabledGuis)
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	for _, ch in pg:GetChildren() do
		if ch:IsA("ScreenGui") and ch.Enabled and ch.Name ~= GUI_NAME and ch.Name ~= "Main" then
			ch.Enabled = false
			table.insert(extraDisabledGuis, ch)
		end
	end
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
	end)
end

local function restoreForcedGuis()
	for _, gui in extraDisabledGuis do
		if gui.Parent then
			gui.Enabled = true
		end
	end
	table.clear(extraDisabledGuis)
	for _, g in extraHiddenHud do
		if g.Parent then
			g.Visible = true
		end
	end
	table.clear(extraHiddenHud)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
	end)
end

local function hideHudCountersNow()
	table.clear(extraHiddenHud)
	local main = PlayerGuiMain.ensure(player)
	local function hideGui(g: GuiObject)
		if not g.Visible then
			return
		end
		table.insert(extraHiddenHud, g)
		g.Visible = false
	end
	local side = main:FindFirstChild("SideUI")
	if side and side:IsA("GuiObject") then
		for _, ch in side:GetChildren() do
			if ch:IsA("GuiObject") and ch.Name ~= "AdminFrame" then
				hideGui(ch)
			end
		end
	end
	for _, d in main:GetChildren() do
		if d:IsA("GuiObject") then
			local n = string.lower(d.Name)
			if n == "counters" or n == "cash" or n == "top" or n == "right" then
				hideGui(d)
			end
		end
	end
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
	gui.DisplayOrder = 2000
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
	title.Position = UDim2.new(0.5, 0, 0.76, 0)
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
	sub.Position = UDim2.new(0.5, 0, 0.76, 28)
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

local function smootherstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function tweenFadeAmount(fade: Frame, fromAmount: number, toAmount: number, dur: number, token: number): boolean
	if fadeTweenConn then
		fadeTweenConn:Disconnect()
		fadeTweenConn = nil
	end
	local done = Instance.new("BindableEvent")
	local t0 = os.clock()
	local fired = false
	fadeTweenConn = RunService.RenderStepped:Connect(function()
		if token ~= cutsceneToken or not active then
			if fadeTweenConn then
				fadeTweenConn:Disconnect()
				fadeTweenConn = nil
			end
			if not fired then
				fired = true
				done:Fire(false)
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / math.max(dur, 0.05), 0, 1)
		local amount = fromAmount + (toAmount - fromAmount) * smootherstep(u)
		fade.BackgroundTransparency = 1 - amount
		if u >= 1 then
			if fadeTweenConn then
				fadeTweenConn:Disconnect()
				fadeTweenConn = nil
			end
			if not fired then
				fired = true
				done:Fire(true)
			end
		end
	end)
	local ok = done.Event:Wait()
	done:Destroy()
	return ok == true
end

local function finish()
	if not active then
		return
	end
	active = false
	cutsceneToken += 1
	stopConns()
	unlockMovement()
	beginFastReturnToCharacter()
	restoreForcedGuis()
	if hudHidden then
		GameplayUiVisibility.forceShow()
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

function M.play(): boolean
	if active then
		return false
	end
	local export = waitForExport()
	if not export then
		warnErr("export missing", EXPORT_NAME)
		return false
	end
	local track = loadMoonTrack(export)
	if not track then
		warnErr("could not parse", EXPORT_NAME)
		return false
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end

	streamAround(track.frames[1].Position)

	active = true
	cutsceneToken += 1
	local token = cutsceneToken

	local ev = Instance.new("BindableEvent")
	doneEvent = ev

	GameplayUiVisibility.hide({
		keepScreenGuiNames = { GUI_NAME },
		hideScreenGuiNames = {
			"TutorialObjective",
			"TutorialUiPointer",
			"WorkoutComboGui",
			"SwingTargetMarker",
			"ServerResetHud",
			"TouchGui",
			"TimCheeseQuestHud",
			"TimCheeseQuestTracker",
		},
		hideMainChildNames = { "TutorialQuestHost", "TimCheeseQuestHost", "Frames" },
	})
	hudHidden = true
	hideHudCountersNow()
	forceHideOtherGuis()

	local gui, fade, top, bottom, title, sub, pop = ensureGui()
	fade.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, 0)
	bottom.Size = UDim2.new(1, 0, 0, 0)
	gui.Enabled = true

	if not tweenFadeAmount(fade, 0, 1, FADE_TO_BLACK_SEC, token) then
		if active and token == cutsceneToken then
			finish()
		end
		if doneEvent == ev then
			doneEvent = nil
		end
		ev:Destroy()
		return false
	end
	if token ~= cutsceneToken or not active then
		if doneEvent == ev then
			doneEvent = nil
		end
		ev:Destroy()
		return false
	end

	stopWorkoutIfActive()
	task.wait(BLACK_HOLD_SEC)
	if token ~= cutsceneToken or not active then
		if doneEvent == ev then
			doneEvent = nil
		end
		ev:Destroy()
		return false
	end

	local liveCam = Workspace.CurrentCamera
	if not liveCam then
		finish()
		if doneEvent == ev then
			doneEvent = nil
		end
		ev:Destroy()
		return false
	end

	savedCameraType = liveCam.CameraType
	savedCameraSubject = liveCam.CameraSubject
	savedFov = liveCam.FieldOfView
	liveCam.CameraType = Enum.CameraType.Scriptable
	liveCam.CameraSubject = nil
	liveCam.CFrame = track.frames[1]
	liveCam.FieldOfView = track.fov[1]
	liveCam.Focus = track.frames[1]
	lockMovement()

	pcall(function()
		GameSoundEffects.playQuestPopUp()
	end)

	local started = os.clock()
	local titleStinger = false
	local total = track.totalSec

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

	task.delay(total + 1.2, function()
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
		if t >= total then
			finish()
			return
		end
		local liveCam = Workspace.CurrentCamera
		if not liveCam then
			return
		end
		local cf, fov, onLast = sampleTrack(track, t)
		if onLast then
			cf = breathe(cf, t - track.clipSec)
		end
		liveCam.CFrame = cf
		liveCam.FieldOfView = fov
		liveCam.Focus = cf

		local boxIn = smootherstep(math.clamp(t / 0.32, 0, 1))
		local boxOut = if t > total - 0.4 then 1 - smootherstep((t - (total - 0.4)) / 0.4) else 1
		local box = math.min(boxIn, boxOut)
		top.Size = UDim2.new(1, 0, 0.118 * box, 0)
		bottom.Size = UDim2.new(1, 0, 0.118 * box, 0)

		local fadeA = 0
		if t < FADE_IN_SEC then
			fadeA = 1 - smootherstep(t / FADE_IN_SEC)
		elseif t > total - 0.42 then
			fadeA = smootherstep((t - (total - 0.42)) / 0.42)
		end
		fade.BackgroundTransparency = 1 - fadeA

		local titleT = t - (track.clipSec - TITLE_LEAD_SEC)
		local ta = 0
		if titleT > 0 then
			if titleT < 0.38 then
				ta = smootherstep(titleT / 0.38)
			elseif t < total - 0.42 then
				ta = 1
			else
				ta = 1 - smootherstep((t - (total - 0.42)) / 0.42)
			end
		end
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
