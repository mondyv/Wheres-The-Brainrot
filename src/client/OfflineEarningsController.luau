-- [ACTIVE] OfflineEarningsController
--[[
	OfflineEarnings2x join panel: shows pending offline cash, Decline keeps pad pickups,
	Double prompts the 2× Robux product. Dim covers HUD; panel mounts in a higher
	DisplayOrder host so the card stays above the black overlay.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local HUDController = require(script.Parent.HUDController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local LoadingScreenController = require(script.Parent.LoadingScreenController)
local GameplayUiVisibility = require(script.Parent.GameplayUiVisibility)
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local OfflineEarningsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OfflineEarningsConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local MobileTouchGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileTouchGate"))

local player = Players.LocalPlayer

local FRAME_NAME = "OfflineEarnings2x"
local DIM_GUI_NAME = "OfflineEarningsDim"
local PANEL_HOST_NAME = "OfflineEarningsHost"
-- Dim above Main (covers SideUI); panel host above dim so the card stays readable.
local DIM_DISPLAY_ORDER = 90
local PANEL_DISPLAY_ORDER = 95
local DIM_COLOR = Color3.fromRGB(0, 0, 0)
local DIM_TRANSPARENCY = 0.42
local AUTO_DECLINE_SEC = 45

local OPEN_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRICE_SWAY = TweenInfo.new(1.15, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local PRICE_SWAY_PX = 5
local TITLE_SWAY = TweenInfo.new(1.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local TITLE_SWAY_PX = 10

local OfflineEarningsController = {}

local panel: GuiObject? = nil
local cashLabel: TextLabel? = nil
local cashTemplate: string? = nil
local doubleBtn: GuiObject? = nil
local declineBtn: GuiObject? = nil
local priceLabel: GuiObject? = nil
local priceBasePos: UDim2? = nil
local priceSwayTween: Tween? = nil
local animateThis: GuiObject? = nil
local animateThisBasePos: UDim2? = nil
local animateThisSwayTween: Tween? = nil

local dimGui: ScreenGui? = nil
local dimFrame: Frame? = nil
local panelHost: ScreenGui? = nil
local panelHomeParent: Instance? = nil

local sessionActive = false
local pendingAmount = 0
local hiddenHud: { { inst: GuiObject, wasVisible: boolean } } = {}
local showOfflineRE: RemoteEvent? = nil
local declineOfflineRE: RemoteEvent? = nil
local doubledRE: RemoteEvent? = nil
local queuedAmount: number? = nil
local autoDeclineToken = 0
local priceLabelTemplate: string? = nil

local function getOrAddUIScale(parent: Instance): UIScale
	local s = parent:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = parent
	return s
end

local function healCoreHud()
	if LoadingScreenController.isActive() or sessionActive then
		return
	end
	-- Don't fight panel / cutscene HUD hide
	if GameplayUiVisibility.isHidden() then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	local main = playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Visible = true
		end
	end
end

local function resolveMainGui(): ScreenGui?
	local ok, main = pcall(function()
		return PlayerGuiMain.ensure(player)
	end)
	if ok and main and main:IsA("ScreenGui") then
		if not LoadingScreenController.isActive() and not sessionActive then
			main.Enabled = true
		end
		return main
	end
	return nil
end

local function hideGameplayHud(main: ScreenGui)
	if #hiddenHud > 0 then
		return
	end
	table.clear(hiddenHud)
	HUDController.closeCurrentFrame()

	local sideUI = main:FindFirstChild("SideUI")
	if sideUI and sideUI:IsA("GuiObject") then
		local gui = sideUI :: GuiObject
		table.insert(hiddenHud, { inst = gui, wasVisible = gui.Visible })
		gui.Visible = false
	end

	local frames = main:FindFirstChild("Frames")
	if frames then
		for _, ch in frames:GetChildren() do
			if ch:IsA("GuiObject") and ch.Name ~= FRAME_NAME then
				local gui = ch :: GuiObject
				table.insert(hiddenHud, { inst = gui, wasVisible = gui.Visible })
				gui.Visible = false
			end
		end
	end
end

local function restoreGameplayHud()
	for _, entry in hiddenHud do
		if entry.inst.Parent then
			entry.inst.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenHud)

	local playerGui = player:FindFirstChild("PlayerGui")
	local main = playerGui and playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			local gui = sideUI :: GuiObject
			gui.Visible = true
			local scale = getOrAddUIScale(gui)
			scale.Scale = 0.96
			TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end
end

local function showDim()
	local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end
	local gui = playerGui:FindFirstChild(DIM_GUI_NAME)
	if not gui or not gui:IsA("ScreenGui") then
		gui = Instance.new("ScreenGui")
		gui.Name = DIM_GUI_NAME
		gui.ResetOnSpawn = false
		gui.DisplayOrder = DIM_DISPLAY_ORDER
		gui.IgnoreGuiInset = true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui

		local frame = Instance.new("Frame")
		frame.Name = "Dim"
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = DIM_COLOR
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.ZIndex = 1
		frame.Active = false
		frame.Parent = gui
		dimFrame = frame
	else
		(gui :: ScreenGui).DisplayOrder = DIM_DISPLAY_ORDER
	end
	dimGui = gui :: ScreenGui
	gui.Enabled = true
	local frame = dimFrame or gui:FindFirstChild("Dim")
	if frame and frame:IsA("Frame") then
		dimFrame = frame
		TweenService:Create(frame, FADE_TWEEN, { BackgroundTransparency = DIM_TRANSPARENCY }):Play()
	end
end

local function hideDim(instant: boolean?)
	if instant then
		if dimFrame and dimFrame.Parent then
			dimFrame.BackgroundTransparency = 1
		end
		if dimGui and dimGui.Parent then
			dimGui.Enabled = false
		end
		return
	end
	if dimFrame and dimFrame.Parent then
		local frame = dimFrame
		local tween = TweenService:Create(frame, FADE_TWEEN, { BackgroundTransparency = 1 })
		tween.Completed:Once(function()
			if dimGui and dimGui.Parent then
				dimGui.Enabled = false
			end
		end)
		tween:Play()
	elseif dimGui and dimGui.Parent then
		dimGui.Enabled = false
	end
end

local function deactivateGuiTree(root: Instance)
	if root:IsA("GuiObject") then
		(root :: GuiObject).Active = false
	end
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") then
			(d :: GuiObject).Active = false
		end
	end
end

local function restoreMobileMovement()
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		for _, name in { DIM_GUI_NAME, PANEL_HOST_NAME } do
			local gui = playerGui:FindFirstChild(name)
			if gui and gui:IsA("ScreenGui") then
				gui.Enabled = false
			end
		end
	end
	MobileTouchGate.ensureTouchControlsVisible()
	MobileTouchGate.restorePlayerMovement()
end

local function releaseOverlayInput()
	if panelHost and panelHost.Parent then
		panelHost.Enabled = false
	end
	hideDim(true)

	local p = panel
	if p and p:IsA("GuiObject") then
		(p :: GuiObject).Active = false
		deactivateGuiTree(p)
		for _, d in p:GetDescendants() do
			if d.Name == "__OfflineClick" and d:IsA("GuiButton") then
				d.Active = false
			end
		end
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	local main = playerGui and playerGui:FindFirstChild("Main")
	if main and main:IsA("ScreenGui") then
		main.Enabled = true
		local frames = main:FindFirstChild("Frames")
		if frames and frames:IsA("GuiObject") then
			(frames :: GuiObject).Active = false
		end
		local sideUI = main:FindFirstChild("SideUI")
		if sideUI and sideUI:IsA("GuiObject") then
			(sideUI :: GuiObject).Active = false
		end
	end

	HUDController.syncInputPassthrough()
	restoreMobileMovement()
end

local function ensurePanelHost(): ScreenGui?
	local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return nil
	end
	local host = playerGui:FindFirstChild(PANEL_HOST_NAME)
	if not host or not host:IsA("ScreenGui") then
		host = Instance.new("ScreenGui")
		host.Name = PANEL_HOST_NAME
		host.ResetOnSpawn = false
		host.IgnoreGuiInset = true
		host.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		host.DisplayOrder = PANEL_DISPLAY_ORDER
		host.Enabled = false
		host.Parent = playerGui
	else
		(host :: ScreenGui).DisplayOrder = PANEL_DISPLAY_ORDER
	end
	panelHost = host :: ScreenGui
	return panelHost
end

local function mountPanelAboveDim(frame: GuiObject)
	local host = ensurePanelHost()
	if not host then
		return
	end
	if frame.Parent ~= host then
		panelHomeParent = frame.Parent
		frame.Parent = host
	end
	host.Enabled = true
end

local function restorePanelHome(frame: GuiObject?)
	local host = panelHost
	if host then
		host.Enabled = false
	end
	if not frame or not frame.Parent then
		return
	end
	local home = panelHomeParent
	if home and home.Parent and frame.Parent ~= home then
		frame.Parent = home
	end
end

local function resolvePriceLabel(frame: Instance): GuiObject?
	local direct = frame:FindFirstChild("DoublePriceText")
	if direct and direct:IsA("GuiObject") then
		return direct
	end
	local btn = frame:FindFirstChild("Double Button")
	if btn then
		local under = btn:FindFirstChild("DoublePriceText")
		if under and under:IsA("GuiObject") then
			return under
		end
	end
	local deep = frame:FindFirstChild("DoublePriceText", true)
	if deep and deep:IsA("GuiObject") then
		return deep
	end
	return nil
end

local function stopPriceSway()
	if priceSwayTween then
		priceSwayTween:Cancel()
		priceSwayTween = nil
	end
	if priceLabel and priceBasePos then
		priceLabel.Position = priceBasePos
	end
end

local function startPriceSway()
	stopPriceSway()
	if not priceLabel or not priceBasePos then
		return
	end
	local base = priceBasePos
	priceLabel.Position = UDim2.new(base.X.Scale, base.X.Offset - PRICE_SWAY_PX, base.Y.Scale, base.Y.Offset)
	priceSwayTween = TweenService:Create(
		priceLabel,
		PRICE_SWAY,
		{ Position = UDim2.new(base.X.Scale, base.X.Offset + PRICE_SWAY_PX, base.Y.Scale, base.Y.Offset) }
	)
	priceSwayTween:Play()
end

local function stopAnimateThisSway()
	if animateThisSwayTween then
		animateThisSwayTween:Cancel()
		animateThisSwayTween = nil
	end
	if animateThis and animateThisBasePos then
		animateThis.Position = animateThisBasePos
	end
end

local function startAnimateThisSway()
	stopAnimateThisSway()
	local target = animateThis
	if not target then
		return
	end
	if not animateThisBasePos then
		animateThisBasePos = target.Position
	end
	local base = animateThisBasePos
	target.Position = UDim2.new(base.X.Scale, base.X.Offset - TITLE_SWAY_PX, base.Y.Scale, base.Y.Offset)
	animateThisSwayTween = TweenService:Create(
		target,
		TITLE_SWAY,
		{ Position = UDim2.new(base.X.Scale, base.X.Offset + TITLE_SWAY_PX, base.Y.Scale, base.Y.Offset) }
	)
	animateThisSwayTween:Play()
end

-- Keep DoublePriceText parented to Double Button and positioned over it (Studio keeps it as a sibling).
local function attachPriceToDoubleButton()
	if not priceLabel or not doubleBtn then
		return
	end

	if doubleBtn:IsA("GuiObject") then
		(doubleBtn :: GuiObject).ClipsDescendants = false
	end

	local label = priceLabel
	label.Visible = true
	label.ZIndex = math.max(label.ZIndex, ((doubleBtn :: GuiObject).ZIndex or 1) + 5)

	-- Capture world-space alignment once while both share the panel, then reparent.
	if label.Parent ~= doubleBtn then
		local priceAbs = label.AbsolutePosition
		local priceSize = label.AbsoluteSize
		local btnAbs = doubleBtn.AbsolutePosition
		local btnSize = doubleBtn.AbsoluteSize
		local anchor = label.AnchorPoint

		local relX: number
		local relY: number
		if btnSize.X > 1 and btnSize.Y > 1 and priceSize.X > 1 then
			relX = (priceAbs.X + priceSize.X * anchor.X) - btnAbs.X
			relY = (priceAbs.Y + priceSize.Y * anchor.Y) - btnAbs.Y
		else
			-- Layout not ready — center on the button.
			relX = btnSize.X * 0.5
			relY = btnSize.Y * 0.5
			label.AnchorPoint = Vector2.new(0.5, 0.5)
		end

		label.Parent = doubleBtn
		label.Position = UDim2.fromOffset(relX, relY)
		priceBasePos = label.Position
	elseif not priceBasePos then
		priceBasePos = label.Position
	end
end

local function fillCashText(amount: number)
	if not cashLabel then
		return
	end
	local formatted = BrainrotEconomy.formatCashAccumulated(amount)
	local tmpl = cashTemplate or "You earned: ${Cash}"
	if string.find(tmpl, "${Cash}", 1, true) then
		cashLabel.Text = (string.gsub(tmpl, "%${Cash}", formatted))
	else
		cashLabel.Text = "You earned: " .. formatted
	end
end

local function refreshRobuxPrice()
	if not priceLabel or not priceLabel:IsA("TextLabel") then
		return
	end
	local label = priceLabel :: TextLabel
	if not priceLabelTemplate then
		priceLabelTemplate = label.Text
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(OfflineEarningsConfig.DOUBLE_DEV_PRODUCT_ID, Enum.InfoType.Product)
		end)
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" and label.Parent then
			local template = priceLabelTemplate or label.Text
			label.Text = string.gsub(template, "%d+", tostring(info.PriceInRobux), 1)
		end
	end)
end

local function wireButton(host: GuiObject, onClick: () -> (), alsoScale: GuiObject?)
	local scale = getOrAddUIScale(host)
	local extraScale: UIScale? = nil
	if alsoScale and alsoScale ~= host then
		extraScale = getOrAddUIScale(alsoScale)
	end
	local clickBtn = host:FindFirstChild("__OfflineClick") :: TextButton?
	if not clickBtn then
		clickBtn = Instance.new("TextButton")
		clickBtn.Name = "__OfflineClick"
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 100
		clickBtn.Parent = host
	end
	local function setScale(v: number)
		TweenService:Create(scale, HOVER_TWEEN, { Scale = v }):Play()
		if extraScale then
			TweenService:Create(extraScale, HOVER_TWEEN, { Scale = v }):Play()
		end
	end
	clickBtn.MouseEnter:Connect(function()
		UIInteractionSounds.playHover()
		setScale(1.06)
	end)
	clickBtn.MouseLeave:Connect(function()
		setScale(1)
	end)
	clickBtn.MouseButton1Down:Connect(function()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		if extraScale then
			TweenService:Create(extraScale, CLICK_TWEEN, { Scale = 0.94 }):Play()
		end
	end)
	clickBtn.MouseButton1Up:Connect(function()
		setScale(1.06)
	end)
	clickBtn.Activated:Connect(function()
		UIInteractionSounds.playClick()
		onClick()
	end)
end

local function closePanel()
	if not sessionActive then
		healCoreHud()
		return
	end
	sessionActive = false
	autoDeclineToken += 1
	stopPriceSway()
	stopAnimateThisSway()
	releaseOverlayInput()
	restoreGameplayHud()

	local p = panel
	if p and p:IsA("GuiObject") then
		-- Hide immediately so fullscreen panel children cannot keep eating mobile touches.
		(p :: GuiObject).Visible = false
		deactivateGuiTree(p)
	end
	if p and p.Parent then
		local scale = getOrAddUIScale(p)
		local tween = TweenService:Create(scale, CLOSE_TWEEN, { Scale = 0.72 })
		tween.Completed:Once(function()
			p.Visible = false
			if p:IsA("GuiObject") then
				(p :: GuiObject).Active = false
			end
			scale.Scale = 1
			restorePanelHome(p)
			releaseOverlayInput()
			healCoreHud()
		end)
		tween:Play()
	elseif p then
		p.Visible = false
		if p:IsA("GuiObject") then
			(p :: GuiObject).Active = false
		end
		restorePanelHome(p)
		releaseOverlayInput()
	end
end

local function onDecline()
	if not sessionActive then
		return
	end
	if declineOfflineRE then
		declineOfflineRE:FireServer()
	end
	closePanel()
end

local function onDouble()
	if not sessionActive then
		return
	end
	PurchasePrompt.promptProduct(OfflineEarningsConfig.DOUBLE_DEV_PRODUCT_ID)
end

local function openPanel(amount: number)
	local main = resolveMainGui()
	if not main then
		queuedAmount = amount
		return
	end
	local frames = main:FindFirstChild("Frames")
	local frame = frames and frames:FindFirstChild(FRAME_NAME)
	if not frame then
		local playerGui = player:FindFirstChild("PlayerGui")
		local host = playerGui and playerGui:FindFirstChild(PANEL_HOST_NAME)
		frame = host and host:FindFirstChild(FRAME_NAME)
	end
	if not frame or not frame:IsA("GuiObject") then
		warn("[OfflineEarningsController] Frames.OfflineEarnings2x missing")
		healCoreHud()
		return
	end
	panel = frame
	if frames and not panelHomeParent then
		panelHomeParent = frames
	end
	-- Dim covers Main/SideUI; panel is lifted into its own higher DisplayOrder host.

	declineBtn = frame:FindFirstChild("Decline Button") :: GuiObject?
	doubleBtn = frame:FindFirstChild("Double Button") :: GuiObject?
	priceLabel = resolvePriceLabel(frame)
	local title = frame:FindFirstChild("AnimateThis")
	if title and title:IsA("GuiObject") then
		animateThis = title
		animateThisBasePos = title.Position
	end
	local cash = frame:FindFirstChild("HowMuchCashYouEarnedText")
	if cash and cash:IsA("TextLabel") then
		cashLabel = cash
		if not cashTemplate then
			cashTemplate = cash.Text
		end
	end

	pendingAmount = amount
	fillCashText(amount)

	if declineBtn and not declineBtn:FindFirstChild("__OfflineClick") then
		wireButton(declineBtn, onDecline)
	end
	if doubleBtn and not doubleBtn:FindFirstChild("__OfflineClick") then
		wireButton(doubleBtn, onDouble, priceLabel)
	end

	HUDController.closeCurrentFrame()
	showDim()
	mountPanelAboveDim(frame)
	hideGameplayHud(main)
	sessionActive = true

	local scale = getOrAddUIScale(frame)
	scale.Scale = 0.78
	frame.Visible = true
	frame.ZIndex = math.max(frame.ZIndex, 20)
	TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()

	-- Stick price after the panel is visible so AbsolutePosition is valid.
	task.defer(function()
		if not sessionActive or panel ~= frame then
			return
		end
		priceLabel = resolvePriceLabel(frame)
		attachPriceToDoubleButton()
		refreshRobuxPrice()
		startPriceSway()
	end)
	startAnimateThisSway()

	autoDeclineToken += 1
	local token = autoDeclineToken
	task.delay(AUTO_DECLINE_SEC, function()
		if token ~= autoDeclineToken or not sessionActive then
			return
		end
		onDecline()
	end)
end

local function tryFlushQueue()
	if queuedAmount and not sessionActive then
		local amt = queuedAmount
		queuedAmount = nil
		openPanel(amt)
	end
end

function OfflineEarningsController.init()
	healCoreHud()

	-- Wire panel buttons immediately; remotes live under StandRemotes (not Remotes).
	local main = resolveMainGui()
	if main then
		local frames = main:FindFirstChild("Frames")
		local frame = frames and frames:FindFirstChild(FRAME_NAME)
		if frame and frame:IsA("GuiObject") then
			panel = frame
			frame.Visible = false
			declineBtn = frame:FindFirstChild("Decline Button") :: GuiObject?
			doubleBtn = frame:FindFirstChild("Double Button") :: GuiObject?
			priceLabel = resolvePriceLabel(frame)
			local cash = frame:FindFirstChild("HowMuchCashYouEarnedText")
			if cash and cash:IsA("TextLabel") then
				cashLabel = cash
				cashTemplate = cash.Text
			end
			if declineBtn then
				wireButton(declineBtn, onDecline)
			end
			if doubleBtn then
				wireButton(doubleBtn, onDouble, priceLabel)
			end
		end
	end

	task.spawn(function()
		local remotes = ReplicatedStorage:FindFirstChild("StandRemotes")
			or ReplicatedStorage:WaitForChild("StandRemotes", 15)
		if not remotes then
			warn("[OfflineEarningsController] StandRemotes folder missing")
			return
		end
		showOfflineRE = remotes:FindFirstChild("ShowOfflineEarnings") :: RemoteEvent?
			or remotes:WaitForChild("ShowOfflineEarnings", 10) :: RemoteEvent?
		declineOfflineRE = remotes:FindFirstChild("DeclineOfflineEarnings") :: RemoteEvent?
			or remotes:WaitForChild("DeclineOfflineEarnings", 10) :: RemoteEvent?
		doubledRE = remotes:FindFirstChild("OfflineEarningsDoubled") :: RemoteEvent?
			or remotes:WaitForChild("OfflineEarningsDoubled", 10) :: RemoteEvent?
		if not showOfflineRE or not declineOfflineRE then
			warn("[OfflineEarningsController] offline remotes missing under StandRemotes")
			return
		end

		showOfflineRE.OnClientEvent:Connect(function(amount: any)
			if typeof(amount) ~= "number" or amount < 1 then
				return
			end
			task.spawn(function()
				local deadline = os.clock() + 90
				while os.clock() < deadline do
					local pg = player:FindFirstChild("PlayerGui")
					local loading = pg and pg:FindFirstChild("LoadingScreen")
					local mainGui = pg and pg:FindFirstChild("Main")
					local loadingDone = not loading or not loading:IsA("ScreenGui") or not loading.Enabled
					local mainReady = mainGui and mainGui:IsA("ScreenGui") and mainGui.Enabled
					if loadingDone and mainReady then
						break
					end
					task.wait(0.25)
				end
				task.wait(0.35)
				healCoreHud()
				if sessionActive then
					queuedAmount = amount
					return
				end
				openPanel(amount)
			end)
		end)

		if doubledRE then
			doubledRE.OnClientEvent:Connect(function(_granted: any)
				closePanel()
			end)
		end

		tryFlushQueue()
	end)

	-- Periodic heal in case another system left Main/SideUI off.
	task.spawn(function()
		for _ = 1, 20 do
			task.wait(1)
			if not sessionActive then
				healCoreHud()
			end
		end
	end)
end

return OfflineEarningsController
