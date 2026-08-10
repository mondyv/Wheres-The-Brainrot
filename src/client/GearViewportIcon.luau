-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
-- NOTE: ParticleEmitters do NOT render inside ViewportFrames — use neon spark parts + UI overlay.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GearConfig = require(Shared:WaitForChild("GearConfig"))
local BrainrotHeaderStyle = require(Shared:WaitForChild("BrainrotHeaderStyle"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local M = {}

local VF_NAME = "GearViewport"
local UI_VFX_NAME = "GearUiVfx"
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}
local uiVfxConns: { [GuiObject]: RBXScriptConnection } = {}

local function accentForGear(gearId: number): Color3
	local def = GearConfig.get(gearId)
	local rarity = if def then def.rarity else "common"
	local ok, color = pcall(function()
		return BrainrotHeaderStyle.rarityAccentColor(rarity)
	end)
	if ok and typeof(color) == "Color3" then
		return color
	end
	return Color3.fromRGB(255, 220, 120)
end

local function enablePartFx(root: Instance)
	-- Lights/beams/trails sometimes help; ParticleEmitters are kept enabled but won't draw in VF.
	local primary = if root:IsA("Model") then root.PrimaryPart else nil
	if not primary and root:IsA("Model") then
		primary = root:FindFirstChildWhichIsA("BasePart", true)
	end

	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = true
			d.LockedToPart = true
			if primary and not d:FindFirstAncestorWhichIsA("BasePart") then
				local att = Instance.new("Attachment")
				att.Name = "ViewportVfxAttach"
				att.Parent = primary
				d.Parent = att
			end
		elseif d:IsA("Beam") then
			d.Enabled = true
			d.Width0 = math.max(d.Width0 * 1.8, 0.22)
			d.Width1 = math.max(d.Width1 * 1.8, 0.22)
			d.Brightness = math.max(d.Brightness, 3)
		elseif d:IsA("Trail") then
			d.Enabled = true
			d.Lifetime = math.max(d.Lifetime, 0.5)
		elseif d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
			local fx = d :: any
			fx.Enabled = true
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			local light = d :: Light
			light.Enabled = true
			light.Brightness = math.max(light.Brightness, 4)
			light.Range = math.max(light.Range, 14)
		end
	end
end

-- Neon balls DO render in ViewportFrames — use them as visible "particles".
local function addNeonSparks(clone: Model, maxDim: number, color: Color3, count: number)
	for i = 1, count do
		local p = Instance.new("Part")
		p.Name = "ViewportSpark"
		p.Shape = Enum.PartType.Ball
		local s = maxDim * (0.045 + (i % 3) * 0.018)
		p.Size = Vector3.new(s, s, s)
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p:SetAttribute("SparkAngle", (i / count) * math.pi * 2)
		p:SetAttribute("SparkRadius", maxDim * (0.42 + (i % 4) * 0.07))
		p:SetAttribute("SparkY", maxDim * (0.12 * ((i % 3) - 1)))
		p:SetAttribute("SparkSpin", 1.6 + (i % 5) * 0.35)
		p.Parent = clone
	end
end

local function updateNeonSparks(clone: Model, dt: number, rainbow: boolean)
	for _, d in clone:GetChildren() do
		if d.Name == "ViewportSpark" and d:IsA("BasePart") then
			local a = ((d:GetAttribute("SparkAngle") :: number?) or 0) + dt * ((d:GetAttribute("SparkSpin") :: number?) or 2)
			d:SetAttribute("SparkAngle", a)
			local r = (d:GetAttribute("SparkRadius") :: number?) or 0.5
			local y = (d:GetAttribute("SparkY") :: number?) or 0
			d.CFrame = CFrame.new(math.cos(a) * r, y + math.sin(a * 1.7) * r * 0.12, math.sin(a) * r)
			if rainbow then
				d.Color = Color3.fromHSV((os.clock() * 0.35 + a * 0.08) % 1, 0.85, 1)
			end
		end
	end
end

local function clearUiVfx(host: Instance)
	local conn = uiVfxConns[host :: GuiObject]
	if conn then
		conn:Disconnect()
		uiVfxConns[host :: GuiObject] = nil
	end
	local existing = host:FindFirstChild(UI_VFX_NAME)
	if existing then
		existing:Destroy()
	end
end

-- 2D sparkle rain over the icon (ViewportFrame can't draw ParticleEmitters).
local function mountUiVfx(host: GuiObject, gearId: number, vf: ViewportFrame)
	clearUiVfx(host)
	local accent = accentForGear(gearId)

	local layer = Instance.new("Frame")
	layer.Name = UI_VFX_NAME
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromScale(1, 1)
	layer.Position = UDim2.fromScale(0.5, 0.5)
	layer.AnchorPoint = Vector2.new(0.5, 0.5)
	layer.ClipsDescendants = true
	layer.ZIndex = vf.ZIndex + 1
	layer.Parent = host

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(0.72, 0.72)
	glow.BackgroundColor3 = accent
	glow.BackgroundTransparency = 0.72
	glow.BorderSizePixel = 0
	glow.ZIndex = layer.ZIndex
	glow.Parent = layer
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = glow

	local pulse = Instance.new("UIScale")
	pulse.Scale = 1
	pulse.Parent = glow
	TweenService:Create(
		pulse,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.18 }
	):Play()

	local spawnAcc = 0.0
	uiVfxConns[host] = RunService.RenderStepped:Connect(function(dt)
		if not layer.Parent or not host.Parent then
			clearUiVfx(host)
			return
		end
		spawnAcc += dt
		if spawnAcc < 0.07 then
			return
		end
		spawnAcc = 0

		local spark = Instance.new("ImageLabel")
		spark.Name = "Spark"
		spark.BackgroundTransparency = 1
		spark.Image = "rbxasset://textures/particles/sparkles_main.dds"
		spark.ImageColor3 = if gearId == 6 then Color3.fromHSV(os.clock() % 1, 0.8, 1) else accent
		spark.ImageTransparency = 0.05
		spark.Size = UDim2.fromOffset(10 + math.random(0, 10), 10 + math.random(0, 10))
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Position = UDim2.fromScale(0.15 + math.random() * 0.7, 0.2 + math.random() * 0.55)
		spark.ZIndex = layer.ZIndex + 1
		spark.Parent = layer

		local life = 0.35 + math.random() * 0.25
		local endPos = UDim2.fromScale(
			spark.Position.X.Scale + (math.random() - 0.5) * 0.25,
			spark.Position.Y.Scale - (0.18 + math.random() * 0.22)
		)
		TweenService:Create(
			spark,
			TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Position = endPos,
				ImageTransparency = 1,
				Size = UDim2.fromOffset(4, 4),
				Rotation = math.random(-40, 40),
			}
		):Play()
		task.delay(life + 0.02, function()
			if spark.Parent then
				spark:Destroy()
			end
		end)
	end)
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
	clearUiVfx(host)
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
		if not host:FindFirstChild(UI_VFX_NAME) then
			mountUiVfx(host, gearId, existing)
		end
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
	vf.Ambient = Color3.fromRGB(230, 235, 255)
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Vector3.new(-0.25, -1, -0.4)
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
			if d.Transparency >= 1 then
				d.Transparency = 0.99
			end
		end
	end
	clone.Parent = world
	enablePartFx(clone)

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
	local accent = accentForGear(gearId)
	addNeonSparks(clone, maxDim, accent, if gearId >= 6 then 10 else 7)

	local fillLight = Instance.new("PointLight")
	fillLight.Name = "ViewportFillLight"
	fillLight.Brightness = 5
	fillLight.Range = math.max(16, maxDim * 5)
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
	local rainbow = gearId == 6

	local function updateCam()
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-16), 0, 0)
		local camPos = rot:VectorToWorldSpace(Vector3.new(0, maxDim * 0.06, distance))
		cam.CFrame = CFrame.new(camPos, Vector3.zero)
		clone:PivotTo(CFrame.Angles(0, yaw * 0.4, 0) * homePivot)
	end
	updateCam()
	updateNeonSparks(clone, 0, rainbow)

	if rainbow then
		GearRainbowFX.attach(clone)
	end

	mountUiVfx(host, gearId, vf)

	local shouldRotate = not (opts and opts.rotate == false)
	spinConns[vf] = RunService.RenderStepped:Connect(function(dt)
		if not vf.Parent then
			stopSpin(vf)
			return
		end
		if shouldRotate then
			yaw += dt * 1.05
			updateCam()
		end
		updateNeonSparks(clone, dt, rainbow)
	end)

	vf.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stopSpin(vf)
			GearRainbowFX.detach(clone)
			clearUiVfx(host)
		end
	end)

	return vf
end

return M
