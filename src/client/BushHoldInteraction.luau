--[[
	Bush harvest — closest-bush targeting, highlight, hold-to-search.
	Engine ProximityPrompt handles hold/trigger; ProximityPromptEffects draws the custom bush card + FX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CarryGate = require(script.Parent.CarryGate)
local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)

local player = Players.LocalPlayer

-- Must stand near the bush; keep in sync with BushHarvest.server MAX_HARVEST_RANGE.
local MAX_RANGE = 14
-- Cooldown timer / red lock can be seen from farther than search range.
local COOLDOWN_UI_MAX_RANGE = 56
-- Red outline + cooldown clock: after stepping back from point-blank (still within MAX_RANGE).
local COOLDOWN_VFX_MIN_DIST = 2.5
-- Right after a search, keep lock visuals (red outline + timer) for this long even when still close.
local POST_HARVEST_LOCK_VFX_SEC = 10
local HOLD_DURATION = 1.15
local POST_HARVEST_COOLDOWN_MIN = 10
local POST_HARVEST_COOLDOWN_MAX = 15
local BUSH_MANAGED_ATTR = "BushManagedPrompt"
local AIM_STEP = "BushAimStep"
local BUSH_FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }

local bushByModel: { [Model]: ProximityPrompt } = {}
local bushAnchor: { [Model]: BasePart } = {}
local pendingParts: { [Model]: RBXScriptConnection } = {}
local cooldownUntil: { [Model]: number } = {} -- os.clock() when search is allowed again
-- After harvest: show red + clock at any distance <= MAX_RANGE until this time (then min-dist rule applies).
local harvestLockVisualUntil: { [Model]: number } = {}
local lastHarvestAt = 0
local lastHarvestPrompt: ProximityPrompt? = nil

local aimHighlight: Highlight? = nil
local harvestRemote: RemoteEvent? = nil
local hooked = false
local mapWatchRoot: Instance? = nil

local activeBush: Model? = nil
local activePrompt: ProximityPrompt? = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function isBushFolderName(name: string): boolean
	for _, n in BUSH_FOLDER_NAMES do
		if name == n then
			return true
		end
	end
	return false
end

local function isForeignSearchPrompt(d: ProximityPrompt): boolean
	if d:GetAttribute(BUSH_MANAGED_ATTR) == true then
		return false
	end
	return d.Name == "Search"
		or (d.ActionText == "Search" and d.ObjectText == "Bush")
		or CarryGate.isBushSearchPrompt(d)
end

local function anchorFor(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
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

local function bushRootFromPrompt(prompt: ProximityPrompt): Model?
	local node: Instance? = prompt.Parent
	local best: Model? = nil
	while node do
		if node:IsA("Model") then
			best = node :: Model
		end
		node = node.Parent
	end
	return best
end

local function stripExtraPrompts(root: Model, keep: ProximityPrompt?)
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

local function attachPrompt(root: Model)
	if bushByModel[root] then
		return
	end
	local anchor = anchorFor(root)
	if not anchor then
		return
	end

	stripExtraPrompts(root, nil)

	local att = Instance.new("Attachment")
	att.Name = "_BushPromptCenter"
	att.Parent = anchor
	local center = select(1, root:GetBoundingBox()).Position
	att.Position = anchor.CFrame:PointToObjectSpace(center)

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

	task.defer(function()
		stripExtraPrompts(root, bushByModel[root])
	end)
end

local function registerBushModel(root: Model)
	if bushByModel[root] then
		return
	end
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

local function registerFromSearchPrompt(prompt: ProximityPrompt)
	local root = bushRootFromPrompt(prompt)
	if not root then
		return
	end
	registerBushModel(root)
end

local function purgeForeignUnder(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ProximityPrompt") and isForeignSearchPrompt(d) then
			d:Destroy()
		end
	end
end

local function collectBushFolders(map: Instance): { Folder }
	local out: { Folder } = {}
	for _, desc in map:GetDescendants() do
		if desc:IsA("Folder") and isBushFolderName(desc.Name) then
			table.insert(out, desc :: Folder)
		end
	end
	return out
end

local function registerBushesUnderFolder(folder: Folder)
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			registerBushModel(child :: Model)
		end
	end
	for _, desc in folder:GetDescendants() do
		if desc:IsA("ProximityPrompt") and isForeignSearchPrompt(desc) then
			registerFromSearchPrompt(desc)
		end
	end
end

local function registerAllBushesOnMap(map: Instance)
	purgeForeignUnder(map)

	for _, folder in collectBushFolders(map) do
		registerBushesUnderFolder(folder)
	end

	for _, desc in map:GetDescendants() do
		if desc:IsA("ProximityPrompt") and isForeignSearchPrompt(desc) then
			registerFromSearchPrompt(desc)
		end
	end
end

-- ── Targeting ─────────────────────────────────────────────────────────────────

local function pickClosest(): (Model?, ProximityPrompt?, BasePart?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil, nil
	end
	local pos = hrp.Position
	local now = os.clock()
	local bestM: Model? = nil
	local bestP: ProximityPrompt? = nil
	local bestA: BasePart? = nil
	local bestD = math.huge

	for model, prompt in bushByModel do
		if not model.Parent then
			cooldownUntil[model] = nil
			harvestLockVisualUntil[model] = nil
			continue
		end
		if cooldownUntil[model] and now < cooldownUntil[model] then
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

local function pickClosestCooldownBush(): (Model?, ProximityPrompt?, BasePart?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil, nil
	end
	local pos = hrp.Position
	local now = os.clock()
	local bestM: Model? = nil
	local bestP: ProximityPrompt? = nil
	local bestA: BasePart? = nil
	local bestD = math.huge

	for model, prompt in bushByModel do
		if not model.Parent then
			cooldownUntil[model] = nil
			harvestLockVisualUntil[model] = nil
			continue
		end
		local untilT = cooldownUntil[model]
		if not untilT or now >= untilT then
			harvestLockVisualUntil[model] = nil
			continue
		end
		local wp = promptWorldPos(prompt)
		if wp == Vector3.zero then
			continue
		end
		local d = (wp - pos).Magnitude
		if d > COOLDOWN_UI_MAX_RANGE then
			continue
		end
		local grace = harvestLockVisualUntil[model]
		local graceActive = typeof(grace) == "number" and now < grace
		if not graceActive and d < COOLDOWN_VFX_MIN_DIST then
			continue
		end
		if d < bestD then
			bestD = d
			bestM = model
			bestP = prompt
			bestA = bushAnchor[model] or anchorFor(model)
		end
	end

	return bestM, bestP, bestA
end

local function setActive(bush: Model?, prompt: ProximityPrompt?, _anchor: BasePart?)
	local carryBlock = CarryGate.isCarrying()
	local effectivePrompt = if carryBlock then nil else prompt
	local changed = activeBush ~= bush or activePrompt ~= effectivePrompt

	if changed then
		activeBush = bush
		activePrompt = effectivePrompt
		setAllBushPromptsEnabled(effectivePrompt)
		ProximityPromptEffects.suppressBushSearchUi(effectivePrompt)
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

local function doHarvest(prompt: ProximityPrompt)
	local now = os.clock()
	if lastHarvestPrompt == prompt and now - lastHarvestAt < 0.35 then
		return
	end
	if CarryGate.isCarrying() then
		return
	end
	lastHarvestPrompt = prompt
	lastHarvestAt = now
	local bush: Model? = nil
	for model, pr in bushByModel do
		if pr == prompt then
			bush = model
			break
		end
	end
	if not bush then
		return
	end

	cooldownUntil[bush] = now + math.random(POST_HARVEST_COOLDOWN_MIN, POST_HARVEST_COOLDOWN_MAX)
	harvestLockVisualUntil[bush] = now + POST_HARVEST_LOCK_VFX_SEC
	setActive(nil, nil, nil)

	local rem = getHarvestRemote()
	if rem then
		rem:FireServer(promptWorldPos(prompt))
	end
end

local HIGHLIGHT_READY = Color3.fromRGB(72, 255, 140)
-- Match cooldown card stroke so “locked” reads as the same red treatment.
local HIGHLIGHT_LOCKED = Color3.fromRGB(255, 45, 45)

local function tickAim()
	local hl = aimHighlight
	if hl and hl.Parent ~= workspace.CurrentCamera then
		hl.Parent = workspace.CurrentCamera
	end

	if mapWatchRoot and mapWatchRoot.Parent then
		local bushN = 0
		for _ in bushByModel do
			bushN += 1
		end
		if bushN == 0 then
			registerAllBushesOnMap(mapWatchRoot)
		end
	end

	-- While carrying a haul, you can’t start a new bush search — but cooldown lock visuals
	-- (red outline + timer) should stay until you leave range / time ends, not vanish when the brainrot pops in.
	local bush: Model?, prompt: ProximityPrompt?, anchor: BasePart?
	if CarryGate.isCarrying() then
		bush, prompt, anchor = nil, nil, nil
	else
		bush, prompt, anchor = pickClosest()
	end
	if bush then
		ProximityPromptEffects.hideBushCooldownBanner()
		if hl then
			hl.Adornee = bush
			hl.Enabled = true
			hl.OutlineColor = HIGHLIGHT_READY
		end
		setActive(bush, prompt, anchor)
		return
	end

	local cBush, cPrompt, _cAnchor = pickClosestCooldownBush()
	if cBush and cPrompt then
		local ends = cooldownUntil[cBush]
		if typeof(ends) == "number" then
			ProximityPromptEffects.showBushCooldownBanner(cPrompt, ends)
		end
		if hl then
			hl.Adornee = cBush
			hl.Enabled = true
			hl.OutlineColor = HIGHLIGHT_LOCKED
		end
		setActive(nil, nil, nil)
		return
	end

	ProximityPromptEffects.hideBushCooldownBanner()
	if hl then
		hl.Enabled = false
		hl.Adornee = nil
		hl.OutlineColor = HIGHLIGHT_READY
	end
	setActive(nil, nil, nil)
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
		elseif desc:IsA("Model") and desc.Parent and desc.Parent:IsA("Folder") and isBushFolderName(desc.Parent.Name) then
			task.defer(function()
				registerBushModel(desc :: Model)
			end)
		end
	end)
end

local function bootMap(map: Instance)
	wireMapWatch(map)
	registerAllBushesOnMap(map)
	local n = 0
	for _, _ in bushByModel do
		n += 1
	end
	if n == 0 then
		warn("[BushHoldInteraction] No bush prompts yet — waiting for Map/Tycoon to finish loading bushes")
	else
		print(string.format("[BushHoldInteraction] Registered %d bush search prompt(s)", n))
	end
end

-- ── Init ─────────────────────────────────────────────────────────────────────-

local BushHoldInteraction = {}

function BushHoldInteraction.init()
	if hooked then
		return
	end
	hooked = true

	ProximityPromptEffects.setBushHoldCompleteHandler(doHarvest)

	local pg = player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in { "BushSearchUI", "BushSearchPrompt", "BushSearchSharedPrompt", "CustomProximityPrompt", "BushCooldownBanner" } do
			local legacy = pg:FindFirstChild(name)
			if legacy then
				legacy:Destroy()
			end
		end
	end

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("BushRemotes", 60)
		if folder then
			local ev = folder:WaitForChild("HarvestBrainrot", 30)
			if ev and ev:IsA("RemoteEvent") then
				harvestRemote = ev
			end
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

	RunService:BindToRenderStep(AIM_STEP, Enum.RenderPriority.Input.Value + 1, tickAim)

	local function onCarryChanged()
		if CarryGate.isCarrying() then
			setActive(nil, nil, nil)
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

	task.spawn(function()
		local map = workspace:WaitForChild("Map", 120)
		if not map then
			warn("[BushHoldInteraction] workspace.Map missing — bush search disabled")
			return
		end
		bootMap(map)
		map.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				mapWatchRoot = nil
			end
		end)
		task.defer(function()
			if map.Parent then
				registerAllBushesOnMap(map)
			end
		end)
	end)
end

return BushHoldInteraction
