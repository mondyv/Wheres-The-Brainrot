-- [ACTIVE] GamepadInput
--[[
	Shared gamepad helpers: preferred-input detection, face-button labels/icons
	that respect Xbox vs PlayStation glyphs (via GetStringForKeyCode / GetImageForKeyCode).
]]

local UserInputService = game:GetService("UserInputService")
local GamepadService = game:GetService("GamepadService")

local M = {}

-- Canonical bindings used across gameplay UIs.
M.ACCEPT = Enum.KeyCode.ButtonA -- Xbox A / PlayStation Cross
M.DECLINE = Enum.KeyCode.ButtonB -- Xbox B / PlayStation Circle
M.INTERACT = Enum.KeyCode.ButtonX -- Xbox X / PlayStation Square (bush / prompts)
M.SECONDARY = Enum.KeyCode.ButtonY -- Xbox Y / PlayStation Triangle (backpack, steal)
M.QTE = Enum.KeyCode.ButtonA -- spider dodge (same as accept / confirm)

export type HintOpts = {
	contrast: boolean?,
	imageColor: Color3?,
}

local FALLBACK_FACE: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonA] = "A",
	[Enum.KeyCode.ButtonB] = "B",
	[Enum.KeyCode.ButtonX] = "X",
	[Enum.KeyCode.ButtonY] = "Y",
	[Enum.KeyCode.DPadLeft] = "◀",
	[Enum.KeyCode.DPadRight] = "▶",
	[Enum.KeyCode.DPadUp] = "▲",
	[Enum.KeyCode.DPadDown] = "▼",
	[Enum.KeyCode.ButtonSelect] = "View",
	[Enum.KeyCode.ButtonL1] = "LB",
	[Enum.KeyCode.ButtonR1] = "RB",
	[Enum.KeyCode.ButtonL2] = "LT",
	[Enum.KeyCode.ButtonR2] = "RT",
}

function M.lastInputIsGamepad(): boolean
	local last = UserInputService:GetLastInputType()
	return string.sub(last.Name, 1, 7) == "Gamepad"
end

function M.preferredInput(): Enum.PreferredInput?
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok then
		return preferred
	end
	return nil
end

function M.hasGamepadHardware(): boolean
	if UserInputService.GamepadEnabled then
		return true
	end
	local ok, pads = pcall(function()
		return UserInputService:GetConnectedGamepads()
	end)
	return ok and typeof(pads) == "table" and #pads > 0
end

function M.isPreferred(): boolean
	if M.lastInputIsGamepad() then
		return true
	end
	if M.preferredInput() == Enum.PreferredInput.Gamepad then
		return true
	end
	-- Console-style: gamepad present, no keyboard/touch driving UI.
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		return true
	end
	return false
end

function M.isGamepadKeyCode(keyCode: Enum.KeyCode): boolean
	local name = keyCode.Name
	return string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 6) == "Thumb" or string.find(name, "Trigger", 1, true) ~= nil
end

function M.faceLabel(keyCode: Enum.KeyCode): string
	local ok, text = pcall(function()
		return UserInputService:GetStringForKeyCode(keyCode)
	end)
	if ok and typeof(text) == "string" and text ~= "" then
		-- Strip "Button" prefix if the API returns raw enum-ish names.
		if string.sub(text, 1, 6) == "Button" and #text == 7 then
			return string.sub(text, 7, 7)
		end
		return text
	end
	return FALLBACK_FACE[keyCode] or "•"
end

function M.faceImage(keyCode: Enum.KeyCode): string
	local ok, img = pcall(function()
		return UserInputService:GetImageForKeyCode(keyCode)
	end)
	if ok and typeof(img) == "string" and img ~= "" then
		return img
	end
	return ""
end

-- Short tip fragment e.g. "Ⓐ" / "A" / "✕" depending on platform.
function M.tipToken(keyCode: Enum.KeyCode): string
	return M.faceLabel(keyCode)
end

function M.onPreferredChanged(callback: (boolean) -> ()): RBXScriptConnection
	local function fire()
		callback(M.isPreferred())
	end
	local conn = UserInputService.LastInputTypeChanged:Connect(fire)
	UserInputService.GamepadConnected:Connect(function()
		fire()
	end)
	UserInputService.GamepadDisconnected:Connect(function()
		fire()
	end)
	pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(fire)
	end)
	return conn
end

function M.cursorScreenPosition(): Vector2
	if M.isPreferred() then
		local ok, pos = pcall(function()
			return GamepadService:GetGamepadCursorPosition()
		end)
		if ok and typeof(pos) == "Vector2" then
			return pos
		end
	end
	return UserInputService:GetMouseLocation()
end

function M.isAcceptHeld(): boolean
	local ok, held = pcall(function()
		return UserInputService:IsGamepadButtonPressed(Enum.UserInputType.Gamepad1, M.ACCEPT)
	end)
	return ok and held == true
end

function M.mountHint(host: GuiObject, keyCode: Enum.KeyCode, centered: boolean?, opts: HintOpts?)
	local contrast = opts ~= nil and opts.contrast == true
	local imageColor = if opts and opts.imageColor then opts.imageColor else Color3.fromRGB(255, 255, 255)
	local hint = host:FindFirstChild("GamepadHotkey")
	if not (hint and hint:IsA("ImageLabel")) then
		local label = Instance.new("ImageLabel")
		label.Name = "GamepadHotkey"
		label.BackgroundTransparency = 1
		if centered == true then
			label.AnchorPoint = Vector2.new(0.5, 0.5)
			label.Position = UDim2.fromScale(0.5, 0.5)
			label.Size = UDim2.fromOffset(26, 26)
		else
			label.AnchorPoint = Vector2.new(1, 1)
			label.Position = UDim2.new(1, 2, 1, 2)
			label.Size = UDim2.fromOffset(22, 22)
		end
		label.ZIndex = math.max(host.ZIndex + 3, 7)
		label.ScaleType = Enum.ScaleType.Fit
		label.ClipsDescendants = false
		label.Visible = false
		label.Parent = host
		hint = label
	elseif centered == true then
		hint.AnchorPoint = Vector2.new(0.5, 0.5)
		hint.Position = UDim2.fromScale(0.5, 0.5)
		hint.Size = UDim2.fromOffset(26, 26)
	end
	hint.ImageColor3 = imageColor
	local staleChild = hint:FindFirstChild("GamepadHotkeyBadge")
	if staleChild then
		staleChild:Destroy()
	end

	local function shadowPos(): UDim2
		return UDim2.new(
			hint.Position.X.Scale,
			hint.Position.X.Offset + 2,
			hint.Position.Y.Scale,
			hint.Position.Y.Offset + 3
		)
	end
	local function shadowSize(): UDim2
		local w = hint.Size.X.Offset
		local h = hint.Size.Y.Offset
		if w <= 0 then
			w = 22
		end
		if h <= 0 then
			h = 22
		end
		return UDim2.fromOffset(w + 6, h + 6)
	end

	local badge = host:FindFirstChild("GamepadHotkeyBadge")
	if contrast then
		if not (badge and badge:IsA("Frame")) then
			local frame = Instance.new("Frame")
			frame.Name = "GamepadHotkeyBadge"
			frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			frame.BackgroundTransparency = 0.58
			frame.BorderSizePixel = 0
			frame.AnchorPoint = hint.AnchorPoint
			frame.Position = shadowPos()
			frame.Size = shadowSize()
			frame.ZIndex = math.max(hint.ZIndex - 1, 1)
			frame.Visible = false
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = frame
			frame.Parent = host
			badge = frame
		end
		if badge and badge:IsA("Frame") then
			badge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			badge.BackgroundTransparency = 0.58
			badge.AnchorPoint = hint.AnchorPoint
			badge.Position = shadowPos()
			badge.Size = shadowSize()
			badge.ZIndex = math.max(hint.ZIndex - 1, 1)
		end
	end

	local text = host:FindFirstChild("GamepadHotkeyText")
	if not (text and text:IsA("TextLabel")) then
		local label = Instance.new("TextLabel")
		label.Name = "GamepadHotkeyText"
		label.BackgroundTransparency = 1
		label.AnchorPoint = hint.AnchorPoint
		label.Position = hint.Position
		label.Size = hint.Size
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextColor3 = imageColor
		label.ZIndex = hint.ZIndex + 1
		label.Visible = false
		label.Parent = host
		text = label
	end

	local function refresh()
		if not host.Parent then
			return
		end
		local show = M.isPreferred()
		local img = if show then M.faceImage(keyCode) else ""
		local caption = M.faceLabel(keyCode)
		hint.Image = img
		hint.Visible = show and img ~= ""
		text.Text = caption
		text.Visible = show and img == ""
		if badge and badge:IsA("GuiObject") then
			badge.Visible = show and contrast
			badge.AnchorPoint = hint.AnchorPoint
			badge.Position = shadowPos()
			badge.Size = shadowSize()
			badge.ZIndex = math.max(hint.ZIndex - 1, 1)
		end
	end
	refresh()
	if host:GetAttribute("_GamepadHotkeyWired") ~= true then
		host:SetAttribute("_GamepadHotkeyWired", true)
		M.onPreferredChanged(function()
			refresh()
		end)
	end
end

function M.setHintVisible(host: GuiObject, visible: boolean)
	for _, name in { "GamepadHotkey", "GamepadHotkeyBadge", "GamepadHotkeyText" } do
		local inst = host:FindFirstChild(name)
		if inst and inst:IsA("GuiObject") then
			inst.Visible = visible
		end
	end
end

function M.clearHint(host: GuiObject)
	host:SetAttribute("_GamepadHotkeyWired", nil)
	for _, name in { "GamepadHotkey", "GamepadHotkeyBadge", "GamepadHotkeyText" } do
		local inst = host:FindFirstChild(name)
		if inst then
			inst:Destroy()
		end
	end
	local nested = host:FindFirstChild("GamepadHotkey")
	if nested then
		nested:Destroy()
	end
end

return M
