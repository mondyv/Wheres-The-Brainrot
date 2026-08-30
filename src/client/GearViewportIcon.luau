-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
-- ViewportFrames cannot draw ParticleEmitters — we re-host the gear's OWN emitters
-- on a tiny camera-aligned part so their existing VFX can still show in world space.
-- The 3D mesh always stays inside the slot ViewportFrame (never reparented off the icon).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local M = {}

local VF_NAME = "GearViewport"
local PROXY_FOLDER_NAME = "GearIconFxProxies"
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}
local proxyConns: { [GuiObject]: RBXScriptConnection } = {}
local proxyParts: { [GuiObject]: BasePart } = {}

-- Published clients (including mobile) always get the real gear mesh + VFX.
-- Studio skips spin / world-space particle proxies to keep play-solo RAM down.
local function isStudioPreview(): boolean
	return RunService:IsStudio()
end

local function stripSimulatedFx(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			d:Clear()
		elseif d:IsA("Beam") or d:IsA("Trail") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
			(d :: any).Enabled = false
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			(d :: Light).Enabled = false
		end
	end
end

local function scaleNumberSequence(seq: NumberSequence, mult: number): NumberSequence
	local keys = seq.Keypoints
	local out = table.create(#keys)
	for i, kp in keys do
		out[i] = NumberSequenceKeypoint.new(kp.Time, math.max(kp.Value * mult, 0.02), kp.Envelope * mult)
	end
	return NumberSequence.new(out)
end

local function looksLikeFxPart(part: BasePart): boolean
	local n = string.lower(part.Name)
	return string.find(n, "vfx", 1, true) ~= nil
		or string.find(n, "fx", 1, true) ~= nil
		or string.find(n, "emitter", 1, true) ~= nil
		or string.find(n, "particle", 1, true) ~= nil
		or string.find(n, "hitbox", 1, true) ~= nil
end

-- Transparent VFX-only meshes render as empty/black in a ViewportFrame.
local function revealHiddenMeshes(root: Instance)
	local parts: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local visible = 0
	for _, p in parts do
		if p.Transparency < 0.85 and not looksLikeFxPart(p) then
			visible += 1
		end
	end
	if visible > 0 then
		return
	end
	local model = if root:IsA("Model") then root :: Model else root:FindFirstAncestorOfClass("Model")
	local primary = model and model.PrimaryPart
	for _, p in parts do
		if p.Name == "Handle" or p == primary then
			continue
		end
		if p.Transparency >= 0.85 then
			p.Transparency = 0.2
			if p.Material == Enum.Material.ForceField or p.Material == Enum.Material.Glass then
				p.Material = Enum.Material.Neon
			end
		end
	end
end

local function iconPartList(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.9 and not looksLikeFxPart(d) then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
	end
	return parts
end

local function boundsFromParts(parts: { BasePart }): (Vector3, Vector3)
	if #parts == 0 then
		return Vector3.zero, Vector3.zero
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in parts do
		local cf = p.CFrame
		local half = p.Size * 0.5
		for _, corner in {
			Vector3.new(-1, -1, -1),
			Vector3.new(-1, -1, 1),
			Vector3.new(-1, 1, -1),
			Vector3.new(-1, 1, 1),
			Vector3.new(1, -1, -1),
			Vector3.new(1, -1, 1),
			Vector3.new(1, 1, -1),
			Vector3.new(1, 1, 1),
		} do
			local w = cf:PointToWorldSpace(half * corner)
			minV = Vector3.new(math.min(minV.X, w.X), math.min(minV.Y, w.Y), math.min(minV.Z, w.Z))
			maxV = Vector3.new(math.max(maxV.X, w.X), math.max(maxV.Y, w.Y), math.max(maxV.Z, w.Z))
		end
	end
	return (minV + maxV) * 0.5, maxV - minV
end

-- Enable / reparent the gear's authored FX only (no synthetic particles).
local function enableAuthoredFx(root: Instance)
	if isStudioPreview() then
		stripSimulatedFx(root)
		return
	end
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
		elseif d:IsA("Trail") then
			d.Enabled = true
		elseif d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
			local fx = d :: any
			fx.Enabled = true
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			(d :: Light).Enabled = true
		end
	end
end

local function clearFxProxy(host: GuiObject)
	local conn = proxyConns[host]
	if conn then
		conn:Disconnect()
		proxyConns[host] = nil
	end
	local part = proxyParts[host]
	if part then
		part:Destroy()
		proxyParts[host] = nil
	end
end

-- Clone the gear's own ParticleEmitters into world space (VF can't draw them).
local function mountFxProxy(host: GuiObject, sourceModel: Model)
	if isStudioPreview() then
		return
	end
	clearFxProxy(host)

	local emitters: { ParticleEmitter } = {}
	for _, d in sourceModel:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(emitters, d)
		end
	end
	if #emitters == 0 then
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	local folder = cam:FindFirstChild(PROXY_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = PROXY_FOLDER_NAME
		folder.Parent = cam
	end

	local part = Instance.new("Part")
	part.Name = "GearFxProxy"
	part.Transparency = 1
	part.Size = Vector3.new(0.15, 0.15, 0.15)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Parent = folder
	proxyParts[host] = part

	local SIZE_MULT = 0.12
	for _, src in emitters do
		local e = src:Clone()
		e.LockedToPart = true
		e.Enabled = true
		e.ZOffset = math.max(e.ZOffset, 3)
		if typeof(e.Size) == "NumberSequence" then
			e.Size = scaleNumberSequence(e.Size, SIZE_MULT)
		end
		if e.Rate <= 0 then
			e.Rate = 8
		end
		e.Parent = part
		src.Enabled = false
		pcall(function()
			e:Emit(4)
		end)
	end

	local function setProxyEmittersEnabled(on: boolean)
		for _, ch in part:GetChildren() do
			if ch:IsA("ParticleEmitter") then
				ch.Enabled = on
				if not on then
					ch:Clear()
				end
			end
		end
	end

	proxyConns[host] = RunService.RenderStepped:Connect(function()
		if not host.Parent or not part.Parent then
			clearFxProxy(host)
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local vis = host.Visible and host.AbsoluteSize.X >= 2 and host.AbsoluteSize.Y >= 2
		if vis then
			local p: Instance? = host.Parent
			while p do
				if p:IsA("GuiObject") and not (p :: GuiObject).Visible then
					vis = false
					break
				end
				if p:IsA("LayerCollector") then
					if p:IsA("ScreenGui") and not (p :: ScreenGui).Enabled then
						vis = false
					end
					break
				end
				p = p.Parent
			end
		end
		if not vis then
			setProxyEmittersEnabled(false)
			part.CFrame = CFrame.new(0, -1e6, 0)
			return
		end

		setProxyEmittersEnabled(true)
		local center = host.AbsolutePosition + host.AbsoluteSize * 0.5
		local ray = camera:ViewportPointToRay(center.X, center.Y)
		local depth = 2.4
		local pos = ray.Origin + ray.Direction.Unit * depth
		part.CFrame = CFrame.lookAt(pos, pos + camera.CFrame.LookVector, camera.CFrame.UpVector)
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
	if host:IsA("GuiObject") then
		clearFxProxy(host)
	end
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
	vf.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
	vf.BorderSizePixel = 0
	vf.Size = if opts and opts.size then opts.size else UDim2.fromScale(1, 1)
	vf.Position = UDim2.fromScale(0.5, 0.5)
	vf.AnchorPoint = Vector2.new(0.5, 0.5)
	vf.ZIndex = host.ZIndex + 1
	vf.Ambient = Color3.fromRGB(230, 235, 255)
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Vector3.new(-0.45, -0.85, -0.55)
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
	clone.Parent = world
	enableAuthoredFx(clone)
	revealHiddenMeshes(clone)

	local parts = iconPartList(clone)
	local center, size = boundsFromParts(parts)
	if size.Magnitude < 0.05 then
		local okBb, bb = pcall(function()
			local cf, sz = clone:GetBoundingBox()
			return { cf = cf, size = sz }
		end)
		if okBb and typeof(bb) == "table" and bb.cf and bb.size then
			center = bb.cf.Position
			size = bb.size
		else
			center = Vector3.zero
			size = Vector3.new(2, 2, 2)
		end
	end
	clone:PivotTo(clone:GetPivot() - center)

	-- Longest axis → world X so dumbbells aren't camera-end-on.
	parts = iconPartList(clone)
	center, size = boundsFromParts(parts)
	if size.Z >= size.X and size.Z >= size.Y then
		clone:PivotTo(CFrame.Angles(0, math.rad(90), 0) * clone:GetPivot())
	elseif size.Y >= size.X and size.Y >= size.Z then
		clone:PivotTo(CFrame.Angles(0, 0, math.rad(-90)) * clone:GetPivot())
	end
	parts = iconPartList(clone)
	center, size = boundsFromParts(parts)
	clone:PivotTo(clone:GetPivot() - center)

	local maxDim = math.max(size.X, size.Y, size.Z, 0.15)
	local homePivot = clone:GetPivot()

	if not isStudioPreview() then
		local fillLight = Instance.new("PointLight")
		fillLight.Name = "ViewportFillLight"
		fillLight.Brightness = 4
		fillLight.Range = math.max(14, maxDim * 5)
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
	end

	local cam = Instance.new("Camera")
	cam.FieldOfView = 28
	cam.Parent = vf
	vf.CurrentCamera = cam

	local distance = maxDim * 2.15
	local shouldRotate = (not isStudioPreview()) and not (opts and opts.rotate == false)
	-- Hotbar: frozen 3/4 view. Shop: same pose as the spin start.
	local yaw = math.rad(48)

	local function updateCam()
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-18), 0, math.rad(-8))
		local camPos = rot:VectorToWorldSpace(Vector3.new(0, maxDim * 0.08, distance))
		cam.CFrame = CFrame.new(camPos, Vector3.zero)
		clone:PivotTo(CFrame.Angles(0, yaw * 0.15, 0) * homePivot)
	end
	updateCam()

	if not isStudioPreview() then
		mountFxProxy(host, clone)
	end

	if gearId == 6 and not isStudioPreview() then
		GearRainbowFX.attach(clone)
	end

	if shouldRotate then
		spinConns[vf] = RunService.RenderStepped:Connect(function(dt)
			if not vf.Parent then
				stopSpin(vf)
				return
			end
			yaw += dt * 1.05
			updateCam()
		end)
	end

	vf.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stopSpin(vf)
			GearRainbowFX.detach(clone)
			clearFxProxy(host)
		end
	end)

	return vf
end

return M
