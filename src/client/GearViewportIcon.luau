-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local M = {}

local VF_NAME = "GearViewport"
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}

local function getPrimary(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local primary = model:FindFirstChild("Primary", true)
	if primary and primary:IsA("BasePart") then
		return primary
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function enableVfx(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = true
			-- Viewport previews need a stronger rate or they look empty.
			if d.Rate < 8 then
				d.Rate = 14
			end
			if d.Lifetime < 1.2 then
				d.Lifetime = 1.35
			end
		elseif d:IsA("Beam") or d:IsA("Trail") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
			(d :: any).Enabled = true
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			(d :: Light).Enabled = true
			(d :: Light).Brightness = math.max((d :: Light).Brightness, 1.25)
		end
	end
end

local function makeFallbackModel(gearId: number): Model
	local def = GearConfig.get(gearId)
	local model = Instance.new("Model")
	model.Name = if def then def.name else ("Gear " .. tostring(gearId))
	local bar = Instance.new("Part")
	bar.Name = "Primary"
	bar.Size = Vector3.new(0.35, 0.35, 2.4)
	bar.Color = Color3.fromRGB(90 + gearId * 8, 90, 140)
	bar.Material = Enum.Material.SmoothPlastic
	bar.Anchored = true
	bar.CanCollide = false
	bar.Parent = model
	local left = Instance.new("Part")
	left.Size = Vector3.new(0.9, 0.9, 0.5)
	left.Color = bar.Color
	left.Material = Enum.Material.SmoothPlastic
	left.Anchored = true
	left.CanCollide = false
	left.CFrame = bar.CFrame * CFrame.new(0, 0, -1.2)
	left.Parent = model
	local right = left:Clone()
	right.CFrame = bar.CFrame * CFrame.new(0, 0, 1.2)
	right.Parent = model
	model.PrimaryPart = bar
	return model
end

local function stopSpin(vf: ViewportFrame)
	local conn = spinConns[vf]
	if conn then
		conn:Disconnect()
		spinConns[vf] = nil
	end
end

function M.clear(host: Instance)
	local existing = host:FindFirstChild(VF_NAME)
	if existing then
		if existing:IsA("ViewportFrame") then
			stopSpin(existing)
			local world = existing:FindFirstChildOfClass("WorldModel")
			if world then
				for _, child in world:GetChildren() do
					GearRainbowFX.detach(child)
				end
			end
		end
		existing:Destroy()
	end
end

function M.mount(host: GuiObject, gearId: number, opts: { rotate: boolean?, size: UDim2? }?): ViewportFrame?
	local existing = host:FindFirstChild(VF_NAME)
	if existing and existing:IsA("ViewportFrame") and existing:GetAttribute("GearId") == gearId then
		return existing
	end

	local clone = GearConfig.cloneGearModel(gearId)
	if not clone then
		clone = makeFallbackModel(gearId)
	end

	M.clear(host)

	for _, d in host:GetChildren() do
		if d:IsA("ImageLabel") and (d.Name == "Icon" or d.Name == "icon") then
			d.Visible = false
		end
	end

	local vf = Instance.new("ViewportFrame")
	vf.Name = VF_NAME
	vf.BackgroundTransparency = 1
	vf.BorderSizePixel = 0
	vf.Size = if opts and opts.size then opts.size else UDim2.fromScale(1, 1)
	vf.Position = UDim2.fromScale(0.5, 0.5)
	vf.AnchorPoint = Vector2.new(0.5, 0.5)
	vf.ZIndex = host.ZIndex + 1
	vf.Ambient = Color3.fromRGB(200, 205, 220)
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Vector3.new(-0.35, -1, -0.4)
	vf:SetAttribute("GearId", gearId)
	vf.Parent = host

	local world = Instance.new("WorldModel")
	world.Parent = vf

	for _, d in clone:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.Massless = true
			d.CastShadow = false
		end
	end
	enableVfx(clone)
	clone.Parent = world

	local primary = getPrimary(clone)
	if primary then
		clone.PrimaryPart = primary
	end

	local okExtents, extents = pcall(function()
		return clone:GetExtentsSize()
	end)
	local size = if okExtents then extents else Vector3.new(2, 2, 2)
	local maxDim = math.max(size.X, size.Y, size.Z, 0.1)
	local cam = Instance.new("Camera")
	cam.FieldOfView = 35
	cam.Parent = vf
	vf.CurrentCamera = cam

	local pivot = if primary then primary.CFrame else clone:GetPivot()
	local distance = maxDim * 1.65
	local yaw = 0

	local function updateCam()
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-18), 0, 0)
		local lookAt = pivot.Position
		cam.CFrame = CFrame.new(lookAt + rot:VectorToWorldSpace(Vector3.new(0, maxDim * 0.12, distance)), lookAt)
		if clone.PrimaryPart then
			clone:PivotTo(CFrame.new(lookAt) * CFrame.Angles(0, yaw * 0.35, 0))
		end
	end
	updateCam()

	if gearId == 6 then
		GearRainbowFX.attach(clone)
	end

	local shouldRotate = not (opts and opts.rotate == false)
	if shouldRotate then
		spinConns[vf] = RunService.RenderStepped:Connect(function(dt)
			if not vf.Parent then
				stopSpin(vf)
				return
			end
			yaw += dt * 1.15
			updateCam()
		end)
	end

	vf.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stopSpin(vf)
			GearRainbowFX.detach(clone)
		end
	end)

	return vf
end

return M
