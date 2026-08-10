-- [ACTIVE] GearViewportIcon
-- Rotating ViewportFrame previews of EssentialAssets.Gears for shop + hotbar.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))

local M = {}

local VF_NAME = "GearViewport"
local gearsFolder: Folder? = nil
local spinConns: { [ViewportFrame]: RBXScriptConnection } = {}

local function getGearsFolder(): Folder?
	if gearsFolder and gearsFolder.Parent then
		return gearsFolder
	end
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local folder = assets and assets:FindFirstChild("Gears")
	if folder and folder:IsA("Folder") then
		gearsFolder = folder
		return folder
	end
	return nil
end

local function getTemplate(gearId: number): Model?
	local def = GearConfig.get(gearId)
	if not def then
		return nil
	end
	local folder = getGearsFolder()
	if not folder then
		return nil
	end
	local inst = folder:FindFirstChild(def.assetName)
	if inst and inst:IsA("Model") then
		return inst
	end
	return nil
end

local function getPrimary(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local primary = model:FindFirstChild("Primary")
	if primary and primary:IsA("BasePart") then
		return primary
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
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
		end
		existing:Destroy()
	end
end

function M.mount(host: GuiObject, gearId: number, opts: { rotate: boolean?, size: UDim2? }?): ViewportFrame?
	local existing = host:FindFirstChild(VF_NAME)
	if existing and existing:IsA("ViewportFrame") and existing:GetAttribute("GearId") == gearId then
		return existing
	end

	local template = getTemplate(gearId)
	if not template then
		return nil
	end

	M.clear(host)

	-- Hide static ImageLabel icons under the same host so the viewport shows through.
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
	vf.Ambient = Color3.fromRGB(200, 200, 210)
	vf.LightColor = Color3.fromRGB(255, 255, 255)
	vf.LightDirection = Vector3.new(-0.4, -1, -0.35)
	vf:SetAttribute("GearId", gearId)
	vf.Parent = host

	local world = Instance.new("WorldModel")
	world.Parent = vf

	local clone = template:Clone()
	for _, d in clone:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.Massless = true
		end
	end
	clone.Parent = world

	local primary = getPrimary(clone)
	if primary then
		clone.PrimaryPart = primary
	end

	local extents = clone:GetExtentsSize()
	local maxDim = math.max(extents.X, extents.Y, extents.Z, 0.1)
	local cam = Instance.new("Camera")
	cam.FieldOfView = 35
	cam.Parent = vf
	vf.CurrentCamera = cam

	local pivot = if primary then primary.CFrame else clone:GetPivot()
	local distance = maxDim * 1.55
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
		end
	end)

	return vf
end

return M
