--[[
	Brainrot world scale: base 0.7× template size, +0.01× per level (stand upgrade / inventory level).
--]]

local M = {}

M.BASE_SCALE = 0.7
M.UPGRADE_SCALE_STEP = 0.01
M.CARRY_CLEARANCE = 0.04

local function stackContributionY(model: Model): number
	if not model.Parent then
		return 1.0
	end
	local _, bbSize = model:GetBoundingBox()
	local pp = model.PrimaryPart
	if pp then
		local tight = pp.Size.Y * 1.0 + 0.04
		return math.clamp(math.min(bbSize.Y, tight), 0.45, 3.8)
	end
	return math.clamp(bbSize.Y, 0.45, 3.8)
end

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

-- stackLiftY: extra vertical offset when stacking multiple bush carries on the head.
function M.getHeadCarryWorldCFrame(character: Model, mainPart: BasePart, stackLiftY: number): (BasePart?, CFrame?)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character:FindFirstChild("Head") :: BasePart?
	local anchor: BasePart? = head or hrp
	if not anchor then
		return nil, nil
	end

	local charCF, charSize = character:GetBoundingBox()
	local topY = charCF.Position.Y + charSize.Y * 0.5

	local brHalfY = 0.5
	local parent = mainPart.Parent
	if parent and parent:IsA("Model") then
		brHalfY = stackContributionY(parent) * 0.5
	elseif parent and parent:IsA("Tool") then
		for _, d in parent:GetDescendants() do
			if d:IsA("BasePart") then
				brHalfY = math.max(brHalfY, d.Size.Y * 0.5)
			end
		end
		brHalfY = math.clamp(brHalfY, 0.35, 2.5)
	end
	local centerY = topY + M.CARRY_CLEARANCE + brHalfY + stackLiftY

	local face = Vector3.new(0, 0, -1)
	if hrp then
		local flat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		if flat.Magnitude > 0.08 then
			face = flat.Unit
		end
	end

	local center = Vector3.new(charCF.Position.X, centerY, charCF.Position.Z)
	local desired = CFrame.lookAt(center, center + face, Vector3.yAxis)
	return anchor, desired
end

return M
