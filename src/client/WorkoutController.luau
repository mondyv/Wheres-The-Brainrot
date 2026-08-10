-- [ACTIVE] WorkoutController
-- Gear activate: feet attach (handstand), curl anim, white Highlight fade, +power floaters.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

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
local workoutBillboard: BillboardGui? = nil
local workoutTrack: AnimationTrack? = nil
local workoutAnim: Animation? = nil
local footWeld: WeldConstraint? = nil
local footMotor: Motor6D? = nil
local bodyHighlight: Highlight? = nil
local walkSpeedBefore: number? = nil
local jumpPowerBefore: number? = nil
local jumpHeightBefore: number? = nil
local floaterLayer: Frame? = nil
local handleTransparency: { [BasePart]: number } = {}

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

local function clearFootAttach()
	if footWeld then
		footWeld:Destroy()
		footWeld = nil
	end
	if footMotor then
		footMotor:Destroy()
		footMotor = nil
	end
	for part, tr in handleTransparency do
		if part.Parent then
			part.LocalTransparencyModifier = 0
			part.Transparency = tr
		end
	end
	table.clear(handleTransparency)
end

local function attachGearToFeet(character: Model, tool: Tool)
	clearFootAttach()
	local foot = findFoot(character)
	local handle = tool:FindFirstChild("Handle")
	if not foot or not handle or not handle:IsA("BasePart") then
		return
	end

	-- Break default hand grip so the barbell can sit on the feet (handstand).
	for _, name in { "RightGrip", "LeftGrip" } do
		local grip = character:FindFirstChild(name)
		if grip then
			grip:Destroy()
		end
	end

	-- Orient barbell across both feet.
	handle.CFrame = foot.CFrame * CFrame.new(0, -0.15, 0) * CFrame.Angles(0, 0, math.rad(90))
	local weld = Instance.new("WeldConstraint")
	weld.Name = "WorkoutFootWeld"
	weld.Part0 = foot
	weld.Part1 = handle
	weld.Parent = handle
	footWeld = weld
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

local function destroyWorkoutBillboard()
	if workoutBillboard then
		workoutBillboard:Destroy()
		workoutBillboard = nil
	end
end

local function showWorkoutBillboard(character: Model)
	destroyWorkoutBillboard()
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "WorkoutVisual"
	bb.Size = UDim2.fromOffset(88, 88)
	bb.StudsOffset = Vector3.new(1.35, 1.1, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 90
	bb.Adornee = head
	bb.Parent = head
	local img = Instance.new("ImageLabel")
	img.Name = "Muscle"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = GearConfig.WORKOUT_IMAGE
	img.Parent = bb
	workoutBillboard = bb
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

local function spawnPowerFloater(gain: number)
	local main = PlayerGuiMain.ensure(player)
	local layer = ensureFloaterLayer(main)
	local counters = main:FindFirstChild("SideUI") and (main :: any).SideUI:FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	local target = powerFrame and (powerFrame:FindFirstChild("Amount") or powerFrame:FindFirstChildWhichIsA("TextLabel"))

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	-- Spawn beside the muscle billboard (not the body center).
	local startX: number
	local startY: number
	if workoutBillboard and workoutBillboard.Adornee and workoutBillboard.Adornee:IsA("BasePart") then
		local adornee = workoutBillboard.Adornee :: BasePart
		local world = adornee.Position + Vector3.new(1.6, 1.2, 0)
		local screenPos, onScreen = cam:WorldToViewportPoint(world)
		if onScreen then
			startX = screenPos.X + 18
			startY = screenPos.Y - 10
		else
			return
		end
	else
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			return
		end
		local screenPos, onScreen = cam:WorldToViewportPoint(hrp.Position + Vector3.new(0, 2.2, 0))
		if not onScreen then
			return
		end
		startX = screenPos.X
		startY = screenPos.Y
	end

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(110, 34)
	label.Position = UDim2.fromOffset(startX - 20, startY - 16)
	label.TextScaled = false
	label.TextColor3 = Color3.fromRGB(120, 255, 150)
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain)
	label.TextTransparency = 0
	label.ZIndex = 81
	label.Parent = layer
	UiFonts.applyBodyLabel(label, 22, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.55
	scale.Parent = label

	local endPos = label.Position
	if target and target:IsA("GuiObject") then
		local abs = target.AbsolutePosition
		local size = target.AbsoluteSize
		endPos = UDim2.fromOffset(abs.X + size.X * 0.35, abs.Y + size.Y * 0.15)
	end

	TweenService:Create(
		scale,
		TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.12 }
	):Play()
	task.delay(0.18, function()
		if scale.Parent then
			TweenService:Create(scale, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.9 })
				:Play()
		end
	end)

	local move = TweenService:Create(
		label,
		TweenInfo.new(0.75, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = endPos }
	)
	move:Play()
	move.Completed:Connect(function()
		local fade = TweenService:Create(
			label,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		local fadeStroke = TweenService:Create(
			stroke,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		fade:Play()
		fadeStroke:Play()
		fade.Completed:Connect(function()
			label:Destroy()
		end)
	end)
end

local function cleanupWorkoutVisuals()
	stopWorkoutAnim()
	clearFootAttach()
	destroyWorkoutBillboard()
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
	table.insert(
		toolConns,
		tool.Unequipped:Connect(function()
			onUnequip()
		end)
	)
	table.insert(
		toolConns,
		tool.Activated:Connect(function()
			local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
			if typeof(gearId) ~= "number" then
				return
			end
			if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
				onUnequip()
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
				showWorkoutBillboard(character)
			end
		end)
	)
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
