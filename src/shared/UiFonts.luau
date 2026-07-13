-- [ACTIVE] UiFonts
--[[
	Project font tokens for code-built UI.
	• Press Start 2P (Enum.Font.Arcade) — body copy / labels
	• Montserrat — buttons (close X, actions, inputs)
]]

local TextService = game:GetService("TextService")

local M = {}

-- Legacy enums for TextService measurement (Press Start 2P = Arcade).
M.BODY_LEGACY = Enum.Font.Arcade
M.BUTTON_LEGACY = Enum.Font.GothamBold

M.BODY_FACE = Font.fromEnum(Enum.Font.Arcade)
M.BUTTON_FACE = Font.fromName("Montserrat", Enum.FontWeight.Bold)
M.BUTTON_REGULAR_FACE = Font.fromName("Montserrat", Enum.FontWeight.Regular)
M.INPUT_FACE = Font.fromName("Montserrat", Enum.FontWeight.Medium)

function M.applyBody(textGui: TextLabel | TextButton | TextBox)
	textGui.FontFace = M.BODY_FACE
end

function M.applyButton(textGui: TextLabel | TextButton | TextBox)
	textGui.FontFace = M.BUTTON_FACE
end

function M.applyInput(textBox: TextBox)
	textBox.FontFace = M.INPUT_FACE
end

-- Bold sans for map markers / spawn toasts (not pixel body font).
M.DISPLAY_LEGACY = Enum.Font.GothamBold
M.DISPLAY_FACE = Font.fromEnum(Enum.Font.GothamBold)

function M.applyDisplay(textGui: TextLabel | TextButton)
	textGui.FontFace = M.DISPLAY_FACE
end

function M.applyDisplayLabel(label: TextLabel, textSize: number, minSize: number?)
	M.applyDisplay(label)
	label.TextSize = textSize
	M.ensureTextSizeConstraint(label, textSize, minSize)
end

function M.ensureTextSizeConstraint(label: TextLabel, maxSize: number, minSize: number?)
	local existing = label:FindFirstChildOfClass("UITextSizeConstraint")
	if existing then
		existing.MaxTextSize = maxSize
		if typeof(minSize) == "number" then
			existing.MinTextSize = minSize
		end
		return existing
	end
	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MaxTextSize = maxSize
	bounds.MinTextSize = if typeof(minSize) == "number" then minSize else math.max(6, math.floor(maxSize * 0.65))
	bounds.Parent = label
	return bounds
end

function M.applyBodyLabel(label: TextLabel, textSize: number, minSize: number?)
	M.applyBody(label)
	label.TextSize = textSize
	M.ensureTextSizeConstraint(label, textSize, minSize)
end

function M.applyButtonLabel(label: TextLabel | TextButton, textSize: number?, minSize: number?)
	M.applyButton(label)
	if typeof(textSize) == "number" then
		label.TextSize = textSize
		if label:IsA("TextLabel") then
			M.ensureTextSizeConstraint(label, textSize, minSize)
		end
	end
end

function M.applyButtonTree(root: Instance)
	if root:IsA("TextButton") or root:IsA("TextLabel") then
		M.applyButton(root :: any)
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("TextButton") then
			M.applyButton(desc)
		elseif desc:IsA("TextLabel") then
			local parent = desc.Parent
			if parent and (parent:IsA("TextButton") or parent.Name == "Close") then
				M.applyButton(desc)
			end
		end
	end
end

function M.measureBody(text: string, textSize: number, bounds: Vector2): Vector2
	return TextService:GetTextSize(text, textSize, M.BODY_LEGACY, bounds)
end

return M
