-- [ACTIVE] BushHoldInteraction
--[[
	Bush harvest — closest-bush targeting, highlight, hold-to-search.
	Engine ProximityPrompt handles hold/trigger; ProximityPromptEffects draws the custom bush card + FX.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BushShiver = require(script.Parent.BushShiver)
local BushRootUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushRootUtil"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local CarryGate = require(script.Parent.CarryGate)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local player = Players.LocalPlayer

-- Must stand near the bush; keep in sync with BushHarvest.server MAX_HARVEST_RANGE.
local MAX_RANGE = 14
local HOLD_DURATION = 1.15
local BUSH_MANAGED_ATTR = "BushManagedPrompt"
local BUSH_ON_COOLDOWN_ATTR = "BushOnCooldown"
local BUSH_LOOT_PHASE_ATTR = "BushLootPhase"
local BUSH_COOLDOWN_ENDS_ATTR = "BushCooldownEndsAt"
local BUSH_LOOT_PHASE_COOLDOWN = "cooldown"
local BUSH_FLOATING_CLAIM_ATTR = "BushFloatingClaimActive"
local AIM_TICK_INTERVAL = 0.05
local PICK_FULL_SCAN_INTERVAL = 0.5
local COOLDOWN_VISUAL_SYNC_INTERVAL = 0.5
local BUSH_FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }

local bushByModel: { [Instance]: ProximityPrompt } = {}
local bushAnchor: { [Instance]: BasePart } = {}
local pendingParts: { [Instance]: RBXScriptConnection } = {}
local cooldownHighlights: { [Instance]: Highlight } = {}
local lastHarvestAt = 0
local lastHarvestPrompt: ProximityPrompt? = nil

local aimHighlight: Highlight? = nil
local aimTickAccum = 0
local harvestRemote: RemoteEvent? = nil
local harvestFunction: RemoteFunction? = nil
local hooked = false
local mapWatchRoot: Instance? = nil
local EMPTY_BUSH_RESCAN_INTERVAL = 8
local lastEmptyBushScanAt = 0
local bushMapScanInProgress = false
local lastPickFullScanAt = 0
local lastCooldownVisualSyncAt = 0
local bushSearchSuppressUntil = 0.0
local bushSearchLocked = false

local pendingBushRoots: { Instance } = {}
local pendingBushSet: { [Instance]: boolean } = {}
local bushRegisterBatchConn: RBXScriptConnection? = nil
local BUSH_REGISTER_PER_TICK = 6

local activeBush: Instance? = nil
local activePrompt: ProximityPrompt? = nil

-- External listeners (e.g. X-Ray Vision) notified whenever the targeted bush changes.
local activeBushListeners: { (Instance?) -> () } = {}
local bushOutlineColorProvider: ((Instance) -> Color3?)? = nil
local bushOutlineGradientProvider: ((Instance) -> ColorSequence?)? = nil
local function notifyActiveBushChanged(bush: Instance?)
	for _, cb in activeBushListeners do
		task.spawn(cb, bush)
	end
end

local BUSH_SEARCH_HOLD_ACTION = "BushSearchHoldWhileToolEquipped"
local bushSearchHoldPrompt: ProximityPrompt? = nil
local bushSearchHoldBeganAt = 0.0
local bushSearchHoldToken = 0

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function isBushInSearchCooldown(bush: Instance): boolean
	if bush:GetAttribute(BUSH_LOOT_PHASE_ATTR) == BUSH_LOOT_PHASE_COOLDOWN then
		return true
	end
	if bush:GetAttribute(BUSH_ON_COOLDOWN_ATTR) == true then
		return true
	end
	local endsAt = bush:GetAttribute(BUSH_COOLDOWN_ENDS_ATTR)
	return typeof(endsAt) == "number" and Workspace:GetServerTimeNow() < endsAt
end

local function isBushFolderName(name: string): boolean
	return BushRootUtil.isBushFolderName(name)
end

local function isForeignSearchPrompt(d: ProximityPrompt): boolean
	if d:GetAttribute(BUSH_MANAGED_ATTR) == true then
		return false
	end
	return d.Name == "Search"
		or (d.ActionText == "Search" and d.ObjectText == "Bush")
		or CarryGate.isBushSearchPrompt(d)
end

local function anchorFor(root: Instance): BasePart?
	local centerAnchor = BushRootUtil.ensurePromptAnchorPart(root)
	if centerAnchor then
		return centerAnchor
	end
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") then
		local model = root :: Model
		if model.PrimaryPart then
			return model.PrimaryPart
		end
		return model:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local BUSH_PROMPT_LIFT_SCALE = 0.66

local function bushPromptWorldPosition(root: Model): Vector3?
	return BushRootUtil.focusWorldPosition(root, BUSH_PROMPT_LIFT_SCALE)
end

local function promptWorldPos(prompt: ProximityPrompt): Vector3
	local p = prompt.Parent
	if p and p:IsA("Attachment") then
		return p.WorldPosition
	end
	if p and p:IsA("BasePart") then
		return p.Position
	end
	return Vector3.zero
end

local function bushRootFromPrompt(prompt: ProximityPrompt): Instance?
	return BushRootUtil.resolveBushRootFromPrompt(prompt)
end

local function stripExtraPrompts(root: Instance, keep: ProximityPrompt?)
	for _, d in root:GetDescendants() do
		if d:IsA("ProximityPrompt") and d ~= keep then
			d:Destroy()
		end
	end
end

local function setAllBushPromptsEnabled(enabledPrompt: ProximityPrompt?)
	for _, p in bushByModel do
		if p.Parent then
			p.Enabled = p == enabledPrompt
		end
	end
end

local function attachPrompt(root: Instance)
	if bushByModel[root] then
		return
	end
	local anchor = anchorFor(root)
	if not anchor then
		return
	end

	local att = Instance.new("Attachment")
	att.Name = "_BushPromptCenter"
	att.Position = Vector3.zero
	att.Parent = anchor

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BushHarvestPrompt"
	prompt.ActionText = "Search"
	prompt.ObjectText = "Bush"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = HOLD_DURATION
	prompt.MaxActivationDistance = MAX_RANGE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Enabled = true
	prompt:SetAttribute(BUSH_MANAGED_ATTR, true)
	pcall(function()
		(prompt :: any).ClickablePrompt = true
	end)
	prompt.Parent = att

	ProximityPromptEffects.stylePrompt(prompt)

	bushByModel[root] = prompt
	bushAnchor[root] = anchor

	root.DescendantAdded:Connect(function(ch)
		if ch:IsA("ProximityPrompt") and ch ~= bushByModel[root] then
			ch:Destroy()
		end
	end)
end

local bushCooldownConns: { [Instance]: { RBXScriptConnection } } = {}
local syncCooldownVisuals: () -> () = function() end

local function wireBushCooldownSignals(root: Instance)
	if bushCooldownConns[root] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	local function bump()
		task.defer(syncCooldownVisuals)
	end
	table.insert(conns, root:GetAttributeChangedSignal(BUSH_LOOT_PHASE_ATTR):Connect(bump))
	table.insert(conns, root:GetAttributeChangedSignal(BUSH_ON_COOLDOWN_ATTR):Connect(bump))
	table.insert(conns, root:GetAttributeChangedSignal(BUSH_COOLDOWN_ENDS_ATTR):Connect(bump))
	bushCooldownConns[root] = conns
	root.Destroying:Once(function()
		local existing = bushCooldownConns[root]
		if existing then
			for _, conn in existing do
				conn:Disconnect()
			end
			bushCooldownConns[root] = nil
		end
	end)
end

local function registerBushRootNow(root: Instance)
	if not BushRootUtil.isDirectBushRoot(root) then
		return
	end
	if bushByModel[root] then
		return
	end
	BushShiver.trackBush(root)
	wireBushCooldownSignals(root)
	if anchorFor(root) then
		attachPrompt(root)
		return
	end
	if pendingParts[root] then
		return
	end
	pendingParts[root] = root.DescendantAdded:Connect(function()
		if anchorFor(root) then
			pendingParts[root]:Disconnect()
			pendingParts[root] = nil
			attachPrompt(root)
		end
	end)
end

local function ensureBushRegisterBatchLoop()
	if bushRegisterBatchConn then
		return
	end
	bushRegisterBatchConn = RunService.Heartbeat:Connect(function()
		local processed = 0
		while processed < BUSH_REGISTER_PER_TICK and #pendingBushRoots > 0 do
			local root = table.remove(pendingBushRoots, 1)
			pendingBushSet[root] = nil
			if root.Parent then
				registerBushRootNow(root)
			end
			processed += 1
		end
		if #pendingBushRoots == 0 and bushRegisterBatchConn then
			bushRegisterBatchConn:Disconnect()
			bushRegisterBatchConn = nil
		end
	end)
end

local function registerBushRoot(root: Instance)
	if not BushRootUtil.isDirectBushRoot(root) then
		return
	end
	if bushByModel[root] or pendingBushSet[root] then
		return
	end
	pendingBushSet[root] = true
	table.insert(pendingBushRoots, root)
	ensureBushRegisterBatchLoop()
end

local function registerBushModel(root: Model)
	if BushRootUtil.isDirectBushRoot(root) then
		registerBushRoot(root)
	end
end

local function registerFromSearchPrompt(prompt: ProximityPrompt)
	local root = bushRootFromPrompt(prompt)
	if not root then
		return
	end
	registerBushRoot(root)
end

local function registerBushesUnderFolder(folder: Folder)
	for _, child in folder:GetChildren() do
		if BushRootUtil.isDirectBushRoot(child) then
			registerBushRoot(child)
		elseif child:IsA("Model") then
			registerBushModel(child :: Model)
		end
	end
end

-- Walk map tree with GetChildren only — never GetDescendants (sync hitch on huge maps).
local function registerAllBushesOnMap(map: Instance)
	local bushFolders: { Folder } = {}
	local foreignPrompts: { ProximityPrompt } = {}
	local stack = { map }
	local count = 0
	while #stack > 0 do
		local inst = table.remove(stack)
		if inst ~= map then
			if inst:IsA("Folder") and isBushFolderName(inst.Name) then
				table.insert(bushFolders, inst :: Folder)
			elseif inst:IsA("ProximityPrompt") and isForeignSearchPrompt(inst) then
				table.insert(foreignPrompts, inst)
			elseif inst.Name == "BushEmptyMessage" then
				inst:Destroy()
			elseif inst.Name == "_BushEmptyMessageAnchor" and inst:IsA("BasePart") then
				inst:Destroy()
			end
		end
		for _, child in inst:GetChildren() do
			table.insert(stack, child)
		end
		count += 1
		if count % 400 == 0 then
			task.wait()
		end
	end

	for _, folder in bushFolders do
		registerBushesUnderFolder(folder)
	end
	for _, prompt in foreignPrompts do
		if prompt.Parent then
			registerFromSearchPrompt(prompt)
		end
	end
end

-- ── Targeting ─────────────────────────────────────────────────────────────────

local HIGHLIGHT_READY = Color3.fromRGB(72, 255, 140)
local HIGHLIGHT_LOCKED = Color3.fromRGB(255, 45, 45)

local function applyBushHighlight(hl: Highlight, bush: Instance, locked: boolean)
	hl.Adornee = bush
	hl.Enabled = true
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0
	if locked then
		hl.OutlineColor = HIGHLIGHT_LOCKED
	else
		local gradientSequence = if bushOutlineGradientProvider then bushOutlineGradientProvider(bush) else nil
		if gradientSequence then
			hl.OutlineColor = BrainrotHeaderStyle.sampleColorSequence(gradientSequence, (os.clock() * 0.42) % 1)
		else
			local custom = if bushOutlineColorProvider then bushOutlineColorProvider(bush) else nil
			hl.OutlineColor = custom or HIGHLIGHT_READY
		end
	end
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
end

local function bushHighlightInViewRange(model: Instance): boolean
	local prompt = bushByModel[model]
	if not prompt or not prompt.Parent then
		return false
	end
	return ProximityPromptEffects.isBushSearchInViewRange(prompt)
end

syncCooldownVisuals = function()
	for bush, hl in cooldownHighlights do
		if not bush.Parent or not isBushInSearchCooldown(bush) or not bushHighlightInViewRange(bush) then
			hl:Destroy()
			cooldownHighlights[bush] = nil
		end
	end

	local cam = workspace.CurrentCamera
	for model in bushByModel do
		if not model.Parent then
			continue
		end
		if model:GetAttribute(BUSH_FLOATING_CLAIM_ATTR) == true then
			local hl = cooldownHighlights[model]
			if hl then
				hl:Destroy()
				cooldownHighlights[model] = nil
			end
			continue
		end
		if not isBushInSearchCooldown(model) then
			continue
		end
		if not bushHighlightInViewRange(model) then
			local hl = cooldownHighlights[model]
			if hl then
				hl:Destroy()
				cooldownHighlights[model] = nil
			end
			continue
		end
		local hl = cooldownHighlights[model]
		if not hl then
			hl = Instance.new("Highlight")
			hl.Name = "BushCooldownHighlight"
			if cam then
				hl.Parent = cam
			end
			cooldownHighlights[model] = hl
		elseif cam and hl.Parent ~= cam then
			hl.Parent = cam
		end
		applyBushHighlight(hl, model, true)
	end

	ProximityPromptEffects.syncBushCooldownBanners(bushByModel)
end

local function syncCooldownVisualsIfDue(force: boolean?)
	local now = os.clock()
	if not force and now - lastCooldownVisualSyncAt < COOLDOWN_VISUAL_SYNC_INTERVAL then
		return
	end
	lastCooldownVisualSyncAt = now
	syncCooldownVisuals()
end

local function pickClosest(): (Instance?, ProximityPrompt?, BasePart?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil, nil
	end
	local pos = hrp.Position
	local now = os.clock()
	if now - lastPickFullScanAt < PICK_FULL_SCAN_INTERVAL then
		local bush = activeBush
		local prompt = activePrompt
		if bush and prompt and bush.Parent and prompt.Parent and not isBushInSearchCooldown(bush) then
			if bush:GetAttribute(BUSH_FLOATING_CLAIM_ATTR) == true then
				return nil, nil, nil
			end
			local wp = promptWorldPos(prompt)
			if wp ~= Vector3.zero and (wp - pos).Magnitude <= MAX_RANGE then
				return bush, prompt, bushAnchor[bush] or anchorFor(bush)
			end
		end
		return nil, nil, nil
	end
	lastPickFullScanAt = now

	local bestM: Instance? = nil
	local bestP: ProximityPrompt? = nil
	local bestA: BasePart? = nil
	local bestD = math.huge

	for model, prompt in bushByModel do
		if not model.Parent then
			continue
		end
		if model:GetAttribute(BUSH_FLOATING_CLAIM_ATTR) == true then
			continue
		end
		if isBushInSearchCooldown(model) then
			continue
		end
		local wp = promptWorldPos(prompt)
		if wp == Vector3.zero then
			continue
		end
		local d = (wp - pos).Magnitude
		if d <= MAX_RANGE and d < bestD then
			bestD = d
			bestM = model
			bestP = prompt
			bestA = bushAnchor[model] or anchorFor(model)
		end
	end

	return bestM, bestP, bestA
end

local function setActive(bush: Instance?, prompt: ProximityPrompt?, _anchor: BasePart?)
	local carryBlock = CarryGate.isFull()
	if carryBlock and bushSearchHoldPrompt then
		ProximityPromptEffects.endManagedBushHold(bushSearchHoldPrompt, false)
		bushSearchHoldPrompt = nil
	end
	local effectivePrompt = if carryBlock then nil else prompt
	local changed = activeBush ~= bush or activePrompt ~= effectivePrompt

	if changed then
		activeBush = bush
		activePrompt = effectivePrompt
		setAllBushPromptsEnabled(effectivePrompt)
		ProximityPromptEffects.suppressBushSearchUi(effectivePrompt)
		GameSoundEffects.syncBushAura(bush)
		notifyActiveBushChanged(bush)
	end
end

-- ── Harvest ───────────────────────────────────────────────────────────────────

local function getHarvestRemote(): RemoteEvent?
	if harvestRemote and harvestRemote.Parent then
		return harvestRemote
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		return nil
	end
	local ev = folder:FindFirstChild("HarvestBrainrot")
	if ev and ev:IsA("RemoteEvent") then
		harvestRemote = ev
		return ev
	end
	return nil
end

local function getHarvestFunction(): RemoteFunction?
	if harvestFunction and harvestFunction.Parent then
		return harvestFunction
	end
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes")
	if not folder then
		return nil
	end
	local fn = folder:FindFirstChild("HarvestBush")
	if fn and fn:IsA("RemoteFunction") then
		harvestFunction = fn
		return fn
	end
	return nil
end

local bushSearchInFlight: { [Instance]: boolean } = {}

--[[ Server-authoritative 50/50 roll via HarvestBush RemoteFunction. ]]
local function requestBushSearch(worldPos: Vector3, bush: Instance): any
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes") or ReplicatedStorage:WaitForChild("BushRemotes", 8)
	if not folder then
		return nil
	end

	local rf = folder:FindFirstChild("HarvestBush") or folder:WaitForChild("HarvestBush", 8)
	if rf and rf:IsA("RemoteFunction") then
		harvestFunction = rf
		local ok, result = pcall(function()
			return rf:InvokeServer(worldPos, bush)
		end)
		if ok then
			return result
		end
		warn("[BushHoldInteraction] HarvestBush InvokeServer failed:", result)
	end

	local rem = folder:FindFirstChild("HarvestBrainrot")
	if rem and rem:IsA("RemoteEvent") then
		harvestRemote = rem
		rem:FireServer(worldPos, bush)
		return { ok = true, viaRemoteEvent = true }
	end

	return nil
end

local function doHarvest(prompt: ProximityPrompt)
	local now = os.clock()
	if lastHarvestPrompt == prompt and now - lastHarvestAt < 0.35 then
		return
	end
	if CarryGate.isFull() then
		return
	end
	lastHarvestPrompt = prompt
	lastHarvestAt = now
	local bush: Instance? = bushRootFromPrompt(prompt)
	if not bush then
		for model, pr in bushByModel do
			if pr == prompt then
				bush = model
				break
			end
		end
	end
	if bush then
		bush = BushRootUtil.resolveBushRoot(bush) or bush
	end
	if not bush then
		return
	end
	if bushSearchInFlight[bush] then
		return
	end
	bushSearchInFlight[bush] = true
	task.delay(0.5, function()
		bushSearchInFlight[bush] = nil
	end)

	setActive(nil, nil, nil)

	local result = requestBushSearch(promptWorldPos(prompt), bush)
	if typeof(result) == "table" then
		local cooldownEndsAt = result.cooldownEndsAt
		if typeof(cooldownEndsAt) == "number" and cooldownEndsAt > Workspace:GetServerTimeNow() then
			bush:SetAttribute(BUSH_ON_COOLDOWN_ATTR, true)
			bush:SetAttribute(BUSH_LOOT_PHASE_ATTR, BUSH_LOOT_PHASE_COOLDOWN)
			bush:SetAttribute(BUSH_COOLDOWN_ENDS_ATTR, cooldownEndsAt)
			if result.found ~= true then
				ProximityPromptEffects.showBushCooldownBanner(prompt, cooldownEndsAt)
			end
		end
		-- Empty-bush message is shown server-side (BushHarvest.showEmptyBushMessage).
	end
end

local function tickAim()
	local hl = aimHighlight
	local cam = workspace.CurrentCamera
	if hl and cam and hl.Parent ~= cam then
		hl.Parent = cam
	end

	if bushSearchLocked or os.clock() < bushSearchSuppressUntil then
		if activeBush or activePrompt then
			setActive(nil, nil, nil)
		end
		if hl then
			hl.Enabled = false
			hl.Adornee = nil
		end
		GameSoundEffects.syncBushAura(nil)
		return
	end

	if mapWatchRoot and mapWatchRoot.Parent then
		local bushN = 0
		for _ in bushByModel do
			bushN += 1
		end
		if bushN == 0 and not bushMapScanInProgress and #pendingBushRoots == 0 then
			local now = os.clock()
			if now - lastEmptyBushScanAt >= EMPTY_BUSH_RESCAN_INTERVAL then
				lastEmptyBushScanAt = now
				scheduleBushMapScan(mapWatchRoot)
			end
		end
	end

	local now = os.clock()
	for model in bushByModel do
		if model.Parent and (model == activeBush or isBushInSearchCooldown(model)) then
			BushRootUtil.ensurePromptAnchorPart(model)
		end
	end
	syncCooldownVisualsIfDue(false)

	-- Block new bush search only at carry capacity; cooldown lock visuals still update while partially loaded.
	local bush: Instance?, prompt: ProximityPrompt?, anchor: BasePart?
	if CarryGate.isFull() then
		bush, prompt, anchor = nil, nil, nil
	else
		bush, prompt, anchor = pickClosest()
		if bush and prompt and not ProximityPromptEffects.isBushSearchNearPlayer(prompt) then
			bush, prompt, anchor = nil, nil, nil
		end
	end
	if bush then
		if hl then
			applyBushHighlight(hl, bush, false)
		end
		setActive(bush, prompt, anchor)
		GameSoundEffects.syncBushAura(bush)
		return
	end

	if hl then
		hl.Enabled = false
		hl.Adornee = nil
		hl.OutlineColor = HIGHLIGHT_READY
	end
	setActive(nil, nil, nil)
	GameSoundEffects.syncBushAura(nil)
end

-- ── Map boot ─────────────────────────────────────────────────────────────────-

local function wireMapWatch(map: Instance)
	if mapWatchRoot == map then
		return
	end
	mapWatchRoot = map

	map.DescendantAdded:Connect(function(desc)
		if desc:IsA("Folder") and isBushFolderName(desc.Name) then
			task.defer(function()
				registerBushesUnderFolder(desc :: Folder)
			end)
		elseif desc:IsA("ProximityPrompt") and isForeignSearchPrompt(desc) then
			task.defer(function()
				registerFromSearchPrompt(desc)
			end)
		elseif desc.Parent and desc.Parent:IsA("Folder") and isBushFolderName(desc.Parent.Name) then
			if BushRootUtil.isDirectBushRoot(desc) then
				task.defer(function()
					registerBushRoot(desc)
				end)
			end
		end
	end)
end

local function scheduleBushMapScan(map: Instance)
	if bushMapScanInProgress then
		return
	end
	bushMapScanInProgress = true
	task.spawn(function()
		registerAllBushesOnMap(map)
		lastEmptyBushScanAt = os.clock()
		bushMapScanInProgress = false
		local n = 0
		for _, _ in bushByModel do
			n += 1
		end
		if n == 0 then
			warn("[BushHoldInteraction] No bush prompts yet — waiting for Map/Tycoon to finish loading bushes")
		end
	end)
end

local function bootMap(map: Instance)
	wireMapWatch(map)
	scheduleBushMapScan(map)
end

-- ── Init ─────────────────────────────────────────────────────────────────────-

local BushHoldInteraction = {}

function BushHoldInteraction.getActiveBush(): Instance?
	return activeBush
end

-- Register a callback fired with the targeted bush (or nil when none). Fires once immediately.
function BushHoldInteraction.onActiveBushChanged(callback: (Instance?) -> ())
	table.insert(activeBushListeners, callback)
	task.spawn(callback, activeBush)
end

function BushHoldInteraction.setBushOutlineColorProvider(provider: ((Instance) -> Color3?)?)
	bushOutlineColorProvider = provider
end

function BushHoldInteraction.setBushOutlineGradientProvider(provider: ((Instance) -> ColorSequence?)?)
	bushOutlineGradientProvider = provider
end

function BushHoldInteraction.init()
	if hooked then
		return
	end
	hooked = true

	BushShiver.init()
	ProximityPromptEffects.setBushHoldCompleteHandler(doHarvest)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in
			{
				"BushSearchUI",
				"BushSearchPrompt",
				"BushSearchSharedPrompt",
				"CustomProximityPrompt",
				"BushCooldownBanner",
			}
		do
			local legacy = pg:FindFirstChild(name)
			if legacy then
				legacy:Destroy()
			end
		end
	end

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("BushRemotes", 60)
		if not folder then
			return
		end
		local fn = folder:WaitForChild("HarvestBush", 30)
		if fn and fn:IsA("RemoteFunction") then
			harvestFunction = fn
		end
		local ev = folder:WaitForChild("HarvestBrainrot", 30)
		if ev and ev:IsA("RemoteEvent") then
			harvestRemote = ev
		end
	end)

	if not aimHighlight then
		aimHighlight = Instance.new("Highlight")
		aimHighlight.Name = "BushAimHighlight"
		aimHighlight.FillTransparency = 1
		aimHighlight.OutlineColor = Color3.fromRGB(72, 255, 140)
		aimHighlight.OutlineTransparency = 0
		aimHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		aimHighlight.Enabled = false
		aimHighlight.Parent = workspace.CurrentCamera
	end

	RunService.Heartbeat:Connect(function(dt)
		aimTickAccum += dt
		if aimTickAccum < AIM_TICK_INTERVAL then
			return
		end
		aimTickAccum = 0
		tickAim()
	end)

	-- Engine ProximityPrompt hold is blocked while a brainrot Tool is equipped; run the hold ourselves.
	ContextActionService:BindActionAtPriority(BUSH_SEARCH_HOLD_ACTION, function(_name, state, input)
		if bushSearchLocked or os.clock() < bushSearchSuppressUntil then
			return Enum.ContextActionResult.Pass
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		local prompt = activePrompt
		if not prompt or not prompt.Parent or not prompt.Enabled or CarryGate.isFull() then
			if state == Enum.UserInputState.End and bushSearchHoldPrompt then
				ProximityPromptEffects.endManagedBushHold(bushSearchHoldPrompt, false)
				bushSearchHoldPrompt = nil
			end
			return Enum.ContextActionResult.Pass
		end
		if
			input.UserInputType ~= Enum.UserInputType.Keyboard
			and input.UserInputType ~= Enum.UserInputType.Gamepad1
		then
			return Enum.ContextActionResult.Pass
		end
		local keyOk = input.KeyCode == Enum.KeyCode.E or input.KeyCode == prompt.KeyboardKeyCode
		local padOk = prompt.GamepadKeyCode ~= Enum.KeyCode.Unknown and input.KeyCode == prompt.GamepadKeyCode
		if not keyOk and not padOk then
			return Enum.ContextActionResult.Pass
		end

		if state == Enum.UserInputState.Begin then
			bushSearchHoldPrompt = prompt
			bushSearchHoldBeganAt = os.clock()
			bushSearchHoldToken += 1
			local token = bushSearchHoldToken
			local holdPrompt = prompt

			ProximityPromptEffects.beginManagedBushHold(holdPrompt)

			-- Hard completion path: do not depend on the custom UI, PromptTriggered, or key release.
			-- If the player keeps holding long enough, the harvest request fires exactly once.
			task.delay(math.max(0.05, holdPrompt.HoldDuration), function()
				if bushSearchHoldToken ~= token then
					return
				end
				if bushSearchHoldPrompt ~= holdPrompt then
					return
				end
				if not holdPrompt.Parent or not holdPrompt.Enabled or CarryGate.isFull() then
					return
				end

				ProximityPromptEffects.endManagedBushHold(holdPrompt, true)
				task.defer(doHarvest, holdPrompt)
				bushSearchHoldPrompt = nil
			end)

			return Enum.ContextActionResult.Sink
		end

		if state == Enum.UserInputState.End and bushSearchHoldPrompt == prompt then
			local dur = prompt.HoldDuration
			local completed = dur > 0 and (os.clock() - bushSearchHoldBeganAt) >= dur * 0.92
			bushSearchHoldToken += 1
			ProximityPromptEffects.endManagedBushHold(prompt, completed)

			-- Backup for normal release completion. The timed completion above handles the
			-- common case where the player keeps holding until the bar finishes.
			if completed then
				task.defer(doHarvest, prompt)
			end

			bushSearchHoldPrompt = nil
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.E, Enum.KeyCode.ButtonX)

	-- Extra safety: if Roblox's real ProximityPrompt fires, harvest directly here too.
	-- doHarvest has a debounce, so this will not duplicate rewards.
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggerPlayer: Player)
		if triggerPlayer ~= player then
			return
		end
		if prompt:GetAttribute(BUSH_MANAGED_ATTR) ~= true then
			return
		end
		task.defer(doHarvest, prompt)
	end)

	local function onCarryChanged()
		if CarryGate.isFull() then
			setActive(nil, nil, nil)
		else
			aimTickAccum = AIM_TICK_INTERVAL
		end
	end
	player:GetAttributeChangedSignal("Carry"):Connect(onCarryChanged)
	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(onCarryChanged)
	player.CharacterAdded:Connect(function(char)
		char.DescendantAdded:Connect(onCarryChanged)
		char.DescendantRemoving:Connect(onCarryChanged)
		onCarryChanged()
	end)
	if player.Character then
		onCarryChanged()
	end

	local function startMap(map: Instance)
		bootMap(map)
		map.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				mapWatchRoot = nil
			end
		end)
	end

	local existingMap = workspace:FindFirstChild("Map")
	if existingMap then
		startMap(existingMap)
	else
		task.spawn(function()
			local map = workspace:WaitForChild("Map", 120)
			if not map then
				warn("[BushHoldInteraction] workspace.Map missing — bush search disabled")
				return
			end
			startMap(map)
		end)
	end
end

local function bushHarvestKey(root: Instance): string
	local pos = if root:IsA("BasePart") then root.Position else root:GetPivot().Position
	return string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z)
end

function BushHoldInteraction.findBushByHarvestKey(key: string): Instance?
	if typeof(key) ~= "string" or key == "" then
		return nil
	end
	for bush in bushByModel do
		if bush.Parent and bushHarvestKey(bush) == key then
			return bush
		end
	end
	return nil
end

function BushHoldInteraction.getPromptForBush(bush: Instance): ProximityPrompt?
	return bushByModel[bush]
end

function BushHoldInteraction.refreshCooldownVisuals()
	syncCooldownVisualsIfDue(true)
end

function BushHoldInteraction.suppressBushSearchBriefly(durationSec: number)
	bushSearchSuppressUntil = os.clock() + math.max(durationSec, 0.25)
	setActive(nil, nil, nil)
	ProximityPromptEffects.hideBushSearch()
end

function BushHoldInteraction.setBushSearchLocked(locked: boolean)
	bushSearchLocked = locked == true
	if bushSearchLocked then
		if bushSearchHoldPrompt then
			ProximityPromptEffects.endManagedBushHold(bushSearchHoldPrompt, false)
			bushSearchHoldPrompt = nil
		end
		setActive(nil, nil, nil)
		ProximityPromptEffects.hideBushSearch()
	end
end

function BushHoldInteraction.isBushSearchLocked(): boolean
	return bushSearchLocked
end

return BushHoldInteraction
