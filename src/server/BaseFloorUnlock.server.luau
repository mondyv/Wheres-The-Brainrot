--[[
	BaseFloorUnlock (server)
	Each base under workspace.Map["Spawn And Bases"] has up to 4 story folders
	("1 Story", "2 Story", "3 Story", "4 Story"). Story 1 is unlocked by default.
	The Upgrade/Add sign in story N unlocks story N+1.

	Bases may be cloned at runtime (see 0_BasePlotSpawner): PlotSlotId + player AssignedPlotSlot
	must match before paying to unlock a floor on those plots.

	Costs:
	  Floor 2 → $250.5M
	  Floor 3 → $25.5B
	  Floor 4 → $30.5T

	Per-base state (attributes on the base container — Model or Folder):
	  BaseFloorLevel  : number 1..MAX_FLOOR (current top-unlocked floor)
	  PlotOwnerUserId : number — plot owner (also used by PlotUsernameLabels)
	  PlotSlotId      : number (optional) — 1..7 when spawned by 0_BasePlotSpawner

	Per-stand state (attributes on each stand Model):
	  BrainrotStandLocked : bool — set to true while its story is above the current floor.
	    StandManager checks this to disable the proximity prompt.

	Sign UI (under each story.Upgrade/Add.GUIPart.SurfaceGui.Frame):
	  TextLabel        — "Upgrade Base" / "MAX FLOOR"
	  Upgrade.Cost     — formatted cost or "MAX"
	  Upgrade.Current  — "<floor>/<MAX>"

	Locked floors (2+) are parented to ServerStorage.__HiddenBaseFloors so nothing
	replicates in Workspace (no ghost SurfaceGuis / Billboards / highlights).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PlotPaths = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotPaths"))
local PlotStandPlaceholders = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlotStandPlaceholders"))

local MAX_FLOOR = 4
local FLOOR_UNLOCK_COSTS: { [number]: number } = {
	[2] = 250_500_000,
	[3] = 25_500_000_000,
	[4] = 30_500_000_000_000,
}

local UNLOCK_DEBOUNCE = 0.5
local SIGN_CLICK_DISTANCE = 22

local function formatCash(n: number): string
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

-- ── Discovery ────────────────────────────────────────────────────────────────

local function findSpawnBasesFolder(): Instance?
	return PlotPaths.findSpawnAndBasesFolder()
end

local function getStoryNumber(name: string): number?
	-- Accepts "1 Story", "1st Story", "2 Story", etc.
	local digits = string.match(name, "^(%d+)")
	if not digits then return nil end
	local n = tonumber(digits)
	if n and n >= 1 and n <= MAX_FLOOR then
		return n
	end
	return nil
end

local function findStoriesUnderBase(base: Instance): { [number]: Instance }
	local result: { [number]: Instance } = {}
	for _, child in ipairs(base:GetChildren()) do
		local n = getStoryNumber(child.Name)
		if n then
			result[n] = child
		end
	end
	return result
end

local function isUpgradeAddSignName(name: string): boolean
	local ak = string.gsub(string.lower(name), "[^a-z0-9]", "")
	return ak == "upgradeadd" or (string.find(ak, "upgrade", 1, true) ~= nil and string.find(ak, "add", 1, true) ~= nil)
end

local function findUpgradeSign(story: Instance): Model?
	for _, d in ipairs(story:GetDescendants()) do
		if d:IsA("Model") and isUpgradeAddSignName(d.Name) then
			return d :: Model
		end
	end
	return nil
end

local function findSignGuiPart(sign: Model): BasePart?
	local p = sign:FindFirstChild("GUIPart")
	if p and p:IsA("BasePart") then
		return p :: BasePart
	end
	return sign:FindFirstChildWhichIsA("BasePart", true)
end

local function findSignFrame(sign: Model): Frame?
	local gp = findSignGuiPart(sign)
	if not gp then return nil end
	local sg = gp:FindFirstChild("SurfaceGui") or gp:FindFirstChildWhichIsA("SurfaceGui")
	if not sg or not sg:IsA("SurfaceGui") then return nil end
	local f = sg:FindFirstChild("Frame")
	if f and f:IsA("Frame") then
		return f :: Frame
	end
	local anyFrame = sg:FindFirstChildWhichIsA("Frame")
	if anyFrame then
		return anyFrame :: Frame
	end
	return nil
end

local function findSignBarrierModel(sign: Model): Model?
	-- The "Model" child holds parts that visually gate / block the locked floor.
	local m = sign:FindFirstChild("Model")
	if m and m:IsA("Model") then
		return m :: Model
	end
	return nil
end

-- ── UI helpers ───────────────────────────────────────────────────────────────

local function ensureUIScale(target: GuiObject): UIScale
	local s = target:FindFirstChildOfClass("UIScale")
	if s then return s end
	local n = Instance.new("UIScale")
	n.Parent = target
	return n
end

local function setLabel(parent: Instance, name: string, text: string)
	local label = parent:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		(label :: TextLabel).Text = text
	elseif label and label:IsA("TextButton") then
		(label :: TextButton).Text = text
	end
end

-- ── Visibility snapshot helpers ──────────────────────────────────────────────
-- We snapshot the part's original Transparency / CanCollide / Decal opacity the
-- first time we hide it so that an unlock can restore the exact look from Studio,
-- even if the artist used something non-default (e.g. semi-transparent glass).

local ORIG_PART_TRANSP = "__FUOrigTransparency"
local ORIG_PART_COLLIDE = "__FUOrigCollide"
local ORIG_PART_QUERY = "__FUOrigQuery"
local ORIG_PART_TOUCH = "__FUOrigTouch"
local ORIG_DECAL_TRANSP = "__FUOrigDecalT"

local function setPartHidden(part: BasePart, hidden: boolean)
	if hidden then
		if part:GetAttribute(ORIG_PART_TRANSP) == nil then
			part:SetAttribute(ORIG_PART_TRANSP, part.Transparency)
			part:SetAttribute(ORIG_PART_COLLIDE, part.CanCollide)
			part:SetAttribute(ORIG_PART_QUERY, part.CanQuery)
			part:SetAttribute(ORIG_PART_TOUCH, part.CanTouch)
		end
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	else
		local t = part:GetAttribute(ORIG_PART_TRANSP)
		if typeof(t) == "number" then
			part.Transparency = t
		else
			part.Transparency = 0
		end
		local c = part:GetAttribute(ORIG_PART_COLLIDE)
		part.CanCollide = if typeof(c) == "boolean" then c else true
		local q = part:GetAttribute(ORIG_PART_QUERY)
		part.CanQuery = if typeof(q) == "boolean" then q else true
		local h = part:GetAttribute(ORIG_PART_TOUCH)
		part.CanTouch = if typeof(h) == "boolean" then h else true
	end
end

local function setDecalHidden(d: Instance, hidden: boolean)
	if not (d:IsA("Decal") or d:IsA("Texture")) then return end
	if hidden then
		if d:GetAttribute(ORIG_DECAL_TRANSP) == nil then
			d:SetAttribute(ORIG_DECAL_TRANSP, (d :: any).Transparency)
		end
		(d :: any).Transparency = 1
	else
		local t = d:GetAttribute(ORIG_DECAL_TRANSP)
		if typeof(t) == "number" then
			(d :: any).Transparency = t
		else
			(d :: any).Transparency = 0
		end
	end
end

-- Move locked stories out of Workspace entirely so clients never replicate or draw
-- them (fixes leftover SurfaceGui / BillboardGui / any world UI on upper floors).
local hiddenFloorsRoot: Folder? = nil
local lockedStoryOriginalParent: { [Instance]: Instance } = {}

local function getHiddenFloorsRoot(): Folder
	if hiddenFloorsRoot and hiddenFloorsRoot.Parent then
		return hiddenFloorsRoot :: Folder
	end
	local f = ServerStorage:FindFirstChild("__HiddenBaseFloors")
	if not f then
		f = Instance.new("Folder")
		f.Name = "__HiddenBaseFloors"
		f.Parent = ServerStorage
	end
	assert(f:IsA("Folder"))
	hiddenFloorsRoot = f :: Folder
	return hiddenFloorsRoot
end

local function setStoryParkedOutOfWorkspace(story: Instance, locked: boolean, base: Instance)
	if locked then
		local root = getHiddenFloorsRoot()
		if story.Parent ~= root then
			local p = story.Parent
			if p then
				lockedStoryOriginalParent[story] = p
			end
			story.Parent = root
		end
	else
		local orig = lockedStoryOriginalParent[story]
		local dest: Instance = if orig and orig.Parent then orig else base
		if story.Parent ~= dest then
			story.Parent = dest
		end
		lockedStoryOriginalParent[story] = nil
	end
end

-- ── State ────────────────────────────────────────────────────────────────────

type SignData = {
	story: Instance,
	storyNumber: number,
	sign: Model,
	guiPart: BasePart,
	frame: Frame,
	surfaceGui: SurfaceGui?,
	-- UIScale hover / pulse only on the button graphic, not the whole frame (title text).
	hoverTarget: GuiObject,
	clickDetector: ClickDetector?,
	lastClickAt: number,
}

type BaseState = {
	base: Instance,
	floorLevel: number,
	stories: { [number]: Instance },
	signs: { [number]: SignData },
	hooked: boolean,
}

local bases: { [Instance]: BaseState } = {}
local standRescanScheduled = false

local function scheduleStandRescan()
	if standRescanScheduled then
		return
	end
	standRescanScheduled = true
	task.defer(function()
		standRescanScheduled = false
		local internal = ServerStorage:FindFirstChild("BrainrotInternal")
		if not internal then
			return
		end
		local bf = internal:FindFirstChild("RequestStandRescan")
		if bf and bf:IsA("BindableFunction") then
			pcall(function()
				(bf :: BindableFunction):Invoke()
			end)
		end
	end)
end

local function ensureUnlockRemote(): RemoteEvent
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local ev = remotes:FindFirstChild("UnlockBaseFloor")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "UnlockBaseFloor"
		ev.Parent = remotes
	end
	return ev :: RemoteEvent
end

local function setStandsLocked(story: Instance, locked: boolean)
	local standsFolder = PlotStandPlaceholders.findStandsFolder(story)
	if not standsFolder then return end
	for _, stand in ipairs(standsFolder:GetChildren()) do
		if stand:IsA("Model") then
			stand:SetAttribute("BrainrotStandLocked", locked)
		end
	end
end

-- We hide the post Model + GUIPart together: when the sign is inactive (already
-- consumed or not reachable yet), the whole sign-post visually disappears.
local function setSignVisible(signData: SignData, visible: boolean)
	setPartHidden(signData.guiPart, not visible)
	if signData.clickDetector then
		signData.clickDetector.MaxActivationDistance = if visible then SIGN_CLICK_DISTANCE else 0
	end
	if signData.surfaceGui then
		signData.surfaceGui.Enabled = visible
		signData.surfaceGui.Active = visible
	end
	signData.frame.Visible = visible
	if visible then
		signData.guiPart.CanQuery = true
	end

	local barrier = findSignBarrierModel(signData.sign)
	if barrier then
		for _, d in ipairs(barrier:GetDescendants()) do
			if d:IsA("BasePart") then
				setPartHidden(d, not visible)
			elseif d:IsA("Decal") or d:IsA("Texture") then
				setDecalHidden(d, not visible)
			end
		end
	end
end

local function updateSignText(signData: SignData, currentFloor: number)
	local frame = signData.frame
	local nextFloor = signData.storyNumber + 1
	local cost = FLOOR_UNLOCK_COSTS[nextFloor]

	if currentFloor >= MAX_FLOOR then
		setLabel(frame, "TextLabel", "MAX FLOOR")
	else
		setLabel(frame, "TextLabel", "Upgrade Base")
	end

	local upgrade = frame:FindFirstChild("Upgrade")
	if upgrade then
		if cost and currentFloor < MAX_FLOOR then
			setLabel(upgrade, "Cost", formatCash(cost))
		else
			setLabel(upgrade, "Cost", "MAX")
		end
		setLabel(upgrade, "Current", string.format("%d/%d", currentFloor, MAX_FLOOR))
	end
end

local function countPartsIn(story: Instance): number
	local n = 0
	for _, d in ipairs(story:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function refreshBase(state: BaseState)
	local claimed = typeof(state.base:GetAttribute("PlotOwnerUserId")) == "number"
	local story1 = state.stories[1]
	local story1HasGeometry = story1 ~= nil and countPartsIn(story1) > 0

	-- 1) Lock/unlock stands per story.
	for n, story in pairs(state.stories) do
		setStandsLocked(story, claimed and n > state.floorLevel)
	end

	-- 2) Park locked upper stories only for claimed plots with story-1 geometry.
	--    Never park on unclaimed plots — BaseFloorUnlock was moving all 528 parts to
	--    ServerStorage when geometry lives in stories 2–4, leaving Workspace empty.
	for n, story in pairs(state.stories) do
		if n > 1 then
			local shouldPark = claimed and story1HasGeometry and n > state.floorLevel
			setStoryParkedOutOfWorkspace(story, shouldPark, state.base)
		end
	end

	-- 3) Sign visibility and text. Only the sign at the current floor is interactive,
	--    and only if there's a higher floor still to unlock. Done AFTER story
	--    reparenting so the active sign sits on the correct visible story.
	for n, signData in pairs(state.signs) do
		local isActive = claimed and (n == state.floorLevel) and (state.floorLevel < MAX_FLOOR)
		setSignVisible(signData, isActive)
		updateSignText(signData, state.floorLevel)
	end

	local internal = ServerStorage:FindFirstChild("BrainrotInternal")
	if internal then
		scheduleStandRescan()
	end
end

-- ── Hover / click feedback ───────────────────────────────────────────────────

local function pulseSignBurst(signData: SignData)
	local scale = ensureUIScale(signData.hoverTarget)
	scale.Scale = 1.12
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function hookHover(signData: SignData)
	if not signData.clickDetector then return end
	signData.clickDetector.MouseHoverEnter:Connect(function()
		local s = ensureUIScale(signData.hoverTarget)
		TweenService:Create(s, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.06 }):Play()
	end)
	signData.clickDetector.MouseHoverLeave:Connect(function()
		local s = ensureUIScale(signData.hoverTarget)
		TweenService:Create(s, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
end

-- ── Click → unlock ───────────────────────────────────────────────────────────

local function tryUnlock(state: BaseState, signData: SignData, player: Player): (boolean, string?)
	local now = os.clock()
	if now - signData.lastClickAt < UNLOCK_DEBOUNCE then
		return false, "debounce"
	end
	signData.lastClickAt = now

	if signData.storyNumber ~= state.floorLevel then
		return false, "wrong_sign"
	end
	if state.floorLevel >= MAX_FLOOR then
		return false, "max"
	end

	local plotSlot = state.base:GetAttribute("PlotSlotId")
	if typeof(plotSlot) == "number" then
		local assigned = player:GetAttribute("AssignedPlotSlot")
		if typeof(assigned) == "number" and math.floor(assigned) ~= math.floor(plotSlot) then
			return false, "slot"
		end
	end

	local ownerAttr = state.base:GetAttribute("PlotOwnerUserId")
	if typeof(ownerAttr) == "number" and ownerAttr ~= player.UserId then
		return false, "owner"
	end

	local nextLevel = state.floorLevel + 1
	local cost = FLOOR_UNLOCK_COSTS[nextLevel] or 0
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	if c < cost then
		return false, "cash"
	end

	player:SetAttribute("Cash", c - cost)
	if typeof(ownerAttr) ~= "number" then
		state.base:SetAttribute("PlotOwnerUserId", player.UserId)
	end

	state.floorLevel = nextLevel
	state.base:SetAttribute("BaseFloorLevel", state.floorLevel)
	refreshBase(state)
	pulseSignBurst(signData)
	return true, nil
end

-- ── Sign init ────────────────────────────────────────────────────────────────

local function ensureClickDetector(part: BasePart, name: string, maxDist: number): ClickDetector
	local existing = part:FindFirstChild(name)
	if existing and existing:IsA("ClickDetector") then
		(existing :: ClickDetector).MaxActivationDistance = maxDist
		return existing :: ClickDetector
	end
	if existing then existing:Destroy() end
	local cd = Instance.new("ClickDetector")
	cd.Name = name
	cd.MaxActivationDistance = maxDist
	cd.Parent = part
	return cd
end

local function buildSignData(state: BaseState, storyNumber: number, story: Instance): SignData?
	local sign = findUpgradeSign(story)
	if not sign then return nil end
	local guiPart = findSignGuiPart(sign)
	if not guiPart then return nil end
	local frame = findSignFrame(sign)
	if not frame then return nil end

	-- SurfaceGui with Active=true so client Upgrade button receives clicks (see BaseFloorUnlockClick).
	local surfaceGuiInst = guiPart:FindFirstChildWhichIsA("SurfaceGui")
	local surfaceGui: SurfaceGui? = if surfaceGuiInst and surfaceGuiInst:IsA("SurfaceGui") then surfaceGuiInst :: SurfaceGui else nil
	if surfaceGui then
		surfaceGui.Active = true
	end

	-- Hover scale: only the Upgrade graphic/button, not the header TextLabel on the same frame.
	local hoverTarget: GuiObject = frame
	local upg = frame:FindFirstChild("Upgrade")
	if upg and upg:IsA("GuiObject") then
		hoverTarget = upg
	end

	local cd = ensureClickDetector(guiPart, "_FloorUnlockClick", SIGN_CLICK_DISTANCE)

	local signData: SignData = {
		story = story,
		storyNumber = storyNumber,
		sign = sign,
		guiPart = guiPart,
		frame = frame,
		surfaceGui = surfaceGui,
		hoverTarget = hoverTarget,
		clickDetector = cd,
		lastClickAt = 0,
	}

	cd.MouseClick:Connect(function(player)
		tryUnlock(state, signData, player)
	end)
	-- Extra hit targets on the wooden post / frame (GUIPart ray can be finicky vs. SurfaceGui).
	local function connectUnlockToPart(hitPart: BasePart)
		if hitPart == guiPart then
			return
		end
		local ed = ensureClickDetector(hitPart, "_FloorUnlockExtra_" .. hitPart.Name, SIGN_CLICK_DISTANCE)
		ed.MouseClick:Connect(function(player)
			tryUnlock(state, signData, player)
		end)
	end
	for _, ch in ipairs(sign:GetChildren()) do
		if ch:IsA("BasePart") and ch ~= guiPart then
			connectUnlockToPart(ch :: BasePart)
			break
		elseif ch:IsA("Model") then
			local first = (ch :: Model):FindFirstChildWhichIsA("BasePart", true)
			if first and first ~= guiPart and not first:IsDescendantOf(guiPart) then
				connectUnlockToPart(first)
				break
			end
		end
	end
	hookHover(signData)

	return signData
end

local function hookBase(base: Instance)
	if bases[base] then return end
	local stories = findStoriesUnderBase(base)
	if next(stories) == nil then return end

	local existingLevel = base:GetAttribute("BaseFloorLevel")
	local floorLevel = if typeof(existingLevel) == "number" then math.clamp(math.floor(existingLevel), 1, MAX_FLOOR) else 1
	base:SetAttribute("BaseFloorLevel", floorLevel)

	local state: BaseState = {
		base = base,
		floorLevel = floorLevel,
		stories = stories,
		signs = {},
		hooked = true,
	}
	bases[base] = state

	for _, story in pairs(stories) do
		story:SetAttribute("PlotBaseName", base.Name)
	end

	for n, story in pairs(stories) do
		local signData = buildSignData(state, n, story)
		if signData then
			state.signs[n] = signData
		end
	end

	base:GetAttributeChangedSignal("BaseFloorLevel"):Connect(function()
		local v = base:GetAttribute("BaseFloorLevel")
		if typeof(v) == "number" then
			state.floorLevel = math.clamp(math.floor(v), 1, MAX_FLOOR)
			refreshBase(state)
		end
	end)

	base:GetAttributeChangedSignal("PlotOwnerUserId"):Connect(function()
		refreshBase(state)
	end)

	-- New stands streamed under one of this base's stories — make sure they get the
	-- correct lock state without us having to wait for refreshBase to be called again.
	base.DescendantAdded:Connect(function(inst)
		if not inst:IsA("Model") then
			return
		end
		local par = inst.Parent
		if not par or (par.Name ~= "Stands" and par.Name ~= "stands") then
			return
		end
		for n, s in pairs(state.stories) do
			if inst:IsDescendantOf(s) then
				inst:SetAttribute("BrainrotStandLocked", n > state.floorLevel)
				break
			end
		end
	end)

	refreshBase(state)

	base.Destroying:Once(function()
		bases[base] = nil
	end)
end

local function hookAllBasesUnder(folder: Instance)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") or child:IsA("Folder") then
			hookBase(child)
		end
	end
end

local function tryStart(): boolean
	local folder = findSpawnBasesFolder()
	if not folder then return false end
	hookAllBasesUnder(folder)
	folder.ChildAdded:Connect(function(child)
		if child:IsA("Model") or child:IsA("Folder") then
			task.defer(function()
				hookBase(child)
			end)
		end
	end)
	return true
end

task.spawn(function()
	for _ = 1, 30 do
		if tryStart() then
			break
		end
		task.wait(1)
	end
	tryStart()
end)

local function findPlayerPlot(player: Player): Instance?
	local folder = findSpawnBasesFolder()
	if not folder then
		return nil
	end
	local slot = player:GetAttribute("AssignedPlotSlot")
	if typeof(slot) == "number" then
		local bySlot = folder:FindFirstChild("Plot_" .. tostring(math.floor(slot)))
		if bySlot and PlotPaths.isPlotRoot(bySlot) then
			return bySlot
		end
	end
	for _, ch in ipairs(folder:GetChildren()) do
		if PlotPaths.isPlotRoot(ch) and ch:GetAttribute("PlotOwnerUserId") == player.UserId then
			return ch
		end
	end
	return nil
end

local function resolveActiveSignData(state: BaseState): SignData?
	local signData = state.signs[state.floorLevel]
	if signData then
		return signData
	end
	local story = state.stories[state.floorLevel]
	if not story then
		return nil
	end
	signData = buildSignData(state, state.floorLevel, story)
	if signData then
		state.signs[state.floorLevel] = signData
	end
	return signData
end

local unlockRE = ensureUnlockRemote()
unlockRE.OnServerEvent:Connect(function(player: Player)
	local base = findPlayerPlot(player)
	if not base then
		unlockRE:FireClient(player, false, "no_plot")
		return
	end
	local state = bases[base]
	if not state then
		hookBase(base)
		state = bases[base]
	end
	if not state then
		unlockRE:FireClient(player, false, "no_stories")
		return
	end
	local signData = resolveActiveSignData(state)
	if not signData then
		unlockRE:FireClient(player, false, "no_sign")
		return
	end
	local ok, reason = tryUnlock(state, signData, player)
	unlockRE:FireClient(player, ok, reason or "")
end)
