--[[
	Bush harvest — closest-bush targeting, highlight, hold-to-search.
	Engine ProximityPrompt handles hold/trigger; ProximityPromptEffects draws the custom bush card + FX.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BushShiver = require(script.Parent.BushShiver)
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
local AIM_TICK_INTERVAL = 0.1
local BUSH_FOLDER_NAMES = { "BushSCRIPTs", "BushSCRIPT" }

local bushByModel: { [Instance]: ProximityPrompt } = {}
local bushAnchor: { [Instance]: BasePart } = {}
local pendingParts: { [Instance]: RBXScriptConnection } = {}
local cooldownUntil: { [Instance]: number } = {} -- os.clock() when search is allowed again
-- After harvest: show red + clock at any distance <= MAX_RANGE until this time (then min-dist rule applies).
local harvestLockVisualUntil: { [Instance]: number } = {}
local lastHarvestAt = 0
local lastHarvestPrompt: ProximityPrompt? = nil

local aimHighlight: Highlight? = nil
local aimTickAccum = 0
local harvestRemote: RemoteEvent? = nil
local harvestFunction: RemoteFunction? = nil
local hooked = false
local mapWatchRoot: Instance? = nil

local activeBush: Instance? = nil
local activePrompt: ProximityPrompt? = nil

local BUSH_SEARCH_HOLD_ACTION = "BushSearchHoldWhileToolEquipped"
local bushSearchHoldPrompt: ProximityPrompt? = nil
local bushSearchHoldBeganAt = 0.0

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

local function anchorFor(root: Instance): BasePart?
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
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local foundPart = false

	for _, desc in root:GetDescendants() do
		if desc:IsA("BasePart") then
			foundPart = true
			local cf = desc.CFrame
			local h = desc.Size * 0.5
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local wp = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						minX = math.min(minX, wp.X)
						minY = math.min(minY, wp.Y)
						minZ = math.min(minZ, wp.Z)
						maxX = math.max(maxX, wp.X)
						maxY = math.max(maxY, wp.Y)
						maxZ = math.max(maxZ, wp.Z)
					end
				end
			end
		end
	end

	if foundPart then
		local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
		local height = math.max(0.5, maxY - minY)
		return center + Vector3.new(0, height * BUSH_PROMPT_LIFT_SCALE, 0)
	end

	local ok, cf, size = pcall(function()
		return root:GetBoundingBox()
	end)
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		return cf.Position + Vector3.new(0, size.Y * BUSH_PROMPT_LIFT_SCALE, 0)
	end
	return nil
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
	local node: Instance? = prompt.Parent
	while node do
		if node.Name == "BushSCRIPT" and (node:IsA("Model") or node:IsA("BasePart")) then
			return node
		end
		node = node.Parent
	end
	return nil
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

	stripExtraPrompts(root, nil)

	local att = Instance.new("Attachment")
	att.Name = "_BushPromptCenter"
	att.Parent = anchor
	local targetWorld: Vector3
	if root:IsA("Model") then
		targetWorld = bushPromptWorldPosition(root :: Model) or (anchor.Position + Vector3.new(0, 2, 0))
	else
		targetWorld = anchor.Position + Vector3.new(0, anchor.Size.Y * BUSH_PROMPT_LIFT_SCALE + 1, 0)
	end
	att.Position = anchor.CFrame:PointToObjectSpace(targetWorld)

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

local function registerBushRoot(root: Instance)
	if bushByModel[root] then
		return
	end
	BushShiver.trackBush(root)
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

local function registerBushModel(root: Model)
	registerBushRoot(root)
end

local function registerFromSearchPrompt(prompt: ProximityPrompt)
	local root = bushRootFromPrompt(prompt)
	if not root then
		return
	end
	registerBushRoot(root)
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
		if child.Name == "BushSCRIPT" and (child:IsA("Model") or child:IsA("BasePart")) then
			registerBushRoot(child)
		elseif child:IsA("Model") then
			registerBushModel(child :: Model)
		end
	end
	for _, desc in folder:GetDescendants() do
		if desc:IsA("ProximityPrompt") and isForeignSearchPrompt(desc) then
			registerFromSearchPrompt(desc)
		end
	end
end

local function purgeLegacyEmptyBushBillboards(map: Instance)
	for _, desc in map:GetDescendants() do
		if desc.Name == "BushEmptyMessage" then
			desc:Destroy()
		end
	end
end

local function registerAllBushesOnMap(map: Instance)
	purgeForeignUnder(map)
	purgeLegacyEmptyBushBillboards(map)

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

local HIGHLIGHT_READY = Color3.fromRGB(72, 255, 140)
local HIGHLIGHT_LOCKED = Color3.fromRGB(255, 45, 45)

local function applyBushHighlight(hl: Highlight, bush: Instance, locked: boolean)
	hl.Adornee = bush
	hl.Enabled = true
	hl.FillTransparency = 1
	hl.OutlineTransparency = 0
	hl.OutlineColor = if locked then HIGHLIGHT_LOCKED else HIGHLIGHT_READY
	-- AlwaysOnTop can fail to draw on some mobile GPUs; Occluded is more reliable.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
	else
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	end
end

local function cooldownOutlineMinDistance(): number
	-- Phones are usually close to the bush; don't hide the red lock outline for being "too near".
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return 0
	end
	return COOLDOWN_VFX_MIN_DIST
end

local function pickClosest(): (Instance?, ProximityPrompt?, BasePart?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil, nil
	end
	local pos = hrp.Position
	local now = os.clock()
	local bestM: Instance? = nil
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

local function pickClosestCooldownBush(): (Instance?, ProximityPrompt?, BasePart?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil, nil
	end
	local pos = hrp.Position
	local now = os.clock()
	local bestM: Instance? = nil
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
		if not graceActive and d < cooldownOutlineMinDistance() then
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

--[[ Server-authoritative 30/70 roll via HarvestBush RemoteFunction. ]]
local function requestBushSearch(worldPos: Vector3, bush: Instance)
	local folder = ReplicatedStorage:FindFirstChild("BushRemotes") or ReplicatedStorage:WaitForChild("BushRemotes", 8)
	if not folder then
		return
	end

	local rf = folder:FindFirstChild("HarvestBush") or folder:WaitForChild("HarvestBush", 8)
	if rf and rf:IsA("RemoteFunction") then
		harvestFunction = rf
		local ok = pcall(function()
			rf:InvokeServer(worldPos, bush)
		end)
		if ok then
			return
		end
	end

	local rem = folder:FindFirstChild("HarvestBrainrot")
	if rem and rem:IsA("RemoteEvent") then
		harvestRemote = rem
		rem:FireServer(worldPos, bush)
	end
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

	cooldownUntil[bush] = now + math.random(POST_HARVEST_COOLDOWN_MIN, POST_HARVEST_COOLDOWN_MAX)
	harvestLockVisualUntil[bush] = now + POST_HARVEST_LOCK_VFX_SEC
	setActive(nil, nil, nil)

	requestBushSearch(promptWorldPos(prompt), bush)
end

local function tickAim()
	local hl = aimHighlight
	local cam = workspace.CurrentCamera
	if hl and cam and hl.Parent ~= cam then
		hl.Parent = cam
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

	-- Block new bush search only at carry capacity; cooldown lock visuals still update while partially loaded.
	local bush: Instance?, prompt: ProximityPrompt?, anchor: BasePart?
	if CarryGate.isFull() then
		bush, prompt, anchor = nil, nil, nil
	else
		bush, prompt, anchor = pickClosest()
	end
	if bush then
		ProximityPromptEffects.hideBushCooldownBanner()
		if hl then
			applyBushHighlight(hl, bush, false)
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
			applyBushHighlight(hl, cBush, true)
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
		elseif desc.Parent and desc.Parent:IsA("Folder") and isBushFolderName(desc.Parent.Name) then
			if desc.Name == "BushSCRIPT" and (desc:IsA("Model") or desc:IsA("BasePart")) then
				task.defer(function()
					registerBushRoot(desc)
				end)
			elseif desc:IsA("Model") then
				task.defer(function()
					registerBushModel(desc :: Model)
				end)
			end
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
	ContextActionService:BindActionAtPriority(
		BUSH_SEARCH_HOLD_ACTION,
		function(_name, state, input)
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
			if input.UserInputType ~= Enum.UserInputType.Keyboard
				and input.UserInputType ~= Enum.UserInputType.Gamepad1
			then
				return Enum.ContextActionResult.Pass
			end
			local keyOk = input.KeyCode == Enum.KeyCode.E
				or input.KeyCode == prompt.KeyboardKeyCode
			local padOk = prompt.GamepadKeyCode ~= Enum.KeyCode.Unknown
				and input.KeyCode == prompt.GamepadKeyCode
			if not keyOk and not padOk then
				return Enum.ContextActionResult.Pass
			end

			if state == Enum.UserInputState.Begin then
				bushSearchHoldPrompt = prompt
				bushSearchHoldBeganAt = os.clock()
				ProximityPromptEffects.beginManagedBushHold(prompt)
				return Enum.ContextActionResult.Sink
			end
			if state == Enum.UserInputState.End and bushSearchHoldPrompt == prompt then
				local dur = prompt.HoldDuration
				local completed = dur > 0 and (os.clock() - bushSearchHoldBeganAt) >= dur * 0.92
				ProximityPromptEffects.endManagedBushHold(prompt, completed)
				bushSearchHoldPrompt = nil
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.ContextActionPriority.High.Value + 1,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonX
	)

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

return BushHoldInteraction
