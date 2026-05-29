-- Shows "No brainrots hiding!" to the local player when a bush search rolls empty (30%).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

local MESSAGE = "No brainrots hiding!"
local DURATION = 4

local player = Players.LocalPlayer
local messageLabel: TextLabel? = nil
local hideToken = 0

local function ensureGui(): ScreenGui
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("NoBrainrotFoundGui")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "NoBrainrotFoundGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = playerGui
	return gui
end

local function ensureMessageLabel(gui: ScreenGui): TextLabel
	if messageLabel and messageLabel.Parent then
		return messageLabel
	end

	local label = Instance.new("TextLabel")
	label.Name = "Message"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.72)
	label.Size = UDim2.new(0.85, 0, 0.08, 0)
	label.BackgroundTransparency = 1
	label.Text = MESSAGE
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.Visible = false
	label.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 220, 90)
	stroke.Thickness = 2.5
	stroke.Parent = label

	messageLabel = label
	return label
end

local function showMessage()
	local gui = ensureGui()
	local label = ensureMessageLabel(gui)
	label.TextTransparency = 0
	label.Visible = true

	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0
	end

	hideToken += 1
	local token = hideToken
	task.delay(DURATION, function()
		if token ~= hideToken or not label.Parent then
			return
		end
		label.Visible = false
	end)
end

function M.init()
	local remote = ReplicatedStorage:WaitForChild("NoBrainrotFoundEvent", 60)
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end
	remote.OnClientEvent:Connect(showMessage)
end

return M
