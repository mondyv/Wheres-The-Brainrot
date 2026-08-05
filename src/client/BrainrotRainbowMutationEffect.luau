-- [ACTIVE] BrainrotRainbowMutationEffect
--[[
	HSV color-cycle for rainbow-mutation brainrot meshes.
	Targets MeshParts / particles / SurfaceAppearances under a child named "Rainbow"
	(Studio template convention). Falls back to MeshParts on the model root if needed.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local SPEED = 0.2
local VFX_ENABLED_ATTR = "BrainrotVFXEnabled"

type TrackedFx = {
	parts: { BasePart },
	particles: { ParticleEmitter },
	surfaces: { SurfaceAppearance },
	ancestryConn: RBXScriptConnection?,
	descConn: RBXScriptConnection?,
	rebuildQueued: boolean,
}

local tracked: { [Instance]: TrackedFx } = {}
local mutationWatch: { [Instance]: boolean } = {}
local heartbeatConn: RBXScriptConnection? = nil
local phaseSeed = math.random() * 1000

local function brainrotVfxEnabled(): boolean
	return player:GetAttribute(VFX_ENABLED_ATTR) ~= false
end

local function isRainbowMutation(root: Instance): boolean
	local mut = root:GetAttribute("BrainrotMutation")
	if typeof(mut) == "string" and string.lower(mut) == "rainbow" then
		return true
	end
	local headerMut = root:GetAttribute("BrainrotHeaderMutation")
	if typeof(headerMut) == "string" and string.lower(headerMut) == "rainbow" then
		return true
	end
	local path = root:GetAttribute("BrainrotSourcePath")
	if typeof(path) == "string" and string.find(string.lower(path), "/rainbow", 1, true) then
		return true
	end
	return false
end

local function isBrainrotWorldModel(model: Model): boolean
	if model:GetAttribute("BrainrotStandDisplay") == true then
		return true
	end
	if model:GetAttribute("BrainrotCarryPhase") ~= nil then
		return true
	end
	if typeof(model:GetAttribute("BrainrotName")) == "string" and model:GetAttribute("BrainrotName") ~= "" then
		return true
	end
	return false
end

local function isBrainrotTool(tool: Tool): boolean
	return tool:GetAttribute("BrainrotTool") == true
end

local function findRainbowRoot(root: Instance): Instance?
	local direct = root:FindFirstChild("Rainbow")
	if direct then
		return direct
	end
	for _, ch in root:GetChildren() do
		local nested = ch:FindFirstChild("Rainbow")
		if nested then
			return nested
		end
	end
	return root:FindFirstChild("Rainbow", true)
end

local function collectFx(scope: Instance): ({ BasePart }, { ParticleEmitter }, { SurfaceAppearance })
	local parts: { BasePart } = {}
	local particles: { ParticleEmitter } = {}
	local surfaces: { SurfaceAppearance } = {}
	local seenParts: { [BasePart]: boolean } = {}

	local function considerPart(part: BasePart)
		if seenParts[part] then
			return
		end
		seenParts[part] = true
		table.insert(parts, part)
		local hasSurface = false
		for _, child in part:GetChildren() do
			if child:IsA("ParticleEmitter") then
				child.LightEmission = 1
				child.LightInfluence = 0
				table.insert(particles, child)
			elseif child:IsA("SurfaceAppearance") then
				table.insert(surfaces, child)
				hasSurface = true
			end
		end
		if not hasSurface and part:IsA("MeshPart") then
			part.Material = Enum.Material.Neon
		end
	end

	if scope:IsA("BasePart") then
		considerPart(scope :: BasePart)
	end
	for _, desc in scope:GetDescendants() do
		if desc:IsA("MeshPart") or desc:IsA("UnionOperation") then
			considerPart(desc :: BasePart)
		elseif desc:IsA("BasePart") and desc.Name == "Rainbow" then
			considerPart(desc)
		end
	end

	return parts, particles, surfaces
end

local function ensureHeartbeat()
	if heartbeatConn then
		return
	end
	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not next(tracked) then
			if heartbeatConn then
				heartbeatConn:Disconnect()
				heartbeatConn = nil
			end
			return
		end
		if not brainrotVfxEnabled() then
			return
		end

		local hue = (os.clock() * SPEED + phaseSeed) % 1
		local strongColor = Color3.fromHSV(hue, 1, 1)
		local seq = ColorSequence.new(strongColor)

		for root, fx in tracked do
			if not root.Parent then
				tracked[root] = nil
				continue
			end
			for _, p in fx.particles do
				if p.Parent then
					p.Color = seq
				end
			end
			for _, s in fx.surfaces do
				if s.Parent then
					s.Color = strongColor
				end
			end
			for _, p in fx.parts do
				if p.Parent then
					p.Color = strongColor
				end
			end
		end
	end)
end

local function untrack(root: Instance)
	local fx = tracked[root]
	if not fx then
		return
	end
	if fx.ancestryConn then
		fx.ancestryConn:Disconnect()
	end
	if fx.descConn then
		fx.descConn:Disconnect()
	end
	tracked[root] = nil
end

local rebuildFx: (Instance) -> ()

local function queueRebuild(root: Instance)
	local fx = tracked[root]
	if fx then
		if fx.rebuildQueued then
			return
		end
		fx.rebuildQueued = true
		task.defer(function()
			local cur = tracked[root]
			if cur then
				cur.rebuildQueued = false
			end
			if root.Parent and isRainbowMutation(root) then
				rebuildFx(root)
			end
		end)
		return
	end
	task.defer(function()
		if root.Parent and isRainbowMutation(root) then
			rebuildFx(root)
		end
	end)
end

rebuildFx = function(root: Instance)
	local existing = tracked[root]
	local rainbowScope = findRainbowRoot(root)
	-- Prefer the named Rainbow body; if missing, color MeshParts on the whole model.
	local scope = rainbowScope or root
	local parts, particles, surfaces = collectFx(scope)
	if rainbowScope == nil then
		-- Avoid recoloring entire non-specialized models with huge part counts.
		if #parts > 48 then
			untrack(root)
			return
		end
	end
	if #parts == 0 and #particles == 0 and #surfaces == 0 then
		untrack(root)
		return
	end

	if existing then
		existing.parts = parts
		existing.particles = particles
		existing.surfaces = surfaces
	else
		local fx: TrackedFx = {
			parts = parts,
			particles = particles,
			surfaces = surfaces,
			ancestryConn = nil,
			descConn = nil,
			rebuildQueued = false,
		}
		fx.ancestryConn = root.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				untrack(root)
			end
		end)
		fx.descConn = root.DescendantAdded:Connect(function()
			queueRebuild(root)
		end)
		tracked[root] = fx
	end
	ensureHeartbeat()
end

local function tryTrack(inst: Instance)
	if inst:IsA("Model") and isBrainrotWorldModel(inst) then
		if isRainbowMutation(inst) then
			rebuildFx(inst)
		else
			untrack(inst)
		end
	elseif inst:IsA("Tool") and isBrainrotTool(inst) then
		if isRainbowMutation(inst) then
			rebuildFx(inst)
		else
			untrack(inst)
		end
	end
end

local function watchMutationAttr(root: Instance)
	if mutationWatch[root] then
		return
	end
	if not (root:IsA("Model") or root:IsA("Tool")) then
		return
	end
	mutationWatch[root] = true
	root:GetAttributeChangedSignal("BrainrotMutation"):Connect(function()
		tryTrack(root)
	end)
	root.Destroying:Once(function()
		mutationWatch[root] = nil
		untrack(root)
	end)
end

local function scanWorkspace()
	local stack: { Instance } = { Workspace }
	local scanned = 0
	while #stack > 0 do
		local node = table.remove(stack) :: Instance
		local ok, children = pcall(function()
			return node:GetChildren()
		end)
		if not ok or typeof(children) ~= "table" then
			continue
		end
		for _, ch in children do
			scanned += 1
			if scanned % 250 == 0 then
				task.wait()
			end
			tryTrack(ch)
			watchMutationAttr(ch)
			if ch:IsA("Model") or ch:IsA("Folder") or ch:IsA("Tool") then
				table.insert(stack, ch)
			end
		end
	end
	for _, plr in Players:GetPlayers() do
		local bp = plr:FindFirstChildOfClass("Backpack")
		if bp then
			for _, ch in bp:GetChildren() do
				tryTrack(ch)
				watchMutationAttr(ch)
			end
		end
		if plr.Character then
			for _, ch in plr.Character:GetChildren() do
				tryTrack(ch)
				watchMutationAttr(ch)
			end
		end
	end
end

local BrainrotRainbowMutationEffect = {}

function BrainrotRainbowMutationEffect.init()
	Workspace.DescendantAdded:Connect(function(inst)
		if not (inst:IsA("Model") or inst:IsA("Tool")) then
			return
		end
		task.defer(function()
			tryTrack(inst)
			watchMutationAttr(inst)
		end)
	end)

	Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function(char)
			char.ChildAdded:Connect(function(ch)
				task.defer(function()
					tryTrack(ch)
					watchMutationAttr(ch)
				end)
			end)
			for _, ch in char:GetChildren() do
				tryTrack(ch)
				watchMutationAttr(ch)
			end
		end)
		task.spawn(function()
			local bp = plr:WaitForChild("Backpack", 30)
			if not bp then
				return
			end
			bp.ChildAdded:Connect(function(ch)
				tryTrack(ch)
				watchMutationAttr(ch)
			end)
		end)
	end)

	for _, plr in Players:GetPlayers() do
		if plr.Character then
			for _, ch in plr.Character:GetChildren() do
				tryTrack(ch)
				watchMutationAttr(ch)
			end
		end
		local bp = plr:FindFirstChildOfClass("Backpack")
		if bp then
			for _, ch in bp:GetChildren() do
				tryTrack(ch)
				watchMutationAttr(ch)
			end
		end
	end

	player:GetAttributeChangedSignal(VFX_ENABLED_ATTR):Connect(function()
		if brainrotVfxEnabled() then
			ensureHeartbeat()
		end
	end)

	task.defer(scanWorkspace)
end

return BrainrotRainbowMutationEffect
