-- [ACTIVE] BrainrotCarryVisual
--[[
	Brainrot world scale: base 0.7× template size, +5% per level after level 1.
--]]

local M = {}

M.BASE_SCALE = 0.7
M.UPGRADE_SCALE_PER_LEVEL = 0.05
M.CARRY_CLEARANCE = 0.04
-- Hard cap so mis-scaled Studio templates cannot dwarf the map.
M.MAX_WORLD_LONGEST_AXIS = 5.5
-- Gap between bush top (or surface) and the brainrot model's lowest point.
M.SPAWN_GAP_ABOVE_SURFACE = 1.15

local function getWorldAabbCorners(model: Model): (Vector3?, Vector3?)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local found = false

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			found = true
			local cf = desc.CFrame
			local h = desc.Size * 0.5
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						minX = math.min(minX, wp.X)
						minY = math.min(minY, wp.Y)
						minZ = math.min(minZ, wp.Z)
						maxX = math.max(maxX, wp.X)
						maxY = math.max(maxY, wp.Y)
						maxZ = math.max(maxZ, wp.Z)
					end
				end
			end
		end
	end

	if not found then
		local ok, cf, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			local half = size * 0.5
			return cf.Position - half, cf.Position + half
		end
		return nil, nil
	end

	return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

function M.getWorldAabb(model: Model): (Vector3?, Vector3?)
	return getWorldAabbCorners(model)
end

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
	return M.BASE_SCALE * (1 + M.UPGRADE_SCALE_PER_LEVEL * (lv - 1))
end

function M.clampWorldSize(model: Model, maxLongest: number?)
	local cap = maxLongest or M.MAX_WORLD_LONGEST_AXIS
	local ok, _, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or typeof(size) ~= "Vector3" then
		return
	end
	local longest = math.max(size.X, size.Y, size.Z)
	if longest <= cap then
		return
	end
	local okScale, current = pcall(function()
		return model:GetScale()
	end)
	if okScale and typeof(current) == "number" then
		pcall(function()
			model:ScaleTo(current * (cap / longest))
		end)
	end
end

function M.applyScaleForLevel(model: Model, level: number?)
	local lv = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1
	pcall(function()
		model:ScaleTo(M.scaleMultiplierForLevel(lv))
	end)
	M.clampWorldSize(model)
end

-- Place model so its world-space bottom sits `gap` studs above `surfaceTopY`.
function M.spawnCFrameAboveSurface(
	model: Model,
	worldX: number,
	surfaceTopY: number,
	worldZ: number,
	gap: number?,
	yaw: number?
): CFrame
	local clearance = gap or M.SPAWN_GAP_ABOVE_SURFACE
	local rotY = yaw or (math.random() * math.pi * 2)

	model:PivotTo(CFrame.new(worldX, surfaceTopY + clearance + 3, worldZ) * CFrame.Angles(0, rotY, 0))

	local bbCF, bbSize = model:GetBoundingBox()
	local bottomY = bbCF.Position.Y - bbSize.Y * 0.5
	local pivot = model:GetPivot()
	local lift = (surfaceTopY + clearance) - bottomY
	return CFrame.new(worldX, pivot.Position.Y + lift, worldZ) * CFrame.Angles(0, rotY, 0)
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
