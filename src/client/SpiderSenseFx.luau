-- [ACTIVE] SpiderSenseFx
--[[
	Attach EssentialAssets.SpiderVFX templates to the local player's head.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpiderSenseFx = {}

local activeRoots: { Instance } = {}

local function findVfxFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local vfx = assets and assets:FindFirstChild("SpiderVFX")
	if vfx and vfx:IsA("Folder") then
		return vfx
	end
	return nil
end

local function findTemplate(name: string): Instance?
	local folder = findVfxFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild(name)
end

local function setEnabled(root: Instance, enabled: boolean)
	if root:IsA("ParticleEmitter") or root:IsA("Trail") or root:IsA("Beam") then
		root.Enabled = enabled
	end
	for _, desc in root:GetDescendants() do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam") then
			desc.Enabled = enabled
		end
	end
end

local function emitParticles(root: Instance, defaultCount: number)
	for _, desc in root:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			local count = desc:GetAttribute("EmitCount")
			desc:Emit(if typeof(count) == "number" then count else defaultCount)
		end
	end
	if root:IsA("ParticleEmitter") then
		local count = root:GetAttribute("EmitCount")
		root:Emit(if typeof(count) == "number" then count else defaultCount)
	end
end

local function playSounds(root: Instance)
	for _, desc in root:GetDescendants() do
		if desc:IsA("Sound") then
			desc:Play()
		end
	end
end

local function resolveHead(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function attachToHost(template: Instance, host: BasePart, cloneName: string): Instance?
	local clone = template:Clone()
	clone.Name = cloneName

	if clone:IsA("Attachment") then
		clone.Parent = host
		setEnabled(clone, true)
		return clone
	end

	local anchorPart = clone:FindFirstChildWhichIsA("BasePart", true)
	if anchorPart and anchorPart:IsA("BasePart") then
		for _, desc in clone:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanQuery = false
				desc.CanTouch = false
				desc.Massless = true
			end
		end
		clone.Parent = host
		anchorPart.CFrame = host.CFrame
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = host
		weld.Part1 = anchorPart
		weld.Parent = anchorPart
		setEnabled(clone, true)
		return clone
	end

	local anchor = Instance.new("Part")
	anchor.Name = cloneName
	anchor.Size = Vector3.new(0.12, 0.12, 0.12)
	anchor.Transparency = 1
	anchor.Anchored = false
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Massless = true
	anchor.CFrame = host.CFrame
	anchor.Parent = host

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = host
	weld.Part1 = anchor
	weld.Parent = anchor

	local moved = false
	for _, desc in clone:GetDescendants() do
		if desc:IsA("Attachment") or desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam") or desc:IsA("Sound") then
			desc.Parent = anchor
			moved = true
		end
	end
	clone:Destroy()

	if not moved then
		anchor:Destroy()
		return nil
	end

	setEnabled(anchor, true)
	return anchor
end

function SpiderSenseFx.stopAll()
	for _, root in activeRoots do
		if root.Parent then
			setEnabled(root, false)
			root:Destroy()
		end
	end
	table.clear(activeRoots)
end

function SpiderSenseFx.startOnPlayer(templateNames: { string })
	SpiderSenseFx.stopAll()
	local char = game:GetService("Players").LocalPlayer.Character
	if not char then
		return
	end
	local head = resolveHead(char)
	if not head then
		return
	end

	for i, name in templateNames do
		local template = findTemplate(name)
		if not template then
			warn("[SpiderSenseFx] Missing SpiderVFX template:", name)
			continue
		end
		local attached = attachToHost(template, head, "PlayerSpiderSense_" .. tostring(i))
		if attached then
			table.insert(activeRoots, attached)
			emitParticles(attached, 18)
			playSounds(attached)
		end
	end
end

function SpiderSenseFx.startLurkingSense()
	-- Player-only VFX (not the spider encounter variant).
	SpiderSenseFx.startOnPlayer({ "Spidey senses human" })
end

return SpiderSenseFx
