-- [ACTIVE] OtherVfxController
--[[
	Plays EssentialAssets.OtherVFX with the standard Studio emit-plugin pattern:
	emitters stay Disabled; script calls :Emit(EmitCount) once (after EmitDelay).
	Supports EmitDuration (brief enable window), Beam Width0/Width1/Duration tweens.
	Bush search: one BushEffect on the bush (pulsed Emit while holding); BushEffectBurst on open.
	UpgradeBR/OnUpgrade: Fading Glow on host + Bezier.Part flight (Trail on, particle :Emit bursts),
	then EmitOnFinish burst and Trail off at path end.
	Level Up vfx: one-shot weld on the local character (not during workout).
	Workout: looping Lines only from that template — no start burst / sparks.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local OtherVfxController = {}

local LIFETIME_SEC = 5
local UPGRADE_LIFETIME_SEC = 6.5
local BEZIER_DURATION = 0.7
-- One frame+ after Clone/Parent so particle textures can load before Emit.
local EMIT_SETTLE_SEC = 0.08
local DEFAULT_EMIT_FALLBACK = 16

local function easeOutCubic(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u
end

local function cubicBezier3(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u = 1 - t
	local uu = u * u
	local tt = t * t
	return (uu * u) * p0 + (3 * uu * t) * p1 + (3 * u * tt) * p2 + (tt * t) * p3
end

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
local function emitAll(root: Instance, skipUnder: Instance?, opts: { noLights: boolean? }?)
	local noLights = opts ~= nil and opts.noLights == true
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
		elseif not noLights and (inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight")) then
			flashLight(inst)
		end
	end

	visit(root)
	for _, d in root:GetDescendants() do
		visit(d)
	end
	playSounds(root)
end

local function stripLights(root: Instance)
	local function kill(inst: Instance)
		if inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			inst.Enabled = false
			inst:Destroy()
		end
	end
	kill(root)
	for _, d in root:GetDescendants() do
		kill(d)
	end
end

local function scaleParticleSizes(root: Instance, mult: number)
	if mult == 1 then
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			local keypoints = d.Size.Keypoints
			local scaled: { NumberSequenceKeypoint } = {}
			for _, kp in keypoints do
				table.insert(scaled, NumberSequenceKeypoint.new(kp.Time, kp.Value * mult, kp.Envelope * mult))
			end
			d.Size = NumberSequence.new(scaled)
		end
	end
	if root:IsA("ParticleEmitter") then
		local keypoints = root.Size.Keypoints
		local scaled: { NumberSequenceKeypoint } = {}
		for _, kp in keypoints do
			table.insert(scaled, NumberSequenceKeypoint.new(kp.Time, kp.Value * mult, kp.Envelope * mult))
		end
		root.Size = NumberSequence.new(scaled)
	end
end

type BezierKnot = {
	i: number,
	p: Vector3,
	t0: Vector3?,
	t1: Vector3?,
}

local function worldPosOf(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	end
	if inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	local att = inst:FindFirstChildWhichIsA("Attachment", true)
	if att then
		return att.WorldPosition
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.Position
	end
	return nil
end

local function findNamedWorldPos(parent: Instance, name: string): Vector3?
	local child = parent:FindFirstChild(name)
	if not child then
		return nil
	end
	return worldPosOf(child)
end

--- Collect numbered Points with optional T0/T1 tangent handles (plugin Bezier layout).
local function collectBezierKnots(pointsFolder: Instance): { BezierKnot }
	local numbered: { BezierKnot } = {}
	for _, child in pointsFolder:GetChildren() do
		local idx = tonumber(child.Name)
		if not idx then
			continue
		end
		local pos = worldPosOf(child)
		if not pos then
			continue
		end
		table.insert(numbered, {
			i = idx,
			p = pos,
			t0 = findNamedWorldPos(child, "T0"),
			t1 = findNamedWorldPos(child, "T1"),
		})
	end
	table.sort(numbered, function(a, b)
		return a.i < b.i
	end)
	return numbered
end

local function sampleBezierPath(knots: { BezierKnot }, alpha: number): Vector3
	if #knots == 0 then
		return Vector3.zero
	end
	if #knots == 1 then
		return knots[1].p
	end
	local t = math.clamp(alpha, 0, 1) * (#knots - 1)
	local i = math.floor(t) + 1
	local f = t - math.floor(t)
	local a = knots[i]
	local b = knots[math.min(i + 1, #knots)]
	local p0 = a.p
	local p3 = b.p
	local p1 = a.t1 or p0:Lerp(p3, 1 / 3)
	local p2 = b.t0 or p0:Lerp(p3, 2 / 3)
	return cubicBezier3(p0, p1, p2, p3, f)
end

--- One-shot ParticleEmitter bursts only — never leave emitters Enabled (plugin burst style).
local function emitParticleBursts(root: Instance, skipUnder: Instance?)
	local function skip(inst: Instance): boolean
		return skipUnder ~= nil and (inst == skipUnder or inst:IsDescendantOf(skipUnder))
	end
	local function emitOne(emitter: ParticleEmitter)
		if skip(emitter) then
			return
		end
		emitter.Enabled = false
		local delayAttr = emitter:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		local countAttr = emitter:GetAttribute("EmitCount")
		local count = if typeof(countAttr) == "number" then math.floor(countAttr) else nil
		local burst = 0
		if typeof(count) == "number" and count > 0 then
			burst = count
		else
			burst = math.max(DEFAULT_EMIT_FALLBACK, math.floor(emitter.Rate))
		end
		task.delay(delaySec, function()
			if not emitter.Parent or burst <= 0 then
				return
			end
			emitter.Enabled = false
			emitter:Emit(burst)
		end)
	end
	if root:IsA("ParticleEmitter") then
		emitOne(root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			emitOne(d)
		end
	end
end

local function setTrailsEnabled(root: Instance, enabled: boolean, skipUnder: Instance?)
	local function skip(inst: Instance): boolean
		return skipUnder ~= nil and (inst == skipUnder or inst:IsDescendantOf(skipUnder))
	end
	for _, d in root:GetDescendants() do
		if skip(d) then
			continue
		end
		if d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = enabled
		end
	end
end

--- Trails need Attachment0 + Attachment1. Specs (Blurred Spec, etc.) live on those same
--- Attachments under Bezier.Part — wire trails, then :Emit() every ParticleEmitter once.
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

	-- Burst every particle under the flight Part (Blurred Spec 21, etc.) — never leave Enabled.
	emitParticleBursts(mover, emitOnFinish)
end

--- Put orphan Trail / ParticleEmitter / Beam onto Attachments under the mover so they
--- actually render from those Attachment slots (plugin layout expects this).
local function nestOrphanFxOntoAttachments(mover: BasePart)
	local attachments: { Attachment } = {}
	for _, ch in mover:GetChildren() do
		if ch:IsA("Attachment") then
			table.insert(attachments, ch)
		end
	end
	if #attachments == 0 then
		local a = Instance.new("Attachment")
		a.Name = "VfxAttachment"
		a.Parent = mover
		table.insert(attachments, a)
	end
	local slot = 1
	for _, ch in mover:GetChildren() do
		if ch:IsA("Trail") or ch:IsA("ParticleEmitter") or ch:IsA("Beam") then
			local att = attachments[((slot - 1) % #attachments) + 1]
			ch.Parent = att
			slot += 1
		end
	end
	local eof = mover:FindFirstChild("EmitOnFinish")
	if eof then
		for _, ch in eof:GetChildren() do
			if ch:IsA("Trail") or ch:IsA("ParticleEmitter") or ch:IsA("Beam") then
				local att = eof:FindFirstChildWhichIsA("Attachment")
				if not att then
					att = Instance.new("Attachment")
					att.Name = "EmitOnFinishAtt"
					att.Parent = eof
				end
				-- EmitOnFinish is often a Folder — Attachment must live on a BasePart.
				-- Parent Attachment to mover and keep emitters under it for the finish burst.
				if eof:IsA("Folder") or eof:IsA("Model") then
					att.Parent = mover
				end
				ch.Parent = att
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

	nestOrphanFxOntoAttachments(mover)

	local knots = collectBezierKnots(pointsFolder)
	if #knots < 2 then
		knots = {
			{ i = 1, p = hostCf.Position, t0 = nil, t1 = nil },
			{
				i = 2,
				p = hostCf.Position + hostCf.UpVector * 4 + hostCf.LookVector * 2,
				t0 = nil,
				t1 = nil,
			},
			{ i = 3, p = hostCf.Position + hostCf.UpVector * 2, t0 = nil, t1 = nil },
		}
	end

	local emitOnFinish = mover:FindFirstChild("EmitOnFinish")
	-- Root glow (Fading Glow) outside Bezier — skip the whole Bezier tree so Part isn't double-fired.
	emitAll(root, bezier, nil)
	-- Wire Trail on Bezier.Part, enable for the flight, :Emit() all Part particles.
	prepareMoverFlightVfx(mover, emitOnFinish)

	mover.CFrame = CFrame.new(knots[1].p)
	local started = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not mover.Parent then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			return
		end
		local raw = math.clamp((os.clock() - started) / BEZIER_DURATION, 0, 1)
		local alpha = easeOutCubic(raw)
		local pos = sampleBezierPath(knots, alpha)
		local look = if alpha < 0.99
			then sampleBezierPath(knots, math.min(1, alpha + 0.04))
			else pos + Vector3.yAxis
		mover.CFrame = CFrame.lookAt(pos, look)
		if raw >= 1 then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			-- Trail/beam off when the flight ends.
			setTrailsEnabled(mover, false, emitOnFinish)
			for _, d in mover:GetDescendants() do
				if emitOnFinish and d:IsDescendantOf(emitOnFinish) then
					continue
				end
				if d:IsA("ParticleEmitter") then
					d.Enabled = false
				end
			end
			-- Finish burst from EmitOnFinish folder.
			if emitOnFinish then
				emitAll(emitOnFinish, nil, nil)
			else
				emitParticleBursts(mover, nil)
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

local function playTemplate(
	pathParts: { string },
	at: CFrame | BasePart,
	lifetimeSec: number?,
	opts: { noLights: boolean?, particleScale: number?, muteSounds: boolean? }?
)
	local template = findTemplate(pathParts)
	if not template then
		warn("[OtherVfxController] missing template:", table.concat(pathParts, "/"))
		return
	end
	local life = lifetimeSec or LIFETIME_SEC
	local clone = template:Clone()
	if opts and opts.noLights then
		stripLights(clone)
	end
	if opts and opts.muteSounds then
		if clone:IsA("Sound") then
			clone:Destroy()
			return
		end
		for _, d in clone:GetDescendants() do
			if d:IsA("Sound") then
				d:Destroy()
			end
		end
	end
	if opts and typeof(opts.particleScale) == "number" then
		scaleParticleSizes(clone, opts.particleScale)
	end
	local placed = placeClone(clone, at)
	local hostCf = if typeof(at) == "CFrame" then at else at.CFrame
	local emitOpts = if opts and opts.noLights then { noLights = true } else nil

	task.delay(EMIT_SETTLE_SEC, function()
		if not clone.Parent then
			return
		end
		local usedBezier = runBezierIfPresent(clone, hostCf)
		if not usedBezier then
			emitAll(clone, nil, emitOpts)
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
			local outCf = cf :: CFrame
			local outSize = Vector3.new(math.max(1.2, size.X), math.max(1.2, size.Y), math.max(1.2, size.Z))
			return outCf, outSize
		end
		local pivotCf: CFrame = bush:GetPivot()
		local padSize = Vector3.new(4, 4, 4)
		return pivotCf, padSize
	end

	local host = resolveBushHost(bush)
	if typeof(host) == "CFrame" then
		local hostCf: CFrame = host
		local padSize = Vector3.new(4, 4, 4)
		return hostCf, padSize
	end
	local part = host :: BasePart
	local padSize = Vector3.new(4, 4, 4)
	return part.CFrame, padSize
end

local function sampleBushVolumePoints(bush: Instance, count: number): { CFrame }
	local volumeCf, size = getBushVolume(bush)
	-- Use most of the visual volume so FX isn't stuck at the crown/center.
	local half = size * 0.46
	local points: { CFrame } = {}
	if count <= 0 then
		return points
	end

	-- Stratified shell + interior samples so each pulse covers the bush.
	local layers = {
		{ r = 0.92, n = math.max(1, math.floor(count * 0.55 + 0.5)) },
		{ r = 0.55, n = math.max(0, math.floor(count * 0.3 + 0.5)) },
		{ r = 0.2, n = 0 },
	}
	local assigned = 0
	for i, layer in ipairs(layers) do
		if i == #layers then
			layer.n = math.max(0, count - assigned)
		else
			layer.n = math.min(layer.n, count - assigned)
			assigned += layer.n
		end
	end

	for _, layer in ipairs(layers) do
		for i = 1, layer.n do
			local yaw = ((i - 1) / math.max(layer.n, 1)) * math.pi * 2 + math.random() * 0.7
			local pitch = (math.random() * 2 - 1) * 0.85
			local dir = Vector3.new(
				math.cos(yaw) * math.cos(pitch),
				math.sin(pitch),
				math.sin(yaw) * math.cos(pitch)
			)
			local radius = layer.r * (0.72 + math.random() * 0.28)
			local offset = Vector3.new(
				dir.X * half.X * radius,
				dir.Y * half.Y * radius,
				dir.Z * half.Z * radius
			)
			table.insert(points, volumeCf * CFrame.new(offset))
		end
	end

	-- Shuffle lightly so consecutive pulses don't look identical.
	for i = #points, 2, -1 do
		local j = math.random(1, i)
		points[i], points[j] = points[j], points[i]
	end
	return points
end

local BUSH_VFX_OPTS = { noLights = true }

local bushShakeToken = 0
local bushShakeClone: Instance? = nil
local bushShakeHost: BasePart? = nil
local BUSH_SHAKE_PULSE_SEC = 0.55

local function bushCenterCf(bush: Instance): CFrame
	local cf, _size = getBushVolume(bush)
	return cf
end

local function bushVfxHostPart(bush: Instance): BasePart?
	if bush:IsA("BasePart") then
		return bush
	end
	if bush:IsA("Model") then
		return bush.PrimaryPart or bush:FindFirstChildWhichIsA("BasePart", true)
	end
	return bush:FindFirstChildWhichIsA("BasePart", true)
end

local function clearBushShakeClone()
	if bushShakeClone then
		bushShakeClone:Destroy()
		bushShakeClone = nil
	end
	bushShakeHost = nil
end

local function ensureBushShakeClone(bush: Instance): Instance?
	if bushShakeClone and bushShakeClone.Parent and bushShakeHost and bushShakeHost.Parent then
		return bushShakeClone
	end
	clearBushShakeClone()
	local template = findTemplate({ "Bush Opening", "BushEffect" })
	if not template then
		warn("[OtherVfxController] missing template: Bush Opening/BushEffect")
		return nil
	end
	local hostPart = bushVfxHostPart(bush)
	if not hostPart then
		warn("[OtherVfxController] no host part for bush VFX")
		return nil
	end
	local clone = template:Clone()
	stripLights(clone)
	disableAllFx(clone)
	placeClone(clone, hostPart)
	bushShakeClone = clone
	bushShakeHost = hostPart
	return clone
end

--- Leaves/debris while searching — single BushEffect on the bush, pulsed Emit (not scattered clones).
function OtherVfxController.playBushSearchShake(bush: Instance)
	bushShakeToken += 1
	local token = bushShakeToken
	local function pulse()
		if token ~= bushShakeToken or not bush.Parent then
			return
		end
		local clone = ensureBushShakeClone(bush)
		if not clone or not clone.Parent then
			return
		end
		task.defer(function()
			if token ~= bushShakeToken or not clone.Parent then
				return
			end
			emitAll(clone, nil, { noLights = true })
		end)
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
	clearBushShakeClone()
end

--- Final burst when search completes — one BushEffectBurst at the bush center.
function OtherVfxController.playBushOpenedBurst(bush: Instance)
	OtherVfxController.stopBushSearchShake()
	playTemplate({ "Bush Opening", "BushEffectBurst" }, bushCenterCf(bush), nil, BUSH_VFX_OPTS)
end

function OtherVfxController.playLuckyBlockOpen(at: CFrame | BasePart)
	-- Visual burst only — no choir/angelic template SFX (ground smash plays separately).
	playTemplate({ "Bush Opening", "Luckyblock" }, at, nil, { muteSounds = true })
end

--- Upgrade VFX: parent Attachments onto the brainrot BasePart, then run Bezier off those slots.
function OtherVfxController.playBrainrotUpgrade(at: CFrame | BasePart)
	local hostPart: BasePart? = nil
	local hostCf: CFrame
	if typeof(at) == "CFrame" then
		hostCf = at
	else
		hostPart = at
		hostCf = at.CFrame
	end

	local template = findTemplate({ "UpgradeBR", "OnUpgrade" })
	if not template then
		warn("[OtherVfxController] missing template: UpgradeBR/OnUpgrade")
		return
	end

	local clone = template:Clone()
	stabilizeParts(clone)
	disableAllFx(clone)

	if not hostPart then
		local anchor = Instance.new("Part")
		anchor.Name = "OtherVfxUpgradeAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.4, 0.4, 0.4)
		anchor.CFrame = hostCf
		anchor.Parent = Workspace
		hostPart = anchor
		Debris:AddItem(anchor, UPGRADE_LIFETIME_SEC)
	end

	local movedAtts: { Attachment } = {}

	if clone:IsA("BasePart") then
		local bezier = clone:FindFirstChild("Bezier")
		local mover = if bezier then bezier:FindFirstChild("Part") else nil
		local freeMover = if mover and mover:IsA("BasePart") then mover :: BasePart else nil
		relocatePartTree(clone, hostCf)
		if freeMover then
			weldStaticPartsToRoot(clone, freeMover)
			freeMover.Anchored = true
		end

		-- Put root Attachments (Fading Glow) directly on the brainrot part.
		for _, ch in clone:GetChildren() do
			if ch:IsA("Attachment") then
				local world = ch.WorldCFrame
				ch.Parent = hostPart
				ch.WorldCFrame = world
				ch:SetAttribute("__UpgradeVfx", true)
				table.insert(movedAtts, ch)
				Debris:AddItem(ch, UPGRADE_LIFETIME_SEC)
			end
		end

		clone.Anchored = false
		clone.Parent = hostPart
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hostPart
		weld.Part1 = clone
		weld.Parent = clone
	elseif clone:IsA("Model") then
		clone.Parent = Workspace
		clone:PivotTo(hostCf)
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			for _, ch in primary:GetChildren() do
				if ch:IsA("Attachment") then
					local world = ch.WorldCFrame
					ch.Parent = hostPart
					ch.WorldCFrame = world
					ch:SetAttribute("__UpgradeVfx", true)
					table.insert(movedAtts, ch)
					Debris:AddItem(ch, UPGRADE_LIFETIME_SEC)
				end
			end
			primary.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hostPart
			weld.Part1 = primary
			weld.Parent = primary
		end
	else
		clone.Parent = hostPart
	end

	task.delay(EMIT_SETTLE_SEC, function()
		-- Fading Glow attachments were reparented onto the brainrot — burst them once.
		for _, att in movedAtts do
			if att.Parent then
				emitAll(att, nil, nil)
			end
		end
		if clone.Parent then
			local usedBezier = runBezierIfPresent(clone, hostPart.CFrame)
			if not usedBezier then
				emitAll(clone, nil, nil)
			end
		end
	end)

	Debris:AddItem(clone, UPGRADE_LIFETIME_SEC)
end

local LEVEL_UP_HOLD_SEC = 1.0
local LEVEL_UP_FADE_SEC = 0.35

local BODY_PART_ALIASES: { [string]: { string } } = {
	Torso = { "UpperTorso", "Torso", "HumanoidRootPart" },
	Head = { "Head" },
	["Left Arm"] = { "LeftUpperArm", "Left Arm" },
	["Right Arm"] = { "RightUpperArm", "Right Arm" },
	["Left Leg"] = { "LeftUpperLeg", "Left Leg" },
	["Right Leg"] = { "RightUpperLeg", "Right Leg" },
	HumanoidRootPart = { "HumanoidRootPart" },
}

local levelUpToken = 0
local activeLevelUpRoot: Instance? = nil
local activeWorkoutLinesRoot: Instance? = nil
local workoutAuraEnabled = false

local function findCharacterPart(character: Model, dummyName: string): BasePart?
	local aliases = BODY_PART_ALIASES[dummyName]
	if aliases then
		for _, name in aliases do
			local inst = character:FindFirstChild(name)
			if inst and inst:IsA("BasePart") then
				return inst
			end
		end
	end
	local exact = character:FindFirstChild(dummyName)
	if exact and exact:IsA("BasePart") then
		return exact
	end
	return nil
end

local function isLineAuraName(name: string): boolean
	local n = string.lower(name)
	return n == "lines" or n == "lineb" or n == "line"
end

local function setFxEnabled(root: Instance, on: boolean)
	local function apply(inst: Instance)
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
			inst.Enabled = on
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			inst.Enabled = on
		end
	end
	apply(root)
	for _, d in root:GetDescendants() do
		apply(d)
	end
end

local function pruneToLinesOnly(root: Instance)
	local toDestroy: { Instance } = {}
	for _, d in root:GetDescendants() do
		if
			d:IsA("ParticleEmitter")
			or d:IsA("Beam")
			or d:IsA("Trail")
			or d:IsA("PointLight")
			or d:IsA("SpotLight")
			or d:IsA("SurfaceLight")
			or d:IsA("Sound")
		then
			local parentName = if d.Parent then d.Parent.Name else ""
			if not isLineAuraName(d.Name) and not isLineAuraName(parentName) then
				table.insert(toDestroy, d)
			end
		end
	end
	for _, inst in toDestroy do
		if inst.Parent then
			inst:Destroy()
		end
	end
end

local function applyWorkoutLinesState()
	if not activeWorkoutLinesRoot or not activeWorkoutLinesRoot.Parent then
		return
	end
	for _, d in activeWorkoutLinesRoot:GetDescendants() do
		if isLineAuraName(d.Name) then
			setFxEnabled(d, workoutAuraEnabled)
		end
	end
end

local function stripStaleCharacterVfx(character: Model)
	local stale = character:FindFirstChild("LevelUpVfx")
	if stale then
		stale:Destroy()
	end
	for _, d in character:GetDescendants() do
		if d.Name == "Stable" and d:GetAttribute("__LevelUpVfx") == true then
			d:Destroy()
		end
	end
end

local function ensureWorldFolder(): Folder
	local existing = Workspace:FindFirstChild("LevelUpVfxWorld")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LevelUpVfxWorld"
	folder.Parent = Workspace
	return folder
end

local function destroyWorkoutLines()
	if activeWorkoutLinesRoot and activeWorkoutLinesRoot.Parent then
		activeWorkoutLinesRoot:Destroy()
	end
	activeWorkoutLinesRoot = nil
	local folder = Workspace:FindFirstChild("WorkoutLinesVfxWorld")
	if folder then
		folder:Destroy()
	end
end

local function weldCloneToCharacter(clone: Instance, character: Model): boolean
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		hrp = character:FindFirstChildWhichIsA("BasePart")
	end
	if not hrp then
		return false
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			local host = findCharacterPart(character, d.Name) or hrp
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = false
			d.Transparency = 1
			d.CFrame = host.CFrame
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = host
			weld.Part1 = d
			weld.Parent = d
		end
	end
	return true
end

local function cloneLevelUpTemplate(): Instance?
	local template = findTemplate({ "Level Up vfx" })
	if not template then
		warn("[OtherVfxController] missing template: Level Up vfx")
		return nil
	end
	local clone = template:Clone()
	for _, d in clone:GetDescendants() do
		if d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("Motor6D") or d:IsA("Weld") then
			d:Destroy()
		end
	end
	return clone
end

function OtherVfxController.clearLevelUpVfx()
	levelUpToken += 1
	if activeLevelUpRoot and activeLevelUpRoot.Parent then
		activeLevelUpRoot:Destroy()
	end
	activeLevelUpRoot = nil
	local folder = Workspace:FindFirstChild("LevelUpVfxWorld")
	if folder then
		folder:Destroy()
	end
end

--- Legacy lines aura — ComboVFX world auras replaced this.
function OtherVfxController.setWorkoutAuraEnabled(_on: boolean)
	workoutAuraEnabled = false
	destroyWorkoutLines()
	local folder = Workspace:FindFirstChild("WorkoutLinesVfxWorld")
	if folder then
		folder:Destroy()
	end
end

local COMBO_TEXT_MIN = 6
local COMBO_AURA_MIN = 5
local COMBO_FADE_IN_SEC = 0.42
local COMBO_FADE_OUT_SEC = 0.28
local COMBO_POP_IN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COMBO_POP_SETTLE = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COMBO_FADE_TWEEN = TweenInfo.new(COMBO_FADE_IN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COMBO_FADE_OUT_TWEEN = TweenInfo.new(COMBO_FADE_OUT_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type ComboWatch = {
	conns: { RBXScriptConnection },
	auraRoot: Instance?,
	auraName: string?,
	billboard: BillboardGui?,
	label: TextLabel?,
	scale: UIScale?,
	lastShown: number,
	token: number,
}

local comboWatches: { [Player]: ComboWatch } = {}
local comboWatchStarted = false

local function comboAuraFolderName(n: number): string?
	if n < COMBO_AURA_MIN then
		return nil
	end
	if n < 15 then
		return "5-15"
	end
	if n < 30 then
		return "15-30"
	end
	if n < 45 then
		return "30-45"
	end
	return "45+"
end

local comboTemplateWarned = false

local function findComboVfxFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
	local combo = assets and assets:FindFirstChild("ComboVFX")
	return combo
end

local function waitForComboVfxFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("EssentialAssets")
		or ReplicatedStorage:WaitForChild("EssentialAssets", 30)
	if not assets then
		return nil
	end
	local combo = assets:FindFirstChild("ComboVFX") or assets:WaitForChild("ComboVFX", 30)
	return combo
end

local function comboNumber(plr: Player): number
	local v = plr:GetAttribute("WorkoutCombo")
	if typeof(v) == "number" then
		return math.max(0, math.floor(v))
	end
	return 0
end

local function comboTextColor(n: number): Color3
	if n >= 50 then
		return Color3.fromRGB(255, 236, 160)
	end
	if n >= 45 then
		return Color3.fromRGB(255, 120, 255)
	end
	if n >= 30 then
		return Color3.fromRGB(255, 90, 70)
	end
	if n >= 15 then
		return Color3.fromRGB(255, 160, 60)
	end
	return Color3.fromRGB(255, 220, 80)
end

local function snapshotComboFx(root: Instance)
	local function snap(inst: Instance)
		if inst:IsA("ParticleEmitter") then
			local rate = inst.Rate
			if rate <= 0 then
				local count = inst:GetAttribute("EmitCount")
				if typeof(count) == "number" and count > 0 then
					rate = math.clamp(count, 4, 48)
				else
					rate = 14
				end
			end
			inst:SetAttribute("__ComboRate", rate)
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			local bright = inst.Brightness
			if bright <= 0 then
				bright = 2
			end
			inst:SetAttribute("__ComboBright", bright)
		elseif inst:IsA("Beam") then
			inst:SetAttribute("__ComboW0", inst.Width0)
			inst:SetAttribute("__ComboW1", inst.Width1)
		end
	end
	snap(root)
	for _, d in root:GetDescendants() do
		snap(d)
	end
end

local function applyComboFade(root: Instance, alpha: number)
	local a = math.clamp(alpha, 0, 1)
	local function apply(inst: Instance)
		if inst:IsA("ParticleEmitter") then
			local orig = inst:GetAttribute("__ComboRate")
			if typeof(orig) == "number" then
				inst.Rate = orig * a
			end
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			local orig = inst:GetAttribute("__ComboBright")
			if typeof(orig) == "number" then
				inst.Brightness = orig * a
			end
		elseif inst:IsA("Beam") then
			local w0 = inst:GetAttribute("__ComboW0")
			local w1 = inst:GetAttribute("__ComboW1")
			if typeof(w0) == "number" then
				inst.Width0 = w0 * a
			end
			if typeof(w1) == "number" then
				inst.Width1 = w1 * a
			end
		end
	end
	apply(root)
	for _, d in root:GetDescendants() do
		apply(d)
	end
end

local function tweenComboFade(root: Instance, fromAlpha: number, toAlpha: number, info: TweenInfo)
	applyComboFade(root, fromAlpha)
	setFxEnabled(root, true)
	local function tweenInst(inst: Instance)
		if inst:IsA("ParticleEmitter") then
			local orig = inst:GetAttribute("__ComboRate")
			if typeof(orig) == "number" then
				TweenService:Create(inst, info, { Rate = orig * toAlpha }):Play()
			end
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			local orig = inst:GetAttribute("__ComboBright")
			if typeof(orig) == "number" then
				TweenService:Create(inst, info, { Brightness = orig * toAlpha }):Play()
			end
		elseif inst:IsA("Beam") then
			local w0 = inst:GetAttribute("__ComboW0")
			local w1 = inst:GetAttribute("__ComboW1")
			local goals: { [string]: number } = {}
			if typeof(w0) == "number" then
				goals.Width0 = w0 * toAlpha
			end
			if typeof(w1) == "number" then
				goals.Width1 = w1 * toAlpha
			end
			if next(goals) then
				TweenService:Create(inst, info, goals):Play()
			end
		end
	end
	tweenInst(root)
	for _, d in root:GetDescendants() do
		tweenInst(d)
	end
end

local function parentLooseComboAttachments(clone: Instance, character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local back = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or hrp
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	local loose: { Attachment } = {}
	if clone:IsA("Attachment") then
		table.insert(loose, clone)
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("Attachment") and d.Parent and not d.Parent:IsA("BasePart") then
			table.insert(loose, d)
		end
	end
	for _, att in loose do
		local host: Instance? = hrp
		local n = string.lower(att.Name)
		if string.find(n, "back", 1, true) and back and back:IsA("BasePart") then
			host = back
		end
		att.Parent = host
	end
end

local function cloneComboAura(folderName: string): Instance?
	local root = findComboVfxFolder()
	local template = root and root:FindFirstChild(folderName)
	if not template then
		if not comboTemplateWarned then
			comboTemplateWarned = true
			warn("[OtherVfxController] ComboVFX template missing:", folderName, "root=", root)
		end
		return nil
	end
	local clone = template:Clone()
	clone.Name = "ComboAura_" .. folderName
	for _, d in clone:GetDescendants() do
		if d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	return clone
end

local function weldComboCloneToCharacter(clone: Instance, character: Model): boolean
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		hrp = character:FindFirstChildWhichIsA("BasePart")
	end
	if not hrp then
		return false
	end
	if clone:IsA("Model") then
		pcall(function()
			(clone :: Model):PivotTo(hrp.CFrame)
		end)
	elseif clone:IsA("BasePart") then
		clone.CFrame = hrp.CFrame
	else
		local first = clone:FindFirstChildWhichIsA("BasePart", true)
		if first then
			local delta = hrp.CFrame * first.CFrame:Inverse()
			for _, d in clone:GetDescendants() do
				if d:IsA("BasePart") then
					d.CFrame = delta * d.CFrame
				end
			end
		end
	end
	local function prepPart(part: BasePart)
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false
		part.Transparency = 1
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hrp
		weld.Part1 = part
		weld.Parent = part
	end
	if clone:IsA("BasePart") then
		prepPart(clone)
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			prepPart(d)
		end
	end
	return true
end

local function destroyComboAura(watch: ComboWatch, fade: boolean)
	local root = watch.auraRoot
	watch.auraRoot = nil
	watch.auraName = nil
	if not (root and root.Parent) then
		return
	end
	if fade then
		local token = watch.token
		tweenComboFade(root, 1, 0, COMBO_FADE_OUT_TWEEN)
		task.delay(COMBO_FADE_OUT_SEC, function()
			if watch.token ~= token then
				return
			end
			if root.Parent then
				root:Destroy()
			end
		end)
		return
	end
	root:Destroy()
end

local function attachComboAura(plr: Player, watch: ComboWatch, character: Model, folderName: string)
	if watch.auraName == folderName and watch.auraRoot and watch.auraRoot.Parent then
		return
	end
	destroyComboAura(watch, watch.auraRoot ~= nil)
	local clone = cloneComboAura(folderName)
	if not clone then
		return
	end
	clone.Parent = character
	weldComboCloneToCharacter(clone, character)
	parentLooseComboAttachments(clone, character)
	snapshotComboFx(clone)
	disableAllFx(clone)
	watch.auraRoot = clone
	watch.auraName = folderName
	tweenComboFade(clone, 0, 1, COMBO_FADE_TWEEN)
end

local function ensureComboBillboard(character: Model, watch: ComboWatch): (TextLabel?, UIScale?)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil, nil
	end
	if watch.billboard and watch.billboard.Parent == hrp and watch.label and watch.scale then
		-- Studs size so the counter shrinks with the character when the camera pulls out.
		watch.billboard.Size = UDim2.new(4.2, 0, 1.35, 0)
		return watch.label, watch.scale
	end
	if watch.billboard then
		watch.billboard:Destroy()
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "WorkoutWorldCombo"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 90
	bb.Size = UDim2.new(4.2, 0, 1.35, 0)
	bb.StudsOffset = Vector3.new(0, 3.35, 0)
	bb.Adornee = hrp
	bb.ResetOnSpawn = false

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = bb

	local label = Instance.new("TextLabel")
	label.Name = "Combo"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(255, 220, 80)
	label.Parent = bb
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(20, 8, 4)
	stroke.Thickness = 2.4
	stroke.Transparency = 0.05
	stroke.Parent = label

	bb.Parent = hrp
	watch.billboard = bb
	watch.label = label
	watch.scale = scale
	return label, scale
end

local function popComboLabel(watch: ComboWatch)
	local scale = watch.scale
	if not scale then
		return
	end
	scale.Scale = 0.42
	local tweenIn = TweenService:Create(scale, COMBO_POP_IN, { Scale = 1.18 })
	tweenIn:Play()
	tweenIn.Completed:Once(function()
		if watch.scale == scale and scale.Parent then
			TweenService:Create(scale, COMBO_POP_SETTLE, { Scale = 1 }):Play()
		end
	end)
end

local function refreshComboVisual(plr: Player)
	local watch = comboWatches[plr]
	if not watch then
		return
	end
	local workoutOn = plr:GetAttribute("WorkoutActive") == true
	local n = comboNumber(plr)
	local character = plr.Character
	if not workoutOn or not character or not character.Parent then
		if watch.billboard then
			watch.billboard.Enabled = false
		end
		destroyComboAura(watch, true)
		watch.lastShown = 0
		return
	end

	local folderName = comboAuraFolderName(n)
	if folderName then
		attachComboAura(plr, watch, character, folderName)
	else
		destroyComboAura(watch, true)
	end

	local label, scale = ensureComboBillboard(character, watch)
	if not label then
		return
	end
	if n >= COMBO_TEXT_MIN then
		if watch.billboard then
			watch.billboard.Enabled = true
		end
		label.Text = "x" .. tostring(n)
		label.TextColor3 = comboTextColor(n)
		if n > watch.lastShown then
			popComboLabel(watch)
		elseif scale then
			scale.Scale = 1
		end
		watch.lastShown = n
	else
		if watch.billboard then
			watch.billboard.Enabled = false
		end
		watch.lastShown = n
	end
end

local function unbindComboPlayer(plr: Player)
	local watch = comboWatches[plr]
	if not watch then
		return
	end
	watch.token += 1
	for _, c in watch.conns do
		c:Disconnect()
	end
	if watch.billboard then
		watch.billboard:Destroy()
	end
	destroyComboAura(watch, false)
	comboWatches[plr] = nil
end

local function bindComboPlayer(plr: Player)
	if comboWatches[plr] then
		refreshComboVisual(plr)
		return
	end
	local watch: ComboWatch = {
		conns = {},
		auraRoot = nil,
		auraName = nil,
		billboard = nil,
		label = nil,
		scale = nil,
		lastShown = 0,
		token = 0,
	}
	comboWatches[plr] = watch
	table.insert(
		watch.conns,
		plr:GetAttributeChangedSignal("WorkoutCombo"):Connect(function()
			refreshComboVisual(plr)
		end)
	)
	table.insert(
		watch.conns,
		plr:GetAttributeChangedSignal("WorkoutActive"):Connect(function()
			refreshComboVisual(plr)
		end)
	)
	table.insert(
		watch.conns,
		plr.CharacterAdded:Connect(function()
			watch.token += 1
			if watch.auraRoot and watch.auraRoot.Parent then
				watch.auraRoot:Destroy()
			end
			watch.auraRoot = nil
			watch.auraName = nil
			if watch.billboard then
				watch.billboard:Destroy()
			end
			watch.billboard = nil
			watch.label = nil
			watch.scale = nil
			watch.lastShown = 0
			task.defer(function()
				refreshComboVisual(plr)
			end)
		end)
	)
	refreshComboVisual(plr)
end

function OtherVfxController.startComboWorldWatch()
	if comboWatchStarted then
		return
	end
	comboWatchStarted = true
	Players.PlayerAdded:Connect(bindComboPlayer)
	Players.PlayerRemoving:Connect(unbindComboPlayer)
	for _, plr in Players:GetPlayers() do
		bindComboPlayer(plr)
	end
	task.spawn(function()
		waitForComboVfxFolder()
		for plr, watch in comboWatches do
			watch.auraName = nil
			if watch.auraRoot and watch.auraRoot.Parent then
				watch.auraRoot:Destroy()
			end
			watch.auraRoot = nil
			refreshComboVisual(plr)
		end
	end)
end

--- One-shot body VFX on real level-ups (including mid-workout).
function OtherVfxController.playLevelUpOnCharacter(character: Model)
	if not character or not character.Parent then
		return
	end

	stripStaleCharacterVfx(character)
	levelUpToken += 1
	local token = levelUpToken
	if activeLevelUpRoot and activeLevelUpRoot.Parent then
		activeLevelUpRoot:Destroy()
	end

	local clone = cloneLevelUpTemplate()
	if not clone then
		return
	end
	clone.Name = "LevelUpVfx"
	clone:SetAttribute("__LevelUpVfx", true)

	clone.Parent = ensureWorldFolder()
	if not weldCloneToCharacter(clone, character) then
		clone:Destroy()
		return
	end
	activeLevelUpRoot = clone

	disableAllFx(clone)
	task.delay(EMIT_SETTLE_SEC, function()
		if token ~= levelUpToken or not clone.Parent then
			return
		end
		emitAll(clone, nil, nil)
		playSounds(clone)
	end)

	task.delay(LEVEL_UP_HOLD_SEC, function()
		if token ~= levelUpToken or not clone.Parent then
			return
		end
		disableAllFx(clone)
		for _, d in clone:GetDescendants() do
			if d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
				TweenService:Create(d, TweenInfo.new(LEVEL_UP_FADE_SEC), { Brightness = 0 }):Play()
			end
		end
		task.delay(LEVEL_UP_FADE_SEC, function()
			if token ~= levelUpToken or not clone.Parent then
				return
			end
			if clone.Parent then
				clone:Destroy()
			end
			if activeLevelUpRoot == clone then
				activeLevelUpRoot = nil
			end
		end)
	end)
end

return OtherVfxController
