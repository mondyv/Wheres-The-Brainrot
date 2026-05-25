-- SwingSystem.client.luau
-- Double-jump while airborne to attach to the nearest SwingTarget vine.
-- WASD steers along the arc; vine glide pulls you toward the hook + lighter gravity (Mowgli-style).
-- Release Jump (Space / ButtonA release) to detach on PC & gamepad. Mobile: hold the touch jump button to stay attached, let go to detach (matches PC). Falls back to second-tap detach only if the JumpButton can't be located.
-- Upgrade attributes on the player: SwingRange, SwingForce, RopeLength (all numbers)

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local player = Players.LocalPlayer
local camera: Camera = workspace.CurrentCamera

-- Unique name per boot() so BindToRenderStep doesn’t collide across respawns.
local r6RenderBindSerial = 0

-- ───────────────────────────── TUNABLES ──────────────────────────────────────
local BASE_RANGE         = 56    -- grapple search radius in studs (starting reach)
local BASE_ROPE          = 56
local BASE_FORCE         = 68    -- camera-look tangent steering (starting power)
local FORCE_DECAY_TIME   = 6.0
local FORCE_MIN_MULT     = 0.75
local ANGULAR_DAMP       = 6.0
-- SpringConstraint: FreeLength=0 means force = dist * stiffness, always pulling toward vine, never pushes back
local SPRING_FREE_LENGTH = 0
local SPRING_STIFFNESS   = 100
local SPRING_DAMPING     = 20
local ZIP_TOWARD_DV          = 19    -- studs/s into the arc on attach
local LAUNCH_SPEED_RATIO     = 0.96  -- detach speed vs swing speed (always slower than dynMaxSwingSpeed cap)
local LAUNCH_CAMERA_BLEND    = 0.42  -- how much camera look steers launch vs current arc direction
-- After aim is chosen, blend toward flat camera forward and add lift so release feels like a lunge.
local LAUNCH_FORWARD_CAMERA_MIX = 0.4
local LAUNCH_UP_BLEND        = 0.34
local LAUNCH_DURATION        = 0.12  -- seconds FOV treats player as "launched" after detach
local REATTACH_ZIP_MULT      = 0.4   -- zip impulse scale when re-hooking soon after a release
local REATTACH_ZIP_GRACE      = 0.4   -- seconds after detach where zip is reduced
local MIN_SWING_HOLD_LAUNCH   = 0.1  -- shorter swings get a softer release (anti spam-fling)
-- Minimum exit speed so a detach still feels like a lunge when tangential speed reads low.
local MIN_LAUNCH_EXIT_SPEED   = 24
local LAUNCH_DEADHANG_SPEED   = 28 -- studs/s when velocity is tiny but player still releases (lunge out)
local REATTACH_AIR_GRACE     = 1.2
	local GRAPPLE_INPUT_COOLDOWN = 0.52
-- Grapple only to vines roughly in front of the camera (blocks snagging behind you).
local MIN_GRAPPLE_LOOK_DOT = 0.18
local MAX_SWING_SPEED        = 80
local FOV_MAX            = 96
local FOV_SPEED          = 5
local SHAKE_INTENSITY    = 1.2   -- max camera offset studs on hard landing
local SHAKE_DURATION     = 0.55  -- seconds the shake lasts
local SHAKE_SPEED        = 50    -- oscillation frequency
local SHAKE_VEL_MIN      = 18    -- landing speed that starts shake
local SHAKE_VEL_MAX      = 65    -- landing speed for full shake

local COLOR_NEAR     = Color3.fromRGB(90, 210, 255)
local COLOR_BEST     = Color3.fromRGB(55, 255, 105)
local COLOR_BLOCKED  = Color3.fromRGB(255, 72, 88) -- safe zone: in range but grapple disabled
local BEAM_GREEN_A   = Color3.fromRGB(30, 255, 100)
local BEAM_GREEN_B   = Color3.fromRGB(10, 200, 70)

--[[  R6 swing hang clips (camera-right vine → RightHand clip index 1; camera-left → Left clip index 2):
	HangingRight  rbxassetid://72668212449531
	HangingLeft   rbxassetid://85555597079083
]]
local ANIM_HANGING_RIGHT = "rbxassetid://72668212449531"
local ANIM_HANGING_LEFT = "rbxassetid://85555597079083"
-- ─────────────────────────────────────────────────────────────────────────────

local function isJumpReleaseKey(key: Enum.KeyCode): boolean
	return key == Enum.KeyCode.Space or key == Enum.KeyCode.ButtonA
end

local function boot(character: Model)
	local hrp      = character:WaitForChild("HumanoidRootPart", 30) :: BasePart
	local humanoid = character:WaitForChild("Humanoid",          30) :: Humanoid
	local baseWalkSpeed = humanoid.WalkSpeed
	humanoid:SetAttribute("BrainrotBaseWalkSpeed", baseWalkSpeed)
	local function applyBrainrotWalkSpeed()
		local slow = player:GetAttribute("SlowWalkEnabled") == true
		humanoid.WalkSpeed = baseWalkSpeed * (if slow then 1 else 1.75)
	end
	applyBrainrotWalkSpeed()
	local walkSpeedAttrConn = player:GetAttributeChangedSignal("SlowWalkEnabled"):Connect(applyBrainrotWalkSpeed)

	-- ── Animations / R6 Motor6D fallback ─────────────────────────────────────
	-- Load the hang clip first. If it succeeds, use Animator-only (no Motor6D wrestling).
	-- Procedural shoulders run only when the clip fails and we have classic R6 joints.
	local animateScript: Instance? = character:FindFirstChild("Animate")
	local function setDefaultAnimateEnabled(on: boolean)
		local animSc = animateScript or character:FindFirstChild("Animate")
		if animSc then
			animateScript = animSc
		end
		if animSc and animSc:IsA("LocalScript") then
			(animSc :: LocalScript).Disabled = not on
		end
	end

	local useR6Procedural = false
	local shoulderSwingAlpha = 0
	local r6Pose = {
		rs = nil :: Motor6D?,
		ls = nil :: Motor6D?,
		baseRS = nil :: CFrame?,
		baseLS = nil :: CFrame?,
		swingIdx = 1,
	}

	local animTracks: { AnimationTrack } = {}
	local activeTrack: AnimationTrack? = nil
	--- Camera-relative side index (1 right / 2 left): matches animTracks[1]/[2] and procedural pose.
	local lastSwingAnimIdx: number? = nil

	local animator = humanoid:WaitForChild("Animator") :: Animator
	for _, assetId in { ANIM_HANGING_RIGHT, ANIM_HANGING_LEFT } do
		local anim = Instance.new("Animation")
		anim.AnimationId = assetId
		local ok, trackOrErr = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and typeof(trackOrErr) == "Instance" and trackOrErr:IsA("AnimationTrack") then
			local tr = trackOrErr :: AnimationTrack
			tr.Priority = Enum.AnimationPriority.Action4
			tr.Looped = true
			table.insert(animTracks, tr)
		else
			warn(
				"[SwingSystem] Failed to load swing animation:",
				assetId,
				trackOrErr,
				"(permissions / deleted asset / wrong rig vs character)"
			)
		end
	end

	local hasR6Shoulders = false
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local torso = character:WaitForChild("Torso", 10)
		if torso then
			local rs = torso:FindFirstChild("Right Shoulder")
			local ls = torso:FindFirstChild("Left Shoulder")
			if rs and ls and rs:IsA("Motor6D") and ls:IsA("Motor6D") then
				hasR6Shoulders = true
				r6Pose.rs = rs
				r6Pose.ls = ls
				r6Pose.baseRS = rs.C0
				r6Pose.baseLS = ls.C0
			end
		end
	end

	useR6Procedural = hasR6Shoulders and (#animTracks == 0)

	if #animTracks == 0 and not useR6Procedural then
		warn("[SwingSystem] No hang animation and no R6 shoulder fallback — swinging has no arm pose.")
	end

	local function swingSideIdx(attachWorld: Vector3): number
		local idx = 1
		local flatT = Vector3.new(attachWorld.X - hrp.Position.X, 0, attachWorld.Z - hrp.Position.Z)
		local flatR = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
		if flatT.Magnitude > 0.2 and flatR.Magnitude > 0.05 then
			idx = if flatT.Unit:Dot(flatR.Unit) >= 0 then 1 else 2
		end
		return idx
	end

	local function r6HangTargets(idx: number): (CFrame, CFrame)
		local br = r6Pose.baseRS :: CFrame
		local bl = r6Pose.baseLS :: CFrame
		if idx == 1 then
			local upRR = CFrame.Angles(math.rad(-128), math.rad(-38), math.rad(12))
			local upLR = CFrame.Angles(math.rad(-108), math.rad(22), math.rad(-6))
			return br * upRR, bl * upLR
		end
		local upRL = CFrame.Angles(math.rad(-108), math.rad(-22), math.rad(6))
		local upLL = CFrame.Angles(math.rad(-128), math.rad(38), math.rad(-12))
		return br * upRL, bl * upLL
	end

	local function playSwingAnim(attachWorld: Vector3)
		local idx = swingSideIdx(attachWorld)
		if useR6Procedural then
			r6Pose.swingIdx = idx
			lastSwingAnimIdx = idx
			return
		end
		if #animTracks == 0 then
			return
		end
		idx = math.clamp(idx, 1, #animTracks)
		lastSwingAnimIdx = idx
		local track = animTracks[idx] :: AnimationTrack
		for _, t in animTracks do
			if t ~= track then
				t:Stop(0)
			end
		end
		track:Play(0.12)
		activeTrack = track
	end

	local function stopSwingAnim()
		lastSwingAnimIdx = nil
		if useR6Procedural then
			return
		end
		for _, t in animTracks do
			t:Stop(0.2)
		end
		activeTrack = nil
	end

	-- ── Landing block burst ───────────────────────────────────────────────────
	-- Grass/dirt chunk colours — top face green, body earthy brown
	local BLOCK_COLORS = {
		Color3.fromRGB(106, 127,  63),  -- dark grass green
		Color3.fromRGB( 82, 109,  39),  -- olive grass
		Color3.fromRGB(121, 152,  57),  -- medium grass
		Color3.fromRGB( 91,  65,  43),  -- dirt brown
		Color3.fromRGB(110,  82,  50),  -- light dirt
	}

	local function spawnLandingBlocks(intensity: number)
		-- Raycast straight down to find the floor
		local origin    = hrp.Position
		local rayResult = workspace:Raycast(origin, Vector3.new(0, -8, 0),
			RaycastParams.new())
		local floorY = rayResult and rayResult.Position.Y or (origin.Y - 3)
		local spawnPos = Vector3.new(origin.X, floorY, origin.Z)

		local count = math.floor(5 + intensity * 7)  -- 5–12 blocks
		for _ = 1, count do
			local size = math.random(45, 120) / 100  -- 0.45–1.2 studs — chunky blocks
			local p = Instance.new("Part")
			p.Size             = Vector3.new(size, size * math.random(60, 140) / 100, size)
			p.Color            = BLOCK_COLORS[math.random(1, #BLOCK_COLORS)]
			p.Material         = Enum.Material.Grass
			p.CastShadow       = false
			p.CanCollide       = false
			p.Anchored         = false
			p.CFrame           = CFrame.new(spawnPos + Vector3.new(
				math.random(-20, 20) / 10, 0.2, math.random(-20, 20) / 10))
				* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
			p.Parent           = workspace

			-- Outward + upward velocity with some tumble
			local angle  = math.random() * math.pi * 2
			local speed  = math.random(14, 28) * (0.7 + intensity * 0.3)
			local upward = math.random(12, 22) * (0.7 + intensity * 0.3)
			p.AssemblyLinearVelocity  = Vector3.new(math.cos(angle) * speed, upward, math.sin(angle) * speed)
			p.AssemblyAngularVelocity = Vector3.new(
				math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))

			-- Fade + shrink then auto-clean
			TweenService:Create(p, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1, Size = Vector3.one * 0.05 }):Play()
			Debris:AddItem(p, 0.75)
		end
	end

	-- ── Shake state ───────────────────────────────────────────────────────────
	local shakeTimer      = 0
	local landingSpeed    = 0
	local landedFromSwing = false  -- only shake when landing after a swing release

	-- ── Upgrade stats ────────────────────────────────────────────────────────
	-- Per-point gains halved vs earlier tuning (reach + rope felt too strong).
	local REACH_PER_POINT = 7 -- SwingRange → studs (search + rope)
	local ROPE_PER_ATTR_PT = 2 -- RopeLength attribute bonus per point

	local swingRange = BASE_RANGE
	local swingForce = BASE_FORCE
	local ropeLength = BASE_ROPE

	-- SwingForce: steering + attach zip + swing speed cap scale with attribute.
	local dynMaxSwingSpeed = MAX_SWING_SPEED
	local dynZipToward = ZIP_TOWARD_DV
	local dynLaunchSpeedRatio = LAUNCH_SPEED_RATIO

	local function refreshStats()
		local r = player:GetAttribute("SwingRange")
		local f = player:GetAttribute("SwingForce")
		local l = player:GetAttribute("RopeLength")
		local reachPts = if typeof(r) == "number" then r else 0
		local ropePts = if typeof(l) == "number" then l else 0
		local powerPts = if typeof(f) == "number" then f else 1

		swingRange = BASE_RANGE + reachPts * REACH_PER_POINT
		-- Rope must track reach or attachRadius=min(range,rope) stays ~BASE_ROPE forever
		ropeLength = BASE_ROPE + reachPts * REACH_PER_POINT + ropePts * ROPE_PER_ATTR_PT
		ropeLength = math.max(ropeLength, 8)

		swingForce = BASE_FORCE + powerPts * 17

		-- Swing speed keeps climbing at high power; detach launch stays a fixed ratio below cap.
		local spdBonus = math.min(powerPts * 3.5, 150)
		dynMaxSwingSpeed = 68 + spdBonus
		dynZipToward = ZIP_TOWARD_DV + powerPts * 1.4
		dynLaunchSpeedRatio = LAUNCH_SPEED_RATIO
	end
	refreshStats()

	-- Grapple only works to targets within rope reach (swingRange can be larger from upgrades)
	local function attachRadius(): number
		return math.min(swingRange, ropeLength)
	end

	local statConns = {
		player:GetAttributeChangedSignal("SwingRange"):Connect(refreshStats),
		player:GetAttributeChangedSignal("SwingForce"):Connect(refreshStats),
		player:GetAttributeChangedSignal("RopeLength"):Connect(refreshStats),
	}

	-- ── State ─────────────────────────────────────────────────────────────────
	local isSwinging  = false
	local isLaunched  = false
	local isAirborne  = false
	local swingTimer  = 0

	-- Swing constraints / force
	local ropeInst:      SpringConstraint? = nil
	local ropeBodyAtt:   Attachment?       = nil
	local ropeAnchorAtt: Attachment?       = nil
	local forceInst:     VectorForce?      = nil
	local forceAtt:      Attachment?       = nil

	local swingTargetPart: BasePart? = nil
	local beamInst: Beam?       = nil
	local beamA0:   Attachment? = nil
	local beamA1:   Attachment? = nil
	local lastSwingEndClock = -1e9
	local lastGrappleInputClock = -1e9
	local lastSwingAttachClock = -1e9
	local SWING_ATTACH_JUMP_DEBOUNCE = 0.14 -- ignore duplicate JumpRequest right after hooking (same tap)
	-- Touch jump button does not set IsKeyDown(Space); Heartbeat uses this for swing-charge ring fill.
	local mobileJumpHeld = false

	-- R6: Animator applies Motor6D.Transform after Heartbeat — must override last frame via RenderStep + clear Transform.
	local r6RenderBindName: string? = nil
	if useR6Procedural then
		r6RenderBindSerial += 1
		r6RenderBindName = "SwingSystem_R6Hang_" .. tostring(r6RenderBindSerial)
		RunService:BindToRenderStep(
			r6RenderBindName,
			Enum.RenderPriority.Last.Value + 10,
			function(dt: number)
				if not r6Pose.rs or not r6Pose.ls or not r6Pose.baseRS or not r6Pose.baseLS then
					return
				end
				local targetAlpha = if isSwinging then 1 else 0
				shoulderSwingAlpha += (targetAlpha - shoulderSwingAlpha) * math.min(1, dt * 14)
				if shoulderSwingAlpha < 0.001 then
					return
				end
				local trs, tls = r6HangTargets(r6Pose.swingIdx)
				r6Pose.rs.Transform = CFrame.new()
				r6Pose.ls.Transform = CFrame.new()
				r6Pose.rs.C0 = r6Pose.baseRS:Lerp(trs, shoulderSwingAlpha)
				r6Pose.ls.C0 = r6Pose.baseLS:Lerp(tls, shoulderSwingAlpha)
			end
		)
	end

	-- Closest point on SwingTarget surface to HRP — rope attaches there (not part center).
	local function closestAttachWorldOnPart(p: BasePart): Vector3
		local ok, pt = pcall(function()
			return p:GetClosestPointOnSurface(hrp.Position)
		end)
		if ok and typeof(pt) == "Vector3" then
			return pt :: Vector3
		end
		return p.Position
	end
	type VisEntry = { bb: BillboardGui, ring: Frame, dot: Frame, lbl: TextLabel }
	local visMap: { [BasePart]: VisEntry } = {}

	-- During swing: Space hold fills inner dot toward outer ring (visual only)
	type SwingChargeHud = { bb: BillboardGui, ring: Frame, dot: Frame }
	local swingChargeHud: SwingChargeHud? = nil
	local swingChargeFill = 0
	local SWING_CHARGE_HOLD_SEC = 1.15
	local CHARGE_DOT_MIN = 8
	-- Ring outer ~56px; stroke eats ~5px — fill nearly flush with inner edge
	local CHARGE_DOT_MAX = 52

	local function makeVisual(part: BasePart, color: Color3): VisEntry
		-- BillboardGui tall enough to hold ring (56px) + gap + label (20px)
		local bb = Instance.new("BillboardGui")
		bb.Adornee         = part
		bb.Size            = UDim2.fromOffset(110, 88)
		bb.StudsOffset     = Vector3.new(0, part.Size.Y * 0.5 + 0.5, 0)
		bb.AlwaysOnTop     = true
		bb.LightInfluence  = 0
		bb.Parent          = workspace

		-- Ring (top 56×56, horizontally centered)
		local ring = Instance.new("Frame")
		ring.Size                   = UDim2.fromOffset(56, 56)
		ring.Position               = UDim2.new(0.5, -28, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel        = 0
		ring.Parent                 = bb

		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(1, 0)
		ringCorner.Parent       = ring

		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color        = color
		ringStroke.Thickness    = 2.5
		ringStroke.Transparency = 0.08
		ringStroke.Parent       = ring

		-- Center dot
		local dot = Instance.new("Frame")
		dot.Size                   = UDim2.fromOffset(8, 8)
		dot.Position               = UDim2.new(0.5, -4, 0.5, -4)
		dot.BackgroundColor3       = color
		dot.BackgroundTransparency = 0
		dot.BorderSizePixel        = 0
		dot.Parent                 = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent       = dot

		-- Label below ring (fits inside billboard)
		local lbl = Instance.new("TextLabel")
		lbl.Size                = UDim2.new(1, 0, 0, 22)
		lbl.Position            = UDim2.new(0, 0, 0, 62)
		lbl.BackgroundTransparency = 1
		lbl.Text                = "JUMP  ·  swing"
		lbl.TextColor3          = color
		lbl.TextTransparency    = 0.08
		lbl.TextSize            = 12
		lbl.Font                = Enum.Font.GothamBold
		lbl.TextXAlignment      = Enum.TextXAlignment.Center
		lbl.Parent              = bb

		return { bb = bb, ring = ring, dot = dot, lbl = lbl }
	end

	local function setVisualColor(v: VisEntry, color: Color3)
		local stroke = v.ring:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Color = color end
		v.dot.BackgroundColor3 = color
		v.lbl.TextColor3       = color
	end

	local function addVisual(part: BasePart)
		if visMap[part] then return end
		visMap[part] = makeVisual(part, COLOR_NEAR)
	end

	local function removeVisual(part: BasePart)
		local v = visMap[part]
		if not v then return end
		v.bb:Destroy()
		visMap[part] = nil
	end

	local function clearVisuals()
		for part in visMap do
			removeVisual(part)
		end
	end

	local function destroySwingChargeHud()
		if swingChargeHud then
			swingChargeHud.bb:Destroy()
			swingChargeHud = nil
		end
		swingChargeFill = 0
	end

	local function layoutSwingChargeDot()
		if not swingChargeHud then
			return
		end
		local t = swingChargeFill
		local px = CHARGE_DOT_MIN + (CHARGE_DOT_MAX - CHARGE_DOT_MIN) * t
		px = math.floor(px + 0.5)
		local dot = swingChargeHud.dot
		dot.Size = UDim2.fromOffset(px, px)
		dot.Position = UDim2.new(0.5, -px * 0.5, 0.5, -px * 0.5)
	end

	local function ensureSwingChargeHud(vinePart: BasePart)
		if swingChargeHud then
			return
		end
		local bb = Instance.new("BillboardGui")
		bb.Name = "SwingChargeHud"
		bb.Adornee = vinePart
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.Size = UDim2.fromOffset(110, 88)
		bb.StudsOffset = Vector3.new(0, vinePart.Size.Y * 0.5 + 0.5, 0)
		bb.Parent = workspace

		local ring = Instance.new("Frame")
		ring.Size = UDim2.fromOffset(56, 56)
		ring.Position = UDim2.new(0.5, -28, 0, 0)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.Parent = bb

		local ringCorner = Instance.new("UICorner")
		ringCorner.CornerRadius = UDim.new(1, 0)
		ringCorner.Parent = ring

		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color = BEAM_GREEN_A
		ringStroke.Thickness = 2.5
		ringStroke.Transparency = 0.06
		ringStroke.Parent = ring

		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(CHARGE_DOT_MIN, CHARGE_DOT_MIN)
		dot.Position = UDim2.new(0.5, -4, 0.5, -4)
		dot.BackgroundColor3 = BEAM_GREEN_A
		dot.BorderSizePixel = 0
		dot.Parent = ring

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, 0, 0, 22)
		lbl.Position = UDim2.new(0, 0, 0, 62)
		lbl.BackgroundTransparency = 1
		lbl.Text = "JUMP  ·  swing"
		lbl.TextColor3 = BEAM_GREEN_A
		lbl.TextTransparency = 0.08
		lbl.TextSize = 12
		lbl.Font = Enum.Font.GothamBold
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.Parent = bb

		swingChargeHud = { bb = bb, ring = ring, dot = dot }
		layoutSwingChargeDot()
	end

	-- ── Rope beam (visual: wire from R6 hand to vine; physics stay on HRP) ─────
	local BEAM_GRIP_R6 = Vector3.new(0, -1.15, 0)

	local function handPartForSwingSide(sideIdx: number): BasePart?
		local n = if sideIdx == 1 then "Right Arm" else "Left Arm"
		local p = character:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			return p
		end
		return nil
	end

	local function placeBeamGripAttachment(att: Attachment, sideIdx: number)
		local hand = handPartForSwingSide(sideIdx)
		if hand then
			att.Parent = hand
			att.Position = BEAM_GRIP_R6
		else
			att.Parent = hrp
			att.Position = Vector3.new(0, 1.25, 0)
		end
	end

	local function spawnBeam(attachWorld: Vector3)
		local a0 = Instance.new("Attachment")
		placeBeamGripAttachment(a0, swingSideIdx(attachWorld))
		beamA0 = a0

		beamA1 = nil -- vine end uses rope anchor attachment (same point as rope)

		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = ropeAnchorAtt
		b.Width0        = 0.14
		b.Width1        = 0.1
		b.Color         = ColorSequence.new(BEAM_GREEN_A, BEAM_GREEN_B)
		b.Transparency  = NumberSequence.new(0.08)
		b.LightEmission = 0.55
		b.FaceCamera    = true
		b.Segments      = 16
		b.CurveSize0    = 0
		b.CurveSize1    = 0
		b.Parent        = character
		beamInst        = b
	end

	local function destroyBeam()
		if beamA0 then beamA0:Destroy(); beamA0 = nil end
		if beamInst then beamInst:Destroy(); beamInst = nil end
	end

	-- Preview tracer: transparent line to the grapple point whenever the swing UI shows (hidden while swinging).
	local previewBeam: Beam? = nil
	local previewAttFrom: Attachment? = nil
	local previewAttTo: Attachment? = nil
	local previewTarget: BasePart? = nil

	local PREVIEW_WHITE = Color3.new(1, 1, 1)
	local PREVIEW_TRANSPARENCY_OK = 0.12
	local PREVIEW_TRANSPARENCY_BLOCKED = 0.4
	local PREVIEW_WIDTH = 0.1
	local PREVIEW_DASH_COUNT = 18

	local function previewDashedTransparency(alpha: number): NumberSequence
		local keypoints: { NumberSequenceKeypoint } = {}
		for i = 0, PREVIEW_DASH_COUNT do
			local t = i / PREVIEW_DASH_COUNT
			local solid = i % 2 == 0
			table.insert(keypoints, NumberSequenceKeypoint.new(t, if solid then alpha else 1))
		end
		return NumberSequence.new(keypoints)
	end

	local function destroyPreviewTracer()
		if previewAttFrom then
			previewAttFrom:Destroy()
			previewAttFrom = nil
		end
		if previewAttTo then
			previewAttTo:Destroy()
			previewAttTo = nil
		end
		if previewBeam then
			previewBeam:Destroy()
			previewBeam = nil
		end
		previewTarget = nil
	end

	local function updatePreviewTracer(target: BasePart?, grappleOk: boolean)
		if isSwinging or not target or not target.Parent then
			destroyPreviewTracer()
			return
		end

		local attachWorld = closestAttachWorldOnPart(target)

		if previewTarget ~= target or not previewBeam or not previewAttFrom or not previewAttTo then
			destroyPreviewTracer()
			previewTarget = target

			previewAttFrom = Instance.new("Attachment")
			previewAttFrom.Name = "SwingPreviewFrom"
			previewAttFrom.Parent = hrp
			previewAttFrom.Position = Vector3.new(0, 0.6, 0)

			previewAttTo = Instance.new("Attachment")
			previewAttTo.Name = "SwingPreviewTo"
			previewAttTo.Parent = target

			previewBeam = Instance.new("Beam")
			previewBeam.Name = "SwingPreviewTracer"
			previewBeam.Attachment0 = previewAttFrom
			previewBeam.Attachment1 = previewAttTo
			previewBeam.Width0 = PREVIEW_WIDTH
			previewBeam.Width1 = PREVIEW_WIDTH * 0.75
			previewBeam.Color = ColorSequence.new(PREVIEW_WHITE)
			previewBeam.Texture = ""
			previewBeam.LightEmission = 0.12
			previewBeam.FaceCamera = true
			previewBeam.Segments = 1
			previewBeam.CurveSize0 = 0
			previewBeam.CurveSize1 = 0
			previewBeam.Parent = character
		end

		previewAttTo.Position = target.CFrame:PointToObjectSpace(attachWorld)
		local lineAlpha = if grappleOk then PREVIEW_TRANSPARENCY_OK else PREVIEW_TRANSPARENCY_BLOCKED
		previewBeam.Transparency = previewDashedTransparency(lineAlpha)
		previewBeam.Color = ColorSequence.new(PREVIEW_WHITE)
	end

	-- ── Target scan ───────────────────────────────────────────────────────────
	local partCache:  { BasePart } = {}
	local cacheStamp = 0
	local CACHE_TTL  = 1.0

	local function rebuildCache()
		table.clear(partCache)
		local seen: { [BasePart]: boolean } = {}

		for _, obj in CollectionService:GetTagged("SwingTarget") do
			if obj:IsA("BasePart") and obj.Parent then
				seen[obj]             = true
				table.insert(partCache, obj)
			end
		end

		local map  = workspace:FindFirstChild("Map")
		local vine = map and map:FindFirstChild("Vine")
		if vine then
			for _, d in vine:GetDescendants() do
				if d:IsA("BasePart") and d.Name == "SwingTarget" and not seen[d] then
					table.insert(partCache, d)
				end
			end
		end
		cacheStamp = os.clock()
	end

	local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart): boolean
		local localPt = part.CFrame:PointToObjectSpace(worldPoint)
		local half = part.Size * 0.5
		return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
	end

	-- workspace.Map["Spawn And Bases"].SafezoneHitbox — cached; OBB point test only (no touch queries).
	local safezoneHitbox: BasePart? = nil
	local function refreshSafezoneHitbox()
		if safezoneHitbox and safezoneHitbox.Parent then
			return
		end
		safezoneHitbox = nil
		local map = workspace:FindFirstChild("Map")
		if not map then
			return
		end
		local spawnBases = map:FindFirstChild("Spawn And Bases")
		if not spawnBases then
			return
		end
		local h = spawnBases:FindFirstChild("SafezoneHitbox")
		if h and h:IsA("BasePart") then
			safezoneHitbox = h
		end
	end

	local function isHrpInSafezone(): boolean
		refreshSafezoneHitbox()
		if not safezoneHitbox then
			return false
		end
		return isPointInsidePartOBB(hrp.Position, safezoneHitbox)
	end

	-- One SwingTarget in range: chosen by where the camera looks (not pure distance — avoids snapping back to the vine you just left).
	-- respectSafezone: when true, returns nil while HRP is inside SafezoneHitbox (grapple disabled there).
	local function cameraPickSwingTarget(respectSafezone: boolean?): BasePart?
		local respectSafe = if respectSafezone == nil then true else respectSafezone :: boolean
		if respectSafe and isHrpInSafezone() then
			return nil
		end
		if os.clock() - cacheStamp > CACHE_TTL then
			rebuildCache()
		end
		local look = camera.CFrame.LookVector
		local maxReach = attachRadius()
		local ropeLim = ropeLength + 0.35
		local limit = math.min(maxReach, ropeLim)
		local best: BasePart? = nil
		local bestScore = -math.huge
		for _, p in partCache do
			if not p.Parent then
				continue
			end
			local attachWorld = closestAttachWorldOnPart(p)
			local dir = attachWorld - hrp.Position
			local dist = dir.Magnitude
			if dist < 0.08 or dist > limit then
				continue
			end
			local flatDir = Vector3.new(dir.X, 0, dir.Z)
			local flatLook = Vector3.new(look.X, 0, look.Z)
			local align: number
			if flatDir.Magnitude > 0.05 and flatLook.Magnitude > 0.05 then
				align = flatDir.Unit:Dot(flatLook.Unit)
			else
				align = look:Dot(dir.Unit)
			end
			if align < MIN_GRAPPLE_LOOK_DOT then
				continue
			end
			local score = align * 1.15
				+ (if attachWorld.Y > hrp.Position.Y + 2 then 0.08 else 0)
				- (dist / math.max(limit, 1)) * 0.06
			if score > bestScore then
				bestScore = score
				best = p
			end
		end
		return best
	end

	local function canGrappleFromAir(): boolean
		if isAirborne then
			return true
		end
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
			return true
		end
		if os.clock() - lastSwingEndClock < REATTACH_AIR_GRACE then
			return true
		end
		return false
	end

	local function applyGrappleMomentumBoost(attachWorld: Vector3)
		hrp.AssemblyAngularVelocity = Vector3.zero

		local v = hrp.AssemblyLinearVelocity
		local fromAnchor = hrp.Position - attachWorld
		local radial = if fromAnchor.Magnitude > 0.25 then fromAnchor.Unit else Vector3.yAxis

		-- Camera look on the tangent plane, tilted slightly down into the arc.
		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local fwdTang = flatLook - radial * flatLook:Dot(radial)
		local swingDir: Vector3
		if fwdTang.Magnitude > 0.1 then
			local down = Vector3.new(fwdTang.X, fwdTang.Y - 0.55, fwdTang.Z)
			swingDir = down.Unit
		else
			swingDir = Vector3.new(0, -1, 0)
		end

		-- Only inherit prior tangential motion when not re-hooking right after a release (avoids compounding flings).
		local recentDetach = os.clock() - lastSwingEndClock < REATTACH_ZIP_GRACE
		local existingTang = v - radial * v:Dot(radial)
		if not recentDetach and existingTang.Magnitude > 4 then
			swingDir = existingTang.Unit
		end

		local zip = dynZipToward
		if recentDetach then
			zip *= REATTACH_ZIP_MULT
		end

		hrp:ApplyImpulse(swingDir * zip * hrp.AssemblyMass)

		local post = hrp.AssemblyLinearVelocity
		if post.Magnitude > dynMaxSwingSpeed then
			hrp.AssemblyLinearVelocity = post.Unit * dynMaxSwingSpeed
		end
	end

	local function startSwing(target: BasePart)
		local attachWorld = closestAttachWorldOnPart(target)
		local dist = (hrp.Position - attachWorld).Magnitude
		if dist > ropeLength + 0.5 or dist < 0.08 then
			return
		end
		if isHrpInSafezone() then
			return
		end

		isSwinging = true
		lastSwingAttachClock = os.clock()
		isLaunched = false
		swingTimer = 0

		local anchorAtt = Instance.new("Attachment")
		anchorAtt.Parent = target
		anchorAtt.Position = target.CFrame:PointToObjectSpace(attachWorld)
		ropeAnchorAtt = anchorAtt

		local bodyAtt = Instance.new("Attachment")
		bodyAtt.Position = Vector3.zero
		bodyAtt.Parent = hrp
		ropeBodyAtt = bodyAtt

		-- SpringConstraint: always active tension means no gravity cancel needed.
		-- LimitsEnabled = false so it pulls when far AND pushes when close, giving
		-- a natural pendulum feel without any artificial upward force hacks.
		local spring = Instance.new("SpringConstraint")
		spring.Attachment0 = anchorAtt
		spring.Attachment1 = bodyAtt
		spring.FreeLength   = SPRING_FREE_LENGTH
		spring.Stiffness    = SPRING_STIFFNESS
		spring.Damping      = SPRING_DAMPING
		spring.MaxForce     = math.huge
		spring.LimitsEnabled = false
		spring.Parent = hrp
		ropeInst = spring

		swingTargetPart = target

		humanoid.PlatformStand = true

		humanoid.AutoRotate = false

		local fa = Instance.new("Attachment")
		fa.Parent = hrp
		forceAtt = fa

		local vf = Instance.new("VectorForce")
		vf.Attachment0 = fa
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.Force = Vector3.zero
		vf.Parent = hrp
		forceInst = vf

		hrp.AssemblyAngularVelocity = Vector3.zero
		applyGrappleMomentumBoost(anchorAtt.WorldPosition)
		setDefaultAnimateEnabled(false)
		playSwingAnim(attachWorld)

		spawnBeam(attachWorld)
		destroyPreviewTracer()
		clearVisuals()
		swingChargeFill = 0
		ensureSwingChargeHud(target)
	end

	local function stopSwing(doLaunch: boolean)
		if not isSwinging then return end

		local heldTime = swingTimer
		local detachAnchorWorld: Vector3? = nil
		if ropeAnchorAtt and ropeAnchorAtt.Parent then
			detachAnchorWorld = ropeAnchorAtt.WorldPosition
		end

		destroySwingChargeHud()
		isSwinging = false

		if forceInst     then forceInst:Destroy();     forceInst     = nil end
		if forceAtt      then forceAtt:Destroy();      forceAtt      = nil end
		if ropeAnchorAtt then ropeAnchorAtt:Destroy(); ropeAnchorAtt = nil end
		if ropeBodyAtt   then ropeBodyAtt:Destroy();   ropeBodyAtt   = nil end
		if ropeInst      then ropeInst:Destroy();      ropeInst      = nil end
		destroyBeam()
		stopSwingAnim()
		setDefaultAnimateEnabled(true)

		swingTargetPart = nil

		lastSwingEndClock = os.clock()
		if doLaunch then landedFromSwing = true end

		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		hrp.AssemblyAngularVelocity = Vector3.zero

		-- Exit velocity: forward (camera-led) + slight lift. Apply on the next task step so the
		-- Humanoid doesn't zero AssemblyLinearVelocity the same frame PlatformStand turns off.
		if doLaunch then
			local snapVel = hrp.AssemblyLinearVelocity
			local snapPos = hrp.Position
			local snapHeld = heldTime
			local snapAnchor = detachAnchorWorld
			local camLook0 = camera.CFrame.LookVector

			task.defer(function()
				if not hrp.Parent then
					return
				end
				local vel = snapVel
				local speed = vel.Magnitude
				local camLook = camLook0
				local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
				local camFlatUnit = if camFlat.Magnitude > 0.08 then camFlat.Unit else Vector3.new(0, 0, -1)

				local function applyLaunch(launchDir: Vector3, targetSpeed: number)
					local d = launchDir
					if camFlat.Magnitude > 0.08 then
						local flat = camFlat.Unit
						d = (d * (1 - LAUNCH_FORWARD_CAMERA_MIX) + flat * LAUNCH_FORWARD_CAMERA_MIX)
					end
					d = d + Vector3.new(0, LAUNCH_UP_BLEND, 0)
					if d.Magnitude > 1e-4 then
						d = d.Unit
					end
					humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					hrp.AssemblyLinearVelocity = d * targetSpeed
					hrp.AssemblyAngularVelocity = Vector3.zero
					isLaunched = true
					task.delay(LAUNCH_DURATION, function()
						isLaunched = false
					end)
				end

				if speed <= 1 then
					local hangDir = (camFlatUnit + Vector3.new(0, LAUNCH_UP_BLEND + 0.12, 0))
					if hangDir.Magnitude > 1e-4 then
						applyLaunch(hangDir.Unit, math.max(LAUNCH_DEADHANG_SPEED, MIN_LAUNCH_EXIT_SPEED * 0.85))
					end
				else
					local radial = Vector3.yAxis
					if snapAnchor then
						local fromAnchor = snapPos - snapAnchor
						if fromAnchor.Magnitude > 0.2 then
							radial = fromAnchor.Unit
						end
					end

					local tangVel = vel - radial * vel:Dot(radial)
					local tangSpeed = tangVel.Magnitude

					local camTang = camFlat - radial * camFlat:Dot(radial)

					local launchDir: Vector3
					if tangSpeed > 2 then
						local tDir = tangVel.Unit
						if camTang.Magnitude > 0.05 then
							launchDir = (tDir * (1 - LAUNCH_CAMERA_BLEND) + camTang.Unit * LAUNCH_CAMERA_BLEND).Unit
						else
							launchDir = tDir
						end
					elseif camTang.Magnitude > 0.05 then
						launchDir = camTang.Unit
					else
						launchDir = if speed > 0.1 then vel.Unit else camFlatUnit
					end

					local speedRef = if tangSpeed > 3
						then tangSpeed
						else math.min(tangSpeed + speed * 0.35, speed * 0.55, 28)
					local holdT = math.clamp(snapHeld / MIN_SWING_HOLD_LAUNCH, 0.72, 1)
					local targetSpeed = math.min(speedRef, dynMaxSwingSpeed) * dynLaunchSpeedRatio * holdT
					targetSpeed = math.max(targetSpeed, MIN_LAUNCH_EXIT_SPEED * holdT)

					applyLaunch(launchDir, targetSpeed)
				end
			end)
		end
	end

	-- ── Input ─────────────────────────────────────────────────────────────────
	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Freefall
		or new == Enum.HumanoidStateType.Jumping then
			isAirborne = true
		elseif new == Enum.HumanoidStateType.Landed then
			isAirborne = false
			-- Only shake + burst blocks when landing after a swing release, not on normal jumps
			if landedFromSwing then
				landedFromSwing = false
				local alpha = math.clamp(
					(landingSpeed - SHAKE_VEL_MIN) / (SHAKE_VEL_MAX - SHAKE_VEL_MIN), 0, 1)
				if alpha > 0 then
					shakeTimer = SHAKE_DURATION * alpha
					spawnLandingBlocks(alpha)
				end
			end
			isLaunched = false
		elseif new == Enum.HumanoidStateType.Running
		or new == Enum.HumanoidStateType.RunningNoPhysics then
			isAirborne = false
		end
	end)

	-- Try to hook onto the best visible target. No air-state gating here — if the
	-- green UI is showing there is a valid target and the player intentionally pressed
	-- jump; just attach. Cooldown prevents double-fire only after a successful hook.
	local function tryGrappleAttach()
		if isSwinging then
			return
		end
		if isHrpInSafezone() then
			return
		end
		local now = os.clock()
		if now - lastGrappleInputClock < GRAPPLE_INPUT_COOLDOWN then return end

		local best = cameraPickSwingTarget(true)
		if not best then
			return
		end

		startSwing(best)
		if isSwinging then
			lastGrappleInputClock = now
		end
	end

	-- Mobile: bind the Roblox touch JumpButton so press = attach, release = detach (same feel as PC Space).
	-- Tap-detach via JumpRequest is kept as a fallback only when the button can't be located.
	local mobileJumpBound = false
	local mobileBoundConns: { RBXScriptConnection } = {}

	local function disconnectMobileBound()
		for _, c in mobileBoundConns do c:Disconnect() end
		table.clear(mobileBoundConns)
		mobileJumpBound = false
		mobileJumpHeld = false
	end

	local function tryBindMobileJumpButton(): boolean
		if mobileJumpBound then return true end
		if not UserInputService.TouchEnabled then return false end
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if not pg then return false end
		local touchGui = pg:FindFirstChild("TouchGui")
		if not touchGui then return false end
		local frame = touchGui:FindFirstChild("TouchControlFrame")
		if not frame then return false end
		local btn = frame:FindFirstChild("JumpButton")
		if not (btn and btn:IsA("GuiButton")) then return false end

		mobileJumpBound = true
		local pressDown = false

		table.insert(mobileBoundConns, btn.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then return end
			if pressDown then return end
			pressDown = true
			mobileJumpHeld = true
			if not isSwinging then
				tryGrappleAttach()
			end
		end))

		table.insert(mobileBoundConns, btn.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then return end
			if not pressDown then return end
			pressDown = false
			mobileJumpHeld = false
			if isSwinging then
				stopSwing(true)
			end
		end))

		table.insert(mobileBoundConns, btn.AncestryChanged:Connect(function(_, parent)
			if not parent then
				disconnectMobileBound()
				task.defer(function()
					-- Roblox rebuilds TouchGui on respawn / device changes; reattach to the new button.
					tryBindMobileJumpButton()
				end)
			end
		end))

		return true
	end

	local pgWatchConns: { RBXScriptConnection } = {}
	if UserInputService.TouchEnabled then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if pg and not tryBindMobileJumpButton() then
			table.insert(pgWatchConns, pg.DescendantAdded:Connect(function(d)
				if d.Name == "JumpButton" and d:IsA("GuiButton") then
					task.defer(tryBindMobileJumpButton)
				end
			end))
		end
	end

	local function onJumpRequest()
		if isSwinging then
			-- Fallback only: pure-touch device where we couldn't bind to the JumpButton.
			-- Without this, the player would be stuck swinging since they have no key to release.
			if not mobileJumpBound
				and UserInputService.TouchEnabled
				and not UserInputService.KeyboardEnabled
				and os.clock() - lastSwingAttachClock >= SWING_ATTACH_JUMP_DEBOUNCE
			then
				stopSwing(true)
			end
			return
		end
		tryGrappleAttach()
	end

	local jumpConn = UserInputService.JumpRequest:Connect(onJumpRequest)

	local beginConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or isSwinging then return end
		if input.UserInputType == Enum.UserInputType.Gamepad1 and isJumpReleaseKey(input.KeyCode) then
			tryGrappleAttach()
		end
	end)

	local releaseConn = UserInputService.InputEnded:Connect(function(input: InputObject, processed: boolean)
		if processed or not isSwinging then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and isJumpReleaseKey(input.KeyCode) then
			stopSwing(true)
			return
		end
		if input.UserInputType == Enum.UserInputType.Gamepad1 and isJumpReleaseKey(input.KeyCode) then
			stopSwing(true)
		end
	end)

	local diedConn = humanoid.Died:Connect(function()
		if isSwinging then
			stopSwing(false)
		end
	end)

	-- ── Heartbeat (physics + visuals) ─────────────────────────────────────────
	local fovBase   = camera.FieldOfView
	local prevInRng: { [BasePart]: boolean } = {}

	local heartbeat = RunService.Heartbeat:Connect(function(dt)
		local vel = hrp.AssemblyLinearVelocity

		-- FOV effect
		if isSwinging or isLaunched then
			local t = math.clamp(vel.Magnitude / math.max(dynMaxSwingSpeed, 1), 0, 1)
			local target = fovBase + (FOV_MAX - fovBase) * t
			camera.FieldOfView += (target - camera.FieldOfView) * math.min(dt * FOV_SPEED, 1)
		else
			camera.FieldOfView += (fovBase - camera.FieldOfView) * math.min(dt * FOV_SPEED, 1)
		end

		-- Swing physics: camera-steered pendulum on a SpringConstraint.
		if isSwinging and forceInst and swingTargetPart and swingTargetPart.Parent and ropeAnchorAtt and ropeAnchorAtt.Parent then
			swingTimer += dt
			humanoid.PlatformStand = true
			humanoid.Jump = false

			local decay = math.clamp(swingTimer / FORCE_DECAY_TIME, 0, 1)
			local mult = 1 - decay * (1 - FORCE_MIN_MULT)

			local fromAnchor = hrp.Position - ropeAnchorAtt.WorldPosition
			local radial = if fromAnchor.Magnitude > 0.2 then fromAnchor.Unit else Vector3.yAxis

			-- Camera-relative steering: where you look is where you swing.
			local camLook = camera.CFrame.LookVector
			local camRight = camera.CFrame.RightVector
			local md = humanoid.MoveDirection

			local inputBias = Vector3.zero
			if md.Magnitude > 0.05 then
				local mdFlat = Vector3.new(md.X, 0, md.Z)
				inputBias = camRight * camRight:Dot(mdFlat) * 0.6
			end
			local steerDir = Vector3.new(camLook.X, 0, camLook.Z) + inputBias

			local tang = steerDir - radial * steerDir:Dot(radial)
			if tang.Magnitude > 0.05 then
				forceInst.Force = tang.Unit * swingForce * mult * hrp.AssemblyMass
			else
				forceInst.Force = Vector3.zero
			end

			-- Steering uses VectorForce only. Avoid aiming HRP at the camera here — that rotation
			-- fights the hang animation and twists arms into the torso.

			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity * math.exp(-ANGULAR_DAMP * dt)

			if vel.Magnitude > dynMaxSwingSpeed then
				hrp.AssemblyLinearVelocity = vel.Unit * dynMaxSwingSpeed
			end

			local spaceHeld = UserInputService:IsKeyDown(Enum.KeyCode.Space)
				or UserInputService:IsKeyDown(Enum.KeyCode.ButtonA)
				or mobileJumpHeld
			swingChargeFill = if spaceHeld
				then math.min(1, swingChargeFill + dt / SWING_CHARGE_HOLD_SEC)
				else math.max(0, swingChargeFill - dt * 3.5)
			layoutSwingChargeDot()

			return
		end

		-- Track speed in air so we know how hard the landing will be
		if isAirborne then
			landingSpeed = vel.Magnitude
		end

		-- Camera shake on landing
		if shakeTimer > 0 then
			shakeTimer = math.max(0, shakeTimer - dt)
			local progress  = shakeTimer / SHAKE_DURATION
			local intensity = SHAKE_INTENSITY * progress
			humanoid.CameraOffset = Vector3.new(
				math.sin(tick() * SHAKE_SPEED)       * intensity,
				math.cos(tick() * SHAKE_SPEED * 1.3) * intensity,
				0
			)
		else
			-- Smoothly reset camera offset when shake ends
			humanoid.CameraOffset = humanoid.CameraOffset:Lerp(Vector3.zero, math.min(dt * 12, 1))
		end

		-- Single target indicator: best vine in range (camera aim). Safe zone = red, no grapple.
		local inSafe = isHrpInSafezone()
		local aimVisual = cameraPickSwingTarget(false)
		local grappleOk = not inSafe and aimVisual ~= nil

		local inRngNow: { BasePart } = {}
		if aimVisual then
			table.insert(inRngNow, aimVisual)
		end
		local inRngSet: { [BasePart]: boolean } = {}
		for _, p in ipairs(inRngNow) do
			inRngSet[p] = true
		end

		for _, p in inRngNow do
			if not prevInRng[p] then
				addVisual(p)
			end
		end
		for p in prevInRng do
			if not inRngSet[p] then
				removeVisual(p)
			end
		end
		prevInRng = inRngSet

		if aimVisual then
			local v = visMap[aimVisual]
			if v then
				local aimColor = if grappleOk then COLOR_BEST else COLOR_BLOCKED
				setVisualColor(v, aimColor)
				v.lbl.Text = if grappleOk then "JUMP  ·  swing" else "SAFE ZONE"
				if grappleOk and not isSwinging then
					local w = math.sin(os.clock() * 3.4) * 0.5 + 0.5
					v.dot.BackgroundTransparency = 0.06 + 0.38 * w
				else
					v.dot.BackgroundTransparency = 0
				end
			end
		end

		if isSwinging then
			destroyPreviewTracer()
		elseif aimVisual then
			updatePreviewTracer(aimVisual, grappleOk)
		else
			destroyPreviewTracer()
		end
	end)

	-- ── Cleanup (called on character removal / respawn) ───────────────────────
	return function()
		walkSpeedAttrConn:Disconnect()
		jumpConn:Disconnect()
		beginConn:Disconnect()
		releaseConn:Disconnect()
		diedConn:Disconnect()
		disconnectMobileBound()
		for _, c in pgWatchConns do c:Disconnect() end
		table.clear(pgWatchConns)
		if r6RenderBindName then
			pcall(function()
				RunService:UnbindFromRenderStep(r6RenderBindName :: string)
			end)
		end
		heartbeat:Disconnect()
		for _, c in statConns do c:Disconnect() end
		if isSwinging then stopSwing(false) end
		destroyPreviewTracer()
		stopSwingAnim()
		clearVisuals()
		pcall(function() camera.FieldOfView = fovBase end)
		pcall(function()
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
		end)
		pcall(function()
			local animSc = animateScript
			if animSc and animSc:IsA("LocalScript") then
				animSc.Disabled = false
			end
		end)
		if useR6Procedural and r6Pose.rs and r6Pose.baseRS then
			r6Pose.rs.C0 = r6Pose.baseRS
		end
		if useR6Procedural and r6Pose.ls and r6Pose.baseLS then
			r6Pose.ls.C0 = r6Pose.baseLS
		end
	end
end

-- ── Entry point ───────────────────────────────────────────────────────────────
local dispose: (() -> ())?

local function onCharacter(char: Model)
	if dispose then dispose(); dispose = nil end
	dispose = boot(char)
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end
