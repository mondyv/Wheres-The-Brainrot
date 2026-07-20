-- [ACTIVE] OtherVfxController
--[[
	One-shot VFX from ReplicatedStorage.EssentialAssets.OtherVFX.
	Enables every ParticleEmitter / Trail / Beam / Light in the clone, then Emit()
	using EmitCount / EmitDelay / EmitDuration attributes when present.
	Skips continuous BushEffect; uses BushEffectBurst / Luckyblock / UpgradeBR.OnUpgrade.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local OtherVfxController = {}

local LIFETIME_SEC = 5.5
local DEFAULT_EMIT = 28
local BEZIER_DURATION = 0.55
local DEFAULT_EMIT_DURATION = 0.85

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

local function activateLight(light: PointLight | SpotLight | SurfaceLight)
	light.Enabled = true
	local peak = light.Brightness
	if peak <= 0 then
		peak = 2
		light.Brightness = peak
	end
	task.delay(math.max(0.4, DEFAULT_EMIT_DURATION), function()
		if light.Parent then
			light.Enabled = false
		end
	end)
end

--- Enable every VFX under root, then burst Emit on particle emitters.
local function activateAllVfx(root: Instance, defaultCount: number, skipUnder: Instance?)
	local function skip(inst: Instance): boolean
		return skipUnder ~= nil and (inst == skipUnder or inst:IsDescendantOf(skipUnder))
	end

	local function activateEmitter(emitter: ParticleEmitter)
		if skip(emitter) then
			return
		end
		local delayAttr = emitter:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		local countAttr = emitter:GetAttribute("EmitCount")
		local count = if typeof(countAttr) == "number" then math.max(1, math.floor(countAttr)) else defaultCount
		local durAttr = emitter:GetAttribute("EmitDuration")
		local dur = if typeof(durAttr) == "number" then math.max(0, durAttr) else DEFAULT_EMIT_DURATION

		local function run()
			if not emitter.Parent then
				return
			end
			-- Enable first so rate-based + style layers show; Emit for the burst spike.
			emitter.Enabled = true
			emitter:Emit(count)
			if dur > 0 then
				task.delay(dur, function()
					if emitter.Parent then
						emitter.Enabled = false
					end
				end)
			end
		end

		if delaySec > 0 then
			task.delay(delaySec, run)
		else
			run()
		end
	end

	local function activateInst(inst: Instance)
		if skip(inst) then
			return
		end
		if inst:IsA("ParticleEmitter") then
			activateEmitter(inst)
		elseif inst:IsA("Trail") or inst:IsA("Beam") then
			inst.Enabled = true
			task.delay(DEFAULT_EMIT_DURATION + 0.4, function()
				if inst.Parent then
					(inst :: Trail).Enabled = false
				end
			end)
		elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
			activateLight(inst)
		end
	end

	activateInst(root)
	for _, d in root:GetDescendants() do
		activateInst(d)
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

local function runBezierIfPresent(root: Instance, hostCf: CFrame): boolean
	local bezier = root:FindFirstChild("Bezier")
	if not bezier then
		return false
	end
	local pointsFolder = bezier:FindFirstChild("Points")
	local mover = bezier:FindFirstChild("Part")
	if not pointsFolder or not mover or not mover:IsA("BasePart") then
		return false
	end

	local points = collectBezierWorldPoints(pointsFolder)
	if #points < 2 then
		points = {}
		local origin = hostCf.Position
		table.insert(points, origin)
		table.insert(points, origin + hostCf.UpVector * 4 + hostCf.LookVector * 2)
		table.insert(points, origin + hostCf.UpVector * 2)
	end

	local emitOnFinish = mover:FindFirstChild("EmitOnFinish")
	-- Enable everything except EmitOnFinish (that bursts at path end).
	activateAllVfx(root, DEFAULT_EMIT, emitOnFinish)

	for _, d in mover:GetDescendants() do
		if d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = true
		elseif d:IsA("ParticleEmitter") and not (emitOnFinish and d:IsDescendantOf(emitOnFinish)) then
			d.Enabled = true
		end
	end

	mover.Anchored = true
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
				activateAllVfx(emitOnFinish, DEFAULT_EMIT, nil)
			else
				activateAllVfx(mover, DEFAULT_EMIT, nil)
			end
			task.delay(0.5, function()
				if not mover.Parent then
					return
				end
				for _, d in mover:GetDescendants() do
					if d:IsA("Trail") or d:IsA("Beam") then
						d.Enabled = false
					end
				end
			end)
		end
	end)
	return true
end

local function placeClone(clone: Instance, at: CFrame | BasePart): Instance
	stabilizeParts(clone)
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
		clone.CFrame = cf
		if hostPart then
			clone.Anchored = false
			clone.Parent = hostPart
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
		clone:PivotTo(cf)
		clone.Parent = Workspace
		if hostPart then
			local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
			if primary then
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
	if hostPart then
		anchor.Anchored = false
		anchor.Parent = hostPart
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hostPart
		weld.Part1 = anchor
		weld.Parent = anchor
	else
		anchor.Parent = Workspace
	end
	clone.Parent = anchor
	anchor:SetAttribute("__OtherVfxDebris", true)
	Debris:AddItem(anchor, LIFETIME_SEC)
	return anchor
end

local function playTemplate(pathParts: { string }, at: CFrame | BasePart, defaultEmit: number?)
	local template = findTemplate(pathParts)
	if not template then
		warn("[OtherVfxController] missing template:", table.concat(pathParts, "/"))
		return
	end
	local clone = template:Clone()
	local placed = placeClone(clone, at)
	local hostCf = if typeof(at) == "CFrame" then at else at.CFrame
	-- Defer one frame so Attachment WorldCFrames settle after parenting.
	task.defer(function()
		if not clone.Parent then
			return
		end
		local usedBezier = runBezierIfPresent(clone, hostCf)
		if not usedBezier then
			activateAllVfx(clone, defaultEmit or DEFAULT_EMIT, nil)
		end
	end)
	if clone:IsA("Attachment") and typeof(at) ~= "CFrame" then
		Debris:AddItem(clone, LIFETIME_SEC)
	elseif placed.Name == "OtherVfxAnchor" then
		if not placed:GetAttribute("__OtherVfxDebris") then
			placed:SetAttribute("__OtherVfxDebris", true)
			Debris:AddItem(placed, LIFETIME_SEC)
		end
	else
		Debris:AddItem(placed, LIFETIME_SEC)
	end
end

local function resolveBushCFrame(bush: Instance): CFrame
	if bush:IsA("Model") then
		return bush:GetPivot()
	end
	if bush:IsA("BasePart") then
		return bush.CFrame
	end
	local part = bush:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.CFrame
	end
	return CFrame.new()
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
	return resolveBushCFrame(bush)
end

function OtherVfxController.playBushOpenedBurst(bush: Instance)
	playTemplate({ "Bush Opening", "BushEffectBurst" }, resolveBushHost(bush), 36)
end

function OtherVfxController.playLuckyBlockOpen(at: CFrame | BasePart)
	playTemplate({ "Bush Opening", "Luckyblock" }, at, 40)
end

function OtherVfxController.playBrainrotUpgrade(at: CFrame | BasePart)
	playTemplate({ "UpgradeBR", "OnUpgrade" }, at, 32)
end

return OtherVfxController
