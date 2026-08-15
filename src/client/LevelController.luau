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
local panelBarTween: Tween? = nil
local xpAnimToken = 0
local pendingBarAlpha: number? = nil

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

-- Keep Studio-authored text size; TextScaled blows up short strings like "Level 4".
local function lockStudioTextSize(label: TextLabel, maxSize: number?)
	if label:GetAttribute("LevelTextSizeLocked") == true then
		return
	end
	local cap = maxSize or 22
	local size = label.TextSize
	if label.TextScaled and label.AbsoluteSize.Y > 4 then
		size = math.floor(label.AbsoluteSize.Y * 0.42)
	end
	size = math.clamp(math.floor(size), 10, cap)
	label.TextScaled = false
	label.TextSize = size
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	constraint.MaxTextSize = size
	constraint.MinTextSize = math.max(8, size - 6)
	label:SetAttribute("LevelTextSizeLocked", true)
end

-- Studio bar size at wire-time is the authored max; never exceed that.
local function captureBarFullSize(fill: GuiObject)
	if fill:GetAttribute("BarFullCaptured") == true then
		return
	end
	fill:SetAttribute("BarFullXScale", fill.Size.X.Scale)
	fill:SetAttribute("BarFullXOffset", fill.Size.X.Offset)
	fill:SetAttribute("BarFullYScale", fill.Size.Y.Scale)
	fill:SetAttribute("BarFullYOffset", fill.Size.Y.Offset)
	fill:SetAttribute("BarFullCaptured", true)
end

local function barGoalSize(fill: GuiObject, alpha: number): UDim2
	captureBarFullSize(fill)
	alpha = math.clamp(alpha, 0, 1)
	local xs = (fill:GetAttribute("BarFullXScale") :: number?) or 0
	local xo = (fill:GetAttribute("BarFullXOffset") :: number?) or 0
	local ys = (fill:GetAttribute("BarFullYScale") :: number?) or fill.Size.Y.Scale
	local yo = (fill:GetAttribute("BarFullYOffset") :: number?) or fill.Size.Y.Offset
	return UDim2.new(xs * alpha, xo * alpha, ys, yo)
end

local function setProgressFill(fill: GuiObject?, alpha: number, animate: boolean?, tweenSlot: "hud" | "panel"?)
	if not fill then
		return
	end
	local goal = barGoalSize(fill, alpha)
	local slot = tweenSlot or "hud"
	if animate then
		local existing = if slot == "panel" then panelBarTween else barTween
		if existing then
			existing:Cancel()
		end
		local tw = TweenService:Create(
			fill,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = goal }
		)
		if slot == "panel" then
			panelBarTween = tw
		else
			barTween = tw
		end
		tw:Play()
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

local function spawnXpHitLight(layer: Frame, screen: Vector2)
	local lp = layer.AbsolutePosition
	local glow = Instance.new("Frame")
	glow.Name = "XpHitLight"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromOffset(screen.X - lp.X, screen.Y - lp.Y)
	glow.Size = UDim2.fromOffset(18, 18)
	glow.BackgroundColor3 = Color3.fromRGB(120, 255, 180)
	glow.BackgroundTransparency = 0.2
	glow.BorderSizePixel = 0
	glow.ZIndex = 85
	glow.Parent = layer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = glow
	TweenService:Create(glow, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(90, 90),
		BackgroundTransparency = 1,
	}):Play()
	task.delay(0.34, function()
		if glow.Parent then
			glow:Destroy()
		end
	end)
end

local function pulseLevelHudChip()
	if not hudRoot or not hudRoot:IsA("GuiObject") then
		return
	end
	local sc = hudRoot:FindFirstChild("LevelHudPulse")
	if not sc or not sc:IsA("UIScale") then
		sc = Instance.new("UIScale")
		sc.Name = "LevelHudPulse"
		sc.Parent = hudRoot
	end
	local token = ((hudRoot:GetAttribute("LevelHudPulseToken") :: number?) or 0) + 1
	hudRoot:SetAttribute("LevelHudPulseToken", token)
	sc.Scale = 0.94
	TweenService:Create(sc, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.1 })
		:Play()
	task.delay(0.08, function()
		if sc.Parent and hudRoot and hudRoot:GetAttribute("LevelHudPulseToken") == token then
			TweenService:Create(sc, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
				:Play()
		end
	end)
end

local function applyPendingHudBar()
	if pendingBarAlpha == nil then
		return
	end
	local alpha = pendingBarAlpha
	pendingBarAlpha = nil
	setProgressFill(hudBar, alpha, true, "hud")
end

local function spawnXpFloater(gain: number, onArrive: (() -> ())?)
	local main = PlayerGuiMain.ensure(player)
	local layer = ensureFloaterLayer(main)
	if not hudRoot or not hudRoot.Parent then
		if onArrive then
			onArrive()
		end
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		if onArrive then
			onArrive()
		end
		return
	end

	local function destScreen(): Vector2
		local root = hudRoot :: GuiObject
		local bar = hudBar
		if bar and bar.Parent and bar.AbsoluteSize.X > 1 then
			return bar.AbsolutePosition + bar.AbsoluteSize * 0.5
		end
		return root.AbsolutePosition + root.AbsoluteSize * 0.5
	end

	local function toLayerOffset(screen: Vector2): UDim2
		local lp = layer.AbsolutePosition
		return UDim2.fromOffset(screen.X - lp.X, screen.Y - lp.Y)
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart")
		then head
		else (character and character:FindFirstChild("HumanoidRootPart"))

	local endPos = toLayerOffset(destScreen())
	local startPos = endPos
	if anchor and anchor:IsA("BasePart") then
		local screenPos, onScreen = cam:WorldToViewportPoint(anchor.Position + Vector3.new(0, 1.35, 0))
		if onScreen then
			startPos = toLayerOffset(Vector2.new(screenPos.X, screenPos.Y))
		else
			startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 64)
		end
	else
		startPos = UDim2.fromOffset(endPos.X.Offset, endPos.Y.Offset + 64)
	end

	spawnXpHitLight(
		layer,
		Vector2.new(startPos.X.Offset + layer.AbsolutePosition.X, startPos.Y.Offset + layer.AbsolutePosition.Y)
	)

	local label = Instance.new("TextLabel")
	label.Name = "XpGainFloater"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = startPos
	label.Size = UDim2.fromOffset(0, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Text = "+" .. BrainrotEconomy.formatNumberShort(gain) .. " XP"
	label.TextColor3 = Color3.fromRGB(120, 255, 180)
	label.ZIndex = 90
	label.Parent = layer
	UiFonts.applyBodyLabel(label, 28, 17)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.6
	stroke.Color = Color3.fromRGB(20, 40, 28)
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.2 })
		:Play()

	local startX, startY = startPos.X.Offset, startPos.Y.Offset
	local liftY = startY - 34
	TweenService:Create(
		label,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.fromOffset(startX, liftY) }
	):Play()

	local progress = Instance.new("NumberValue")
	progress.Value = 0
	local fromX, fromY = startX, liftY
	local conn = progress:GetPropertyChangedSignal("Value"):Connect(function()
		local liveEnd = toLayerOffset(destScreen())
		local t = progress.Value
		local one = 1 - t
		local midX = (fromX + liveEnd.X.Offset) * 0.5
		local midY = math.min(fromY, liveEnd.Y.Offset) - 48
		local x = one * one * fromX + 2 * one * t * midX + t * t * liveEnd.X.Offset
		local y = one * one * fromY + 2 * one * t * midY + t * t * liveEnd.Y.Offset
		label.Position = UDim2.fromOffset(x, y)
	end)

	task.delay(0.14, function()
		if not label.Parent then
			conn:Disconnect()
			progress:Destroy()
			if onArrive then
				onArrive()
			end
			return
		end
		fromX = label.Position.X.Offset
		fromY = label.Position.Y.Offset
		local move = TweenService:Create(
			progress,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Value = 1 }
		)
		move:Play()
		move.Completed:Connect(function()
			conn:Disconnect()
			progress:Destroy()
			if not label.Parent then
				if onArrive then
					onArrive()
				end
				return
			end
			local dest = destScreen()
			label.Position = toLayerOffset(dest)
			spawnXpHitLight(layer, dest)
			pulseLevelHudChip()
			if onArrive then
				onArrive()
			end
			TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.3 })
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
		local shadowLabel = shadow :: TextLabel
		shadowLabel.Text = text
	end
	local alpha = LevelConfig.progressAlpha(xp, needed)
	if animateBar == true then
		pendingBarAlpha = alpha
		-- If no floater is mid-flight, apply immediately.
		setProgressFill(hudBar, alpha, true, "hud")
	else
		setProgressFill(hudBar, alpha, false, "hud")
	end
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

local function setLabelPair(host: Instance?, primaryName: string, shadowName: string?, text: string, maxSize: number?)
	if not host then
		return
	end
	local primary = host:FindFirstChild(primaryName)
	if primary and (primary:IsA("TextLabel") or primary:IsA("TextButton")) then
		lockStudioTextSize(primary :: TextLabel, maxSize)
		local primaryLabel = primary :: TextLabel
		primaryLabel.Text = text
	end
	if shadowName then
		local shadow = host:FindFirstChild(shadowName)
		if shadow and (shadow:IsA("TextLabel") or shadow:IsA("TextButton")) then
			lockStudioTextSize(shadow :: TextLabel, maxSize)
			local shadowLabel = shadow :: TextLabel
			shadowLabel.Text = text
		end
	end
end

local function resolveCashIcon(): string
	return "rbxassetid://70813633481126"
end

local function applyPrizeButton(btn: Instance?, prizeIndex: number, reward: LevelConfig.LevelReward?, claimed: boolean, cashIcon: string)
	if not btn or not btn:IsA("GuiObject") then
		return
	end
	-- Studio owns all prize text. Only swap icons + checkmarks.
	if reward then
		local iconNames = {
			"Prize " .. tostring(prizeIndex) .. " icon",
			"Icon",
		}
		for _, iconName in iconNames do
			local icon = btn:FindFirstChild(iconName, true)
			if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
				icon.Image = cashIcon
				icon.ImageTransparency = 0
				icon.Visible = true
			end
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

local function isXpProgressLabel(label: TextLabel): boolean
	local lower = string.lower(label.Name)
	local text = string.lower(label.Text)
	if string.find(lower, "editthis", 1, true) then
		return false
	end
	if string.find(lower, "xp", 1, true) or string.find(text, "xp", 1, true) then
		return true
	end
	if string.find(text, "/", 1, true) and string.find(text, "%d") then
		return true
	end
	return false
end

local function isLvlProgressLabel(label: TextLabel): boolean
	local lower = string.lower(label.Name)
	local text = string.lower(label.Text)
	if string.find(lower, "editthis", 1, true) then
		return false
	end
	if string.find(lower, "lvl", 1, true) or string.find(lower, "level", 1, true) then
		return true
	end
	if string.find(text, "lvl", 1, true) then
		return true
	end
	return false
end

local function ensureProgressLabels(progress: Instance): (TextLabel?, TextLabel?)
	local searchRoots: { Instance } = { progress }
	if levelFrame then
		table.insert(searchRoots, levelFrame)
	end

	local xpLabel: TextLabel? = nil
	local lvlLabel: TextLabel? = nil

	local function consider(label: TextLabel)
		if label:IsDescendantOf(progress) == false and label.Parent ~= progress then
			-- Prefer labels that sit on/near the progress bar.
			local okNear = false
			if progress:IsA("GuiObject") then
				local p = progress :: GuiObject
				local ly = label.AbsolutePosition.Y
				local py = p.AbsolutePosition.Y
				local ph = p.AbsoluteSize.Y
				if ph > 0 and ly >= py - 30 and ly <= py + ph + 30 then
					okNear = true
				end
			end
			if not okNear and label.Parent ~= levelFrame then
				return
			end
		end
		if not xpLabel and isXpProgressLabel(label) and not isLvlProgressLabel(label) then
			xpLabel = label
		elseif not lvlLabel and isLvlProgressLabel(label) then
			lvlLabel = label
		end
	end

	for _, root in searchRoots do
		for _, d in root:GetDescendants() do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				consider(d :: TextLabel)
			end
		end
		for _, d in root:GetChildren() do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				consider(d :: TextLabel)
			end
		end
	end

	-- Fallback: any two text labels under ProgressXP by screen X.
	if not xpLabel or not lvlLabel then
		local texts: { TextLabel } = {}
		for _, d in progress:GetDescendants() do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and not string.find(string.lower(d.Name), "editthis", 1, true) then
				table.insert(texts, d :: TextLabel)
			end
		end
		table.sort(texts, function(a, b)
			return a.AbsolutePosition.X < b.AbsolutePosition.X
		end)
		if #texts >= 2 then
			xpLabel = xpLabel or texts[1]
			lvlLabel = lvlLabel or texts[#texts]
		elseif #texts == 1 then
			xpLabel = xpLabel or texts[1]
		end
	end

	-- Studio placeholders may be missing as TextLabels — create them once on ProgressXP.
	if not xpLabel then
		local made = Instance.new("TextLabel")
		made.Name = "XpProgressText"
		made.BackgroundTransparency = 1
		made.AnchorPoint = Vector2.new(0, 0.5)
		made.Position = UDim2.new(0, 8, 0.5, 0)
		made.Size = UDim2.fromOffset(120, 22)
		made.TextXAlignment = Enum.TextXAlignment.Left
		made.TextColor3 = Color3.new(1, 1, 1)
		made.ZIndex = 5
		made.Parent = progress
		UiFonts.applyBodyLabel(made, 16, 12)
		lockStudioTextSize(made)
		xpLabel = made
	end
	if not lvlLabel then
		local made = Instance.new("TextLabel")
		made.Name = "LvlProgressText"
		made.BackgroundTransparency = 1
		made.AnchorPoint = Vector2.new(1, 0.5)
		made.Position = UDim2.new(1, -8, 0.5, 0)
		made.Size = UDim2.fromOffset(90, 22)
		made.TextXAlignment = Enum.TextXAlignment.Right
		made.TextColor3 = Color3.new(1, 1, 1)
		made.ZIndex = 5
		made.Parent = progress
		UiFonts.applyBodyLabel(made, 16, 12)
		lockStudioTextSize(made)
		lvlLabel = made
	end
	return xpLabel, lvlLabel
end

local function refreshProgressXpLabels(progress: Instance?, xp: number, needed: number, level: number, animate: boolean?)
	if not progress then
		return
	end
	local xpText = string.format("%d/%dxp", math.floor(xp), math.floor(needed))
	local lvlText = "LVL " .. tostring(level)
	local xpLabel, lvlLabel = ensureProgressLabels(progress)
	if xpLabel then
		lockStudioTextSize(xpLabel)
		if animate and xpLabel.Text ~= xpText then
			xpAnimToken += 1
			local token = xpAnimToken
			local proxy = Instance.new("NumberValue")
			local startXp = tonumber(string.match(xpLabel.Text, "^(%d+)")) or 0
			proxy.Value = startXp
			local conn = proxy:GetPropertyChangedSignal("Value"):Connect(function()
				if token ~= xpAnimToken then
					return
				end
				xpLabel.Text = string.format("%d/%dxp", math.floor(proxy.Value + 0.5), math.floor(needed))
			end)
			local tw = TweenService:Create(
				proxy,
				TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Value = xp }
			)
			tw:Play()
			tw.Completed:Connect(function()
				conn:Disconnect()
				proxy:Destroy()
				if token == xpAnimToken then
					xpLabel.Text = xpText
				end
			end)
		else
			xpLabel.Text = xpText
		end
	end
	if lvlLabel then
		lockStudioTextSize(lvlLabel)
		lvlLabel.Text = lvlText
	end
end

local function refreshLevelInfo(animateBar: boolean?)
	if not levelFrame then
		return
	end
	local playerLevel, playerXp, playerNeeded = readState()
	browseLevel = math.clamp(browseLevel, 1, LevelConfig.MAX_LEVEL)
	local rewards = LevelConfig.rewardsForLevel(browseLevel)
	local claimed = browseLevel <= playerLevel
	local cashIcon = resolveCashIcon()

	local rewardsRoot = levelFrame:FindFirstChild("Rewards")
	local main = rewardsRoot and rewardsRoot:FindFirstChild("Main")
	if main then
		local icon = main:FindFirstChild("Player Icon")
		if icon and icon:IsA("ImageLabel") then
			loadPfp(icon)
		end
	end

	local progress = levelFrame:FindFirstChild("ProgressXP")
	local fill = progress and progress:FindFirstChild("EditThisForBarFill", true)
	local fillGui = if fill and fill:IsA("GuiObject") then fill else nil
	if fillGui then
		captureBarFullSize(fillGui)
	end
	local doAnim = animateBar == true
	if browseLevel == playerLevel then
		setProgressFill(fillGui, LevelConfig.progressAlpha(playerXp, playerNeeded), doAnim, "panel")
	elseif browseLevel < playerLevel then
		setProgressFill(fillGui, 1, false, "panel")
	else
		setProgressFill(fillGui, 0, false, "panel")
	end

	local buttons = levelFrame:FindFirstChild("Buttons")
	if buttons then
		applyPrizeButton(buttons:FindFirstChild("Button2"), 1, rewards[1], claimed, cashIcon)
		applyPrizeButton(buttons:FindFirstChild("Button3"), 2, rewards[2], claimed, cashIcon)
	end
end

local function openLevelInfo()
	browseLevel = select(1, readState())
	HUDController.openFrameByName("Level Info")
	refreshLevelInfo(false)
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
		-- Remove leftover code-made overlays from older builds.
		for _, name in { "__LevelNav", "__LevelHudClick" } do
			local leftover = main:FindFirstChild(name, true)
			while leftover do
				leftover:Destroy()
				leftover = main:FindFirstChild(name, true)
			end
		end

		local left = main:FindFirstChild("Level Left", true)
		local right = main:FindFirstChild("Level Right", true)
		local function wireNav(node: Instance?, delta: number)
			if not node then
				return
			end
			local btn: GuiButton? = if node:IsA("GuiButton") then node else node:FindFirstChildWhichIsA("GuiButton", true)
			local function onNav()
				browseLevel = math.clamp(browseLevel + delta, 1, LevelConfig.MAX_LEVEL)
				UIInteractionSounds.playClick()
				refreshLevelInfo(false)
			end
			if btn then
				UIButtonEffects.wireScaleButtonAnim(btn, onNav)
			elseif node:IsA("GuiObject") then
				-- Use Studio host directly — do not invent overlay buttons.
				node.InputBegan:Connect(function(input)
					if
						input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.Touch
					then
						onNav()
					end
				end)
			end
		end
		wireNav(left, -1)
		wireNav(right, 1)
	end

	local progress = frame:FindFirstChild("ProgressXP")
	if progress then
		local fill = progress:FindFirstChild("EditThisForBarFill", true)
		if fill and fill:IsA("GuiObject") then
			captureBarFullSize(fill)
		end
	end

	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			refreshLevelInfo(false)
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
	if hudBar then
		captureBarFullSize(hudBar)
	end
	local pfp = highlight and highlight:FindFirstChild("UserPFP")
	if pfp and pfp:IsA("ImageLabel") then
		hudPfp = pfp
		loadPfp(pfp)
	end

	local clickBtn: GuiButton? = if chip:IsA("GuiButton") then chip else chip:FindFirstChildWhichIsA("GuiButton", true)
	local function openFromHud()
		UIInteractionSounds.playClick()
		openLevelInfo()
	end
	if clickBtn then
		UIButtonEffects.wireScaleButtonAnim(clickBtn, openFromHud)
	else
		-- Studio LevelOnhHud may be a Frame — click the chip itself, no overlay button.
		chip.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				openFromHud()
			end
		end)
	end

	refreshHud(false)
end

local function onXpPulse()
	local gain = player:GetAttribute(LevelConfig.LAST_XP_GAIN_ATTR)
	local g = if typeof(gain) == "number" then gain else 0
	local lv, xp, needed = readState()
	local alpha = LevelConfig.progressAlpha(xp, needed)

	-- Update level text immediately; animate bar when floater lands.
	if hudLvl then
		hudLvl.Text = "Lvl " .. tostring(lv)
	end
	local shadow = hudRoot and hudRoot:FindFirstChild("UserLVL shadow")
	if shadow and (shadow:IsA("TextLabel") or shadow:IsA("TextButton")) then
		local shadowLabel = shadow :: TextLabel
		shadowLabel.Text = "Lvl " .. tostring(lv)
	end
	pendingBarAlpha = alpha

	local function onArrive()
		applyPendingHudBar()
		if levelFrame and levelFrame.Visible then
			refreshLevelInfo(true)
		end
	end

	if g > 0 then
		spawnXpFloater(g, onArrive)
	else
		onArrive()
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
		refreshLevelInfo(true)
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
		local lv = select(1, readState())
		if hudLvl then
			hudLvl.Text = "Lvl " .. tostring(lv)
		end
		local shadow = hudRoot and hudRoot:FindFirstChild("UserLVL shadow")
		if shadow and (shadow:IsA("TextLabel") or shadow:IsA("TextButton")) then
			local shadowLabel = shadow :: TextLabel
		shadowLabel.Text = "Lvl " .. tostring(lv)
		end
		if levelFrame and levelFrame.Visible then
			refreshLevelInfo(true)
		end
	end)
	-- Bar / floater handled by XpGainPulse so we don't snap twice.
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
		local xpGainRE = remotes:FindFirstChild("PlayerXpGain")
		if xpGainRE and xpGainRE:IsA("RemoteEvent") then
			xpGainRE.OnClientEvent:Connect(function(gain: any)
				-- Attribute pulse is primary; remote is a backup if pulse was missed.
				if typeof(gain) == "number" and gain > 0 then
					local last = player:GetAttribute(LevelConfig.LAST_XP_GAIN_ATTR)
					if last ~= gain then
						player:SetAttribute(LevelConfig.LAST_XP_GAIN_ATTR, gain)
						onXpPulse()
					end
				end
			end)
		end
	end)

	refreshHud(false)
end

return M
