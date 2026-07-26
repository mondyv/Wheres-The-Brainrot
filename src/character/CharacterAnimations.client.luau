-- [ACTIVE] CharacterAnimations.client
--[[
	Replaces default Roblox character Animate locomotion with custom assets.
	Walk swaps when SlowWalkEnabled is on.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local character = script.Parent
if not character or not character:IsA("Model") then
	return
end

local ANIMS = {
	idle = 103546733090654,
	walk = 79330322261039,
	walkSlow = 119335536256791,
	jump = 133207078869082,
	fall = 73814243071114,
	land = 89197053203102,
}

local FADE = 0.15
local MOVE_EPS = 0.12
local SLOW_WALK_ATTR = "SlowWalkEnabled"

local humanoid = character:WaitForChild("Humanoid", 15)
if not humanoid or not humanoid:IsA("Humanoid") then
	return
end

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
	animator = Instance.new("Animator")
	animator.Parent = humanoid
end

-- Stop default Animate from fighting our tracks
local function disableAnimate(inst: Instance)
	if inst.Name == "Animate" and inst:IsA("LocalScript") then
		inst.Disabled = true
	end
end

local existingAnimate = character:FindFirstChild("Animate")
if existingAnimate then
	disableAnimate(existingAnimate)
end
character.ChildAdded:Connect(disableAnimate)

task.defer(function()
	for _, track in animator:GetPlayingAnimationTracks() do
		track:Stop(0)
	end
end)

local function makeTrack(assetId: number, looped: boolean, priority: Enum.AnimationPriority): AnimationTrack?
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. tostring(assetId)
	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	anim:Destroy()
	if not ok or typeof(trackOrErr) ~= "Instance" then
		warn("[CharacterAnimations] load failed", assetId, trackOrErr)
		return nil
	end
	local track = trackOrErr :: AnimationTrack
	track.Looped = looped
	track.Priority = priority
	return track
end

local idleTrack = makeTrack(ANIMS.idle, true, Enum.AnimationPriority.Idle)
local walkTrack = makeTrack(ANIMS.walk, true, Enum.AnimationPriority.Movement)
local walkSlowTrack = makeTrack(ANIMS.walkSlow, true, Enum.AnimationPriority.Movement)
local jumpTrack = makeTrack(ANIMS.jump, false, Enum.AnimationPriority.Action)
local fallTrack = makeTrack(ANIMS.fall, true, Enum.AnimationPriority.Movement)
local landTrack = makeTrack(ANIMS.land, false, Enum.AnimationPriority.Action)

type LocoMode = "idle" | "walk" | "jump" | "fall" | "land"
local mode: LocoMode = "idle"
local landing = false

local refreshGround: () -> ()

local function stopTrack(track: AnimationTrack?, fade: number?)
	if track and track.IsPlaying then
		track:Stop(fade or FADE)
	end
end

local function playTrack(track: AnimationTrack?, fade: number?)
	if not track then
		return
	end
	if not track.IsPlaying then
		track:Play(fade or FADE)
	end
end

local function activeWalkTrack(): AnimationTrack?
	if player:GetAttribute(SLOW_WALK_ATTR) == true then
		return walkSlowTrack or walkTrack
	end
	return walkTrack or walkSlowTrack
end

local function stopLocomotion(fade: number?)
	stopTrack(idleTrack, fade)
	stopTrack(walkTrack, fade)
	stopTrack(walkSlowTrack, fade)
	stopTrack(jumpTrack, fade)
	stopTrack(fallTrack, fade)
end

local function playIdle()
	if landing then
		return
	end
	mode = "idle"
	stopTrack(walkTrack, FADE)
	stopTrack(walkSlowTrack, FADE)
	stopTrack(jumpTrack, FADE)
	stopTrack(fallTrack, FADE)
	playTrack(idleTrack, FADE)
end

local function playWalk()
	if landing then
		return
	end
	mode = "walk"
	local want = activeWalkTrack()
	stopTrack(idleTrack, FADE)
	stopTrack(jumpTrack, FADE)
	stopTrack(fallTrack, FADE)
	if want == walkTrack then
		stopTrack(walkSlowTrack, FADE)
		playTrack(walkTrack, FADE)
	else
		stopTrack(walkTrack, FADE)
		playTrack(walkSlowTrack, FADE)
	end
end

local function playJump()
	landing = false
	mode = "jump"
	stopLocomotion(0.08)
	stopTrack(landTrack, 0.05)
	if jumpTrack then
		jumpTrack.TimePosition = 0
		jumpTrack:Play(0.08)
	end
end

local function playFall()
	if landing then
		return
	end
	mode = "fall"
	stopTrack(idleTrack, FADE)
	stopTrack(walkTrack, FADE)
	stopTrack(walkSlowTrack, FADE)
	stopTrack(jumpTrack, 0.1)
	playTrack(fallTrack, 0.12)
end

local function playLand()
	landing = true
	mode = "land"
	stopLocomotion(0.08)
	if not landTrack then
		landing = false
		refreshGround()
		return
	end
	landTrack.TimePosition = 0
	landTrack:Play(0.06)
	local conn: RBXScriptConnection? = nil
	conn = landTrack.Stopped:Connect(function()
		if conn then
			conn:Disconnect()
		end
		if not character.Parent then
			return
		end
		landing = false
		refreshGround()
	end)
	task.delay(math.max(0.35, landTrack.Length > 0 and landTrack.Length or 0.6), function()
		if landing and mode == "land" then
			landing = false
			stopTrack(landTrack, 0.1)
			refreshGround()
		end
	end)
end

refreshGround = function()
	if landing then
		return
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping then
		playJump()
		return
	end
	if state == Enum.HumanoidStateType.Freefall then
		playFall()
		return
	end
	local moving = humanoid.MoveDirection.Magnitude > MOVE_EPS
	if moving then
		playWalk()
	else
		playIdle()
	end
end

humanoid.StateChanged:Connect(function(_old, new)
	if new == Enum.HumanoidStateType.Jumping then
		playJump()
	elseif new == Enum.HumanoidStateType.Freefall then
		playFall()
	elseif new == Enum.HumanoidStateType.Landed then
		playLand()
	elseif
		new == Enum.HumanoidStateType.Running
		or new == Enum.HumanoidStateType.RunningNoPhysics
		or new == Enum.HumanoidStateType.GettingUp
		or new == Enum.HumanoidStateType.Swimming
	then
		if not landing then
			refreshGround()
		end
	end
end)

local moveAccum = 0.0
local _heartbeatConn = RunService.Heartbeat:Connect(function(dt)
	if not character.Parent then
		_heartbeatConn:Disconnect()
		return
	end
	moveAccum += dt
	if moveAccum < 0.08 then
		return
	end
	moveAccum = 0
	if landing then
		return
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		return
	end
	local moving = humanoid.MoveDirection.Magnitude > MOVE_EPS
	if moving and mode ~= "walk" then
		playWalk()
	elseif not moving and mode == "walk" then
		playIdle()
	elseif moving and mode == "walk" then
		local want = activeWalkTrack()
		if want == walkTrack and walkSlowTrack and walkSlowTrack.IsPlaying then
			playWalk()
		elseif want == walkSlowTrack and walkTrack and walkTrack.IsPlaying then
			playWalk()
		end
	end
end)

player:GetAttributeChangedSignal(SLOW_WALK_ATTR):Connect(function()
	if mode == "walk" and not landing then
		playWalk()
	end
end)

task.defer(function()
	refreshGround()
end)
