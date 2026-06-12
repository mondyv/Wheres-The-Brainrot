-- [ACTIVE] CurrentAreaController
--[[
	Shows SideUI.Top.CurrentArea when the player enters a land luck hitbox.
	Enables the matching UIGradient on LuckText + Multiplier (1x = default, no gradient).
	Entrance: drop + pop, left–right tilt settle; higher tiers shake harder on land and while idle.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local SwingUpgrades = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local CLOSE_DEBOUNCE = 0.22
local TICK_INTERVAL = 0.5
local tickAccum = 0

type LuckZone = {
	hitbox: BasePart,
	displayLuck: number,
	tierIndex: number,
}

local zones: { LuckZone } = {}
local registeredHitboxes: { [BasePart]: boolean } = {}
local hookedLuckRoots: { [Instance]: boolean } = {}
local currentArea: GuiObject? = nil
local luckText: TextLabel? = nil
local multiplier: TextLabel? = nil
local areaScale: UIScale? = nil
local restPosition: UDim2? = nil

local activeDisplayLuck: number? = nil
local closePending: thread? = nil
local introToken = 0
local idleToken = 0
local swingConn: RBXScriptConnection? = nil

local function cancelClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function setGradient(label: TextLabel?, gradientName: string?)
	if not label then
		return
	end
	for _, c in label:GetChildren() do
		if c:IsA("UIGradient") then
			c.Enabled = (gradientName ~= nil and c.Name == gradientName)
		end
	end
end

local function applyLuckVisuals(displayLuck: number)
	local gradientName = PlotLuck.gradientNameForDisplay(displayLuck)
	local amountText = tostring(math.floor(displayLuck + 0.5)) .. "X"

	if multiplier then
		multiplier.Text = amountText
		setGradient(multiplier, gradientName)
	end
	if luckText then
		luckText.Text = "LUCK"
		setGradient(luckText, gradientName)
	end
end

local function stopIdle()
	idleToken += 1
	if swingConn then
		swingConn:Disconnect()
		swingConn = nil
	end
end

local function resetAreaTransform()
	if currentArea and restPosition then
		currentArea.Position = restPosition
		currentArea.Rotation = 0
	end
	if areaScale then
		areaScale.Scale = 1
	end
end

type TierMotion = {
	maxTilt: number,
	dropHeight: number,
	popScale: number,
	dropTime: number,
	settleAngles: { number },
	settleTimes: { number },
	burstDuration: number,
	burstRotAmp: number,
	burstFreq: number,
	idleRotAmp: number,
	idlePeriod: number,
	idleScaleAmp: number,
}

local function motionForTier(tierIndex: number, dir: number): TierMotion
	local t = math.clamp(tierIndex, 1, 8)
	local maxTilt = 2 + t * 1.65

	if t <= 2 then
		return {
			maxTilt = maxTilt,
			dropHeight = 16 + t * 2,
			popScale = 1.03,
			dropTime = 0.46,
			settleAngles = { maxTilt * 0.35 * dir, -maxTilt * 0.12 * dir, 0 },
			settleTimes = { 0.5, 0.45, 0.5 },
			burstDuration = 0,
			burstRotAmp = 0,
			burstFreq = 0,
			idleRotAmp = 0,
			idlePeriod = 99,
			idleScaleAmp = 0,
		}
	elseif t <= 4 then
		return {
			maxTilt = maxTilt,
			dropHeight = 20 + t * 3,
			popScale = 1.05,
			dropTime = 0.48,
			settleAngles = { maxTilt * 0.45 * dir, -maxTilt * 0.3 * dir, maxTilt * 0.1 * dir, 0 },
			settleTimes = { 0.42, 0.38, 0.36, 0.48 },
			burstDuration = 0,
			burstRotAmp = 0,
			burstFreq = 0,
			idleRotAmp = 0.35 + t * 0.12,
			idlePeriod = 3.4,
			idleScaleAmp = 0,
		}
	elseif t <= 6 then
		return {
			maxTilt = maxTilt,
			dropHeight = 26 + t * 4,
			popScale = 1.08,
			dropTime = 0.44,
			settleAngles = {
				maxTilt * 0.58 * dir,
				-maxTilt * 0.48 * dir,
				maxTilt * 0.3 * dir,
				-maxTilt * 0.14 * dir,
				0,
			},
			settleTimes = { 0.3, 0.28, 0.26, 0.24, 0.38 },
			burstDuration = 0.45 + (t - 4) * 0.12,
			burstRotAmp = maxTilt * (0.35 + (t - 4) * 0.12),
			burstFreq = 14 + t * 3,
			idleRotAmp = 1.2 + t * 0.35,
			idlePeriod = 2.4 - (t - 5) * 0.15,
			idleScaleAmp = 0.012,
		}
	else
		-- 750x–1750x: big tilt, fast settle, vigorous burst + idle
		return {
			maxTilt = maxTilt,
			dropHeight = 34 + t * 5,
			popScale = 1.12,
			dropTime = 0.4,
			settleAngles = {
				maxTilt * 0.65 * dir,
				-maxTilt * 0.55 * dir,
				maxTilt * 0.38 * dir,
				-maxTilt * 0.22 * dir,
				maxTilt * 0.08 * dir,
				0,
			},
			settleTimes = { 0.24, 0.22, 0.2, 0.18, 0.2, 0.35 },
			burstDuration = 0.65 + (t - 6) * 0.15,
			burstRotAmp = maxTilt * 0.55,
			burstFreq = 20 + t * 4,
			idleRotAmp = 2.8 + t * 0.55,
			idlePeriod = 1.15 - (t - 7) * 0.08,
			idleScaleAmp = 0.022 + (t - 6) * 0.006,
		}
	end
end

-- Damped rotation burst after settle (high tiers only; frame-only, no layout fight).
local function playVigorousBurst(token: number, motion: TierMotion, onDone: () -> ())
	if motion.burstDuration <= 0 or not currentArea then
		onDone()
		return
	end

	if swingConn then
		swingConn:Disconnect()
		swingConn = nil
	end

	local t0 = os.clock()
	local phase = math.random() * math.pi * 2
	local decay = 5.5 - motion.burstDuration * 2

	swingConn = RunService.RenderStepped:Connect(function()
		if token ~= introToken or not currentArea then
			if swingConn then
				swingConn:Disconnect()
				swingConn = nil
			end
			return
		end

		local elapsed = os.clock() - t0
		if elapsed >= motion.burstDuration then
			currentArea.Rotation = 0
			if swingConn then
				swingConn:Disconnect()
				swingConn = nil
			end
			onDone()
			return
		end

		local falloff = math.exp(-decay * elapsed)
		local wobble = math.sin(elapsed * motion.burstFreq + phase) * motion.burstRotAmp * falloff
		local wobble2 = math.sin(elapsed * motion.burstFreq * 1.37 + phase * 1.3) * motion.burstRotAmp * 0.4 * falloff
		currentArea.Rotation = wobble + wobble2
	end)
end

local function startTierIdle(tierIndex: number, motion: TierMotion)
	if motion.idleRotAmp <= 0 or not currentArea or not areaScale then
		return
	end

	idleToken += 1
	local myIdle = idleToken
	local phase = math.random() * math.pi * 2
	local vigorous = tierIndex >= 6

	swingConn = RunService.RenderStepped:Connect(function()
		if myIdle ~= idleToken or not currentArea or not currentArea.Visible then
			return
		end
		local t = os.clock()
		local wave = math.sin((t / motion.idlePeriod) * math.pi * 2 + phase)
		currentArea.Rotation = wave * motion.idleRotAmp
		if motion.idleScaleAmp > 0 then
			local w2 = math.sin((t / motion.idlePeriod) * math.pi * 4 + phase * 0.7)
			areaScale.Scale = 1 + w2 * motion.idleScaleAmp
		end
		if vigorous and tierIndex >= 7 then
			-- Extra high-frequency layer on top for 1250x / 1750x
			currentArea.Rotation += math.sin(t * 22 + phase) * motion.idleRotAmp * 0.18
		end
	end)
end

local function chainTilt(token: number, angles: { number }, durations: { number }, onDone: () -> ())
	local step = 0
	local function nextStep()
		if token ~= introToken or not currentArea then
			return
		end
		step += 1
		if step > #angles then
			onDone()
			return
		end
		local tw = TweenService:Create(
			currentArea,
			TweenInfo.new(durations[step], Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Rotation = angles[step] }
		)
		tw.Completed:Once(nextStep)
		tw:Play()
	end
	nextStep()
end

local function playIntro(displayLuck: number, tierIndex: number)
	if not currentArea or not areaScale or not restPosition then
		return
	end

	introToken += 1
	local myIntro = introToken
	stopIdle()
	resetAreaTransform()

	currentArea.Visible = true
	applyLuckVisuals(displayLuck)

	local dir = if math.random() > 0.5 then 1 else -1
	local motion = motionForTier(tierIndex, dir)
	local landRot = -motion.maxTilt * 0.75 * dir

	currentArea.Position = restPosition + UDim2.fromOffset(0, -motion.dropHeight)
	currentArea.Rotation = motion.maxTilt * dir
	areaScale.Scale = 0.88

	TweenService:Create(
		currentArea,
		TweenInfo.new(motion.dropTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = restPosition, Rotation = landRot }
	):Play()
	TweenService:Create(
		areaScale,
		TweenInfo.new(motion.dropTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = motion.popScale }
	):Play()

	task.delay(motion.dropTime, function()
		if myIntro ~= introToken or not currentArea then
			return
		end

		TweenService
			:Create(areaScale, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
			:Play()

		chainTilt(myIntro, motion.settleAngles, motion.settleTimes, function()
			if myIntro ~= introToken then
				return
			end
			playVigorousBurst(myIntro, motion, function()
				if myIntro == introToken then
					startTierIdle(tierIndex, motion)
				end
			end)
		end)
	end)
end

local function hideArea()
	stopIdle()
	introToken += 1
	activeDisplayLuck = nil
	if currentArea and restPosition and currentArea.Visible then
		local hideRot = currentArea.Rotation * 0.4
		local hideTween = TweenService:Create(
			currentArea,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = restPosition + UDim2.fromOffset(0, -10), Rotation = hideRot }
		)
		if areaScale then
			TweenService:Create(areaScale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Scale = 0.94,
			}):Play()
		end
		hideTween:Play()
		hideTween.Completed:Once(function()
			if currentArea then
				currentArea.Visible = false
			end
			resetAreaTransform()
		end)
	else
		if currentArea then
			currentArea.Visible = false
		end
		resetAreaTransform()
	end
end

local function showArea(displayLuck: number)
	if activeDisplayLuck == displayLuck then
		return
	end
	activeDisplayLuck = displayLuck
	cancelClose()
	playIntro(displayLuck, PlotLuck.tierIndex(displayLuck))
end

local function scheduleHide()
	cancelClose()
	closePending = task.delay(CLOSE_DEBOUNCE, function()
		closePending = nil
		hideArea()
	end)
end

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart, padding: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function findActiveZone(): LuckZone?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end
	local pos = (hrp :: BasePart).Position

	local best: LuckZone? = nil
	for _, zone in ipairs(zones) do
		if not zone.hitbox.Parent then
			continue
		end
		if isPointInsidePartOBB(pos, zone.hitbox, 2.75) and (not best or zone.displayLuck > best.displayLuck) then
			best = zone
		end
	end
	return best
end

local function tick()
	local zone = findActiveZone()
	if zone then
		showArea(zone.displayLuck)
	else
		if activeDisplayLuck and not closePending then
			scheduleHide()
		end
	end
end

local function tryRegisterHitbox(part: BasePart)
	if registeredHitboxes[part] then
		return
	end
	local displayLuck = PlotLuck.parseHitboxDisplayLuck(part.Name)
	if not displayLuck then
		return
	end
	registeredHitboxes[part] = true
	table.insert(zones, {
		hitbox = part,
		displayLuck = displayLuck,
		tierIndex = PlotLuck.tierIndex(displayLuck),
	})
end

local function scanLuckHitboxes(root: Instance)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("BasePart") then
			tryRegisterHitbox(desc)
		end
	end
end

local function hookLuckRoot(root: Instance)
	if hookedLuckRoots[root] then
		return
	end
	hookedLuckRoots[root] = true
	scanLuckHitboxes(root)
	root.DescendantAdded:Connect(function(ch)
		if ch:IsA("BasePart") then
			tryRegisterHitbox(ch)
		end
	end)
	root.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			hookedLuckRoots[root] = nil
		end
	end)
end

local function beginLuckDiscovery(map: Instance)
	local function hookNamedRoot(name: string)
		local root = map:FindFirstChild(name)
		if root then
			hookLuckRoot(root)
			return
		end
		task.spawn(function()
			local container = map:WaitForChild(name, 120)
			if container then
				hookLuckRoot(container)
			end
		end)
	end

	hookNamedRoot("Lands")
	hookNamedRoot("Spawn And Bases")

	map.ChildAdded:Connect(function(child)
		if child.Name == "Lands" or child.Name == "Spawn And Bases" then
			task.defer(hookLuckRoot, child)
		end
	end)

	task.delay(8, function()
		if #zones == 0 then
			warn(
				"[CurrentAreaController] No *xHitbox parts found under workspace.Map.Lands or Spawn And Bases (check streaming / hitbox names like 1xHitbox, 10xHitbox)"
			)
		end
	end)
end

local CurrentAreaController = {}

function CurrentAreaController.init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[CurrentAreaController] PlayerGui.Main missing")
		return
	end

	local sideUI = main:WaitForChild("SideUI", 15)
	local top = sideUI and sideUI:FindFirstChild("Top")
	local area = top and top:FindFirstChild("CurrentArea")
	if not area or not area:IsA("GuiObject") then
		warn("[CurrentAreaController] SideUI.Top.CurrentArea missing")
		return
	end

	currentArea = area
	restPosition = area.Position
	luckText = area:FindFirstChild("LuckText", true) :: TextLabel?
	multiplier = area:FindFirstChild("Multiplier", true) :: TextLabel?

	areaScale = area:FindFirstChildOfClass("UIScale")
	if not areaScale then
		areaScale = Instance.new("UIScale")
		areaScale.Scale = 1
		areaScale.Parent = area
	end

	hideArea()

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 120)
		if not map then
			warn("[CurrentAreaController] workspace.Map never appeared")
			return
		end
		beginLuckDiscovery(map)
	end)

	player.CharacterAdded:Connect(function()
		cancelClose()
		hideArea()
	end)

	RunService.Heartbeat:Connect(function(dt)
		tickAccum += dt
		if tickAccum < TICK_INTERVAL then
			return
		end
		tickAccum = 0
		tick()
	end)
end

return CurrentAreaController
