-- [ACTIVE] LevelController
-- HUD level chip + Level Info panel + XP floaters + level-up celebration.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LevelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LevelConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local HUDController = require(script.Parent.HUDController)
local TopNotifController = require(script.Parent.TopNotifController)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GameSoundEffects = require(script.Parent.GameSoundEffects)

local player = Players.LocalPlayer

local M = {}

local hudRoot: GuiObject? = nil
local hudLvl: TextLabel? = nil
local hudBar: GuiObject? = nil
local hudPfp: ImageLabel? = nil

local levelFrame: Frame? = nil
local browseLevel = 1
local wired = false
local floaterLayer: Frame? = nil
local barTween: Tween? = nil

local function fireConfettiAndShake()
	local essentials = ReplicatedStorage:FindFirstChild("EssentialsShared")
	if not essentials then
		return
	end
	local ok, mod = pcall(require, essentials:FindFirstChild("EffectsController"))
	if ok and mod and typeof(mod.celebratePurchase) == "function" then
		local okCall, err = pcall(function()
			mod.celebratePurchase(player)
		end)
		if not okCall then
			warn("[LevelController] celebratePurchase failed:", err)
		end
	end
end

local function findText(root: Instance?, names: { string }): TextLabel?
	if not root then
		return nil
	end
	for _, name in names do
		local n = root:FindFirstChild(name, true)
		if n and (n:IsA("TextLabel") or n:IsA("TextButton")) then
			return n :: TextLabel
		end
	end
	return nil
end

local function setProgressFill(fill: GuiObject?, alpha: number, animate: boolean?)
	if not fill then
		return
	end
	alpha = math.clamp(alpha, 0, 1)
	local goal = UDim2.new(alpha, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
	-- If Studio used offset-only height, keep Y offset.
	if fill.Size.Y.Scale == 0 and fill.Size.Y.Offset > 0 then
		goal = UDim2.new(alpha, 0, 0, fill.Size.Y.Offset)
	elseif fill.Size.Y.Scale == 0 and fill.Size.Y.Offset == 0 then
		goal = UDim2.fromScale(alpha, 1)
	end
	if animate then
		if barTween then
			barTween:Cancel()
			barTween = nil
		end
		barTween = TweenService:Create(
			fill,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = goal }
		)
		barTween:Play()
	else
		fill.Size = goal
	end
end

local function ensureFloaterLayer(main: ScreenGui): Frame
	if floaterLayer and floaterLayer.Parent then
		return floaterLayer
	end
	local layer = Instance.new("Frame")
	layer.Name = "XpFloaterLayer"
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 80
	layer.Parent = main
	floaterLayer = layer
	return layer
end

local function spawnXpFloater(gain: number)
	local main = PlayerGuiMain.ensure(player)
	local layer = ensureFloaterLayer(main)
	if not hudRoot or not hudRoot.Parent then
		return
	end

	local dest = hudRoot.AbsolutePosition + hudRoot.AbsoluteSize * 0.5
	local start = dest + Vector2.new(0, 56)
	local lp = layer.AbsolutePosition

	local label = Instance.new("TextLabel")
	label.Name = "XpGainFloater"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(start.X - lp.X, start.Y - lp.Y)
	label.Size = UDim2.fromOffset(0, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain) .. " XP"
	label.TextColor3 = Color3.fromRGB(120, 255, 180)
	label.ZIndex = 90
	label.Parent = layer
	UiFonts.applyBodyLabel(label, 26, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.4
	stroke.Color = Color3.fromRGB(20, 40, 28)
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.15 })
		:Play()

	local progress = Instance.new("NumberValue")
	progress.Value = 0
	local fromX, fromY = start.X - lp.X, start.Y - lp.Y - 20
	label.Position = UDim2.fromOffset(fromX, fromY)
	local conn = progress:GetPropertyChangedSignal("Value"):Connect(function()
		local live = (hudRoot :: GuiObject).AbsolutePosition + (hudRoot :: GuiObject).AbsoluteSize * 0.5
		local t = progress.Value
		local one = 1 - t
		local endX, endY = live.X - lp.X, live.Y - lp.Y
		local midX = (fromX + endX) * 0.5
		local midY = math.min(fromY, endY) - 30
		local x = one * one * fromX + 2 * one * t * midX + t * t * endX
		local y = one * one * fromY + 2 * one * t * midY + t * t * endY
		label.Position = UDim2.fromOffset(x, y)
	end)

	task.delay(0.1, function()
		if not label.Parent then
			conn:Disconnect()
			progress:Destroy()
			return
		end
		local move = TweenService:Create(
			progress,
			TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Value = 1 }
		)
		move:Play()
		move.Completed:Connect(function()
			conn:Disconnect()
			progress:Destroy()
			TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.4 })
				:Play()
			TweenService:Create(label, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			}):Play()
			TweenService:Create(stroke, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
			task.delay(0.12, function()
				label:Destroy()
			end)
			-- Punch HUD chip.
			if hudRoot and hudRoot:IsA("GuiObject") then
				local sc = hudRoot:FindFirstChild("LevelHudPulse")
				if not sc or not sc:IsA("UIScale") then
					sc = Instance.new("UIScale")
					sc.Name = "LevelHudPulse"
					sc.Parent = hudRoot
				end
				sc.Scale = 1
				TweenService:Create(sc, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.12 })
					:Play()
				task.delay(0.08, function()
					if sc.Parent then
						TweenService:Create(sc, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
							:Play()
					end
				end)
			end
		end)
	end)
end

local function loadPfp(image: ImageLabel?)
	if not image then
		return
	end
	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and typeof(url) == "string" and image.Parent then
			image.Image = url
		end
	end)
end

local function readState(): (number, number, number)
	local level = player:GetAttribute(LevelConfig.LEVEL_ATTR)
	local xp = player:GetAttribute(LevelConfig.XP_ATTR)
	local needed = player:GetAttribute(LevelConfig.XP_NEEDED_ATTR)
	local lv = if typeof(level) == "number" then math.max(1, math.floor(level)) else 1
	local x = if typeof(xp) == "number" then math.max(0, math.floor(xp)) else 0
	local n = if typeof(needed) == "number" and needed > 0
		then math.floor(needed)
		else LevelConfig.xpRequiredForLevel(lv)
	return lv, x, n
end

local function refreshHud(animateBar: boolean?)
	local lv, xp, needed = readState()
	local text = "Lvl " .. tostring(lv)
	if hudLvl then
		hudLvl.Text = text
	end
	local shadow = hudRoot and hudRoot:FindFirstChild("UserLVL shadow")
	if shadow and (shadow:IsA("TextLabel") or shadow:IsA("TextButton")) then
		(shadow :: TextLabel).Text = text
	end
	setProgressFill(hudBar, LevelConfig.progressAlpha(xp, needed), animateBar == true)
end

local function setNamedVisible(host: Instance?, names: { string }, visible: boolean)
	if not host then
		return
	end
	for _, name in names do
		local n = host:FindFirstChild(name, true)
		if n and n:IsA("GuiObject") then
			n.Visible = visible
		end
	end
end

local function setLabelPair(host: Instance?, primaryName: string, shadowName: string?, text: string)
	if not host then
		return
	end
	local primary = host:FindFirstChild(primaryName)
	if primary and (primary:IsA("TextLabel") or primary:IsA("TextButton")) then
		(primary :: TextLabel).Text = text
	end
	if shadowName then
		local shadow = host:FindFirstChild(shadowName)
		if shadow and (shadow:IsA("TextLabel") or shadow:IsA("TextButton")) then
			(shadow :: TextLabel).Text = text
		end
	end
end

local function applyPrizeButton(btn: Instance?, prizeIndex: number, reward: LevelConfig.LevelReward?, claimed: boolean)
	if not btn or not btn:IsA("GuiObject") then
		return
	end
	if reward then
		local nameKey = "Prize " .. tostring(prizeIndex) .. " name"
		local shadowKey = "Prize " .. tostring(prizeIndex) .. " name shadow"
		setLabelPair(btn, nameKey, shadowKey, reward.displayAmount)
		local info = btn:FindFirstChild("Info")
		if info and (info:IsA("TextLabel") or info:IsA("TextButton")) then
			(info :: TextLabel).Text = reward.displayName
		end
		local infoShadow = btn:FindFirstChild("Info shadow")
		if infoShadow and (infoShadow:IsA("TextLabel") or infoShadow:IsA("TextButton")) then
			(infoShadow :: TextLabel).Text = reward.displayName
		end
	end
	setNamedVisible(btn, {
		"Prize " .. tostring(prizeIndex) .. " checkmark",
		"Prize 1 checkmark",
		"Prize 2 checkmark",
		"Checkmark",
		"Check",
	}, claimed)
end

local function refreshProgressXpLabels(progress: Instance?, xp: number, needed: number, level: number)
	if not progress then
		return
	end
	local xpText = string.format("%d/%dxp", math.floor(xp), math.floor(needed))
	local lvlText = "LVL " .. tostring(level)
	for _, d in progress:GetChildren() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			local lower = string.lower(d.Name)
			if string.find(lower, "xp", 1, true) or string.find(lower, "progress", 1, true) then
				d.Text = xpText
			elseif string.find(lower, "lvl", 1, true) or string.find(lower, "level", 1, true) then
				d.Text = lvlText
			end
		end
	end
	-- Fallback: unlabeled TextLabels under ProgressXP (left = XP, right = LVL).
	local texts: { TextLabel } = {}
	for _, d in progress:GetChildren() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			table.insert(texts, d :: TextLabel)
		end
	end
	if #texts == 2 then
		local a, b = texts[1], texts[2]
		if a.AbsolutePosition.X <= b.AbsolutePosition.X then
			a.Text = xpText
			b.Text = lvlText
		else
			b.Text = xpText
			a.Text = lvlText
		end
	elseif #texts == 1 then
		texts[1].Text = xpText .. "  " .. lvlText
	end
end

local function refreshLevelInfo()
	if not levelFrame then
		return
	end
	local playerLevel, playerXp, playerNeeded = readState()
	browseLevel = math.clamp(browseLevel, 1, LevelConfig.MAX_LEVEL)
	local rewards = LevelConfig.rewardsForLevel(browseLevel)
	local claimed = browseLevel <= playerLevel

	local rewardsRoot = levelFrame:FindFirstChild("Rewards")
	local main = rewardsRoot and rewardsRoot:FindFirstChild("Main")
	if main then
		setLabelPair(main, "Player Name For Profile", "Player Name For Profile Shadow", player.DisplayName)
		local levelText = "Level " .. tostring(browseLevel)
		-- Studio uses both casings.
		setLabelPair(main, "Player level for profile", "Player Level For Profile Shadow", levelText)
		setLabelPair(main, "Player Level For Profile", nil, levelText)
		local icon = main:FindFirstChild("Player Icon")
		if icon and icon:IsA("ImageLabel") then
			loadPfp(icon)
		end
	end

	local progress = levelFrame:FindFirstChild("ProgressXP")
	local fill = progress and progress:FindFirstChild("EditThisForBarFill")
	local fillGui = if fill and fill:IsA("GuiObject") then fill else nil
	if browseLevel == playerLevel then
		setProgressFill(fillGui, LevelConfig.progressAlpha(playerXp, playerNeeded), true)
		refreshProgressXpLabels(progress, playerXp, playerNeeded, browseLevel)
	elseif browseLevel < playerLevel then
		local needed = LevelConfig.xpRequiredForLevel(browseLevel)
		setProgressFill(fillGui, 1, false)
		refreshProgressXpLabels(progress, needed, needed, browseLevel)
	else
		local needed = LevelConfig.xpRequiredForLevel(browseLevel)
		setProgressFill(fillGui, 0, false)
		refreshProgressXpLabels(progress, 0, needed, browseLevel)
	end

	local buttons = levelFrame:FindFirstChild("Buttons")
	if buttons then
		applyPrizeButton(buttons:FindFirstChild("Button2"), 1, rewards[1], claimed)
		applyPrizeButton(buttons:FindFirstChild("Button3"), 2, rewards[2], claimed)
	end
end

local function openLevelInfo()
	browseLevel = select(1, readState())
	HUDController.openFrameByName("Level Info")
	refreshLevelInfo()
end

local function wireLevelInfo(frame: Frame)
	levelFrame = frame
	local header = frame:FindFirstChild("Header")
	local headerButtons = header and header:FindFirstChild("Buttons")
	local close = headerButtons and headerButtons:FindFirstChild("Close")
	if close and close:IsA("GuiButton") then
		UIButtonEffects.wireGlistenCloseButton(close, function()
			HUDController.closeFrameByName("Level Info")
		end)
	elseif close and close:IsA("GuiObject") then
		local btn = close:FindFirstChildWhichIsA("GuiButton", true)
		if btn then
			UIButtonEffects.wireGlistenCloseButton(btn, function()
				HUDController.closeFrameByName("Level Info")
			end)
		end
	end

	local rewardsRoot = frame:FindFirstChild("Rewards")
	local main = rewardsRoot and rewardsRoot:FindFirstChild("Main")
	if main then
		local left = main:FindFirstChild("Level Left", true)
		local right = main:FindFirstChild("Level Right", true)
		local function wireNav(node: Instance?, delta: number)
			if not node then
				return
			end
			local btn: GuiButton? = if node:IsA("GuiButton") then node else node:FindFirstChildWhichIsA("GuiButton", true)
			if not btn and node:IsA("GuiObject") then
				local overlay = Instance.new("TextButton")
				overlay.Name = "__LevelNav"
				overlay.BackgroundTransparency = 1
				overlay.Text = ""
				overlay.Size = UDim2.fromScale(1, 1)
				overlay.ZIndex = (node :: GuiObject).ZIndex + 2
				overlay.Parent = node
				btn = overlay
			end
			if btn then
				UIButtonEffects.wireScaleButtonAnim(btn, function()
					browseLevel = math.clamp(browseLevel + delta, 1, LevelConfig.MAX_LEVEL)
					UIInteractionSounds.playClick()
					refreshLevelInfo()
				end)
			end
		end
		wireNav(left, -1)
		wireNav(right, 1)
	end

	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			refreshLevelInfo()
		end
	end)
end

local function wireHud(main: ScreenGui)
	local side = main:FindFirstChild("SideUI")
	local lef = side and (side:FindFirstChild("Lef1") or side:FindFirstChild("Left") or side:FindFirstChild("Left1"))
	local buttons = lef and lef:FindFirstChild("Buttons")
	local other = buttons and buttons:FindFirstChild("Other")
	local chip = other and other:FindFirstChild("LevelOnhHud")
	if not chip or not chip:IsA("GuiObject") then
		warn("[LevelController] LevelOnhHud not found under SideUI")
		return
	end
	hudRoot = chip
	hudLvl = findText(chip, { "UserLVL" })
	local decor = chip:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local bar = highlight and highlight:FindFirstChild("Progress bar")
	hudBar = if bar and bar:IsA("GuiObject") then bar else nil
	local pfp = highlight and highlight:FindFirstChild("UserPFP")
	if pfp and pfp:IsA("ImageLabel") then
		hudPfp = pfp
		loadPfp(pfp)
	end

	local clickBtn: GuiButton? = if chip:IsA("GuiButton") then chip else chip:FindFirstChildWhichIsA("GuiButton", true)
	if not clickBtn then
		local overlay = Instance.new("TextButton")
		overlay.Name = "__LevelHudClick"
		overlay.BackgroundTransparency = 1
		overlay.Text = ""
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.ZIndex = chip.ZIndex + 5
		overlay.Parent = chip
		clickBtn = overlay
	end
	UIButtonEffects.wireScaleButtonAnim(clickBtn, function()
		UIInteractionSounds.playClick()
		openLevelInfo()
	end)

	refreshHud(false)
end

local function onXpPulse()
	local gain = player:GetAttribute(LevelConfig.LAST_XP_GAIN_ATTR)
	local g = if typeof(gain) == "number" then gain else 0
	if g > 0 then
		spawnXpFloater(g)
	end
	refreshHud(true)
	if levelFrame and levelFrame.Visible then
		refreshLevelInfo()
	end
end

local lastLevelCelebrateAt = 0
local function onLevelUpPulse()
	if os.clock() - lastLevelCelebrateAt < 0.6 then
		return
	end
	lastLevelCelebrateAt = os.clock()
	local to = player:GetAttribute(LevelConfig.LEVEL_UP_TO_ATTR)
	local lv = if typeof(to) == "number" then math.floor(to) else select(1, readState())
	TopNotifController.showPersonal("Level up! You reached Level " .. tostring(lv) .. "!", nil, 5)
	GameSoundEffects.playUpgrade()
	fireConfettiAndShake()
	browseLevel = lv
	refreshHud(true)
	if levelFrame and levelFrame.Visible then
		refreshLevelInfo()
	else
		task.delay(0.35, function()
			openLevelInfo()
		end)
	end
end

function M.init()
	if wired then
		return
	end
	wired = true

	local main = PlayerGuiMain.ensure(player)
	local frames = main:WaitForChild("Frames")
	local info = frames:FindFirstChild("Level Info")
	if info and info:IsA("Frame") then
		wireLevelInfo(info)
	else
		warn("[LevelController] Frames['Level Info'] missing")
	end
	wireHud(main)

	player:GetAttributeChangedSignal(LevelConfig.LEVEL_ATTR):Connect(function()
		refreshHud(true)
		if levelFrame and levelFrame.Visible then
			refreshLevelInfo()
		end
	end)
	player:GetAttributeChangedSignal(LevelConfig.XP_ATTR):Connect(function()
		refreshHud(true)
	end)
	player:GetAttributeChangedSignal(LevelConfig.XP_GAIN_PULSE_ATTR):Connect(onXpPulse)
	player:GetAttributeChangedSignal(LevelConfig.LEVEL_UP_PULSE_ATTR):Connect(onLevelUpPulse)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
		if not remotes then
			return
		end
		local levelUpRE = remotes:WaitForChild("PlayerLevelUp", 30)
		if levelUpRE and levelUpRE:IsA("RemoteEvent") then
			levelUpRE.OnClientEvent:Connect(function(reached: any)
				if typeof(reached) == "number" then
					player:SetAttribute(LevelConfig.LEVEL_UP_TO_ATTR, reached)
				end
				onLevelUpPulse()
			end)
		end
	end)

	refreshHud(false)
end

return M
