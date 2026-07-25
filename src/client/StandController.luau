-- [ACTIVE] StandController
--[[
	StandController
	• Hitbox detection for UIStands pads
	• Undertale-style dialogue cutscene before opening Shop / Sell / Upgrades
	• Charge-in pad fill (~0.55s) before dialogue when cutscenes enabled
	• Ensures stand brainrot idle animations play
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
local activeStandFrame: string? = nil
local activeStandEntry: StandEntry? = nil
local closePending: thread? = nil
local dialogueBusy = false
local dismissedStandKey: string? = nil
local openedPanelFromDialogue = false

local chargeStand: StandEntry? = nil
local chargeAmount = 0
local chargeBillboard: BillboardGui? = nil
local chargeFill: Frame? = nil
local chargeFillTween: Tween? = nil

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
	return player:GetAttribute("ShopCutsceneEnabled") ~= false
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
	chargeStand = nil
	chargeAmount = 0
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
		HUDController.closeCurrentFrame()
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

local function updateCharge(stand: StandEntry, dt: number)
	if not canChargeOnStand(stand) then
		resetCharge()
		return
	end
	if chargeStand ~= stand then
		chargeStand = stand
		chargeAmount = 0
	end
	chargeAmount += dt / CHARGE_DURATION
	setChargeVisual(chargeAmount)
	if chargeAmount >= 1 then
		resetCharge()
		beginDialogue(stand)
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

	if dialogueBusy or StandDialogueCutscene.isActive() then
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
			HUDController.closeCurrentFrame()
			activeStandFrame = nil
			activeStandEntry = nil
			openedPanelFromDialogue = false
		end

		if not shopCutsceneEnabled() then
			resetCharge()
			openPanelDirect(insideStand)
		else
			updateCharge(insideStand, dt)
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
	local map = workspace:WaitForChild("Map", 20)
	if not map then
		warn("[StandController] workspace.Map not found")
		return
	end

	local uiStands = map:WaitForChild("UIStands", 15)
	if not uiStands then
		warn("[StandController] workspace.Map.UIStands not found")
		return
	end

	for _, cfg in ipairs(STAND_CONFIG) do
		local standFolder = uiStands:WaitForChild(cfg.standName, 10)
		if not standFolder then
			warn("[StandController] Stand not found: " .. cfg.standName)
			continue
		end

		local hitbox = standFolder:WaitForChild(cfg.hitboxName, 10) :: BasePart?
		if not hitbox then
			warn("[StandController] Hitbox not found: " .. cfg.hitboxName)
			continue
		end

		local brainrot = findBrainrotModel(standFolder, cfg.brainrotName)
		if brainrot then
			StandDialogueCutscene.ensureIdleAnimation(brainrot, cfg.brainrotName)
		else
			warn("[StandController] Brainrot model missing on " .. cfg.standName)
		end

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
	end

	if #stands == 0 then
		warn("[StandController] No stands loaded – check UIStands names")
		return
	end

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

	local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		tick(dt)
	end)
	player.AncestryChanged:Connect(function(_, parent)
		if not parent and heartbeatConn then
			heartbeatConn:Disconnect()
		end
	end)
end

return StandController
