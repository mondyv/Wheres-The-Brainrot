-- [ACTIVE] CurrentAreaController
--[[
	Shows SideUI.Top.CurrentArea whenever the player is outside the safezone
	(unless a gameplay cutscene has hidden HUD). Uses land luck hitboxes with
	nearest-land fallback so the meter does not flicker between OBBs / streaming.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SwingUpgrades = require(Shared:WaitForChild("SwingUpgrades"))
local PlotLuck = SwingUpgrades.PlotLuck
local LandResolver = require(Shared:WaitForChild("LandResolver"))
local SafezoneUtil = require(Shared:WaitForChild("SafezoneUtil"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local FloatingClaimCutscene = require(script.Parent.FloatingClaimCutscene)
local GameplayCutsceneGate = require(script.Parent.GameplayCutsceneGate)

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
local activeTierIndex = 1
local closePending: thread? = nil
local introToken = 0
local idleToken = 0
local swingConn: RBXScriptConnection? = nil
local heartbeatConn: RBXScriptConnection? = nil
local wired = false
local pruneAccum = 0
local PRUNE_INTERVAL = 8

local function cancelClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function tierIntensity(tierIndex: number): number
	return math.clamp((tierIndex - 1) / 7, 0, 1)
end

local function tierRestScale(tierIndex: number): number
	return 1 + tierIntensity(tierIndex) * 0.16
end

local function prepareTextLabel(label: TextLabel)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Rotation = 0
	for _, child in label:GetChildren() do
		if child:IsA("UIScale") then
			child:Destroy()
		elseif child:IsA("UIGradient") then
			child.Offset = Vector2.new(0, 0)
		elseif child:IsA("UIStroke") then
			-- Border mode draws a box behind the text; Contextual follows the glyphs only.
			child.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		end
	end
end

local function prepareArea(root: GuiObject)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	for _, desc in root:GetDescendants() do
		if desc:IsA("GuiObject") and not desc:IsA("TextLabel") then
			desc.BackgroundTransparency = 1
			desc.BorderSizePixel = 0
		end
	end
end

local function setGradient(label: TextLabel?, gradientName: string?)
	if not label then
		return
	end
	for _, c in label:GetChildren() do
		if c:IsA("UIGradient") then
			local enabled = gradientName ~= nil and c.Name == gradientName
			c.Enabled = enabled
			if not enabled then
				c.Offset = Vector2.new(0, 0)
			end
		end
	end
end

local function applyLuckVisuals(displayLuck: number)
	local gradientName = PlotLuck.gradientNameForDisplay(displayLuck)
	local amountText = tostring(math.floor(displayLuck + 0.5)) .. "X"

	if multiplier then
		multiplier.Text = amountText
		if gradientName then
			multiplier.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
		setGradient(multiplier, gradientName)
	end
	if luckText then
		luckText.Text = "LUCK"
		if gradientName then
			luckText.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
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

local function resetAreaTransform(tierIndex: number?)
	if currentArea and restPosition then
		currentArea.Position = restPosition
		currentArea.Rotation = 0
	end
	if areaScale then
		areaScale.Scale = tierRestScale(tierIndex or 1)
	end
end

type TierMotion = {
	dropHeight: number,
	popScale: number,
	dropTime: number,
	burstDuration: number,
	burstPosAmp: number,
	burstFreq: number,
	idlePosAmp: number,
	idlePeriod: number,
	idleScaleAmp: number,
}

local function motionForTier(tierIndex: number): TierMotion
	local t = math.clamp(tierIndex, 1, 8)
	local intensity = tierIntensity(t)
	local restScale = tierRestScale(tierIndex)

	if t <= 2 then
		return {
			dropHeight = 18 + t * 3,
			popScale = restScale * (1.04 + intensity * 0.02),
			dropTime = 0.44,
			burstDuration = 0,
			burstPosAmp = 0,
			burstFreq = 0,
			idlePosAmp = 1 + t * 0.4,
			idlePeriod = 3.6,
			idleScaleAmp = 0.006,
		}
	elseif t <= 4 then
		return {
			dropHeight = 24 + t * 4,
			popScale = restScale * (1.06 + intensity * 0.03),
			dropTime = 0.42,
			burstDuration = 0,
			burstPosAmp = 0,
			burstFreq = 0,
			idlePosAmp = 2 + t * 0.6,
			idlePeriod = 3 - intensity * 0.5,
			idleScaleAmp = 0.01,
		}
	elseif t <= 6 then
		return {
			dropHeight = 30 + t * 5,
			popScale = restScale * (1.09 + intensity * 0.04),
			dropTime = 0.4,
			burstDuration = 0.4 + (t - 4) * 0.1,
			burstPosAmp = 4 + t * 1.2,
			burstFreq = 16 + t * 3,
			idlePosAmp = 3 + t * 0.8,
			idlePeriod = 2.2 - (t - 5) * 0.12,
			idleScaleAmp = 0.016,
		}
	else
		return {
			dropHeight = 38 + t * 6,
			popScale = restScale * (1.12 + intensity * 0.05),
			dropTime = 0.36,
			burstDuration = 0.62 + (t - 6) * 0.14,
			burstPosAmp = 7 + t * 1.8,
			burstFreq = 22 + t * 4,
			idlePosAmp = 5 + t * 1.1,
			idlePeriod = 1.1 - (t - 7) * 0.07,
			idleScaleAmp = 0.026 + (t - 6) * 0.005,
		}
	end
end

local function playLandBurst(token: number, motion: TierMotion, onDone: () -> ())
	if UserInputService.TouchEnabled then
		onDone()
		return
	end
	if motion.burstDuration <= 0 or not currentArea or not restPosition then
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
		if token ~= introToken or not currentArea or not restPosition then
			if swingConn then
				swingConn:Disconnect()
				swingConn = nil
			end
			return
		end

		local elapsed = os.clock() - t0
		if elapsed >= motion.burstDuration then
			currentArea.Position = restPosition
			if swingConn then
				swingConn:Disconnect()
				swingConn = nil
			end
			onDone()
			return
		end

		local falloff = math.exp(-decay * elapsed)
		local px = math.sin(elapsed * motion.burstFreq + phase) * motion.burstPosAmp * falloff
		local py = math.sin(elapsed * motion.burstFreq * 1.6 + phase * 0.7) * motion.burstPosAmp * 0.45 * falloff
		currentArea.Position = restPosition + UDim2.fromOffset(px, py)
	end)
end

local function startTierIdle(tierIndex: number, motion: TierMotion)
	if UserInputService.TouchEnabled then
		return
	end
	if motion.idlePosAmp <= 0 or not currentArea or not areaScale or not restPosition then
		return
	end

	if swingConn then
		swingConn:Disconnect()
		swingConn = nil
	end

	idleToken += 1
	local myIdle = idleToken
	local phase = math.random() * math.pi * 2
	local restScale = tierRestScale(tierIndex)

	swingConn = RunService.RenderStepped:Connect(function()
		if myIdle ~= idleToken or not currentArea or not currentArea.Visible or not restPosition then
			return
		end
		local t = os.clock()
		local wave = math.sin((t / motion.idlePeriod) * math.pi * 2 + phase)
		local wave2 = math.sin((t / motion.idlePeriod) * math.pi * 3.2 + phase * 1.4)
		local px = wave * motion.idlePosAmp + wave2 * motion.idlePosAmp * 0.35
		local py = wave2 * motion.idlePosAmp * 0.25
		currentArea.Position = restPosition + UDim2.fromOffset(px, py)
		if motion.idleScaleAmp > 0 then
			areaScale.Scale = restScale + wave2 * motion.idleScaleAmp
		end
	end)
end

local function playIntro(displayLuck: number, tierIndex: number)
	if not currentArea or not areaScale or not restPosition then
		return
	end

	introToken += 1
	local myIntro = introToken
	activeTierIndex = tierIndex
	stopIdle()
	resetAreaTransform(tierIndex)

	currentArea.Visible = true
	applyLuckVisuals(displayLuck)
	-- Land/base multiplier UI — LandMultiply only (never Notification1).
	GameSoundEffects.playLandMultiply()

	local motion = motionForTier(tierIndex)
	local restScale = tierRestScale(tierIndex)

	currentArea.Position = restPosition + UDim2.fromOffset(0, -motion.dropHeight)
	areaScale.Scale = restScale * 0.82

	TweenService:Create(
		currentArea,
		TweenInfo.new(motion.dropTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = restPosition }
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

		TweenService:Create(
			areaScale,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = restScale }
		):Play()

		playLandBurst(myIntro, motion, function()
			if myIntro == introToken then
				startTierIdle(tierIndex, motion)
			end
		end)
	end)
end

local function hideArea()
	stopIdle()
	introToken += 1
	activeDisplayLuck = nil
	activeTierIndex = 1
	if currentArea and restPosition and currentArea.Visible then
		local hideTween = TweenService:Create(
			currentArea,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = restPosition + UDim2.fromOffset(0, -10) }
		)
		if areaScale then
			TweenService:Create(areaScale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Scale = tierRestScale(activeTierIndex) * 0.94,
			}):Play()
		end
		hideTween:Play()
		hideTween.Completed:Once(function()
			if currentArea then
				currentArea.Visible = false
			end
			resetAreaTransform(1)
		end)
	else
		if currentArea then
			currentArea.Visible = false
		end
		resetAreaTransform(1)
	end
end

local function showArea(displayLuck: number)
	if activeDisplayLuck == displayLuck then
		return
	end
	activeDisplayLuck = displayLuck
	cancelClose()
	local tierIndex = PlotLuck.tierIndex(displayLuck)
	task.defer(function()
		if activeDisplayLuck ~= displayLuck then
			return
		end
		playIntro(displayLuck, tierIndex)
	end)
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

local function isCutsceneBlockingMeters(): boolean
	if GameplayUiVisibility.isHidden() then
		return true
	end
	if StandDialogueCutscene.isActive() then
		return true
	end
	if FloatingClaimCutscene.isActive() then
		return true
	end
	if GameplayCutsceneGate.isAmbushOrChaseActive() then
		return true
	end
	return false
end

local function resolveMeterLuck(pos: Vector3): number?
	-- Prefer live OBB (most accurate), then LandResolver nearest-land fallback.
	local best: number? = nil
	for _, zone in ipairs(zones) do
		if not zone.hitbox.Parent then
			continue
		end
		if isPointInsidePartOBB(pos, zone.hitbox, 2.75) and (not best or zone.displayLuck > best) then
			best = zone.displayLuck
		end
	end
	if best then
		return best
	end
	local fallback = LandResolver.resolveDisplayLuckAtPosition(pos)
	if typeof(fallback) == "number" and fallback >= 1 then
		return fallback
	end
	return nil
end

local function tick()
	if isCutsceneBlockingMeters() then
		cancelClose()
		if activeDisplayLuck then
			hideArea()
		end
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		if activeDisplayLuck and not closePending then
			scheduleHide()
		end
		return
	end
	local pos = (hrp :: BasePart).Position

	if SafezoneUtil.isWorldPointInSafezone(pos) then
		if activeDisplayLuck and not closePending then
			scheduleHide()
		end
		return
	end

	local luck = resolveMeterLuck(pos) or 1
	showArea(luck)
end

local function unregisterHitbox(part: BasePart)
	if not registeredHitboxes[part] then
		return
	end
	registeredHitboxes[part] = nil
	for i = #zones, 1, -1 do
		if zones[i].hitbox == part then
			table.remove(zones, i)
			break
		end
	end
end

local function pruneDeadZones()
	for i = #zones, 1, -1 do
		local hitbox = zones[i].hitbox
		if not hitbox.Parent then
			registeredHitboxes[hitbox] = nil
			table.remove(zones, i)
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
	part.Destroying:Connect(function()
		unregisterHitbox(part)
	end)
end

local function scanLuckHitboxesChunked(root: Instance)
	task.spawn(function()
		local stack = { root }
		local processed = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			if inst:IsA("BasePart") then
				tryRegisterHitbox(inst)
			end
			for _, child in inst:GetChildren() do
				table.insert(stack, child)
			end
			processed += 1
			if processed % 400 == 0 then
				task.wait()
			end
		end
	end)
end

local function hookLuckRoot(root: Instance)
	if hookedLuckRoots[root] then
		return
	end
	hookedLuckRoots[root] = true
	scanLuckHitboxesChunked(root)
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
	if wired then
		return
	end
	wired = true

	local main = PlayerGuiMain.ensure(player)
	if not main then
		wired = false
		warn("[CurrentAreaController] PlayerGui.Main missing")
		return
	end

	local sideUI = main:WaitForChild("SideUI", 15)
	local top = sideUI and sideUI:FindFirstChild("Top")
	local area = top and top:FindFirstChild("CurrentArea")
	if not area or not area:IsA("GuiObject") then
		wired = false
		warn("[CurrentAreaController] SideUI.Top.CurrentArea missing")
		return
	end

	currentArea = area
	restPosition = area.Position
	luckText = area:FindFirstChild("LuckText", true) :: TextLabel?
	multiplier = area:FindFirstChild("Multiplier", true) :: TextLabel?

	prepareArea(area)
	if luckText then
		prepareTextLabel(luckText)
	end
	if multiplier then
		prepareTextLabel(multiplier)
	end

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

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		tickAccum += dt
		pruneAccum += dt
		if pruneAccum >= PRUNE_INTERVAL then
			pruneAccum = 0
			pruneDeadZones()
		end
		if tickAccum < TICK_INTERVAL then
			return
		end
		tickAccum = 0
		tick()
	end)
end

return CurrentAreaController
