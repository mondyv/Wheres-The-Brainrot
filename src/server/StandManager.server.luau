--[[
	StandManager (server)
	Manages every brainrot stand under workspace.Map["Spawn And Bases"].<Base>["<Story>"].stands.<Stand N>.

	Stand layout (Studio):
	  stand
	    ├── Spawn                 (BasePart; brainrot model is placed here)
	    ├── Cube.005.Attachment.ProximityPrompt   (E to place / pick up)
	    ├── Button (folder/model)
	    │     ├── ButtonPart      (BasePart; touch with body → collect cash)
	    │     │     └── SurfaceGui.Frame.Total  (TextLabel — accumulated cash)
	    │     └── Cash.BillboardGui.Offline.Purple  (offline cash label — hidden for now)
	    └── LevelPanel.Level.SurfaceGui.Frame.Upgrade
	          └── Info.Cost      (TextLabel — upgrade cost)

	Behaviour:
	• Player with an equipped brainrot Tool triggers the prompt → brainrot is placed on Spawn,
	  Tool/inventory entry consumed, stand now owned by the placer.
	• Owner standing on prompt again removes the brainrot (returned to inventory).
	• Stand generates cash at the level/mutation income rate; cap at OFFLINE_CAP if no one collects.
	• Touch ButtonPart → owner collects accumulated cash; coin VFX bursts.
	• Owner clicks the Upgrade SurfaceGui → level +1 (if affordable, < MAX_LEVEL).
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))
local BrainrotHeader = require(Modules:WaitForChild("BrainrotHeader"))
local BrainrotAnimations = require(Modules:WaitForChild("BrainrotAnimations"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotStandPlaceholders = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotStandPlaceholders"))

local STAND_TAG = "BrainrotStand"
-- Accumulated cash is capped at OFFLINE_CAP_SECONDS * income; tunes how long a player can leave it.
local OFFLINE_CAP_SECONDS = 60 * 60 * 4 -- 4 hours of income, then it stops growing
local COLLECT_TOUCH_DEBOUNCE = 0.5 -- seconds between collect claims on the money pad
local UPGRADE_DEBOUNCE = 0.05 -- min seconds between level-ups (spam-friendly; still blocks same-frame double fires)
local INCOME_TICK = 0.5 -- seconds between accumulation updates (label refresh too)
local PROMPT_PLACE_DISTANCE = 10
local PROMPT_PICKUP_DISTANCE = 14
-- When placing on empty stands side-by-side, only the nearest spawn wins (prevents wrong-stand place).
local PROMPT_CLOSEST_MARGIN = 1.25

-- ── Remote folder + events ────────────────────────────────────────────────────

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("StandRemotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local newF = Instance.new("Folder")
	newF.Name = "StandRemotes"
	newF.Parent = ReplicatedStorage
	return newF
end

local function ensureRemoteEvent(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = folder
	return ev
end

local remotesFolder = ensureRemotesFolder()
local placeRE = ensureRemoteEvent(remotesFolder, "PlaceBrainrotOnStand")   -- (standModel)
local removeRE = ensureRemoteEvent(remotesFolder, "RemoveBrainrotFromStand") -- (standModel)
local upgradeRE = ensureRemoteEvent(remotesFolder, "UpgradeStandBrainrot")  -- (standModel)
local upgradeFeedbackRE = ensureRemoteEvent(remotesFolder, "StandUpgradeFeedback") -- server → client (ok, reason)
local collectVFXRE = ensureRemoteEvent(remotesFolder, "StandCashCollectedFX") -- server → client (standModel, cashAmount)

-- ── Internal BindableFunction from BushHarvest (inventory mutation) ───────────

local function getConsumeInventoryFn(): BindableFunction?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		return nil
	end
	local bf = folder:FindFirstChild("ConsumeInventoryEntry")
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function findSpawnBasesFolder(): Instance?
	return PlotPaths.findSpawnAndBasesFolder()
end

-- Plot root = direct child of Spawn And Bases (cloned Plot_1 … or legacy base folder).
local function plotRootForStand(stand: Model): Instance?
	local folder = findSpawnBasesFolder()
	if not folder then
		return nil
	end
	local x: Instance? = stand
	while x do
		if x.Parent == folder then
			return x
		end
		x = x.Parent
	end
	local name = stand:GetAttribute("PlotBaseName")
	if typeof(name) == "string" then
		return folder:FindFirstChild(name)
	end
	return nil
end

-- When bases use PlotSlotId + player AssignedPlotSlot, reject all stand actions off-plot.
local function playerAssignedToStandPlot(player: Player, stand: Model): boolean
	local root = plotRootForStand(stand)
	if not root then
		return true
	end
	local slot = root:GetAttribute("PlotSlotId")
	if typeof(slot) ~= "number" then
		return true
	end
	local assigned = player:GetAttribute("AssignedPlotSlot")
	return typeof(assigned) == "number" and math.floor(assigned :: number) == math.floor(slot :: number)
end

local function formatCashShort(n: number): string
	if n >= 1e15 then
		return string.format("$%.2fQa", n / 1e15)
	elseif n >= 1e12 then
		return string.format("$%.2fT", n / 1e12)
	elseif n >= 1e9 then
		return string.format("$%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("$%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("$%.2fK", n / 1e3)
	end
	return string.format("$%d", math.floor(n + 0.5))
end

local function findDescendantByName(root: Instance, name: string): Instance?
	if root.Name == name then
		return root
	end
	return root:FindFirstChild(name, true)
end

local function findSpawnPart(stand: Model): BasePart?
	local spawn = stand:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then
		return spawn
	end
	-- Fallback: look for any descendant named "Spawn" that's a BasePart.
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Spawn" then
			return d
		end
	end
	return nil
end

local function findProximityPrompt(stand: Model): ProximityPrompt?
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			return d
		end
	end
	return nil
end

local function findButtonPart(stand: Model): BasePart?
	local btn = stand:FindFirstChild("Button")
	if btn then
		local bp = btn:FindFirstChild("ButtonPart")
		if bp and bp:IsA("BasePart") then
			return bp
		end
	end
	return nil
end

local function getPlayerHRP(player: Player): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function configureStandProximityPrompt(prompt: ProximityPrompt, maxDistance: number?)
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.MaxActivationDistance = maxDistance or PROMPT_PLACE_DISTANCE
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	if prompt:GetAttribute("ClickablePromptSet") ~= true then
		pcall(function()
			(prompt :: any).ClickablePrompt = true
		end)
		prompt:SetAttribute("ClickablePromptSet", true)
	end
end

-- Parent prompt on Decor cube / Spawn (where Studio placed it), not the cash pad.
local function findPromptAnchorPart(stand: Model, spawnPart: BasePart): BasePart
	return PlotStandPlaceholders.findPromptAnchorPart(stand, spawnPart)
end

local function ensureStandProximityPrompt(stand: Model, spawnPart: BasePart): ProximityPrompt?
	local anchor = findPromptAnchorPart(stand, spawnPart)
	local prompt = findProximityPrompt(stand)
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "StandProximityPrompt"
	end
	for _, d in ipairs(stand:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d ~= prompt then
			d:Destroy()
		end
	end
	prompt.Parent = anchor
	configureStandProximityPrompt(prompt, PROMPT_PLACE_DISTANCE)
	return prompt
end

local function getStandPromptWorldPosition(state: StandState): Vector3?
	local prompt = state.prompt
	if prompt and prompt.Parent then
		local parent = prompt.Parent
		if parent:IsA("Attachment") then
			return parent.WorldPosition
		end
		if parent:IsA("BasePart") then
			return parent.Position
		end
	end
	if state.spawnPart then
		return state.spawnPart.Position
	end
	return nil
end

local function isPlayerNearStandSpawn(player: Player, state: StandState, maxDistance: number): boolean
	local hrp = getPlayerHRP(player)
	local worldPos = getStandPromptWorldPosition(state)
	if not hrp or not worldPos then
		return false
	end
	return (hrp.Position - worldPos).Magnitude <= maxDistance
end

local function findTotalCashLabel(stand: Model): (TextLabel | TextButton)?
	local btn = stand:FindFirstChild("Button")
	if not btn then return nil end
	local bp = btn:FindFirstChild("ButtonPart")
	if not bp then return nil end
	local sg = bp:FindFirstChild("SurfaceGui")
	if not sg then return nil end
	local frame = sg:FindFirstChild("Frame")
	if not frame then return nil end
	local total = frame:FindFirstChild("Total")
	if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
		return total
	end
	return nil
end

local function findOfflineCashLabel(stand: Model): (TextLabel | TextButton)?
	local btn = stand:FindFirstChild("Button")
	if not btn then return nil end
	local cash = btn:FindFirstChild("Cash")
	if not cash then return nil end
	local bb = cash:FindFirstChild("BillboardGui")
	if not bb then return nil end
	local offline = bb:FindFirstChild("Offline")
	if offline then
		local purple = offline:FindFirstChild("Purple")
		if purple and (purple:IsA("TextLabel") or purple:IsA("TextButton")) then
			return purple
		end
		if offline:IsA("TextLabel") or offline:IsA("TextButton") then
			return offline
		end
	end
	return nil
end

local function findUpgradeFrameAndLabels(stand: Model): (Instance?, (TextLabel | TextButton)?, (TextLabel | TextButton)?)
	local panel = stand:FindFirstChild("LevelPanel")
	if not panel then return nil, nil, nil end
	local level = panel:FindFirstChild("Level")
	if not level then return nil, nil, nil end
	local sg = level:FindFirstChild("SurfaceGui")
	if not sg then return nil, nil, nil end
	local frame = sg:FindFirstChild("Frame")
	if not frame then return nil, nil, nil end
	local upgrade = frame:FindFirstChild("Upgrade")
	if not upgrade then return nil, nil, nil end
	local info = upgrade:FindFirstChild("Info")
	local costLabel: (TextLabel | TextButton)? = nil
	local levelLabel: (TextLabel | TextButton)? = nil
	if info then
		local cost = info:FindFirstChild("Cost")
		if cost and (cost:IsA("TextLabel") or cost:IsA("TextButton")) then
			costLabel = cost
		end
		-- Newer stand layout adds an Info.Level TextLabel showing current → next level.
		local lvl = info:FindFirstChild("Level")
		if lvl and (lvl:IsA("TextLabel") or lvl:IsA("TextButton")) then
			levelLabel = lvl
		end
	end
	return upgrade, costLabel, levelLabel
end

-- ── Stand state ───────────────────────────────────────────────────────────────

type StandState = {
	stand: Model,
	spawnPart: BasePart,
	prompt: ProximityPrompt?,
	buttonPart: BasePart?,
	totalLabel: (TextLabel | TextButton)?,
	offlineLabel: (TextLabel | TextButton)?,
	upgradeFrame: Instance?,
	costLabel: (TextLabel | TextButton)?,
	levelLabel: (TextLabel | TextButton)?,

	ownerUserId: number?,
	brainrotName: string?,
	rarity: string?,
	mutation: string?,
	level: number,
	baseIncome: number,
	sourcePath: string,
	-- Cached so we don't have to re-search inventory; if owner re-enters world, level is still on stand attrs.
	displayModel: Model?,
	idleTrack: AnimationTrack?,
	accumulated: number,
	lastTickAt: number,
	lastCollectAt: number,
	lastUpgradeAt: number,
	touchDebouncePerPlayer: { [Player]: number },
}

local stands: { [Model]: StandState } = {}

local function isPlayerClosestStandPromptTarget(player: Player, state: StandState, maxDistance: number): boolean
	local hrp = getPlayerHRP(player)
	if not hrp or not state.spawnPart then
		return false
	end
	local pos = hrp.Position
	local myPos = getStandPromptWorldPosition(state)
	if not myPos then
		return false
	end
	local myDist = (pos - myPos).Magnitude
	if myDist > maxDistance then
		return false
	end
	for _, other in stands do
		if other ~= state then
			local otherPos = getStandPromptWorldPosition(other)
			if otherPos then
				local otherDist = (pos - otherPos).Magnitude
				if otherDist <= maxDistance and otherDist + PROMPT_CLOSEST_MARGIN < myDist then
					return false
				end
			end
		end
	end
	return true
end

local function isOwner(state: StandState, player: Player): boolean
	return state.ownerUserId ~= nil and state.ownerUserId == player.UserId
end

local function recomputeIncomePerSecond(state: StandState): number
	if not state.brainrotName or not state.rarity then
		return 0
	end
	local def = {
		name = state.brainrotName,
		rarity = state.rarity,
		baseIncome = state.baseIncome,
	}
	return Brainrots.incomePerSecond(def, state.level, state.mutation or "normal")
end

local function recomputeUpgradeCost(state: StandState): number
	if not state.brainrotName or not state.rarity then
		return 0
	end
	local def = {
		name = state.brainrotName,
		rarity = state.rarity,
		baseIncome = state.baseIncome,
	}
	return Brainrots.upgradeCost(def, state.level, state.mutation or "normal")
end

local STAND_BRAINROT_MAX_DIM = 14 -- only shrink templates larger than this (matches carry clamp order-of-magnitude)
-- Extra yaw applied AFTER auto-facing the cash pad. 180 if the brainrot template's "front" is +Z, 0 if it's -Z.
local STAND_YAW_OFFSET = math.rad(0)
local STAND_PITCH_OFFSET = math.rad(0)
local STAND_ROLL_OFFSET = math.rad(0)

-- Pick a reference part in front of the stand so we can auto-face the brainrot toward the player.
local function findFrontReferencePart(state: StandState): BasePart?
	if state.buttonPart then return state.buttonPart end
	local panel = state.stand:FindFirstChild("LevelPanel")
	if panel then
		local level = panel:FindFirstChild("Level")
		if level and level:IsA("BasePart") then return level :: BasePart end
		if level then
			local any = level:FindFirstChildWhichIsA("BasePart", true)
			if any then return any end
		end
	end
	return nil
end

local function refreshHeader(state: StandState)
	if not state.displayModel or not state.displayModel.Parent then
		return
	end
	if not state.brainrotName or not state.rarity then
		return
	end
	local headerOpts = { alwaysOnTop = true }
	local ok = BrainrotHeader.refresh(state.displayModel, {
		name = state.brainrotName,
		rarity = state.rarity,
		mutation = state.mutation or "normal",
		level = state.level,
		incomePerSecond = recomputeIncomePerSecond(state),
	}, headerOpts)
	if not ok then
		warn("[StandManager] BrainrotHeader.refresh failed for stand display:", state.brainrotName)
	end
end

local function setLabelText(label: (TextLabel | TextButton)?, text: string)
	if not label then return end
	if label:IsA("TextLabel") then
		(label :: TextLabel).Text = text
	elseif label:IsA("TextButton") then
		(label :: TextButton).Text = text
	end
end

local function refreshLabels(state: StandState)
	if state.totalLabel then
		setLabelText(state.totalLabel, formatCashShort(state.accumulated))
	end
	if state.offlineLabel then
		-- No persistence yet → hide offline label so it doesn't show stale "$0".
		if state.offlineLabel:IsA("TextLabel") then
			(state.offlineLabel :: TextLabel).Visible = false
		elseif state.offlineLabel:IsA("TextButton") then
			(state.offlineLabel :: TextButton).Visible = false
		end
	end
	if state.costLabel then
		if not state.brainrotName then
			setLabelText(state.costLabel, "—")
		else
			local cost = recomputeUpgradeCost(state)
			if state.level >= Brainrots.MAX_LEVEL then
				setLabelText(state.costLabel, "MAX")
			else
				setLabelText(state.costLabel, formatCashShort(cost))
			end
		end
	end
	if state.levelLabel then
		if not state.brainrotName then
			setLabelText(state.levelLabel, "Empty")
		elseif state.level >= Brainrots.MAX_LEVEL then
			setLabelText(state.levelLabel, string.format("Lvl %d", state.level))
		else
			-- "Lvl 3 → 4" so the panel shows current and next.
			setLabelText(state.levelLabel, string.format("Lvl %d → %d", state.level, state.level + 1))
		end
	end
end

local function isStandLocked(state: StandState): boolean
	return state.stand:GetAttribute("BrainrotStandLocked") == true
end

local function setPromptText(state: StandState)
	local prompt = state.prompt
	if not prompt then
		return
	end
	if isStandLocked(state) then
		-- Floor not yet unlocked: prompt is hidden until BaseFloorUnlock raises the floor level.
		prompt:SetAttribute("BrainrotPlacePrompt", nil)
		prompt.Enabled = false
		return
	end
	if state.brainrotName then
		-- Occupied: everyone who can interact sees Pick Up (client does not gate this).
		prompt:SetAttribute("BrainrotPlacePrompt", nil)
		prompt.ActionText = "Pick Up"
		prompt.ObjectText = string.format("Lvl %d %s", state.level, state.brainrotName)
		prompt.MaxActivationDistance = PROMPT_PICKUP_DISTANCE
	else
		-- Empty stand: server leaves Enabled true; BrainrotStandController hides the prompt
		-- locally until the player has a brainrot Tool equipped (matches placeBrainrotOnStand).
		prompt:SetAttribute("BrainrotPlacePrompt", true)
		prompt.ActionText = "Place Brainrot"
		prompt.ObjectText = "Stand"
		prompt.MaxActivationDistance = PROMPT_PLACE_DISTANCE
	end
	configureStandProximityPrompt(
		prompt,
		if state.brainrotName then PROMPT_PICKUP_DISTANCE else PROMPT_PLACE_DISTANCE
	)
	prompt.Enabled = true
end

-- ── Stand display Idle (asset IDs in Shared.BrainrotAnimations) ─────────────

local function findIdleAnimationForBrainrot(brainrotName: string): Animation?
	return BrainrotAnimations.getIdleAnimation(brainrotName)
end

local function resolveAnimator(model: Model): Animator?
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		return animator
	end
	local controller = model:FindFirstChildOfClass("AnimationController")
	if controller then
		local animator = controller:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = controller
		end
		return animator
	end
	return nil
end

local function stopStandIdleAnimation(state: StandState)
	local track = state.idleTrack
	state.idleTrack = nil
	if track then
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
end

local function playStandIdleAnimation(state: StandState, model: Model, brainrotName: string)
	stopStandIdleAnimation(state)

	local anim = findIdleAnimationForBrainrot(brainrotName)
	if not anim then
		return
	end

	local animator = resolveAnimator(model)
	if not animator then
		return
	end

	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not trackOrErr or not trackOrErr:IsA("AnimationTrack") then
		return
	end

	local track = trackOrErr :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped = true
	track:Play(0.15)
	state.idleTrack = track
end

-- ── Stand placement / removal ────────────────────────────────────────────────

local function clearDisplayModel(state: StandState)
	stopStandIdleAnimation(state)
	if state.displayModel and state.displayModel.Parent then
		state.displayModel:Destroy()
	end
	state.displayModel = nil
end

local function setAllPartsAnchored(model: Model, anchored: boolean, canCollide: boolean)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = anchored
			d.CanCollide = canCollide
		end
	end
end

local function getMainPart(model: Model): BasePart?
	if model.PrimaryPart then return model.PrimaryPart end
	local p = model:FindFirstChildWhichIsA("BasePart", true)
	if p and not model.PrimaryPart then
		model.PrimaryPart = p
	end
	return p
end

local function findBrainrotTemplateForState(state: StandState): Model?
	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots or not brainrots:IsA("Folder") then return nil end
	local nameFolder = brainrots:FindFirstChild(state.brainrotName or "")
	if not nameFolder then return nil end
	local variantName = (Brainrots :: any).MUTATION_TEMPLATE_FOLDER[state.mutation or "normal"]
	if typeof(variantName) == "string" then
		local v = nameFolder:FindFirstChild(variantName)
		if v and v:IsA("Model") then return v :: Model end
	end
	local normal = nameFolder:FindFirstChild("Normal")
	if normal and normal:IsA("Model") then return normal :: Model end
	for _, c in ipairs(nameFolder:GetChildren()) do
		if c:IsA("Model") then return c :: Model end
	end
	return nil
end

-- Place the configured brainrot model on the Spawn part with header billboard.
local function rebuildDisplay(state: StandState)
	clearDisplayModel(state)
	if not state.brainrotName then return end

	local template = findBrainrotTemplateForState(state)
	if not template then
		warn(string.format("[StandManager] No template for %s (%s)", tostring(state.brainrotName), tostring(state.mutation)))
		return
	end

	local clone = template:Clone()
	clone.Name = state.brainrotName :: string
	clone:SetAttribute("BrainrotStandDisplay", true)
	clone:SetAttribute("OwnerUserId", state.ownerUserId)
	clone:SetAttribute("BrainrotName", state.brainrotName)
	clone:SetAttribute("BrainrotRarity", state.rarity)
	clone:SetAttribute("BrainrotMutation", state.mutation)
	clone:SetAttribute("BrainrotLevel", state.level)
	clone:SetAttribute("BrainrotBaseIncome", state.baseIncome)

	-- Parent under the stand (not Spawn) so the display is not trapped inside the hidden placeholder cube.
	clone.Parent = state.stand
	local main = getMainPart(clone)
	if not main then
		warn("[StandManager] rebuildDisplay: clone has no BasePart:", clone.Name)
		clone:Destroy()
		return
	end

	-- Only shrink genuinely huge templates; small spawn pads must not force tiny brainrots.
	local _, bbSize = clone:GetBoundingBox()
	local maxDim = math.max(bbSize.X, bbSize.Y, bbSize.Z)
	if maxDim > STAND_BRAINROT_MAX_DIM and maxDim > 0 then
		local ok, scaleNow = pcall(function()
			return clone:GetScale()
		end)
		if ok then
			local target = (scaleNow or 1) * (STAND_BRAINROT_MAX_DIM / maxDim)
			pcall(function()
				clone:ScaleTo(target)
			end)
		end
	end

	-- Build orientation. Prefer auto-facing toward the cash pad / front of the stand so the brainrot
	-- always looks at the player. Fall back to the Spawn part's own rotation if no reference exists.
	local frontPart = findFrontReferencePart(state)
	local baseRot: CFrame
	if frontPart then
		local lookTarget = Vector3.new(frontPart.Position.X, state.spawnPart.Position.Y, frontPart.Position.Z)
		local from = state.spawnPart.Position
		if (lookTarget - from).Magnitude < 0.05 then
			baseRot = state.spawnPart.CFrame.Rotation
		else
			baseRot = CFrame.lookAt(from, lookTarget).Rotation
		end
	else
		baseRot = state.spawnPart.CFrame.Rotation
	end

	-- Pivot once with a provisional Y, then re-measure the post-rotation bounding box and lift so the
	-- model rests flush on the spawn pad rather than sinking or floating.
	local provisionalCf = CFrame.new(state.spawnPart.Position)
		* baseRot
		* CFrame.Angles(STAND_PITCH_OFFSET, STAND_YAW_OFFSET, STAND_ROLL_OFFSET)
	if clone.PrimaryPart then
		clone:PivotTo(provisionalCf)
	else
		clone:MoveTo(provisionalCf.Position)
	end

	local rotatedCenter, rotatedSize = clone:GetBoundingBox()
	local minY = rotatedCenter.Y - rotatedSize.Y * 0.5
	local desiredMinY = state.spawnPart.Position.Y + state.spawnPart.Size.Y * 0.5 + 0.05
	local yShift = desiredMinY - minY
	local pivotCf = provisionalCf + Vector3.new(0, yShift, 0)
	if clone.PrimaryPart then
		clone:PivotTo(pivotCf)
	else
		clone:MoveTo(pivotCf.Position)
	end

	setAllPartsAnchored(clone, true, false)
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanTouch = false
			d.CanQuery = false
		end
	end

	state.displayModel = clone
	PlotStandPlaceholders.hideSpawnShellOnStand(state.stand)
	refreshHeader(state)
	playStandIdleAnimation(state, clone, state.brainrotName :: string)
end

local function clearStandState(state: StandState)
	clearDisplayModel(state)
	state.ownerUserId = nil
	state.brainrotName = nil
	state.rarity = nil
	state.mutation = nil
	state.level = 1
	state.baseIncome = 0
	state.sourcePath = ""
	state.accumulated = 0
	state.lastTickAt = os.clock()
	state.stand:SetAttribute("StandOwnerUserId", nil)
	state.stand:SetAttribute("BrainrotName", nil)
	state.stand:SetAttribute("BrainrotRarity", nil)
	state.stand:SetAttribute("BrainrotMutation", nil)
	state.stand:SetAttribute("BrainrotLevel", nil)
	state.stand:SetAttribute("BrainrotBaseIncome", nil)
	setPromptText(state)
	refreshLabels(state)
end

local function placeBrainrotOnStand(player: Player, state: StandState)
	if state.brainrotName ~= nil then
		return -- Already occupied.
	end
	if isStandLocked(state) then return end
	if not playerAssignedToStandPlot(player, state.stand) then return end
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("BrainrotTool") ~= true then
		return
	end
	local invIdx = tool:GetAttribute("BrainrotInvIndex")
	if typeof(invIdx) ~= "number" then return end

	-- Distance check to prevent remote exploits.
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp and (hrp.Position - state.spawnPart.Position).Magnitude > 24 then
		return
	end

	-- Capture tool attributes BEFORE consume destroys the tool.
	local toolName = tool.Name
	local toolBrainrotName = tool:GetAttribute("BrainrotName")
	local toolRarity = tool:GetAttribute("BrainrotRarity")
	local toolMutation = tool:GetAttribute("BrainrotMutation")
	local toolLevel = tool:GetAttribute("BrainrotLevel")
	local toolBaseIncome = tool:GetAttribute("BrainrotBaseIncome")
	local toolSourcePath = tool:GetAttribute("BrainrotSourcePath")

	local consumeBF = getConsumeInventoryFn()
	if not consumeBF then
		warn("[StandManager] ConsumeInventoryEntry BindableFunction missing")
		return
	end

	local ok, entry = pcall(function()
		return consumeBF:Invoke(player, invIdx)
	end)
	if not ok or typeof(entry) ~= "table" then
		return
	end

	state.ownerUserId = player.UserId
	state.brainrotName = entry.name or toolBrainrotName or toolName
	state.rarity = entry.rarity or toolRarity or "common"
	state.mutation = entry.mutation or toolMutation or "normal"
	state.level = math.max(1, math.floor(entry.level or toolLevel or 1))
	state.baseIncome = entry.baseIncome or toolBaseIncome or 0
	state.sourcePath = entry.sourcePath or toolSourcePath or ""
	state.accumulated = 0
	state.lastTickAt = os.clock()

	state.stand:SetAttribute("StandOwnerUserId", state.ownerUserId)
	state.stand:SetAttribute("BrainrotName", state.brainrotName)
	state.stand:SetAttribute("BrainrotRarity", state.rarity)
	state.stand:SetAttribute("BrainrotMutation", state.mutation)
	state.stand:SetAttribute("BrainrotLevel", state.level)
	state.stand:SetAttribute("BrainrotBaseIncome", state.baseIncome)

	rebuildDisplay(state)
	setPromptText(state)
	refreshLabels(state)
end

local function getReturnInventoryFn(): BindableFunction?
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then return nil end
	local bf = folder:FindFirstChild("ReturnInventoryEntry")
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

local function removeBrainrotFromStand(player: Player, state: StandState)
	if not state.brainrotName then return end
	if not isOwner(state, player) then return end
	if not playerAssignedToStandPlot(player, state.stand) then return end

	local entryToReturn = {
		name = state.brainrotName,
		icon = "",
		sourcePath = state.sourcePath,
		rarity = state.rarity,
		mutation = state.mutation,
		level = state.level,
		baseIncome = state.baseIncome,
	}
	local returnFn = getReturnInventoryFn()
	if returnFn then
		local okReturn, returned = pcall(function()
			return returnFn:Invoke(player, entryToReturn)
		end)
		if not okReturn or returned ~= true then
			return
		end
	end

	-- Auto-pay any unclaimed cash on pick-up so the owner never loses it.
	if state.accumulated > 0 then
		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		local boost = if player:GetAttribute("IndexGoldenQuestComplete") == true then 1.25 else 1
		local payout = math.floor(state.accumulated * boost)
		player:SetAttribute("Cash", c + payout)
		collectVFXRE:FireClient(player, state.stand, payout)
	end

	clearStandState(state)
end

-- ── Cash accumulation / collection ───────────────────────────────────────────

local function tickStand(state: StandState, dt: number)
	if not state.brainrotName then
		return
	end
	local ips = recomputeIncomePerSecond(state)
	if ips <= 0 then return end
	local cap = ips * OFFLINE_CAP_SECONDS
	state.accumulated = math.min(cap, state.accumulated + ips * dt)
	if state.totalLabel then
		setLabelText(state.totalLabel, formatCashShort(state.accumulated))
	end
end

local function collectCash(state: StandState, player: Player)
	if not isOwner(state, player) then return end
	if not playerAssignedToStandPlot(player, state.stand) then return end
	if state.accumulated <= 0 then return end
	local now = os.clock()
	if state.touchDebouncePerPlayer[player] and (state.touchDebouncePerPlayer[player] + COLLECT_TOUCH_DEBOUNCE > now) then
		return
	end
	state.touchDebouncePerPlayer[player] = now
	local amount = math.floor(state.accumulated)
	if amount <= 0 then return end
	local boost = if player:GetAttribute("IndexGoldenQuestComplete") == true then 1.25 else 1
	amount = math.floor(amount * boost)
	state.accumulated -= amount
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + amount)
	state.lastCollectAt = now
	refreshLabels(state)
	collectVFXRE:FireClient(player, state.stand, amount)
end

local function upgradeStandBrainrot(state: StandState, player: Player)
	if not isOwner(state, player) then return end
	if not playerAssignedToStandPlot(player, state.stand) then return end
	if not state.brainrotName then return end
	if isStandLocked(state) then return end
	if state.level >= Brainrots.MAX_LEVEL then return end
	local now = os.clock()
	if state.lastUpgradeAt + UPGRADE_DEBOUNCE > now then return end
	state.lastUpgradeAt = now
	local cost = recomputeUpgradeCost(state)
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	if c < cost then
		upgradeFeedbackRE:FireClient(player, false, "cash")
		return
	end
	player:SetAttribute("Cash", c - cost)
	state.level += 1
	state.stand:SetAttribute("BrainrotLevel", state.level)
	refreshHeader(state)
	refreshLabels(state)
	setPromptText(state)
end

-- ── Hooks ─────────────────────────────────────────────────────────────────────

local function hookProximity(state: StandState)
	if not state.prompt then
		return
	end
	state.prompt.Triggered:Connect(function(player: Player)
		if state.brainrotName then
			if not isOwner(state, player) then
				return
			end
			local pickupDist = state.prompt.MaxActivationDistance
			if not isPlayerNearStandSpawn(player, state, pickupDist) then
				return
			end
			removeBrainrotFromStand(player, state)
		else
			local placeDist = state.prompt.MaxActivationDistance
			if not isPlayerClosestStandPromptTarget(player, state, placeDist) then
				return
			end
			placeBrainrotOnStand(player, state)
		end
	end)
end

local function ensureClickDetector(part: BasePart, name: string, maxDist: number): ClickDetector
	local existing = part:FindFirstChild(name)
	if existing and existing:IsA("ClickDetector") then
		(existing :: ClickDetector).MaxActivationDistance = maxDist
		return existing
	end
	if existing then existing:Destroy() end
	local cd = Instance.new("ClickDetector")
	cd.Name = name
	cd.MaxActivationDistance = maxDist
	cd.Parent = part
	return cd
end

local function findUpgradePart(stand: Model): BasePart?
	local panel = stand:FindFirstChild("LevelPanel")
	if not panel then return nil end
	local level = panel:FindFirstChild("Level")
	if level and level:IsA("BasePart") then
		return level :: BasePart
	end
	if level then
		for _, d in ipairs(level:GetDescendants()) do
			if d:IsA("BasePart") then
				return d :: BasePart
			end
		end
	end
	return nil
end

local function hookButtonTouch(state: StandState)
	local part = state.buttonPart
	if not part then return end
	-- Touched only fires when physics reports contact; many cash pads are non-collidable.
	part.CanTouch = true
	part.Touched:Connect(function(other: BasePart)
		if not other:IsA("BasePart") then return end
		local char = other:FindFirstAncestorWhichIsA("Model")
		if not char then return end
		local plr = Players:GetPlayerFromCharacter(char)
		if not plr then return end
		collectCash(state, plr)
	end)
	-- No ClickDetector on the cash pad: collection is walk-over only.
	local stale = part:FindFirstChild("_StandCashClick")
	if stale then stale:Destroy() end
end

local function hookUpgradeClick(state: StandState)
	local part = findUpgradePart(state.stand)
	if not part then return end
	local cd = ensureClickDetector(part, "_StandUpgradeClick", 22)
	cd.MouseClick:Connect(function(plr)
		upgradeStandBrainrot(state, plr)
	end)
end

-- Collection uses ButtonPart.Touched (CanTouch enabled in ensureStandVisible).

-- Forward declaration (body below stand discovery helpers).
local scanForStands: () -> ()

-- Copied onto each stand so PlotUsernameLabels / remotes can resolve the plot when
-- the stand's story is parked under ServerStorage (not a descendant of the base).
local function resolvePlotBaseNameForStand(stand: Model): string?
	local standsFolder = stand.Parent
	if standsFolder then
		local story = standsFolder.Parent
		if story then
			local a = story:GetAttribute("PlotBaseName")
			if typeof(a) == "string" and a ~= "" then
				return a
			end
		end
	end
	local p: Instance? = stand
	while p do
		local par = p.Parent
		if par and par.Name == "Spawn And Bases" then
			return p.Name
		end
		p = par
	end
	return nil
end

-- ── Stand init ────────────────────────────────────────────────────────────────

local function initStand(stand: Model)
	if stands[stand] then
		PlotStandPlaceholders.ensureStandVisible(stand)
		return
	end

	local spawnPart = findSpawnPart(stand)
	if not spawnPart then
		if stand:GetAttribute("_StandInitWaiting") ~= true then
			stand:SetAttribute("_StandInitWaiting", true)
			local conn: RBXScriptConnection?
			conn = stand.DescendantAdded:Connect(function(desc)
				if desc:IsA("BasePart") and desc.Name == "Spawn" then
					if conn then
						conn:Disconnect()
					end
					stand:SetAttribute("_StandInitWaiting", nil)
					task.defer(function()
						if stand.Parent then
							initStand(stand)
						end
					end)
				end
			end)
			stand.Destroying:Once(function()
				if conn then
					conn:Disconnect()
				end
			end)
		end
		return
	end
	stand:SetAttribute("_StandInitWaiting", nil)
	local prompt = ensureStandProximityPrompt(stand, spawnPart)
	local buttonPart = findButtonPart(stand)
	local totalLabel = findTotalCashLabel(stand)
	local offlineLabel = findOfflineCashLabel(stand)
	local upgradeFrame, costLabel, levelLabel = findUpgradeFrameAndLabels(stand)

	local state: StandState = {
		stand = stand,
		spawnPart = spawnPart,
		prompt = prompt,
		buttonPart = buttonPart,
		totalLabel = totalLabel,
		offlineLabel = offlineLabel,
		upgradeFrame = upgradeFrame,
		costLabel = costLabel,
		levelLabel = levelLabel,
		ownerUserId = nil,
		brainrotName = nil,
		rarity = nil,
		mutation = nil,
		level = 1,
		baseIncome = 0,
		sourcePath = "",
		displayModel = nil,
		idleTrack = nil,
		accumulated = 0,
		lastTickAt = os.clock(),
		lastCollectAt = 0,
		lastUpgradeAt = 0,
		touchDebouncePerPlayer = {},
	}
	stands[stand] = state

	local plotBaseName = resolvePlotBaseNameForStand(stand)
	if plotBaseName then
		stand:SetAttribute("PlotBaseName", plotBaseName)
	end

	stand:SetAttribute("BrainrotStand", true)
	hookProximity(state)
	hookButtonTouch(state)
	hookUpgradeClick(state)
	-- Re-evaluate prompt when the BaseFloorUnlock script toggles the lock attribute.
	stand:GetAttributeChangedSignal("BrainrotStandLocked"):Connect(function()
		setPromptText(state)
	end)
	setPromptText(state)
	refreshLabels(state)
	PlotStandPlaceholders.ensureStandVisible(stand)
end

-- ── Stand discovery: auto-detect any descendant of Map matching the structure ─

local function isStandModel(inst: Instance): boolean
	if not inst:IsA("Model") then return false end
	if not inst.Parent then return false end
	if not (inst.Parent.Name == "stands" or inst.Parent.Name == "Stands") then return false end
	if findSpawnPart(inst :: Model) then return true end
	if inst:FindFirstChild("Button", true) or inst:FindFirstChild("LevelPanel", true) then return true end
	return string.match(inst.Name, "^[Ss]tand") ~= nil
end

local rescanStandScheduled = false
local function requestStandRescan()
	if rescanStandScheduled then
		return
	end
	rescanStandScheduled = true
	task.defer(function()
		rescanStandScheduled = false
		scanForStands()
	end)
end

local function getStoryNumberFromName(name: string): number?
	local digits = string.match(name, "^(%d+)")
	if digits then
		return tonumber(digits)
	end
	return nil
end

local function scanStandsUnderStory(story: Instance)
	local standsFolder = PlotStandPlaceholders.findStandsFolder(story)
	if not standsFolder then
		return
	end
	for _, stand in ipairs(standsFolder:GetChildren()) do
		if isStandModel(stand) then
			if not CollectionService:HasTag(stand, STAND_TAG) then
				CollectionService:AddTag(stand, STAND_TAG)
			end
			initStand(stand :: Model)
		end
	end
end

local function scanFolderForStands(root: Instance)
	for _, ch in ipairs(root:GetChildren()) do
		if getStoryNumberFromName(ch.Name) then
			scanStandsUnderStory(ch)
		end
	end
end

scanForStands = function()
	local folder = PlotPaths.findSpawnAndBasesFolder()
	if folder then
		for _, ch in ipairs(folder:GetChildren()) do
			if PlotPaths.isPlotRoot(ch) then
				scanFolderForStands(ch)
			end
		end
	end
	local hidden = ServerStorage:FindFirstChild("__HiddenBaseFloors")
	if hidden then
		scanFolderForStands(hidden)
	end
end

local hiddenFloorsHooked: Instance? = nil

local function hookHiddenFloorsFolder(folder: Instance)
	folder.ChildAdded:Connect(function()
		requestStandRescan()
	end)
end

local function ensureHiddenFloorsHooked()
	local hidden = ServerStorage:FindFirstChild("__HiddenBaseFloors")
	if hidden and hiddenFloorsHooked ~= hidden then
		hiddenFloorsHooked = hidden
		hookHiddenFloorsFolder(hidden)
	end
end

local function ensureStandRescanRequestBindable()
	local folder = ServerStorage:FindFirstChild("BrainrotInternal")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BrainrotInternal"
		folder.Parent = ServerStorage
	end
	local bf = folder:FindFirstChild("RequestStandRescan")
	if not bf then
		bf = Instance.new("BindableFunction")
		bf.Name = "RequestStandRescan"
		bf.Parent = folder
	end
	if bf:IsA("BindableFunction") then
		(bf :: BindableFunction).OnInvoke = requestStandRescan
	end
end

CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(function(inst)
	if not inst:IsA("Model") then
		return
	end
	local stand = inst :: Model
	if not isStandModel(stand) then
		return
	end
	initStand(stand)
end)

ServerStorage.ChildAdded:Connect(function(ch)
	if ch.Name == "__HiddenBaseFloors" then
		ensureHiddenFloorsHooked()
		requestStandRescan()
	end
end)

task.spawn(function()
	ensureStandRescanRequestBindable()
	ensureHiddenFloorsHooked()
	-- Map may stream in late.
	for _ = 1, 5 do
		scanForStands()
		if next(stands) ~= nil then
			break
		end
		task.wait(1)
	end
	scanForStands()
end)

-- ── Remote events ─────────────────────────────────────────────────────────────

local function resolveStandFromArg(arg: any): StandState?
	if typeof(arg) ~= "Instance" then
		return nil
	end
	local m: Instance? = arg :: Instance
	while m do
		if m:IsA("Model") then
			local st = stands[m]
			if st then
				return st
			end
		end
		m = m.Parent
	end
	return nil
end

placeRE.OnServerEvent:Connect(function(player: Player, standArg: any)
	local state = resolveStandFromArg(standArg)
	if not state then return end
	placeBrainrotOnStand(player, state)
end)

removeRE.OnServerEvent:Connect(function(player: Player, standArg: any)
	local state = resolveStandFromArg(standArg)
	if not state then
		return
	end
	if not isOwner(state, player) then
		return
	end
	local maxDist = if state.prompt then state.prompt.MaxActivationDistance else PROMPT_PICKUP_DISTANCE
	if not isPlayerNearStandSpawn(player, state, maxDist) then
		return
	end
	removeBrainrotFromStand(player, state)
end)

upgradeRE.OnServerEvent:Connect(function(player: Player, standArg: any)
	local state = resolveStandFromArg(standArg)
	if not state then return end
	upgradeStandBrainrot(state, player)
end)

-- ── Income loop ──────────────────────────────────────────────────────────────

local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum >= INCOME_TICK then
		local stepped = accum
		accum = 0
		for _, state in pairs(stands) do
			tickStand(state, stepped)
		end
	end
end)

-- ── Player cleanup ───────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player)
	for _, state in pairs(stands) do
		if isOwner(state, player) then
			-- Leave the brainrot on the stand; ownership persists per-server.
			state.touchDebouncePerPlayer[player] = nil
		end
	end
end)

