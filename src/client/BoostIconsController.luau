--[[
	BoostIconsController
	• Enables/disables the SideUI gamepass boost icons based on ownership.
	• Hover tooltips (one shared frame on Main) on every boost icon, CurrentBoost,
	  and OverallLuck.Amount — title + description with fade-in and mouse follow.
	• Renders the "Overall Luck" multiplier (VIP × Super × Mega × Server) with a pulse
	  animation whenever it changes.
	• Drives the ServerLuckFrame (pop-in when active, MM:SS countdown, hide when off).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local LuckBoost = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckBoost"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local PULSE_UP = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_DOWN = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local BoostIconsController = {}

-- ── Tooltip (one shared frame on Main ScreenGui) ───────────────────────────────

local TOOLTIP_FADE = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MOUSE_OFFSET = Vector2.new(16, -8)
local TOOLTIP_Z = 9999

local tooltipRoot: ScreenGui? = nil
local tooltipFrame: Frame? = nil
local tooltipTitle: TextLabel? = nil
local tooltipDesc: TextLabel? = nil
local positionConn: RBXScriptConnection? = nil
local tooltipHoverDepth = 0

local function colorToRgbTag(c: Color3): string
	return string.format(
		"rgb(%d,%d,%d)",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

-- Pull an accent color already used on this SideUI element (gradient, text, stroke, image).
local function readGuiAccentColor(obj: GuiObject): Color3
	for _, d in obj:GetDescendants() do
		if d:IsA("UIGradient") then
			local keypoints = d.Color.Keypoints
			if #keypoints > 0 then
				return keypoints[math.ceil(#keypoints / 2)].Value
			end
		end
	end
	for _, d in obj:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
			local tc = d.TextColor3
			if tc.R + tc.G + tc.B < 2.85 then
				return tc
			end
		end
	end
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		return obj.TextColor3
	end
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		local ic = obj.ImageColor3
		if ic.R + ic.G + ic.B < 2.85 then
			return ic
		end
	end
	local stroke = obj:FindFirstChildOfClass("UIStroke")
	if stroke then
		return stroke.Color
	end
	if obj.Parent and obj.Parent:IsA("GuiObject") then
		local parentStroke = obj.Parent:FindFirstChildOfClass("UIStroke")
		if parentStroke then
			return parentStroke.Color
		end
	end
	return Color3.fromRGB(255, 255, 255)
end

local function prepareHoverTarget(obj: GuiObject)
	-- ImageLabels ignore MouseEnter unless Active; enable input without changing visuals.
	if not obj:IsA("GuiButton") then
		obj.Active = true
	end
end

local function hideTooltip(force: boolean?)
	if not force and tooltipHoverDepth > 0 then
		return
	end
	tooltipHoverDepth = 0
	if positionConn then
		positionConn:Disconnect()
		positionConn = nil
	end
	if tooltipFrame then
		tooltipFrame.Visible = false
	end
end

local function updateTooltipPosition()
	if not tooltipFrame then
		return
	end
	local pos = UserInputService:GetMouseLocation()
	tooltipFrame.Position = UDim2.fromOffset(pos.X + MOUSE_OFFSET.X, pos.Y + MOUSE_OFFSET.Y)
end

local function ensureTooltip(mainGui: ScreenGui)
	if tooltipFrame and tooltipFrame.Parent then
		return
	end

	tooltipRoot = mainGui

	local frame = Instance.new("Frame")
	frame.Name = "BoostCounterTooltip"
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.BackgroundColor3 = Color3.fromRGB(8, 8, 16)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.ZIndex = TOOLTIP_Z
	frame.BorderSizePixel = 0

	local bgGrad = Instance.new("UIGradient")
	bgGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 16, 28)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 8, 16)),
	})
	bgGrad.Rotation = 90
	bgGrad.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(100, 70, 180)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.2
	stroke.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 1
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.RichText = true
	title.AutomaticSize = Enum.AutomaticSize.XY
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextTransparency = 1
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = TOOLTIP_Z + 1
	title.Parent = frame

	local desc = Instance.new("TextLabel")
	desc.Name = "Description"
	desc.LayoutOrder = 2
	desc.BackgroundTransparency = 1
	desc.Font = Enum.Font.GothamMedium
	desc.TextSize = 13
	desc.TextColor3 = Color3.fromRGB(210, 200, 230)
	desc.AutomaticSize = Enum.AutomaticSize.XY
	desc.TextTransparency = 1
	desc.TextWrapped = true
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.ZIndex = TOOLTIP_Z + 1
	desc.Parent = frame

	frame.Parent = mainGui
	tooltipFrame = frame
	tooltipTitle = title
	tooltipDesc = desc
end

local function showTooltip(titleText: string, description: string, accent: Color3)
	if not tooltipRoot then
		return
	end
	ensureTooltip(tooltipRoot)
	if not tooltipFrame or not tooltipTitle or not tooltipDesc then
		return
	end

	local rgb = colorToRgbTag(accent)
	tooltipTitle.Text = string.format("<font color='%s'>%s</font>", rgb, titleText)
	tooltipDesc.Text = description

	tooltipFrame.BackgroundTransparency = 1
	tooltipTitle.TextTransparency = 1
	tooltipDesc.TextTransparency = 1
	tooltipFrame.Visible = true
	updateTooltipPosition()

	if not positionConn then
		positionConn = RunService.RenderStepped:Connect(updateTooltipPosition)
	end

	if tooltipFrame.BackgroundTransparency > 0.5 then
		TweenService:Create(tooltipFrame, TOOLTIP_FADE, { BackgroundTransparency = 0.05 }):Play()
		TweenService:Create(tooltipTitle, TOOLTIP_FADE, { TextTransparency = 0 }):Play()
		TweenService:Create(tooltipDesc, TOOLTIP_FADE, { TextTransparency = 0 }):Play()
	else
		tooltipFrame.BackgroundTransparency = 0.05
		tooltipTitle.TextTransparency = 0
		tooltipDesc.TextTransparency = 0
	end
end

local function onTooltipEnter(titleText: string, description: string, accent: Color3)
	tooltipHoverDepth += 1
	showTooltip(titleText, description, accent)
end

local function onTooltipLeave()
	tooltipHoverDepth -= 1
	if tooltipHoverDepth <= 0 then
		tooltipHoverDepth = 0
		hideTooltip(true)
	end
end

local function bindTooltip(obj: GuiObject?, titleText: string, description: string, accent: Color3?)
	if not obj then
		return
	end
	prepareHoverTarget(obj)
	local color = accent or readGuiAccentColor(obj)
	obj.MouseEnter:Connect(function()
		onTooltipEnter(titleText, description, color)
	end)
	obj.MouseLeave:Connect(onTooltipLeave)
end

-- ── Gamepass icons ──────────────────────────────────────────────────────────────

-- iconName → { gamePassId, ownedAttr, title, description }
local ICON_DEFS = {
	["VIP"] = {
		id = StoreConfig.GAMEPASS.VIP,
		attr = StoreConfig.ATTR.VIP_OWNED,
		title = "VIP",
		description = "1.5× cash income · 4× luck · 2 free steals",
	},
	["2x Cash"] = {
		id = StoreConfig.GAMEPASS.DOUBLE_CASH,
		attr = StoreConfig.ATTR.DOUBLE_CASH_OWNED,
		title = "2× Cash",
		description = "Double income from all brainrots on your stands",
	},
	["2x Upgrades"] = {
		id = StoreConfig.GAMEPASS.DOUBLE_UPGRADES,
		attr = StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED,
		title = "2× Upgrades",
		description = "Each stand upgrade grants two levels instead of one",
	},
	["Super Luck"] = {
		id = StoreConfig.GAMEPASS.SUPER_LUCK,
		attr = StoreConfig.ATTR.SUPER_LUCK_OWNED,
		title = "Super Luck",
		description = "+100% better brainrot chances when harvesting bushes",
	},
	["Mega Luck"] = {
		id = StoreConfig.GAMEPASS.MEGA_LUCK,
		attr = StoreConfig.ATTR.MEGA_LUCK_OWNED,
		title = "MEGA Luck",
		description = "+250% better brainrot chances when harvesting bushes",
	},
	["X-Ray Vision"] = {
		id = StoreConfig.GAMEPASS.XRAY,
		attr = StoreConfig.ATTR.XRAY_OWNED,
		title = "X-Ray Vision",
		description = "See what brainrot is hiding inside targeted bushes",
	},
}

local function ownsGamePass(gamePassId: number): boolean
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	return ok and result == true
end

local function setupIcons(iconsFolder: Instance)
	for iconName, def in ICON_DEFS do
		local icon = iconsFolder:FindFirstChild(iconName)
		if icon and icon:IsA("GuiObject") then
			bindTooltip(icon, def.title, def.description, readGuiAccentColor(icon))
			local function evaluate()
				local owned = player:GetAttribute(def.attr) == true
				icon.Visible = owned
			end
			-- Initial: trust attribute if already set, else query the marketplace.
			task.spawn(function()
				if player:GetAttribute(def.attr) ~= true then
					if ownsGamePass(def.id) then
						player:SetAttribute(def.attr, true)
					end
				end
				evaluate()
			end)
			player:GetAttributeChangedSignal(def.attr):Connect(evaluate)
			evaluate()
		end
	end

	-- Re-check after any gamepass purchase in this session.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if plr ~= player or not wasPurchased then
			return
		end
		for _, def in ICON_DEFS do
			if def.id == gamePassId then
				task.spawn(function()
					if ownsGamePass(def.id) then
						player:SetAttribute(def.attr, true)
					end
				end)
			end
		end
	end)
end

-- ── Overall luck ──────────────────────────────────────────────────────────────────

local overallLuckLabel: TextLabel? = nil

local function pulse(label: GuiObject)
	local scale = label:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = label
	end
	local up = TweenService:Create(scale, PULSE_UP, { Scale = 1.25 })
	up.Completed:Once(function()
		TweenService:Create(scale, PULSE_DOWN, { Scale = 1 }):Play()
	end)
	up:Play()
end

local function refreshOverallLuck()
	if not overallLuckLabel then
		return
	end
	local total = LuckBoost.totalLuckMultiplier(player)
	local rounded = if total >= 10 then math.floor(total + 0.5) else math.floor(total * 10 + 0.5) / 10
	local text = string.format(if rounded == math.floor(rounded) then "%dx Luck" else "%.1fx Luck", rounded)
	if overallLuckLabel.Text ~= text then
		overallLuckLabel.Text = text
		pulse(overallLuckLabel)
	end
end

-- ── Server luck frame ──────────────────────────────────────────────────────────────

local serverLuckFrame: GuiObject? = nil
local serverLuckAmount: TextLabel? = nil
local serverLuckTimer: TextLabel? = nil
local lastAmountText = ""

local function formatMMSS(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function refreshServerLuckFrame()
	if not serverLuckFrame then
		return
	end
	local mult = LuckBoost.serverLuckMultiplier()
	local endsAt = ReplicatedStorage:GetAttribute(StoreConfig.SERVER_LUCK_ENDS_ATTR)
	local remaining = if typeof(endsAt) == "number" then endsAt - os.time() else 0

	if mult > 1 and remaining > 0 then
		if not serverLuckFrame.Visible then
			serverLuckFrame.Visible = true
			local scale = serverLuckFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", serverLuckFrame)
			scale.Scale = 0.8
			TweenService:Create(scale, POP_TWEEN, { Scale = 1 }):Play()
		end
		if serverLuckAmount then
			local txt = string.format("%dx", mult)
			if txt ~= lastAmountText then
				lastAmountText = txt
				serverLuckAmount.Text = txt
				pulse(serverLuckAmount)
			end
		end
		if serverLuckTimer then
			serverLuckTimer.Text = formatMMSS(remaining)
		end
	else
		if serverLuckFrame.Visible then
			serverLuckFrame.Visible = false
		end
		lastAmountText = ""
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────────

local function init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[BoostIconsController] Main ScreenGui missing")
		return
	end
	tooltipRoot = main
	ensureTooltip(main)

	local sideUI = main:WaitForChild("SideUI")
	local counters = sideUI:WaitForChild("Counters")

	local iconsFolder = counters:FindFirstChild("GamepassBoostIcons")
	if iconsFolder then
		setupIcons(iconsFolder)
	end

	local boost = counters:FindFirstChild("Boost")
	if boost then
		local currentBoost = boost:FindFirstChild("CurrentBoost")
		if currentBoost and currentBoost:IsA("GuiObject") then
			bindTooltip(
				currentBoost,
				"Cash Boost",
				"Total cash income boost from rebirths, friends, dailies, and gamepasses",
				readGuiAccentColor(currentBoost)
			)
		end
		local overall = boost:FindFirstChild("OverallLuck")
		local amount = overall and overall:FindFirstChild("Amount")
		if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
			overallLuckLabel = amount :: TextLabel
			bindTooltip(
				amount :: GuiObject,
				"Overall Luck",
				"Combined luck multiplier from VIP, Super Luck, MEGA Luck, and server luck",
				readGuiAccentColor(amount :: GuiObject)
			)
		end
	end

	local slFrame = sideUI:FindFirstChild("ServerLuckFrame")
	if slFrame and slFrame:IsA("GuiObject") then
		serverLuckFrame = slFrame
		local sl = slFrame:FindFirstChild("ServerLuck")
		if sl then
			local amt = sl:FindFirstChild("Amount")
			if amt and (amt:IsA("TextLabel") or amt:IsA("TextButton")) then
				serverLuckAmount = amt :: TextLabel
			end
			local timer = sl:FindFirstChild("Timer")
			if timer and (timer:IsA("TextLabel") or timer:IsA("TextButton")) then
				serverLuckTimer = timer :: TextLabel
			end
		end
	end

	-- Luck sources → overall luck refresh.
	for _, attr in { StoreConfig.ATTR.VIP_LUCK_MULT, StoreConfig.ATTR.SUPER_LUCK_OWNED, StoreConfig.ATTR.MEGA_LUCK_OWNED } do
		player:GetAttributeChangedSignal(attr):Connect(refreshOverallLuck)
	end
	ReplicatedStorage:GetAttributeChangedSignal(StoreConfig.SERVER_LUCK_MULT_ATTR):Connect(function()
		refreshOverallLuck()
		refreshServerLuckFrame()
	end)

	-- Also react directly to the server's per-second replication event.
	task.spawn(function()
		local storeRemotes = ReplicatedStorage:WaitForChild("StoreRemotes", 30)
		local serverLuckRE = storeRemotes and storeRemotes:WaitForChild("ServerLuckUpdated", 30)
		if serverLuckRE and serverLuckRE:IsA("RemoteEvent") then
			serverLuckRE.OnClientEvent:Connect(function(multiplier, remaining)
				warn("[ServerLuck] received update, multiplier:", multiplier, "remaining:", remaining)
				refreshOverallLuck()
				refreshServerLuckFrame()
			end)
		else
			warn("[ServerLuck] StoreRemotes.ServerLuckUpdated remote not found on client")
		end
	end)

	refreshOverallLuck()
	refreshServerLuckFrame()

	-- Live countdown for the server luck timer.
	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum >= 0.25 then
			accum = 0
			refreshServerLuckFrame()
		end
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[BoostIconsController]", err)
	end
end

BoostIconsController.init = boot
return BoostIconsController
