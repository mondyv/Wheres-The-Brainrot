-- [ACTIVE] StandManager.server
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
	    │     └── Cash.BillboardGui.Offline.Purple  (offline cash earned while away)
	    └── LevelPanel.Level.SurfaceGui.Frame.Upgrade
	          └── Info.Cost      (TextLabel — upgrade cost)

	Behaviour:
	• Player with an equipped brainrot Tool triggers the prompt → brainrot is placed on Spawn,
	  Tool/inventory entry consumed, stand now owned by the placer.
	• Owner standing on prompt again removes the brainrot (returned to inventory).
	• Stand generates cash at the level/mutation income rate; cap at OFFLINE_CAP if no one collects.
	• After a saved logout (10+ minutes away), returning players earn offline income at 0.2× live rate
	  (up to 8h). OfflineEarnings2x offers a Robux 2× claim; Decline puts the cash on pads.
	• Touch ButtonPart → owner collects accumulated cash (online + offline); coin VFX bursts.
	• Owner clicks the Upgrade SurfaceGui → level +1 (cash) or +25 with 2× Upgrades (Robux dev product).
--]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Modules = script.Parent:WaitForChild("Modules")
local Brainrots = require(Modules:WaitForChild("Brainrots"))
local BrainrotHeader = require(Modules:WaitForChild("BrainrotHeader"))
local BrainrotAnimations = require(Modules:WaitForChild("BrainrotAnimations"))
local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotStandPlaceholders = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotStandPlaceholders"))
local BrainrotCarryVisual = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotCarryVisual"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotStandConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotStandConfig"))
local OfflineEarningsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OfflineEarningsConfig"))

local STAND_TAG = "BrainrotStand"
local STAND_ACCUMULATED_ATTR = "StandAccumulatedCash"
-- Accumulated cash is capped at OFFLINE_CAP_SECONDS * income; tunes how long a player can leave it.
local OFFLINE_CAP_SECONDS = OfflineEarningsConfig.CAP_SECONDS
local OFFLINE_MIN_SECONDS = OfflineEarningsConfig.MIN_OFFLINE_SECONDS
local OFFLINE_INCOME_MULT = OfflineEarningsConfig.INCOME_MULT
local COLLECT_TOUCH_DEBOUNCE = 0.5 -- seconds between successful collect claims on the money pad
local COLLECT_TOUCH_CHARACTER_DEBOUNCE = 0.2 -- blocks limb/accessory spam before collectCash even runs
local COLLECT_VFX_MIN_INTERVAL = 0.25 -- prevents duplicate collect remotes from stacking in one moment
local CASH_PAD_DISPLAY_INTERVAL = 1 -- cash pad label/attribute refresh cadence (once per second)
local CASH_PAD_DISPLAY_STAGGER_BUCKETS = 16
local INCOME_TICK_INTERVAL = 0.25
local INCOME_STANDS_PER_HEARTBEAT = 24
local UPGRADE_DEBOUNCE = 0.08 -- blocks duplicate upgrade fires from GUI + remote on the same click
local PICKUP_DEBOUNCE = 0.35 -- blocks duplicate inventory adds from double prompt triggers
local PROMPT_PLACE_DISTANCE = 10
local PROMPT_PICKUP_DISTANCE = 14
-- When placing on empty stands side-by-side, only the nearest spawn wins (prevents wrong-stand place).
local PROMPT_CLOSEST_MARGIN = 1.25
local nextCashDisplayBucket = 0

local function nextCashDisplayPhase(): number
	nextCashDisplayBucket = (nextCashDisplayBucket % CASH_PAD_DISPLAY_STAGGER_BUCKETS) + 1
	return (nextCashDisplayBucket / CASH_PAD_DISPLAY_STAGGER_BUCKETS) * CASH_PAD_DISPLAY_INTERVAL
end

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
local placeRE = ensureRemoteEvent(remotesFolder, "PlaceBrainrotOnStand") -- (standModel)
local removeRE = ensureRemoteEvent(remotesFolder, "RemoveBrainrotFromStand") -- (standModel)
local upgradeRE = ensureRemoteEvent(remotesFolder, "UpgradeStandBrainrot") -- (standModel)
local prepareRobuxStandUpgradeRE = ensureRemoteEvent(remotesFolder, "PrepareRobuxStandUpgrade") -- (standModel, mode)
local upgradeFeedbackRE = ensureRemoteEvent(remotesFolder, "StandUpgradeFeedback") -- server → client (ok, reason)
local collectVFXRE = ensureRemoteEvent(remotesFolder, "StandCashCollectedFX") -- server → client (standModel, cashAmount)
local _autoCollectVFXRE = ensureRemoteEvent(remotesFolder, "AutoCollectCashCollectedFX") -- server → client (autocollectModel, totalCash)
local showOfflineEarningsRE = ensureRemoteEvent(remotesFolder, "ShowOfflineEarnings") -- server → client (amount)
local declineOfflineEarningsRE = ensureRemoteEvent(remotesFolder, "DeclineOfflineEarnings") -- client → server
local offlineDoubledRE = ensureRemoteEvent(remotesFolder, "OfflineEarningsDoubled") -- server → client (grantedAmount)

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
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if plot then
		return stand:IsDescendantOf(plot)
	end
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

local function storyNameForStand(stand: Model): string?
	local standsFolder = stand.Parent
	if not standsFolder or (standsFolder.Name ~= "Stands" and standsFolder.Name ~= "stands") then
		return nil
	end
	local story = standsFolder.Parent
	if story then
		return story.Name
	end
	return nil
end

local function standSaveKey(standName: string, storyName: string?): string
	return (storyName or "") .. "\0" .. standName
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

local function _findDescendantByName(root: Instance, name: string): Instance?
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
	local bp: Instance? = nil
	if btn then
		bp = btn:FindFirstChild("ButtonPart")
	end
	if not bp or not bp:IsA("BasePart") then
		bp = stand:FindFirstChild("ButtonPart", true)
	end
	if not bp then
		return nil
	end
	local total = bp:FindFirstChild("Total", true)
	if total and (total:IsA("TextLabel") or total:IsA("TextButton")) then
		return total
	end
	return nil
end

local function setLabelText(label: (TextLabel | TextButton)?, text: string)
	if not label then
		return
	end
	if label:IsA("TextLabel") then
		local tl = label :: TextLabel
		tl.AutoLocalize = false
		tl.TextTruncate = Enum.TextTruncate.None
		tl.Text = text
	elseif label:IsA("TextButton") then
		local tb = label :: TextButton
		tb.AutoLocalize = false
		tb.TextTruncate = Enum.TextTruncate.None
		tb.Text = text
	end
end

local function findStandOfflineUi(stand: Model): (BillboardGui?, GuiObject?, (TextLabel | TextButton)?)
	local btn = stand:FindFirstChild("Button")
	if not btn then
		return nil, nil, nil
	end
	local cash = btn:FindFirstChild("Cash")
	if not cash then
		return nil, nil, nil
	end
	local bb = cash:FindFirstChild("BillboardGui")
	if not bb or not bb:IsA("BillboardGui") then
		return nil, nil, nil
	end
	local offline = bb:FindFirstChild("Offline")
	if not offline then
		return bb, nil, nil
	end
	local offlineRoot: GuiObject? = if offline:IsA("GuiObject") then offline else nil
	local purple = offline:FindFirstChild("Purple")
	if purple and (purple:IsA("TextLabel") or purple:IsA("TextButton")) then
		return bb, offlineRoot, purple
	end
	if offline:IsA("TextLabel") or offline:IsA("TextButton") then
		return bb, offlineRoot, offline
	end
	return bb, offlineRoot, nil
end

local function findUpgradeFrameAndLabels(
	stand: Model
): (Instance?, (TextLabel | TextButton)?, (TextLabel | TextButton)?)
	local panel = stand:FindFirstChild("LevelPanel")
	if not panel then
		return nil, nil, nil
	end
	local level = panel:FindFirstChild("Level")
	if not level then
		return nil, nil, nil
	end
	local sg = level:FindFirstChild("SurfaceGui")
	if not sg then
		return nil, nil, nil
	end
	local frame = sg:FindFirstChild("Frame")
	if not frame then
		return nil, nil, nil
	end
	local upgrade = frame:FindFirstChild("Upgrade")
	if not upgrade then
		return nil, nil, nil
	end
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
	offlineFrame: GuiObject?,
	offlineBillboard: BillboardGui?,
	offlinePending: number,
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
	lastCollectVfxAt: number,
	lastUpgradeAt: number,
	lastPickupAt: number,
	lastCashDisplayAt: number,
	cashDisplayPhase: number,
	touchDebouncePerPlayer: { [Player]: number },
}

local stands: { [Model]: StandState } = {}

local autoCollectRefreshScheduled: { [number]: boolean } = {}
local autoCollectRefreshLastAt: { [number]: number } = {}
local AUTO_COLLECT_REFRESH_MIN_INTERVAL = 2.5

local function scheduleAutoCollectRefresh(ownerUserId: number?)
	if typeof(ownerUserId) ~= "number" then
		return
	end
	local uid = ownerUserId
	local now = os.clock()
	local lastAt = autoCollectRefreshLastAt[uid] or 0
	if now - lastAt < AUTO_COLLECT_REFRESH_MIN_INTERVAL then
		return
	end
	if autoCollectRefreshScheduled[uid] then
		return
	end
	autoCollectRefreshScheduled[uid] = true
	task.defer(function()
		autoCollectRefreshScheduled[uid] = nil
		autoCollectRefreshLastAt[uid] = os.clock()
		local folder = ServerStorage:FindFirstChild("BrainrotInternal")
		local bf = folder and folder:FindFirstChild("RefreshAutoCollectDisplay")
		if bf and bf:IsA("BindableFunction") then
			pcall(function()
				(bf :: BindableFunction):Invoke(uid)
			end)
		end
	end)
end

local function resolveTotalCashLabel(state: StandState): (TextLabel | TextButton)?
	local label = state.totalLabel
	if label and label.Parent then
		return label
	end
	label = findTotalCashLabel(state.stand)
	state.totalLabel = label
	return label
end

local function syncCashPadDisplay(state: StandState, forceImmediate: boolean?)
	local now = os.clock()
	if not forceImmediate and state.lastCashDisplayAt + CASH_PAD_DISPLAY_INTERVAL > now then
		return
	end
	if forceImmediate then
		state.lastCashDisplayAt = now - state.cashDisplayPhase
	else
		state.lastCashDisplayAt = now
	end

	local displayAmount = math.floor(state.accumulated + 0.5)
	if state.stand:GetAttribute(STAND_ACCUMULATED_ATTR) ~= displayAmount then
		state.stand:SetAttribute(STAND_ACCUMULATED_ATTR, displayAmount)
	end
	local text = BrainrotEconomy.formatCashAccumulated(displayAmount)
	local label = resolveTotalCashLabel(state)
	if label and label.Text ~= text then
		setLabelText(label, text)
	end
end

local function resolveOfflineUi(state: StandState): (BillboardGui?, GuiObject?, (TextLabel | TextButton)?)
	if state.offlineBillboard and state.offlineBillboard.Parent then
		return state.offlineBillboard, state.offlineFrame, state.offlineLabel
	end
	local bb, frame, label = findStandOfflineUi(state.stand)
	state.offlineBillboard = bb
	state.offlineFrame = frame
	state.offlineLabel = label
	return bb, frame, label
end

local function syncOfflineDisplay(state: StandState)
	local bb, frame, label = resolveOfflineUi(state)
	local pending = state.offlinePending
	local show = state.brainrotName ~= nil and pending > 0.5
	if bb then
		bb.Enabled = show
		if show and not bb.Adornee then
			local btn = state.stand:FindFirstChild("Button")
			local cash = if btn then btn:FindFirstChild("Cash") else nil
			if cash and cash:IsA("BasePart") then
				bb.Adornee = cash :: BasePart
			elseif state.buttonPart then
				bb.Adornee = state.buttonPart
			end
		end
	end
	if frame then
		frame.Visible = show
	end
	if label then
		if show then
			setLabelText(label, "+" .. BrainrotEconomy.formatCashAccumulated(pending) .. " Offline")
			if label:IsA("GuiObject") then
				(label :: GuiObject).Visible = true
			end
		elseif label:IsA("GuiObject") then
			(label :: GuiObject).Visible = false
		end
	end
end

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
	if not state.brainrotName then
		return 0
	end
	-- Repair missing/invalid income identity so stands don't sit forever at $0.
	local catalog = Brainrots.getByName(state.brainrotName)
	if catalog then
		if typeof(state.baseIncome) ~= "number" or state.baseIncome <= 0 then
			state.baseIncome = catalog.baseIncome
			state.stand:SetAttribute("BrainrotBaseIncome", state.baseIncome)
		end
		local rarityOk = typeof(state.rarity) == "string"
			and Brainrots.RARITY_BY_ID[Brainrots.normalizeRarityId(state.rarity)] ~= nil
		if not rarityOk then
			state.rarity = catalog.rarity
			state.stand:SetAttribute("BrainrotRarity", state.rarity)
		else
			local normalized = Brainrots.normalizeRarityId(state.rarity :: string)
			if normalized ~= state.rarity then
				state.rarity = normalized
				state.stand:SetAttribute("BrainrotRarity", state.rarity)
			end
		end
	elseif typeof(state.rarity) == "string" then
		state.rarity = Brainrots.normalizeRarityId(state.rarity)
	end
	if not state.rarity then
		return 0
	end
	local def = {
		name = state.brainrotName,
		rarity = state.rarity,
		baseIncome = state.baseIncome,
	}
	return Brainrots.incomePerSecond(def, state.level, state.mutation or "normal")
end

local function standBrainrotDef(state: StandState)
	return {
		name = state.brainrotName,
		rarity = state.rarity,
		baseIncome = state.baseIncome,
	}
end

local function upgradeLevelGainForPlayer(player: Player?): number
	if not player then
		return BrainrotStandConfig.NORMAL_LEVEL_GAIN
	end
	if player:GetAttribute(StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED) == true then
		return BrainrotStandConfig.PLUS_25_LEVEL_GAIN
	end
	return BrainrotStandConfig.NORMAL_LEVEL_GAIN
end

local function upgradeLevelGainForStand(state: StandState): number
	if not state.ownerUserId then
		return 1
	end
	local owner = Players:GetPlayerByUserId(state.ownerUserId)
	return upgradeLevelGainForPlayer(owner)
end

-- One button press always costs a single level step — never sum both steps for 2× Upgrades.
local function recomputeUpgradeCost(state: StandState): number
	if not state.brainrotName or not state.rarity then
		return 0
	end
	return Brainrots.upgradeCost(standBrainrotDef(state), state.level, state.mutation or "normal")
end

local STAND_YAW_OFFSET = math.rad(0)
local STAND_PITCH_OFFSET = math.rad(0)
local STAND_ROLL_OFFSET = math.rad(0)

-- Pick a reference part in front of the stand so we can auto-face the brainrot toward the player.
local function findFrontReferencePart(state: StandState): BasePart?
	if state.buttonPart then
		return state.buttonPart
	end
	local panel = state.stand:FindFirstChild("LevelPanel")
	if panel then
		local level = panel:FindFirstChild("Level")
		if level and level:IsA("BasePart") then
			return level :: BasePart
		end
		if level then
			local any = level:FindFirstChildWhichIsA("BasePart", true)
			if any then
				return any
			end
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

local function refreshLabels(state: StandState)
	syncCashPadDisplay(state, true)
	syncOfflineDisplay(state)
	if state.costLabel then
		if not state.brainrotName then
			setLabelText(state.costLabel, "—")
			state.stand:SetAttribute("StandUpgradeCost", 0)
		else
			local cost = recomputeUpgradeCost(state)
			if state.level >= Brainrots.MAX_LEVEL then
				setLabelText(state.costLabel, "MAX")
				state.stand:SetAttribute("StandUpgradeCost", 0)
			else
				setLabelText(state.costLabel, formatCashShort(cost))
				state.stand:SetAttribute("StandUpgradeCost", cost)
			end
		end
	end
	if state.levelLabel then
		if not state.brainrotName then
			setLabelText(state.levelLabel, "Empty")
		elseif state.level >= Brainrots.MAX_LEVEL then
			setLabelText(state.levelLabel, string.format("Lvl %d", state.level))
		else
			local gain = upgradeLevelGainForStand(state)
			local nextLevel = math.min(Brainrots.MAX_LEVEL, state.level + gain)
			setLabelText(state.levelLabel, string.format("Lvl %d → %d", state.level, nextLevel))
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
	configureStandProximityPrompt(prompt, if state.brainrotName then PROMPT_PICKUP_DISTANCE else PROMPT_PLACE_DISTANCE)
	prompt.Enabled = true
end

-- ── Stand display Idle (asset IDs in Modules.BrainrotAnimations) ─────────────

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
	local stand = state.stand
	local toDestroy: { Model } = {}
	local seen: { [Model]: boolean } = {}

	local function queue(model: Model)
		if seen[model] then
			return
		end
		seen[model] = true
		table.insert(toDestroy, model)
	end

	if state.displayModel and state.displayModel.Parent then
		queue(state.displayModel)
	end

	for _, desc in stand:GetDescendants() do
		if desc:IsA("Model") and desc:GetAttribute("BrainrotStandDisplay") == true then
			queue(desc :: Model)
		end
	end

	for _, model in toDestroy do
		BrainrotHeader.remove(model)
		if model.Parent then
			model:Destroy()
		end
	end

	state.displayModel = nil
end

local function setAllPartsAnchored(model: Model, anchored: boolean)
	BrainrotCarryVisual.applyNonColliding(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = anchored
		end
	end
end

local function getMainPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local p = model:FindFirstChildWhichIsA("BasePart", true)
	if p and not model.PrimaryPart then
		model.PrimaryPart = p
	end
	return p
end

local function findBrainrotTemplateForState(state: StandState): Model?
	local brainrots = Brainrots.getBrainrotsFolder()
	if not brainrots or not brainrots:IsA("Folder") then
		return nil
	end
	local nameFolder = Brainrots.findBrainrotStorageFolder(brainrots, state.brainrotName or "")
	if not nameFolder then
		return nil
	end
	local variantName = (Brainrots :: any).MUTATION_TEMPLATE_FOLDER[state.mutation or "normal"]
	if typeof(variantName) == "string" then
		local v = nameFolder:FindFirstChild(variantName)
		if v and v:IsA("Model") then
			return v :: Model
		end
	end
	local normal = nameFolder:FindFirstChild("Normal")
	if normal and normal:IsA("Model") then
		return normal :: Model
	end
	for _, c in ipairs(nameFolder:GetChildren()) do
		if c:IsA("Model") then
			return c :: Model
		end
	end
	return nil
end

local function repositionDisplayOnSpawn(state: StandState)
	local clone = state.displayModel
	if not clone or not clone.Parent or not state.spawnPart then
		return
	end
	local rotatedCenter, rotatedSize = clone:GetBoundingBox()
	local minY = rotatedCenter.Y - rotatedSize.Y * 0.5
	local desiredMinY = state.spawnPart.Position.Y + state.spawnPart.Size.Y * 0.5 + 0.05
	local yShift = desiredMinY - minY
	if math.abs(yShift) > 0.005 then
		clone:PivotTo(clone:GetPivot() + Vector3.new(0, yShift, 0))
	end
end

-- Place the configured brainrot model on the Spawn part with header billboard.
local function rebuildDisplay(state: StandState)
	clearDisplayModel(state)
	if not state.brainrotName then
		return
	end

	local template = findBrainrotTemplateForState(state)
	if not template then
		warn(
			string.format(
				"[StandManager] No template for %s (%s)",
				tostring(state.brainrotName),
				tostring(state.mutation)
			)
		)
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

	BrainrotCarryVisual.applyScaleForLevel(clone, state.level)

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

	setAllPartsAnchored(clone, true)
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

local function applyStandFromSave(
	player: Player,
	state: StandState,
	entry: {
		storyName: string?,
		standName: string,
		brainrotName: string,
		rarity: string,
		mutation: string,
		level: number,
		baseIncome: number,
		sourcePath: string,
		accumulated: number,
	}
)
	if not playerAssignedToStandPlot(player, state.stand) then
		return
	end
	if state.stand.Name ~= entry.standName then
		return
	end
	if entry.storyName and storyNameForStand(state.stand) ~= entry.storyName then
		return
	end
	if state.ownerUserId ~= nil and state.ownerUserId ~= player.UserId then
		return
	end

	state.ownerUserId = player.UserId
	state.brainrotName = entry.brainrotName
	state.rarity = entry.rarity
	state.mutation = entry.mutation
	state.level = math.max(1, math.floor(entry.level))
	state.baseIncome = entry.baseIncome
	if state.baseIncome <= 0 then
		local catalog = Brainrots.getByName(entry.brainrotName)
		if catalog then
			state.baseIncome = catalog.baseIncome
		end
	end
	if typeof(state.rarity) == "string" then
		state.rarity = Brainrots.normalizeRarityId(state.rarity)
	end
	state.sourcePath = entry.sourcePath
	state.accumulated = math.max(0, entry.accumulated)
	state.offlinePending = 0
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

local function buildStandSaveEntryFromState(state: StandState): { any }
	return {
		standName = state.stand.Name,
		storyName = storyNameForStand(state.stand),
		brainrotName = state.brainrotName,
		rarity = state.rarity or "common",
		mutation = state.mutation or "normal",
		level = state.level,
		baseIncome = state.baseIncome,
		sourcePath = state.sourcePath,
		accumulated = state.accumulated,
	}
end

local function buildStandSaveEntryFromModel(stand: Model, ownerUserId: number): { any }?
	local owner = stand:GetAttribute("StandOwnerUserId")
	local brainrotName = stand:GetAttribute("BrainrotName")
	if owner ~= ownerUserId or typeof(brainrotName) ~= "string" or brainrotName == "" then
		return nil
	end
	local level = stand:GetAttribute("BrainrotLevel")
	local baseIncome = stand:GetAttribute("BrainrotBaseIncome")
	return {
		standName = stand.Name,
		storyName = storyNameForStand(stand),
		brainrotName = brainrotName,
		rarity = if typeof(stand:GetAttribute("BrainrotRarity")) == "string"
			then stand:GetAttribute("BrainrotRarity")
			else "common",
		mutation = if typeof(stand:GetAttribute("BrainrotMutation")) == "string"
			then stand:GetAttribute("BrainrotMutation")
			else "normal",
		level = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1,
		baseIncome = if typeof(baseIncome) == "number" then baseIncome else 0,
		sourcePath = "",
		accumulated = if typeof(stand:GetAttribute(STAND_ACCUMULATED_ATTR)) == "number"
			then stand:GetAttribute(STAND_ACCUMULATED_ATTR)
			else 0,
	}
end

local function exportStandEntriesFromPlot(player: Player): { any }
	local out: { any } = {}
	local plot = PlotPaths.findPlotForAssignedSlot(player)
	if not plot then
		return out
	end
	for _, story in ipairs(plot:GetChildren()) do
		local standsFolder = PlotStandPlaceholders.findStandsFolder(story)
		if not standsFolder then
			continue
		end
		for _, child in ipairs(standsFolder:GetChildren()) do
			if child:IsA("Model") then
				local entry = buildStandSaveEntryFromModel(child :: Model, player.UserId)
				if entry then
					table.insert(out, entry)
				end
			end
		end
	end
	return out
end

local function exportStandsForPlayer(player: Player): { any }
	local merged: { [string]: any } = {}
	for _, state in pairs(stands) do
		if state.ownerUserId == player.UserId and state.brainrotName and state.stand.Parent then
			if playerAssignedToStandPlot(player, state.stand) then
				local entry = buildStandSaveEntryFromState(state)
				merged[standSaveKey(entry.standName, entry.storyName)] = entry
			end
		end
	end
	for _, entry in exportStandEntriesFromPlot(player) do
		local key = standSaveKey(entry.standName, entry.storyName)
		if not merged[key] then
			merged[key] = entry
		else
			local existing = merged[key]
			if (existing.accumulated or 0) <= 0 and (entry.accumulated or 0) > 0 then
				existing.accumulated = entry.accumulated
			end
		end
	end
	local out = {}
	for _, entry in pairs(merged) do
		table.insert(out, entry)
	end
	return out
end

local function grantOfflineEarningsForStand(state: StandState, player: Player, lastSavedAt: number): number
	if not state.brainrotName or lastSavedAt <= 0 then
		return 0
	end
	if state.ownerUserId ~= player.UserId then
		return 0
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return 0
	end
	local elapsed = os.time() - lastSavedAt
	-- No offline income until the player has been away long enough.
	if elapsed < OFFLINE_MIN_SECONDS then
		return 0
	end
	-- Accrue only the time after the minimum AFK gate.
	local offlineSec = math.min(elapsed - OFFLINE_MIN_SECONDS, OFFLINE_CAP_SECONDS)
	if offlineSec <= 0 then
		return 0
	end
	local ips = recomputeIncomePerSecond(state)
	if ips <= 0 then
		return 0
	end
	local moneyMult = getPlayerMoneyMult(player)
	local mult = moneyMult * OFFLINE_INCOME_MULT
	local gain = ips * mult * offlineSec
	local cap = ips * mult * OFFLINE_CAP_SECONDS
	local room = math.max(0, cap - state.accumulated)
	-- Held in offlinePending until Decline (pads) or Double (cash grant) — not collectable yet.
	return math.min(gain, room)
end

local pendingOfflineDoubleOffer: { [Player]: number } = {}

local function clearOfflinePendingOnly(player: Player)
	for _, state in pairs(stands) do
		if state.ownerUserId == player.UserId and state.brainrotName then
			if state.offlinePending > 0 then
				state.offlinePending = 0
				refreshLabels(state)
			end
		end
	end
	scheduleAutoCollectRefresh(player.UserId)
end

local function commitOfflinePendingToPads(player: Player)
	for _, state in pairs(stands) do
		if state.ownerUserId == player.UserId and state.brainrotName then
			local pending = math.max(0, state.offlinePending)
			if pending > 0 then
				local moneyMult = getPlayerMoneyMult(player)
				local ips = recomputeIncomePerSecond(state)
				local cap = ips * moneyMult * OFFLINE_INCOME_MULT * OFFLINE_CAP_SECONDS
				-- Once committed, pad uses full money mult for ongoing cap; offline chunk stays in accumulated.
				cap = math.max(cap, ips * moneyMult * OFFLINE_CAP_SECONDS)
				state.accumulated = math.min(cap, state.accumulated + pending)
				-- Keep offlinePending so the stand billboard still shows "+X Offline" until collected.
				refreshLabels(state)
			end
		end
	end
	scheduleAutoCollectRefresh(player.UserId)
end

local function applyOfflineEarningsForPlayer(player: Player, lastSavedAt: number)
	if typeof(lastSavedAt) ~= "number" or lastSavedAt <= 0 then
		return
	end
	local totalAdded = 0
	for _, state in pairs(stands) do
		if state.ownerUserId == player.UserId and state.brainrotName then
			local added = grantOfflineEarningsForStand(state, player, lastSavedAt)
			state.offlinePending = added
			totalAdded += added
			refreshLabels(state)
		end
	end
	scheduleAutoCollectRefresh(player.UserId)
	local offer = math.floor(totalAdded + 0.5)
	if offer >= 1 then
		pendingOfflineDoubleOffer[player] = offer
		showOfflineEarningsRE:FireClient(player, offer)
		-- Safety: if the client never resolves the offer, still put cash on the pads.
		task.delay(180, function()
			if not player.Parent then
				return
			end
			if pendingOfflineDoubleOffer[player] == offer then
				commitOfflinePendingToPads(player)
				pendingOfflineDoubleOffer[player] = nil
			end
		end)
	else
		pendingOfflineDoubleOffer[player] = nil
	end
end

local function grantOfflineDouble(player: Player): (boolean, number)
	local offer = pendingOfflineDoubleOffer[player]
	if typeof(offer) ~= "number" or offer < 1 then
		return false, 0
	end
	local granted = math.floor(offer) * 2
	clearOfflinePendingOnly(player)
	pendingOfflineDoubleOffer[player] = nil
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + granted)
	offlineDoubledRE:FireClient(player, granted)
	return true, granted
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
	state.offlinePending = 0
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

local function countStandsOnPlayerPlot(player: Player): number
	local count = 0
	for _, state in pairs(stands) do
		if playerAssignedToStandPlot(player, state.stand) then
			count += 1
		end
	end
	return count
end

local function clearPlayerPlotStands(player: Player)
	for _, state in pairs(stands) do
		if not playerAssignedToStandPlot(player, state.stand) then
			continue
		end
		if state.ownerUserId == nil or state.ownerUserId == player.UserId then
			clearStandState(state)
		end
	end
end

local function importStandsForPlayer(player: Player, entries: { any })
	if typeof(entries) ~= "table" then
		return
	end
	clearPlayerPlotStands(player)
	for _, entry in entries do
		if typeof(entry) ~= "table" or typeof(entry.standName) ~= "string" then
			continue
		end
		for _, state in pairs(stands) do
			if state.stand.Name ~= entry.standName then
				continue
			end
			if not playerAssignedToStandPlot(player, state.stand) then
				continue
			end
			if entry.storyName and storyNameForStand(state.stand) ~= entry.storyName then
				continue
			end
			applyStandFromSave(player, state, entry :: any)
			break
		end
	end
end

local function placeBrainrotOnStand(player: Player, state: StandState)
	if state.brainrotName ~= nil then
		return -- Already occupied.
	end
	if isStandLocked(state) then
		return
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return
	end
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("BrainrotTool") ~= true then
		return
	end
	local invIdx = tool:GetAttribute("BrainrotInvIndex")
	if typeof(invIdx) ~= "number" then
		return
	end

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
	if state.baseIncome <= 0 and typeof(state.brainrotName) == "string" then
		local catalog = Brainrots.getByName(state.brainrotName)
		if catalog then
			state.baseIncome = catalog.baseIncome
			if typeof(state.rarity) ~= "string" or state.rarity == "" then
				state.rarity = catalog.rarity
			end
		end
	end
	if typeof(state.rarity) == "string" then
		state.rarity = Brainrots.normalizeRarityId(state.rarity)
	end
	state.sourcePath = entry.sourcePath or toolSourcePath or ""
	state.accumulated = 0
	state.offlinePending = 0
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
	if not folder then
		return nil
	end
	local bf = folder:FindFirstChild("ReturnInventoryEntry")
	if bf and bf:IsA("BindableFunction") then
		return bf
	end
	return nil
end

local CashBoostUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CashBoostUtil"))

function getPlayerMoneyMult(player: Player): number
	return CashBoostUtil.getMoneyMultiplier(player)
end

local function removeBrainrotFromStand(player: Player, state: StandState)
	if not state.brainrotName then
		return
	end
	if not isOwner(state, player) then
		return
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return
	end

	local now = os.clock()
	if state.lastPickupAt + PICKUP_DEBOUNCE > now then
		return
	end
	state.lastPickupAt = now

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
	if not returnFn then
		-- Without the inventory bindable the brainrot would be destroyed and lost; abort pick-up.
		warn("[StandManager] ReturnInventoryEntry bindable missing; pick-up aborted for", player.Name)
		state.lastPickupAt = 0
		return
	end
	local okReturn, returned = pcall(function()
		return returnFn:Invoke(player, entryToReturn)
	end)
	if not okReturn or returned ~= true then
		state.lastPickupAt = 0
		return
	end

	-- Auto-pay any unclaimed cash on pick-up so the owner never loses it.
	-- Note: the money multiplier is already applied while cash accumulates in tickStand,
	-- so pay accumulated flat here (same as pad collection) instead of multiplying twice.
	if state.accumulated > 0 then
		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		local payout = math.floor(state.accumulated)
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
	if ips <= 0 then
		return
	end
	local mult = 1
	if state.ownerUserId then
		local owner = Players:GetPlayerByUserId(state.ownerUserId)
		if owner then
			mult = getPlayerMoneyMult(owner)
		end
	end
	local cap = ips * mult * OFFLINE_CAP_SECONDS
	state.accumulated = math.min(cap, state.accumulated + ips * mult * dt)
	syncCashPadDisplay(state)
end

local function collectCash(state: StandState, player: Player)
	if not isOwner(state, player) then
		return
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return
	end

	local now = os.clock()
	local lastTouch = state.touchDebouncePerPlayer[player]
	if lastTouch and (lastTouch + COLLECT_TOUCH_DEBOUNCE > now) then
		return
	end
	state.touchDebouncePerPlayer[player] = now

	local amount = math.floor(state.accumulated)
	if amount <= 0 then
		return
	end

	-- Keep any tiny fractional income instead of destroying it, but remove the whole-number payout.
	state.accumulated = math.max(0, state.accumulated - amount)
	-- While the 2× join offer is open, offline cash is not on the pad yet — don't wipe it.
	if not pendingOfflineDoubleOffer[player] then
		state.offlinePending = 0
	end

	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + amount)
	state.lastCollectAt = now

	-- Cash collection only needs the money pad + offline label updated.
	-- refreshLabels(state) also touches upgrade cost/level UI and stand attributes, which is unnecessary here.
	syncCashPadDisplay(state, true)
	syncOfflineDisplay(state)
	-- Autocollect pad label is updated client-side (it watches StandAccumulatedCash on each stand),
	-- so we deliberately do NOT refresh the autocollect display here — that path did a per-collect
	-- gamepass web check and caused periodic hitches.

	-- Defer the client-side presentation so payout/labels finish first, and hard-throttle duplicates.
	if now - (state.lastCollectVfxAt or 0) >= COLLECT_VFX_MIN_INTERVAL then
		state.lastCollectVfxAt = now
		task.defer(function()
			if player.Parent and state.stand.Parent then
				collectVFXRE:FireClient(player, state.stand, amount)
			end
		end)
	end
end

local function collectAllCashForPlayer(player: Player): number
	local totalCollected = 0
	local vfxEntries: { { stand: Model, amount: number } } = {}

	for _, state in pairs(stands) do
		if state.ownerUserId ~= player.UserId then
			continue
		end
		if not state.brainrotName then
			continue
		end
		if not playerAssignedToStandPlot(player, state.stand) then
			continue
		end

		local amount = math.floor(state.accumulated)
		if amount <= 0 then
			continue
		end

		state.accumulated = math.max(0, state.accumulated - amount)
		if not pendingOfflineDoubleOffer[player] then
			state.offlinePending = 0
		end
		totalCollected += amount
		table.insert(vfxEntries, { stand = state.stand, amount = amount })
		syncCashPadDisplay(state, true)
		syncOfflineDisplay(state)
	end

	if totalCollected <= 0 then
		return 0
	end

	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + totalCollected)
	-- AutoCollectManager already refreshes the pad display directly after collect-all; no extra
	-- refresh needed here (and the client updates each stand label from replicated attributes).

	table.sort(vfxEntries, function(a, b)
		return a.amount > b.amount
	end)
	for i, entry in ipairs(vfxEntries) do
		if i > 4 then
			break
		end
		task.defer(function()
			if player.Parent and entry.stand.Parent then
				collectVFXRE:FireClient(player, entry.stand, entry.amount)
			end
		end)
	end

	return totalCollected
end

local function getPlayerPlotCashTotals(player: Player): (number, number)
	local accumulated = 0
	local offlinePending = 0
	for _, state in pairs(stands) do
		if state.ownerUserId ~= player.UserId then
			continue
		end
		if not state.brainrotName then
			continue
		end
		if not playerAssignedToStandPlot(player, state.stand) then
			continue
		end
		accumulated += math.max(0, math.floor(state.accumulated + 0.5))
		offlinePending += math.max(0, state.offlinePending)
	end
	return accumulated, offlinePending
end

local pendingRobuxStandUpgrade: { [Player]: { stand: Model, mode: string } } = {}

local function applyStandUpgrade(state: StandState, player: Player, levelGain: number, chargeCash: boolean): boolean
	if not isOwner(state, player) then
		return false
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return false
	end
	if not state.brainrotName then
		return false
	end
	if isStandLocked(state) then
		return false
	end
	if state.level >= Brainrots.MAX_LEVEL then
		return false
	end
	if levelGain <= 0 then
		return false
	end

	local now = os.clock()
	if state.lastUpgradeAt + UPGRADE_DEBOUNCE > now then
		return false
	end
	state.lastUpgradeAt = now

	if chargeCash then
		local cost = recomputeUpgradeCost(state)
		local cash = player:GetAttribute("Cash")
		local c = if typeof(cash) == "number" then cash else 0
		if c < cost then
			return false
		end
		player:SetAttribute("Cash", c - cost)
	end

	state.level = math.min(Brainrots.MAX_LEVEL, state.level + levelGain)
	state.stand:SetAttribute("BrainrotLevel", state.level)
	if state.displayModel and state.displayModel.Parent then
		state.displayModel:SetAttribute("BrainrotLevel", state.level)
		BrainrotCarryVisual.applyScaleForLevel(state.displayModel, state.level)
		repositionDisplayOnSpawn(state)
	end
	refreshLabels(state)
	setPromptText(state)
	task.defer(function()
		if state.displayModel and state.displayModel.Parent then
			refreshHeader(state)
		end
	end)
	return true
end

local function upgradeStandBrainrot(state: StandState, player: Player)
	local levelGain = upgradeLevelGainForPlayer(player)
	if levelGain > BrainrotStandConfig.NORMAL_LEVEL_GAIN then
		upgradeFeedbackRE:FireClient(player, false, "robux_plus25")
		return
	end
	if applyStandUpgrade(state, player, levelGain, true) then
		upgradeFeedbackRE:FireClient(player, true, "ok")
	else
		upgradeFeedbackRE:FireClient(player, false, "cash")
	end
end

local function setPendingRobuxStandUpgrade(player: Player, state: StandState, mode: string)
	pendingRobuxStandUpgrade[player] = {
		stand = state.stand,
		mode = mode,
	}
end

local function fulfillPendingRobuxStandUpgrade(player: Player, expectedMode: string, levelGain: number): boolean
	local pending = pendingRobuxStandUpgrade[player]
	if not pending or pending.mode ~= expectedMode then
		return false
	end
	local state = stands[pending.stand]
	pendingRobuxStandUpgrade[player] = nil
	if not state then
		return false
	end
	return applyStandUpgrade(state, player, levelGain, false)
end

-- ── Hooks ─────────────────────────────────────────────────────────────────────

local function hookProximity(state: StandState)
	if not state.prompt then
		return
	end
	if state.prompt:GetAttribute("_StandTriggerHooked") == true then
		return
	end
	state.prompt:SetAttribute("_StandTriggerHooked", true)
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
	if existing then
		existing:Destroy()
	end
	local cd = Instance.new("ClickDetector")
	cd.Name = name
	cd.MaxActivationDistance = maxDist
	cd.Parent = part
	return cd
end

local function findUpgradePart(stand: Model): BasePart?
	local panel = stand:FindFirstChild("LevelPanel")
	if not panel then
		return nil
	end
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

local cashPadTouchByCharacter: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

local function hookButtonTouch(state: StandState)
	local part = state.buttonPart
	if not part then
		return
	end

	-- Touched can fire for several character parts/accessories in the same instant.
	-- Debounce per character BEFORE calling collectCash so the server doesn't run the full claim path repeatedly.
	part.CanTouch = true
	part.Touched:Connect(function(other: BasePart)
		if not other:IsA("BasePart") then
			return
		end

		local char = other:FindFirstAncestorWhichIsA("Model")
		if not char then
			return
		end

		local plr = Players:GetPlayerFromCharacter(char)
		if not plr then
			return
		end

		local now = os.clock()
		local lastTouch = cashPadTouchByCharacter[char]
		if lastTouch and now - lastTouch < COLLECT_TOUCH_CHARACTER_DEBOUNCE then
			return
		end
		cashPadTouchByCharacter[char] = now

		collectCash(state, plr)
	end)

	-- No ClickDetector on the cash pad: collection is walk-over only.
	local stale = part:FindFirstChild("_StandCashClick")
	if stale then
		stale:Destroy()
	end
end

local function hookUpgradeClick(state: StandState)
	local part = findUpgradePart(state.stand)
	if not part then
		return
	end
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

local function refreshStandProximityPromptState(state: StandState)
	if not state.spawnPart then
		return
	end
	local prompt = ensureStandProximityPrompt(state.stand, state.spawnPart)
	if not prompt then
		return
	end
	if state.prompt ~= prompt then
		state.prompt = prompt
		hookProximity(state)
	end
	setPromptText(state)
end

local function ensureStandPromptDedupWatch(stand: Model)
	if stand:GetAttribute("_StandPromptDedupWatch") == true then
		return
	end
	stand:SetAttribute("_StandPromptDedupWatch", true)
	stand.DescendantAdded:Connect(function(desc)
		if not desc:IsA("ProximityPrompt") then
			return
		end
		task.defer(function()
			local state = stands[stand]
			if state and stand.Parent then
				refreshStandProximityPromptState(state)
			end
		end)
	end)
end

local function initStand(stand: Model)
	if stands[stand] then
		PlotStandPlaceholders.ensureStandVisible(stand)
		local existing = stands[stand]
		refreshStandProximityPromptState(existing)
		resolveTotalCashLabel(existing)
		syncCashPadDisplay(existing, true)
		-- The cash pad may have streamed in after the first init; without this the
		-- pad's Touched is never wired and collection on this stand never works.
		if not existing.buttonPart then
			local lateButton = findButtonPart(stand)
			if lateButton then
				existing.buttonPart = lateButton
				hookButtonTouch(existing)
			end
		end
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
	local offlineBillboard, offlineFrame, offlineLabel = findStandOfflineUi(stand)
	local upgradeFrame, costLabel, levelLabel = findUpgradeFrameAndLabels(stand)

	local state: StandState = {
		stand = stand,
		spawnPart = spawnPart,
		prompt = prompt,
		buttonPart = buttonPart,
		totalLabel = totalLabel,
		offlineLabel = offlineLabel,
		offlineFrame = offlineFrame,
		offlineBillboard = offlineBillboard,
		offlinePending = 0,
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
		lastCollectVfxAt = 0,
		lastUpgradeAt = 0,
		lastPickupAt = 0,
		lastCashDisplayAt = 0,
		cashDisplayPhase = nextCashDisplayPhase(),
		touchDebouncePerPlayer = {},
	}
	stands[stand] = state
	ensureStandPromptDedupWatch(stand)

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
	if not inst:IsA("Model") then
		return false
	end
	if not inst.Parent then
		return false
	end
	if not (inst.Parent.Name == "stands" or inst.Parent.Name == "Stands") then
		return false
	end
	if findSpawnPart(inst :: Model) then
		return true
	end
	if inst:FindFirstChild("Button", true) or inst:FindFirstChild("LevelPanel", true) then
		return true
	end
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

	local exportBF = folder:FindFirstChild("ExportStandsForSave")
	if not exportBF then
		exportBF = Instance.new("BindableFunction")
		exportBF.Name = "ExportStandsForSave"
		exportBF.Parent = folder
	end
	if exportBF:IsA("BindableFunction") then
		(exportBF :: BindableFunction).OnInvoke = function(playerArg: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return {}
			end
			return exportStandsForPlayer(playerArg :: Player)
		end
	end

	local importBF = folder:FindFirstChild("ImportStandsFromSave")
	if not importBF then
		importBF = Instance.new("BindableFunction")
		importBF.Name = "ImportStandsFromSave"
		importBF.Parent = folder
	end
	if importBF:IsA("BindableFunction") then
		(importBF :: BindableFunction).OnInvoke = function(playerArg: any, entries: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return false
			end
			importStandsForPlayer(playerArg :: Player, entries)
			return true
		end
	end

	local offlineBF = folder:FindFirstChild("ApplyStandOfflineEarnings")
	if not offlineBF then
		offlineBF = Instance.new("BindableFunction")
		offlineBF.Name = "ApplyStandOfflineEarnings"
		offlineBF.Parent = folder
	end
	if offlineBF:IsA("BindableFunction") then
		(offlineBF :: BindableFunction).OnInvoke = function(playerArg: any, lastSavedAt: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return false
			end
			if typeof(lastSavedAt) ~= "number" then
				return false
			end
			applyOfflineEarningsForPlayer(playerArg :: Player, lastSavedAt)
			return true
		end
	end

	local countBF = folder:FindFirstChild("CountPlayerPlotStands")
	if not countBF then
		countBF = Instance.new("BindableFunction")
		countBF.Name = "CountPlayerPlotStands"
		countBF.Parent = folder
	end
	if countBF:IsA("BindableFunction") then
		(countBF :: BindableFunction).OnInvoke = function(playerArg: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return 0
			end
			return countStandsOnPlayerPlot(playerArg :: Player)
		end
	end

	local collectAllBF = folder:FindFirstChild("CollectAllStandCashForPlayer")
	if not collectAllBF then
		collectAllBF = Instance.new("BindableFunction")
		collectAllBF.Name = "CollectAllStandCashForPlayer"
		collectAllBF.Parent = folder
	end
	if collectAllBF:IsA("BindableFunction") then
		(collectAllBF :: BindableFunction).OnInvoke = function(playerArg: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return 0
			end
			return collectAllCashForPlayer(playerArg :: Player)
		end
	end

	local totalsBF = folder:FindFirstChild("GetPlayerPlotCashTotals")
	if not totalsBF then
		totalsBF = Instance.new("BindableFunction")
		totalsBF.Name = "GetPlayerPlotCashTotals"
		totalsBF.Parent = folder
	end
	if totalsBF:IsA("BindableFunction") then
		(totalsBF :: BindableFunction).OnInvoke = function(playerArg: any)
			if typeof(playerArg) ~= "Instance" or not (playerArg :: any):IsA("Player") then
				return 0, 0
			end
			return getPlayerPlotCashTotals(playerArg :: Player)
		end
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

ensureStandRescanRequestBindable()

task.spawn(function()
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
	if not state then
		return
	end
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
	if not state then
		return
	end
	upgradeStandBrainrot(state, player)
end)

prepareRobuxStandUpgradeRE.OnServerEvent:Connect(function(player: Player, standArg: any, mode: any)
	if typeof(mode) ~= "string" then
		return
	end
	local state = resolveStandFromArg(standArg)
	if not state then
		return
	end
	if not isOwner(state, player) then
		return
	end
	if not playerAssignedToStandPlot(player, state.stand) then
		return
	end
	if mode == "plus25" then
		if upgradeLevelGainForPlayer(player) <= BrainrotStandConfig.NORMAL_LEVEL_GAIN then
			return
		end
		setPendingRobuxStandUpgrade(player, state, mode)
	elseif mode == "cant_afford" then
		if upgradeLevelGainForPlayer(player) > BrainrotStandConfig.NORMAL_LEVEL_GAIN then
			return
		end
		setPendingRobuxStandUpgrade(player, state, mode)
	end
end)

-- ── Income loop ──────────────────────────────────────────────────────────────

local incomeStandOrder: { StandState } = {}
local incomeTickCursor = 1
local nextIncomeOrderRebuildAt = 0

local function rebuildIncomeStandOrder()
	table.clear(incomeStandOrder)
	for _, state in pairs(stands) do
		table.insert(incomeStandOrder, state)
	end
	incomeTickCursor = 1
	nextIncomeOrderRebuildAt = os.clock() + 1
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now >= nextIncomeOrderRebuildAt or incomeTickCursor > #incomeStandOrder then
		rebuildIncomeStandOrder()
	end
	local count = #incomeStandOrder
	if count == 0 then
		return
	end

	local processed = 0
	while processed < INCOME_STANDS_PER_HEARTBEAT and incomeTickCursor <= count do
		local state = incomeStandOrder[incomeTickCursor]
		incomeTickCursor += 1
		processed += 1
		if state.stand.Parent then
			local elapsed = now - state.lastTickAt
			if elapsed >= INCOME_TICK_INTERVAL then
				state.lastTickAt = now
				tickStand(state, elapsed)
			end
		end
	end
end)

-- ── Player cleanup ───────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player)
	pendingRobuxStandUpgrade[player] = nil
	if pendingOfflineDoubleOffer[player] then
		commitOfflinePendingToPads(player)
	end
	pendingOfflineDoubleOffer[player] = nil
	for _, state in pairs(stands) do
		if isOwner(state, player) then
			-- Leave the brainrot on the stand; ownership persists per-server.
			state.touchDebouncePerPlayer[player] = nil
		end
	end
end)

-- ── Steal API (used by StealBrainrot.server) ─────────────────────────────────
-- Removes the brainrot currently on a stand (without returning it to the owner's
-- inventory) and reports its stats so the thief's system can grant a copy.
do
	local internal = ServerStorage:FindFirstChild("StandInternal")
	if not internal then
		internal = Instance.new("Folder")
		internal.Name = "StandInternal"
		internal.Parent = ServerStorage
	end

	local stealBF = internal:FindFirstChild("StealBrainrotFromStand")
	if not stealBF then
		stealBF = Instance.new("BindableFunction")
		stealBF.Name = "StealBrainrotFromStand"
		stealBF.Parent = internal
	end

	(stealBF :: BindableFunction).OnInvoke = function(standArg: any, thiefArg: any): any
		if typeof(standArg) ~= "Instance" then
			return nil
		end
		local state = stands[standArg :: Model]
		if not state or not state.brainrotName then
			return nil
		end
		-- Don't allow stealing from your own plot.
		if typeof(thiefArg) == "Instance" and (thiefArg :: Instance):IsA("Player") then
			if state.ownerUserId == (thiefArg :: Player).UserId then
				return nil
			end
		end
		local stolen = {
			name = state.brainrotName,
			rarity = state.rarity,
			mutation = state.mutation or "normal",
			level = state.level,
			baseIncome = state.baseIncome,
		}
		clearStandState(state)
		return stolen
	end
end

local ProductHandlerServer = require(
	game:GetService("ServerScriptService").EssentialsServer.ProductHandler.ProductHandlerServer
)

ProductHandlerServer.registerProductReceipt(BrainrotStandConfig.PLUS_25_DEV_PRODUCT_ID, function(player: Player)
	local ok = fulfillPendingRobuxStandUpgrade(player, "plus25", BrainrotStandConfig.PLUS_25_LEVEL_GAIN)
	if ok then
		upgradeFeedbackRE:FireClient(player, true, "ok")
	end
	return if ok
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end)

ProductHandlerServer.registerProductReceipt(BrainrotStandConfig.CANT_AFFORD_DEV_PRODUCT_ID, function(player: Player)
	local ok = fulfillPendingRobuxStandUpgrade(player, "cant_afford", BrainrotStandConfig.NORMAL_LEVEL_GAIN)
	if ok then
		upgradeFeedbackRE:FireClient(player, true, "ok")
	end
	return if ok
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end)

ProductHandlerServer.registerProductReceipt(OfflineEarningsConfig.DOUBLE_DEV_PRODUCT_ID, function(player: Player)
	local ok = grantOfflineDouble(player)
	return if ok
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end)

declineOfflineEarningsRE.OnServerEvent:Connect(function(player: Player)
	if pendingOfflineDoubleOffer[player] then
		commitOfflinePendingToPads(player)
	end
	pendingOfflineDoubleOffer[player] = nil
end)
