-- [ACTIVE] AdminSpectateController
--[[
	Client spectate driven by AdminSpectateUserId (admin `spectate` command).
	Shows who you're watching; press X (or Exit button) to stop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local M = {}

local SPECTATE_ATTR = "AdminSpectateUserId"
local COMMAND_REMOTE_NAME = "AdminCommand"

local gui: ScreenGui? = nil
local titleLabel: TextLabel? = nil
local nameLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local exitButton: TextButton? = nil

local activeUserId: number? = nil
local targetConns: { RBXScriptConnection } = {}
local heartbeatConn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil
local attrConn: RBXScriptConnection? = nil

local function getCommandRemote(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(COMMAND_REMOTE_NAME)
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function requestUnspectate()
	local rf = getCommandRemote()
	if not rf then
		return
	end
	local ok, err = pcall(function()
		rf:InvokeServer("unspectate")
	end)
	if not ok then
		warn("[AdminSpectateController] unspectate failed:", err)
	end
end

local function disconnectTargetConns()
	for _, conn in targetConns do
		conn:Disconnect()
	end
	table.clear(targetConns)
end

local function restoreCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Custom
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
end

local function ensureGui(): ScreenGui
	if gui and gui.Parent then
		return gui
	end

	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminSpectateHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 120
	screen.Enabled = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 18)
	panel.Size = UDim2.fromOffset(340, 92)
	panel.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
	panel.BackgroundTransparency = 0.18
	panel.BorderSizePixel = 0
	panel.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(72, 255, 140)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -70, 0, 18)
	title.Position = UDim2.fromOffset(0, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(72, 255, 140)
	title.Text = "SPECTATING"
	title.Parent = panel
	titleLabel = title

	local name = Instance.new("TextLabel")
	name.Name = "TargetName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, -70, 0, 24)
	name.Position = UDim2.fromOffset(0, 22)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 20
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.fromRGB(248, 250, 252)
	name.Text = "—"
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = panel
	nameLabel = name

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.Size = UDim2.new(1, -70, 0, 18)
	hint.Position = UDim2.fromOffset(0, 52)
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 13
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Color3.fromRGB(180, 190, 200)
	hint.Text = "Press X to exit"
	hint.Parent = panel
	hintLabel = hint

	local exit = Instance.new("TextButton")
	exit.Name = "Exit"
	exit.AnchorPoint = Vector2.new(1, 0.5)
	exit.Position = UDim2.new(1, 0, 0.5, 0)
	exit.Size = UDim2.fromOffset(56, 56)
	exit.BackgroundColor3 = Color3.fromRGB(28, 32, 40)
	exit.BorderSizePixel = 0
	exit.AutoButtonColor = true
	exit.Font = Enum.Font.GothamBold
	exit.TextSize = 22
	exit.TextColor3 = Color3.fromRGB(255, 120, 120)
	exit.Text = "X"
	exit.Parent = panel
	exitButton = exit

	local exitCorner = Instance.new("UICorner")
	exitCorner.CornerRadius = UDim.new(0, 8)
	exitCorner.Parent = exit

	local exitStroke = Instance.new("UIStroke")
	exitStroke.Color = Color3.fromRGB(255, 120, 120)
	exitStroke.Thickness = 1.2
	exitStroke.Transparency = 0.45
	exitStroke.Parent = exit

	exit.Activated:Connect(function()
		requestUnspectate()
	end)

	screen.Parent = playerGui
	gui = screen
	return screen
end

local function setHudVisible(on: boolean, target: Player?)
	local screen = ensureGui()
	screen.Enabled = on
	if on and target and nameLabel and hintLabel then
		local display = target.DisplayName
		local user = target.Name
		if display ~= "" and display ~= user then
			nameLabel.Text = string.format("%s (@%s)", display, user)
		else
			nameLabel.Text = user
		end
		hintLabel.Text = "Press X to exit"
	end
end

local function applyCameraToTarget(target: Player)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local char = target.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraType = Enum.CameraType.Custom
		cam.CameraSubject = hum
	end
end

local function stopSpectateLocal()
	activeUserId = nil
	disconnectTargetConns()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	setHudVisible(false, nil)
	restoreCamera()
end

local function startSpectate(target: Player)
	stopSpectateLocal()
	activeUserId = target.UserId
	setHudVisible(true, target)
	applyCameraToTarget(target)

	table.insert(
		targetConns,
		target.CharacterAdded:Connect(function()
			task.defer(function()
				if activeUserId == target.UserId then
					applyCameraToTarget(target)
				end
			end)
		end)
	)

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if activeUserId == nil then
			return
		end
		local targetPlayer = Players:GetPlayerByUserId(activeUserId)
		if not targetPlayer then
			requestUnspectate()
			stopSpectateLocal()
			return
		end
		local cam = Workspace.CurrentCamera
		local char = targetPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if cam and hum and cam.CameraSubject ~= hum then
			cam.CameraType = Enum.CameraType.Custom
			cam.CameraSubject = hum
		end
	end)
end

local function syncFromAttribute()
	local raw = player:GetAttribute(SPECTATE_ATTR)
	if typeof(raw) ~= "number" then
		stopSpectateLocal()
		return
	end
	local userId = math.floor(raw)
	if userId == player.UserId then
		stopSpectateLocal()
		return
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		requestUnspectate()
		stopSpectateLocal()
		return
	end
	if activeUserId == userId then
		setHudVisible(true, target)
		applyCameraToTarget(target)
		return
	end
	startSpectate(target)
end

function M.init()
	ensureGui()

	attrConn = player:GetAttributeChangedSignal(SPECTATE_ATTR):Connect(syncFromAttribute)

	inputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if activeUserId == nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			requestUnspectate()
		end
	end)

	Players.PlayerRemoving:Connect(function(leaving)
		if activeUserId and leaving.UserId == activeUserId then
			requestUnspectate()
			stopSpectateLocal()
		end
	end)

	player.CharacterAdded:Connect(function()
		if activeUserId == nil then
			task.defer(restoreCamera)
		end
	end)

	syncFromAttribute()
end

return M
