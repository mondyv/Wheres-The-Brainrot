-- [ACTIVE] BoostIconsController
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
local Workspace = game:GetService("Workspace")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local LuckBoost = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckBoost"))
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UiFonts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiFonts"))

local player = Players.LocalPlayer

local PULSE_UP = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_DOWN = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local BoostIconsController = {}

-- ── Tooltip (one shared frame on Main ScreenGui) ───────────────────────────────

local TOOLTIP_FADE = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MOUSE_OFFSET = Vector2.new(16, 8)
local MOUSE_OFFSET_ABOVE = Vector2.new(16, -8)
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
	for _, d in obj:GetDescendants() do
		if d:IsA("GuiObject") and not d:IsA("GuiButton") then
			d.Active = true
		end
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
	local camera = Workspace.CurrentCamera
	local viewportY = if camera then camera.ViewportSize.Y else 1080
	local tooltipHeight = tooltipFrame.AbsoluteSize.Y
	if tooltipHeight < 1 then
		tooltipHeight = 72
	end
	local offset = MOUSE_OFFSET
	if pos.Y + offset.Y + tooltipHeight > viewportY then
		offset = MOUSE_OFFSET_ABOVE
		local y = pos.Y + offset.Y - tooltipHeight
		if y < 0 then
			y = 4
		end
		tooltipFrame.Position = UDim2.fromOffset(pos.X + offset.X, y)
		return
	end
	tooltipFrame.Position = UDim2.fromOffset(pos.X + offset.X, pos.Y + offset.Y)
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
	stroke.Color = Color3.fromRGB(180, 180, 200)
	stroke.Thickness = 1
	stroke.Transparency = 0.72
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
	UiFonts.applyBodyLabel(title, 11, 7)
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
	UiFonts.applyBodyLabel(desc, 9, 6)
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
		TweenService:Create(tooltipFrame, TOOLTIP_FADE, { BackgroundTransparency = 0.55 }):Play()
		TweenService:Create(tooltipTitle, TOOLTIP_FADE, { TextTransparency = 0 }):Play()
		TweenService:Create(tooltipDesc, TOOLTIP_FADE, { TextTransparency = 0 }):Play()
	else
		tooltipFrame.BackgroundTransparency = 0.55
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

local function isMobileClient(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function bindTooltip(obj: GuiObject?, titleText: string, description: string, accent: Color3?)
	if not obj or isMobileClient() then
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
		description = "Each stand upgrade grants +25 levels (Robux)",
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
	["Autocollect"] = {
		id = StoreConfig.GAMEPASS.AUTOCOLLECT,
		attr = StoreConfig.ATTR.AUTOCOLLECT_OWNED,
		title = "Autocollect",
		description = "Collect all stand cash at once from your Autocollect pad",
	},
	["Auto Collect"] = {
		id = StoreConfig.GAMEPASS.AUTOCOLLECT,
		attr = StoreConfig.ATTR.AUTOCOLLECT_OWNED,
		title = "Autocollect",
		description = "Collect all stand cash at once from your Autocollect pad",
	},
}

local function normalizeIconName(name: string): string
	return string.gsub(string.lower(name), "%s+", "")
end

local function resolveBoostIcon(iconsFolder: Instance, iconName: string): GuiObject?
	local direct = iconsFolder:FindFirstChild(iconName)
	if direct and direct:IsA("GuiObject") then
		return direct
	end
	local want = normalizeIconName(iconName)
	for _, child in iconsFolder:GetChildren() do
		if child:IsA("GuiObject") and normalizeIconName(child.Name) == want then
			return child
		end
	end
	return nil
end

local function hideAllBoostIcons(iconsFolder: Instance)
	for _, child in iconsFolder:GetChildren() do
		if child:IsA("GuiObject") then
			child.Visible = false
		end
	end
	if iconsFolder:IsA("GuiObject") then
		(iconsFolder :: GuiObject).Visible = false
	end
end

local function refreshIconsFolderVisible(iconsFolder: Instance)
	if not iconsFolder:IsA("GuiObject") then
		return
	end
	local anyVisible = false
	for _, child in iconsFolder:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			anyVisible = true
			break
		end
	end
	(iconsFolder :: GuiObject).Visible = anyVisible
end

-- Server StoreHandler owns these attrs — don't Marketplace-poll on join (that flashes icons).
local function isGamePassOwned(def: { id: number, attr: string }): boolean
	if player:GetAttribute(def.attr) == true then
		return true
	end
	local purchasedAttr = StoreConfig.PURCHASED_GAMEPASS_ATTR_BY_ID[def.id]
	if typeof(purchasedAttr) == "string" and player:GetAttribute(purchasedAttr) == true then
		return true
	end
	local giftedAttr = StoreConfig.GIFTED_GAMEPASS_ATTR_BY_ID[def.id]
	if typeof(giftedAttr) == "string" and player:GetAttribute(giftedAttr) == true then
		return true
	end
	return false
end

local function setupIcons(iconsFolder: Instance)
	-- Place file leaves these Visible=true; hide before any ownership work.
	hideAllBoostIcons(iconsFolder)

	for iconName, def in ICON_DEFS do
		local icon = resolveBoostIcon(iconsFolder, iconName)
		if not icon then
			warn("[BoostIconsController] boost icon not found:", iconName)
			continue
		end
		icon.Visible = false
		bindTooltip(icon, def.title, def.description, readGuiAccentColor(icon))
		local function evaluate()
			icon.Visible = isGamePassOwned(def)
			refreshIconsFolderVisible(iconsFolder)
		end
		player:GetAttributeChangedSignal(def.attr):Connect(evaluate)
		evaluate()
	end
	refreshIconsFolderVisible(iconsFolder)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
		if plr ~= player then
			return
		end
		-- Already-owned prompts finish with wasPurchased=false — still refresh icons.
		if not wasPurchased then
			task.defer(function()
				for iconName, def in ICON_DEFS do
					if def.id == gamePassId then
						local icon = resolveBoostIcon(iconsFolder, iconName)
						if icon then
							icon.Visible = isGamePassOwned(def)
						end
					end
				end
				refreshIconsFolderVisible(iconsFolder)
			end)
			return
		end
		for iconName, def in ICON_DEFS do
			if def.id ~= gamePassId then
				continue
			end
			local icon = resolveBoostIcon(iconsFolder, iconName)
			if icon then
				icon.Visible = true
				refreshIconsFolderVisible(iconsFolder)
			end
		end
		task.defer(function()
			for iconName, def in ICON_DEFS do
				if def.id == gamePassId then
					local icon = resolveBoostIcon(iconsFolder, iconName)
					if icon then
						icon.Visible = isGamePassOwned(def)
					end
				end
			end
			refreshIconsFolderVisible(iconsFolder)
		end)
	end)

	-- Claim pre-owned passes so SideUI icons appear without re-buying.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
		local claim = remotes and remotes:WaitForChild("ClaimOwnedGamepass", 10)
		if not claim or not claim:IsA("RemoteEvent") then
			return
		end
		local seen: { [number]: boolean } = {}
		for _, def in ICON_DEFS do
			if seen[def.id] or isGamePassOwned(def) then
				continue
			end
			seen[def.id] = true
			local ok, owned = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
			end)
			if ok and owned == true then
				claim:FireServer(def.id)
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
	local text = string.format(if rounded == math.floor(rounded) then "%dx" else "%.1fx", rounded)
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

local booted = false

local function init()
	if booted then
		return
	end
	booted = true
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[BoostIconsController] Main ScreenGui missing")
		return
	end
	tooltipRoot = main
	ensureTooltip(main)

	local sideUI = main:WaitForChild("SideUI")
	local counters = sideUI:WaitForChild("Counters")

	-- Hide ASAP so loading/HUD reveal never flashes unowned icons from the place file.
	local earlyIcons = counters:FindFirstChild("GamepassBoostIcons")
	if earlyIcons then
		hideAllBoostIcons(earlyIcons)
	end

	local iconsFolder = counters:WaitForChild("GamepassBoostIcons", 30)
	if iconsFolder then
		hideAllBoostIcons(iconsFolder)
		setupIcons(iconsFolder)
	else
		warn("[BoostIconsController] SideUI.Counters.GamepassBoostIcons missing")
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
		end
		if overall and overall:IsA("GuiObject") then
			bindTooltip(
				overall :: GuiObject,
				"Overall Luck",
				"Combined luck multiplier from VIP, Super Luck, MEGA Luck, and server luck",
				readGuiAccentColor(overall :: GuiObject)
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
			serverLuckRE.OnClientEvent:Connect(function(_multiplier, _remaining)
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
