-- [ACTIVE] BrainrotItemTooltip
--[[
	Shared mouse-follow tooltip for brainrot hotbar / backpack slots.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local BrainrotItemTooltip = {}

local TOOLTIP_Z = 120
local MOUSE_OFFSET = Vector2.new(14, 14)
local MOUSE_OFFSET_ABOVE = Vector2.new(14, -10)
local FADE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local tooltipFrame: Frame? = nil
local tooltipTitle: TextLabel? = nil
local hoverDepth = 0
local positionConn: RBXScriptConnection? = nil

local function isMobileClient(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function updatePosition()
	if not tooltipFrame then
		return
	end
	local pos = UserInputService:GetMouseLocation()
	local camera = Workspace.CurrentCamera
	local viewportY = if camera then camera.ViewportSize.Y else 1080
	local tooltipHeight = tooltipFrame.AbsoluteSize.Y
	if tooltipHeight < 1 then
		tooltipHeight = 36
	end
	local offset = MOUSE_OFFSET
	if pos.Y + offset.Y + tooltipHeight > viewportY then
		offset = MOUSE_OFFSET_ABOVE
		local y = pos.Y + offset.Y - tooltipHeight
		if y < 0 then
			y = 4
		end
		tooltipFrame.Position = UDim2.fromOffset(pos.X + offset.X, y)
		return
	end
	tooltipFrame.Position = UDim2.fromOffset(pos.X + offset.X, pos.Y + offset.Y)
end

local function ensureTooltip(mainGui: ScreenGui)
	if tooltipFrame and tooltipFrame.Parent then
		return
	end

	local frame = Instance.new("Frame")
	frame.Name = "BrainrotItemTooltip"
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = TOOLTIP_Z
	frame.BorderSizePixel = 0
	frame.Parent = mainGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 1.2
	stroke.Transparency = 0.55
	stroke.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextColor3 = Color3.fromRGB(245, 245, 255)
	title.TextTransparency = 1
	title.AutomaticSize = Enum.AutomaticSize.XY
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	tooltipFrame = frame
	tooltipTitle = title
end

function BrainrotItemTooltip.init()
	if isMobileClient() then
		return
	end
	local player = Players.LocalPlayer
	local mainGui = PlayerGuiMain.ensure(player)
	ensureTooltip(mainGui)
end

function BrainrotItemTooltip.show(nameText: string)
	if isMobileClient() or nameText == "" then
		return
	end
	local player = Players.LocalPlayer
	local mainGui = PlayerGuiMain.ensure(player)
	ensureTooltip(mainGui)
	if not tooltipFrame or not tooltipTitle then
		return
	end

	hoverDepth += 1
	tooltipTitle.Text = nameText
	tooltipFrame.Visible = true
	updatePosition()

	if not positionConn then
		positionConn = RunService.RenderStepped:Connect(updatePosition)
	end

	TweenService:Create(tooltipFrame, FADE_TWEEN, { BackgroundTransparency = 0.08 }):Play()
	TweenService:Create(tooltipTitle, FADE_TWEEN, { TextTransparency = 0 }):Play()
end

function BrainrotItemTooltip.hide(force: boolean?)
	if force ~= true and hoverDepth > 1 then
		hoverDepth -= 1
		return
	end
	hoverDepth = 0
	if positionConn then
		positionConn:Disconnect()
		positionConn = nil
	end
	if tooltipFrame then
		tooltipFrame.Visible = false
	end
end

function BrainrotItemTooltip.bind(gui: GuiObject, getName: () -> string?)
	if isMobileClient() then
		return
	end
	if not gui:IsA("GuiButton") then
		gui.Active = true
	end
	gui.MouseEnter:Connect(function()
		local nameText = getName()
		if typeof(nameText) == "string" and nameText ~= "" then
			BrainrotItemTooltip.show(nameText)
		end
	end)
	gui.MouseLeave:Connect(function()
		BrainrotItemTooltip.hide()
	end)
end

return BrainrotItemTooltip
