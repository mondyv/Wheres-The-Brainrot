-- [ACTIVE] WorkoutController
-- Gear activate: bar across both feet during curl, white flash, +power floaters into HUD.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local player = Players.LocalPlayer

local startWorkoutFn: RemoteFunction? = nil
local stopWorkoutFn: RemoteFunction? = nil

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	if not remotes then
		return
	end
	startWorkoutFn = remotes:WaitForChild("StartWorkout", 30) :: RemoteFunction?
	stopWorkoutFn = remotes:WaitForChild("StopWorkout", 30) :: RemoteFunction?
end)

local toolConns: { RBXScriptConnection } = {}
local charConns: { RBXScriptConnection } = {}
local boundTools: { [Tool]: boolean } = {}
local workoutTrack: AnimationTrack? = nil
local workoutAnim: Animation? = nil
local footMotor: Motor6D? = nil
local footProp: Model? = nil
local gripKillConn: RBXScriptConnection? = nil
local gripChildConn: RBXScriptConnection? = nil
local footPoseConn: RBXScriptConnection? = nil
local bodyHighlight: Highlight? = nil
local walkSpeedBefore: number? = nil
local jumpPowerBefore: number? = nil
local jumpHeightBefore: number? = nil
local floaterLayer: Frame? = nil
local powerHudScale: UIScale? = nil
local handleTransparency: { [BasePart]: number } = {}
local handleBaseTransparency: { [BasePart]: number } = {}

-- Match SideUI Power HUD (yellowish gold). Runtime sample overrides if available.
local POWER_HUD_YELLOW = Color3.fromRGB(255, 214, 90)

local function clearToolConns()
	for _, c in toolConns do
		c:Disconnect()
	end
	table.clear(toolConns)
	table.clear(boundTools)
end

local function clearCharConns()
	for _, c in charConns do
		c:Disconnect()
	end
	table.clear(charConns)
end

local function getHumanoid(character: Model?): Humanoid?
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function findFeet(character: Model): (BasePart?, BasePart?)
	local function pick(names: { string }): BasePart?
		for _, name in names do
			local p = character:FindFirstChild(name)
			if p and p:IsA("BasePart") then
				return p
			end
		end
		return nil
	end
	local r = pick({ "RightFoot", "Right Leg", "RightLowerLeg" })
	local l = pick({ "LeftFoot", "Left Leg", "LeftLowerLeg" })
	return r, l
end

local function stopWorkoutAnim()
	if workoutTrack then
		workoutTrack:Stop(0.15)
		workoutTrack = nil
	end
end

local function destroyHandGrips(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
			if string.find(string.lower(d.Name), "grip", 1, true) then
				d:Destroy()
			end
		end
	end
end

local function restoreToolVisibility()
	for part, tr in handleTransparency do
		if part.Parent then
			part.LocalTransparencyModifier = tr
		end
	end
	table.clear(handleTransparency)
	for part, tr in handleBaseTransparency do
		if part.Parent then
			part.Transparency = tr
		end
	end
	table.clear(handleBaseTransparency)
end

local function clearFootAttach()
	if gripKillConn then
		gripKillConn:Disconnect()
		gripKillConn = nil
	end
	if gripChildConn then
		gripChildConn:Disconnect()
		gripChildConn = nil
	end
	if footPoseConn then
		footPoseConn:Disconnect()
		footPoseConn = nil
	end
	if footMotor then
		footMotor:Destroy()
		footMotor = nil
	end
	if footProp then
		footProp:Destroy()
		footProp = nil
	end
	restoreToolVisibility()
end

local function tippyToeWorld(rf: BasePart, lf: BasePart?): CFrame
	-- Tip of the foot (toes), not the ankle/heel.
	local function tipOf(foot: BasePart): Vector3
		return foot.CFrame:PointToWorldSpace(Vector3.new(0, -foot.Size.Y * 0.5 - 0.06, -foot.Size.Z * 0.35))
	end
	if lf then
		local a = tipOf(rf)
		local b = tipOf(lf)
		local mid = (a + b) * 0.5
		local across = b - a
		if across.Magnitude < 0.05 then
			across = rf.CFrame.RightVector
		end
		local right = across.Unit
		local up = (rf.CFrame.UpVector + lf.CFrame.UpVector) * 0.5
		up = if up.Magnitude > 0.1 then up.Unit else Vector3.yAxis
		local look = right:Cross(up)
		look = if look.Magnitude > 0.1 then look.Unit else rf.CFrame.LookVector
		up = look:Cross(right).Unit
		return CFrame.fromMatrix(mid, right, up)
	end
	return CFrame.new(tipOf(rf)) * (rf.CFrame - rf.CFrame.Position) * CFrame.Angles(0, math.rad(90), math.rad(90))
end

-- Move the real equipped tool onto both tippy-toes (break hand grip every frame).
local function attachGearAcrossFeet(character: Model, tool: Tool)
	clearFootAttach()
	local rightFoot, leftFoot = findFeet(character)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		warn("[WorkoutController] Tool missing Handle — cannot attach to feet")
		return
	end
	local anchorFoot = rightFoot or leftFoot
	if not anchorFoot then
		warn("[WorkoutController] Character missing feet — cannot attach gear")
		return
	end

	destroyHandGrips(character)
	gripKillConn = RunService.Heartbeat:Connect(function()
		local char = player.Character
		if char then
			destroyHandGrips(char)
		end
	end)
	gripChildConn = character.DescendantAdded:Connect(function(child)
		if
			(child:IsA("Motor6D") or child:IsA("Weld") or child:IsA("WeldConstraint"))
			and string.find(string.lower(child.Name), "grip", 1, true)
		then
			task.defer(function()
				if child.Parent then
					child:Destroy()
				end
			end)
		end
	end)

	local pose0 = tippyToeWorld(anchorFoot, if anchorFoot == rightFoot then leftFoot else rightFoot)
	local motor = Instance.new("Motor6D")
	motor.Name = "WorkoutFootMotor"
	motor.Part0 = anchorFoot
	motor.Part1 = handle
	motor.C0 = anchorFoot.CFrame:ToObjectSpace(pose0)
	motor.C1 = CFrame.new()
	motor.Parent = anchorFoot
	footMotor = motor

	footPoseConn = RunService.RenderStepped:Connect(function()
		if not footMotor or footMotor ~= motor or not motor.Parent then
			return
		end
		local rf, lf = findFeet(player.Character or character)
		local footA = rf or lf
		if not footA then
			return
		end
		local pose = tippyToeWorld(footA, if footA == rf then lf else rf)
		-- Keep Part0 as the original anchor if it still exists; else retarget.
		if motor.Part0 and motor.Part0.Parent then
			motor.C0 = motor.Part0.CFrame:ToObjectSpace(pose)
		else
			motor.Part0 = footA
			motor.C0 = footA.CFrame:ToObjectSpace(pose)
		end
	end)
end

local function playWorkoutAnim(character: Model)
	stopWorkoutAnim()
	local humanoid = getHumanoid(character)
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if not workoutAnim then
		workoutAnim = Instance.new("Animation")
		workoutAnim.Name = "WorkoutBarbellCurl"
		workoutAnim.AnimationId = GearConfig.WORKOUT_ANIMATION_ID
	end
	local ok, trackOrErr = pcall(function()
		return (animator :: Animator):LoadAnimation(workoutAnim :: Animation)
	end)
	if not ok or typeof(trackOrErr) ~= "Instance" then
		warn("[WorkoutController] LoadAnimation failed:", trackOrErr)
		return
	end
	local track = trackOrErr :: AnimationTrack
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	track:Play(0.15)
	workoutTrack = track
end

local function lockMovement(humanoid: Humanoid, locked: boolean)
	if locked then
		if walkSpeedBefore == nil then
			walkSpeedBefore = humanoid.WalkSpeed
		end
		if jumpPowerBefore == nil then
			jumpPowerBefore = humanoid.JumpPower
		end
		if jumpHeightBefore == nil then
			jumpHeightBefore = humanoid.JumpHeight
		end
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	else
		if walkSpeedBefore ~= nil then
			humanoid.WalkSpeed = walkSpeedBefore
			walkSpeedBefore = nil
		end
		if jumpPowerBefore ~= nil then
			humanoid.JumpPower = jumpPowerBefore
			jumpPowerBefore = nil
		end
		if jumpHeightBefore ~= nil then
			humanoid.JumpHeight = jumpHeightBefore
			jumpHeightBefore = nil
		end
	end
end

local function clearBodyHighlight()
	if bodyHighlight then
		bodyHighlight:Destroy()
		bodyHighlight = nil
	end
end

local function flashWhite(character: Model)
	clearBodyHighlight()
	local hl = Instance.new("Highlight")
	hl.Name = "WorkoutPowerFlash"
	hl.Adornee = character
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillColor = Color3.new(1, 1, 1)
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.15
	hl.OutlineTransparency = 0.35
	hl.Parent = character
	bodyHighlight = hl

	local proxy = Instance.new("NumberValue")
	proxy.Value = 0.15
	local tw = TweenService:Create(
		proxy,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	proxy:GetPropertyChangedSignal("Value"):Connect(function()
		if hl.Parent then
			hl.FillTransparency = proxy.Value
			hl.OutlineTransparency = math.clamp(proxy.Value + 0.2, 0, 1)
		end
	end)
	tw.Completed:Connect(function()
		proxy:Destroy()
		if bodyHighlight == hl then
			clearBodyHighlight()
		elseif hl.Parent then
			hl:Destroy()
		end
	end)
	tw:Play()
end

local function ensureFloaterLayer(main: ScreenGui): Frame
	if floaterLayer and floaterLayer.Parent then
		return floaterLayer
	end
	local layer = Instance.new("Frame")
	layer.Name = "PowerFloaters"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 80
	layer.Parent = main
	floaterLayer = layer
	return layer
end

local function resolvePowerHudColor(amountLabel: TextLabel?): Color3
	if amountLabel then
		local c = amountLabel.TextColor3
		-- Ignore near-white / near-black defaults; keep gold.
		local _, s, v = c:ToHSV()
		if s > 0.15 and v > 0.35 then
			return c
		end
	end
	return POWER_HUD_YELLOW
end

local function ensureHudScale(host: GuiObject): UIScale
	local sc = powerHudScale
	if sc and sc.Parent == host then
		return sc
	end
	sc = host:FindFirstChildOfClass("UIScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Scale = 1
		sc.Parent = host
	end
	powerHudScale = sc
	return sc
end

local function pulsePowerHud(amountLabel: GuiObject?, powerFrame: GuiObject?)
	local host: GuiObject? = nil
	if powerFrame then
		local icon = powerFrame:FindFirstChild("Icon")
		if icon and icon:IsA("GuiObject") then
			host = icon
		else
			host = powerFrame
		end
	elseif amountLabel then
		host = amountLabel
	end
	if not host then
		return
	end

	local sc = ensureHudScale(host)
	sc.Scale = 1
	local up = TweenService:Create(
		sc,
		TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.28 }
	)
	up:Play()
	up.Completed:Connect(function()
		if sc.Parent then
			TweenService:Create(
				sc,
				TweenInfo.new(0.32, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
		end
	end)

	-- Tiny fixed-pixel glow on the icon only (never stretch across SideUI).
	local glow = host:FindFirstChild("PowerHitGlow")
	if glow then
		glow:Destroy()
	end
	local bloom = Instance.new("Frame")
	bloom.Name = "PowerHitGlow"
	bloom.AnchorPoint = Vector2.new(0.5, 0.5)
	bloom.Position = UDim2.fromScale(0.5, 0.5)
	bloom.Size = UDim2.fromOffset(64, 64)
	bloom.BackgroundColor3 = POWER_HUD_YELLOW
	bloom.BackgroundTransparency = 0.4
	bloom.BorderSizePixel = 0
	bloom.ZIndex = math.max(1, host.ZIndex)
	bloom.Parent = host
	local bloomCorner = Instance.new("UICorner")
	bloomCorner.CornerRadius = UDim.new(1, 0)
	bloomCorner.Parent = bloom
	TweenService:Create(
		bloom,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1, Size = UDim2.fromOffset(96, 96) }
	):Play()
	task.delay(0.45, function()
		if bloom.Parent then
			bloom:Destroy()
		end
	end)

	local rim = host:FindFirstChild("PowerHitRim")
	if rim then
		rim:Destroy()
	end
	local rimStroke = Instance.new("UIStroke")
	rimStroke.Name = "PowerHitRim"
	rimStroke.Thickness = 0
	rimStroke.Color = Color3.fromRGB(255, 245, 180)
	rimStroke.Transparency = 0
	rimStroke.Parent = host
	TweenService:Create(
		rimStroke,
		TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Thickness = 3 }
	):Play()
	task.delay(0.1, function()
		if not rimStroke.Parent then
			return
		end
		TweenService:Create(
			rimStroke,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Thickness = 0, Transparency = 1 }
		):Play()
		task.delay(0.4, function()
			if rimStroke.Parent then
				rimStroke:Destroy()
			end
		end)
	end)

	if amountLabel and amountLabel:IsA("TextLabel") then
		local label = amountLabel :: TextLabel
		local baseColor = label.TextColor3
		label.TextColor3 = Color3.fromRGB(255, 255, 230)
		TweenService:Create(
			label,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = POWER_HUD_YELLOW }
		):Play()
		task.delay(0.18, function()
			if label.Parent then
				TweenService:Create(
					label,
					TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ TextColor3 = baseColor }
				):Play()
			end
		end)
	end

	if host:IsA("ImageLabel") then
		local baseT = host.ImageTransparency
		local baseC = host.ImageColor3
		host.ImageColor3 = Color3.fromRGB(255, 255, 220)
		TweenService:Create(
			host,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageColor3 = baseC, ImageTransparency = baseT }
		):Play()
	end
end

local function spawnPowerFloater(gain: number)
	local main = PlayerGuiMain.ensure(player)
	local layer = ensureFloaterLayer(main)
	local sideUI = main:FindFirstChild("SideUI")
	local counters = sideUI and sideUI:FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	if not powerFrame or not powerFrame:IsA("GuiObject") then
		return
	end

	-- Aim at the small muscle icon / amount — never the stretched Power container.
	local icon = powerFrame:FindFirstChild("Icon")
	local amountLabel = powerFrame:FindFirstChild("Amount") or powerFrame:FindFirstChildWhichIsA("TextLabel")
	local destGui: GuiObject = if icon and icon:IsA("GuiObject")
		then icon :: GuiObject
		elseif amountLabel and amountLabel:IsA("GuiObject")
		then amountLabel :: GuiObject
		else powerFrame :: GuiObject

	local hudColor = resolvePowerHudColor(
		if amountLabel and amountLabel:IsA("TextLabel") then amountLabel :: TextLabel else nil
	)

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	local function absCenter(gui: GuiObject): Vector2
		return gui.AbsolutePosition + gui.AbsoluteSize * 0.5
	end

	local function toLayerOffset(screen: Vector2): UDim2
		local lp = layer.AbsolutePosition
		return UDim2.fromOffset(screen.X - lp.X, screen.Y - lp.Y)
	end

	-- Wait one frame so AbsolutePosition is valid after layout.
	task.defer(function()
		if not layer.Parent or not destGui.Parent then
			return
		end

		local endScreen = absCenter(destGui)
		local endPos = toLayerOffset(endScreen)

		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		local anchor = if head and head:IsA("BasePart")
			then head
			else (character and character:FindFirstChild("HumanoidRootPart"))

		local startPos = endPos
		if anchor and anchor:IsA("BasePart") and cam then
			local screenPos, onScreen = cam:WorldToViewportPoint(anchor.Position + Vector3.new(0, 1.1, 0))
			if onScreen then
				startPos = toLayerOffset(Vector2.new(screenPos.X, screenPos.Y))
			else
				-- Start just below the Power icon if head is off-screen.
				startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 70)
			end
		else
			startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 70)
		end

		local row = Instance.new("Frame")
		row.Name = "PowerGainFloater"
		row.BackgroundTransparency = 1
		row.BackgroundColor3 = Color3.new(0, 0, 0)
		row.BorderSizePixel = 0
		row.Size = UDim2.fromOffset(120, 36)
		row.AnchorPoint = Vector2.new(0.5, 0.5)
		row.Position = startPos
		row.ZIndex = 90
		row.Parent = layer

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.Parent = row

		local muscle = Instance.new("ImageLabel")
		muscle.Name = "Muscle"
		muscle.BackgroundTransparency = 1
		muscle.Size = UDim2.fromOffset(28, 28)
		muscle.Image = "rbxassetid://73088512205933"
		muscle.ScaleType = Enum.ScaleType.Fit
		muscle.ImageColor3 = Color3.new(1, 1, 1)
		muscle.LayoutOrder = 1
		muscle.ZIndex = 91
		muscle.Parent = row

		local label = Instance.new("TextLabel")
		label.Name = "Gain"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromOffset(80, 32)
		label.TextColor3 = hudColor
		label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.LayoutOrder = 2
		label.ZIndex = 91
		label.Parent = row
		UiFonts.applyBodyLabel(label, 20, 13)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.2
		stroke.Color = Color3.fromRGB(40, 28, 8)
		stroke.Parent = label

		local scale = Instance.new("UIScale")
		scale.Scale = 0.5
		scale.Parent = row
		TweenService:Create(
			scale,
			TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1.08 }
		):Play()

		-- Re-sample end each tick so we track the real icon (not a stretched parent).
		local progress = Instance.new("NumberValue")
		progress.Value = 0
		local startX, startY = startPos.X.Offset, startPos.Y.Offset
		local progConn = progress:GetPropertyChangedSignal("Value"):Connect(function()
			local liveEnd = toLayerOffset(absCenter(destGui))
			local t = progress.Value
			local one = 1 - t
			local midX = (startX + liveEnd.X.Offset) * 0.5
			local midY = math.min(startY, liveEnd.Y.Offset) - 40
			local x = one * one * startX + 2 * one * t * midX + t * t * liveEnd.X.Offset
			local y = one * one * startY + 2 * one * t * midY + t * t * liveEnd.Y.Offset
			row.Position = UDim2.fromOffset(x, y)
		end)

		local move = TweenService:Create(
			progress,
			TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Value = 1 }
		)
		move:Play()
		move.Completed:Connect(function()
			progConn:Disconnect()
			progress:Destroy()
			row.Position = toLayerOffset(absCenter(destGui))
			pulsePowerHud(
				if amountLabel and amountLabel:IsA("GuiObject") then amountLabel :: GuiObject else nil,
				powerFrame :: GuiObject
			)
			local suck = TweenService:Create(
				scale,
				TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Scale = 0.1 }
			)
			local fadeLabel = TweenService:Create(
				label,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ TextTransparency = 1 }
			)
			local fadeStroke = TweenService:Create(
				stroke,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			local fadeMuscle = TweenService:Create(
				muscle,
				TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			)
			suck:Play()
			fadeLabel:Play()
			fadeStroke:Play()
			fadeMuscle:Play()
			suck.Completed:Connect(function()
				row:Destroy()
			end)
		end)
	end)
end

local function cleanupWorkoutVisuals()
	stopWorkoutAnim()
	clearFootAttach()
	clearBodyHighlight()
	local hum = getHumanoid(player.Character)
	if hum then
		lockMovement(hum, false)
	end
end

local function onUnequip()
	if stopWorkoutFn then
		pcall(function()
			stopWorkoutFn:InvokeServer()
		end)
	end
	local char = player.Character
	if char then
		for _, c in char:GetChildren() do
			if c:IsA("Tool") and c:GetAttribute("RainbowGear") == true then
				GearRainbowFX.detach(c)
			end
		end
	end
	cleanupWorkoutVisuals()
end

local function bindTool(tool: Tool)
	if tool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) ~= true then
		return
	end
	if boundTools[tool] then
		return
	end
	boundTools[tool] = true

	local function startWorkoutFromEquip()
		local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
		if typeof(gearId) ~= "number" then
			return
		end
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
			return
		end
		if not startWorkoutFn then
			return
		end
		local ok = startWorkoutFn:InvokeServer(gearId)
		if not ok then
			return
		end
		local character = player.Character
		local hum = getHumanoid(character)
		if character and hum then
			lockMovement(hum, true)
			playWorkoutAnim(character)
			-- Defer so RightGrip exists, then steal the real Handle onto tippy-toes.
			task.defer(function()
				if tool.Parent == character and player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
					attachGearAcrossFeet(character, tool)
				end
			end)
			if tool:GetAttribute("RainbowGear") == true then
				GearRainbowFX.attach(tool)
			end
		end
	end

	table.insert(
		toolConns,
		tool.Equipped:Connect(function()
			startWorkoutFromEquip()
		end)
	)
	table.insert(
		toolConns,
		tool.Unequipped:Connect(function()
			onUnequip()
		end)
	)

	-- If already equipped when we bind (hotbar swap / respawn edge cases).
	if tool.Parent == player.Character then
		task.defer(startWorkoutFromEquip)
	end
end

local function scanTools(root: Instance?)
	if not root then
		return
	end
	for _, c in root:GetChildren() do
		if c:IsA("Tool") then
			bindTool(c)
		end
	end
end

local function bindCharacter(character: Model)
	clearToolConns()
	clearCharConns()
	cleanupWorkoutVisuals()
	scanTools(player:FindFirstChildOfClass("Backpack"))
	scanTools(character)
	table.insert(
		charConns,
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				bindTool(child)
			end
		end)
	)
end

local function init()
	local backpack = player:WaitForChild("Backpack")
	scanTools(backpack)
	backpack.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
		end
	end)

	if player.Character then
		bindCharacter(player.Character)
	end
	player.CharacterAdded:Connect(bindCharacter)

	player:GetAttributeChangedSignal("WorkoutPowerPulse"):Connect(function()
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			return
		end
		local gain = player:GetAttribute("WorkoutLastGain")
		local g = if typeof(gain) == "number" then gain else 0
		local character = player.Character
		if character then
			flashWhite(character)
		end
		if g > 0 then
			spawnPowerFloater(g)
		end
	end)

	player:GetAttributeChangedSignal(GearConfig.WORKOUT_ACTIVE_ATTR):Connect(function()
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			cleanupWorkoutVisuals()
		end
	end)
end

return {
	init = function()
		local ok, err = pcall(init)
		if not ok then
			warn("[WorkoutController] init error:", err)
		end
	end,
}
