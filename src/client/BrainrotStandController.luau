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

local CarryGate = require(script.Parent.CarryGate)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlotMarkerVisibility = require(script.Parent.PlotMarkerVisibility)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))

local STAND_TAG = "BrainrotStand"
local STAND_ACCUMULATED_ATTR = "StandAccumulatedCash"
-- Server sets this on the stand's ProximityPrompt while the stand is empty; client gates Enabled.
local PLACE_PROMPT_ATTR = "BrainrotPlacePrompt"
local DEFAULT_PLACE_DISTANCE = 10
local DEFAULT_PICKUP_DISTANCE = 14
local PROMPT_REFRESH_INTERVAL = 0.3
local PROMPT_MOVE_SKIP_THRESHOLD = 2
local lastShownStandPrompt: ProximityPrompt? = nil

local player = Players.LocalPlayer
local MONEY_VFX_HOLD_SEC = 0.14
local UPGRADE_CLICK_INTERVAL = 0.05 -- match server UPGRADE_DEBOUNCE; hold repeats at this rate
local CHILD_WAIT_TIMEOUT = 8 -- seconds; stand children may not have replicated when the tag arrives
local CASH_PAD_TICK_INTERVAL = 1
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
local upgradeFeedbackRE: RemoteEvent? = nil
local collectFXRE: RemoteEvent? = nil

-- ── VFX setup ────────────────────────────────────────────────────────────────

local function findMoneyVFXTemplate(): Instance?
	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	if not vfxFolder then return nil end
	local plot = vfxFolder:FindFirstChild("PlotVFX")
	if not plot then return nil end
	local money = plot:FindFirstChild("Money")
	if money then return money end
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
	newAtt.Position = Vector3.new(0, parentPart.Size.Y * 0.6, 0)
	for _, e in ipairs(newAtt:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
		end
	end
	return newAtt
end

local function setEmittersEnabled(attachment: Attachment?, enabled: boolean)
	if not attachment then return end
	for _, e in ipairs(attachment:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			e.Enabled = enabled
		end
	end
end

local function emitBurst(attachment: Attachment?, total: number): boolean
	if not attachment then
		return false
	end
	local found = false
	for _, e in ipairs(attachment:GetDescendants()) do
		if e:IsA("ParticleEmitter") then
			found = true
			pcall(function()
				e:Emit(math.clamp(math.floor(total / 500 + 12), 10, 64))
			end)
		end
	end
	return found
end

-- Big, colourful one-shot emitter so the burst is obvious even when the project's Money template is missing.
local function ensureFallbackBurstEmitter(att: Attachment): ParticleEmitter
	local existing = att:FindFirstChild("_CashPickupBurst")
	if existing and existing:IsA("ParticleEmitter") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "_CashPickupBurst"
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.5, 0.95)
	pe.Speed = NumberRange.new(8, 18)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-180, 180)
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 255, 130)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 230, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	pe.LightEmission = 0.8
	pe.LightInfluence = 0
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Acceleration = Vector3.new(0, -10, 0)
	pe.Parent = att
	return pe
end

-- Short-lived pickup burst: enable emitters briefly, fire one-shot particles, then turn off.
local function playMoneyPickupVFX(attachment: Attachment?, total: number)
	if not attachment then return end
	setEmittersEnabled(attachment, true)
	emitBurst(attachment, if typeof(total) == "number" then total else 0)
	-- Always fire the visible fallback burst so collection has guaranteed feedback even when
	-- the project's Money template is missing or only has Rate-based emitters.
	ensureFallbackBurstEmitter(attachment):Emit(60)
	task.delay(MONEY_VFX_HOLD_SEC, function()
		if attachment.Parent then
			setEmittersEnabled(attachment, false)
		end
	end)
end

local function pulseExistingEmitters(emitters: { ParticleEmitter })
	if #emitters == 0 then return end
	for _, e in ipairs(emitters) do
		if e.Parent then
			e.Enabled = true
			pcall(function()
				e:Emit(20)
			end)
		end
	end
	task.delay(MONEY_VFX_HOLD_SEC, function()
		for _, e in ipairs(emitters) do
			if e.Parent then
				e.Enabled = false
			end
		end
	end)
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
}

local views: { [Model]: StandView } = {}
local lastBrainrotHopAt: { [Model]: number } = {}
local cashPadTickAccum = 0

-- ── Empty-stand place prompt: only when holding a brainrot Tool (local Enabled) ─

local standPlacePromptConns: { [Model]: { RBXScriptConnection } } = {}
local charPlacePromptConns: { RBXScriptConnection } = {}
local promptRefreshAccum = 0
local lastHRPPosition: Vector3? = nil
local cachedTaggedStands: { Model } = {}
local cachedPlotMatch: { [Model]: boolean } = {}

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
	local decor = stand:FindFirstChild("Decor")
	if decor then
		for _, d in ipairs(decor:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				return d
			end
		end
	end
	local spawn = stand:FindFirstChild("Spawn", true)
	if spawn and spawn:IsA("BasePart") then
		local onSpawn = (spawn :: BasePart):FindFirstChildWhichIsA("ProximityPrompt")
		if onSpawn then
			return onSpawn
		end
	end
	return stand:FindFirstChildWhichIsA("ProximityPrompt", true)
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
	return PlotPaths.findSpawnAndBasesFolder()
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

local function rebuildCachedTaggedStands()
	table.clear(cachedTaggedStands)
	for _, inst in CollectionService:GetTagged(STAND_TAG) do
		if inst:IsA("Model") then
			table.insert(cachedTaggedStands, inst :: Model)
		end
	end
	rebuildCachedPlotMatch()
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
		local pp = getStandProximityPrompt(stand)
		if not pp then
			continue
		end
		table.insert(allPrompts, pp)

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
		if closest.prompt ~= lastShownStandPrompt then
			ProximityPromptEffects.syncStandPlaceProximityUi(closest.prompt)
			lastShownStandPrompt = closest.prompt
		end
	else
		ProximityPromptEffects.syncStandProximityUi(nil)
		lastShownStandPrompt = nil
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
	table.insert(charPlacePromptConns, char.ChildAdded:Connect(function(ch)
		if ch:IsA("Tool") then
			bump()
		end
	end))
	table.insert(charPlacePromptConns, char.ChildRemoved:Connect(function(ch)
		if ch:IsA("Tool") then
			bump()
		end
	end))
	bump()
end

local function wireStandPlacePromptListeners(stand: Model)
	local prev = standPlacePromptConns[stand]
	if prev then
		for _, c in ipairs(prev) do
			c:Disconnect()
		end
	end
	local conns: { RBXScriptConnection } = {}
	table.insert(conns, stand:GetAttributeChangedSignal("BrainrotName"):Connect(function()
		refreshStandProximityPromptVisibility(true)
	end))
	table.insert(conns, stand:GetAttributeChangedSignal("BrainrotStandLocked"):Connect(function()
		refreshStandProximityPromptVisibility(true)
	end))
	standPlacePromptConns[stand] = conns
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
	local btn: Instance? = if useWait then stand:WaitForChild("Button", CHILD_WAIT_TIMEOUT) else stand:FindFirstChild("Button")
	if not btn then return nil end
	local bp: Instance? = if useWait then btn:WaitForChild("ButtonPart", CHILD_WAIT_TIMEOUT) else btn:FindFirstChild("ButtonPart")
	if bp and bp:IsA("BasePart") then
		return bp :: BasePart
	end
	return nil
end

-- Studio: stand.Button.Cash (often where BillboardGui / money visuals live). Fallback: ButtonPart.
local function findCashMoneyAnchor(stand: Model, useWait: boolean?): BasePart?
	local btn: Instance? = if useWait then stand:WaitForChild("Button", CHILD_WAIT_TIMEOUT) else stand:FindFirstChild("Button")
	if not btn then return nil end
	local cash: Instance? = if useWait then btn:WaitForChild("Cash", CHILD_WAIT_TIMEOUT) else btn:FindFirstChild("Cash")
	if not cash then return nil end
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
	local panel = step(stand, "LevelPanel"); if not panel then return nil end
	local level = step(panel, "Level"); if not level then return nil end
	local sg = step(level, "SurfaceGui"); if not sg then return nil end
	local frame = step(sg, "Frame"); if not frame then return nil end
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
	if not standMatchesAssignedPlot(view.stand) then
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

local function isTouchPointerInput(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.Touch or last == Enum.UserInputType.TouchTap
end

local function bindUpgradeClick(clickable: GuiButton, tryFireUpgrade: () -> ())
	clickable.Activated:Connect(tryFireUpgrade)
	clickable.MouseButton1Click:Connect(tryFireUpgrade)
	-- SurfaceGui on mobile often skips Activated when MouseButton1Down handlers run; Touch end is reliable.
	clickable.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			tryFireUpgrade()
		end
	end)
end

local function wireUpgradeButton(stand: Model): GuiButton?
	if not standMatchesAssignedPlot(stand) then
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
		if stale then stale:Destroy() end
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
				if overlayExisting then overlayExisting:Destroy() end
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
		if s then return s end
		s = Instance.new("UIScale")
		s.Parent = visibleTarget
		return s
	end

	clickable.MouseEnter:Connect(function()
		if isTouchPointerInput() then
			return
		end
		local sc = getScale()
		TweenService:Create(sc, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.06 }):Play()
	end)
	clickable.MouseLeave:Connect(function()
		if isTouchPointerInput() then
			return
		end
		local sc = getScale()
		TweenService:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)

	local function pressUpgradeScale()
		local sc = getScale()
		TweenService:Create(sc, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.92 }):Play()
	end

	local function releaseUpgradeScale()
		local sc = getScale()
		TweenService:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.06 }):Play()
	end

	-- PC mouse press animation only; touch MouseButton1Down blocks Activated on many devices.
	clickable.MouseButton1Down:Connect(function()
		if isTouchPointerInput() then
			return
		end
		pressUpgradeScale()
	end)
	clickable.MouseButton1Up:Connect(function()
		if isTouchPointerInput() then
			return
		end
		releaseUpgradeScale()
	end)

	if UserInputService.TouchEnabled then
		clickable.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				pressUpgradeScale()
			end
		end)
		clickable.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				releaseUpgradeScale()
			end
		end)
	end

	local lastFire = 0

	local function tryFireUpgrade()
		local now = os.clock()
		if now - lastFire < UPGRADE_CLICK_INTERVAL then
			return
		end
		lastFire = now
		if upgradeRE then
			upgradeRE:FireServer(stand)
		end
	end

	bindUpgradeClick(clickable, tryFireUpgrade)
	return clickable
end

local function pulseUpgradeButton(view: StandView)
	local target = view.upgradeFrame or (view.upgradeButton :: GuiObject?)
	if not target then return end
	local scale = target:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = target
	end
	scale.Scale = 1.12
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
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
		label.Text = text
	elseif label:IsA("TextButton") then
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
	-- Collection resets accumulated cash — snap immediately instead of waiting for the 1s tick.
	if amount + 0.01 < displayed then
		view.displayedCash = amount
		applyCashPadText(view, amount)
	end
end

local function tickCashPadLabels()
	for _, view in views do
		local target = view.targetCash
		if typeof(target) ~= "number" then
			continue
		end
		local displayed = view.displayedCash
		if typeof(displayed) ~= "number" then
			view.displayedCash = target
			applyCashPadText(view, target)
			continue
		end
		if math.abs(displayed - target) < 0.01 then
			continue
		end
		view.displayedCash = target
		applyCashPadText(view, target)
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
	local startT = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not model.Parent then
			if conn then conn:Disconnect() end
			return
		end
		local elapsed = os.clock() - startT
		if elapsed >= 0.26 then
			model:PivotTo(baseCf)
			if conn then conn:Disconnect() end
			return
		end
		local y = if elapsed < 0.11
			then (elapsed / 0.11) * BRAINROT_HOP_HEIGHT
			else ((0.26 - elapsed) / 0.15) * BRAINROT_HOP_HEIGHT
		model:PivotTo(baseCf + Vector3.new(0, y, 0))
	end)
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

local function pulseCashPad(view: StandView)
	local seen: { [BasePart]: boolean } = {}
	local function add(p: BasePart?)
		if not p or seen[p] then return end
		seen[p] = true
		pulseOnePart(p)
	end
	add(view.buttonPart)
	add(view.cashAnchor)
end

-- Lazy: re-resolve a part if the cached lookup was nil (children may have arrived after init).
local function resolveButtonPart(view: StandView): BasePart?
	if view.buttonPart and view.buttonPart.Parent then return view.buttonPart end
	local bp = findButtonPart(view.stand)
	if bp then view.buttonPart = bp end
	return view.buttonPart
end

local function resolveCashAnchor(view: StandView): BasePart?
	if view.cashAnchor and view.cashAnchor.Parent then return view.cashAnchor end
	local cash = findCashMoneyAnchor(view.stand)
	if cash then view.cashAnchor = cash end
	return view.cashAnchor
end

local function ensureMoneyVfxOnView(view: StandView)
	-- Use the visible cash pad (ButtonPart, where the player actually walks) so the burst is seen
	-- exactly where they triggered it. Fall back to the Cash anchor if no ButtonPart was found.
	local anchor = resolveButtonPart(view) or resolveCashAnchor(view)
	if not anchor then return end
	if view.moneyAttachment and view.moneyAttachment.Parent then return end
	view.moneyAttachment = cloneMoneyAttachmentInto(anchor)
end


-- Walk the cash button / cash anchor and disable every particle emitter we find so the
-- stand isn't constantly spraying money particles. We re-enable them briefly on collect.
local function collectAndDisableExistingEmitters(view: StandView): { ParticleEmitter }
	local result: { ParticleEmitter } = {}
	local roots: { Instance } = {}
	local btn = view.stand:FindFirstChild("Button")
	if btn then table.insert(roots, btn) end
	if view.cashAnchor then table.insert(roots, view.cashAnchor) end
	if view.buttonPart then table.insert(roots, view.buttonPart) end
	local seen: { [Instance]: boolean } = {}
	for _, root in ipairs(roots) do
		if seen[root] then continue end
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
	view.levelPulseConn = stand:GetAttributeChangedSignal("BrainrotLevel"):Connect(function()
		if stand:GetAttribute("BrainrotName") == nil then
			return
		end
		pulseUpgradeButton(view)
		hopStandBrainrot(stand)
	end)
end

local function initStand(stand: Model)
	if views[stand] then return end
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
		wireCashPadLabel(view)

		if standMatchesAssignedPlot(stand) then
			local upgradeFrame = findUpgradeFrame(stand, true)
			if upgradeFrame and upgradeFrame:IsA("GuiObject") then
				view.upgradeFrame = upgradeFrame :: GuiObject
			end
			view.upgradeButton = wireUpgradeButton(stand)
			hookStandLevelPulse(stand, view)
		end
		view.existingEmitters = collectAndDisableExistingEmitters(view)
	end)
end

local function refreshLocalStandUpgradeWiring()
	for stand, view in pairs(views) do
		if not stand.Parent then
			continue
		end
		if not standMatchesAssignedPlot(stand) or view.upgradeButton then
			continue
		end
		task.spawn(function()
			if view.upgradeButton then
				return
			end
			local upgradeFrame = findUpgradeFrame(stand, true)
			if upgradeFrame and upgradeFrame:IsA("GuiObject") then
				view.upgradeFrame = upgradeFrame :: GuiObject
			end
			view.upgradeButton = wireUpgradeButton(stand)
			hookStandLevelPulse(stand, view)
		end)
	end
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function M.init()
	remotes = waitStandRemotes()
	if not remotes then return end
	upgradeRE = (remotes :: Folder):WaitForChild("UpgradeStandBrainrot", 45) :: RemoteEvent
	upgradeFeedbackRE = (remotes :: Folder):WaitForChild("StandUpgradeFeedback", 45) :: RemoteEvent
	collectFXRE = (remotes :: Folder):WaitForChild("StandCashCollectedFX", 45) :: RemoteEvent

	upgradeFeedbackRE.OnClientEvent:Connect(function(ok: boolean, reason: string)
		if ok or reason ~= "cash" then
			return
		end
		GameSoundEffects.playErrorNotif()
	end)

	collectFXRE.OnClientEvent:Connect(function(stand: any, total: any)
		GameSoundEffects.playCashGrab()
		if typeof(stand) ~= "Instance" or not (stand :: Instance):IsA("Model") then
			return
		end
		local standModel = stand :: Model
		if not views[standModel] then
			initStand(standModel)
		end
		local view = views[standModel]
		if not view then
			warn("[BrainrotStandController] No view for", standModel:GetFullName())
			return
		end
		pulseCashPad(view)
		pulseUpgradeButton(view)
		pulseExistingEmitters(view.existingEmitters)
		ensureMoneyVfxOnView(view)
		if not view.moneyAttachment then
			warn("[BrainrotStandController] Could not create money attachment for", standModel:GetFullName())
			return
		end
		playMoneyPickupVFX(view.moneyAttachment, if typeof(total) == "number" then total else 0)
	end)

	rebuildCachedTaggedStands()
	for _, m in ipairs(cachedTaggedStands) do
		initStand(m)
	end
	CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(function(inst)
		if inst:IsA("Model") then
			initStand(inst :: Model)
			rebuildCachedTaggedStands()
			task.defer(bumpPromptRefreshFromMovement)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(STAND_TAG):Connect(function(inst)
		if inst:IsA("Model") then
			local view = views[inst :: Model]
			if view and view.accumulatedConn then
				view.accumulatedConn:Disconnect()
			end
			views[inst :: Model] = nil
			rebuildCachedTaggedStands()
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
		bumpPromptRefreshFromMovement()
	end)
	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(bumpPromptRefreshFromMovement)
	player:GetAttributeChangedSignal("Carry"):Connect(bumpPromptRefreshFromMovement)

	RunService.Heartbeat:Connect(function(dt)
		cashPadTickAccum += dt
		if cashPadTickAccum >= CASH_PAD_TICK_INTERVAL then
			cashPadTickAccum = 0
			tickCashPadLabels()
		end

		promptRefreshAccum += dt
		if promptRefreshAccum < PROMPT_REFRESH_INTERVAL then
			return
		end
		promptRefreshAccum = 0
		refreshStandProximityPromptVisibility()
	end)

	bumpPromptRefreshFromMovement()
	PlotMarkerVisibility.onAfterInteractiveApply(reapplyUpgradeInputForAllViews)
end

return M
