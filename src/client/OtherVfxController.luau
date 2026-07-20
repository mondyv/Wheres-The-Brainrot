-- [ACTIVE] OtherVfxController
--[[
	Plays EssentialAssets.OtherVFX with the standard Studio emit-plugin pattern:
	emitters stay Disabled; script calls :Emit(EmitCount) once (after EmitDelay).
	Supports EmitDuration (brief enable window), Beam Width0/Width1/Duration tweens.
	Bush search: BushEffect pulsed across the bush volume while shaking; BushEffectBurst on open.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local OtherVfxController = {}

local LIFETIME_SEC = 5
local UPGRADE_LIFETIME_SEC = 6.5
local BEZIER_DURATION = 0.55
-- One frame+ after Clone/Parent so particle textures can load before Emit.
local EMIT_SETTLE_SEC = 0.08
local DEFAULT_EMIT_FALLBACK = 16

local function findOtherVfxFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local other = assets and assets:FindFirstChild("OtherVFX")
	if other then
		return other
	end
	return nil
end

local function findTemplate(pathParts: { string }): Instance?
	local node: Instance? = findOtherVfxFolder()
	if not node then
		return nil
	end
	for _, name in pathParts do
		node = node:FindFirstChild(name)
		if not node then
			return nil
		end
	end
	return node
end

local function stabilizeParts(root: Instance)
	local function fixPart(part: BasePart)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Transparency = 1
		part.CastShadow = false
	end
	if root:IsA("BasePart") then
		fixPart(root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			fixPart(d)
		end
	end
end

local function disableAllFx(root: Instance)
	if root:IsA("ParticleEmitter") or root:IsA("Trail") or root:IsA("Beam") then
		root.Enabled = false
	elseif root:IsA("PointLight") or root:IsA("SpotLight") or root:IsA("SurfaceLight") then
		root.Enabled = false
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = false
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			d.Enabled = false
		end
	end
end

local function playSounds(root: Instance)
	if root:IsA("Sound") then
		root:Play()
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Sound") then
			d:Play()
		end
	end
end

local function flashLight(light: PointLight | SpotLight | SurfaceLight)
	local delayAttr = light:GetAttribute("EmitDelay")
	local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
	local durAttr = light:GetAttribute("EmitDuration") or light:GetAttribute("Duration")
	local dur = if typeof(durAttr) == "number" then math.max(0.05, durAttr) else 0.35
	task.delay(delaySec, function()
		if not light.Parent then
			return
		end
		if light.Brightness <= 0 then
			light.Brightness = 2
		end
		light.Enabled = true
		task.delay(dur, function()
			if light.Parent then
				light.Enabled = false
			end
		end)
	end)
end

--- Plugin-style one-shot emit for every VFX under root.
local function emitAll(root: Instance, skipUnder: Instance?)
	local function skip(inst: Instance): boolean
		return skipUnder ~= nil and (inst == skipUnder or inst:IsDescendantOf(skipUnder))
	end

	local function emitParticle(emitter: ParticleEmitter)
		if skip(emitter) then
			return
		end
		emitter.Enabled = false
		local delayAttr = emitter:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		local countAttr = emitter:GetAttribute("EmitCount")
		local count = if typeof(countAttr) == "number" then math.floor(countAttr) else nil
		local durAttr = emitter:GetAttribute("EmitDuration")
		local dur = if typeof(durAttr) == "number" then math.max(0, durAttr) else 0

		task.delay(delaySec, function()
			if not emitter.Parent then
				return
			end
			-- EmitDuration = brief rate window (plugin style). Still Emit when count > 0.
			if dur > 0 then
				emitter.Enabled = true
				task.delay(dur, function()
					if emitter.Parent then
						emitter.Enabled = false
					end
				end)
			end
			local burst = 0
			if typeof(count) == "number" and count > 0 then
				burst = count
			elseif count == nil then
				burst = math.max(DEFAULT_EMIT_FALLBACK, math.floor(emitter.Rate))
			elseif count <= 0 and dur <= 0 then
				-- EmitCount 0 with no duration — still pop a small burst so layers aren't silent.
				burst = math.max(DEFAULT_EMIT_FALLBACK, math.floor(emitter.Rate))
			end
			if burst > 0 then
				emitter:Emit(burst)
			end
			if dur <= 0 then
				emitter.Enabled = false
			end
		end)
	end

	local function emitBeam(beam: Beam)
		if skip(beam) then
			return
		end
		local delayAttr = beam:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		local width0 = beam:GetAttribute("Width0")
		local width1 = beam:GetAttribute("Width1")
		local durAttr = beam:GetAttribute("Duration") or beam:GetAttribute("EmitDuration")
		local dur = if typeof(durAttr) == "number" then math.max(0.05, durAttr) else 0.35

		task.delay(delaySec, function()
			if not beam.Parent then
				return
			end
			if typeof(width0) == "number" and typeof(width1) == "number" then
				beam.Width0 = 0
				beam.Width1 = 0
				beam.Enabled = true
				local tw = TweenService:Create(
					beam,
					TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
					{ Width0 = width0, Width1 = width1 }
				)
				tw:Play()
				tw.Completed:Once(function()
					if beam.Parent then
						beam.Enabled = false
					end
				end)
			else
				beam.Enabled = true
				task.delay(dur, function()
					if beam.Parent then
						beam.Enabled = false
					end
				end)
			end
		end)
	end

	local function emitTrail(trail: Trail)
		if skip(trail) then
			return
		end
		local delayAttr = trail:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		local durAttr = trail:GetAttribute("EmitDuration") or trail:GetAttribute("Duration")
		local dur = if typeof(durAttr) == "number" then math.max(0.05, durAttr) else 0.45
		task.delay(delaySec, function()
			if not trail.Parent then
				return
			end
			trail.Enabled = true
			task.delay(dur, function()
				if trail.Parent then
					trail.Enabled = false
				end
			end)
		end)
	end

	local function visit(inst: Instance)
		if skip(inst) then
			return
		end
		if inst:IsA("ParticleEmitter") then
			emitParticle(inst)
		elseif inst:IsA("Beam") then
			emitBeam(inst)
		elseif inst:IsA("Trail") then
			emitTrail(inst)
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			flashLight(inst)
		end
	end

	visit(root)
	for _, d in root:GetDescendants() do
		visit(d)
	end
	playSounds(root)
end

local function collectBezierWorldPoints(pointsFolder: Instance): { Vector3 }
	local numbered: { { i: number, p: Vector3 } } = {}
	for _, child in pointsFolder:GetChildren() do
		local idx = tonumber(child.Name)
		if not idx then
			continue
		end
		local pos: Vector3? = nil
		if child:IsA("BasePart") then
			pos = child.Position
		elseif child:IsA("Attachment") then
			pos = child.WorldPosition
		else
			local att = child:FindFirstChildWhichIsA("Attachment", true)
			local part = child:FindFirstChildWhichIsA("BasePart", true)
			if att then
				pos = att.WorldPosition
			elseif part then
				pos = part.Position
			end
		end
		if pos then
			table.insert(numbered, { i = idx, p = pos })
		end
	end
	table.sort(numbered, function(a, b)
		return a.i < b.i
	end)
	local out: { Vector3 } = {}
	for _, entry in numbered do
		table.insert(out, entry.p)
	end
	return out
end

local function samplePolyline(points: { Vector3 }, alpha: number): Vector3
	if #points == 0 then
		return Vector3.zero
	end
	if #points == 1 then
		return points[1]
	end
	local t = math.clamp(alpha, 0, 1) * (#points - 1)
	local i = math.floor(t) + 1
	local f = t - math.floor(t)
	local a = points[i]
	local b = points[math.min(i + 1, #points)]
	return a:Lerp(b, f)
end

--- Trails need Attachment0 + Attachment1. Specs (Blurred Spec, etc.) live on those same
--- Attachments under Bezier.Part — wire and emit them the same way as the root Fading Glow.
local function prepareMoverFlightVfx(mover: BasePart, emitOnFinish: Instance?)
	local attachments: { Attachment } = {}
	for _, ch in mover:GetChildren() do
		if ch:IsA("Attachment") then
			table.insert(attachments, ch)
		end
	end

	-- Guarantee two attachments so Trail has a span (plugin often leaves these unset).
	while #attachments < 2 do
		local extra = Instance.new("Attachment")
		extra.Name = "TrailSpan" .. tostring(#attachments + 1)
		extra.Position = Vector3.new(0, (#attachments == 0) and 0.14 or -0.14, 0)
		extra.Parent = mover
		table.insert(attachments, extra)
	end
	if (attachments[1].Position - attachments[2].Position).Magnitude < 0.05 then
		attachments[1].Position = Vector3.new(0, 0.16, 0)
		attachments[2].Position = Vector3.new(0, -0.16, 0)
	end

	for _, d in mover:GetDescendants() do
		if emitOnFinish and d:IsDescendantOf(emitOnFinish) then
			continue
		end
		if d:IsA("Trail") then
			d.Attachment0 = attachments[1]
			d.Attachment1 = attachments[2]
			d.Enabled = true
		elseif d:IsA("Beam") then
			if not d.Attachment0 then
				d.Attachment0 = attachments[1]
			end
			if not d.Attachment1 then
				d.Attachment1 = attachments[2]
			end
			d.Enabled = true
		end
	end

	-- Emit every spec/particle on the mover attachments (Blurred Spec 21, etc.).
	for _, att in attachments do
		emitAll(att, emitOnFinish)
		for _, d in att:GetDescendants() do
			if emitOnFinish and d:IsDescendantOf(emitOnFinish) then
				continue
			end
			if d:IsA("ParticleEmitter") then
				d.Enabled = true
			end
		end
	end
end

local function runBezierIfPresent(root: Instance, hostCf: CFrame): boolean
	local bezier = root:FindFirstChild("Bezier", true)
	if not bezier then
		return false
	end
	local pointsFolder = bezier:FindFirstChild("Points")
	local mover = bezier:FindFirstChild("Part")
	if not pointsFolder or not mover or not mover:IsA("BasePart") then
		return false
	end

	-- Break free of any weld so the scripted flight can move this part.
	for _, ch in mover:GetChildren() do
		if ch:IsA("WeldConstraint") or ch:IsA("Weld") or ch:IsA("Motor6D") then
			ch:Destroy()
		end
	end
	mover.Anchored = true

	local points = collectBezierWorldPoints(pointsFolder)
	if #points < 2 then
		points = {
			hostCf.Position,
			hostCf.Position + hostCf.UpVector * 4 + hostCf.LookVector * 2,
			hostCf.Position + hostCf.UpVector * 2,
		}
	end

	local emitOnFinish = mover:FindFirstChild("EmitOnFinish")
	-- Root glow (Fading Glow) + everything outside the finish burst.
	emitAll(root, emitOnFinish)
	-- Wire Trail/Beam to Bezier.Part attachments and emit Blurred Spec layers on them.
	prepareMoverFlightVfx(mover, emitOnFinish)

	mover.CFrame = CFrame.new(points[1])
	local started = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not mover.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local alpha = math.clamp((os.clock() - started) / BEZIER_DURATION, 0, 1)
		local pos = samplePolyline(points, alpha)
		local look = if alpha < 0.99 then samplePolyline(points, math.min(1, alpha + 0.05)) else pos + Vector3.yAxis
		mover.CFrame = CFrame.lookAt(pos, look)
		if alpha >= 1 then
			if conn then
				conn:Disconnect()
			end
			if emitOnFinish then
				emitAll(emitOnFinish, nil)
			else
				emitAll(mover, nil)
			end
			for _, d in mover:GetDescendants() do
				if d:IsA("Trail") or d:IsA("Beam") or d:IsA("ParticleEmitter") then
					if not (emitOnFinish and d:IsDescendantOf(emitOnFinish)) then
						d.Enabled = false
					end
				end
			end
		end
	end)
	return true
end

--- Move a root BasePart and every descendant BasePart by the same delta (Attachments alone aren't enough —
--- Bezier point/mover Parts stay at the template origin unless transformed).
local function relocatePartTree(rootPart: BasePart, targetCf: CFrame)
	local oldCf = rootPart.CFrame
	local delta = targetCf * oldCf:Inverse()
	rootPart.CFrame = targetCf
	for _, d in rootPart:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
end

local function weldStaticPartsToRoot(rootPart: BasePart, freePart: BasePart?)
	for _, d in rootPart:GetDescendants() do
		if d:IsA("BasePart") and d ~= freePart then
			d.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = rootPart
			weld.Part1 = d
			weld.Parent = d
		end
	end
end

local function placeClone(clone: Instance, at: CFrame | BasePart): Instance
	stabilizeParts(clone)
	disableAllFx(clone)

	local cf: CFrame
	local hostPart: BasePart? = nil
	if typeof(at) == "CFrame" then
		cf = at
	else
		hostPart = at
		cf = at.CFrame
	end

	if clone:IsA("Attachment") then
		if hostPart then
			clone.Parent = hostPart
		else
			local anchor = Instance.new("Part")
			anchor.Name = "OtherVfxAnchor"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(0.35, 0.35, 0.35)
			anchor.CFrame = cf
			anchor.Parent = Workspace
			clone.Parent = anchor
			anchor:SetAttribute("__OtherVfxDebris", true)
			Debris:AddItem(anchor, LIFETIME_SEC)
		end
		return clone
	end

	if clone:IsA("BasePart") then
		local bezier = clone:FindFirstChild("Bezier", true)
		local mover = if bezier then bezier:FindFirstChild("Part") else nil
		local freeMover = if mover and mover:IsA("BasePart") then mover :: BasePart else nil
		relocatePartTree(clone, cf)
		if freeMover then
			-- Keep the bezier payload free to fly; weld the rest so Points stay with the host.
			weldStaticPartsToRoot(clone, freeMover)
			freeMover.Anchored = true
		end
		if hostPart then
			clone.Anchored = false
			clone.Parent = Workspace
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hostPart
			weld.Part1 = clone
			weld.Parent = clone
		else
			clone.Parent = Workspace
		end
		return clone
	end

	if clone:IsA("Model") then
		clone.Parent = Workspace
		clone:PivotTo(cf)
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
		local bezier = clone:FindFirstChild("Bezier", true)
		local mover = if bezier then bezier:FindFirstChild("Part") else nil
		local freeMover = if mover and mover:IsA("BasePart") then mover :: BasePart else nil
		if primary then
			if freeMover then
				weldStaticPartsToRoot(primary, freeMover)
				-- Also weld other model parts to primary except freeMover
				for _, d in clone:GetDescendants() do
					if d:IsA("BasePart") and d ~= primary and d ~= freeMover then
						d.Anchored = false
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = primary
						weld.Part1 = d
						weld.Parent = d
					end
				end
				freeMover.Anchored = true
			end
			if hostPart then
				primary.Anchored = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = hostPart
				weld.Part1 = primary
				weld.Parent = primary
			end
		end
		return clone
	end

	local anchor = Instance.new("Part")
	anchor.Name = "OtherVfxAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.35, 0.35, 0.35)
	anchor.CFrame = cf
	anchor.Parent = Workspace
	clone.Parent = anchor
	local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
	if firstPart then
		local delta = cf * firstPart.CFrame:Inverse()
		for _, d in clone:GetDescendants() do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end
		local bezier = clone:FindFirstChild("Bezier", true)
		local mover = if bezier then bezier:FindFirstChild("Part") else nil
		local freeMover = if mover and mover:IsA("BasePart") then mover :: BasePart else nil
		if freeMover then
			weldStaticPartsToRoot(firstPart, freeMover)
			freeMover.Anchored = true
		else
			weldStaticPartsToRoot(firstPart, nil)
		end
		firstPart.Anchored = false
		local weldRoot = Instance.new("WeldConstraint")
		weldRoot.Part0 = anchor
		weldRoot.Part1 = firstPart
		weldRoot.Parent = firstPart
	end
	if hostPart then
		anchor.Anchored = false
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hostPart
		weld.Part1 = anchor
		weld.Parent = anchor
	end
	anchor:SetAttribute("__OtherVfxDebris", true)
	Debris:AddItem(anchor, LIFETIME_SEC)
	return anchor
end

local function playTemplate(pathParts: { string }, at: CFrame | BasePart, lifetimeSec: number?)
	local template = findTemplate(pathParts)
	if not template then
		warn("[OtherVfxController] missing template:", table.concat(pathParts, "/"))
		return
	end
	local life = lifetimeSec or LIFETIME_SEC
	local clone = template:Clone()
	local placed = placeClone(clone, at)
	local hostCf = if typeof(at) == "CFrame" then at else at.CFrame

	task.delay(EMIT_SETTLE_SEC, function()
		if not clone.Parent then
			return
		end
		local usedBezier = runBezierIfPresent(clone, hostCf)
		if not usedBezier then
			emitAll(clone, nil)
		end
	end)

	if clone:IsA("Attachment") and typeof(at) ~= "CFrame" then
		Debris:AddItem(clone, life)
	elseif placed.Name == "OtherVfxAnchor" then
		if not placed:GetAttribute("__OtherVfxDebris") then
			placed:SetAttribute("__OtherVfxDebris", true)
			Debris:AddItem(placed, life)
		elseif life > LIFETIME_SEC then
			Debris:AddItem(placed, life)
		end
	else
		Debris:AddItem(placed, life)
	end
end

local function resolveBushHost(bush: Instance): CFrame | BasePart
	if bush:IsA("BasePart") then
		return bush
	end
	if bush:IsA("Model") then
		local primary = bush.PrimaryPart or bush:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			return primary
		end
	end
	local part = bush:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part
	end
	if bush:IsA("Model") then
		return bush:GetPivot()
	end
	return CFrame.new()
end

local function isHelperPart(part: BasePart): boolean
	local n = part.Name
	return n == "_BushPromptAnchor"
		or n == "_BushPromptCenter"
		or n == "_BushEmptyMessageAnchor"
		or n == "OtherVfxAnchor"
		or string.sub(n, 1, 9) == "OtherVfx"
end

--- Visual AABB of the bush (ignores invisible helpers). Uses volume center, not crown/pivot.
local function getBushVolume(bush: Instance): (CFrame, Vector3)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local found = false

	local function include(part: BasePart)
		if isHelperPart(part) or part.Transparency >= 1 then
			return
		end
		found = true
		local cf = part.CFrame
		local h = part.Size * 0.5
		for sx = -1, 1, 2 do
			for sy = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
					minX = math.min(minX, wp.X)
					minY = math.min(minY, wp.Y)
					minZ = math.min(minZ, wp.Z)
					maxX = math.max(maxX, wp.X)
					maxY = math.max(maxY, wp.Y)
					maxZ = math.max(maxZ, wp.Z)
				end
			end
		end
	end

	if bush:IsA("BasePart") then
		include(bush)
	end
	for _, d in bush:GetDescendants() do
		if d:IsA("BasePart") then
			include(d)
		end
	end

	if found then
		local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
		local size = Vector3.new(
			math.max(1.2, maxX - minX),
			math.max(1.2, maxY - minY),
			math.max(1.2, maxZ - minZ)
		)
		return CFrame.new(center), size
	end

	if bush:IsA("Model") then
		local ok, cf, size = pcall(function()
			return (bush :: Model):GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			return cf, Vector3.new(math.max(1.2, size.X), math.max(1.2, size.Y), math.max(1.2, size.Z))
		end
		return bush:GetPivot(), Vector3.new(4, 4, 4)
	end

	local host = resolveBushHost(bush)
	if typeof(host) == "CFrame" then
		return host, Vector3.new(4, 4, 4)
	end
	return host.CFrame, Vector3.new(4, 4, 4)
end

local function sampleBushVolumePoints(bush: Instance, count: number): { CFrame }
	local volumeCf, size = getBushVolume(bush)
	local half = size * 0.42
	local points: { CFrame } = {}
	table.insert(points, volumeCf)
	table.insert(points, volumeCf * CFrame.new(0, -half.Y * 0.35, 0))
	table.insert(points, volumeCf * CFrame.new(0, half.Y * 0.25, 0))
	local remaining = math.max(0, count - #points)
	for _ = 1, remaining do
		local offset = Vector3.new(
			(math.random() * 2 - 1) * half.X,
			(math.random() * 2 - 1) * half.Y,
			(math.random() * 2 - 1) * half.Z
		)
		table.insert(points, volumeCf * CFrame.new(offset))
	end
	return points
end

local function playScattered(pathParts: { string }, bush: Instance, pointCount: number)
	for _, cf in sampleBushVolumePoints(bush, pointCount) do
		playTemplate(pathParts, cf)
	end
end

local bushShakeToken = 0
local BUSH_SHAKE_PULSE_SEC = 0.42
local BUSH_SHAKE_POINTS = 6
local BUSH_BURST_POINTS = 7

--- Leaves/debris while searching (hold shake). Pulsed Emit across the bush volume.
function OtherVfxController.playBushSearchShake(bush: Instance)
	bushShakeToken += 1
	local token = bushShakeToken
	local function pulse()
		if token ~= bushShakeToken or not bush.Parent then
			return
		end
		playScattered({ "Bush Opening", "BushEffect" }, bush, BUSH_SHAKE_POINTS)
	end
	pulse()
	task.spawn(function()
		while token == bushShakeToken do
			task.wait(BUSH_SHAKE_PULSE_SEC)
			if token ~= bushShakeToken then
				break
			end
			pulse()
		end
	end)
end

function OtherVfxController.stopBushSearchShake()
	bushShakeToken += 1
end

--- Final burst when search completes — scattered through the bush volume.
function OtherVfxController.playBushOpenedBurst(bush: Instance)
	OtherVfxController.stopBushSearchShake()
	playScattered({ "Bush Opening", "BushEffectBurst" }, bush, BUSH_BURST_POINTS)
end

function OtherVfxController.playLuckyBlockOpen(at: CFrame | BasePart)
	playTemplate({ "Bush Opening", "Luckyblock" }, at)
end

function OtherVfxController.playBrainrotUpgrade(at: CFrame | BasePart)
	playTemplate({ "UpgradeBR", "OnUpgrade" }, at, UPGRADE_LIFETIME_SEC)
end

return OtherVfxController
