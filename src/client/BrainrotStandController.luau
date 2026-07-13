-- [ACTIVE] BrainrotStandController
--[[
	BrainrotStandController (client)
	• Wires a click overlay on every stand's Upgrade SurfaceGui → fires UpgradeStandBrainrot.
	• Money VFX: brief burst on collect only. Any pre-existing money emitters on the stand are
	  disabled at init so they don't play continuously; we re-enable them only for the burst.
	• Animates the cash pad scale + colour pulse on collection; pulses upgrade panel on upgrade.
	• Empty-stand ProximityPrompt ("Place Brainrot"): hidden until the local player equips a
	  brainrot Tool (BrainrotTool attribute) or is carrying from a bush, so prompts stay off idle pads.

	Server is authoritative for placement / income — this controller is presentation only.
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))
local CarryGate = require(script.Parent.CarryGate)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local MainGradientButtons = require(script.Parent.MainGradientButtons)
local TopNotifController = require(script.Parent.TopNotifController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local PlotMarkerVisibility = require(script.Parent.PlotMarkerVisibility)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local BrainrotStandConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotStandConfig"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))

local STAND_TAG = "BrainrotStand"
local STAND_ACCUMULATED_ATTR = "StandAccumulatedCash"
local STAND_UPGRADE_COST_ATTR = "StandUpgradeCost"
local BRAINROT_MAX_LEVEL = 90
-- Server sets this on the stand's ProximityPrompt while the stand is empty; client gates Enabled.
local PLACE_PROMPT_ATTR = "BrainrotPlacePrompt"
local DEFAULT_PLACE_DISTANCE = 10
local DEFAULT_PICKUP_DISTANCE = 14
local PROMPT_REFRESH_INTERVAL = 0.3
local PROMPT_MOVE_SKIP_THRESHOLD = 2
local STAND_LAZY_INIT_RANGE = 220

local player = Players.LocalPlayer
local MONEY_VFX_HOLD_SEC = 0.14
local CHILD_WAIT_TIMEOUT = 8 -- seconds; stand children may not have replicated when the tag arrives
local BRAINROT_HOP_HEIGHT = 0.34
local BRAINROT_HOP_COOLDOWN = 0.4

local M = {}

-- ── Remotes ──────────────────────────────────────────────────────────────────

local function waitStandRemotes(): Folder?
	local folder = ReplicatedStorage:WaitForChild("StandRemotes", 60)
	if not folder then
		warn("[BrainrotStandController] StandRemotes folder missing")
		return nil
	end
	return folder :: Folder
end

local remotes: Folder? = nil
local upgradeRE: RemoteEvent? = nil
local prepareRobuxStandUpgradeRE: RemoteEvent? = nil
local upgradeFeedbackRE: RemoteEvent? = nil
local collectFXRE: RemoteEvent? = nil

-- ── VFX setup ────────────────────────────────────────────────────────────────

local function findMoneyVFXTemplate(): Instance?
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	if not vfxFolder then
		return nil
	end
	local plot = vfxFolder:FindFirstChild("PlotVFX")
	if not plot then
		return nil
	end
	local money = plot:FindFirstChild("Money")
	if money then
		return money
	end
	return nil
end

-- Always returns an Attachment — clones the project's Money template if present, otherwise
-- creates an empty one (the fallback burst emitter will be added on demand by playMoneyPickupVFX).
local function cloneMoneyAttachmentInto(parentPart: BasePart): Attachment
	local existing = parentPart:FindFirstChild("StandMoneyVFX")
	if existing and existing:IsA("Attachment") then
		return existing :: Attachment
	end
	local template = findMoneyVFXTemplate()
	local newAtt: Attachment
	if template and template:IsA("Attachment") then
		newAtt = template:Clone() :: Attachment
	elseif template then
		newAtt = Instance.new("Attachment")
		for _, c in ipairs(template:GetChildren()) do
			c:Clone().Parent = newAtt
		end
	else
		newAtt = Instance.new("Attachment")
	end
	newAtt.Name = "StandMoneyVFX"
	newAtt.Parent = parentPart
	newAtt.Position = Vector3.new(0, parentPart.Size.Y * 0.22, 0)
	for _, e in ipairs(newAtt:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
		end
	end
	return newAtt
end

local function setEmittersEnabled(attachment: Attachment?, enabled: boolean)
	if not attachment then
		return
	end
	for _, e in ipairs(attachment:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = enabled
		end
	end
end

local CASH_VFX_TEMPLATE_EMITTER_LIMIT = 3
local CASH_VFX_BASE_EMIT = 4
local CASH_VFX_MIN_EMIT = 3
local CASH_VFX_MAX_EMIT = 8

local function getCashBurstCount(total: number): number
	local amount = if typeof(total) == "number" then math.max(total, 0) else 0
	-- Tiny scaling only: this keeps big cash claims from creating huge particle storms.
	local extra = math.clamp(math.floor(amount / 25000), 0, 3)
	return math.clamp(CASH_VFX_BASE_EMIT + extra, CASH_VFX_MIN_EMIT, CASH_VFX_MAX_EMIT)
end

local function emitBurst(attachment: Attachment?, total: number): boolean
	if not attachment then
		return false
	end

	local emitCount = getCashBurstCount(total)
	local emitted = 0

	for _, e in ipairs(attachment:GetDescendants()) do
		if not e:IsA("ParticleEmitter") or e.Name == "_CashPickupBurst" then
			continue
		end

		emitted += 1
		pcall(function()
			e:Emit(emitCount)
		end)

		if emitted >= CASH_VFX_TEMPLATE_EMITTER_LIMIT then
			break
		end
	end

	return emitted > 0
end

-- Big, colourful one-shot emitter so the burst is obvious even when the project's Money template is missing.
local function ensureFallbackBurstEmitter(att: Attachment): ParticleEmitter
	local existing = att:FindFirstChild("_CashPickupBurst")
	local pe: ParticleEmitter

	if existing and existing:IsA("ParticleEmitter") then
		pe = existing
	else
		if existing then
			existing:Destroy()
		end
		pe = Instance.new("ParticleEmitter")
		pe.Name = "_CashPickupBurst"
		pe.Parent = att
	end

	pe.Enabled = false
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.35, 0.65)
	pe.Speed = NumberRange.new(4, 9)
	pe.SpreadAngle = Vector2.new(110, 110)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-120, 120)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 0.08),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.65, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 255, 130)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 230, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	pe.LightEmission = 0.35
	pe.LightInfluence = 0
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Acceleration = Vector3.new(0, -6, 0)

	return pe
end

-- Short-lived pickup burst: low-cost one-shot particles only.
local FLOAT_RISE_DURATION = 0.85
local FLOAT_RISE_STUDS = 3.2
local CASH_FLOAT_TEXT_SIZE = 26
local FLOAT_STROKE_SCALE = 0.55
local CASH_FLOAT_BURST_COUNT = 8
local MAX_ACTIVE_CASH_FLOATS = 2
local CASH_FLOAT_START_Y_DROP = 0.65
local CASH_COLLECT_VFX_COOLDOWN = 0.18
local AFFORD_REFRESH_DEBOUNCE = 0.15

local cachedCashRateStyle: Instance? = nil
local activeCashFloatCount = 0
local cashFloatSeq = 0
local lastCashCollectVfxAt: { [any]: number } = {}

type RisingFloatTextOpts = {
	text: string?,
	level: number?,
	font: Enum.Font?,
	textSize: number,
	styleSource: Instance?,
	strokeScale: number?,
	useRateGradient: boolean?,
	stackOffsetIndex: number?,
}

local upgradeFloatSeq = 0

local function labelHasGradients(node: Instance): boolean
	local label = BrainrotHeaderStyle.resolveTextLabel(node)
	if not label then
		return false
	end
	for _, child in label:GetChildren() do
		if child:IsA("UIGradient") then
			return true
		end
	end
	return false
end

local function playRisingFloatText(worldPosition: Vector3, opts: RisingFloatTextOpts)
	task.spawn(function()
		local part = Instance.new("Part")
		part.Name = "RisingFloatText"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.new(0.1, 0.1, 0.1)
		part.CFrame = CFrame.new(worldPosition)
		part.Parent = Workspace

		local billboard = Instance.new("BillboardGui")
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.Size = UDim2.fromOffset(math.max(220, opts.textSize * 8), math.max(48, opts.textSize * 1.4))
		local stackIndex = opts.stackOffsetIndex
		if typeof(stackIndex) ~= "number" then
			stackIndex = 0
		end
		billboard.StudsOffset = Vector3.new(0, 0.75 + (stackIndex % 4) * 0.32, 0)
		billboard.Parent = part

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.TextTransparency = 0
		label.ZIndex = 10
		label.Parent = billboard

		local stroke: UIStroke
		local styleSource = opts.styleSource
		if styleSource then
			BrainrotHeaderStyle.prepareFloatTextLabel(label, styleSource, opts.textSize, opts.font)
			if typeof(opts.level) == "number" then
				BrainrotHeaderStyle.applyLevelLabel(label, opts.level)
			else
				label.Text = opts.text or ""
				if opts.useRateGradient == true then
					BrainrotHeaderStyle.applyRateGradient(label)
				else
					BrainrotHeaderStyle.copyActiveGradientFromSource(styleSource, label)
					if not BrainrotHeaderStyle.activeGradientName(label) then
						BrainrotHeaderStyle.selectGradient(label, "Rate")
					end
					if not labelHasGradients(label) then
						local sourceLabel = BrainrotHeaderStyle.resolveTextLabel(styleSource)
						if sourceLabel then
							label.TextColor3 = sourceLabel.TextColor3
						end
					end
				end
			end
			stroke = BrainrotHeaderStyle.copyStrokeFromSource(
				styleSource,
				label,
				opts.strokeScale or FLOAT_STROKE_SCALE
			) or Instance.new("UIStroke")
		else
			if opts.font then
				label.FontFace = Font.fromEnum(opts.font)
			else
				UiFonts.applyBody(label)
			end
			label.Text = opts.text or ""
			label.TextSize = opts.textSize
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextStrokeTransparency = 1
			stroke = Instance.new("UIStroke")
			stroke.Color = Color3.new(0, 0, 0)
			stroke.Thickness = 1
		end
		if stroke.Parent ~= label then
			stroke.Parent = label
		end

		local startCf = part.CFrame
		local fadeStarted = false
		local releasedCashSlot = false
		local function releaseCashFloatSlot()
			if releasedCashSlot or opts.useRateGradient ~= true then
				return
			end
			releasedCashSlot = true
			activeCashFloatCount = math.max(0, activeCashFloatCount - 1)
		end

		local riseProxy = Instance.new("NumberValue")
		riseProxy.Value = 0
		local riseConn = riseProxy:GetPropertyChangedSignal("Value"):Connect(function()
			if not part.Parent then
				releaseCashFloatSlot()
				riseConn:Disconnect()
				return
			end
			local t = riseProxy.Value
			part.CFrame = startCf + Vector3.new(0, FLOAT_RISE_STUDS * t, 0)
			if t >= 0.42 and not fadeStarted then
				fadeStarted = true
				local fadeDur = FLOAT_RISE_DURATION - 0.5
				local fadeInfo = TweenInfo.new(fadeDur, Enum.EasingStyle.Linear)
				TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
				TweenService:Create(stroke, fadeInfo, { Transparency = 1 }):Play()
			end
		end)
		local riseTween = TweenService:Create(
			riseProxy,
			TweenInfo.new(FLOAT_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = 1 }
		)
		riseTween.Completed:Connect(function()
			riseConn:Disconnect()
			riseProxy:Destroy()
			releaseCashFloatSlot()
			if part.Parent then
				part:Destroy()
			end
		end)
		riseTween:Play()
	end)
end

local function playMoneyPickupVFX(attachment: Attachment?, total: number)
	if not attachment then
		return
	end

	local amount = if typeof(total) == "number" then total else 0

	-- Keep emitters disabled so Rate-based particles do not spray extra particles.
	-- ParticleEmitter:Emit() still creates the one-shot burst while Enabled is false.
	setEmittersEnabled(attachment, false)

	local usedTemplateEmitters = emitBurst(attachment, amount)
	if not usedTemplateEmitters then
		ensureFallbackBurstEmitter(attachment):Emit(getCashBurstCount(amount))
	end
end

local function getCashFloatStyleSource(): Instance?
	if cachedCashRateStyle and cachedCashRateStyle.Parent then
		return cachedCashRateStyle
	end
	cachedCashRateStyle = BrainrotHeaderStyle.getHeaderInfoChild("Rate")
	return cachedCashRateStyle
end

local function playCashCollectPresentation(view: StandView, cashAmount: number)
	task.spawn(function()
		local now = os.clock()
		if (lastCashCollectVfxAt[view] or 0) + CASH_COLLECT_VFX_COOLDOWN > now then
			return
		end
		lastCashCollectVfxAt[view] = now

		pulseCashPad(view)
		ensureMoneyVfxOnView(view)
		if view.moneyAttachment then
			playMoneyPickupVFX(view.moneyAttachment, cashAmount)
		end
		if cashAmount <= 0 or activeCashFloatCount >= MAX_ACTIVE_CASH_FLOATS then
			return
		end
		local cashPos: Vector3? = nil
		if view.cashAnchor then
			cashPos = view.cashAnchor.Position
		elseif view.buttonPart then
			cashPos = view.buttonPart.Position
		end
		if not cashPos then
			return
		end
		cashPos -= Vector3.new(0, CASH_FLOAT_START_Y_DROP, 0)
		local styleSource = getCashFloatStyleSource()
		if not styleSource then
			return
		end
		activeCashFloatCount += 1
		cashFloatSeq += 1
		playRisingFloatText(cashPos, {
			text = "+" .. BrainrotEconomy.formatCashAccumulated(cashAmount),
			textSize = CASH_FLOAT_TEXT_SIZE,
			styleSource = styleSource,
			strokeScale = FLOAT_STROKE_SCALE,
			useRateGradient = true,
			stackOffsetIndex = cashFloatSeq,
		})
	end)
end

function pulseExistingEmitters(emitters: { ParticleEmitter })
	if #emitters == 0 then
		return
	end

	local emitted = 0
	for _, e in ipairs(emitters) do
		if not e.Parent then
			continue
		end

		e.Enabled = false
		pcall(function()
			e:Emit(CASH_VFX_BASE_EMIT)
		end)

		emitted += 1
		if emitted >= CASH_VFX_TEMPLATE_EMITTER_LIMIT then
			break
		end
	end
end

-- ── Stand state ──────────────────────────────────────────────────────────────

type StandView = {
	stand: Model,
	buttonPart: BasePart?,
	cashAnchor: BasePart?,
	totalLabel: (TextLabel | TextButton)?,
	displayedCash: number?,
	targetCash: number?,
	accumulatedConn: RBXScriptConnection?,
	upgradeButton: GuiButton?,
	upgradeFrame: GuiObject?,
	moneyAttachment: Attachment?,
	existingEmitters: { ParticleEmitter },
	levelPulseConn: RBXScriptConnection?,
	lastKnownLevel: number?,
}

local views: { [Model]: StandView } = {}
local upgradeScaleTweens: { [Instance]: Tween } = {}
local lastBrainrotHopAt: { [Model]: number } = {}
local lastUpgradeRequestAt: { [Model]: number } = {}
local affordVisualByView: { [StandView]: string } = {}
local cashAffordToken = 0
local UPGRADE_REQUEST_COOLDOWN = 0.22
local standHeartbeatConn: RBXScriptConnection? = nil
local cachedSpawnBasesFolder: Instance? = nil

-- ── Empty-stand place prompt: only when holding a brainrot Tool (local Enabled) ─

local standPlacePromptConns: { [Model]: { RBXScriptConnection } } = {}
local charPlacePromptConns: { RBXScriptConnection } = {}
local promptRefreshAccum = 0
local lastHRPPosition: Vector3? = nil
local cachedTaggedStands: { Model } = {}
local cachedPlotMatch: { [Model]: boolean } = {}

type StandPromptCache = {
	canonical: ProximityPrompt?,
	prompts: { ProximityPrompt },
}
local standPromptCache: { [Model]: StandPromptCache } = {}

local function characterHasBrainrotToolEquipped(char: Model?): boolean
	if not char then
		return false
	end
	for _, ch in char:GetChildren() do
		if ch:IsA("Tool") and ch:GetAttribute("BrainrotTool") == true then
			return true
		end
	end
	return false
end

-- Place prompts when a brainrot Tool is equipped or the player is carrying from a bush haul.
local function canShowPlaceBrainrotPrompt(): boolean
	return characterHasBrainrotToolEquipped(player.Character) or CarryGate.isCarrying()
end

local function standHasBrainrot(stand: Model): boolean
	local name = stand:GetAttribute("BrainrotName")
	return typeof(name) == "string" and name ~= ""
end

local function getStandProximityPrompt(stand: Model): ProximityPrompt?
	local cache = standPromptCache[stand]
	if not cache then
		return nil
	end
	return cache.canonical
end

local function getAllStandProximityPrompts(stand: Model): { ProximityPrompt }
	local cache = standPromptCache[stand]
	if not cache then
		return {}
	end
	return cache.prompts
end

local function rebuildStandPromptCache(stand: Model)
	local prompts: { ProximityPrompt } = {}
	local seen: { [ProximityPrompt]: boolean } = {}
	local canonical: ProximityPrompt? = nil

	local function addPrompt(prompt: ProximityPrompt)
		if seen[prompt] then
			return
		end
		seen[prompt] = true
		table.insert(prompts, prompt)
		if not canonical then
			canonical = prompt
		end
	end

	local decor = stand:FindFirstChild("Decor")
	if decor then
		for _, d in ipairs(decor:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				addPrompt(d :: ProximityPrompt)
			end
		end
	end

	local spawn = stand:FindFirstChild("Spawn", true)
	if spawn and spawn:IsA("BasePart") then
		local onSpawn = (spawn :: BasePart):FindFirstChildWhichIsA("ProximityPrompt")
		if onSpawn then
			addPrompt(onSpawn :: ProximityPrompt)
		end
	end

	if not canonical then
		for _, d in stand:GetDescendants() do
			if d:IsA("ProximityPrompt") then
				addPrompt(d :: ProximityPrompt)
			end
		end
	end

	standPromptCache[stand] = {
		canonical = canonical,
		prompts = prompts,
	}
end

local function invalidateStandPromptCache(stand: Model)
	standPromptCache[stand] = nil
	rebuildStandPromptCache(stand)
end

local function promptWorldDistance(prompt: ProximityPrompt, hrpPos: Vector3): number?
	local parent = prompt.Parent
	if parent and parent:IsA("Attachment") then
		return (hrpPos - parent.WorldPosition).Magnitude
	end
	if parent and parent:IsA("BasePart") then
		return (hrpPos - parent.Position).Magnitude
	end
	return nil
end

local function findSpawnBasesFolder(): Instance?
	if cachedSpawnBasesFolder and cachedSpawnBasesFolder.Parent then
		return cachedSpawnBasesFolder
	end
	cachedSpawnBasesFolder = PlotPaths.findSpawnAndBasesFolder()
	return cachedSpawnBasesFolder
end

-- Slot-assigned plots: hide place prompt unless this stand belongs to our AssignedPlotSlot.
local function standMatchesAssignedPlot(stand: Model): boolean
	local assigned = player:GetAttribute("AssignedPlotSlot")
	if typeof(assigned) ~= "number" then
		return false
	end
	local folder = findSpawnBasesFolder()
	if not folder then
		return true
	end
	local x: Instance? = stand
	while x do
		if x.Parent == folder then
			local sid = x:GetAttribute("PlotSlotId")
			if typeof(sid) ~= "number" then
				return true
			end
			return math.floor(sid :: number) == math.floor(assigned :: number)
		end
		x = x.Parent
	end
	local name = stand:GetAttribute("PlotBaseName")
	if typeof(name) == "string" then
		local root = folder:FindFirstChild(name)
		if root then
			local sid = root:GetAttribute("PlotSlotId")
			if typeof(sid) ~= "number" then
				return true
			end
			return math.floor(sid :: number) == math.floor(assigned :: number)
		end
	end
	return true
end

local function rebuildCachedPlotMatch()
	table.clear(cachedPlotMatch)
	for _, stand in ipairs(cachedTaggedStands) do
		cachedPlotMatch[stand] = standMatchesAssignedPlot(stand)
	end
end

local function standMatchesAssignedPlotCached(stand: Model): boolean
	local cached = cachedPlotMatch[stand]
	if cached ~= nil then
		return cached
	end
	local matches = standMatchesAssignedPlot(stand)
	cachedPlotMatch[stand] = matches
	return matches
end

local function rebuildCachedTaggedStands()
	table.clear(cachedTaggedStands)
	for _, inst in CollectionService:GetTagged(STAND_TAG) do
		if inst:IsA("Model") then
			table.insert(cachedTaggedStands, inst :: Model)
		end
	end
	rebuildCachedPlotMatch()
end

local function registerTaggedStand(stand: Model)
	for _, existing in ipairs(cachedTaggedStands) do
		if existing == stand then
			return
		end
	end
	table.insert(cachedTaggedStands, stand)
	cachedPlotMatch[stand] = standMatchesAssignedPlot(stand)
end

local function unregisterTaggedStand(stand: Model)
	for i = #cachedTaggedStands, 1, -1 do
		if cachedTaggedStands[i] == stand then
			table.remove(cachedTaggedStands, i)
			break
		end
	end
	cachedPlotMatch[stand] = nil
end

-- Only one stand prompt visible at a time (closest). Hide pick-up while holding a brainrot.
local function refreshStandProximityPromptVisibility(forceRefresh: boolean?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local hrpPos = hrp.Position
	if not forceRefresh and lastHRPPosition and (hrpPos - lastHRPPosition).Magnitude < PROMPT_MOVE_SKIP_THRESHOLD then
		return
	end
	local holdingTool = canShowPlaceBrainrotPrompt()
	local ws = workspace

	type Candidate = { prompt: ProximityPrompt, dist: number }
	local candidates: { Candidate } = {}
	local allPrompts: { ProximityPrompt } = {}

	for _, stand in ipairs(cachedTaggedStands) do
		if not stand.Parent or not stand:IsDescendantOf(ws) then
			continue
		end
		local canonical = getStandProximityPrompt(stand)
		if canonical and not canonical.Parent then
			invalidateStandPromptCache(stand)
			canonical = getStandProximityPrompt(stand)
		end
		if not canonical then
			continue
		end
		for _, pp in getAllStandProximityPrompts(stand) do
			if pp.Parent then
				table.insert(allPrompts, pp)
			end
		end

		local pp = canonical

		local locked = stand:GetAttribute("BrainrotStandLocked") == true
		if locked or not cachedPlotMatch[stand] then
			continue
		end

		local isPlace = pp:GetAttribute(PLACE_PROMPT_ATTR) == true or not standHasBrainrot(stand)
		if isPlace then
			if not holdingTool then
				continue
			end
		else
			if holdingTool then
				continue
			end
		end

		local dist = promptWorldDistance(pp, hrpPos)
		if not dist then
			continue
		end

		local maxDist = pp.MaxActivationDistance
		if maxDist <= 0 then
			maxDist = if isPlace then DEFAULT_PLACE_DISTANCE else DEFAULT_PICKUP_DISTANCE
		end
		if dist > maxDist then
			continue
		end

		if not ProximityPromptEffects.isPromptFacingCamera(pp) then
			continue
		end

		table.insert(candidates, { prompt = pp, dist = dist })
	end

	local closest: Candidate? = nil
	for _, c in candidates do
		if not closest or c.dist < closest.dist then
			closest = c
		end
	end

	local closestPrompt = if closest then closest.prompt else nil
	for _, pp in allPrompts do
		if pp == closestPrompt then
			continue
		end
		pp.Enabled = false
		ProximityPromptEffects.forceHide(pp)
	end

	if closest then
		closest.prompt.Enabled = true
		ProximityPromptEffects.syncStandProximityUi(closest.prompt)
	else
		ProximityPromptEffects.syncStandProximityUi(nil)
	end

	lastHRPPosition = hrpPos
end

local function bumpPromptRefreshFromMovement()
	lastHRPPosition = nil
	refreshStandProximityPromptVisibility(true)
end

local function unhookCharPlacePromptListeners()
	for _, c in ipairs(charPlacePromptConns) do
		c:Disconnect()
	end
	charPlacePromptConns = {}
end

local function hookCharPlacePromptListeners(char: Model)
	unhookCharPlacePromptListeners()
	local function bump()
		refreshStandProximityPromptVisibility(true)
	end
	table.insert(
		charPlacePromptConns,
		char.ChildAdded:Connect(function(ch)
			if ch:IsA("Tool") then
				bump()
			end
		end)
	)
	table.insert(
		charPlacePromptConns,
		char.ChildRemoved:Connect(function(ch)
			if ch:IsA("Tool") then
				bump()
			end
		end)
	)
	bump()
end

local function wireStandPlacePromptListeners(stand: Model)
	task.spawn(function()
		if not stand.Parent then
			return
		end
		rebuildStandPromptCache(stand)
		if not stand.Parent then
			return
		end

		local prev = standPlacePromptConns[stand]
		if prev then
			for _, c in ipairs(prev) do
				c:Disconnect()
			end
		end
		local conns: { RBXScriptConnection } = {}
		table.insert(
			conns,
			stand:GetAttributeChangedSignal("BrainrotName"):Connect(function()
				refreshStandProximityPromptVisibility(true)
			end)
		)
		table.insert(
			conns,
			stand:GetAttributeChangedSignal("BrainrotStandLocked"):Connect(function()
				refreshStandProximityPromptVisibility(true)
			end)
		)
		table.insert(
			conns,
			stand.DescendantAdded:Connect(function(desc)
				if desc:IsA("ProximityPrompt") then
					invalidateStandPromptCache(stand)
					refreshStandProximityPromptVisibility(true)
				end
			end)
		)
		table.insert(
			conns,
			stand.DescendantRemoving:Connect(function(desc)
				if desc:IsA("ProximityPrompt") then
					task.defer(function()
						if stand.Parent then
							invalidateStandPromptCache(stand)
							refreshStandProximityPromptVisibility(true)
						end
					end)
				end
			end)
		)
		standPlacePromptConns[stand] = conns
	end)
end

local function findSpawnPart(stand: Model): BasePart?
	local spawn = stand:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then
		return spawn :: BasePart
	end
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Spawn" then
			return d :: BasePart
		end
	end
	return nil
end

local function findButtonPart(stand: Model, useWait: boolean?): BasePart?
	local btn: Instance? = if useWait
		then stand:WaitForChild("Button", CHILD_WAIT_TIMEOUT)
		else stand:FindFirstChild("Button")
	if not btn then
		return nil
	end
	local bp: Instance? = if useWait
		then btn:WaitForChild("ButtonPart", CHILD_WAIT_TIMEOUT)
		else btn:FindFirstChild("ButtonPart")
	if bp and bp:IsA("BasePart") then
		return bp :: BasePart
	end
	return nil
end

local function resolveStandVfxRoot(stand: Model): BasePart?
	local spawn = findSpawnPart(stand)
	if spawn then
		return spawn
	end
	local button = findButtonPart(stand)
	if button then
		return button
	end
	if stand.PrimaryPart and stand.PrimaryPart:IsA("BasePart") then
		return stand.PrimaryPart
	end
	return stand:FindFirstChildWhichIsA("BasePart", true)
end

-- Studio: stand.Button.Cash (often where BillboardGui / money visuals live). Fallback: ButtonPart.
local function findCashMoneyAnchor(stand: Model, useWait: boolean?): BasePart?
	local btn: Instance? = if useWait
		then stand:WaitForChild("Button", CHILD_WAIT_TIMEOUT)
		else stand:FindFirstChild("Button")
	if not btn then
		return nil
	end
	local cash: Instance? = if useWait then btn:WaitForChild("Cash", CHILD_WAIT_TIMEOUT) else btn:FindFirstChild("Cash")
	if not cash then
		return nil
	end
	if cash:IsA("BasePart") then
		return cash :: BasePart
	end
	if cash:IsA("Model") then
		local m = cash :: Model
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		return m:FindFirstChildWhichIsA("BasePart", true)
	end
	local att = cash:FindFirstChildWhichIsA("Attachment", true)
	if att and att.Parent and att.Parent:IsA("BasePart") then
		return att.Parent :: BasePart
	end
	return nil
end

-- Waits the path .LevelPanel.Level.SurfaceGui.Frame.Upgrade because the model may not be fully
-- replicated when the BrainrotStand tag first arrives.
local function findUpgradeFrame(stand: Model, useWait: boolean?): Instance?
	local function step(parent: Instance, name: string): Instance?
		if useWait then
			return parent:WaitForChild(name, CHILD_WAIT_TIMEOUT)
		end
		return parent:FindFirstChild(name)
	end
	local panel = step(stand, "LevelPanel")
	if not panel then
		return nil
	end
	local level = step(panel, "Level")
	if not level then
		return nil
	end
	local sg = step(level, "SurfaceGui")
	if not sg then
		return nil
	end
	local frame = step(sg, "Frame")
	if not frame then
		return nil
	end
	return step(frame, "Upgrade")
end

-- SurfaceGui clicks require Active=true on every GuiObject in the chain AND on the SurfaceGui itself.
-- Enabled is controlled by PlotMarkerVisibility — do not force it on here.
local function ensureSurfaceGuiInputChain(leaf: GuiObject)
	local w: Instance? = leaf
	while w do
		if w:IsA("GuiObject") then
			(w :: GuiObject).Active = true
		end
		if w:IsA("SurfaceGui") then
			local sg = w :: SurfaceGui
			(sg :: any).Active = true
			break
		end
		w = w.Parent
	end
end

-- Decorative icons/labels must not steal touches from the upgrade hit target (especially on mobile).
local function passthroughChildClicks(root: GuiObject, capture: GuiButton)
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d ~= capture then
			(d :: GuiObject).Active = false
		end
	end
	capture.Active = true
	capture.Selectable = true
end

local function passthroughUpgradePanelClicks(upgradeFrame: GuiObject, capture: GuiButton)
	local panelFrame = upgradeFrame.Parent
	if panelFrame and panelFrame:IsA("GuiObject") then
		for _, ch in panelFrame:GetChildren() do
			if ch:IsA("GuiObject") and ch ~= upgradeFrame then
				(ch :: GuiObject).Active = false
			end
		end
	end
	passthroughChildClicks(upgradeFrame, capture)
end

local function reapplyUpgradeInputForView(view: StandView)
	local btn = view.upgradeButton
	local frame = view.upgradeFrame
	if not btn or not frame or not btn.Parent or not frame.Parent then
		return
	end
	if not standMatchesAssignedPlotCached(view.stand) then
		return
	end
	ensureSurfaceGuiInputChain(btn)
	passthroughUpgradePanelClicks(frame, btn)
end

local function reapplyUpgradeInputForAllViews()
	for _, view in pairs(views) do
		reapplyUpgradeInputForView(view)
	end
end

local function cancelUpgradeScaleTween(host: Instance)
	local tw = upgradeScaleTweens[host]
	if tw then
		tw:Cancel()
		upgradeScaleTweens[host] = nil
	end
end

local function playUpgradeScaleTween(host: Instance, scale: UIScale, targetScale: number, tweenInfo: TweenInfo)
	cancelUpgradeScaleTween(host)
	local tw = TweenService:Create(scale, tweenInfo, { Scale = targetScale })
	upgradeScaleTweens[host] = tw
	tw:Play()
end

local function bindUpgradeClick(clickable: GuiButton, tryFireUpgrade: () -> ())
	local lastActivatedAt = -1e9
	local function requestUpgrade()
		local now = os.clock()
		if now - lastActivatedAt < UPGRADE_REQUEST_COOLDOWN then
			return
		end
		lastActivatedAt = now
		tryFireUpgrade()
	end
	clickable.Activated:Connect(requestUpgrade)
	-- Mobile SurfaceGui fallback when Activated does not run on some devices.
	if UserInputService.TouchEnabled then
		clickable.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if os.clock() - lastActivatedAt < 0.05 then
				return
			end
			requestUpgrade()
		end)
	end
end

local function localUpgradeLevelGain(): number
	if player:GetAttribute(StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED) == true then
		return BrainrotStandConfig.PLUS_25_LEVEL_GAIN
	end
	return BrainrotStandConfig.NORMAL_LEVEL_GAIN
end

local function showCantAffordNotif()
	if typeof(TopNotifController.showCantAfford) == "function" then
		TopNotifController.showCantAfford()
	end
end

local function promptRobuxStandUpgrade(stand: Model, mode: string, productId: number)
	if prepareRobuxStandUpgradeRE then
		prepareRobuxStandUpgradeRE:FireServer(stand, mode)
	end
	pcall(function()
		PurchasePrompt.promptProduct(productId)
	end)
end

local function affordVisualKey(view: StandView): string
	local upgradeFrame = view.upgradeFrame
	if not upgradeFrame or not upgradeFrame:IsA("GuiObject") then
		return "none"
	end
	if not standMatchesAssignedPlotCached(view.stand) then
		return "none"
	end
	local brainrotName = view.stand:GetAttribute("BrainrotName")
	if typeof(brainrotName) ~= "string" or brainrotName == "" then
		return "empty"
	end
	local level = view.stand:GetAttribute("BrainrotLevel")
	if typeof(level) == "number" and math.floor(level) >= BRAINROT_MAX_LEVEL then
		return "max"
	end
	local cost = view.stand:GetAttribute(STAND_UPGRADE_COST_ATTR)
	if typeof(cost) ~= "number" or cost <= 0 then
		return "default"
	end
	local cash = player:GetAttribute("Cash")
	local balance = if typeof(cash) == "number" then cash else 0
	if balance < cost then
		return "cant_afford"
	end
	return "default"
end

local function wireUpgradeButton(stand: Model): GuiButton?
	if not standMatchesAssignedPlotCached(stand) then
		return nil
	end
	-- Use the waiting variant so we don't fail before the model finishes replicating.
	local upgradeFrame = findUpgradeFrame(stand, true)
	if not upgradeFrame or not upgradeFrame:IsA("GuiObject") then
		warn("[BrainrotStandController] No Upgrade GuiObject under", stand:GetFullName())
		return nil
	end
	ensureSurfaceGuiInputChain(upgradeFrame :: GuiObject)

	-- Designer already made Upgrade an ImageButton/TextButton → use it directly. No overlay needed.
	-- Adding a transparent overlay on TOP of a real button just intercepts and dampens its input.
	local clickable: GuiButton
	local visibleTarget: GuiObject
	if upgradeFrame:IsA("GuiButton") then
		clickable = upgradeFrame :: GuiButton
		visibleTarget = upgradeFrame :: GuiObject
		-- Remove any old overlay we may have added in a previous run.
		local stale = (upgradeFrame :: Instance):FindFirstChild("__UpgradeOverlay")
		if stale then
			stale:Destroy()
		end
	else
		-- Frame/ImageLabel etc. → wrap with a transparent TextButton overlay so we can capture clicks.
		local nestedBtn: GuiButton? = nil
		for _, d in ipairs(upgradeFrame:GetDescendants()) do
			if d:IsA("TextButton") or d:IsA("ImageButton") then
				nestedBtn = d
				break
			end
		end
		if nestedBtn then
			clickable = nestedBtn
			visibleTarget = upgradeFrame :: GuiObject
		else
			local overlayExisting = (upgradeFrame :: Instance):FindFirstChild("__UpgradeOverlay")
			local overlay: TextButton
			if overlayExisting and overlayExisting:IsA("TextButton") then
				overlay = overlayExisting
			else
				if overlayExisting then
					overlayExisting:Destroy()
				end
				local btn = Instance.new("TextButton")
				btn.Name = "__UpgradeOverlay"
				btn.Text = ""
				btn.BackgroundColor3 = Color3.new(0, 0, 0)
				btn.BackgroundTransparency = 0.99
				btn.TextTransparency = 1
				btn.AutoButtonColor = false
				btn.BorderSizePixel = 0
				btn.Size = UDim2.fromScale(1, 1)
				btn.Position = UDim2.fromScale(0, 0)
				btn.ZIndex = 10000
				btn.Active = true
				btn.Selectable = true
				btn.Parent = upgradeFrame :: Instance
				overlay = btn
			end
			clickable = overlay :: GuiButton
			visibleTarget = upgradeFrame :: GuiObject
		end
	end
	clickable.AutoButtonColor = false
	passthroughUpgradePanelClicks(upgradeFrame :: GuiObject, clickable)

	if clickable:GetAttribute("__UpgradeWired") == true then
		ensureSurfaceGuiInputChain(clickable)
		passthroughUpgradePanelClicks(upgradeFrame :: GuiObject, clickable)
		return clickable
	end
	clickable:SetAttribute("__UpgradeWired", true)

	local function getScale(): UIScale
		local s = visibleTarget:FindFirstChildOfClass("UIScale")
		if s then
			return s
		end
		s = Instance.new("UIScale")
		s.Parent = visibleTarget
		return s
	end

	local function pressUpgradeScale()
		playUpgradeScaleTween(
			visibleTarget,
			getScale(),
			0.92,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		)
	end

	local function releaseUpgradeScale()
		playUpgradeScaleTween(
			visibleTarget,
			getScale(),
			1.06,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		)
	end

	clickable.MouseEnter:Connect(function()
		if UserInputService.TouchEnabled then
			return
		end
		playUpgradeScaleTween(
			visibleTarget,
			getScale(),
			1.06,
			TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		)
	end)
	clickable.MouseLeave:Connect(function()
		if UserInputService.TouchEnabled then
			return
		end
		playUpgradeScaleTween(
			visibleTarget,
			getScale(),
			1,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		)
	end)

	clickable.MouseButton1Down:Connect(function()
		if UserInputService.TouchEnabled then
			return
		end
		pressUpgradeScale()
	end)
	clickable.MouseButton1Up:Connect(function()
		if UserInputService.TouchEnabled then
			return
		end
		releaseUpgradeScale()
	end)

	if UserInputService.TouchEnabled then
		local touchActive = false
		clickable.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			touchActive = true
			pressUpgradeScale()
		end)
		clickable.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.Touch or not touchActive then
				return
			end
			touchActive = false
			releaseUpgradeScale()
		end)
	end

	local function tryFireUpgrade()
		local now = os.clock()
		if (lastUpgradeRequestAt[stand] or 0) + UPGRADE_REQUEST_COOLDOWN > now then
			return
		end
		local view = views[stand]
		if localUpgradeLevelGain() >= BrainrotStandConfig.PLUS_25_LEVEL_GAIN then
			lastUpgradeRequestAt[stand] = now
			promptRobuxStandUpgrade(stand, "plus25", BrainrotStandConfig.PLUS_25_DEV_PRODUCT_ID)
			return
		end
		if view and affordVisualKey(view) == "cant_afford" then
			lastUpgradeRequestAt[stand] = now
			promptRobuxStandUpgrade(stand, "cant_afford", BrainrotStandConfig.CANT_AFFORD_DEV_PRODUCT_ID)
			return
		end
		lastUpgradeRequestAt[stand] = now
		if upgradeRE then
			upgradeRE:FireServer(stand)
		end
	end

	bindUpgradeClick(clickable, tryFireUpgrade)
	return clickable
end

local function refreshStandUpgradeAfford(view: StandView)
	local upgradeFrame = view.upgradeFrame
	if not upgradeFrame or not upgradeFrame:IsA("GuiObject") then
		return
	end
	local visualKey = affordVisualKey(view)
	if affordVisualByView[view] == visualKey then
		return
	end
	affordVisualByView[view] = visualKey
	if visualKey == "none" or visualKey == "empty" then
		MainGradientButtons.applyDefault(upgradeFrame)
		return
	end
	if visualKey == "max" then
		MainGradientButtons.applyPurchased(upgradeFrame, "MAX")
		return
	end
	if visualKey == "cant_afford" then
		MainGradientButtons.applyPurchasedGradient(upgradeFrame)
	else
		MainGradientButtons.applyDefault(upgradeFrame)
	end
end

local function refreshPlotStandAffordIfChanged()
	for stand, view in pairs(views) do
		if not standMatchesAssignedPlotCached(stand) then
			continue
		end
		local key = affordVisualKey(view)
		if affordVisualByView[view] ~= key then
			refreshStandUpgradeAfford(view)
		end
	end
end

local function queuePlotStandAffordIfChanged()
	cashAffordToken += 1
	local token = cashAffordToken
	task.delay(AFFORD_REFRESH_DEBOUNCE, function()
		if token ~= cashAffordToken then
			return
		end
		refreshPlotStandAffordIfChanged()
	end)
end

local function pulseUpgradeButton(view: StandView)
	local target = view.upgradeFrame or (view.upgradeButton :: GuiObject?)
	if not target then
		return
	end
	local scale = target:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = target
	end
	scale.Scale = 1.12
	playUpgradeScaleTween(target, scale, 1, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
end

local function pulseOnePart(part: BasePart)
	local originalColor = part.Color
	local originalSize = part.Size
	pcall(function()
		part.Color = Color3.fromRGB(120, 255, 140)
		part.Size = originalSize * 1.06
	end)
	TweenService:Create(part, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = originalColor,
		Size = originalSize,
	}):Play()
end

local function findTotalCashLabel(stand: Model): (TextLabel | TextButton)?
	local bp = findButtonPart(stand)
	if not bp then
		return nil
	end
	local total = bp:FindFirstChild("Total", true)
	if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
		return total
	end
	return nil
end

local function applyCashPadText(view: StandView, amount: number)
	local label = view.totalLabel
	if not label or not label.Parent then
		label = findTotalCashLabel(view.stand)
		view.totalLabel = label
	end
	if not label then
		return
	end
	local text = BrainrotEconomy.formatCashAccumulated(amount)
	if label:IsA("TextLabel") then
		label.AutoLocalize = false
		label.TextTruncate = Enum.TextTruncate.None
		label.Text = text
	elseif label:IsA("TextButton") then
		label.AutoLocalize = false
		label.TextTruncate = Enum.TextTruncate.None
		label.Text = text
	end
end

local function syncCashPadLabel(view: StandView)
	local amount = view.stand:GetAttribute(STAND_ACCUMULATED_ATTR)
	if typeof(amount) ~= "number" then
		return
	end
	view.targetCash = amount
	local displayed = view.displayedCash
	if typeof(displayed) ~= "number" then
		view.displayedCash = amount
		applyCashPadText(view, amount)
		return
	end
	-- Server staggers this attribute, so apply changes as they arrive instead of batching all labels together.
	if math.abs(displayed - amount) >= 0.01 then
		view.displayedCash = amount
		applyCashPadText(view, amount)
	end
end

local function findStandDisplayModel(stand: Model): Model?
	for _, ch in stand:GetChildren() do
		if ch:IsA("Model") and ch:GetAttribute("BrainrotStandDisplay") == true then
			return ch :: Model
		end
	end
	return nil
end

local function hopStandBrainrot(stand: Model)
	local now = os.clock()
	if (lastBrainrotHopAt[stand] or 0) + BRAINROT_HOP_COOLDOWN > now then
		return
	end
	local model = findStandDisplayModel(stand)
	if not model or not model.Parent then
		return
	end
	lastBrainrotHopAt[stand] = now
	local baseCf = model:GetPivot()
	local hopProxy = Instance.new("NumberValue")
	hopProxy.Value = 0
	local hopConn = hopProxy:GetPropertyChangedSignal("Value"):Connect(function()
		if not model.Parent then
			return
		end
		local t = hopProxy.Value
		local y = if t < 0.42 then (t / 0.42) * BRAINROT_HOP_HEIGHT else ((1 - t) / 0.58) * BRAINROT_HOP_HEIGHT
		model:PivotTo(baseCf + Vector3.new(0, y, 0))
	end)
	local hopTween = TweenService:Create(
		hopProxy,
		TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = 1 }
	)
	hopTween.Completed:Connect(function()
		hopConn:Disconnect()
		hopProxy:Destroy()
		if model.Parent then
			model:PivotTo(baseCf)
		end
	end)
	hopTween:Play()
end

local function wireCashPadLabel(view: StandView)
	view.totalLabel = findTotalCashLabel(view.stand)
	if view.accumulatedConn then
		view.accumulatedConn:Disconnect()
		view.accumulatedConn = nil
	end
	view.accumulatedConn = view.stand:GetAttributeChangedSignal(STAND_ACCUMULATED_ATTR):Connect(function()
		syncCashPadLabel(view)
	end)
	syncCashPadLabel(view)
end

function pulseCashPad(view: StandView)
	local seen: { [BasePart]: boolean } = {}
	local function add(p: BasePart?)
		if not p or seen[p] then
			return
		end
		seen[p] = true
		pulseOnePart(p)
	end
	add(view.buttonPart)
	add(view.cashAnchor)
end

-- Lazy: re-resolve a part if the cached lookup was nil (children may have arrived after init).
local function resolveButtonPart(view: StandView): BasePart?
	if view.buttonPart and view.buttonPart.Parent then
		return view.buttonPart
	end
	local bp = findButtonPart(view.stand)
	if bp then
		view.buttonPart = bp
	end
	return view.buttonPart
end

local function resolveCashAnchor(view: StandView): BasePart?
	if view.cashAnchor and view.cashAnchor.Parent then
		return view.cashAnchor
	end
	local cash = findCashMoneyAnchor(view.stand)
	if cash then
		view.cashAnchor = cash
	end
	return view.cashAnchor
end

function ensureMoneyVfxOnView(view: StandView)
	-- Use the visible cash pad (ButtonPart, where the player actually walks) so the burst is seen
	-- exactly where they triggered it. Fall back to the Cash anchor if no ButtonPart was found.
	local anchor = resolveButtonPart(view) or resolveCashAnchor(view)
	if not anchor then
		return
	end
	if view.moneyAttachment and view.moneyAttachment.Parent then
		return
	end
	view.moneyAttachment = cloneMoneyAttachmentInto(anchor)
end

-- Walk the cash button / cash anchor and disable every particle emitter we find so the
-- stand isn't constantly spraying money particles. We re-enable them briefly on collect.
local function collectAndDisableExistingEmitters(view: StandView): { ParticleEmitter }
	local result: { ParticleEmitter } = {}
	local roots: { Instance } = {}
	local btn = view.stand:FindFirstChild("Button")
	if btn then
		table.insert(roots, btn)
	end
	if view.cashAnchor then
		table.insert(roots, view.cashAnchor)
	end
	if view.buttonPart then
		table.insert(roots, view.buttonPart)
	end
	local seen: { [Instance]: boolean } = {}
	for _, root in ipairs(roots) do
		if seen[root] then
			continue
		end
		seen[root] = true
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
				table.insert(result, d)
			end
		end
	end
	return result
end

local function hookStandLevelPulse(stand: Model, view: StandView)
	if view.levelPulseConn then
		view.levelPulseConn:Disconnect()
		view.levelPulseConn = nil
	end
	local initialLevel = stand:GetAttribute("BrainrotLevel")
	view.lastKnownLevel = if typeof(initialLevel) == "number" then math.floor(initialLevel) else 0

	view.levelPulseConn = stand:GetAttributeChangedSignal("BrainrotLevel"):Connect(function()
		if stand:GetAttribute("BrainrotName") == nil then
			return
		end
		local newLevelRaw = stand:GetAttribute("BrainrotLevel")
		if typeof(newLevelRaw) ~= "number" then
			return
		end
		local newLevel = math.floor(newLevelRaw)
		local prevLevel = view.lastKnownLevel or 0
		view.lastKnownLevel = newLevel
		if newLevel <= prevLevel then
			return
		end
		local displayModel = findStandDisplayModel(stand)
		if displayModel and displayModel.Parent then
			BrainrotCarryVisual.applyScaleForLevel(displayModel, newLevel)
		end
		local vfxRoot = resolveStandVfxRoot(stand)
		if vfxRoot then
			local levelStyleSource = BrainrotHeaderStyle.getHeaderInfoChild("Level")
			upgradeFloatSeq += 1
			playRisingFloatText(vfxRoot.Position, {
				level = newLevel,
				textSize = 28,
				styleSource = levelStyleSource,
				strokeScale = FLOAT_STROKE_SCALE,
				stackOffsetIndex = upgradeFloatSeq,
			})
		end
		pulseUpgradeButton(view)
		affordVisualByView[view] = nil
		refreshStandUpgradeAfford(view)
		hopStandBrainrot(stand)
	end)
end

local standUpgradeAffordConns: { [Model]: { RBXScriptConnection } } = {}

local function hookStandUpgradeAfford(stand: Model, view: StandView)
	local existing = standUpgradeAffordConns[stand]
	if existing then
		for _, conn in existing do
			conn:Disconnect()
		end
	end
	local conns: { RBXScriptConnection } = {}
	table.insert(
		conns,
		stand:GetAttributeChangedSignal(STAND_UPGRADE_COST_ATTR):Connect(function()
			affordVisualByView[view] = nil
			refreshStandUpgradeAfford(view)
		end)
	)
	table.insert(
		conns,
		stand:GetAttributeChangedSignal("BrainrotName"):Connect(function()
			affordVisualByView[view] = nil
			refreshStandUpgradeAfford(view)
		end)
	)
	standUpgradeAffordConns[stand] = conns
	refreshStandUpgradeAfford(view)
end

local function initStand(stand: Model)
	if views[stand] then
		return
	end
	wireStandPlacePromptListeners(stand)
	local view: StandView = {
		stand = stand,
		buttonPart = nil,
		cashAnchor = nil,
		totalLabel = nil,
		accumulatedConn = nil,
		upgradeButton = nil,
		upgradeFrame = nil,
		moneyAttachment = nil,
		existingEmitters = {},
		levelPulseConn = nil,
	}
	views[stand] = view

	-- Run the actual hookup in a spawned task so we can WaitForChild without blocking the main
	-- script (children may not have replicated when the BrainrotStand tag first arrives).
	task.spawn(function()
		local bp = findButtonPart(stand, true)
		local cash = findCashMoneyAnchor(stand, true)
		view.buttonPart = bp
		view.cashAnchor = cash
		if standMatchesAssignedPlotCached(stand) then
			wireCashPadLabel(view)
		end

		if standMatchesAssignedPlotCached(stand) then
			local upgradeFrame = findUpgradeFrame(stand, true)
			if upgradeFrame and upgradeFrame:IsA("GuiObject") then
				view.upgradeFrame = upgradeFrame :: GuiObject
			end
			view.upgradeButton = wireUpgradeButton(stand)
			hookStandLevelPulse(stand, view)
			hookStandUpgradeAfford(stand, view)
		end
		view.existingEmitters = collectAndDisableExistingEmitters(view)
	end)
end

local function refreshLocalStandUpgradeWiring()
	for stand, view in pairs(views) do
		if not stand.Parent then
			continue
		end
		if not standMatchesAssignedPlotCached(stand) or view.upgradeButton then
			continue
		end
		task.spawn(function()
			if view.upgradeButton then
				return
			end
			-- Plot was assigned after initStand ran: cash pad label was skipped there, wire it now.
			if not view.accumulatedConn then
				wireCashPadLabel(view)
			end
			local upgradeFrame = findUpgradeFrame(stand, true)
			if upgradeFrame and upgradeFrame:IsA("GuiObject") then
				view.upgradeFrame = upgradeFrame :: GuiObject
			end
			view.upgradeButton = wireUpgradeButton(stand)
			hookStandLevelPulse(stand, view)
			hookStandUpgradeAfford(stand, view)
		end)
	end
end

local pendingStandRegisters: { Model } = {}
local pendingDistantStandInits: { Model } = {}
local standRegisterFlushScheduled = false

local function standNearPlayer(stand: Model): boolean
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return true
	end
	local ok, pivot = pcall(function()
		return stand:GetPivot()
	end)
	if not ok or typeof(pivot) ~= "CFrame" then
		return true
	end
	return ((pivot :: CFrame).Position - (hrp :: BasePart).Position).Magnitude <= STAND_LAZY_INIT_RANGE
end

local function queueDistantStandInit(stand: Model)
	for _, existing in ipairs(pendingDistantStandInits) do
		if existing == stand then
			return
		end
	end
	table.insert(pendingDistantStandInits, stand)
end

local function flushNearbyPendingStandInits()
	if #pendingDistantStandInits == 0 then
		return
	end
	local remaining: { Model } = {}
	for _, stand in ipairs(pendingDistantStandInits) do
		if not stand.Parent then
			continue
		end
		if views[stand] then
			continue
		end
		if standNearPlayer(stand) then
			initStand(stand)
		else
			table.insert(remaining, stand)
		end
	end
	pendingDistantStandInits = remaining
end

local function flushPendingStandRegisters()
	standRegisterFlushScheduled = false
	local batch = pendingStandRegisters
	pendingStandRegisters = {}
	if #batch == 0 then
		return
	end
	task.spawn(function()
		for i, stand in ipairs(batch) do
			if stand.Parent then
				registerTaggedStand(stand)
				if standNearPlayer(stand) then
					initStand(stand)
				else
					queueDistantStandInit(stand)
				end
			end
			if i % 2 == 0 then
				task.wait()
			end
		end
		task.defer(bumpPromptRefreshFromMovement)
	end)
end

local function queueTaggedStandRegister(stand: Model)
	table.insert(pendingStandRegisters, stand)
	if standRegisterFlushScheduled then
		return
	end
	standRegisterFlushScheduled = true
	task.defer(flushPendingStandRegisters)
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function M.init()
	local main = PlayerGuiMain.ensure(player)
	MainGradientButtons.init(main)

	remotes = waitStandRemotes()
	if not remotes then
		return
	end
	upgradeRE = (remotes :: Folder):WaitForChild("UpgradeStandBrainrot", 45) :: RemoteEvent
	prepareRobuxStandUpgradeRE = (remotes :: Folder):WaitForChild("PrepareRobuxStandUpgrade", 45) :: RemoteEvent
	upgradeFeedbackRE = (remotes :: Folder):WaitForChild("StandUpgradeFeedback", 45) :: RemoteEvent
	collectFXRE = (remotes :: Folder):WaitForChild("StandCashCollectedFX", 45) :: RemoteEvent
	if not upgradeRE or not upgradeFeedbackRE or not collectFXRE then
		warn("[BrainrotStandController] stand remotes missing after wait; init aborted")
		return
	end

	upgradeFeedbackRE.OnClientEvent:Connect(function(ok: boolean, reason: string)
		if ok then
			GameSoundEffects.playUpgrade()
			return
		end
		if reason ~= "cash" then
			return
		end
		showCantAffordNotif()
	end)

	collectFXRE.OnClientEvent:Connect(function(stand: any, total: any)
		GameSoundEffects.playCashGrab()
		if typeof(stand) ~= "Instance" or not (stand :: Instance):IsA("Model") then
			return
		end
		local standModel = stand :: Model
		local amount = if typeof(total) == "number" then total else 0
		local view = views[standModel]
		if not view then
			task.defer(function()
				if not views[standModel] then
					initStand(standModel)
				end
				local deferredView = views[standModel]
				if deferredView then
					playCashCollectPresentation(deferredView, amount)
				end
			end)
			return
		end
		playCashCollectPresentation(view, amount)
	end)

	rebuildCachedTaggedStands()
	task.spawn(function()
		for i, m in ipairs(cachedTaggedStands) do
			if standNearPlayer(m) then
				initStand(m)
			else
				queueDistantStandInit(m)
			end
			if i % 3 == 0 then
				task.wait()
			end
		end
	end)
	CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(function(inst)
		if inst:IsA("Model") then
			queueTaggedStandRegister(inst :: Model)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(STAND_TAG):Connect(function(inst)
		if inst:IsA("Model") then
			local standModel = inst :: Model
			unregisterTaggedStand(standModel)
			local affordConns = standUpgradeAffordConns[standModel]
			if affordConns then
				for _, conn in affordConns do
					conn:Disconnect()
				end
				standUpgradeAffordConns[standModel] = nil
			end
			local view = views[standModel]
			if view and view.accumulatedConn then
				view.accumulatedConn:Disconnect()
			end
			if view and view.levelPulseConn then
				view.levelPulseConn:Disconnect()
			end
			local promptConns = standPlacePromptConns[standModel]
			if promptConns then
				for _, conn in promptConns do
					conn:Disconnect()
				end
				standPlacePromptConns[standModel] = nil
			end
			standPromptCache[standModel] = nil
			views[standModel] = nil
			lastBrainrotHopAt[standModel] = nil
			lastUpgradeRequestAt[standModel] = nil
			if view then
				lastCashCollectVfxAt[view] = nil
			end
			task.defer(bumpPromptRefreshFromMovement)
		end
	end)

	player.CharacterAdded:Connect(function(char)
		lastHRPPosition = nil
		hookCharPlacePromptListeners(char)
	end)
	if player.Character then
		hookCharPlacePromptListeners(player.Character)
	end

	player:GetAttributeChangedSignal("AssignedPlotSlot"):Connect(function()
		rebuildCachedPlotMatch()
		refreshLocalStandUpgradeWiring()
		task.defer(reapplyUpgradeInputForAllViews)
		task.defer(queuePlotStandAffordIfChanged)
		bumpPromptRefreshFromMovement()
	end)
	player:GetAttributeChangedSignal("Cash"):Connect(queuePlotStandAffordIfChanged)
	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(bumpPromptRefreshFromMovement)
	player:GetAttributeChangedSignal("Carry"):Connect(bumpPromptRefreshFromMovement)

	if standHeartbeatConn then
		standHeartbeatConn:Disconnect()
		standHeartbeatConn = nil
	end
	standHeartbeatConn = RunService.Heartbeat:Connect(function(dt)
		promptRefreshAccum += dt
		if promptRefreshAccum < PROMPT_REFRESH_INTERVAL then
			return
		end
		promptRefreshAccum = 0
		flushNearbyPendingStandInits()
		refreshStandProximityPromptVisibility()
	end)

	bumpPromptRefreshFromMovement()
	PlotMarkerVisibility.onAfterInteractiveApply(reapplyUpgradeInputForAllViews)
end

return M
