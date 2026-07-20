-- [ACTIVE] RaritySpawnStyle
--[[
	Self-contained rarity colors + gradients for global rarity spawn UI
	(top notification + map markers + timer labels). Does not depend on the
	game's GameGradients folder, so it renders identically at any graphics level.
]]

local M = {}

export type RaritySpawnTheme = {
	accent: Color3,
	sequence: ColorSequence,
}

local function seq(...: Color3): ColorSequence
	local colors = { ... }
	local keypoints: { ColorSequenceKeypoint } = {}
	local count = #colors
	for i, c in colors do
		local t = if count == 1 then 0 else (i - 1) / (count - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(t, c))
	end
	return ColorSequence.new(keypoints)
end

local THEMES: { [string]: RaritySpawnTheme } = {
	mythic = {
		accent = Color3.fromRGB(255, 120, 40),
		sequence = seq(Color3.fromRGB(255, 196, 92), Color3.fromRGB(255, 96, 32), Color3.fromRGB(196, 40, 24)),
	},
	legendary = {
		accent = Color3.fromRGB(255, 214, 64),
		sequence = seq(Color3.fromRGB(255, 244, 168), Color3.fromRGB(255, 206, 56), Color3.fromRGB(228, 150, 16)),
	},
	["brainrot god"] = {
		accent = Color3.fromRGB(255, 88, 132),
		sequence = seq(Color3.fromRGB(255, 168, 220), Color3.fromRGB(255, 72, 138), Color3.fromRGB(150, 44, 196)),
	},
	secret = {
		accent = Color3.fromRGB(232, 236, 244),
		sequence = seq(Color3.fromRGB(245, 247, 252), Color3.fromRGB(150, 158, 178), Color3.fromRGB(70, 74, 92)),
	},
}

local ALIASES: { [string]: string } = {
	mythical = "mythic",
	godly = "brainrot god",
	god = "brainrot god",
	brainrotgod = "brainrot god",
}

local DEFAULT_THEME: RaritySpawnTheme = {
	accent = Color3.fromRGB(120, 220, 150),
	sequence = seq(Color3.fromRGB(180, 240, 200), Color3.fromRGB(90, 200, 130)),
}

function M.themeFor(rarity: string?): RaritySpawnTheme
	if typeof(rarity) ~= "string" then
		return DEFAULT_THEME
	end
	local key = string.lower(rarity)
	key = ALIASES[key] or key
	return THEMES[key] or DEFAULT_THEME
end

function M.accentColor(rarity: string?): Color3
	return M.themeFor(rarity).accent
end

function M.colorSequence(rarity: string?): ColorSequence
	return M.themeFor(rarity).sequence
end

-- Replaces any existing managed gradient on the label with the rarity gradient.
function M.applyTextGradient(label: TextLabel, rarity: string?): UIGradient
	local existing = label:FindFirstChild("RaritySpawnGradient")
	local grad = if existing and existing:IsA("UIGradient") then existing :: UIGradient else Instance.new("UIGradient")
	grad.Name = "RaritySpawnGradient"
	grad.Color = M.colorSequence(rarity)
	-- Horizontal wash reads cleaner on toast text than a vertical stripe.
	grad.Rotation = 0
	grad.Offset = Vector2.new(0, 0)
	grad.Enabled = true
	grad.Parent = label
	return grad
end

return M
