-- [ACTIVE] WorkoutController
-- Equipped gear activation: lock movement, white flash, +power floaters into SideUI Power.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

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
local walkSpeedBefore: number? = nil
local jumpPowerBefore: number? = nil
local jumpHeightBefore: number? = nil
local floaterLayer: Frame? = nil

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
	bb.Size = UDim2.fromOffset(120, 120)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 80
	bb.Adornee = head
	bb.Parent = head
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = GearConfig.WORKOUT_IMAGE
	img.Parent = bb
	workoutBillboard = bb
end

local function flashWhite(character: Model)
	local parts: { BasePart } = {}
	local originals: { [BasePart]: Color3 } = {}
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			table.insert(parts, d)
			originals[d] = d.Color
			d.Color = Color3.new(1, 1, 1)
		end
	end
	task.delay(0.12, function()
		for _, p in parts do
			if p.Parent and originals[p] then
				p.Color = originals[p]
			end
		end
	end)
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
	local counters = main:FindFirstChild("SideUI") and (main.SideUI :: Instance):FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	local target = powerFrame and powerFrame:FindFirstChild("Amount")
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local screenPos, onScreen = cam:WorldToViewportPoint(hrp.Position + Vector3.new(0, 2, 0))
	if not onScreen then
		return
	end

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(90, 28)
	label.Position = UDim2.fromOffset(screenPos.X - 45, screenPos.Y - 14)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(120, 255, 140)
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain)
	label.ZIndex = 81
	label.Parent = layer
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Parent = label

	local endPos = label.Position
	if target and target:IsA("GuiObject") then
		local abs = target.AbsolutePosition
		local size = target.AbsoluteSize
		endPos = UDim2.fromOffset(abs.X + size.X * 0.5 - 45, abs.Y + size.Y * 0.5 - 14)
	end

	local tween = TweenService:Create(
		label,
		TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = endPos, TextTransparency = 0.15 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		local fade = TweenService:Create(
			label,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		fade:Play()
		fade.Completed:Connect(function()
			label:Destroy()
		end)
	end)
end

local function onUnequip()
	if stopWorkoutFn then
		pcall(function()
			stopWorkoutFn:InvokeServer()
		end)
	end
	destroyWorkoutBillboard()
	local hum = getHumanoid(player.Character)
	if hum then
		lockMovement(hum, false)
	end
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
		tool.Equipped:Connect(function()
			-- Wait for activate to start workout.
		end)
	)
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
	onUnequip()
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
			destroyWorkoutBillboard()
			local hum = getHumanoid(player.Character)
			if hum then
				lockMovement(hum, false)
			end
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
