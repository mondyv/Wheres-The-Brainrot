-- [ACTIVE] WorkoutController
-- Gear activate: bar across both feet during curl, white flash, +power floaters into HUD.
local ContextActionService = game:GetService("ContextActionService")
local GamepadService = game:GetService("GamepadService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GearConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GearConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local GearRainbowFX = require(script.Parent.GearRainbowFX)
local OtherVfxController = require(script.Parent.OtherVfxController)
local UpgradesController = require(script.Parent.UpgradesController)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GamepadInput = require(script.Parent.GamepadInput)

local player = Players.LocalPlayer

local startWorkoutFn: RemoteFunction? = nil
local stopWorkoutFn: RemoteFunction? = nil
local claimDoubleTapFn: RemoteFunction? = nil

local function cacheWorkoutRemote(child: Instance?)
	if not child or not child:IsA("RemoteFunction") then
		return
	end
	if child.Name == "StartWorkout" then
		startWorkoutFn = child
	elseif child.Name == "StopWorkout" then
		stopWorkoutFn = child
	elseif child.Name == "ClaimWorkoutDoubleTap" then
		claimDoubleTapFn = child
	end
end

local function resolveWorkoutRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return
	end
	cacheWorkoutRemote(remotes:FindFirstChild("StartWorkout"))
	cacheWorkoutRemote(remotes:FindFirstChild("StopWorkout"))
	cacheWorkoutRemote(remotes:FindFirstChild("ClaimWorkoutDoubleTap"))
end

local function waitForWorkoutRemote(name: string): RemoteFunction?
	resolveWorkoutRemotes()
	if name == "StartWorkout" and startWorkoutFn and startWorkoutFn.Parent then
		return startWorkoutFn
	end
	if name == "StopWorkout" and stopWorkoutFn and stopWorkoutFn.Parent then
		return stopWorkoutFn
	end
	if name == "ClaimWorkoutDoubleTap" and claimDoubleTapFn and claimDoubleTapFn.Parent then
		return claimDoubleTapFn
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		or ReplicatedStorage:WaitForChild("Remotes", 8)
	if not remotes then
		return nil
	end
	local child = remotes:FindFirstChild(name) or remotes:WaitForChild(name, 8)
	cacheWorkoutRemote(child)
	if child and child:IsA("RemoteFunction") then
		return child
	end
	return nil
end

resolveWorkoutRemotes()
task.spawn(function()
	waitForWorkoutRemote("StartWorkout")
	waitForWorkoutRemote("StopWorkout")
	waitForWorkoutRemote("ClaimWorkoutDoubleTap")
end)

local toolConns: { RBXScriptConnection } = {}
local charConns: { RBXScriptConnection } = {}
local boundTools: { [Tool]: boolean } = {}
local workoutTrack: AnimationTrack? = nil
local workoutAnim: Animation? = nil
local footMotor: Motor6D? = nil
local footWeld: WeldConstraint? = nil
local footProp: Model? = nil
local footTool: Tool? = nil
local footFollowConn: RBXScriptConnection? = nil
local savedRequiresHandle: boolean? = nil
local gripKillConn: RBXScriptConnection? = nil
local gripChildConn: RBXScriptConnection? = nil
local bodyHighlight: Highlight? = nil
local walkSpeedBefore: number? = nil
local jumpPowerBefore: number? = nil
local jumpHeightBefore: number? = nil
local floaterLayer: Frame? = nil
local handleTransparency: { [BasePart]: number } = {}
local handleBaseTransparency: { [BasePart]: number } = {}

-- Match SideUI Power HUD (yellowish gold). Runtime sample overrides if available.
local POWER_HUD_YELLOW = Color3.fromRGB(255, 214, 90)
local POWER_HIT_WHITE = Color3.fromRGB(255, 252, 235)

local function clearToolConns()
	for _, c in toolConns do
		c:Disconnect()
	end
	table.clear(toolConns)
	table.clear(boundTools)
end

local function clearCharConns()
	for _, c in charConns do
		c:Disconnect()
	end
	table.clear(charConns)
end

local function getHumanoid(character: Model?): Humanoid?
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function findFeet(character: Model): (BasePart?, BasePart?)
	local function pick(name: string): BasePart?
		local direct = character:FindFirstChild(name)
		if direct and direct:IsA("BasePart") then
			return direct
		end
		return nil
	end
	local r = pick("RightFoot") or pick("Right Ankle") or pick("Right Leg")
	local l = pick("LeftFoot") or pick("Left Ankle") or pick("Left Leg")
	return r, l
end

local function stopWorkoutAnim()
	if workoutTrack then
		workoutTrack:Stop(0.15)
		workoutTrack = nil
	end
end

local function isArmOrHandPart(part: Instance?): boolean
	if not part or not part:IsA("BasePart") then
		return false
	end
	local n = string.lower(part.Name)
	return string.find(n, "hand", 1, true) ~= nil
		or string.find(n, "arm", 1, true) ~= nil
		or n == "rightgripattachment"
		or n == "leftgripattachment"
end

local function jointParts(j: Instance): (BasePart?, BasePart?)
	if j:IsA("Motor6D") or j:IsA("Weld") then
		return j.Part0, j.Part1
	end
	if j:IsA("WeldConstraint") then
		return j.Part0, j.Part1
	end
	return nil, nil
end

local function isHandGripJoint(j: Instance, handle: BasePart?): boolean
	if j.Name == "WorkoutFootMotor" then
		return false
	end
	if string.find(string.lower(j.Name), "grip", 1, true) then
		return true
	end
	if not handle then
		return false
	end
	local p0, p1 = jointParts(j)
	if p0 == handle or p1 == handle then
		local other = if p0 == handle then p1 else p0
		return isArmOrHandPart(other)
	end
	return false
end

local function destroyHandGrips(character: Model, handle: BasePart?)
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
			if isHandGripJoint(d, handle) then
				d:Destroy()
			end
		end
	end
	if handle then
		for _, d in handle:GetDescendants() do
			if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
				if isHandGripJoint(d, handle) then
					d:Destroy()
				end
			end
		end
	end
end

local function restoreToolVisibility()
	for part, tr in handleTransparency do
		if part.Parent then
			part.LocalTransparencyModifier = tr
		end
	end
	table.clear(handleTransparency)
	for part, tr in handleBaseTransparency do
		if part.Parent then
			part.Transparency = tr
		end
	end
	table.clear(handleBaseTransparency)
end

local function clearFootAttach()
	if gripKillConn then
		gripKillConn:Disconnect()
		gripKillConn = nil
	end
	if gripChildConn then
		gripChildConn:Disconnect()
		gripChildConn = nil
	end
	if footFollowConn then
		footFollowConn:Disconnect()
		footFollowConn = nil
	end
	if footMotor then
		footMotor:Destroy()
		footMotor = nil
	end
	if footWeld then
		footWeld:Destroy()
		footWeld = nil
	end
	if footProp then
		GearRainbowFX.detach(footProp)
		footProp:Destroy()
		footProp = nil
	end
	if footTool then
		for _, d in footTool:GetDescendants() do
			if
				d:IsA("ParticleEmitter")
				or d:IsA("Beam")
				or d:IsA("Trail")
				or d:IsA("Fire")
				or d:IsA("Smoke")
				or d:IsA("Sparkles")
			then
				(d :: any).Enabled = true
			end
		end
	end
	if footTool and footTool.Parent and savedRequiresHandle ~= nil then
		footTool.RequiresHandle = savedRequiresHandle
	end
	footTool = nil
	savedRequiresHandle = nil
	restoreToolVisibility()
end

local DOUBLE_TAP_ACTION = "WorkoutDoubleTapAccept"

-- Stable shoe-top / toe points in foot-local space so the bar stays flush
-- no matter which animation frame the attach happens on.
local function footSoleToeLocal(foot: BasePart, forwardHint: Vector3): Vector3
	local size = foot.Size
	local axisZ = foot.CFrame:VectorToWorldSpace(Vector3.zAxis)
	local axisX = foot.CFrame:VectorToWorldSpace(Vector3.xAxis)
	local useZ = math.abs(axisZ:Dot(forwardHint)) >= math.abs(axisX:Dot(forwardHint))
	local toeAxis = if useZ then Vector3.zAxis else Vector3.xAxis
	local worldAxis = if useZ then axisZ else axisX
	local sign = if worldAxis:Dot(forwardHint) >= 0 then 1 else -1
	local along = if useZ then size.Z else size.X
	-- Local -Y is the sole on R15 feet. Tiny nudge onto the visual shoe top
	-- (not toward the shin — a large +Y put the bar on the torso).
	return Vector3.new(0, -size.Y * 0.5 + 0.12, 0) + toeAxis * (sign * along * 0.38)
end

local function soleAcross(rf: BasePart, lf: BasePart?, forwardHint: Vector3): (Vector3, Vector3, number)
	local hint = Vector3.new(forwardHint.X, 0, forwardHint.Z)
	if hint.Magnitude < 0.05 then
		hint = Vector3.new(0, 0, -1)
	else
		hint = hint.Unit
	end
	local t0 = rf.CFrame:PointToWorldSpace(footSoleToeLocal(rf, hint))
	local t1 = if lf then lf.CFrame:PointToWorldSpace(footSoleToeLocal(lf, hint)) else t0
	local mid = (t0 + t1) * 0.5
	local across = t1 - t0
	across = Vector3.new(across.X, 0, across.Z)
	if across.Magnitude < 0.05 then
		across = Vector3.new(rf.CFrame.RightVector.X, 0, rf.CFrame.RightVector.Z)
	end
	if across.Magnitude < 0.05 then
		across = Vector3.new(1, 0, 0)
	end
	return mid, across.Unit, mid.Y
end

local function boundsFromRoot(root: Instance): (CFrame, Vector3)
	if root:IsA("Model") then
		return (root :: Model):GetBoundingBox()
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			any = true
			local cf = d.CFrame
			local half = d.Size * 0.5
			for _, corner in {
				Vector3.new(-1, -1, -1),
				Vector3.new(-1, -1, 1),
				Vector3.new(-1, 1, -1),
				Vector3.new(-1, 1, 1),
				Vector3.new(1, -1, -1),
				Vector3.new(1, -1, 1),
				Vector3.new(1, 1, -1),
				Vector3.new(1, 1, 1),
			} do
				local w = cf:PointToWorldSpace(half * corner)
				minV = Vector3.new(math.min(minV.X, w.X), math.min(minV.Y, w.Y), math.min(minV.Z, w.Z))
				maxV = Vector3.new(math.max(maxV.X, w.X), math.max(maxV.Y, w.Y), math.max(maxV.Z, w.Z))
			end
		end
	end
	if not any then
		return CFrame.new(), Vector3.new(1, 1, 1)
	end
	local size = maxV - minV
	return CFrame.new((minV + maxV) * 0.5), size
end

-- Map the model's longest axis onto `across` (left-right between the feet)
-- and its thinnest axis onto world up so the gear lies flat. Then pin the
-- actual mesh bottom to the shoe plane so it does not hover.
local function footPropMotorFrames(
	handle: BasePart,
	root: Instance,
	anchorFoot: BasePart,
	mid: Vector3,
	across: Vector3,
	contactY: number
): (CFrame, CFrame)
	local bbCf, bbSize = boundsFromRoot(root)
	local axes = {
		{ len = bbSize.X, dir = bbCf.RightVector },
		{ len = bbSize.Y, dir = bbCf.UpVector },
		{ len = bbSize.Z, dir = bbCf.LookVector },
	}
	table.sort(axes, function(a, b)
		return a.len > b.len
	end)
	local worldLong = axes[1].dir
	local worldThin = axes[3].dir
	local localLong = handle.CFrame:VectorToObjectSpace(worldLong)
	local localThin = handle.CFrame:VectorToObjectSpace(worldThin)
	if localLong.Magnitude < 0.05 then
		localLong = Vector3.yAxis
	end
	if localThin.Magnitude < 0.05 then
		localThin = Vector3.xAxis
	end
	localLong = localLong.Unit
	localThin = localThin.Unit
	if math.abs(localLong:Dot(localThin)) > 0.92 then
		localThin = localLong:Cross(Vector3.zAxis)
		if localThin.Magnitude < 0.05 then
			localThin = localLong:Cross(Vector3.xAxis)
		end
		localThin = localThin.Unit
	end
	local c1 = CFrame.fromMatrix(Vector3.zero, localLong, localThin)
	local trialPos = Vector3.new(mid.X, contactY, mid.Z)
	local trialHandle = CFrame.fromMatrix(trialPos, across, Vector3.yAxis) * c1:Inverse()
	local handleNow = handle.CFrame
	local minY = math.huge
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local rel = handleNow:ToObjectSpace(d.CFrame)
			local worldCf = trialHandle * rel
			local half = d.Size * 0.5
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local y = worldCf:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)).Y
						minY = math.min(minY, y)
					end
				end
			end
		end
	end
	if minY == math.huge then
		minY = contactY
	end
	-- Rest on the shoe top — do not bury the bar into the legs.
	local pos = trialPos + Vector3.new(0, contactY - 0.008 - minY, 0)
	local target = CFrame.fromMatrix(pos, across, Vector3.yAxis)
	return anchorFoot.CFrame:ToObjectSpace(target), c1
end

-- Visible clone of the Studio gear, parented in the world (not the character)
-- so Humanoid cannot weld it to the head. Pivot the solid mesh onto the feet every frame.
local function ensureWorldFolder(): Folder
	local folder = Workspace:FindFirstChild("WorkoutGearWorld")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "WorkoutGearWorld"
	created.Parent = Workspace
	return created
end

-- Solid mesh parts only — skip sparks / beams so pose bounds stay on the bar.
local function isPoseMeshPart(d: Instance): boolean
	if not d:IsA("BasePart") then
		return false
	end
	if d.Transparency >= 0.95 then
		return false
	end
	local vol = d.Size.X * d.Size.Y * d.Size.Z
	return vol >= 0.12
end

local function partWorldMinY(part: BasePart): number
	local cf = part.CFrame
	local half = part.Size * 0.5
	local minY = math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local y = cf:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)).Y
				minY = math.min(minY, y)
			end
		end
	end
	return minY
end

local function dominantMeshCenter(model: Model, primary: BasePart): Vector3
	local largest = 0
	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if isPoseMeshPart(d) then
			local p = d :: BasePart
			local vol = p.Size.X * p.Size.Y * p.Size.Z
			largest = math.max(largest, vol)
			table.insert(parts, p)
		end
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	for _, p in parts do
		local vol = p.Size.X * p.Size.Y * p.Size.Z
		if vol < largest * 0.22 then
			continue
		end
		any = true
		local cf = p.CFrame
		local half = p.Size * 0.5
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local w = cf:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
					minV = Vector3.new(math.min(minV.X, w.X), math.min(minV.Y, w.Y), math.min(minV.Z, w.Z))
					maxV = Vector3.new(math.max(maxV.X, w.X), math.max(maxV.Y, w.Y), math.max(maxV.Z, w.Z))
				end
			end
		end
	end
	if not any then
		return primary.Position
	end
	return (minV + maxV) * 0.5
end

-- Place the authored Studio clone on the shoes using Primary only.
-- Do not inspect VFX parts for bounds and do not toggle any emitters.
local function poseGearOnFeet(character: Model, model: Model)
	local rightFoot, leftFoot = findFeet(character)
	local anchorFoot = rightFoot or leftFoot
	if not anchorFoot then
		return
	end
	local primary = model.PrimaryPart or GearConfig.resolvePrimaryPart(model)
	if not primary then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local forward = if hrp and hrp:IsA("BasePart") then hrp.CFrame.LookVector else Vector3.zAxis
	local mid, across, contactY = soleAcross(anchorFoot, leftFoot, forward)

	local gearId = model:GetAttribute(GearConfig.GEAR_ID_ATTR)
	local flip = typeof(gearId) == "number" and GearConfig.flipOnFeet(gearId)

	local ps = primary.Size
	local lieFlat = CFrame.identity
	if ps.Y >= ps.X and ps.Y >= ps.Z then
		lieFlat = CFrame.Angles(0, 0, math.rad(90))
	elseif ps.Z >= ps.X and ps.Z >= ps.Y then
		lieFlat = CFrame.Angles(0, math.rad(90), 0)
	end
	-- Moon / Jupiter: Primary sits on the wrong pole and hits the legs.
	if flip then
		lieFlat = lieFlat * CFrame.Angles(math.rad(180), 0, 0)
	end

	local target = CFrame.fromMatrix(Vector3.new(mid.X, contactY, mid.Z), across, Vector3.yAxis) * lieFlat
	model:PivotTo(target * primary.CFrame:ToObjectSpace(model:GetPivot()))

	local minY = math.huge
	if flip then
		for _, d in model:GetDescendants() do
			if isPoseMeshPart(d) then
				minY = math.min(minY, partWorldMinY(d :: BasePart))
			end
		end
	else
		minY = partWorldMinY(primary)
	end
	if minY < math.huge then
		model:PivotTo(model:GetPivot() + Vector3.new(0, contactY - minY, 0))
	end

	-- Height is already on the soles. Shift so the dumbbell's real extents
	-- (not a part-count average that VFX can pull sideways) sit on mid XZ.
	local vis = dominantMeshCenter(model, primary)
	model:PivotTo(model:GetPivot() + Vector3.new(mid.X - vis.X, 0, mid.Z - vis.Z))
end

local function attachGearAcrossFeet(character: Model, tool: Tool)
	clearFootAttach()
	local rightFoot, leftFoot = findFeet(character)
	local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
	if typeof(gearId) ~= "number" then
		warn("[WorkoutController] Tool missing gear id — cannot attach to feet")
		return
	end
	local anchorFoot = rightFoot or leftFoot
	if not anchorFoot then
		local tries = tool:GetAttribute("_FootAttachTries")
		local n = if typeof(tries) == "number" then tries else 0
		if n < 8 then
			tool:SetAttribute("_FootAttachTries", n + 1)
			task.delay(0.35, function()
				if tool.Parent == character then
					attachGearAcrossFeet(character, tool)
				end
			end)
		else
			warn("[WorkoutController] Character missing feet — cannot attach gear")
		end
		return
	end
	tool:SetAttribute("_FootAttachTries", nil)

	local model = GearConfig.cloneGearModel(gearId)
	if not model then
		warn("[WorkoutController] Missing gear model for id", gearId)
		return
	end
	model.Name = "WorkoutFootProp"
	model:SetAttribute(GearConfig.GEAR_ID_ATTR, gearId)
	-- Studio clone as-is. Only strip scripts and make the mesh safe to follow the feet.
	for _, d in model:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
			d.Anchored = true
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	local primary = GearConfig.resolvePrimaryPart(model)
	if not primary then
		model:Destroy()
		warn("[WorkoutController] Gear model has no Primary part")
		return
	end
	model.PrimaryPart = primary

	footTool = tool
	if savedRequiresHandle == nil then
		savedRequiresHandle = tool.RequiresHandle
	end
	tool.RequiresHandle = false

	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			if handleTransparency[d] == nil then
				handleTransparency[d] = d.LocalTransparencyModifier
			end
			if handleBaseTransparency[d] == nil then
				handleBaseTransparency[d] = d.Transparency
			end
			d.LocalTransparencyModifier = 1
			d.Transparency = 1
			d.CanCollide = false
			d.Massless = true
		elseif
			d:IsA("ParticleEmitter")
			or d:IsA("Beam")
			or d:IsA("Trail")
			or d:IsA("Fire")
			or d:IsA("Smoke")
			or d:IsA("Sparkles")
		then
			(d :: any).Enabled = false
		end
	end

	destroyHandGrips(character, tool:FindFirstChild("Handle") :: BasePart?)
	local toolHandle = tool:FindFirstChild("Handle")
	gripChildConn = character.DescendantAdded:Connect(function(child)
		if child:IsA("Motor6D") or child:IsA("Weld") or child:IsA("WeldConstraint") then
			if isHandGripJoint(child, if toolHandle and toolHandle:IsA("BasePart") then toolHandle else nil) then
				task.defer(function()
					if child.Parent then
						child:Destroy()
					end
				end)
			end
		end
	end)
	if gripKillConn then
		gripKillConn:Disconnect()
	end
	local gripAccum = 0
	gripKillConn = RunService.Heartbeat:Connect(function(dt)
		if not tool.Parent or tool.Parent ~= character then
			if gripKillConn then
				gripKillConn:Disconnect()
				gripKillConn = nil
			end
			return
		end
		gripAccum += dt
		if gripAccum < 0.08 then
			return
		end
		gripAccum = 0
		destroyHandGrips(character, if toolHandle and toolHandle:IsA("BasePart") then toolHandle else nil)
		if tool.RequiresHandle then
			tool.RequiresHandle = false
		end
	end)

	model.Parent = ensureWorldFolder()
	footProp = model
	poseGearOnFeet(character, model)

	-- Follow both shoes every frame so the bar stays flush in the handstand.
	-- Authored VFX is never toggled; graphics quality is what shows particles.
	if footFollowConn then
		footFollowConn:Disconnect()
	end
	footFollowConn = RunService.RenderStepped:Connect(function()
		if not model.Parent or not character.Parent or tool.Parent ~= character then
			if footFollowConn then
				footFollowConn:Disconnect()
				footFollowConn = nil
			end
			return
		end
		poseGearOnFeet(character, model)
	end)

	if tool:GetAttribute("RainbowGear") == true then
		GearRainbowFX.attach(model)
	end
end

local function playWorkoutAnim(character: Model)
	stopWorkoutAnim()
	local humanoid = getHumanoid(character)
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if not workoutAnim then
		workoutAnim = Instance.new("Animation")
		workoutAnim.Name = "WorkoutBarbellCurl"
		workoutAnim.AnimationId = GearConfig.WORKOUT_ANIMATION_ID
	end
	local ok, trackOrErr = pcall(function()
		return (animator :: Animator):LoadAnimation(workoutAnim :: Animation)
	end)
	if not ok or typeof(trackOrErr) ~= "Instance" then
		warn("[WorkoutController] LoadAnimation failed:", trackOrErr)
		return
	end
	local track = trackOrErr :: AnimationTrack
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	track:Play(0.15)
	workoutTrack = track
end

local function lockMovement(humanoid: Humanoid, locked: boolean)
	if locked then
		if walkSpeedBefore == nil then
			walkSpeedBefore = humanoid.WalkSpeed
		end
		if jumpPowerBefore == nil then
			jumpPowerBefore = humanoid.JumpPower
		end
		if jumpHeightBefore == nil then
			jumpHeightBefore = humanoid.JumpHeight
		end
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	else
		if walkSpeedBefore ~= nil then
			humanoid.WalkSpeed = walkSpeedBefore
			walkSpeedBefore = nil
		end
		if jumpPowerBefore ~= nil then
			humanoid.JumpPower = jumpPowerBefore
			jumpPowerBefore = nil
		end
		if jumpHeightBefore ~= nil then
			humanoid.JumpHeight = jumpHeightBefore
			jumpHeightBefore = nil
		end
	end
end

local function clearBodyHighlight()
	if bodyHighlight then
		bodyHighlight:Destroy()
		bodyHighlight = nil
	end
end

local function flashWhite(character: Model)
	clearBodyHighlight()
	local hl = Instance.new("Highlight")
	hl.Name = "WorkoutPowerFlash"
	hl.Adornee = character
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillColor = Color3.new(1, 1, 1)
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.15
	hl.OutlineTransparency = 0.35
	hl.Parent = character
	bodyHighlight = hl
	GameSoundEffects.playLifting()

	local proxy = Instance.new("NumberValue")
	proxy.Value = 0.15
	local tw = TweenService:Create(
		proxy,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	proxy:GetPropertyChangedSignal("Value"):Connect(function()
		if hl.Parent then
			hl.FillTransparency = proxy.Value
			hl.OutlineTransparency = math.clamp(proxy.Value + 0.2, 0, 1)
		end
	end)
	tw.Completed:Connect(function()
		proxy:Destroy()
		if bodyHighlight == hl then
			clearBodyHighlight()
		elseif hl.Parent then
			hl:Destroy()
		end
	end)
	tw:Play()
end

local function ensureFloaterLayer(main: ScreenGui): Frame
	if floaterLayer and floaterLayer.Parent then
		return floaterLayer
	end
	local layer = Instance.new("Frame")
	layer.Name = "PowerFloaters"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 80
	layer.Parent = main
	floaterLayer = layer
	return layer
end

local function resolvePowerHudColor(amountLabel: TextLabel?): Color3
	if amountLabel then
		local c = amountLabel.TextColor3
		local _, s, v = c:ToHSV()
		if s > 0.15 and v > 0.35 then
			return c
		end
	end
	return POWER_HUD_YELLOW
end

local function ensureChipScale(chip: GuiObject): UIScale
	local sc = chip:FindFirstChild("PowerChipScale")
	if sc and sc:IsA("UIScale") then
		return sc
	end
	local legacy = chip:FindFirstChild("PowerHitScale")
	if legacy then
		legacy:Destroy()
	end
	local made = Instance.new("UIScale")
	made.Name = "PowerChipScale"
	made.Scale = 1
	made.Parent = chip
	return made
end

local function resolveMuscleIcon(powerFrame: Instance): ImageLabel?
	local direct = powerFrame:FindFirstChild("ImageLabel")
	if direct and direct:IsA("ImageLabel") then
		return direct
	end
	-- May already be inside PowerPulseCluster
	local cluster = powerFrame:FindFirstChild("PowerPulseCluster")
	if cluster then
		local nested = cluster:FindFirstChild("ImageLabel") or cluster:FindFirstChild("Icon")
		if nested and nested:IsA("ImageLabel") then
			return nested
		end
		local any = cluster:FindFirstChildWhichIsA("ImageLabel")
		if any then
			return any
		end
	end
	local named = powerFrame:FindFirstChild("Icon")
	if named and named:IsA("ImageLabel") then
		return named
	end
	for _, child in powerFrame:GetChildren() do
		if child:IsA("ImageLabel") then
			return child
		end
	end
	return nil
end

local function resolvePulseCluster(powerFrame: GuiObject): GuiObject
	local cluster = powerFrame:FindFirstChild("PowerPulseCluster")
	if cluster then
		for _, ch in cluster:GetChildren() do
			if ch:IsA("GuiObject") then
				ch.Parent = powerFrame
			end
		end
		cluster:Destroy()
	end
	local amount = powerFrame:FindFirstChild("Amount")
	if amount and amount:IsA("GuiObject") then
		return amount
	end
	return powerFrame
end

local function spawnHitLight(layer: Frame, screen: Vector2, strength: number?)
	local s = strength or 1
	local lp = layer.AbsolutePosition
	local glow = Instance.new("Frame")
	glow.Name = "PowerHitLight"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromOffset(screen.X - lp.X, screen.Y - lp.Y)
	glow.Size = UDim2.fromOffset(22 * s, 22 * s)
	glow.BackgroundColor3 = POWER_HUD_YELLOW
	glow.BackgroundTransparency = 0.25
	glow.BorderSizePixel = 0
	glow.ZIndex = 85
	glow.Parent = layer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = glow
	TweenService:Create(
		glow,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = UDim2.fromOffset(100 * s, 100 * s),
			BackgroundTransparency = 1,
		}
	):Play()
	task.delay(0.3, function()
		if glow.Parent then
			glow:Destroy()
		end
	end)
end

-- Punch Amount+muscle cluster only (never whole Power — Edit made aim/scale feel wrong).
local function pulsePowerHud(amountLabel: GuiObject?, powerFrame: GuiObject?, layer: Frame?)
	if not powerFrame or not powerFrame:IsA("GuiObject") then
		return
	end

	-- Strip mistaken whole-chip scale from earlier builds.
	local badChip = powerFrame:FindFirstChild("PowerChipScale")
	if badChip and badChip:IsA("UIScale") and badChip.Parent == powerFrame then
		badChip:Destroy()
	end

	local cluster = resolvePulseCluster(powerFrame)
	local token = ((cluster:GetAttribute("PowerPulseToken") :: number?) or 0) + 1
	cluster:SetAttribute("PowerPulseToken", token)
	cluster:SetAttribute("PowerPulseAt", os.clock())

	local sc = ensureChipScale(cluster)
	sc.Scale = 0.96
	local up = TweenService:Create(
		sc,
		TweenInfo.new(0.07, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.12 }
	)
	up:Play()
	up.Completed:Connect(function()
		if cluster:GetAttribute("PowerPulseToken") ~= token then
			return
		end
		TweenService:Create(
			sc,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end)

	if layer and layer.Parent then
		local center = cluster.AbsolutePosition + cluster.AbsoluteSize * 0.5
		spawnHitLight(layer, center, 1.1)
	end

	local muscle = resolveMuscleIcon(powerFrame)
	if muscle then
		local baseC = muscle.ImageColor3
		muscle.ImageColor3 = POWER_HIT_WHITE
		TweenService:Create(
			muscle,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageColor3 = baseC }
		):Play()
	end

	if amountLabel and amountLabel:IsA("TextLabel") then
		local label = amountLabel :: TextLabel
		local bad = label:FindFirstChild("PowerHitScale")
		if bad then
			bad:Destroy()
		end
		label.TextTransparency = 0
		local base = label.TextColor3
		label.TextColor3 = POWER_HIT_WHITE
		TweenService:Create(
			label,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = POWER_HUD_YELLOW }
		):Play()
		task.delay(0.2, function()
			if label.Parent then
				TweenService:Create(
					label,
					TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ TextColor3 = base }
				):Play()
			end
		end)
	end
end

local function spawnPowerFloater(gain: number, originScreen: Vector2?)
	local main = PlayerGuiMain.ensure(player)
	if not main then
		return
	end
	local layer = ensureFloaterLayer(main)
	local sideUI = main:FindFirstChild("SideUI")
	local counters = sideUI and sideUI:FindFirstChild("Counters")
	local powerFrame = counters and counters:FindFirstChild("Power")
	if not powerFrame or not powerFrame:IsA("GuiObject") then
		-- HUD can still be booting on the first gear tick — show at screen center.
		powerFrame = nil
	end

	local cluster: GuiObject? = nil
	local amountLabel: Instance? = nil
	if powerFrame then
		cluster = resolvePulseCluster(powerFrame)
		amountLabel = cluster:FindFirstChild("Amount") or powerFrame:FindFirstChild("Amount", true)
	end
	local amountGui: GuiObject? = if amountLabel and amountLabel:IsA("GuiObject")
		then amountLabel :: GuiObject
		else nil
	local iconGui: GuiObject? = if powerFrame then resolveMuscleIcon(powerFrame) else nil

	local hudColor = resolvePowerHudColor(
		if amountLabel and amountLabel:IsA("TextLabel") then amountLabel :: TextLabel else nil
	)

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	local function absCenter(gui: GuiObject): Vector2
		return gui.AbsolutePosition + gui.AbsoluteSize * 0.5
	end

	local function destScreen(): Vector2
		if cluster and cluster.AbsoluteSize.X > 1 then
			return absCenter(cluster)
		end
		if amountGui and iconGui then
			return (absCenter(amountGui) + absCenter(iconGui)) * 0.5
		elseif amountGui then
			return absCenter(amountGui)
		elseif iconGui then
			return absCenter(iconGui)
		elseif powerFrame then
			return absCenter(powerFrame)
		end
		return Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.22)
	end

	local function toLayerOffset(screen: Vector2): UDim2
		local lp = layer.AbsolutePosition
		return UDim2.fromOffset(screen.X - lp.X, screen.Y - lp.Y)
	end

	if not layer.Parent then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart")
		then head
		else (character and character:FindFirstChild("HumanoidRootPart"))

	local endPos = toLayerOffset(destScreen())
	local startPos = endPos
	if originScreen then
		startPos = toLayerOffset(originScreen)
	elseif anchor and anchor:IsA("BasePart") then
		local screenPos, onScreen = cam:WorldToViewportPoint(anchor.Position + Vector3.new(0, 1.35, 0))
		if onScreen then
			startPos = toLayerOffset(Vector2.new(screenPos.X, screenPos.Y))
		else
			startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 48)
		end
	else
		startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 48)
	end

	spawnHitLight(
		layer,
		Vector2.new(startPos.X.Offset + layer.AbsolutePosition.X, startPos.Y.Offset + layer.AbsolutePosition.Y),
		0.85
	)

	local row = Instance.new("Frame")
	row.Name = "PowerGainFloater"
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.Size = UDim2.fromOffset(0, 0)
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = startPos
	row.ZIndex = 90
	row.Parent = layer

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local label = Instance.new("TextLabel")
	label.Name = "Gain"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.TextColor3 = hudColor
	label.TextTransparency = 0
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.LayoutOrder = 1
	label.ZIndex = 91
	label.Parent = row
	local hudSize = 32
	if amountLabel and amountLabel:IsA("TextLabel") then
		hudSize = math.max(28, (amountLabel :: TextLabel).TextSize)
	end
	UiFonts.applyBodyLabel(label, hudSize, math.max(18, hudSize - 8))
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(35, 24, 6)
	stroke.Transparency = 0
	stroke.Parent = label

	local muscle = Instance.new("ImageLabel")
	muscle.Name = "Muscle"
	muscle.BackgroundTransparency = 1
	local iconPx = math.max(12, hudSize + 2)
	muscle.Size = UDim2.fromOffset(iconPx, iconPx)
	muscle.Image = "rbxassetid://73088512205933"
	muscle.ImageTransparency = 0
	muscle.ScaleType = Enum.ScaleType.Fit
	muscle.LayoutOrder = 2
	muscle.ZIndex = 91
	muscle.Parent = row

	local scale = Instance.new("UIScale")
	scale.Scale = 0.35
	scale.Parent = row
	TweenService:Create(
		scale,
		TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()

	local startX, startY = startPos.X.Offset, startPos.Y.Offset
	local liftY = startY - 28
	TweenService:Create(
		row,
		TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.fromOffset(startX, liftY) }
	):Play()

	local progress = Instance.new("NumberValue")
	progress.Value = 0
	local fromX, fromY = startX, liftY
	local progConn = progress:GetPropertyChangedSignal("Value"):Connect(function()
		local liveEnd = toLayerOffset(destScreen())
		local t = progress.Value
		local one = 1 - t
		local midX = (fromX + liveEnd.X.Offset) * 0.5
		local midY = math.min(fromY, liveEnd.Y.Offset) - 36
		local x = one * one * fromX + 2 * one * t * midX + t * t * liveEnd.X.Offset
		local y = one * one * fromY + 2 * one * t * midY + t * t * liveEnd.Y.Offset
		row.Position = UDim2.fromOffset(x, y)
	end)

	task.delay(0.12, function()
		if not row.Parent then
			progConn:Disconnect()
			progress:Destroy()
			return
		end
		fromX = row.Position.X.Offset
		fromY = row.Position.Y.Offset
		local move = TweenService:Create(
			progress,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Value = 1 }
		)
		move:Play()
		move.Completed:Connect(function()
			progConn:Disconnect()
			progress:Destroy()
			if not row.Parent then
				return
			end
			row.Position = toLayerOffset(destScreen())
			pulsePowerHud(amountGui, powerFrame, layer)
			if typeof(UpgradesController.commitPowerHudFromFloater) == "function" then
				UpgradesController.commitPowerHudFromFloater()
			end
			local suck = TweenService:Create(
				scale,
				TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Scale = 0.35 }
			)
			TweenService:Create(
				label,
				TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ TextTransparency = 1 }
			):Play()
			TweenService:Create(
				stroke,
				TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			):Play()
			TweenService:Create(
				muscle,
				TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			):Play()
			suck:Play()
			suck.Completed:Connect(function()
				row:Destroy()
			end)
		end)
	end)
end

local DOUBLE_TAP_ICON = "rbxassetid://94931726481451"
local DOUBLE_TAP_LIFE = 5
local doubleTapGen = 0
local doubleTapHits = 0
local lastDoubleTapSpawnAt = -100
local activeDoubleTaps: { Frame } = {}
local doubleTapActivateByHolder: { [Frame]: () -> () } = {}
local doubleTapGui: ScreenGui? = nil
local claimDoubleTapBusy = false

local function spawnIntervalForHits(hits: number): number
	if hits < 3 then
		return 7 - (hits / 3) * 2
	end
	local t = math.clamp((hits - 3) / 5, 0, 1)
	return 5 - t * 2
end

local function maxDoubleTapsForHits(hits: number): number
	return if hits >= 3 then 2 else 1
end

local function pruneDoubleTaps()
	for i = #activeDoubleTaps, 1, -1 do
		if not activeDoubleTaps[i].Parent then
			doubleTapActivateByHolder[activeDoubleTaps[i]] = nil
			table.remove(activeDoubleTaps, i)
		end
	end
end

local function ensureDoubleTapGui(): ScreenGui
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		pg = player:WaitForChild("PlayerGui", 8) :: PlayerGui?
	end
	if doubleTapGui and doubleTapGui.Parent then
		return doubleTapGui
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "WorkoutDoubleTapGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 115
	gui.Enabled = true
	if pg then
		gui.Parent = pg
	end
	doubleTapGui = gui
	return gui
end

local function pickDoubleTapPos(gui: ScreenGui, sizePx: number): UDim2
	local cam = workspace.CurrentCamera
	local vs = if cam then cam.ViewportSize else Vector2.new(800, 600)
	local padX = math.max(96, vs.X * 0.16)
	local padY = math.max(110, vs.Y * 0.2)
	local minX = padX
	local maxX = math.max(minX + 8, vs.X - padX)
	local minY = padY
	local maxY = math.max(minY + 8, vs.Y - padY)
	for _ = 1, 10 do
		local x = minX + math.random() * (maxX - minX)
		local y = minY + math.random() * (maxY - minY)
		local ok = true
		for _, other in activeDoubleTaps do
			if other.Parent then
				local p = other.AbsolutePosition + other.AbsoluteSize * 0.5
				if (Vector2.new(x, y) - p).Magnitude < sizePx * 1.35 then
					ok = false
					break
				end
			end
		end
		if ok then
			return UDim2.fromOffset(x, y)
		end
	end
	return UDim2.fromOffset((minX + maxX) * 0.5, (minY + maxY) * 0.5)
end

local function dismissDoubleTap(holder: Frame, clicked: boolean)
	doubleTapActivateByHolder[holder] = nil
	if holder:GetAttribute("Closing") == true then
		return
	end
	holder:SetAttribute("Closing", true)
	UIInteractionSounds.playNotif()
	local scale = holder:FindFirstChild("PopScale")
	if clicked then
		local hit = holder:FindFirstChild("Hit")
		if hit and (hit:IsA("ImageButton") or hit:IsA("ImageLabel")) then
			local burst = Instance.new("ImageLabel")
			burst.Name = "Burst"
			burst.BackgroundTransparency = 1
			burst.BorderSizePixel = 0
			burst.AnchorPoint = Vector2.new(0.5, 0.5)
			burst.Position = UDim2.fromScale(0.5, 0.5)
			burst.Size = UDim2.fromScale(1, 1)
			burst.Image = hit.Image
			burst.ScaleType = Enum.ScaleType.Fit
			burst.ImageTransparency = 0.15
			burst.ZIndex = 19
			burst.Parent = holder
			local burstScale = Instance.new("UIScale")
			burstScale.Scale = 1
			burstScale.Parent = burst
			TweenService:Create(
				burstScale,
				TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 2.15 }
			):Play()
			TweenService:Create(
				burst,
				TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			):Play()
		end
		if scale and scale:IsA("UIScale") then
			TweenService:Create(
				scale,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1.38 }
			):Play()
			task.delay(0.12, function()
				if not holder.Parent then
					return
				end
				TweenService:Create(
					scale,
					TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
					{ Scale = 0.08 }
				):Play()
			end)
		end
		TweenService:Create(
			holder,
			TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Rotation = holder.Rotation + (if holder.Rotation >= 0 then 38 else -38) }
		):Play()
	else
		if scale and scale:IsA("UIScale") then
			TweenService:Create(
				scale,
				TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Scale = 0.15 }
			):Play()
		end
		TweenService:Create(
			holder,
			TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Rotation = holder.Rotation + (if holder.Rotation >= 0 then 28 else -28) }
		):Play()
	end
	for _, d in holder:GetDescendants() do
		if d.Name == "Burst" then
			-- Burst fades on its own so it can expand while the icon shrinks.
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			TweenService:Create(
				d,
				TweenInfo.new(if clicked then 0.36 else 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			):Play()
		elseif d:IsA("TextLabel") then
			TweenService:Create(
				d,
				TweenInfo.new(if clicked then 0.28 else 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ TextTransparency = 1 }
			):Play()
			local stroke = d:FindFirstChildOfClass("UIStroke")
			if stroke then
				TweenService:Create(
					stroke,
					TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Transparency = 1 }
				):Play()
			end
		end
	end
	task.delay(if clicked then 0.46 else 0.34, function()
		if holder.Parent then
			holder:Destroy()
		end
	end)
end

local function spawnDoubleTapPrompt()
	pruneDoubleTaps()
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
		return
	end
	if #activeDoubleTaps >= maxDoubleTapsForHits(doubleTapHits) then
		return
	end
	local gui = ensureDoubleTapGui()
	if not gui.Parent then
		return
	end

	local sizePx = 118
	local holder = Instance.new("Frame")
	holder.Name = "DoubleTap"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(sizePx, sizePx)
	holder.Position = pickDoubleTapPos(gui, sizePx)
	holder.Rotation = (math.random() - 0.5) * 10
	holder.ZIndex = 20
	holder.Parent = gui

	local pop = Instance.new("UIScale")
	pop.Name = "PopScale"
	pop.Scale = 0.18
	pop.Parent = holder

	local btn = Instance.new("ImageButton")
	btn.Name = "Hit"
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Size = UDim2.fromScale(1, 1)
	btn.Image = DOUBLE_TAP_ICON
	btn.ScaleType = Enum.ScaleType.Fit
	btn.AutoButtonColor = false
	btn.Active = true
	btn.Selectable = true
	btn.ZIndex = 21
	btn.Parent = holder
	GamepadInput.mountHint(btn, GamepadInput.ACCEPT, true)
	pcall(function()
		GamepadService:DisableGamepadCursor()
	end)

	table.insert(activeDoubleTaps, holder)
	UIInteractionSounds.playClick()

	TweenService:Create(
		pop,
		TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.08 }
	):Play()
	task.delay(0.28, function()
		if holder.Parent and holder:GetAttribute("Closing") ~= true then
			TweenService:Create(
				pop,
				TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
		end
	end)

	local born = os.clock()
	local idleConn: RBXScriptConnection? = nil
	idleConn = RunService.Heartbeat:Connect(function()
		if not holder.Parent or holder:GetAttribute("Closing") == true then
			if idleConn then
				idleConn:Disconnect()
				idleConn = nil
			end
			return
		end
		local t = os.clock() - born
		holder.Rotation = math.sin(t * 2.35) * 12 + math.sin(t * 5.4) * 3.2
		pop.Scale = 1 + math.sin(t * 3.15) * 0.055
	end)

	local consumed = false
	local function onActivate()
		if consumed or holder:GetAttribute("Closing") == true then
			return
		end
		consumed = true
		btn.Active = false
		if idleConn then
			idleConn:Disconnect()
			idleConn = nil
		end
		local squash = TweenService:Create(
			pop,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = 0.82 }
		)
		squash:Play()
		local center = holder.AbsolutePosition + holder.AbsoluteSize * 0.5
		task.spawn(function()
			local gain = 0
			waitForWorkoutRemote("ClaimWorkoutDoubleTap")
			if claimDoubleTapFn and not claimDoubleTapBusy then
				claimDoubleTapBusy = true
				local ok, result = pcall(function()
					return claimDoubleTapFn:InvokeServer()
				end)
				claimDoubleTapBusy = false
				if ok and typeof(result) == "number" then
					gain = result
				end
			end
			if gain > 0 then
				doubleTapHits += 1
				spawnPowerFloater(gain, center)
			end
		end)
		dismissDoubleTap(holder, true)
	end
	btn.Activated:Connect(onActivate)
	btn.MouseButton1Click:Connect(onActivate)
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == GamepadInput.ACCEPT then
			onActivate()
		end
	end)
	doubleTapActivateByHolder[holder] = onActivate

	task.delay(DOUBLE_TAP_LIFE, function()
		if holder.Parent and holder:GetAttribute("Closing") ~= true then
			if idleConn then
				idleConn:Disconnect()
				idleConn = nil
			end
			dismissDoubleTap(holder, false)
		end
	end)
end

local function stopDoubleTapLoop()
	doubleTapGen += 1
	doubleTapHits = 0
	lastDoubleTapSpawnAt = -100
	pruneDoubleTaps()
	for _, holder in activeDoubleTaps do
		if holder.Parent then
			holder:Destroy()
		end
	end
	table.clear(activeDoubleTaps)
	table.clear(doubleTapActivateByHolder)
	if doubleTapGui then
		doubleTapGui:Destroy()
		doubleTapGui = nil
	end
	pcall(function()
		ContextActionService:UnbindAction(DOUBLE_TAP_ACTION)
	end)
	pcall(function()
		GamepadService:DisableGamepadCursor()
	end)
end

local function tryActivateOldestDoubleTap(): boolean
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
		return false
	end
	pruneDoubleTaps()
	local holder = activeDoubleTaps[1]
	local activate = holder and doubleTapActivateByHolder[holder]
	if activate then
		activate()
		return true
	end
	return false
end

local function startDoubleTapLoop()
	doubleTapGen += 1
	local gen = doubleTapGen
	doubleTapHits = 0
	lastDoubleTapSpawnAt = -100
	ensureDoubleTapGui()
	ContextActionService:BindActionAtPriority(
		DOUBLE_TAP_ACTION,
		function(_name, state, _input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if tryActivateOldestDoubleTap() then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.ContextActionPriority.High.Value + 80,
		Enum.KeyCode.ButtonA
	)
	task.spawn(function()
		task.wait(1.15)
		while gen == doubleTapGen and player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true do
			pruneDoubleTaps()
			if #activeDoubleTaps < maxDoubleTapsForHits(doubleTapHits) then
				local since = os.clock() - lastDoubleTapSpawnAt
				if since < 0.9 then
					task.wait(0.9 - since)
					if gen ~= doubleTapGen then
						return
					end
				end
				if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
					return
				end
				lastDoubleTapSpawnAt = os.clock()
				spawnDoubleTapPrompt()
			end
			local interval = spawnIntervalForHits(doubleTapHits)
			task.wait(interval)
			if gen ~= doubleTapGen then
				return
			end
		end
	end)
end

local function cleanupWorkoutVisuals()
	stopDoubleTapLoop()
	stopWorkoutAnim()
	clearFootAttach()
	clearBodyHighlight()
	local hum = getHumanoid(player.Character)
	if hum then
		lockMovement(hum, false)
	end
end

local function onUnequip()
	resolveWorkoutRemotes()
	if stopWorkoutFn then
		pcall(function()
			stopWorkoutFn:InvokeServer()
		end)
	end
	local char = player.Character
	if char then
		for _, c in char:GetChildren() do
			if c:IsA("Tool") and c:GetAttribute("RainbowGear") == true then
				GearRainbowFX.detach(c)
			end
		end
	end
	cleanupWorkoutVisuals()
end

local function isUpgradesShopOpen(): boolean
	local okHud, hud = pcall(function()
		return require(script.Parent.HUDController)
	end)
	if okHud and typeof(hud) == "table" and typeof((hud :: any).getCurrentFrame) == "function" then
		local frame = (hud :: any).getCurrentFrame()
		return typeof(frame) == "Instance" and frame.Name == "Upgrades" and frame.Visible == true
	end
	return false
end

local function bindTool(tool: Tool)
	if tool:GetAttribute(GearConfig.GEAR_TOOL_ATTR) ~= true then
		return
	end
	if boundTools[tool] then
		return
	end
	boundTools[tool] = true

	local function startWorkoutFromEquip()
		task.spawn(function()
			local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
			if typeof(gearId) ~= "number" then
				return
			end
			if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
				return
			end
			if isUpgradesShopOpen() then
				return
			end
			if not waitForWorkoutRemote("StartWorkout") or not startWorkoutFn then
				warn("[WorkoutController] StartWorkout remote missing")
				return
			end
			if tool.Parent ~= player.Character then
				return
			end
			local ok = startWorkoutFn:InvokeServer(gearId)
			if not ok then
				return
			end
			local character = player.Character
			local hum = getHumanoid(character)
			if character and hum then
				lockMovement(hum, true)
				playWorkoutAnim(character)
				task.defer(function()
					if tool.Parent == character then
						attachGearAcrossFeet(character, tool)
					end
				end)
			end
		end)
	end

	table.insert(
		toolConns,
		tool.Equipped:Connect(function()
			startWorkoutFromEquip()
		end)
	)
	table.insert(
		toolConns,
		tool.Unequipped:Connect(function()
			onUnequip()
		end)
	)

	-- If already equipped when we bind (hotbar swap / respawn edge cases).
	if tool.Parent == player.Character then
		task.defer(startWorkoutFromEquip)
	end
end

local function scanTools(root: Instance?)
	if not root then
		return
	end
	for _, c in root:GetChildren() do
		if c:IsA("Tool") then
			bindTool(c)
		end
	end
end

local function bindCharacter(character: Model)
	clearToolConns()
	clearCharConns()
	cleanupWorkoutVisuals()
	scanTools(player:FindFirstChildOfClass("Backpack"))
	scanTools(character)
	table.insert(
		charConns,
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				bindTool(child)
				-- Hotbar swap onto a brainrot / lucky block: drop the workout.
				if child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) ~= true then
					if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
						onUnequip()
					end
				end
			end
		end)
	)
	table.insert(
		charConns,
		character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") and child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
					onUnequip()
				end
			end
		end)
	)
end

local function init()
	local backpack = player:WaitForChild("Backpack")
	scanTools(backpack)
	backpack.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(child)
		end
	end)

	if player.Character then
		bindCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		OtherVfxController.clearLevelUpVfx()
		bindCharacter(character)
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
			OtherVfxController.setWorkoutAuraEnabled(false)
			OtherVfxController.setWorkoutAuraEnabled(true)
		end
	end)

	player:GetAttributeChangedSignal("WorkoutPowerPulse"):Connect(function()
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			return
		end
		local character = player.Character
		if character then
			flashWhite(character)
		end
		-- LastGain can replicate a frame after the pulse (first gear especially).
		local function tryFloater(attempt: number)
			if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
				return
			end
			local gain = player:GetAttribute("WorkoutLastGain")
			local g = if typeof(gain) == "number" then gain else 0
			if g > 0 then
				spawnPowerFloater(g)
				return
			end
			if attempt < 6 then
				task.delay(0.08, function()
					tryFloater(attempt + 1)
				end)
			end
		end
		tryFloater(1)
		-- Don't snap the power number here — wait until the +N floater lands.
		if typeof(UpgradesController.snapPowerHud) == "function" then
			UpgradesController.snapPowerHud()
		end
	end)

	player:GetAttributeChangedSignal(GearConfig.WORKOUT_ACTIVE_ATTR):Connect(function()
		local on = player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true
		OtherVfxController.setWorkoutAuraEnabled(on)
		if on then
			startDoubleTapLoop()
			local character = player.Character
			if character then
				for _, child in character:GetChildren() do
					if child:IsA("Tool") and child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
						attachGearAcrossFeet(character, child)
						break
					end
				end
			end
		else
			cleanupWorkoutVisuals()
		end
	end)
	OtherVfxController.setWorkoutAuraEnabled(player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true)
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
		startDoubleTapLoop()
	end

	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= GamepadInput.ACCEPT then
			return
		end
		tryActivateOldestDoubleTap()
	end)
end

return {
	init = function()
		local ok, err = pcall(init)
		if not ok then
			warn("[WorkoutController] init error:", err)
		end
	end,
}
