-- [ACTIVE] WorkoutController
-- Gear activate: feet attach (handstand), curl anim, white Highlight fade, +power floaters.
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
local bodyHighlight: Highlight? = nil
local walkSpeedBefore: number? = nil
local jumpPowerBefore: number? = nil
local jumpHeightBefore: number? = nil
local floaterLayer: Frame? = nil
local powerHudScale: UIScale? = nil
local handleTransparency: { [BasePart]: number } = {}

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

local function findFoot(character: Model): BasePart?
	-- Prefer the sole at the end of the leg (R15 foot / R6 leg).
	for _, name in { "RightFoot", "LeftFoot", "Right Leg", "Left Leg" } do
		local p = character:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	local lower = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if lower and lower:IsA("BasePart") then
		return lower
	end
	return nil
end

local function stopWorkoutAnim()
	if workoutTrack then
		workoutTrack:Stop(0.15)
		workoutTrack = nil
	end
end

local function destroyHandGrips(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Motor6D") or child:IsA("Weld") or child:IsA("WeldConstraint") then
			local name = string.lower(child.Name)
			if string.find(name, "grip", 1, true) then
				child:Destroy()
			end
		end
	end
	-- Also strip any hand→handle joints the Tool recreates under limbs.
	for _, limbName in { "RightHand", "LeftHand", "Right Arm", "Left Arm" } do
		local limb = character:FindFirstChild(limbName)
		if limb then
			for _, c in limb:GetChildren() do
				if c:IsA("Motor6D") or c:IsA("Weld") then
					local n = string.lower(c.Name)
					if string.find(n, "grip", 1, true) then
						c:Destroy()
					end
				end
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
end

local function hideToolVisibility(tool: Tool)
	restoreToolVisibility()
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			handleTransparency[d] = d.LocalTransparencyModifier
			d.LocalTransparencyModifier = 1
		end
	end
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

local function attachGearToFeet(character: Model, tool: Tool)
	clearFootAttach()
	local foot = findFoot(character)
	local handle = tool:FindFirstChild("Handle")
	if not foot or not handle or not handle:IsA("BasePart") then
		return
	end

	-- Real Tool stays equipped (workout detection) but hidden — grip keeps fighting
	-- the foot motor during the flip, so we show a separate prop on the sole instead.
	hideToolVisibility(tool)
	destroyHandGrips(character)

	local function killGrips()
		local char = player.Character
		if char then
			destroyHandGrips(char)
		end
	end
	gripKillConn = RunService.Heartbeat:Connect(killGrips)
	gripChildConn = character.ChildAdded:Connect(function(child)
		if child:IsA("Motor6D") or child:IsA("Weld") or child:IsA("WeldConstraint") then
			local n = string.lower(child.Name)
			if string.find(n, "grip", 1, true) then
				task.defer(function()
					if child.Parent then
						child:Destroy()
					end
				end)
			end
		end
	end)

	local prop = Instance.new("Model")
	prop.Name = "WorkoutFootProp"

	local primary: BasePart? = nil
	local clones: { BasePart } = {}
	local worldCf: { [BasePart]: CFrame } = {}
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			local c = d:Clone()
			c.Anchored = false
			c.CanCollide = false
			c.Massless = true
			c.CanQuery = false
			c.CanTouch = false
			c.LocalTransparencyModifier = 0
			worldCf[c] = d.CFrame
			c.Parent = prop
			c.CFrame = worldCf[c]
			table.insert(clones, c)
			if d == handle or d.Name == "Handle" then
				primary = c
			end
		end
	end
	-- Carry loose VFX folders that lived under the tool (not under parts).
	for _, d in tool:GetChildren() do
		if not d:IsA("BasePart") and not d:IsA("Script") and not d:IsA("LocalScript") then
			local okClone, cloned = pcall(function()
				return d:Clone()
			end)
			if okClone and cloned then
				cloned.Parent = prop
			end
		end
	end

	if not primary then
		primary = clones[1]
	end
	if not primary then
		prop:Destroy()
		restoreToolVisibility()
		return
	end
	primary.Name = "Handle"

	for _, p in clones do
		if p ~= primary then
			local w = Instance.new("WeldConstraint")
			w.Part0 = primary
			w.Part1 = p
			w.Parent = primary
		end
	end

	-- Sole of the foot (end of the leg). Follows the flip with the foot bone.
	local soleY = -foot.Size.Y * 0.5 - 0.12
	local motor = Instance.new("Motor6D")
	motor.Name = "WorkoutFootMotor"
	motor.Part0 = foot
	motor.Part1 = primary
	motor.C0 = CFrame.new(0, soleY, 0) * CFrame.Angles(0, math.rad(90), math.rad(90))
	motor.C1 = CFrame.new()
	motor.Parent = foot
	footMotor = motor

	prop.Parent = character
	footProp = prop
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
	if not amountLabel then
		return
	end
	local host: GuiObject = if powerFrame then powerFrame else amountLabel
	local parent = amountLabel.Parent
	if not powerFrame and parent and parent:IsA("GuiObject") then
		host = parent :: GuiObject
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

	-- Soft yellow bloom behind the counter (simple frame so we don't depend on a glow decal).
	local glow = host:FindFirstChild("PowerHitGlow")
	if glow then
		glow:Destroy()
	end
	local bloom = Instance.new("Frame")
	bloom.Name = "PowerHitGlow"
	bloom.AnchorPoint = Vector2.new(0.5, 0.5)
	bloom.Position = UDim2.fromScale(0.5, 0.5)
	bloom.Size = UDim2.fromScale(1.15, 1.25)
	bloom.BackgroundColor3 = POWER_HUD_YELLOW
	bloom.BackgroundTransparency = 0.35
	bloom.BorderSizePixel = 0
	bloom.ZIndex = math.max(0, host.ZIndex - 1)
	bloom.Parent = host
	local bloomCorner = Instance.new("UICorner")
	bloomCorner.CornerRadius = UDim.new(0.35, 0)
	bloomCorner.Parent = bloom
	TweenService:Create(
		bloom,
		TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1, Size = UDim2.fromScale(1.65, 1.85) }
	):Play()
	task.delay(0.48, function()
		if bloom.Parent then
			bloom:Destroy()
		end
	end)

	-- Bright rim flash on the counter frame.
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
		{ Thickness = 3.5 }
	):Play()
	task.delay(0.1, function()
		if not rimStroke.Parent then
			return
		end
		TweenService:Create(
			rimStroke,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Thickness = 0, Transparency = 1 }
		):Play()
		task.delay(0.45, function()
			if rimStroke.Parent then
				rimStroke:Destroy()
			end
		end)
	end)

	if amountLabel:IsA("TextLabel") then
		local label = amountLabel :: TextLabel
		local baseColor = label.TextColor3
		local baseStroke: UIStroke? = label:FindFirstChildOfClass("UIStroke")
		local baseStrokeColor = if baseStroke then baseStroke.Color else nil
		local baseStrokeThick = if baseStroke then baseStroke.Thickness else nil

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

		if baseStroke then
			baseStroke.Color = Color3.fromRGB(255, 240, 160)
			baseStroke.Thickness = (baseStrokeThick or 2) + 1.5
			TweenService:Create(
				baseStroke,
				TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{
					Color = baseStrokeColor or Color3.new(0, 0, 0),
					Thickness = baseStrokeThick or 2,
				}
			):Play()
		end
	end

	-- Flash any icon sitting in the Power counter.
	local icon = host:FindFirstChild("Icon") or host:FindFirstChildWhichIsA("ImageLabel")
	if icon and icon:IsA("ImageLabel") and icon.Name ~= "PowerHitGlow" then
		local baseT = icon.ImageTransparency
		local baseC = icon.ImageColor3
		icon.ImageTransparency = 0
		icon.ImageColor3 = Color3.fromRGB(255, 255, 220)
		TweenService:Create(
			icon,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageColor3 = baseC, ImageTransparency = baseT }
		):Play()
	end
end

local function spawnPowerFloater(gain: number)
	local main = PlayerGuiMain.ensure(player)
	local layer = ensureFloaterLayer(main)
	local counters = main:FindFirstChild("SideUI") and (main :: any).SideUI:FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	local target = powerFrame and (powerFrame:FindFirstChild("Amount") or powerFrame:FindFirstChildWhichIsA("TextLabel"))
	local amountLabel = if target and target:IsA("TextLabel") then target :: TextLabel else nil
	local hudColor = resolvePowerHudColor(amountLabel)
	local powerGui = if powerFrame and powerFrame:IsA("GuiObject") then powerFrame :: GuiObject else nil

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart")
		then head
		else (character and character:FindFirstChild("HumanoidRootPart"))
	if not anchor or not anchor:IsA("BasePart") then
		return
	end
	local screenPos, onScreen = cam:WorldToViewportPoint(anchor.Position + Vector3.new(1.15, 0.85, 0))
	if not onScreen then
		return
	end
	local startX = screenPos.X + 10
	local startY = screenPos.Y - 6

	-- Container: muscle icon + yellowish +N (matches Power HUD).
	local row = Instance.new("Frame")
	row.Name = "PowerGainFloater"
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromOffset(150, 40)
	row.Position = UDim2.fromOffset(startX - 24, startY - 18)
	row.ZIndex = 81
	row.Parent = layer

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local muscle = Instance.new("ImageLabel")
	muscle.Name = "Muscle"
	muscle.BackgroundTransparency = 1
	muscle.Size = UDim2.fromOffset(32, 32)
	muscle.Image = "rbxassetid://73088512205933"
	muscle.ScaleType = Enum.ScaleType.Fit
	muscle.ImageColor3 = Color3.new(1, 1, 1)
	muscle.LayoutOrder = 1
	muscle.ZIndex = 82
	muscle.Parent = row

	local label = Instance.new("TextLabel")
	label.Name = "Gain"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(110, 34)
	label.TextScaled = false
	label.TextColor3 = hudColor
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTransparency = 0
	label.LayoutOrder = 2
	label.ZIndex = 82
	label.Parent = row
	UiFonts.applyBodyLabel(label, 22, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(40, 28, 8)
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.45
	scale.Parent = row

	local endPos = row.Position
	if target and target:IsA("GuiObject") then
		local abs = target.AbsolutePosition
		local size = target.AbsoluteSize
		endPos = UDim2.fromOffset(abs.X + size.X * 0.2, abs.Y + size.Y * 0.1)
	end

	TweenService:Create(
		scale,
		TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.15 }
	):Play()

	local move = TweenService:Create(
		row,
		TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut),
		{ Position = endPos }
	)
	move:Play()
	move.Completed:Connect(function()
		-- Combine into the Power counter: suck-in + light-up hit.
		pulsePowerHud(
			if target and target:IsA("GuiObject") then target :: GuiObject else nil,
			powerGui
		)
		local suck = TweenService:Create(
			scale,
			TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Scale = 0.15 }
		)
		local fadeLabel = TweenService:Create(
			label,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		local fadeStroke = TweenService:Create(
			stroke,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		local fadeMuscle = TweenService:Create(
			muscle,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
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
			attachGearToFeet(character, tool)
			playWorkoutAnim(character)
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
