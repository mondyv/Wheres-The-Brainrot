-- [ACTIVE] StandController
--[[
	StandController
	• Hitbox detection for UIStands pads
	• Default: charge bar + overhead welcome → open Shop / Sell / Upgrades panel
	• Optional ShopCutsceneEnabled: Undertale dialogue before Enter/Exit
	• Goodbye speech near brainrot when leaving after shopping or choosing Exit

	Workspace path:  workspace.Map.UIStands.<Stand Name>.<HitboxPart>
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local HUDController = require(script.Parent.HUDController)
local StandDialogueCutscene = require(script.Parent.StandDialogueCutscene)
local BackgroundMusicController = require(script.Parent.BackgroundMusicController)

local player = Players.LocalPlayer

if not player.Character then
	player.CharacterAdded:Wait()
end

-- ── Stand config ──────────────────────────────────────────────────────────────
-- voicePitch: Shop keeps default Gaster range; Sell deeper; Upgrade higher

local FRAME_TO_BOOTH = {
	Shop = "BrainrotDealerBooth" :: BackgroundMusicController.BoothKey,
	Sell = "SellBooth" :: BackgroundMusicController.BoothKey,
	Upgrades = "UpgradeBooth" :: BackgroundMusicController.BoothKey,
}
local STAND_CONFIG = {
	{
		standName = "Shop Stand",
		standAliases = { "Shop Stand", "Dealer Stand", "Brainrot Dealer", "Shop", "Dealer" },
		hitboxName = "ShopPadHitbox",
		frameName = "Shop",
		brainrotName = "TatatataSahur",
		enterLabel = "SHOP",
		voicePitchMin = 0.88,
		voicePitchMax = 1.2,
		lines = {
			{ text = "HEY!! WELCOME TO MY SHOP!!", shake = true },
			{ text = "WANT TO BUY SOME STUFF??", shake = false },
		},
		goodbye = "COME BACK SOON!! BYE BYE!!",
	},
	{
		standName = "Sell Stand",
		standAliases = { "Sell Stand", "Sell" },
		hitboxName = "SellPadHitbox",
		frameName = "Sell",
		brainrotName = "TricTracBarabum",
		enterLabel = "SELL",
		voicePitchMin = 0.58,
		voicePitchMax = 0.82,
		lines = {
			{ text = "GOT BRAINROTS?? I'LL BUY EM!!", shake = true },
			{ text = "CASH FOR YOUR JUNK!!", shake = false },
		},
		goodbye = "BRING MORE JUNK NEXT TIME!!",
	},
	{
		standName = "Upgrade Stand",
		standAliases = { "Upgrade Stand", "Upgrade" },
		hitboxName = "UpgradePadHitbox",
		frameName = "Upgrades",
		brainrotName = "OrangutiniAnanassini",
		enterLabel = "UPGRADE",
		voicePitchMin = 1.2,
		voicePitchMax = 1.55,
		lines = {
			{ text = "FEELING WEAK??", shake = true },
			{ text = "LET ME UPGRADE YOUR SWING!!", shake = false },
		},
		goodbye = "GO SWING HARDER!! SEE YA!!",
	},
}

type StandEntry = {
	hitbox: BasePart,
	standFolder: Instance,
	brainrot: Model?,
	frameName: string,
	brainrotName: string,
	enterLabel: string,
	lines: { { text: string, shake: boolean? } },
	standName: string,
	voicePitchMin: number,
	voicePitchMax: number,
	goodbye: string,
}

local CLOSE_DEBOUNCE = 0.22
local CHARGE_DURATION = 0.55
local CHARGE_GUI_NAME = "StandPadCharge"
local CHARGE_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local stands: { StandEntry } = {}
local registeredHitboxes: { [BasePart]: boolean } = {}
local activeStandFrame: string? = nil
local activeStandEntry: StandEntry? = nil
local closePending: thread? = nil
local dialogueBusy = false
local dismissedStandKey: string? = nil
local openedPanelFromDialogue = false
local heartbeatStarted = false

local chargeStand: StandEntry? = nil
local chargeAmount = 0
local chargeBillboard: BillboardGui? = nil
local chargeFill: Frame? = nil
local chargeFillTween: Tween? = nil
local welcomeShownFor: StandEntry? = nil

local function syncBoothMusic(stand: StandEntry?)
	local key = if stand then FRAME_TO_BOOTH[stand.frameName] else nil
	BackgroundMusicController.setActiveBooth(key)
end

local function cancelPendingClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function shopCutsceneEnabled(): boolean
	-- Explicit true only — nil/false = charge + direct open (default).
	return player:GetAttribute("ShopCutsceneEnabled") == true
end

local function getHRP(): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function destroyChargeUi()
	if chargeFillTween then
		chargeFillTween:Cancel()
		chargeFillTween = nil
	end
	if chargeBillboard then
		chargeBillboard:Destroy()
		chargeBillboard = nil
		chargeFill = nil
	end
end

local function ensureChargeUi(): Frame?
	local hrp = getHRP()
	if not hrp then
		return nil
	end
	if chargeBillboard and chargeBillboard.Parent == hrp then
		return chargeFill
	end
	destroyChargeUi()

	local bb = Instance.new("BillboardGui")
	bb.Name = CHARGE_GUI_NAME
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 60
	bb.Size = UDim2.fromOffset(132, 16)
	bb.StudsOffset = Vector3.new(0, -2.8, 0)
	bb.Adornee = hrp
	bb.Parent = hrp

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	track.BackgroundTransparency = 0.05
	track.BorderSizePixel = 0
	track.Size = UDim2.fromScale(1, 1)
	track.ClipsDescendants = true
	track.Parent = bb

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 6)
	trackCorner.Parent = track

	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = Color3.fromRGB(255, 255, 255)
	trackStroke.Thickness = 2
	trackStroke.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(255, 230, 40)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	local tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.AnchorPoint = Vector2.new(1, 0.5)
	tip.Position = UDim2.fromScale(1, 0.5)
	tip.Size = UDim2.fromOffset(6, 10)
	tip.BackgroundColor3 = Color3.fromRGB(255, 245, 120)
	tip.BorderSizePixel = 0
	tip.Parent = fill
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 3)
	tipCorner.Parent = tip

	chargeBillboard = bb
	chargeFill = fill
	return fill
end

local function setChargeVisual(alpha: number)
	local fill = ensureChargeUi()
	if not fill then
		return
	end
	local goal = math.clamp(alpha, 0, 1)
	if chargeFillTween then
		chargeFillTween:Cancel()
	end
	chargeFillTween = TweenService:Create(fill, CHARGE_TWEEN, {
		Size = UDim2.fromScale(goal, 1),
	})
	chargeFillTween:Play()
end

local function resetCharge()
	if welcomeShownFor then
		StandDialogueCutscene.cancelWorldSpeech()
	end
	chargeStand = nil
	chargeAmount = 0
	welcomeShownFor = nil
	destroyChargeUi()
end

local function canChargeOnStand(_stand: StandEntry): boolean
	if dialogueBusy or StandDialogueCutscene.isActive() then
		return false
	end
	if activeStandFrame then
		return false
	end
	return true
end

local function showGoodbye(stand: StandEntry)
	local brainrot = stand.brainrot
	if not brainrot or not brainrot.Parent then
		brainrot = nil
		local child = stand.standFolder:FindFirstChild(stand.brainrotName)
		if child and child:IsA("Model") then
			brainrot = child
		end
	end
	if brainrot then
		StandDialogueCutscene.showWorldSpeech(brainrot, stand.goodbye, {
			durationSec = 1.6,
			voicePitchMin = stand.voicePitchMin,
			voicePitchMax = stand.voicePitchMax,
		})
	end
end

local function scheduleClose()
	cancelPendingClose()
	closePending = task.delay(CLOSE_DEBOUNCE, function()
		closePending = nil
		local leavingStand = activeStandEntry
		local shouldGoodbye = openedPanelFromDialogue and leavingStand ~= nil
		activeStandFrame = nil
		activeStandEntry = nil
		openedPanelFromDialogue = false
		syncBoothMusic(nil)
		if HUDController.getCurrentFrame() then
			HUDController.closeCurrentFrame()
		else
			HUDController.forceClearPanelModal()
		end
		if shouldGoodbye and leavingStand then
			showGoodbye(leavingStand)
		end
	end)
end

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart, padding: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function findBrainrotModel(standFolder: Instance, brainrotName: string): Model?
	local child = standFolder:FindFirstChild(brainrotName)
	if child and child:IsA("Model") then
		return child
	end
	for _, desc in standFolder:GetChildren() do
		if desc:IsA("Model") and desc.Name ~= "Meshes" then
			return desc
		end
	end
	return nil
end

local function getWelcomeText(stand: StandEntry): string
	local first = stand.lines[1]
	if first and typeof(first.text) == "string" and first.text ~= "" then
		return first.text
	end
	return "HEY!!"
end

local function showChargeWelcome(stand: StandEntry)
	if welcomeShownFor == stand then
		return
	end
	welcomeShownFor = stand
	local brainrot = stand.brainrot
	if not brainrot or not brainrot.Parent then
		brainrot = findBrainrotModel(stand.standFolder, stand.brainrotName)
		stand.brainrot = brainrot
	end
	if not brainrot then
		return
	end
	StandDialogueCutscene.showWorldSpeech(brainrot, getWelcomeText(stand), {
		durationSec = 1.45,
		textSize = 16,
		studsOffset = Vector3.new(0, 3.15, 0),
		voicePitchMin = stand.voicePitchMin,
		voicePitchMax = stand.voicePitchMax,
	})
end

local function normalizeStandKey(name: string): string
	return string.lower((string.gsub(name, "%s+", "")))
end

local function findStandFolderForConfig(uiStands: Instance, cfg: any): Instance?
	local aliases = cfg.standAliases or { cfg.standName }
	for _, alias in ipairs(aliases) do
		local direct = uiStands:FindFirstChild(alias)
		if direct then
			return direct
		end
	end
	local wanted = normalizeStandKey(cfg.standName)
	for _, child in uiStands:GetChildren() do
		if normalizeStandKey(child.Name) == wanted then
			return child
		end
		for _, alias in ipairs(aliases) do
			if normalizeStandKey(child.Name) == normalizeStandKey(alias) then
				return child
			end
		end
	end
	-- Last resort: folder that contains the expected pad hitbox.
	for _, child in uiStands:GetChildren() do
		local hit = child:FindFirstChild(cfg.hitboxName, true)
		if hit and hit:IsA("BasePart") then
			return child
		end
	end
	return nil
end

local function findHitbox(standFolder: Instance, hitboxName: string): BasePart?
	local direct = standFolder:FindFirstChild(hitboxName)
	if direct and direct:IsA("BasePart") then
		return direct
	end
	local deep = standFolder:FindFirstChild(hitboxName, true)
	if deep and deep:IsA("BasePart") then
		return deep
	end
	return nil
end

local function registerStand(cfg: any, standFolder: Instance): boolean
	local hitbox = findHitbox(standFolder, cfg.hitboxName)
	if not hitbox then
		return false
	end
	if registeredHitboxes[hitbox] then
		return true
	end

	local brainrot = findBrainrotModel(standFolder, cfg.brainrotName)
	if brainrot then
		StandDialogueCutscene.ensureIdleAnimation(brainrot, cfg.brainrotName)
	else
		warn("[StandController] Brainrot model missing on " .. tostring(standFolder.Name))
	end

	registeredHitboxes[hitbox] = true
	table.insert(stands, {
		hitbox = hitbox,
		standFolder = standFolder,
		brainrot = brainrot,
		frameName = cfg.frameName,
		brainrotName = cfg.brainrotName,
		enterLabel = cfg.enterLabel,
		lines = cfg.lines,
		standName = cfg.standName,
		voicePitchMin = cfg.voicePitchMin,
		voicePitchMax = cfg.voicePitchMax,
		goodbye = cfg.goodbye,
	})
	return true
end

local function tryRegisterAll(uiStands: Instance)
	for _, cfg in ipairs(STAND_CONFIG) do
		local already = false
		for _, entry in ipairs(stands) do
			if entry.standName == cfg.standName then
				already = true
				break
			end
		end
		if already then
			continue
		end
		local standFolder = findStandFolderForConfig(uiStands, cfg)
		if standFolder then
			registerStand(cfg, standFolder)
		end
	end
end

local function openPanelDirect(stand: StandEntry)
	dismissedStandKey = nil
	activeStandFrame = stand.frameName
	activeStandEntry = stand
	openedPanelFromDialogue = true
	syncBoothMusic(stand)
	HUDController.openFrameByName(stand.frameName)
end

local function beginDialogue(stand: StandEntry)
	if dialogueBusy or StandDialogueCutscene.isActive() then
		return
	end
	local brainrot = stand.brainrot
	if not brainrot or not brainrot.Parent then
		brainrot = findBrainrotModel(stand.standFolder, stand.brainrotName)
		stand.brainrot = brainrot
	end
	if not brainrot then
		openPanelDirect(stand)
		return
	end

	resetCharge()
	dialogueBusy = true
	openedPanelFromDialogue = false
	syncBoothMusic(stand)
	task.spawn(function()
		local choseEnter = StandDialogueCutscene.play({
			standName = stand.standName,
			frameName = stand.frameName,
			brainrotName = stand.brainrotName,
			enterLabel = stand.enterLabel,
			lines = stand.lines,
			voicePitchMin = stand.voicePitchMin,
			voicePitchMax = stand.voicePitchMax,
		}, brainrot)

		dialogueBusy = false

		if choseEnter then
			dismissedStandKey = nil
			activeStandFrame = stand.frameName
			activeStandEntry = stand
			openedPanelFromDialogue = true
			syncBoothMusic(stand)
			HUDController.openFrameByName(stand.frameName)
		else
			dismissedStandKey = stand.standName
			activeStandFrame = nil
			activeStandEntry = nil
			openedPanelFromDialogue = false
			syncBoothMusic(nil)
			showGoodbye(stand)
		end
	end)
end

local function updateCharge(stand: StandEntry, dt: number, onComplete: () -> ())
	if not canChargeOnStand(stand) then
		resetCharge()
		return
	end
	if chargeStand ~= stand then
		chargeStand = stand
		chargeAmount = 0
		-- Direct-open path: welcome chatter while the pad charges.
		if not shopCutsceneEnabled() then
			showChargeWelcome(stand)
		end
	end
	chargeAmount += dt / CHARGE_DURATION
	setChargeVisual(chargeAmount)
	if chargeAmount >= 1 then
		-- Keep welcome balloon — don't cancelWorldSpeech via resetCharge.
		welcomeShownFor = nil
		chargeStand = nil
		chargeAmount = 0
		destroyChargeUi()
		onComplete()
	end
end

local function tick(dt: number)
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local hrpPos = (hrp :: BasePart).Position

	-- External cutscenes (Tim Cheese etc.) also use StandDialogueCutscene —
	-- only cancel when THIS controller owns the session (dialogueBusy).
	if StandDialogueCutscene.isActive() and not dialogueBusy then
		resetCharge()
		return
	end
	if dialogueBusy then
		resetCharge()
		local stillInside: StandEntry? = nil
		for _, stand in ipairs(stands) do
			if stand.hitbox.Parent and isPointInsidePartOBB(hrpPos, stand.hitbox, 2.75) then
				stillInside = stand
				break
			end
		end
		if stillInside then
			syncBoothMusic(stillInside)
		else
			StandDialogueCutscene.cancel()
			dialogueBusy = false
			syncBoothMusic(nil)
		end
		return
	end

	local insideStand: StandEntry? = nil

	for _, stand in ipairs(stands) do
		if not stand.hitbox.Parent then
			continue
		end
		if isPointInsidePartOBB(hrpPos, stand.hitbox, 2.75) then
			insideStand = stand
			break
		end
	end

	if insideStand then
		cancelPendingClose()
		syncBoothMusic(insideStand)
		if dismissedStandKey == insideStand.standName then
			resetCharge()
			return
		end
		if activeStandFrame == insideStand.frameName then
			resetCharge()
			return
		end
		if activeStandFrame then
			if HUDController.getCurrentFrame() then
				HUDController.closeCurrentFrame()
			else
				HUDController.forceClearPanelModal()
			end
			activeStandFrame = nil
			activeStandEntry = nil
			openedPanelFromDialogue = false
		end

		if not shopCutsceneEnabled() then
			updateCharge(insideStand, dt, function()
				openPanelDirect(insideStand)
			end)
		else
			updateCharge(insideStand, dt, function()
				beginDialogue(insideStand)
			end)
		end
	else
		dismissedStandKey = nil
		resetCharge()
		if activeStandFrame and not closePending then
			scheduleClose()
		elseif not activeStandFrame then
			syncBoothMusic(nil)
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

local StandController = {}

function StandController.init()
	local map = workspace:WaitForChild("Map", 60)
	if not map then
		warn("[StandController] workspace.Map not found")
		return
	end

	local uiStands = map:WaitForChild("UIStands", 60)
	if not uiStands then
		warn("[StandController] workspace.Map.UIStands not found")
		return
	end

	tryRegisterAll(uiStands)

	-- Streaming: stands may arrive after boot — keep trying as they stream in.
	uiStands.ChildAdded:Connect(function()
		task.defer(function()
			tryRegisterAll(uiStands)
		end)
	end)
	uiStands.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") and string.find(desc.Name, "Hitbox", 1, true) then
			task.defer(function()
				tryRegisterAll(uiStands)
			end)
		end
	end)

	-- Periodic catch-up for late streaming (Shop Stand often streams after Sell/Upgrade).
	task.spawn(function()
		for _ = 1, 40 do
			if #stands >= #STAND_CONFIG then
				break
			end
			task.wait(1.5)
			tryRegisterAll(uiStands)
		end
		if #stands == 0 then
			warn("[StandController] No stands loaded – check UIStands names / streaming")
		elseif #stands < #STAND_CONFIG then
			local missing = {}
			for _, cfg in ipairs(STAND_CONFIG) do
				local found = false
				for _, entry in ipairs(stands) do
					if entry.standName == cfg.standName then
						found = true
						break
					end
				end
				if not found then
					table.insert(missing, cfg.standName)
				end
			end
			warn("[StandController] Still missing stands:", table.concat(missing, ", "))
		end
	end)

	player.CharacterAdded:Connect(function()
		cancelPendingClose()
		activeStandFrame = nil
		activeStandEntry = nil
		dismissedStandKey = nil
		openedPanelFromDialogue = false
		resetCharge()
		if StandDialogueCutscene.isActive() then
			StandDialogueCutscene.cancel()
		end
		dialogueBusy = false
	end)

	if not heartbeatStarted then
		heartbeatStarted = true
		local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
			tick(dt)
		end)
		player.AncestryChanged:Connect(function(_, parent)
			if not parent and heartbeatConn then
				heartbeatConn:Disconnect()
			end
		end)
	end
end

return StandController
