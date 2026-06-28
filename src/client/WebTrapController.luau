-- [ACTIVE] WebTrapController
--[[
	Client VFX for spider-web traps: strands, vignette, subtle particles.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local WebTrapConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WebTrapConfig"))

local player = Players.LocalPlayer

local WebTrapController = {}

local active = false
local attrConn: RBXScriptConnection? = nil
local charConn: RBXScriptConnection? = nil

local colorFx: ColorCorrectionEffect? = nil
local vignetteGui: ScreenGui? = nil
local vignetteFrame: Frame? = nil
local strandFolder: Folder? = nil
local websFolder: Instance? = nil
local dustEmitter: ParticleEmitter? = nil
local webAttachments: { Attachment } = {}

local function findWebsFolder(): Instance?
	local node: Instance = Workspace
	for _, name in WebTrapConfig.WEBS_FOLDER_PATH do
		local child = node:FindFirstChild(name)
		if not child then
			return nil
		end
		node = child
	end
	return node
end

local function nearestWebPart(from: Vector3): BasePart?
	local root = websFolder or findWebsFolder()
	if not root then
		return nil
	end
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			local dist = (desc.Position - from).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = desc
			end
		end
	end
	return best
end

local function ensureColorFx(): ColorCorrectionEffect
	if colorFx and colorFx.Parent then
		return colorFx
	end
	local fx = Instance.new("ColorCorrectionEffect")
	fx.Name = "WebTrapColor"
	fx.Brightness = 0
	fx.Contrast = 0
	fx.Saturation = 0
	fx.TintColor = Color3.fromRGB(255, 255, 255)
	fx.Enabled = false
	fx.Parent = game:GetService("Lighting")
	colorFx = fx
	return fx
end

local function ensureVignette(): Frame
	if vignetteFrame and vignetteFrame.Parent then
		return vignetteFrame
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "WebTrapVignette"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Dim"
	frame.BackgroundColor3 = Color3.fromRGB(18, 12, 28)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = gui

	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(0.45, 0.72),
		NumberSequenceKeypoint.new(1, 0.92),
	})
	grad.Rotation = 90
	grad.Parent = frame

	vignetteGui = gui
	vignetteFrame = frame
	return frame
end

local function makeStrand(fromAtt: Attachment, toAtt: Attachment, parent: Instance)
	local beam = Instance.new("Beam")
	beam.Name = "WebStrand"
	beam.Attachment0 = fromAtt
	beam.Attachment1 = toAtt
	beam.Color = ColorSequence.new(Color3.fromRGB(220, 220, 235), Color3.fromRGB(170, 170, 190))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.5, 0.28),
		NumberSequenceKeypoint.new(1, 0.42),
	})
	beam.Width0 = 0.14
	beam.Width1 = 0.06
	beam.LightEmission = 0.15
	beam.FaceCamera = true
	beam.Segments = 8
	beam.CurveSize0 = 0.35
	beam.CurveSize1 = -0.2
	beam.Parent = parent
	return beam
end

local function buildStrands(character: Model)
	if strandFolder then
		strandFolder:Destroy()
		strandFolder = nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not hrp or not torso or not torso:IsA("BasePart") then
		return
	end

	local webPart = nearestWebPart(hrp.Position)
	if not webPart then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "WebTrapStrands"
	folder.Parent = character
	strandFolder = folder

	local bodyAtt = Instance.new("Attachment")
	bodyAtt.Name = "WebTrapBody"
	bodyAtt.Position = Vector3.new(0, 0.2, 0)
	bodyAtt.Parent = torso :: BasePart

	local offsets = {
		Vector3.new(0.8, 1.1, 0.3),
		Vector3.new(-0.7, 0.9, -0.4),
		Vector3.new(0.2, -0.5, 0.9),
		Vector3.new(-0.5, 0.3, -0.8),
		Vector3.new(0.6, -0.2, -0.7),
	}

	local webCenterAtt = Instance.new("Attachment")
	webCenterAtt.Name = "WebTrapCenter"
	webCenterAtt.Position = webPart.CFrame:PointToObjectSpace(hrp.Position)
	webCenterAtt.Parent = webPart
	table.insert(webAttachments, webCenterAtt)

	for i, offset in offsets do
		local webAtt = Instance.new("Attachment")
		webAtt.Name = "WebTrapAnchor" .. i
		webAtt.Position = offset
		webAtt.Parent = webPart
		table.insert(webAttachments, webAtt)

		local limbAtt = Instance.new("Attachment")
		limbAtt.Name = "WebTrapLimb" .. i
		limbAtt.Position = Vector3.new(
			math.sin(i * 1.7) * 0.55,
			math.cos(i * 1.3) * 0.45,
			math.sin(i * 2.1) * 0.35
		)
		limbAtt.Parent = torso :: BasePart

		makeStrand(limbAtt, webAtt, folder)
	end

	makeStrand(bodyAtt, webCenterAtt, folder)
end

local function cleanupFx()
	if strandFolder then
		strandFolder:Destroy()
		strandFolder = nil
	end
	for _, att in webAttachments do
		if att.Parent then
			att:Destroy()
		end
	end
	table.clear(webAttachments)

	if dustEmitter then
		dustEmitter:Destroy()
		dustEmitter = nil
	end

	if colorFx then
		colorFx.Enabled = false
		TweenService:Create(colorFx, TweenInfo.new(0.35), {
			Saturation = 0,
			Brightness = 0,
			Contrast = 0,
			TintColor = Color3.fromRGB(255, 255, 255),
		}):Play()
	end

	if vignetteGui then
		vignetteGui.Enabled = false
	end
end

local function startFx(character: Model)
	if active then
		cleanupFx()
	end
	active = true

	buildStrands(character)

	local fx = ensureColorFx()
	fx.Enabled = true
	TweenService:Create(fx, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Saturation = -0.35,
		Brightness = -0.06,
		Contrast = 0.08,
		TintColor = Color3.fromRGB(232, 228, 248),
	}):Play()

	local vignette = ensureVignette()
	if vignetteGui then
		vignetteGui.Enabled = true
	end
	vignette.BackgroundTransparency = 1
	TweenService:Create(vignette, TweenInfo.new(0.5), { BackgroundTransparency = 0.35 }):Play()

	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		local dust = Instance.new("ParticleEmitter")
		dust.Name = "WebTrapDust"
		dust.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		dust.Color = ColorSequence.new(Color3.fromRGB(230, 230, 245))
		dust.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.08),
			NumberSequenceKeypoint.new(1, 0),
		})
		dust.Lifetime = NumberRange.new(0.35, 0.7)
		dust.Rate = 8
		dust.Speed = NumberRange.new(0.1, 0.5)
		dust.SpreadAngle = Vector2.new(30, 30)
		dust.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		})
		dust.Parent = torso
		dustEmitter = dust
	end
end

local function onTrappedChanged()
	local trapped = player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true
	if trapped then
		local character = player.Character
		if character then
			startFx(character)
		end
	else
		active = false
		cleanupFx()
	end
end

local function hookCharacter(character: Model)
	if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true then
		task.defer(function()
			if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true and character.Parent then
				startFx(character)
			end
		end)
	end
end

function WebTrapController.init()
	websFolder = findWebsFolder()
	if not websFolder then
		task.spawn(function()
			local map = Workspace:WaitForChild("Map", 120)
			websFolder = map and map:WaitForChild("Webs", 120)
		end)
	end

	attrConn = player:GetAttributeChangedSignal(WebTrapConfig.TRAPPED_ATTR):Connect(onTrappedChanged)
	charConn = player.CharacterAdded:Connect(hookCharacter)

	if player:GetAttribute(WebTrapConfig.TRAPPED_ATTR) == true then
		onTrappedChanged()
	end
	if player.Character then
		hookCharacter(player.Character)
	end
end

return WebTrapController
