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

type ObservedWorkout = {
	character: Model,
	tool: Tool,
	prop: Model,
	hidden: { BasePart },
}

local observedWorkouts: { [Player]: ObservedWorkout } = {}
local observedFollowConn: RBXScriptConnection? = nil
local observedPlayerConns: { [Player]: { RBXScriptConnection } } = {}
local observedCharChildConn: { [Player]: RBXScriptConnection } = {}

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

-- Stable shoe-top center in foot-local space (R15 local -Y is the sole).
local function footTopCenterLocal(foot: BasePart): Vector3
	local size = foot.Size
	return Vector3.new(0, -size.Y * 0.5 + 0.12, 0)
end

local function soleAcross(rf: BasePart, lf: BasePart?, _forwardHint: Vector3): (Vector3, Vector3, number)
	local t0 = rf.CFrame:PointToWorldSpace(footTopCenterLocal(rf))
	local t1 = if lf then lf.CFrame:PointToWorldSpace(footTopCenterLocal(lf)) else t0
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
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local any = false
	for _, d in model:GetDescendants() do
		if not isPoseMeshPart(d) then
			continue
		end
		any = true
		local p = d :: BasePart
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

local function restoreObservedTool(obs: ObservedWorkout)
	for _, part in obs.hidden do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	if obs.tool.Parent then
		for _, d in obs.tool:GetDescendants() do
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
end

local function clearObservedWorkout(plr: Player)
	local obs = observedWorkouts[plr]
	if not obs then
		return
	end
	restoreObservedTool(obs)
	if obs.prop.Parent then
		GearRainbowFX.detach(obs.prop)
		obs.prop:Destroy()
	end
	observedWorkouts[plr] = nil
end

local function ensureObservedFollow()
	if observedFollowConn then
		return
	end
	observedFollowConn = RunService.RenderStepped:Connect(function()
		for plr, obs in observedWorkouts do
			if not obs.prop.Parent or not obs.character.Parent or obs.tool.Parent ~= obs.character then
				clearObservedWorkout(plr)
			else
				poseGearOnFeet(obs.character, obs.prop)
			end
		end
		if next(observedWorkouts) == nil and observedFollowConn then
			observedFollowConn:Disconnect()
			observedFollowConn = nil
		end
	end)
end

local function findEquippedGearTool(character: Model): Tool?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
			return child
		end
	end
	return nil
end

local attachObservedWorkout: (Player) -> ()

attachObservedWorkout = function(plr: Player)
	if plr == player then
		return
	end
	if plr:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
		clearObservedWorkout(plr)
		return
	end
	local character = plr.Character
	if not character then
		clearObservedWorkout(plr)
		return
	end
	local tool = findEquippedGearTool(character)
	if not tool then
		clearObservedWorkout(plr)
		return
	end
	local existing = observedWorkouts[plr]
	if existing and existing.tool == tool and existing.prop.Parent then
		return
	end
	clearObservedWorkout(plr)

	local rightFoot, leftFoot = findFeet(character)
	if not (rightFoot or leftFoot) then
		task.delay(0.4, function()
			if plr.Parent and plr:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
				attachObservedWorkout(plr)
			end
		end)
		return
	end

	local gearId = tool:GetAttribute(GearConfig.GEAR_ID_ATTR)
	if typeof(gearId) ~= "number" then
		return
	end
	local model = GearConfig.cloneGearModel(gearId)
	if not model then
		return
	end
	model.Name = "WorkoutFootPropOther"
	model:SetAttribute(GearConfig.GEAR_ID_ATTR, gearId)
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
		return
	end
	model.PrimaryPart = primary

	local hidden: { BasePart } = {}
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 1
			table.insert(hidden, d)
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

	model.Parent = ensureWorldFolder()
	poseGearOnFeet(character, model)
	observedWorkouts[plr] = {
		character = character,
		tool = tool,
		prop = model,
		hidden = hidden,
	}
	if tool:GetAttribute("RainbowGear") == true then
		GearRainbowFX.attach(model)
	end
	ensureObservedFollow()
end

local function bindObservedPlayer(plr: Player)
	if plr == player then
		return
	end
	if observedPlayerConns[plr] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	observedPlayerConns[plr] = conns
	table.insert(
		conns,
		plr:GetAttributeChangedSignal(GearConfig.WORKOUT_ACTIVE_ATTR):Connect(function()
			attachObservedWorkout(plr)
		end)
	)
	local function hookCharacter(character: Model)
		local prev = observedCharChildConn[plr]
		if prev then
			prev:Disconnect()
		end
		observedCharChildConn[plr] = character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child:GetAttribute(GearConfig.GEAR_TOOL_ATTR) == true then
				attachObservedWorkout(plr)
			end
		end)
	end
	table.insert(
		conns,
		plr.CharacterAdded:Connect(function(character)
			task.defer(function()
				hookCharacter(character)
				attachObservedWorkout(plr)
			end)
		end)
	)
	if plr.Character then
		hookCharacter(plr.Character)
	end
	attachObservedWorkout(plr)
end

local function unbindObservedPlayer(plr: Player)
	clearObservedWorkout(plr)
	local conns = observedPlayerConns[plr]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		observedPlayerConns[plr] = nil
	end
	local childConn = observedCharChildConn[plr]
	if childConn then
		childConn:Disconnect()
		observedCharChildConn[plr] = nil
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
	local comboAttr = player:GetAttribute("WorkoutCombo")
	local comboN = if typeof(comboAttr) == "number" then comboAttr else 1
	local lift = GearConfig.workoutLiftMultiplier(comboN)
	track:AdjustSpeed(1 + (lift - 1) * 0.28)
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

local doubleTapGen = 0
local doubleTapGui: ScreenGui? = nil
local claimDoubleTapBusy = false
local comboRingConn: RBXScriptConnection? = nil
local comboPreferredConn: RBXScriptConnection? = nil
local comboShakeConn: RBXScriptConnection? = nil
local comboTrailConn: RBXScriptConnection? = nil
local comboRingBorn = 0.0
local comboAppearAt = 0.0
local comboWindow = 1.55
local comboBusyAnim = false
local lastComboPos = Vector2.new(-999, -999)
-- Face buttons only. Never B (cancel / back) or bumpers / D-pad (hotbar unequip).
local COMBO_PAD_KEYS = { Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonY }
local comboPromptKey = Enum.KeyCode.ButtonA
local COMBO_GOLD = Color3.fromRGB(255, 214, 74)
local COMBO_DANGER = Color3.fromRGB(255, 62, 52)
local COMBO_RING_START = 1.18
local COMBO_RING_END = 1.0
local COMBO_CORE_FILL = 0.22
local PAD_BADGE_COLOR: { [Enum.KeyCode]: Color3 } = {
	[Enum.KeyCode.ButtonA] = Color3.fromRGB(86, 196, 78),
	[Enum.KeyCode.ButtonX] = Color3.fromRGB(68, 138, 255),
	[Enum.KeyCode.ButtonY] = Color3.fromRGB(255, 208, 58),
}

local function comboWindowFor(n: number): number
	local lift = GearConfig.workoutLiftMultiplier(n)
	return math.clamp(1.48 - (lift - 1) * 0.22, 1.05, 1.48)
end

local function comboAnimSpeedFor(n: number): number
	local lift = GearConfig.workoutLiftMultiplier(n)
	return 1 + (lift - 1) * 0.28
end

local function applyComboAnimSpeed(n: number)
	if workoutTrack then
		workoutTrack:AdjustSpeed(comboAnimSpeedFor(n))
	end
end

local function burstComboLine()
	if not footProp or not footProp.Parent then
		return
	end
	local part = footProp.PrimaryPart or footProp:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "WorkoutComboBurst0"
	a0.Position = Vector3.zero
	local a1 = Instance.new("Attachment")
	a1.Name = "WorkoutComboBurst1"
	a1.Position = Vector3.new(0, 9.5, 0)
	local beam = Instance.new("Beam")
	beam.Name = "WorkoutComboBurst"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.LightEmission = 0.85
	beam.LightInfluence = 0
	beam.Width0 = 0.55
	beam.Width1 = 0.04
	beam.Segments = 10
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 214, 74), Color3.fromRGB(255, 120, 40))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	a0.Parent = part
	a1.Parent = part
	beam.Parent = part
	TweenService:Create(beam, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Width0 = 0.02,
		Width1 = 0.01,
	}):Play()
	task.delay(0.32, function()
		if beam.Parent then
			beam:Destroy()
		end
		if a0.Parent then
			a0:Destroy()
		end
		if a1.Parent then
			a1:Destroy()
		end
	end)
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
	gui.Name = "WorkoutComboGui"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 118
	gui.Enabled = true

	local trailLayer = Instance.new("Frame")
	trailLayer.Name = "ApproachTrail"
	trailLayer.BackgroundTransparency = 1
	trailLayer.Size = UDim2.fromScale(1, 1)
	trailLayer.ZIndex = 12
	trailLayer.Active = false
	trailLayer.Parent = gui
	local line = Instance.new("Frame")
	line.Name = "ApproachLine"
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.BackgroundColor3 = Color3.fromRGB(255, 236, 180)
	line.BackgroundTransparency = 1
	line.BorderSizePixel = 0
	line.Size = UDim2.fromOffset(11, 20)
	line.Visible = false
	line.ZIndex = 12
	line.Parent = trailLayer
	local lineCorner = Instance.new("UICorner")
	lineCorner.CornerRadius = UDim.new(1, 0)
	lineCorner.Parent = line
	local glow = Instance.new("Frame")
	glow.Name = "ApproachGlow"
	glow.AnchorPoint = Vector2.new(0.5, 0)
	glow.BackgroundColor3 = Color3.fromRGB(255, 220, 140)
	glow.BackgroundTransparency = 1
	glow.BorderSizePixel = 0
	glow.Size = UDim2.fromOffset(26, 20)
	glow.Visible = false
	glow.ZIndex = 11
	glow.Parent = trailLayer
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = glow
	for i = 1, 22 do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.BackgroundColor3 = Color3.fromRGB(255, 244, 200)
		pip.BackgroundTransparency = 1
		pip.BorderSizePixel = 0
		pip.AnchorPoint = Vector2.new(0.5, 0.5)
		pip.Size = UDim2.fromOffset(16, 16)
		pip.Visible = false
		pip.ZIndex = 13
		pip.Parent = trailLayer
		local pipCorner = Instance.new("UICorner")
		pipCorner.CornerRadius = UDim.new(1, 0)
		pipCorner.Parent = pip
		local pipStroke = Instance.new("UIStroke")
		pipStroke.Name = "PipStroke"
		pipStroke.Color = Color3.fromRGB(255, 214, 74)
		pipStroke.Thickness = 2
		pipStroke.Transparency = 1
		pipStroke.Parent = pip
	end

	local holder = Instance.new("Frame")
	holder.Name = "ComboHold"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.74, 0)
	holder.Size = UDim2.fromOffset(132, 132)
	holder.ZIndex = 20
	holder.Parent = gui

	local pop = Instance.new("UIScale")
	pop.Name = "PopScale"
	pop.Scale = 1
	pop.Parent = holder

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.BackgroundColor3 = Color3.fromRGB(8, 6, 14)
	shadow.BackgroundTransparency = 0.78
	shadow.BorderSizePixel = 0
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 5)
	shadow.Size = UDim2.fromScale(0.58, 0.58)
	shadow.ZIndex = 20
	shadow.Parent = holder
	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(1, 0)
	shadowCorner.Parent = shadow

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1, 1)
	ring.ZIndex = 21
	ring.Parent = holder
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Name = "RingStroke"
	ringStroke.Color = Color3.fromRGB(255, 214, 74)
	ringStroke.Thickness = 7
	ringStroke.Transparency = 0.04
	ringStroke.LineJoinMode = Enum.LineJoinMode.Round
	ringStroke.Parent = ring
	local ringScale = Instance.new("UIScale")
	ringScale.Name = "RingScale"
	ringScale.Scale = COMBO_RING_START
	ringScale.Parent = ring

	local halo = Instance.new("Frame")
	halo.Name = "Halo"
	halo.BackgroundColor3 = Color3.fromRGB(255, 214, 74)
	halo.BackgroundTransparency = 0.9
	halo.BorderSizePixel = 0
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromScale(0.78, 0.78)
	halo.ZIndex = 21
	halo.Parent = holder
	local haloCorner = Instance.new("UICorner")
	haloCorner.CornerRadius = UDim.new(1, 0)
	haloCorner.Parent = halo

	local ripple = Instance.new("Frame")
	ripple.Name = "HitRipple"
	ripple.BackgroundTransparency = 1
	ripple.AnchorPoint = Vector2.new(0.5, 0.5)
	ripple.Position = UDim2.fromScale(0.5, 0.5)
	ripple.Size = UDim2.fromScale(1, 1)
	ripple.Visible = false
	ripple.ZIndex = 21
	ripple.Parent = holder
	local rippleCorner = Instance.new("UICorner")
	rippleCorner.CornerRadius = UDim.new(1, 0)
	rippleCorner.Parent = ripple
	local rippleStroke = Instance.new("UIStroke")
	rippleStroke.Name = "RippleStroke"
	rippleStroke.Color = Color3.fromRGB(255, 248, 200)
	rippleStroke.Thickness = 6
	rippleStroke.Transparency = 0.08
	rippleStroke.Parent = ripple
	local rippleScale = Instance.new("UIScale")
	rippleScale.Name = "RippleScale"
	rippleScale.Scale = 0.7
	rippleScale.Parent = ripple

	local core = Instance.new("ImageButton")
	core.Name = "Hit"
	core.BackgroundColor3 = Color3.fromRGB(22, 16, 38)
	core.BackgroundTransparency = COMBO_CORE_FILL
	core.BorderSizePixel = 0
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromScale(0.62, 0.62)
	core.AutoButtonColor = false
	core.Image = ""
	core.Active = true
	core.Selectable = true
	core.ZIndex = 22
	core.Parent = holder
	local coreCorner = Instance.new("UICorner")
	coreCorner.CornerRadius = UDim.new(1, 0)
	coreCorner.Parent = core
	local coreGrad = Instance.new("UIGradient")
	coreGrad.Name = "HitGrad"
	coreGrad.Rotation = 90
	coreGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(48, 36, 78)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 10, 24)),
	})
	coreGrad.Parent = core
	local coreStroke = Instance.new("UIStroke")
	coreStroke.Name = "HitStroke"
	coreStroke.Color = Color3.fromRGB(255, 228, 130)
	coreStroke.Thickness = 2.5
	coreStroke.Transparency = 0.12
	coreStroke.Parent = core
	local num = Instance.new("TextLabel")
	num.Name = "ComboNum"
	num.BackgroundTransparency = 1
	num.Size = UDim2.fromScale(1, 1)
	num.Text = "1"
	num.TextColor3 = Color3.fromRGB(255, 246, 210)
	num.TextScaled = true
	num.Font = Enum.Font.GothamBlack
	num.ZIndex = 23
	num.Parent = core
	UiFonts.applyDisplay(num)
	local numStroke = Instance.new("UIStroke")
	numStroke.Color = Color3.fromRGB(40, 22, 8)
	numStroke.Thickness = 2
	numStroke.Transparency = 0.25
	numStroke.Parent = num
	local numPad = Instance.new("UIPadding")
	numPad.PaddingTop = UDim.new(0, 10)
	numPad.PaddingBottom = UDim.new(0, 10)
	numPad.PaddingLeft = UDim.new(0, 8)
	numPad.PaddingRight = UDim.new(0, 8)
	numPad.Parent = num

	local prompt = Instance.new("Frame")
	prompt.Name = "PadPrompt"
	prompt.BackgroundColor3 = Color3.fromRGB(86, 196, 78)
	prompt.BorderSizePixel = 0
	prompt.AnchorPoint = Vector2.new(0.5, 0.5)
	prompt.Position = UDim2.fromScale(0.5, 0.5)
	prompt.Size = UDim2.fromOffset(48, 48)
	prompt.Visible = false
	prompt.ZIndex = 24
	prompt.Parent = core
	local promptCorner = Instance.new("UICorner")
	promptCorner.CornerRadius = UDim.new(1, 0)
	promptCorner.Parent = prompt
	local promptStroke = Instance.new("UIStroke")
	promptStroke.Color = Color3.fromRGB(255, 255, 255)
	promptStroke.Thickness = 2
	promptStroke.Transparency = 0.12
	promptStroke.Parent = prompt
	local promptIcon = Instance.new("ImageLabel")
	promptIcon.Name = "PadIcon"
	promptIcon.BackgroundTransparency = 1
	promptIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	promptIcon.Position = UDim2.fromScale(0.5, 0.5)
	promptIcon.Size = UDim2.fromScale(0.72, 0.72)
	promptIcon.ScaleType = Enum.ScaleType.Fit
	promptIcon.ZIndex = 25
	promptIcon.Parent = prompt
	local promptText = Instance.new("TextLabel")
	promptText.Name = "PadText"
	promptText.BackgroundTransparency = 1
	promptText.Size = UDim2.fromScale(1, 1)
	promptText.Font = Enum.Font.GothamBlack
	promptText.TextScaled = true
	promptText.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptText.Visible = false
	promptText.ZIndex = 25
	promptText.Parent = prompt

	local stats = Instance.new("Frame")
	stats.Name = "ComboStats"
	stats.BackgroundTransparency = 1
	stats.AnchorPoint = Vector2.new(0.5, 0)
	stats.Position = UDim2.new(0.5, 0, 1, 8)
	stats.Size = UDim2.fromOffset(220, 52)
	stats.ZIndex = 24
	stats.Parent = holder
	local statsList = Instance.new("UIListLayout")
	statsList.FillDirection = Enum.FillDirection.Vertical
	statsList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	statsList.VerticalAlignment = Enum.VerticalAlignment.Top
	statsList.Padding = UDim.new(0, 0)
	statsList.Parent = stats
	local comboLabel = Instance.new("TextLabel")
	comboLabel.Name = "ComboLabel"
	comboLabel.BackgroundTransparency = 1
	comboLabel.Size = UDim2.new(1, 0, 0, 26)
	comboLabel.Text = "COMBO 1"
	comboLabel.TextColor3 = Color3.fromRGB(255, 246, 210)
	comboLabel.TextScaled = true
	comboLabel.Font = Enum.Font.GothamBlack
	comboLabel.ZIndex = 24
	comboLabel.Parent = stats
	UiFonts.applyDisplay(comboLabel)
	local comboStroke = Instance.new("UIStroke")
	comboStroke.Color = Color3.fromRGB(20, 12, 6)
	comboStroke.Thickness = 1.6
	comboStroke.Transparency = 0.2
	comboStroke.Parent = comboLabel
	local liftLabel = Instance.new("TextLabel")
	liftLabel.Name = "LiftLabel"
	liftLabel.BackgroundTransparency = 1
	liftLabel.Size = UDim2.new(1, 0, 0, 24)
	liftLabel.Text = "LIFT x1.0"
	liftLabel.TextColor3 = Color3.fromRGB(255, 214, 74)
	liftLabel.TextScaled = true
	liftLabel.Font = Enum.Font.GothamBlack
	liftLabel.ZIndex = 24
	liftLabel.Parent = stats
	UiFonts.applyDisplay(liftLabel)
	local liftStroke = Instance.new("UIStroke")
	liftStroke.Color = Color3.fromRGB(20, 12, 6)
	liftStroke.Thickness = 1.6
	liftStroke.Transparency = 0.2
	liftStroke.Parent = liftLabel

	if pg then
		gui.Parent = pg
	end
	doubleTapGui = gui
	return gui
end

local function comboDisplay(): number
	local v = player:GetAttribute("WorkoutCombo")
	if typeof(v) == "number" then
		return math.max(1, math.floor(v))
	end
	return 1
end

local function isComboPadKey(code: Enum.KeyCode): boolean
	for _, key in COMBO_PAD_KEYS do
		if key == code then
			return true
		end
	end
	return false
end

local function pickNextComboKey()
	local choices: { Enum.KeyCode } = {}
	for _, key in COMBO_PAD_KEYS do
		if key ~= comboPromptKey then
			table.insert(choices, key)
		end
	end
	if #choices == 0 then
		comboPromptKey = Enum.KeyCode.ButtonA
		return
	end
	comboPromptKey = choices[math.random(1, #choices)]
end

local function refreshComboHud(n: number)
	local gui = doubleTapGui
	local holder = gui and gui:FindFirstChild("ComboHold")
	if not (holder and holder:IsA("Frame")) then
		return
	end
	local count = math.max(1, math.floor(n))
	local lift = GearConfig.workoutLiftMultiplier(count)
	local hit = holder:FindFirstChild("Hit")
	local num = hit and hit:FindFirstChild("ComboNum")
	local prompt = hit and hit:FindFirstChild("PadPrompt")
	local stats = holder:FindFirstChild("ComboStats")
	local comboLabel = stats and stats:FindFirstChild("ComboLabel")
	local liftLabel = stats and stats:FindFirstChild("LiftLabel")
	local pad = GamepadInput.isPreferred()
	local touch = UserInputService.TouchEnabled and not pad
	if comboLabel and comboLabel:IsA("TextLabel") then
		comboLabel.Text = "COMBO " .. tostring(count)
		comboLabel.Visible = pad or touch
	end
	if liftLabel and liftLabel:IsA("TextLabel") then
		liftLabel.Text = string.format("x%.2f", lift)
		liftLabel.TextColor3 = if lift >= GearConfig.WORKOUT_LIFT_MULT_MAX - 0.05
			then Color3.fromRGB(255, 236, 120)
			else Color3.fromRGB(255, 214, 74)
		liftLabel.Visible = true
	end
	if stats and stats:IsA("GuiObject") then
		stats.Visible = true
	end
	if num and num:IsA("TextLabel") then
		num.Text = tostring(count)
		num.Visible = false
	end
	if prompt and prompt:IsA("GuiObject") then
		prompt.Visible = pad
		if prompt:IsA("Frame") then
			prompt.BackgroundColor3 = PAD_BADGE_COLOR[comboPromptKey] or Color3.fromRGB(86, 196, 78)
		end
		local icon = prompt:FindFirstChild("PadIcon")
		local caption = prompt:FindFirstChild("PadText")
		if icon and icon:IsA("ImageLabel") then
			icon.Visible = false
		end
		if caption and caption:IsA("TextLabel") then
			caption.Text = GamepadInput.faceLabel(comboPromptKey)
			caption.Visible = pad
		end
	end
end

local function setComboRingScale(scale: number)
	local gui = doubleTapGui
	if not gui then
		return
	end
	local holder = gui:FindFirstChild("ComboHold")
	local ring = holder and holder:FindFirstChild("Ring")
	local ringScale = ring and ring:FindFirstChild("RingScale")
	if ringScale and ringScale:IsA("UIScale") then
		ringScale.Scale = scale
	end
end

local function setComboNumber(n: number)
	local gui = doubleTapGui
	if not gui then
		return
	end
	local holder = gui:FindFirstChild("ComboHold")
	local hit = holder and holder:FindFirstChild("Hit")
	local num = hit and hit:FindFirstChild("ComboNum")
	if num and num:IsA("TextLabel") then
		num.Text = tostring(math.max(1, math.floor(n)))
	end
	refreshComboHud(n)
end

local function comboHolder(): Frame?
	local gui = doubleTapGui
	local holder = gui and gui:FindFirstChild("ComboHold")
	if holder and holder:IsA("Frame") then
		return holder
	end
	return nil
end

local function paintComboUrgency(t: number)
	local holder = comboHolder()
	if not holder then
		return
	end
	local u = math.clamp((t - 0.52) / 0.48, 0, 1)
	u *= u
	local color = COMBO_GOLD:Lerp(COMBO_DANGER, u)
	local ring = holder:FindFirstChild("Ring")
	local stroke = ring and ring:FindFirstChild("RingStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = color
		stroke.Transparency = 0.08
		stroke.Thickness = 7 + u * 3.5
	end
	local halo = holder:FindFirstChild("Halo")
	if halo and halo:IsA("Frame") then
		halo.BackgroundColor3 = color
		halo.BackgroundTransparency = 0.9 - u * 0.35
	end
	local hit = holder:FindFirstChild("Hit")
	local hitStroke = hit and hit:FindFirstChild("HitStroke")
	if hitStroke and hitStroke:IsA("UIStroke") then
		hitStroke.Color = Color3.fromRGB(255, 228, 130):Lerp(COMBO_DANGER, u)
		hitStroke.Thickness = 2.5 + u * 1.8
	end
end

local function playComboAppear()
	local holder = comboHolder()
	if not holder then
		return
	end
	comboAppearAt = os.clock()
	holder.Visible = true
	local pop = holder:FindFirstChild("PopScale")
	if pop and pop:IsA("UIScale") then
		pop.Scale = 0.56
		TweenService:Create(pop, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	local ring = holder:FindFirstChild("Ring")
	local stroke = ring and ring:FindFirstChild("RingStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Transparency = 1
		TweenService:Create(stroke, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 0.08 }):Play()
	end
	local halo = holder:FindFirstChild("Halo")
	if halo and halo:IsA("GuiObject") then
		halo.BackgroundTransparency = 1
		TweenService:Create(halo, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.9 }):Play()
	end
	local hit = holder:FindFirstChild("Hit")
	if hit and hit:IsA("GuiObject") then
		hit.BackgroundTransparency = 1
		TweenService:Create(hit, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = COMBO_CORE_FILL }):Play()
	end
	local num = hit and hit:FindFirstChild("ComboNum")
	if num and num:IsA("TextLabel") then
		num.TextTransparency = 1
		TweenService:Create(num, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextTransparency = 0 }):Play()
	end
	local prompt = hit and hit:FindFirstChild("PadPrompt")
	if prompt and prompt:IsA("GuiObject") then
		prompt.BackgroundTransparency = 1
		TweenService:Create(prompt, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0 }):Play()
	end
end

local function paintComboIdle(appear: boolean?)
	local holder = comboHolder()
	if not holder then
		return
	end
	holder.Visible = true
	local pop = holder:FindFirstChild("PopScale")
	if pop and pop:IsA("UIScale") then
		pop.Scale = 1
	end
	paintComboUrgency(0)
	local hit = holder:FindFirstChild("Hit")
	if hit and hit:IsA("GuiObject") then
		hit.BackgroundColor3 = Color3.fromRGB(22, 16, 38)
		hit.BackgroundTransparency = COMBO_CORE_FILL
	end
	local num = hit and hit:FindFirstChild("ComboNum")
	if num and num:IsA("TextLabel") then
		num.TextTransparency = 0
		num.TextColor3 = Color3.fromRGB(255, 246, 210)
	end
	refreshComboHud(comboDisplay())
	if appear ~= false then
		playComboAppear()
	end
end

local function stopComboShake()
	if comboShakeConn then
		comboShakeConn:Disconnect()
		comboShakeConn = nil
	end
end

local function hideApproachTrail()
	local gui = doubleTapGui
	local layer = gui and gui:FindFirstChild("ApproachTrail")
	if not layer then
		return
	end
	local line = layer:FindFirstChild("ApproachLine")
	if line and line:IsA("GuiObject") then
		line.Visible = false
		line.BackgroundTransparency = 1
	end
	local glow = layer:FindFirstChild("ApproachGlow")
	if glow and glow:IsA("GuiObject") then
		glow.Visible = false
		glow.BackgroundTransparency = 1
	end
	for _, ch in layer:GetChildren() do
		if string.sub(ch.Name, 1, 3) ~= "Pip" or not ch:IsA("Frame") then
			continue
		end
		ch.Visible = false
		ch.BackgroundTransparency = 1
		local stroke = ch:FindFirstChild("PipStroke")
		if stroke and stroke:IsA("UIStroke") then
			stroke.Transparency = 1
		end
	end
end

local function stopComboTrail()
	if comboTrailConn then
		comboTrailConn:Disconnect()
		comboTrailConn = nil
	end
	hideApproachTrail()
end

local function shakeComboHold(basePos: UDim2)
	stopComboShake()
	local holder = comboHolder()
	if not holder then
		return
	end
	local born = os.clock()
	local dur = 0.42
	comboShakeConn = RunService.Heartbeat:Connect(function()
		local t = os.clock() - born
		if t >= dur or not holder.Parent then
			stopComboShake()
			if holder.Parent then
				holder.Position = basePos
			end
			return
		end
		local fade = 1 - t / dur
		local mag = 18 * fade * fade
		holder.Position = basePos + UDim2.fromOffset(math.sin(t * 82) * mag, math.cos(t * 96) * mag * 0.82)
	end)
end

local function playComboApproachTrail(from: Vector2, to: Vector2)
	local gui = doubleTapGui
	local layer = gui and gui:FindFirstChild("ApproachTrail")
	if not layer then
		return
	end
	local delta = to - from
	if delta.Magnitude < 36 then
		return
	end
	stopComboTrail()
	local pips: { Frame } = {}
	for _, ch in layer:GetChildren() do
		if string.sub(ch.Name, 1, 3) == "Pip" and ch:IsA("Frame") then
			table.insert(pips, ch)
		end
	end
	local n = math.max(1, #pips)
	local dist = delta.Magnitude
	local rot = math.deg(math.atan2(delta.X, delta.Y))
	local line = layer:FindFirstChild("ApproachLine")
	local glow = layer:FindFirstChild("ApproachGlow")
	local born = os.clock()
	local dur = 0.48
	comboTrailConn = RunService.Heartbeat:Connect(function()
		if not layer.Parent then
			stopComboTrail()
			return
		end
		local t = math.clamp((os.clock() - born) / dur, 0, 1)
		local ease = t * t * (3 - 2 * t)
		local remain = 1 - ease
		if glow and glow:IsA("Frame") then
			glow.Visible = remain > 0.02
			glow.Position = UDim2.fromOffset(from.X + delta.X * ease, from.Y + delta.Y * ease)
			glow.Size = UDim2.fromOffset(26, dist * remain)
			glow.Rotation = rot
			glow.BackgroundTransparency = 0.42 + ease * 0.5
		end
		if line and line:IsA("Frame") then
			line.Visible = false
		end
		for i, pip in pips do
			local delay = (i - 1) / n * 0.12
			local localT = math.clamp((t - delay) / 0.88, 0, 1)
			local slide = localT * localT * (3 - 2 * localT)
			local p = from:Lerp(to, slide)
			local fade = if localT < 0.72 then 0 else math.clamp((localT - 0.72) / 0.28, 0, 1)
			local size = 16 + (1 - fade) * 16
			pip.Position = UDim2.fromOffset(p.X, p.Y)
			pip.Size = UDim2.fromOffset(size, size)
			pip.BackgroundTransparency = 0.02 + fade
			pip.Visible = localT > 0 and fade < 0.98
			local stroke = pip:FindFirstChild("PipStroke")
			if stroke and stroke:IsA("UIStroke") then
				stroke.Thickness = 2.2
				stroke.Transparency = 0.08 + fade * 0.88
			end
		end
		if t >= 1 then
			stopComboTrail()
		end
	end)
end

local function placeComboHold()
	local holder = comboHolder()
	if not holder then
		return
	end
	local cam = Workspace.CurrentCamera
	local vs = if cam then cam.ViewportSize else Vector2.new(800, 600)
	local padX = math.max(110, vs.X * 0.16)
	local padY = math.max(140, vs.Y * 0.2)
	local spanX = math.max(8, vs.X - padX * 2)
	local spanY = math.max(8, vs.Y - padY * 2)
	local minJump = math.min(170, vs.Y * 0.24)
	local pos = lastComboPos
	for _ = 1, 16 do
		local candidate = Vector2.new(padX + math.random() * spanX, padY + math.random() * spanY)
		if (candidate - lastComboPos).Magnitude >= minJump then
			pos = candidate
			break
		end
		pos = candidate
	end
	local from = lastComboPos
	lastComboPos = pos
	holder.Position = UDim2.fromOffset(pos.X, pos.Y)
	if from.X > 0 and (pos - from).Magnitude >= 36 then
		playComboApproachTrail(from, pos)
	end
	pickNextComboKey()
	refreshComboHud(comboDisplay())
end

local function pulseComboHold(ok: boolean)
	local gui = doubleTapGui
	if not gui then
		return
	end
	local holder = gui:FindFirstChild("ComboHold")
	local pop = holder and holder:FindFirstChild("PopScale")
	if pop and pop:IsA("UIScale") then
		pop.Scale = if ok then 1.55 else 0.78
		TweenService:Create(
			pop,
			TweenInfo.new(if ok then 0.28 else 0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end
	if not ok or not holder then
		return
	end
	local hit = holder:FindFirstChild("Hit")
	if hit and hit:IsA("GuiObject") then
		hit.BackgroundColor3 = Color3.fromRGB(255, 236, 140)
		TweenService:Create(hit, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = Color3.fromRGB(22, 16, 38),
		}):Play()
	end
	local num = hit and hit:FindFirstChild("ComboNum")
	if num and num:IsA("TextLabel") then
		num.TextColor3 = Color3.fromRGB(255, 255, 255)
		TweenService:Create(num, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			TextColor3 = Color3.fromRGB(255, 246, 210),
		}):Play()
	end
	local ripple = holder:FindFirstChild("HitRipple")
	local rippleScale = ripple and ripple:FindFirstChild("RippleScale")
	local rippleStroke = ripple and ripple:FindFirstChild("RippleStroke")
	if ripple and ripple:IsA("GuiObject") and rippleScale and rippleScale:IsA("UIScale") then
		ripple.Visible = true
		rippleScale.Scale = 0.62
		if rippleStroke and rippleStroke:IsA("UIStroke") then
			rippleStroke.Transparency = 0.05
			rippleStroke.Thickness = 7
			TweenService:Create(rippleStroke, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1,
				Thickness = 2,
			}):Play()
		end
		local tw = TweenService:Create(
			rippleScale,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1.85 }
		)
		tw:Play()
		tw.Completed:Connect(function()
			if ripple.Parent then
				ripple.Visible = false
			end
		end)
	end
end

local function restartComboRing()
	comboRingBorn = os.clock()
	comboWindow = comboWindowFor(comboDisplay())
	setComboRingScale(COMBO_RING_START)
end

local function missCombo()
	if comboBusyAnim then
		return
	end
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
		return
	end
	comboBusyAnim = true
	setComboNumber(1)
	applyComboAnimSpeed(1)
	GameSoundEffects.playWorkoutComboFail()
	local holder = comboHolder()
	local gen = doubleTapGen
	if holder then
		shakeComboHold(holder.Position)
		local pop = holder:FindFirstChild("PopScale")
		local ring = holder:FindFirstChild("Ring")
		local stroke = ring and ring:FindFirstChild("RingStroke")
		local hit = holder:FindFirstChild("Hit")
		local num = hit and hit:FindFirstChild("ComboNum")
		if stroke and stroke:IsA("UIStroke") then
			stroke.Color = Color3.fromRGB(255, 72, 72)
			TweenService:Create(stroke, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
		end
		if hit and hit:IsA("GuiObject") then
			hit.BackgroundColor3 = Color3.fromRGB(90, 18, 22)
			TweenService:Create(hit, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			}):Play()
		end
		if num and num:IsA("TextLabel") then
			num.TextColor3 = Color3.fromRGB(255, 120, 120)
			TweenService:Create(num, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			}):Play()
		end
		if pop and pop:IsA("UIScale") then
			TweenService:Create(
				pop,
				TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Scale = 0.12 }
			):Play()
		end
	end
	task.spawn(function()
		waitForWorkoutRemote("ClaimWorkoutDoubleTap")
		if claimDoubleTapFn and claimDoubleTapFn.Parent then
			local ok, err = pcall(function()
				claimDoubleTapFn:InvokeServer(false)
			end)
			if not ok then
				warn("[WorkoutController] combo miss failed:", err)
			end
		end
	end)
	task.delay(0.38, function()
		if gen ~= doubleTapGen then
			return
		end
		local gone = comboHolder()
		if gone then
			gone.Visible = false
		end
	end)
	task.delay(1.05, function()
		if gen ~= doubleTapGen or player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			comboBusyAnim = false
			return
		end
		placeComboHold()
		paintComboIdle()
		comboBusyAnim = false
		restartComboRing()
	end)
end

local function hitCombo()
	if comboBusyAnim then
		return
	end
	if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
		return
	end
	if claimDoubleTapBusy then
		return
	end
	claimDoubleTapBusy = true
	burstComboLine()
	GameSoundEffects.playWorkoutComboHit(comboDisplay())
	pulseComboHold(true)
	local gen = doubleTapGen
	task.delay(0.14, function()
		if gen ~= doubleTapGen or player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			return
		end
		placeComboHold()
		paintComboIdle(false)
		restartComboRing()
	end)
	task.spawn(function()
		waitForWorkoutRemote("ClaimWorkoutDoubleTap")
		local n = comboDisplay()
		if claimDoubleTapFn and claimDoubleTapFn.Parent then
			local ok, result = pcall(function()
				return claimDoubleTapFn:InvokeServer()
			end)
			if not ok then
				warn("[WorkoutController] combo hit failed:", result)
			elseif typeof(result) == "number" then
				n = result
			end
		end
		claimDoubleTapBusy = false
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) == true then
			setComboNumber(n)
			applyComboAnimSpeed(n)
		end
	end)
end

local function stopDoubleTapLoop()
	doubleTapGen += 1
	comboBusyAnim = false
	if comboRingConn then
		comboRingConn:Disconnect()
		comboRingConn = nil
	end
	if comboPreferredConn then
		comboPreferredConn:Disconnect()
		comboPreferredConn = nil
	end
	stopComboShake()
	stopComboTrail()
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
	hitCombo()
	return true
end

local function startDoubleTapLoop()
	if comboRingConn then
		comboRingConn:Disconnect()
		comboRingConn = nil
	end
	stopComboShake()
	stopComboTrail()
	if doubleTapGui then
		doubleTapGui:Destroy()
		doubleTapGui = nil
	end
	pcall(function()
		ContextActionService:UnbindAction(DOUBLE_TAP_ACTION)
	end)
	if comboPreferredConn then
		comboPreferredConn:Disconnect()
		comboPreferredConn = nil
	end
	doubleTapGen += 1
	local gen = doubleTapGen
	comboBusyAnim = false
	lastComboPos = Vector2.new(-999, -999)
	comboPromptKey = COMBO_PAD_KEYS[math.random(1, #COMBO_PAD_KEYS)]
	ensureDoubleTapGui()
	placeComboHold()
	paintComboIdle()
	setComboNumber(comboDisplay())
	applyComboAnimSpeed(comboDisplay())
	restartComboRing()
	if comboRingConn then
		comboRingConn:Disconnect()
		comboRingConn = nil
	end
	comboRingConn = RunService.Heartbeat:Connect(function()
		if gen ~= doubleTapGen or player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			return
		end
		if comboBusyAnim then
			return
		end
		local t = (os.clock() - comboRingBorn) / math.max(comboWindow, 0.35)
		if t >= 1 then
			missCombo()
			return
		end
		setComboRingScale(COMBO_RING_START - t * (COMBO_RING_START - COMBO_RING_END))
		paintComboUrgency(t)
		local holder = comboHolder()
		if holder and lastComboPos.X > 0 and os.clock() - comboAppearAt > 0.3 then
			local bob = math.sin(os.clock() * 2.15) * 4.5
			local sway = math.sin(os.clock() * 1.35) * 2.2
			holder.Position = UDim2.fromOffset(lastComboPos.X + sway, lastComboPos.Y + bob)
		end
	end)
	comboPreferredConn = GamepadInput.onPreferredChanged(function()
		if gen == doubleTapGen then
			refreshComboHud(comboDisplay())
		end
	end)
	ContextActionService:BindActionAtPriority(
		DOUBLE_TAP_ACTION,
		function(_name, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
				return Enum.ContextActionResult.Pass
			end
			local code = if input then input.KeyCode else comboPromptKey
			if GamepadInput.isPreferred() then
				if code == comboPromptKey then
					hitCombo()
					return Enum.ContextActionResult.Sink
				end
				if isComboPadKey(code) then
					missCombo()
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end
			-- Keyboard / mouse: don't steal jump (A) or other face buttons.
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.ContextActionPriority.High.Value + 80,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonX,
		Enum.KeyCode.ButtonY
	)
	local gui = doubleTapGui
	local holder = gui and gui:FindFirstChild("ComboHold")
	local hit = holder and holder:FindFirstChild("Hit")
	if hit and hit:IsA("GuiButton") then
		hit.Activated:Connect(function()
			if gen ~= doubleTapGen then
				return
			end
			if GamepadInput.isPreferred() then
				return
			end
			hitCombo()
		end)
	end
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

	player:GetAttributeChangedSignal("WorkoutCombo"):Connect(function()
		if player:GetAttribute(GearConfig.WORKOUT_ACTIVE_ATTR) ~= true then
			return
		end
		local n = comboDisplay()
		setComboNumber(n)
		applyComboAnimSpeed(n)
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

	Players.PlayerAdded:Connect(bindObservedPlayer)
	Players.PlayerRemoving:Connect(unbindObservedPlayer)
	for _, plr in Players:GetPlayers() do
		bindObservedPlayer(plr)
	end
end

return {
	init = function()
		local ok, err = pcall(init)
		if not ok then
			warn("[WorkoutController] init error:", err)
		end
	end,
}
