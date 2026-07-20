-- [ACTIVE] BrainrotItemTooltip
--[[
	Shared mouse-follow tooltip for brainrot hotbar / backpack slots.
--]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local BrainrotItemTooltip = {}

local TOOLTIP_Z = 120
local MOUSE_OFFSET = Vector2.new(14, 14)
local MOUSE_OFFSET_ABOVE = Vector2.new(14, -10)
local FADE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local tooltipFrame: Frame? = nil
local tooltipTitle: TextLabel? = nil
local activeHost: GuiObject? = nil
local positionConn: RBXScriptConnection? = nil
local globalConns: { RBXScriptConnection } = {}
local fadeTweens: { Tween } = {}
local isShowing = false
local globalsWired = false

local function isMobileClient(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function cancelFadeTweens()
	for _, tw in fadeTweens do
		tw:Cancel()
	end
	table.clear(fadeTweens)
end

local function stopFollow()
	if positionConn then
		positionConn:Disconnect()
		positionConn = nil
	end
end

local function playerGuiObjectsAt(x: number, y: number): { GuiObject }
	local ok, result = pcall(function()
		return GuiService:GetGuiObjectsAtPosition(x, y)
	end)
	if ok and typeof(result) == "table" then
		return result :: { GuiObject }
	end
	return {}
end

local function isMouseOverHost(host: GuiObject): boolean
	if not host.Parent or not host.Visible then
		return false
	end
	local pos = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	local guiX = pos.X - inset.X
	local guiY = pos.Y - inset.Y
	local objs = playerGuiObjectsAt(guiX, guiY)
	for _, obj in objs do
		if obj == host or obj:IsDescendantOf(host) then
			return true
		end
	end
	-- Fallback AABB (covers cases where the host is Active=false and omitted from hits).
	local absPos = host.AbsolutePosition
	local absSize = host.AbsoluteSize
	return guiX >= absPos.X
		and guiY >= absPos.Y
		and guiX <= absPos.X + absSize.X
		and guiY <= absPos.Y + absSize.Y
end

local function updatePosition()
	if not isShowing or not tooltipFrame or not tooltipFrame.Visible then
		stopFollow()
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
	frame.Active = false
	frame.Selectable = false
	frame.ZIndex = TOOLTIP_Z
	frame.BorderSizePixel = 0
	frame.Parent = mainGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(200, 200, 220)
	stroke.Thickness = 1
	stroke.Transparency = 0.7
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
	title.Active = false
	title.Selectable = false
	UiFonts.applyBodyLabel(title, 11, 7)
	title.TextColor3 = Color3.fromRGB(245, 245, 255)
	title.TextTransparency = 1
	title.AutomaticSize = Enum.AutomaticSize.XY
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	tooltipFrame = frame
	tooltipTitle = title
end

function BrainrotItemTooltip.hide(_force: boolean?)
	isShowing = false
	activeHost = nil
	stopFollow()
	cancelFadeTweens()
	if tooltipFrame then
		tooltipFrame.Visible = false
		tooltipFrame.BackgroundTransparency = 1
	end
	if tooltipTitle then
		tooltipTitle.TextTransparency = 1
		tooltipTitle.Text = ""
	end
end

local function wireGlobalHideListeners()
	if globalsWired then
		return
	end
	globalsWired = true
	local player = Players.LocalPlayer

	table.insert(
		globalConns,
		UserInputService.InputBegan:Connect(function(input, _gameProcessed)
			if not isShowing then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3
				or input.UserInputType == Enum.UserInputType.Touch
			then
				BrainrotItemTooltip.hide(true)
			end
		end)
	)

	table.insert(
		globalConns,
		UserInputService.WindowFocusReleased:Connect(function()
			BrainrotItemTooltip.hide(true)
		end)
	)

	local function wireCharacter(char: Model)
		BrainrotItemTooltip.hide(true)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			table.insert(
				globalConns,
				hum.Died:Connect(function()
					BrainrotItemTooltip.hide(true)
				end)
			)
		end
		table.insert(
			globalConns,
			char.ChildRemoved:Connect(function(child)
				if child:IsA("Tool") then
					BrainrotItemTooltip.hide(true)
				end
			end)
		)
	end

	if player.Character then
		wireCharacter(player.Character)
	end
	table.insert(
		globalConns,
		player.CharacterAdded:Connect(function(char)
			wireCharacter(char)
		end)
	)
end

function BrainrotItemTooltip.init()
	if isMobileClient() then
		return
	end
	local player = Players.LocalPlayer
	local mainGui = PlayerGuiMain.ensure(player)
	ensureTooltip(mainGui)
	wireGlobalHideListeners()
end

function BrainrotItemTooltip.show(nameText: string, host: GuiObject?)
	if isMobileClient() or nameText == "" then
		return
	end
	local player = Players.LocalPlayer
	local mainGui = PlayerGuiMain.ensure(player)
	ensureTooltip(mainGui)
	wireGlobalHideListeners()
	if not tooltipFrame or not tooltipTitle then
		return
	end

	activeHost = host
	isShowing = true

	tooltipTitle.Text = nameText
	tooltipFrame.Visible = true
	updatePosition()

	if not positionConn then
		positionConn = RunService.RenderStepped:Connect(function()
			if not isShowing then
				stopFollow()
				return
			end
			local hostGui = activeHost
			if hostGui and not isMouseOverHost(hostGui) then
				BrainrotItemTooltip.hide(true)
				return
			end
			updatePosition()
		end)
	end

	cancelFadeTweens()
	local twFrame = TweenService:Create(tooltipFrame, FADE_TWEEN, { BackgroundTransparency = 0.55 })
	local twTitle = TweenService:Create(tooltipTitle, FADE_TWEEN, { TextTransparency = 0 })
	table.insert(fadeTweens, twFrame)
	table.insert(fadeTweens, twTitle)
	twFrame:Play()
	twTitle:Play()
end

function BrainrotItemTooltip.bind(gui: GuiObject, getName: () -> string?)
	if isMobileClient() then
		return
	end
	if not gui:IsA("GuiButton") then
		gui.Active = true
	end

	local function hideIfThisHost()
		if activeHost == nil or activeHost == gui then
			BrainrotItemTooltip.hide(true)
		end
	end

	gui.MouseEnter:Connect(function()
		local nameText = getName()
		if typeof(nameText) == "string" and nameText ~= "" then
			BrainrotItemTooltip.show(nameText, gui)
		else
			hideIfThisHost()
		end
	end)
	gui.MouseLeave:Connect(hideIfThisHost)
	gui.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			hideIfThisHost()
		end
	end)
	if gui:IsA("GuiButton") then
		(gui :: GuiButton).MouseButton1Down:Connect(function()
			BrainrotItemTooltip.hide(true)
		end)
	end
	gui.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			hideIfThisHost()
		end
	end)
	gui:GetPropertyChangedSignal("Visible"):Connect(function()
		if not gui.Visible then
			hideIfThisHost()
		end
	end)
end

return BrainrotItemTooltip
