-- [ACTIVE] AdminCommandBar
-- F5 command bar for server-side admin commands.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local M = {}

local ACTION_NAME = "ToggleAdminCommandBar"
local COMMAND_REMOTE_NAME = "AdminCommand"

local gui: ScreenGui? = nil
local inputBox: TextBox? = nil
local statusLabel: TextLabel? = nil
local commandRF: RemoteFunction? = nil
local initialized = false

local function getCommandRemote(): RemoteFunction?
	if commandRF and commandRF.Parent then
		return commandRF
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(COMMAND_REMOTE_NAME)
	if rf and rf:IsA("RemoteFunction") then
		commandRF = rf
		return rf
	end
	return nil
end

local function setStatus(text: string, ok: boolean?)
	local label = statusLabel
	if not label then
		return
	end
	label.Text = text
	if ok == nil then
		label.TextColor3 = Color3.fromRGB(185, 195, 210)
	elseif ok then
		label.TextColor3 = Color3.fromRGB(90, 255, 145)
	else
		label.TextColor3 = Color3.fromRGB(255, 100, 100)
	end
end

local function setOpen(open: boolean)
	if not gui or not inputBox then
		return
	end
	gui.Enabled = open
	if open then
		inputBox.Text = ""
		setStatus("Try: addinventory me NoobiniPizzanini or resetdata me", nil)
		inputBox:CaptureFocus()
	else
		inputBox:ReleaseFocus()
	end
end

local function submitCommand()
	local box = inputBox
	if not box then
		return
	end
	local command = box.Text
	if command == "" then
		setOpen(false)
		return
	end

	local rf = getCommandRemote()
	if not rf then
		setStatus("Admin command service is not ready.", false)
		return
	end

	setStatus("Running...", nil)
	local ok, response = pcall(function()
		return rf:InvokeServer(command)
	end)
	if not ok then
		warn("[AdminCommandBar] command invoke failed:", response)
		setStatus("Command failed. Check client output.", false)
		return
	end

	if typeof(response) == "table" then
		setStatus(tostring(response.message or ""), response.ok == true)
	else
		setStatus(tostring(response), nil)
	end
	box.Text = ""
	box:CaptureFocus()
end

local function buildGui(parent: PlayerGui)
	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminCommandBar"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 9999
	screen.Enabled = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.fromScale(0.5, 0.08)
	root.Size = UDim2.fromOffset(560, 78)
	root.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	root.BackgroundTransparency = 0.08
	root.BorderSizePixel = 0

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 12)
	rootCorner.Parent = root

	local rootStroke = Instance.new("UIStroke")
	rootStroke.Color = Color3.fromRGB(90, 255, 145)
	rootStroke.Transparency = 0.25
	rootStroke.Thickness = 1.5
	rootStroke.Parent = root

	local box = Instance.new("TextBox")
	box.Name = "CommandInput"
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.GothamSemibold
	box.PlaceholderText = "admin command..."
	box.Text = ""
	box.TextColor3 = Color3.fromRGB(245, 248, 255)
	box.PlaceholderColor3 = Color3.fromRGB(130, 140, 155)
	box.TextSize = 18
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	box.BorderSizePixel = 0
	box.Position = UDim2.fromOffset(14, 12)
	box.Size = UDim2.new(1, -28, 0, 34)

	local boxPadding = Instance.new("UIPadding")
	boxPadding.PaddingLeft = UDim.new(0, 12)
	boxPadding.PaddingRight = UDim.new(0, 12)
	boxPadding.Parent = box

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 8)
	boxCorner.Parent = box

	local label = Instance.new("TextLabel")
	label.Name = "Status"
	label.Font = Enum.Font.Gotham
	label.Text = "Press Enter to run, Escape to close."
	label.TextColor3 = Color3.fromRGB(185, 195, 210)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(16, 50)
	label.Size = UDim2.new(1, -32, 0, 20)

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submitCommand()
		end
	end)

	root.Parent = screen
	box.Parent = root
	label.Parent = root
	screen.Parent = parent

	gui = screen
	inputBox = box
	statusLabel = label
end

local function toggleOpen()
	local box = inputBox
	if box and UserInputService:GetFocusedTextBox() == box then
		return
	end
	setOpen(not (gui and gui.Enabled))
end

function M.init()
	if initialized then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[AdminCommandBar] PlayerGui missing; F5 admin bar not wired")
		return
	end
	buildGui(playerGui)

	-- UserInputService is the reliable path; ContextActionService is a backup.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.F5 then
			if gameProcessed then
				return
			end
			toggleOpen()
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and gui and gui.Enabled then
			setOpen(false)
		end
	end)

	ContextActionService:BindActionAtPriority(ACTION_NAME, function(_name, state, _input)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		toggleOpen()
		return Enum.ContextActionResult.Sink
	end, false, 2000, Enum.KeyCode.F5)

	initialized = true
end

return M
