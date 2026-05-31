--[[
	DailyController
	Wires Main.Frames.Daily — the 7-day login calendar.

	Responsibilities:
	• Read DailyConfig + DailyRemotes; render per-day card state (Claim / Claimed / Locked).
	• Animate starbust spin, day 5 "???" left → middle → right pulse, day 7 icon sway.
	• Trigger claim flow on click, play confetti + purchase shake for Day 5, animate the
	  button morph from Claim → Claimed.
	• Drive the sidebar "!" badge on the Gifts (Daily) button while a reward is ready,
	  using the same sway/pulse tween used by Index/Rebirth.
	• Wire Skip-All gamepass prompt button via DailyPromptSkipAll remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local DailyConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DailyConfig"))
local HUDController = require(script.Parent.HUDController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local OPEN_NOTIF = TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BADGE_SWAY = TweenInfo.new(0.72, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BADGE_INNER_SWAY = TweenInfo.new(0.52, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BADGE_INNER_PULSE = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
local BADGE_SWAY_DEG = 5
local BADGE_INNER_SWAY_DEG = 2.5

local STARBUST_REV_SEC = 14
local DAY7_ICON_SWAY_INFO = TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local DAY7_ICON_SWAY_DEG = 12
local DAY5_QUESTION_PULSE_INFO = TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAY5_QUESTION_CYCLE_GAP = 0.32
local CARD_HOVER_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_BTN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLAIM_FLASH_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ── State ───────────────────────────────────────────────────────────────────

local dailyFrame: Frame? = nil
local container: Frame? = nil
local nextRewardLabel: TextLabel? = nil
local headerSkipBtn: GuiButton? = nil
local headerCloseBtn: GuiButton? = nil

local sidebarNotif: GuiObject? = nil
local sidebarNotifInner: TextLabel? = nil
local badgeSwayTween: Tween? = nil
local badgeInnerSwayTween: Tween? = nil
local badgeInnerPulseTween: Tween? = nil

local starbustConns: { RBXScriptConnection } = {}
local cardClaimWired: { [Frame]: boolean } = {}
local cardClaimHandlers: { [Frame]: () -> () } = {}
local cardClaimButtons: { [Frame]: GuiButton } = {}
local cardScales: { [Frame]: UIScale } = {}
local day5Routine: thread? = nil
local nextRewardConn: RBXScriptConnection? = nil

local lastState: DailyConfig.DailyState? = nil

local getStateRF: RemoteFunction? = nil
local claimRF: RemoteFunction? = nil
local updatedRE: RemoteEvent? = nil
local claimedRE: RemoteEvent? = nil
local promptSkipRE: RemoteEvent? = nil

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function getOrAddUIScale(obj: Instance): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Scale = 1
	s.Parent = obj
	return s
end

local function setGradientEnabledDeep(root: Instance?, enabled: boolean)
	if not root then
		return
	end
	if root:IsA("UIGradient") then
		root.Enabled = enabled
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("UIGradient") then
			d.Enabled = enabled
		end
	end
end

local function setVisible(inst: Instance?, visible: boolean)
	if not inst then
		return
	end
	if inst:IsA("GuiObject") then
		(inst :: GuiObject).Visible = visible
	elseif inst:IsA("UIGradient") then
		(inst :: UIGradient).Enabled = visible
	end
end

local function findButtonRoot(host: Instance?): GuiButton?
	if not host then
		return nil
	end
	if host:IsA("GuiButton") then
		return host
	end
	local btn = host:FindFirstChildOfClass("ImageButton") or host:FindFirstChildOfClass("TextButton")
	if btn then
		return btn :: GuiButton
	end
	return nil
end

local function findHeaderButton(name: string): GuiButton?
	if not dailyFrame then
		return nil
	end
	local header = dailyFrame:FindFirstChild("Header")
	local buttons = header and header:FindFirstChild("Buttons")
	if not buttons then
		return nil
	end
	local host = buttons:FindFirstChild(name)
	return findButtonRoot(host)
end

-- ── Sidebar badge ───────────────────────────────────────────────────────────

local function findSidebarNotif(main: ScreenGui): (GuiObject?, TextLabel?)
	local sideUI = main:FindFirstChild("SideUI")
	if not sideUI then
		return nil, nil
	end
	-- The Daily / Gifts HUD button lives somewhere under SideUI; HUDController maps Gifts → Daily.
	local giftsHost = sideUI:FindFirstChild("Gifts", true)
		or sideUI:FindFirstChild("Daily", true)
	if not giftsHost then
		return nil, nil
	end
	local notif = giftsHost:FindFirstChild("Notif")
	if not (notif and notif:IsA("GuiObject")) then
		return nil, nil
	end
	local inner = notif:FindFirstChildWhichIsA("TextLabel")
	if not inner then
		for _, name in { "!", "Text", "TextLabel", "Label", "Icon" } do
			local found = notif:FindFirstChild(name, true)
			if found and found:IsA("TextLabel") then
				inner = found
				break
			end
		end
	end
	return notif :: GuiObject, inner
end

local function stopBadgeSway()
	if badgeSwayTween then
		badgeSwayTween:Cancel()
		badgeSwayTween = nil
	end
	if badgeInnerSwayTween then
		badgeInnerSwayTween:Cancel()
		badgeInnerSwayTween = nil
	end
	if badgeInnerPulseTween then
		badgeInnerPulseTween:Cancel()
		badgeInnerPulseTween = nil
	end
	if sidebarNotif then
		sidebarNotif.Rotation = 0
	end
	if sidebarNotifInner then
		sidebarNotifInner.Rotation = 0
		local s = sidebarNotifInner:FindFirstChildOfClass("UIScale")
		if s then
			s.Scale = 1
		end
	end
end

local function startBadgeSway()
	if not sidebarNotif then
		return
	end
	stopBadgeSway()
	sidebarNotif.Rotation = -BADGE_SWAY_DEG
	badgeSwayTween = TweenService:Create(sidebarNotif, BADGE_SWAY, { Rotation = BADGE_SWAY_DEG })
	badgeSwayTween:Play()
	if sidebarNotifInner then
		sidebarNotifInner.Rotation = BADGE_INNER_SWAY_DEG
		badgeInnerSwayTween = TweenService:Create(
			sidebarNotifInner,
			BADGE_INNER_SWAY,
			{ Rotation = -BADGE_INNER_SWAY_DEG }
		)
		badgeInnerSwayTween:Play()
		local s = getOrAddUIScale(sidebarNotifInner)
		s.Scale = 0.985
		badgeInnerPulseTween = TweenService:Create(s, BADGE_INNER_PULSE, { Scale = 1.015 })
		badgeInnerPulseTween:Play()
	end
end

local function hideSidebarBadge()
	stopBadgeSway()
	if not sidebarNotif then
		return
	end
	sidebarNotif.Visible = false
	local s = sidebarNotif:FindFirstChildOfClass("UIScale")
	if s then
		s.Scale = 1
	end
end

local function showSidebarBadge()
	if not sidebarNotif then
		return
	end
	if sidebarNotif.Visible and badgeSwayTween then
		return
	end
	local s = getOrAddUIScale(sidebarNotif)
	sidebarNotif.Visible = true
	s.Scale = 0.15
	TweenService:Create(s, OPEN_NOTIF, { Scale = 1 }):Play()
	startBadgeSway()
end

-- ── Starbust / icon / day-specific animations ───────────────────────────────

local function startStarbustSpin(starbust: GuiObject)
	if starbust:GetAttribute("__SpinningStarbust") == true then
		return
	end
	starbust:SetAttribute("__SpinningStarbust", true)
	local start = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		if not starbust.Parent then
			conn:Disconnect()
			return
		end
		local elapsed = os.clock() - start
		local rot = (elapsed / STARBUST_REV_SEC) * 360
		starbust.Rotation = rot % 360
	end)
	table.insert(starbustConns, conn)
end

local function startDay7IconSway(icon: GuiObject)
	if icon:GetAttribute("__SwayingDay7Icon") == true then
		return
	end
	icon:SetAttribute("__SwayingDay7Icon", true)
	icon.Rotation = -DAY7_ICON_SWAY_DEG
	TweenService:Create(icon, DAY7_ICON_SWAY_INFO, { Rotation = DAY7_ICON_SWAY_DEG }):Play()
end

local function day5Question(card: Frame, suffix: string): GuiObject?
	local node = card:FindFirstChild("?" .. suffix)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

local function startDay5QuestionCycle(card: Frame)
	if day5Routine then
		return
	end
	local qL = day5Question(card, "L")
	local qM = day5Question(card, "M")
	local qR = day5Question(card, "R")
	if not (qL or qM or qR) then
		return
	end
	local nodes = {}
	for _, q in ipairs({ qL, qM, qR }) do
		if q then
			local s = getOrAddUIScale(q)
			s.Scale = 1
			table.insert(nodes, { node = q, scale = s })
		end
	end
	if #nodes == 0 then
		return
	end

	day5Routine = task.spawn(function()
		while dailyFrame and dailyFrame.Parent do
			for _, entry in ipairs(nodes) do
				local s = entry.scale
				TweenService:Create(s, DAY5_QUESTION_PULSE_INFO, { Scale = 1.3 }):Play()
				task.wait(DAY5_QUESTION_PULSE_INFO.Time * 0.6)
				TweenService:Create(s, DAY5_QUESTION_PULSE_INFO, { Scale = 1 }):Play()
				task.wait(DAY5_QUESTION_CYCLE_GAP)
			end
		end
		day5Routine = nil
	end)
end

local function decorateCard(card: Frame, day: number, reward: DailyConfig.DailyReward)
	local decor = card:FindFirstChild("Decor")
	if decor then
		local starbust = decor:FindFirstChild("Starbust") or decor:FindFirstChild("Starburst")
		if starbust and starbust:IsA("GuiObject") then
			startStarbustSpin(starbust :: GuiObject)
		end
	end

	-- Always-on amount/name labels
	local amount = card:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") and reward.displayAmount then
		amount.Text = reward.displayAmount
	end
	local nameLabel = card:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = "Day " .. tostring(day)
	end

	if day == 5 then
		-- The "Brianrot Name" label (typo per the studio hierarchy) reads "Legendary Brainrot".
		local brName = card:FindFirstChild("Brianrot Name") or card:FindFirstChild("Brainrot Name")
		if brName and brName:IsA("TextLabel") then
			brName.Text = reward.displayName or "Legendary Brainrot"
		end
		startDay5QuestionCycle(card)
	end

	if day == 7 then
		local icon = card:FindFirstChild("Icon")
		if icon and icon:IsA("GuiObject") then
			startDay7IconSway(icon :: GuiObject)
		end
	end
end

-- ── Card state visuals ──────────────────────────────────────────────────────

local function clickHostForCard(card: Frame): Instance?
	return card:FindFirstChild("Claim/Claimed/Locked") or card
end

local function applyCardStatus(card: Frame, status: DailyConfig.DayStatus)
	local clickHost = clickHostForCard(card)
	if not clickHost then
		return
	end

	-- Stud gradients: Claim (green) vs Claimed/Locked (gray)
	local decor = clickHost:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	if stud then
		setGradientEnabledDeep(stud:FindFirstChild("Claim"), status == "claim")
		setGradientEnabledDeep(stud:FindFirstChild("Claimed/Locked"), status ~= "claim")
	end

	-- Text labels: "Claim" vs "Claimed/Locked"; choose which one to show.
	local claimLabel = clickHost:FindFirstChild("Claim")
	local claimedLabel = clickHost:FindFirstChild("Claimed/Locked")
	local comboLabel = clickHost:FindFirstChild("Claim/Claimed/Locked")

	if claimLabel and claimLabel:IsA("TextLabel") then
		claimLabel.Visible = status == "claim"
		claimLabel.Text = "Claim"
	end
	if claimedLabel and claimedLabel:IsA("TextLabel") then
		claimedLabel.Visible = status ~= "claim"
		claimedLabel.Text = if status == "claimed" then "Claimed" else "Locked"
	end
	if comboLabel and comboLabel:IsA("TextLabel") then
		comboLabel.Text = if status == "claim" then "Claim"
			elseif status == "claimed" then "Claimed"
			else "Locked"
	end
end

local function applyCardScaleBump(card: Frame)
	local s = cardScales[card]
	if not s then
		s = getOrAddUIScale(card)
		cardScales[card] = s
	end
	s.Scale = 0.92
	TweenService:Create(s, CLAIM_FLASH_TWEEN, { Scale = 1 }):Play()
end

-- ── Claim flow ──────────────────────────────────────────────────────────────

local function fireConfettiAndShake()
	-- Reuse the existing purchase celebration (confetti template + camera shake + purchase SFX).
	GameSoundEffects.playPurchaseShake()
	local essentials = ReplicatedStorage:FindFirstChild("EssentialsShared")
	if essentials then
		local ok, mod = pcall(require, essentials:FindFirstChild("EffectsController"))
		if ok and mod and typeof(mod.celebratePurchase) == "function" then
			pcall(function()
				mod.celebratePurchase(player)
			end)
		end
	end
end

local function tryClaim(day: number, card: Frame)
	if not claimRF then
		return
	end
	local rf = claimRF
	task.spawn(function()
		local ok, success = pcall(function()
			return rf:InvokeServer(day)
		end)
		if not ok or not success then
			GameSoundEffects.playErrorNotif()
			return
		end
		UIInteractionSounds.playClick()
		applyCardScaleBump(card)
		fireConfettiAndShake()
	end)
end

local function wireCardClaim(card: Frame, day: number)
	local clickHost = clickHostForCard(card)
	local btn = findButtonRoot(clickHost)
	if not btn then
		-- The "Claim/Claimed/Locked" host might not itself be a GuiButton; promote it.
		if clickHost and clickHost:IsA("GuiObject") then
			local existing = (clickHost :: GuiObject):FindFirstChild("__DailyClaimOverlay")
			if existing and existing:IsA("TextButton") then
				btn = existing
			else
				if existing then
					existing:Destroy()
				end
				local overlay = Instance.new("TextButton")
				overlay.Name = "__DailyClaimOverlay"
				overlay.BackgroundTransparency = 1
				overlay.Text = ""
				overlay.AutoButtonColor = false
				overlay.Size = UDim2.fromScale(1, 1)
				overlay.Position = UDim2.fromScale(0, 0)
				overlay.BorderSizePixel = 0
				overlay.ZIndex = (clickHost :: GuiObject).ZIndex + 5
				overlay.Active = true
				overlay.Parent = clickHost
				btn = overlay
			end
		end
	end
	if not btn then
		return
	end
	cardClaimButtons[card] = btn
	if cardClaimWired[card] then
		return
	end
	cardClaimWired[card] = true

	local scale = getOrAddUIScale(if clickHost and clickHost:IsA("GuiObject") then clickHost :: GuiObject else btn)
	btn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		UIButtonEffects.playBorderGlisten(if clickHost and clickHost:IsA("GuiObject") then clickHost :: GuiObject else btn)
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		UIButtonEffects.hideHoverEffects(if clickHost and clickHost:IsA("GuiObject") then clickHost :: GuiObject else btn)
	end)
	btn.MouseButton1Down:Connect(function()
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, CLAIM_BTN_TWEEN, { Scale = 1.06 }):Play()
	end)
	cardClaimHandlers[card] = function()
		tryClaim(day, card)
	end
	btn.Activated:Connect(function()
		local handler = cardClaimHandlers[card]
		if handler then
			handler()
		end
	end)
end

-- ── Render state ────────────────────────────────────────────────────────────

local updateNextRewardLabel: (state: DailyConfig.DailyState?) -> ()

local function applyState(state: DailyConfig.DailyState)
	lastState = state
	if not container then
		return
	end
	for day = 1, DailyConfig.MAX_DAY do
		local card = container:FindFirstChild(tostring(day))
		if not (card and card:IsA("Frame")) then
			continue
		end
		local status = DailyConfig.statusForDay(state, day)
		applyCardStatus(card, status)
		local clickHost = clickHostForCard(card)
		local btn = cardClaimButtons[card]
		if btn then
			btn.Active = status == "claim"
			pcall(function()
				(btn :: any).Selectable = status == "claim"
			end)
		end
		-- The "Claim/Claimed/Locked" host itself should ignore pointer input outside Claim state
		if clickHost and clickHost:IsA("GuiObject") and clickHost ~= btn then
			(clickHost :: GuiObject).Active = status == "claim"
		end
	end

	if DailyConfig.hasUnclaimedReady(state) and not (dailyFrame and dailyFrame.Visible) then
		showSidebarBadge()
	else
		hideSidebarBadge()
	end

	updateNextRewardLabel(state)
end

updateNextRewardLabel = function(state: DailyConfig.DailyState?)
	if not nextRewardLabel then
		return
	end
	local snapshot = state or lastState
	if not snapshot then
		return
	end
	if snapshot.skipAll then
		nextRewardLabel.Text = "All daily rewards unlocked!"
		return
	end
	if snapshot.lastClaimedDay >= DailyConfig.MAX_DAY then
		nextRewardLabel.Text = "All rewards claimed"
		return
	end
	if snapshot.currentDay <= 0 then
		nextRewardLabel.Text = ""
		return
	end
	local remaining = math.max(0, snapshot.nextAvailableAt - os.time())
	if remaining <= 0 then
		nextRewardLabel.Text = "Next Reward: Ready!"
		return
	end
	local hours = math.floor(remaining / 3600)
	local minutes = math.floor((remaining % 3600) / 60)
	local seconds = remaining % 60
	if hours > 0 then
		nextRewardLabel.Text = string.format("Next Reward: %dh %dm %ds", hours, minutes, seconds)
	elseif minutes > 0 then
		nextRewardLabel.Text = string.format("Next Reward: %dm %ds", minutes, seconds)
	else
		nextRewardLabel.Text = string.format("Next Reward: %ds", seconds)
	end
end

-- ── Init ────────────────────────────────────────────────────────────────────

local function fetchState()
	if not getStateRF then
		return
	end
	local ok, snapshot = pcall(function()
		return getStateRF:InvokeServer()
	end)
	if ok and typeof(snapshot) == "table" then
		applyState(snapshot :: DailyConfig.DailyState)
	end
end

local DailyController = {}

function DailyController.init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[DailyController] PlayerGui.Main missing")
		return
	end

	local frames = main:WaitForChild("Frames", 30)
	dailyFrame = if frames then frames:FindFirstChild("Daily") :: Frame? else nil
	if not dailyFrame then
		warn("[DailyController] Main.Frames.Daily missing")
		return
	end
	dailyFrame.Active = false
	dailyFrame.Visible = false

	container = dailyFrame:FindFirstChild("Container") :: Frame?
	nextRewardLabel = dailyFrame:FindFirstChild("NextReward") :: TextLabel?
	if nextRewardLabel and not nextRewardLabel:IsA("TextLabel") then
		nextRewardLabel = nil
	end

	headerCloseBtn = findHeaderButton("Close")
	headerSkipBtn = findHeaderButton("SkipAll")

	if headerCloseBtn then
		UIButtonEffects.wireGlistenCloseButton(headerCloseBtn, function()
			HUDController.closeCurrentFrame()
		end)
	end
	if headerSkipBtn then
		UIButtonEffects.wireAccentButton(headerSkipBtn, function()
			if promptSkipRE then
				promptSkipRE:FireServer()
			end
		end)
	end

	if container then
		for day = 1, DailyConfig.MAX_DAY do
			local card = container:FindFirstChild(tostring(day))
			if card and card:IsA("Frame") then
				local reward = DailyConfig.REWARD_BY_DAY[day]
				if reward then
					decorateCard(card, day, reward)
				end
				wireCardClaim(card, day)
			end
		end
	end

	local sNotif, sInner = findSidebarNotif(main)
	sidebarNotif = sNotif
	sidebarNotifInner = sInner
	if sidebarNotif then
		sidebarNotif.Visible = false
	end

	-- Wait for remotes (Daily.server creates them on boot).
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("DailyRemotes", 60)
		if not folder then
			warn("[DailyController] DailyRemotes folder missing")
			return
		end
		getStateRF = folder:WaitForChild("GetDailyState", 30) :: RemoteFunction?
		claimRF = folder:WaitForChild("ClaimDaily", 30) :: RemoteFunction?
		updatedRE = folder:WaitForChild("DailyUpdated", 30) :: RemoteEvent?
		claimedRE = folder:WaitForChild("DailyClaimed", 30) :: RemoteEvent?
		promptSkipRE = folder:WaitForChild("DailyPromptSkipAll", 30) :: RemoteEvent?

		if updatedRE then
			updatedRE.OnClientEvent:Connect(function(snapshot)
				if typeof(snapshot) == "table" then
					applyState(snapshot :: DailyConfig.DailyState)
				end
			end)
		end
		if claimedRE then
			claimedRE.OnClientEvent:Connect(function()
				-- Already handled visually via tryClaim, but fire celebration as a safety net.
			end)
		end

		fetchState()
	end)

	dailyFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if dailyFrame.Visible then
			hideSidebarBadge()
			fetchState()
		else
			if lastState and DailyConfig.hasUnclaimedReady(lastState) then
				showSidebarBadge()
			end
		end
	end)

	-- Refresh countdown label once a second.
	if nextRewardConn then
		nextRewardConn:Disconnect()
		nextRewardConn = nil
	end
	local lastTickAt = 0.0
	nextRewardConn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastTickAt < 1 then
			return
		end
		lastTickAt = now
		updateNextRewardLabel(lastState)
		-- If a card just became claimable while the panel is closed, surface the badge.
		if lastState and DailyConfig.hasUnclaimedReady(lastState) then
			if not (dailyFrame and dailyFrame.Visible) then
				showSidebarBadge()
			end
		end
	end)
end

return DailyController
