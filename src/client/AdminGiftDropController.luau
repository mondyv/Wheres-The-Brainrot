-- [ACTIVE] AdminGiftDropController
--[[
	When an admin (or reward poll) grants an item, drop it from the sky in
	front of the local player — land smash, stones, then inventory toast.
]]

local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AdminGiftConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AdminGiftConfig"))
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local CharacterWorldNotif = require(script.Parent.CharacterWorldNotif)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local DROP_SEC = 0.92
local IMPACT_SEC = 0.26
local HOLD_SEC = 0.18
local SUCK_SEC = 0.46
local FALL_HEIGHT = 28
local FORWARD = 7

local AdminGiftDropController = {}

local dropConn: RBXScriptConnection? = nil
local shakeConn: RBXScriptConnection? = nil
local dropToken = 0
local liveModel: Model? = nil
local initialized = false

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild(AdminGiftConfig.DROP_REMOTE)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function disconnectDrop()
	if dropConn then
		dropConn:Disconnect()
		dropConn = nil
	end
	if shakeConn then
		shakeConn:Disconnect()
		shakeConn = nil
	end
end

local function destroyLive()
	if liveModel then
		liveModel:Destroy()
		liveModel = nil
	end
end

local function freezeModel(model: Model)
	local remove: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = false
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			table.insert(remove, d)
		end
	end
	for _, d in remove do
		d:Destroy()
	end
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
end

local function fitDropModel(model: Model, maxStuds: number)
	if not model.PrimaryPart then
		return
	end
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" then
		model:PivotTo(cf)
		model.WorldPivot = cf
	end
	local extents = if ok and typeof(size) == "Vector3" then size else model:GetExtentsSize()
	local longest = math.max(extents.X, extents.Y, extents.Z)
	local cap = math.max(1.2, maxStuds)
	if longest > cap then
		model:ScaleTo(model:GetScale() * (cap / longest))
	end
end

local function cloneLuckyBlock(blockId: string, variant: string?): Model?
	local root = ReplicatedStorage:FindFirstChild("Lucky Blocks")
	local folder = root and root:FindFirstChild("lucky blocks")
	local searchRoot = folder or root
	if not searchRoot then
		return nil
	end
	local node: Instance? = searchRoot:FindFirstChild(blockId)
	if not node then
		for _, d in searchRoot:GetDescendants() do
			if d.Name == blockId then
				node = d
				break
			end
		end
	end
	if not node then
		return nil
	end
	local template: Model? = nil
	if typeof(variant) == "string" and variant ~= "" then
		local exact = node:FindFirstChild(variant)
		if exact and exact:IsA("Model") then
			template = exact
		end
	end
	if not template then
		if node:IsA("Model") then
			template = node:FindFirstChildWhichIsA("Model") or (node :: Model)
		else
			template = node:FindFirstChildWhichIsA("Model", true)
		end
	end
	if not template then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "AdminGiftDrop"
	freezeModel(clone)
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	fitDropModel(clone, 4)
	return clone
end

local function stripDropFx(model: Model)
	local remove: { Instance } = {}
	for _, child in model:GetChildren() do
		local n = string.lower(child.Name)
		local looksFx = string.find(n, "vfx", 1, true)
			or string.find(n, "fx", 1, true)
			or string.find(n, "effect", 1, true)
			or string.find(n, "particle", 1, true)
		if looksFx and child ~= model.PrimaryPart then
			table.insert(remove, child)
		end
	end
	for _, d in remove do
		if d.Parent then
			d:Destroy()
		end
	end
end

local function cloneGear(gearId: number): Model?
	local clone = GearConfig.cloneGearModel(gearId)
	if not clone then
		return nil
	end
	clone.Name = "AdminGiftDrop"
	stripDropFx(clone)
	freezeModel(clone)
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	fitDropModel(clone, 2.35)
	return clone
end

local function resolveDropTemplate(template: any, templateName: any): Model?
	if typeof(template) == "Instance" and template:IsA("Model") then
		return template
	end
	if typeof(templateName) ~= "string" or templateName == "" then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild(AdminGiftConfig.TEMPLATE_FOLDER)
	if not folder then
		folder = ReplicatedStorage:WaitForChild(AdminGiftConfig.TEMPLATE_FOLDER, 2)
	end
	if not folder then
		return nil
	end
	local found = folder:FindFirstChild(templateName)
	if not found then
		found = folder:WaitForChild(templateName, 2)
	end
	if found and found:IsA("Model") then
		return found
	end
	return nil
end

local function takeTemplateModel(template: Instance?): Model?
	if not (template and template:IsA("Model")) then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "AdminGiftDrop"
	freezeModel(clone)
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	fitDropModel(clone, 5.2)
	return clone
end

local function cloneBrainrot(name: string, template: any, templateName: any): Model?
	local fromServer = takeTemplateModel(resolveDropTemplate(template, templateName))
	if fromServer then
		return fromServer
	end
	local folder = ReplicatedStorage:FindFirstChild("Brainrots")
	if not (folder and folder:IsA("Folder")) then
		return nil
	end
	local node = folder:FindFirstChild(name)
		or folder:FindFirstChild(name, true)
	if not node then
		return nil
	end
	local model: Model? = if node:IsA("Model") then node else node:FindFirstChildWhichIsA("Model", true)
	if not model then
		return nil
	end
	local clone = model:Clone()
	clone.Name = "AdminGiftDrop"
	freezeModel(clone)
	if not clone.PrimaryPart then
		clone:Destroy()
		return nil
	end
	fitDropModel(clone, 5.2)
	return clone
end

local function makeFallbackCrate(displayName: string, color: Color3): Model
	local model = Instance.new("Model")
	model.Name = "AdminGiftDrop"
	local box = Instance.new("Part")
	box.Name = "Crate"
	box.Size = Vector3.new(3.2, 3.2, 3.2)
	box.Color = color
	box.Material = Enum.Material.Neon
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Parent = model
	model.PrimaryPart = box
	local bb = Instance.new("BillboardGui")
	bb.Name = "NameTag"
	bb.Size = UDim2.fromOffset(220, 36)
	bb.StudsOffset = Vector3.new(0, 2.4, 0)
	bb.AlwaysOnTop = true
	bb.Parent = box
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = UiFonts.DISPLAY_FACE
	label.Text = displayName
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = bb
	return model
end

local function playImpactFrames(token: number)
	local cam = Workspace.CurrentCamera
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if cam then
		local origFov = cam.FieldOfView
		cam.FieldOfView = origFov + 12
		TweenService:Create(cam, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FieldOfView = origFov - 7,
		}):Play()
		task.delay(0.1, function()
			if token ~= dropToken then
				return
			end
			TweenService:Create(cam, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				FieldOfView = origFov,
			}):Play()
		end)
	end

	local flash = Instance.new("ColorCorrectionEffect")
	flash.Name = "AdminGiftImpact"
	flash.Brightness = 1.55
	flash.Contrast = 0.4
	flash.Saturation = -0.2
	flash.TintColor = Color3.fromRGB(255, 236, 210)
	flash.Parent = Lighting
	TweenService:Create(flash, TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.fromRGB(255, 255, 255),
	}):Play()
	Debris:AddItem(flash, 0.4)

	if not (hum and hum:IsA("Humanoid")) then
		return
	end
	if shakeConn then
		shakeConn:Disconnect()
		shakeConn = nil
	end
	local t0 = os.clock()
	local humanoid = hum
	shakeConn = RunService.RenderStepped:Connect(function()
		if token ~= dropToken or not humanoid.Parent then
			if shakeConn then
				shakeConn:Disconnect()
				shakeConn = nil
			end
			if humanoid.Parent then
				humanoid.CameraOffset = Vector3.zero
			end
			return
		end
		local t = os.clock() - t0
		if t >= IMPACT_SEC then
			humanoid.CameraOffset = Vector3.zero
			if shakeConn then
				shakeConn:Disconnect()
				shakeConn = nil
			end
			return
		end
		local fade = 1 - (t / IMPACT_SEC)
		humanoid.CameraOffset = Vector3.new((math.random() - 0.5) * 1.6 * fade, (math.random() - 0.5) * 1.2 * fade, 0)
	end)
end

local function suckIntoBody(token: number, model: Model, fromCf: CFrame)
	local startScale = model:GetScale()
	local lastScale = startScale
	local t0 = os.clock()
	dropConn = RunService.Heartbeat:Connect(function()
		if token ~= dropToken or liveModel ~= model or not model.Parent then
			disconnectDrop()
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local dest = fromCf.Position
		if hrp and hrp:IsA("BasePart") then
			local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
			if look.Magnitude < 0.05 then
				look = Vector3.new(0, 0, -1)
			else
				look = look.Unit
			end
			dest = hrp.Position + look * 1.15 + Vector3.new(0, 0.35, 0)
		end
		local alpha = math.clamp((os.clock() - t0) / SUCK_SEC, 0, 1)
		local goal = fromCf:Lerp(CFrame.new(dest), alpha) * CFrame.Angles(0, alpha * 1.55, alpha * 0.28)
		model:PivotTo(goal)
		local nextScale = math.max(0.06, startScale * (1 - alpha * 0.92))
		if math.abs(nextScale - lastScale) >= 0.03 or alpha >= 1 then
			model:ScaleTo(nextScale)
			lastScale = nextScale
		end
		if alpha >= 1 then
			disconnectDrop()
			destroyLive()
		end
	end)
end

local function spawnBurstDebris(at: Vector3)
	local ring = Instance.new("Part")
	ring.Name = "AdminGiftBurstRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 210, 80)
	ring.Size = Vector3.new(0.35, 2.4, 2.4)
	ring.CFrame = CFrame.new(at + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, 18, 18),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.55)

	for i = 1, 40 do
		local chip = Instance.new("Part")
		chip.Name = "AdminGiftStone"
		local scale = 0.5 + math.random() * 1.2
		chip.Size = Vector3.new(0.7, 0.45, 0.9) * scale
		local roll = i % 4
		chip.Color = if roll == 0
			then Color3.fromRGB(255, 210, 80)
			elseif roll == 1 then Color3.fromRGB(255, 160, 40)
			elseif roll == 2 then Color3.fromRGB(90, 70, 40)
			else Color3.fromRGB(255, 240, 140)
		chip.Material = if roll == 2 then Enum.Material.Slate else Enum.Material.Neon
		chip.Anchored = true
		chip.CanCollide = false
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		local ang = math.rad(i * (360 / 40) + math.random() * 10)
		chip.CFrame = CFrame.new(at + Vector3.new(0, 0.4, 0))
		chip.Parent = Workspace
		local dir = Vector3.new(math.cos(ang), 0.55 + math.random() * 1.1, math.sin(ang)).Unit
		local goal = at + dir * (5 + math.random() * 10) + Vector3.new(0, 2 + math.random() * 5, 0)
		TweenService:Create(chip, TweenInfo.new(0.5 + math.random() * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(goal) * CFrame.Angles(math.random() * 5, math.random() * 5, math.random() * 5),
			Transparency = 1,
			Size = chip.Size * 0.15,
		}):Play()
		Debris:AddItem(chip, 1.0)
	end
end

local function landingCf(): (CFrame, Vector3)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local origin = if hrp and hrp:IsA("BasePart") then hrp.Position else Vector3.new(0, 8, 0)
	local look = if hrp and hrp:IsA("BasePart") then Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z) else Vector3.new(0, 0, -1)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local target = origin + look * FORWARD
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = Workspace:Raycast(target + Vector3.new(0, 8, 0), Vector3.new(0, -48, 0), params)
	local ground = if hit then hit.Position else Vector3.new(target.X, origin.Y - 3, target.Z)
	return CFrame.new(ground) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0), ground
end

local function playDrop(payload: any, template: any)
	if typeof(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	local id = payload.id
	local displayName = if typeof(payload.displayName) == "string" then payload.displayName else "Gift"
	local rarity = if typeof(payload.rarity) == "string" then payload.rarity else "legendary"
	local reason = if typeof(payload.reason) == "string" then payload.reason else AdminGiftConfig.REASON_ADMIN
	if typeof(kind) ~= "string" or typeof(id) ~= "string" then
		return
	end

	dropToken += 1
	local token = dropToken
	disconnectDrop()
	destroyLive()

	local model: Model? = nil
	if kind == "luckyBlock" then
		model = cloneLuckyBlock(id, payload.variant)
	elseif kind == "gear" then
		model = cloneGear(tonumber(id) or 0)
	elseif kind == "brainrot" then
		model = cloneBrainrot(id, template, payload.templateName)
	end
	if not model then
		local color = if kind == "gear"
			then Color3.fromRGB(255, 148, 42)
			elseif kind == "luckyBlock" then Color3.fromRGB(255, 214, 64)
			else Color3.fromRGB(72, 210, 92)
		model = makeFallbackCrate(displayName, color)
	end

	local landCf, ground = landingCf()
	local startCf = landCf + Vector3.new(0, FALL_HEIGHT, 0)
	model:PivotTo(startCf)
	model.Parent = Workspace
	liveModel = model

	local t0 = os.clock()
	dropConn = RunService.Heartbeat:Connect(function()
		if token ~= dropToken or not liveModel then
			disconnectDrop()
			return
		end
		local alpha = math.clamp((os.clock() - t0) / DROP_SEC, 0, 1)
		local eased = alpha * alpha
		local bounce = math.sin(alpha * math.pi) * 0.35 * (1 - alpha)
		local spin = CFrame.Angles(0, alpha * math.pi * 2.2, alpha * 0.4)
		liveModel:PivotTo(startCf:Lerp(landCf, eased) * CFrame.new(0, bounce, 0) * spin)
		if alpha >= 1 then
			disconnectDrop()
			liveModel:PivotTo(landCf)
			spawnBurstDebris(ground)
			playImpactFrames(token)
			GameSoundEffects.playGroundSmash(1)
			GameSoundEffects.playDrop(rarity)
			local isPoll = reason == AdminGiftConfig.REASON_REWARD_POLL
			local toast = if isPoll
				then ("You claimed " .. displayName .. "!")
				else ("Admin has gifted u " .. displayName .. "!")
			local subtitle = if isPoll then "You picked this prize" else "Admin has gifted u this"
			local landed = liveModel
			local holdToken = token
			task.delay(HOLD_SEC, function()
				if holdToken ~= dropToken or landed ~= liveModel or not landed then
					return
				end
				CharacterWorldNotif.showCelebration(player.Character, displayName, {
					subtitle = subtitle,
					lifetimeSec = 3.4,
					color = Color3.fromRGB(255, 214, 96),
					rainbow = not isPoll,
				})
				TopNotifController.showGift(toast, rarity, 3.8)
				suckIntoBody(holdToken, landed, landCf)
			end)
		end
	end)
end

function AdminGiftDropController.init()
	if initialized then
		return
	end
	initialized = true
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
		if not remotes then
			warn("[AdminGiftDropController] Remotes missing")
			return
		end
		local ev = remotes:WaitForChild(AdminGiftConfig.DROP_REMOTE, 30)
		if ev and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(playDrop)
		else
			local existing = getRemote()
			if existing then
				existing.OnClientEvent:Connect(playDrop)
			else
				warn("[AdminGiftDropController] drop remote missing")
			end
		end
	end)
end

return AdminGiftDropController
