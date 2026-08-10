-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local M = {}

local VF_NAME = "GearViewport"
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}

local function enableVfx(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = true
			d.LockedToPart = false
			-- ViewportFrames often need a stronger burst or they look empty.
			local rate = d.Rate
			if typeof(rate) == "number" then
				d.Rate = math.max(rate, 18)
			end
			local life = d.Lifetime
			if typeof(life) == "NumberRange" and life.Min < 1.1 then
				d.Lifetime = NumberRange.new(1.2, 1.8)
			end
			if d.Drag > 2 then
				d.Drag = 1
			end
			-- Kick a visible burst immediately.
			pcall(function()
				d:Emit(math.clamp(math.floor(d.Rate * 0.35), 4, 24))
			end)
		elseif d:IsA("Beam") then
			d.Enabled = true
			d.Width0 = math.max(d.Width0, 0.12)
			d.Width1 = math.max(d.Width1, 0.12)
		elseif d:IsA("Trail") then
			d.Enabled = true
			d.Lifetime = math.max(d.Lifetime, 0.35)
		elseif d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
			(d :: any).Enabled = true
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			(d :: Light).Enabled = true
			(d :: Light).Brightness = math.max((d :: Light).Brightness, 2)
			(d :: Light).Range = math.max((d :: Light).Range, 8)
		end
	end
end

local function burstVfx(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") and d.Enabled then
			pcall(function()
				d:Emit(math.clamp(math.floor(d.Rate * 0.3), 3, 18))
			end)
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
	vf.Ambient = Color3.fromRGB(210, 215, 230)
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Vector3.new(-0.3, -1, -0.45)
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

	-- Frame the full bounding box (Primary can sit at the bottom and crop the rest).
	local okBb, bb = pcall(function()
		local cf, size = clone:GetBoundingBox()
		return { cf = cf, size = size }
	end)
	local size = Vector3.new(2, 2, 2)
	if okBb and typeof(bb) == "table" and bb.cf and bb.size then
		clone:PivotTo(clone:GetPivot() - bb.cf.Position)
		size = bb.size
	end
	local maxDim = math.max(size.X, size.Y, size.Z, 0.15)
	local homePivot = clone:GetPivot()

	-- Extra fill light so particles/beams read in the tiny shop icons.
	local fillLight = Instance.new("PointLight")
	fillLight.Name = "ViewportFillLight"
	fillLight.Brightness = 2.5
	fillLight.Range = math.max(10, maxDim * 4)
	fillLight.Color = Color3.fromRGB(255, 250, 240)
	local lightPart = Instance.new("Part")
	lightPart.Name = "ViewportLightAnchor"
	lightPart.Anchored = true
	lightPart.CanCollide = false
	lightPart.CanQuery = false
	lightPart.CanTouch = false
	lightPart.Transparency = 1
	lightPart.Size = Vector3.new(0.2, 0.2, 0.2)
	lightPart.CFrame = CFrame.new(0, maxDim * 0.35, maxDim * 0.4)
	fillLight.Parent = lightPart
	lightPart.Parent = world

	local cam = Instance.new("Camera")
	cam.FieldOfView = 32
	cam.Parent = vf
	vf.CurrentCamera = cam

	local distance = maxDim * 1.95
	local yaw = 0
	local emitAcc = 0.0

	local function updateCam()
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-16), 0, 0)
		local camPos = rot:VectorToWorldSpace(Vector3.new(0, maxDim * 0.06, distance))
		cam.CFrame = CFrame.new(camPos, Vector3.zero)
		-- Spin model around bounding-box center (world origin after centering).
		clone:PivotTo(CFrame.Angles(0, yaw * 0.4, 0) * homePivot)
	end
	updateCam()
	burstVfx(clone)

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
			yaw += dt * 1.05
			updateCam()
			emitAcc += dt
			if emitAcc >= 0.4 then
				emitAcc = 0
				burstVfx(clone)
			end
		end)
	else
		-- Still pulse VFX for static hotbar icons.
		spinConns[vf] = RunService.RenderStepped:Connect(function(dt)
			if not vf.Parent then
				stopSpin(vf)
				return
			end
			emitAcc += dt
			if emitAcc >= 0.45 then
				emitAcc = 0
				burstVfx(clone)
			end
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
