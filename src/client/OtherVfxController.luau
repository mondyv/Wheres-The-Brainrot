-- [ACTIVE] OtherVfxController
--[[
	One-shot bursts from ReplicatedStorage.EssentialAssets.OtherVFX.
	Particles use Emit (EmitCount / EmitDelay attrs) — not Enabled=true loops.
	Skips continuous BushEffect; use BushEffectBurst / Luckyblock / UpgradeBR.OnUpgrade.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local OtherVfxController = {}

local LIFETIME_SEC = 4.5
local DEFAULT_EMIT = 28
local BEZIER_DURATION = 0.55

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

local function stabilizeClone(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.Massless = true
		root.Transparency = 1
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Transparency = 1
		elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = false
		end
	end
end

local function playSounds(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("Sound") then
			d:Play()
		end
	end
	if root:IsA("Sound") then
		root:Play()
	end
end

local function flashLights(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			local light = d :: PointLight
			local peak = light.Brightness
			if peak <= 0 then
				peak = 2
			end
			light.Enabled = true
			light.Brightness = peak
			task.delay(0.35, function()
				if light.Parent then
					light.Enabled = false
				end
			end)
		end
	end
end

local function emitOne(emitter: ParticleEmitter, defaultCount: number)
	local countAttr = emitter:GetAttribute("EmitCount")
	local count = if typeof(countAttr) == "number" then math.max(1, math.floor(countAttr)) else defaultCount
	local delayAttr = emitter:GetAttribute("EmitDelay")
	local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
	emitter.Enabled = false
	local function doEmit()
		if emitter.Parent then
			emitter:Emit(count)
		end
	end
	if delaySec > 0 then
		task.delay(delaySec, doEmit)
	else
		doEmit()
	end
end

local function emitParticles(root: Instance, defaultCount: number, skipUnder: Instance?)
	local function consider(inst: Instance)
		if skipUnder and (inst == skipUnder or inst:IsDescendantOf(skipUnder)) then
			return
		end
		if inst:IsA("ParticleEmitter") then
			emitOne(inst, defaultCount)
		end
	end
	consider(root)
	for _, d in root:GetDescendants() do
		consider(d)
	end
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

local function runBezierIfPresent(root: Instance, hostCf: CFrame)
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
		-- Fall back: place relative to host if points weren't world-ready yet.
		points = {}
		local origin = hostCf.Position
		table.insert(points, origin)
		table.insert(points, origin + hostCf.UpVector * 4 + hostCf.LookVector * 2)
		table.insert(points, origin + hostCf.UpVector * 2)
	end

	local emitOnFinish = mover:FindFirstChild("EmitOnFinish")
	-- Skip EmitOnFinish during the initial burst; fire at path end.
	emitParticles(root, DEFAULT_EMIT, emitOnFinish)
	flashLights(root)
	playSounds(root)

	for _, d in mover:GetDescendants() do
		if d:IsA("Trail") or d:IsA("Beam") then
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
			for _, d in mover:GetDescendants() do
				if d:IsA("Trail") or d:IsA("Beam") then
					d.Enabled = false
				end
			end
			if emitOnFinish then
				emitParticles(emitOnFinish, DEFAULT_EMIT, nil)
			else
				emitParticles(mover, DEFAULT_EMIT, nil)
			end
		end
	end)
	return true
end

local function placeClone(clone: Instance, at: CFrame | BasePart): Instance
	stabilizeClone(clone)
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
			anchor.Size = Vector3.new(0.2, 0.2, 0.2)
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
		clone.Parent = Workspace
		return clone
	end

	if clone:IsA("Model") then
		clone:PivotTo(cf)
		clone.Parent = Workspace
		return clone
	end

	-- Folder / other: wrap in anchored part at target.
	local anchor = Instance.new("Part")
	anchor.Name = "OtherVfxAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = cf
	anchor.Parent = Workspace
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
	local usedBezier = runBezierIfPresent(clone, hostCf)
	if not usedBezier then
		emitParticles(clone, defaultEmit or DEFAULT_EMIT, nil)
		flashLights(clone)
		playSounds(clone)
	end
	-- Attachment parented to an existing host part: only clean the clone.
	if clone:IsA("Attachment") and typeof(at) ~= "CFrame" then
		Debris:AddItem(clone, LIFETIME_SEC)
	elseif placed.Name == "OtherVfxAnchor" then
		-- placeClone already scheduled Debris on the wrapper when needed.
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

--- Bush search completed — burst only (not continuous BushEffect).
function OtherVfxController.playBushOpenedBurst(bush: Instance)
	playTemplate({ "Bush Opening", "BushEffectBurst" }, resolveBushCFrame(bush), 36)
end

--- Lucky block shake / open.
function OtherVfxController.playLuckyBlockOpen(at: CFrame | BasePart)
	playTemplate({ "Bush Opening", "Luckyblock" }, at, 40)
end

--- Stand brainrot upgraded.
function OtherVfxController.playBrainrotUpgrade(at: CFrame | BasePart)
	playTemplate({ "UpgradeBR", "OnUpgrade" }, at, 32)
end

return OtherVfxController
