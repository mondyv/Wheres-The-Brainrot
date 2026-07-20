-- [ACTIVE] FloatingClaimCutscene
--[[
	Character-focused cinematic for bush brainrot accept / decline.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)

local player = Players.LocalPlayer

local FloatingClaimCutscene = {}

local LOCK_ACTION = "FloatingClaimCutsceneMoveLock"
local GUI_NAME = "FloatingClaimCutscene"

local active = false
local cameraConn: RBXScriptConnection? = nil
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
local letterTopSeal: Frame? = nil
local letterBottomSeal: Frame? = nil
local focusModel: Model? = nil
local intensity = 0
local targetIntensity = 0
local blendFromCf: CFrame? = nil
local blendStart = 0
local BLEND_DURATION = 0.85
local mouseLookX = 0
local mouseLookY = 0
local facedOnce = false
local letterTiltTop = 0
local letterTiltBottom = 0
local barRoll = 0

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

local function flatUnit(from: Vector3, to: Vector3): Vector3
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function modelFocusPoint(model: Model): (Vector3, number)
	local ok, boxCFrame, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3" then
		local radius = math.max(boxSize.X, boxSize.Y, boxSize.Z) * 0.55
		return boxCFrame.Position + Vector3.new(0, boxSize.Y * 0.08, 0), math.max(radius, 2.5)
	end
	local pivot = model:GetPivot().Position
	return pivot + Vector3.new(0, 1.5, 0), 3.5
end

local function faceCharacterToward(target: Vector3)
	local hrp = getHRP()
	if not hrp then
		return
	end
	local flat = flatUnit(hrp.Position, target)
	hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + flat)
end

local function ensureLetterboxGui(): ScreenGui
	if
		cutsceneGui
		and cutsceneGui.Parent
		and letterTopSeal
		and letterTopSeal.Parent
		and cutsceneGui:FindFirstChild("LetterLeftSeal")
	then
		return cutsceneGui
	end
	if cutsceneGui then
		cutsceneGui:Destroy()
		cutsceneGui = nil
		letterTop = nil
		letterBottom = nil
		letterTopSeal = nil
		letterBottomSeal = nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 940
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- iPhone / notched devices: don't clip letterbox to the safe area (leaves side/top gaps).
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = false
	end)
	pcall(function()
		(gui :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Fixed seals never rotate — they keep edges covered while decorative bars tilt.
	local topSeal = Instance.new("Frame")
	topSeal.Name = "LetterTopSeal"
	topSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	topSeal.BorderSizePixel = 0
	topSeal.Size = UDim2.new(1.4, 0, 0, 0)
	topSeal.AnchorPoint = Vector2.new(0.5, 0)
	topSeal.Position = UDim2.new(0.5, 0, -0.04, 0)
	topSeal.ZIndex = 19
	topSeal.Parent = gui

	local bottomSeal = Instance.new("Frame")
	bottomSeal.Name = "LetterBottomSeal"
	bottomSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	bottomSeal.BorderSizePixel = 0
	bottomSeal.Size = UDim2.new(1.4, 0, 0, 0)
	bottomSeal.AnchorPoint = Vector2.new(0.5, 1)
	bottomSeal.Position = UDim2.new(0.5, 0, 1.04, 0)
	bottomSeal.ZIndex = 19
	bottomSeal.Parent = gui

	-- Full-height side strips cover notch gutters on mobile only (look like pillars on PC).
	local leftSeal = Instance.new("Frame")
	leftSeal.Name = "LetterLeftSeal"
	leftSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	leftSeal.BorderSizePixel = 0
	leftSeal.Size = UDim2.new(0, 0, 1.2, 0)
	leftSeal.AnchorPoint = Vector2.new(0, 0.5)
	leftSeal.Position = UDim2.new(0, 0, 0.5, 0)
	leftSeal.ZIndex = 18
	leftSeal.Visible = false
	leftSeal.Parent = gui

	local rightSeal = Instance.new("Frame")
	rightSeal.Name = "LetterRightSeal"
	rightSeal.BackgroundColor3 = Color3.new(0, 0, 0)
	rightSeal.BorderSizePixel = 0
	rightSeal.Size = UDim2.new(0, 0, 1.2, 0)
	rightSeal.AnchorPoint = Vector2.new(1, 0.5)
	rightSeal.Position = UDim2.new(1, 0, 0.5, 0)
	rightSeal.ZIndex = 18
	rightSeal.Visible = false
	rightSeal.Parent = gui

	local top = Instance.new("Frame")
	top.Name = "LetterTop"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.Size = UDim2.new(4, 0, 0, 0)
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, -0.12, 0)
	top.ZIndex = 20
	top.Parent = gui

	local bottom = Instance.new("Frame")
	bottom.Name = "LetterBottom"
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.BorderSizePixel = 0
	bottom.Size = UDim2.new(4, 0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0.5, 1)
	bottom.Position = UDim2.new(0.5, 0, 1.12, 0)
	bottom.ZIndex = 20
	bottom.Parent = gui

	cutsceneGui = gui
	letterTop = top
	letterBottom = bottom
	letterTopSeal = topSeal
	letterBottomSeal = bottomSeal
	return gui
end

local function animateLetterboxIn()
	local gui = ensureLetterboxGui()
	gui.Enabled = true
	local barIn = TweenInfo.new(0.42, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local leftSeal = gui:FindFirstChild("LetterLeftSeal")
	local rightSeal = gui:FindFirstChild("LetterRightSeal")
	if letterTopSeal and letterBottomSeal then
		TweenService:Create(letterTopSeal, barIn, {
			Size = UDim2.new(1.4, 0, 0.1, 0),
		}):Play()
		TweenService:Create(letterBottomSeal, barIn, {
			Size = UDim2.new(1.4, 0, 0.1, 0),
		}):Play()
	end
	-- Side seals are mobile/notch only — on PC they read as black pillars.
	local useSideSeals = UserInputService.TouchEnabled
	if leftSeal and leftSeal:IsA("Frame") then
		leftSeal.Visible = useSideSeals
		if useSideSeals then
			TweenService:Create(leftSeal, barIn, {
				Size = UDim2.new(0.04, 16, 1.2, 0),
			}):Play()
		else
			leftSeal.Size = UDim2.new(0, 0, 1.2, 0)
		end
	end
	if rightSeal and rightSeal:IsA("Frame") then
		rightSeal.Visible = useSideSeals
		if useSideSeals then
			TweenService:Create(rightSeal, barIn, {
				Size = UDim2.new(0.04, 16, 1.2, 0),
			}):Play()
		else
			rightSeal.Size = UDim2.new(0, 0, 1.2, 0)
		end
	end
	if letterTop and letterBottom then
		TweenService:Create(letterTop, barIn, {
			Size = UDim2.new(4, 0, 0.22, 0),
		}):Play()
		TweenService:Create(letterBottom, barIn, {
			Size = UDim2.new(4, 0, 0.22, 0),
		}):Play()
	end
end

local function animateLetterboxOut()
	local barOut = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local gui = cutsceneGui
	local leftSeal = gui and gui:FindFirstChild("LetterLeftSeal")
	local rightSeal = gui and gui:FindFirstChild("LetterRightSeal")
	if letterTopSeal and letterBottomSeal then
		TweenService:Create(letterTopSeal, barOut, {
			Size = UDim2.new(1.4, 0, 0, 0),
		}):Play()
		TweenService:Create(letterBottomSeal, barOut, {
			Size = UDim2.new(1.4, 0, 0, 0),
		}):Play()
	end
	if leftSeal and leftSeal:IsA("Frame") then
		TweenService:Create(leftSeal, barOut, {
			Size = UDim2.new(0, 0, 1.2, 0),
		}):Play()
	end
	if rightSeal and rightSeal:IsA("Frame") then
		TweenService:Create(rightSeal, barOut, {
			Size = UDim2.new(0, 0, 1.2, 0),
		}):Play()
	end
	if letterTop and letterBottom then
		TweenService:Create(letterTop, barOut, {
			Size = UDim2.new(4, 0, 0, 0),
			Rotation = 0,
		}):Play()
		TweenService:Create(letterBottom, barOut, {
			Size = UDim2.new(4, 0, 0, 0),
			Rotation = 0,
		}):Play()
		letterTop.BackgroundColor3 = Color3.new(0, 0, 0)
		letterBottom.BackgroundColor3 = Color3.new(0, 0, 0)
	end
	if cutsceneGui then
		task.delay(0.34, function()
			if cutsceneGui then
				cutsceneGui.Enabled = false
			end
		end)
	end
end

local function stopConn()
	if cameraConn then
		cameraConn:Disconnect()
		cameraConn = nil
	end
end

local function bindMoveLock()
	ContextActionService:BindActionAtPriority(
		LOCK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump
	)
end

local function unbindMoveLock()
	pcall(function()
		ContextActionService:UnbindAction(LOCK_ACTION)
	end)
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
		hum.AutoRotate = false
	end
	bindMoveLock()
end

local function unlockMovement()
	unbindMoveLock()
	local hum = getHumanoid()
	if hum then
		if typeof(savedWalkSpeed) == "number" then
			hum.WalkSpeed = savedWalkSpeed
		end
		if typeof(savedUseJumpPower) == "boolean" then
			hum.UseJumpPower = savedUseJumpPower
		end
		if typeof(savedJumpPower) == "number" then
			hum.JumpPower = savedJumpPower
		end
		if typeof(savedJumpHeight) == "number" then
			hum.JumpHeight = savedJumpHeight
		elseif hum.JumpHeight <= 0 then
			-- Safety if cutscene locked JumpHeight on a UseJumpPower=false humanoid.
			hum.JumpHeight = 7.2
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
end

-- Soft third-person handoff (never dive into the character).
local function defaultGameplayCameraCFrame(hrp: BasePart): CFrame
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local camPos = hrp.Position - look * 12.5 + Vector3.new(0, 5.5, 0)
	local lookAt = hrp.Position + Vector3.new(0, 1.6, 0)
	return CFrame.lookAt(camPos, lookAt)
end

local function restoreCamera(keepMoveLock: boolean?)
	stopConn()
	if not keepMoveLock then
		unlockMovement()
	end
	GameplayUiVisibility.show()
	animateLetterboxOut()
	local cam = Workspace.CurrentCamera
	if cam and savedCameraType then
		cam.CameraType = savedCameraType
		if savedFov then
			cam.FieldOfView = savedFov
		end
		if savedCameraSubject then
			cam.CameraSubject = savedCameraSubject
		end
	end
	savedCameraType = nil
	savedCameraSubject = nil
	savedFov = nil
	active = false
	focusModel = nil
	intensity = 0
	targetIntensity = 0
	blendFromCf = nil
	blendStart = 0
	mouseLookX = 0
	mouseLookY = 0
	facedOnce = false
	letterTiltTop = 0
	letterTiltBottom = 0
	barRoll = 0
end

function FloatingClaimCutscene.isActive(): boolean
	return active
end

function FloatingClaimCutscene.begin(model: Model?, zoomIntensity: number?)
	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	if not cam or not hrp then
		return
	end

	if not active then
		active = true
		blendFromCf = cam.CFrame
		blendStart = os.clock()
		facedOnce = false
		mouseLookX = 0
		mouseLookY = 0
		savedCameraType = cam.CameraType
		savedCameraSubject = cam.CameraSubject
		savedFov = cam.FieldOfView
		cam.CameraType = Enum.CameraType.Scriptable
		GameplayUiVisibility.hide({ keepScreenGuiNames = { "FloatingClaimCutscene" } })
		animateLetterboxIn()
		lockMovement()
	end

	focusModel = model or focusModel
	targetIntensity = math.clamp(zoomIntensity or targetIntensity, 0.2, 1)

	if not facedOnce and focusModel and focusModel.Parent then
		local focusPos = modelFocusPoint(focusModel)
		faceCharacterToward(focusPos)
		facedOnce = true
	end

	if cameraConn then
		return
	end

	local phase = 0
	cameraConn = RunService.RenderStepped:Connect(function(dt)
		if not active or not cam then
			return
		end
		local liveHrp = getHRP()
		local hum = getHumanoid()
		if not liveHrp then
			return
		end
		if hum then
			hum:Move(Vector3.zero, false)
		end

		phase += dt
		intensity += (targetIntensity - intensity) * math.min(dt * 1.5, 1)

		-- Soft mouse / touch look offset (parallax) — more noticeable pan.
		local viewport = cam.ViewportSize
		local mouse = UserInputService:GetMouseLocation()
		local nx = ((mouse.X / math.max(viewport.X, 1)) - 0.5) * 2
		local ny = ((mouse.Y / math.max(viewport.Y, 1)) - 0.5) * 2
		nx = math.clamp(nx, -1, 1)
		ny = math.clamp(ny, -1, 1)
		local lookSmooth = math.min(dt * 7.5, 1)
		mouseLookX += (nx - mouseLookX) * lookSmooth
		mouseLookY += (ny - mouseLookY) * lookSmooth

		-- Easter egg: pressed side dips; seals underneath keep edges covered.
		local topZone = math.clamp(1 - (mouse.Y / math.max(viewport.Y, 1)) / 0.18, 0, 1)
		local bottomZone = math.clamp(((mouse.Y / math.max(viewport.Y, 1)) - 0.82) / 0.18, 0, 1)
		local wantTopTilt = -mouseLookX * 5.5 * topZone
		local wantBottomTilt = mouseLookX * 5.5 * bottomZone
		letterTiltTop += (wantTopTilt - letterTiltTop) * math.min(dt * 8, 1)
		letterTiltBottom += (wantBottomTilt - letterTiltBottom) * math.min(dt * 8, 1)
		local wantRoll = (topZone * letterTiltTop + bottomZone * letterTiltBottom) * 0.01
			+ mouseLookX * 0.03
		barRoll += (wantRoll - barRoll) * math.min(dt * 7, 1)

		if letterTop then
			letterTop.Rotation = letterTiltTop
			letterTop.BackgroundColor3 = Color3.new(0, 0, 0):Lerp(Color3.fromRGB(28, 18, 40), topZone * 0.35)
		end
		if letterBottom then
			letterBottom.Rotation = letterTiltBottom
			letterBottom.BackgroundColor3 = Color3.new(0, 0, 0):Lerp(Color3.fromRGB(28, 18, 40), bottomZone * 0.35)
		end

		local playerPos = liveHrp.Position
		local focusPos = playerPos + Vector3.new(0, 1.35, 0)
		local focusRadius = 3.5
		if focusModel and focusModel.Parent then
			focusPos, focusRadius = modelFocusPoint(focusModel)
		end

		local lookTarget = focusPos + Vector3.new(0, 0.35, 0)
		local shoulder = -liveHrp.CFrame.LookVector
		local flatShoulder = Vector3.new(shoulder.X, 0, shoulder.Z)
		if flatShoulder.Magnitude < 0.05 then
			flatShoulder = Vector3.new(0, 0, 1)
		else
			flatShoulder = flatShoulder.Unit
		end
		local right = flatShoulder:Cross(Vector3.yAxis).Unit

		local pullBack = 8.6 - intensity * 1.35
		local sidePull = 2.35 + mouseLookX * 2.6
		local height = 2.55 + intensity * 0.85 - mouseLookY * 1.15
		local wobble = 0.018 + intensity * 0.012

		local camPos = playerPos
			+ flatShoulder * pullBack
			+ right * sidePull
			+ Vector3.new(
				math.sin(phase * 4.2) * wobble,
				height + math.sin(phase * 3.4) * wobble * 0.4,
				math.cos(phase * 3.8) * wobble * 0.25
			)

		local minDist = focusRadius + 10.5
		local fromFocus = camPos - lookTarget
		if fromFocus.Magnitude < minDist then
			camPos = lookTarget + fromFocus.Unit * minDist
		end

		local lookBias = lookTarget + right * (mouseLookX * 1.15) + Vector3.new(0, -mouseLookY * 0.85, 0)
		local goalCf = CFrame.lookAt(camPos, lookBias) * CFrame.Angles(0, 0, barRoll)
		local goalFov = (savedFov or 70) + intensity * 3.8 + math.sin(phase * 1.4) * 0.45 * intensity
			+ math.abs(mouseLookX) * 1.4 + math.abs(mouseLookY) * 0.8

		local blend = 1
		if blendFromCf then
			local elapsed = os.clock() - blendStart
			local raw = math.clamp(elapsed / BLEND_DURATION, 0, 1)
			blend = 1 - (1 - raw) ^ 2.8
			if raw >= 1 then
				blendFromCf = nil
			end
		end

		if blendFromCf and blend < 1 then
			cam.CFrame = blendFromCf:Lerp(goalCf, blend)
			cam.FieldOfView = (savedFov or 70) + (goalFov - (savedFov or 70)) * blend
		else
			cam.CFrame = goalCf
			cam.FieldOfView = goalFov
		end
	end)
end

function FloatingClaimCutscene.setFocus(model: Model?, zoomIntensity: number?)
	focusModel = model
	if typeof(zoomIntensity) == "number" then
		targetIntensity = math.clamp(zoomIntensity, 0.2, 1)
	end
	if model and model.Parent then
		local focusPos = modelFocusPoint(model)
		faceCharacterToward(focusPos)
	end
end

function FloatingClaimCutscene.endCutscene(fadeSec: number?, keepMoveLock: boolean?)
	if not active then
		return
	end
	active = false
	targetIntensity = 0

	local cam = Workspace.CurrentCamera
	local hrp = getHRP()
	stopConn()

	if cam and hrp and (fadeSec or 0) > 0 then
		local startCf = cam.CFrame
		local endCf = defaultGameplayCameraCFrame(hrp)
		local startFov = cam.FieldOfView
		local goalFov = savedFov or startFov
		local t0 = os.clock()
		local dur = fadeSec :: number
		while os.clock() - t0 < dur do
			local liveHrp = getHRP()
			if liveHrp then
				endCf = defaultGameplayCameraCFrame(liveHrp)
			end
			local alpha = (os.clock() - t0) / dur
			local eased = 1 - (1 - alpha) ^ 3
			cam.CFrame = startCf:Lerp(endCf, eased)
			cam.FieldOfView = startFov + (goalFov - startFov) * eased
			RunService.RenderStepped:Wait()
		end
		cam.CFrame = endCf
		cam.FieldOfView = goalFov
	end
	restoreCamera(keepMoveLock == true)
end

-- Hand off freeze state to a follow-up cutscene without restoring WalkSpeed.
function FloatingClaimCutscene.takeMoveLockState(): {
	walkSpeed: number?,
	jumpPower: number?,
	jumpHeight: number?,
	useJumpPower: boolean?,
	autoRotate: boolean?,
}?
	unbindMoveLock()
	if savedWalkSpeed == nil and savedJumpPower == nil and savedJumpHeight == nil then
		return nil
	end
	local state = {
		walkSpeed = savedWalkSpeed,
		jumpPower = savedJumpPower,
		jumpHeight = savedJumpHeight,
		useJumpPower = savedUseJumpPower,
		autoRotate = savedAutoRotate,
	}
	savedWalkSpeed = nil
	savedJumpPower = nil
	savedJumpHeight = nil
	savedUseJumpPower = nil
	savedAutoRotate = nil
	return state
end

function FloatingClaimCutscene.releaseMoveLock()
	unlockMovement()
end

return FloatingClaimCutscene
