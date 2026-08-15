-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
-- ViewportFrames cannot draw ParticleEmitters — we re-host the gear's OWN emitters
-- on a tiny camera-aligned part so their existing VFX can show over the icon.
-- Shop icons: ViewportFrame lives on a ScreenGui in front of Main, and the row
-- card is inset so world particles show through the icon hole (not behind the panel).
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)

local M = {}

local VF_NAME = "GearViewport"
local PROXY_FOLDER_NAME = "GearIconFxProxies"
local SHOP_BB_ORDER = 80 -- Main modal DisplayOrder is 50
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}
local proxyConns: { [GuiObject]: RBXScriptConnection } = {}
local proxyParts: { [GuiObject]: BasePart } = {}
local shopOverlays: { [GuiObject]: ScreenGui } = {}
local shopViewports: { [GuiObject]: ViewportFrame } = {}
local shopOverlayGui: ScreenGui? = nil

local function scaleNumberSequence(seq: NumberSequence, mult: number): NumberSequence
	local keys = seq.Keypoints
	local out = table.create(#keys)
	for i, kp in keys do
		out[i] = NumberSequenceKeypoint.new(kp.Time, math.max(kp.Value * mult, 0.02), kp.Envelope * mult)
	end
	return NumberSequence.new(out)
end

-- Enable / reparent the gear's authored FX only (no synthetic particles).
local function enableAuthoredFx(root: Instance)
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

local function isUpgradesHost(host: GuiObject): boolean
	local p: Instance? = host
	while p do
		if p.Name == "Upgrades" then
			return true
		end
		p = p.Parent
	end
	return false
end

local function punchShopIconHole(host: GuiObject)
	if host:GetAttribute("IconFxHolePunched") == true then
		return
	end
	local w = host.AbsoluteSize.X
	if w < 8 then
		return
	end
	host:SetAttribute("IconFxHolePunched", true)
	host.BackgroundTransparency = 1
	host.ClipsDescendants = false
	local row = host.Parent
	if not (row and row:IsA("GuiObject")) then
		return
	end
	row.ClipsDescendants = false
	local container = row.Parent
	if container and container:IsA("GuiObject") then
		container.ClipsDescendants = false
	end
	-- Full-bleed card chrome would cover world particles; start it after the icon.
	for _, child in row:GetChildren() do
		if child == host or not child:IsA("GuiObject") then
			continue
		end
		local n = child.Name
		if n ~= "Decor" and n ~= "BG" and n ~= "Highlight" and n ~= "Shadow" then
			continue
		end
		if child.Size.X.Scale < 0.9 then
			continue
		end
		if child:GetAttribute("IconFxHoleInset") == true then
			continue
		end
		child:SetAttribute("IconFxHoleInset", true)
		child.Position = UDim2.new(0, w, child.Position.Y.Scale, child.Position.Y.Offset)
		child.Size = UDim2.new(1, -w, child.Size.Y.Scale, child.Size.Y.Offset)
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
	shopOverlays[host] = nil
	shopViewports[host] = nil
end

local function ensureShopOverlayGui(): ScreenGui?
	if shopOverlayGui and shopOverlayGui.Parent then
		return shopOverlayGui
	end
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	-- Destroy leftover BillboardGui from older builds (DisplayOrder is invalid on it).
	local stale = pg:FindFirstChild("GearShopIconOverlay")
	if stale and not stale:IsA("ScreenGui") then
		stale:Destroy()
	end
	local existing = pg:FindFirstChild("GearShopIconOverlay")
	if existing and existing:IsA("ScreenGui") then
		shopOverlayGui = existing
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "GearShopIconOverlay"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.DisplayOrder = SHOP_BB_ORDER
	sg.Parent = pg
	shopOverlayGui = sg
	return sg
end

local function syncShopViewport(host: GuiObject, vf: ViewportFrame)
	local inset = GuiService:GetGuiInset()
	vf.AnchorPoint = Vector2.new(0, 0)
	vf.Position = UDim2.fromOffset(host.AbsolutePosition.X + inset.X, host.AbsolutePosition.Y + inset.Y)
	vf.Size = UDim2.fromOffset(math.max(host.AbsoluteSize.X, 8), math.max(host.AbsoluteSize.Y, 8))
end

local function ensureShopOverlay(host: GuiObject, vf: ViewportFrame): ScreenGui?
	local sg = ensureShopOverlayGui()
	if not sg then
		return nil
	end
	if vf.Parent ~= sg then
		vf.Parent = sg
	end
	syncShopViewport(host, vf)
	shopOverlays[host] = sg
	shopViewports[host] = vf
	return sg
end

-- Clone the gear's own ParticleEmitters into world space (VF can't draw them).
local function mountFxProxy(host: GuiObject, sourceModel: Model, vf: ViewportFrame)
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

	-- Shrink authored emitters so they read at icon scale (same textures/colors/settings).
	local SIZE_MULT = 0.12
	for _, src in emitters do
		local e = src:Clone()
		e.LockedToPart = true
		e.Enabled = true
		e.ZOffset = math.max(e.ZOffset, 3)
		if typeof(e.Size) == "NumberSequence" then
			e.Size = scaleNumberSequence(e.Size, SIZE_MULT)
		end
		-- Keep a gentle trickle even if the asset is burst-only.
		if e.Rate <= 0 then
			e.Rate = 8
		end
		e.Parent = part
		-- Mute the VF copy — it can't draw anyway, avoids double work.
		src.Enabled = false
		pcall(function()
			e:Emit(4)
		end)
	end

	if isUpgradesHost(host) then
		ensureShopOverlay(host, vf)
	end

	local shop = isUpgradesHost(host)
	proxyConns[host] = RunService.RenderStepped:Connect(function()
		if not host.Parent or not part.Parent then
			clearFxProxy(host)
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local overlayVf = shopViewports[host]
		if not host.Visible or host.AbsoluteSize.X < 2 or host.AbsoluteSize.Y < 2 then
			part.CFrame = CFrame.new(0, -1e6, 0)
			if overlayVf then
				overlayVf.Visible = false
			end
			return
		end
		-- Hide when ancestor ScreenGui/frame is invisible.
		local vis = true
		local p: Instance? = host
		while p do
			if p:IsA("GuiObject") and not (p :: GuiObject).Visible then
				vis = false
				break
			end
			if p:IsA("LayerCollector") then
				break
			end
			p = p.Parent
		end
		if not vis then
			part.CFrame = CFrame.new(0, -1e6, 0)
			if overlayVf then
				overlayVf.Visible = false
			end
			return
		end

		if shop then
			punchShopIconHole(host)
		end

		local center = host.AbsolutePosition + host.AbsoluteSize * 0.5
		local ray = camera:ViewportPointToRay(center.X, center.Y)
		-- Depth tuned so particles sit over the icon, not the world.
		local depth = 2.4
		local pos = ray.Origin + ray.Direction.Unit * depth
		part.CFrame = CFrame.lookAt(pos, pos + camera.CFrame.LookVector, camera.CFrame.UpVector)

		if overlayVf then
			overlayVf.Visible = true
			syncShopViewport(host, overlayVf)
		end
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

local function findMountedViewport(host: GuiObject): ViewportFrame?
	local existing = host:FindFirstChild(VF_NAME)
	if existing and existing:IsA("ViewportFrame") then
		return existing
	end
	local overlayVf = shopViewports[host]
	if overlayVf and overlayVf.Parent then
		return overlayVf
	end
	return nil
end

function M.clear(host: Instance)
	local existing: Instance? = nil
	if host:IsA("GuiObject") then
		existing = findMountedViewport(host)
		clearFxProxy(host)
	else
		existing = host:FindFirstChild(VF_NAME)
	end
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
	local existing = findMountedViewport(host)
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
			if d.Transparency >= 1 and d:FindFirstChildWhichIsA("ParticleEmitter", true) then
				d.Transparency = 0.99
			end
		end
	end
	clone.Parent = world
	enableAuthoredFx(clone)

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

	local cam = Instance.new("Camera")
	cam.FieldOfView = 32
	cam.Parent = vf
	vf.CurrentCamera = cam

	local distance = maxDim * 1.95
	local yaw = 0

	local function updateCam()
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-16), 0, 0)
		local camPos = rot:VectorToWorldSpace(Vector3.new(0, maxDim * 0.06, distance))
		cam.CFrame = CFrame.new(camPos, Vector3.zero)
		clone:PivotTo(CFrame.Angles(0, yaw * 0.4, 0) * homePivot)
	end
	updateCam()

	-- Re-host authored particle emitters so they can actually render over the icon.
	mountFxProxy(host, clone, vf)

	if gearId == 6 then
		GearRainbowFX.attach(clone)
	end

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
	end)

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
