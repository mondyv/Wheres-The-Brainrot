-- [ACTIVE] GamepadInput
--[[
	Shared gamepad helpers: preferred-input detection, face-button labels/icons
	that respect Xbox vs PlayStation glyphs (via GetStringForKeyCode / GetImageForKeyCode).
]]

local UserInputService = game:GetService("UserInputService")

local M = {}

-- Canonical bindings used across gameplay UIs.
M.ACCEPT = Enum.KeyCode.ButtonA -- Xbox A / PlayStation Cross
M.DECLINE = Enum.KeyCode.ButtonB -- Xbox B / PlayStation Circle
M.INTERACT = Enum.KeyCode.ButtonX -- Xbox X / PlayStation Square (bush / prompts)
M.SECONDARY = Enum.KeyCode.ButtonY -- Xbox Y / PlayStation Triangle (backpack, steal)
M.QTE = Enum.KeyCode.ButtonA -- spider dodge (same as accept / confirm)

local FALLBACK_FACE: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonA] = "A",
	[Enum.KeyCode.ButtonB] = "B",
	[Enum.KeyCode.ButtonX] = "X",
	[Enum.KeyCode.ButtonY] = "Y",
}

function M.isPreferred(): boolean
	if UserInputService:GetLastInputType() == Enum.UserInputType.Gamepad1 then
		return true
	end
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and preferred == Enum.PreferredInput.Gamepad then
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
	return UserInputService.LastInputTypeChanged:Connect(function()
		callback(M.isPreferred())
	end)
end

function M.isAcceptHeld(): boolean
	local ok, held = pcall(function()
		return UserInputService:IsGamepadButtonPressed(Enum.UserInputType.Gamepad1, M.ACCEPT)
	end)
	return ok and held == true
end

function M.mountHint(host: GuiObject, keyCode: Enum.KeyCode)
	local hint = host:FindFirstChild("GamepadHotkey")
	if not (hint and hint:IsA("ImageLabel")) then
		local label = Instance.new("ImageLabel")
		label.Name = "GamepadHotkey"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(1, 1)
		label.Position = UDim2.new(1, 2, 1, 2)
		label.Size = UDim2.fromOffset(22, 22)
		label.ZIndex = math.max(host.ZIndex + 2, 6)
		label.ScaleType = Enum.ScaleType.Fit
		label.Visible = false
		label.Parent = host
		hint = label
	end
	local function refresh()
		local show = M.isPreferred()
		local img = if show then M.faceImage(keyCode) else ""
		hint.Image = img
		hint.Visible = show and img ~= ""
	end
	refresh()
	if host:GetAttribute("_GamepadHotkeyWired") ~= true then
		host:SetAttribute("_GamepadHotkeyWired", true)
		M.onPreferredChanged(function()
			if host.Parent then
				refresh()
			end
		end)
	end
end

return M
