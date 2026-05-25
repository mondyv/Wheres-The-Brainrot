--[[
	Brainrot world scale: base 0.7× template size, +0.03× per level (stand upgrade / inventory level).
--]]

local M = {}

M.BASE_SCALE = 0.7
M.UPGRADE_SCALE_STEP = 0.03

function M.scaleMultiplierForLevel(level: number): number
	local lv = math.max(1, math.floor(level))
	return M.BASE_SCALE + (lv - 1) * M.UPGRADE_SCALE_STEP
end

function M.applyScaleForLevel(model: Model, level: number?)
	local lv = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1
	pcall(function()
		model:ScaleTo(M.scaleMultiplierForLevel(lv))
	end)
end

function M.applyNonColliding(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
		end
	end
end

return M
