--[[
	BoostIconsController
	• Enables/disables the SideUI gamepass boost icons based on ownership.
	• Hover tooltips (single shared ScreenGui) on every boost icon + the CurrentBoost
	  label + the Server Luck amount.
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

-- ── Tooltip ───────────────────────────────────────────────────────────────────

local tooltipGui: ScreenGui? = nil
local tooltipLabel: TextLabel? = nil

local function ensureTooltip()
	if tooltipGui and tooltipGui.Parent then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "BoostTooltip"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 5000
	sg.Parent = player:WaitForChild("PlayerGui")

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Label"
	lbl.AutomaticSize = Enum.AutomaticSize.XY
	lbl.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	lbl.BackgroundTransparency = 0.1
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 15
	lbl.Visible = false
	lbl.ZIndex = 5001

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = lbl

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = lbl

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 110)
	stroke.Thickness = 1.5
	stroke.Parent = lbl

	lbl.Parent = sg
	tooltipGui = sg
	tooltipLabel = lbl

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or not tooltipLabel or not tooltipLabel.Visible then
			return
		end
		local pos = UserInputService:GetMouseLocation()
		tooltipLabel.Position = UDim2.fromOffset(pos.X + 14, pos.Y + 8)
	end)
end

local function bindTooltip(obj: GuiObject?, text: string)
	if not obj then
		return
	end
	obj.MouseEnter:Connect(function()
		ensureTooltip()
		if tooltipLabel then
			tooltipLabel.Text = text
			tooltipLabel.Visible = true
			local pos = UserInputService:GetMouseLocation()
			tooltipLabel.Position = UDim2.fromOffset(pos.X + 14, pos.Y + 8)
		end
	end)
	obj.MouseLeave:Connect(function()
		if tooltipLabel then
			tooltipLabel.Visible = false
		end
	end)
end

-- ── Gamepass icons ──────────────────────────────────────────────────────────────

-- iconName → { gamePassId, ownedAttr, tooltip }
local ICON_DEFS = {
	["VIP"] = { id = StoreConfig.GAMEPASS.VIP, attr = StoreConfig.ATTR.VIP_OWNED, tip = "VIP: 1.5x Cash · 4x Luck · Free Steals" },
	["2x Cash"] = { id = StoreConfig.GAMEPASS.DOUBLE_CASH, attr = StoreConfig.ATTR.DOUBLE_CASH_OWNED, tip = "2x Cash: Double income from brainrots" },
	["2x Upgrades"] = { id = StoreConfig.GAMEPASS.DOUBLE_UPGRADES, attr = StoreConfig.ATTR.DOUBLE_UPGRADES_OWNED, tip = "2x Upgrades: Each upgrade gives double levels" },
	["Super Luck"] = { id = StoreConfig.GAMEPASS.SUPER_LUCK, attr = StoreConfig.ATTR.SUPER_LUCK_OWNED, tip = "Super Luck: +100% better brainrot chances" },
	["Mega Luck"] = { id = StoreConfig.GAMEPASS.MEGA_LUCK, attr = StoreConfig.ATTR.MEGA_LUCK_OWNED, tip = "MEGA Luck: +250% better brainrot chances" },
	["X-Ray Vision"] = { id = StoreConfig.GAMEPASS.XRAY, attr = StoreConfig.ATTR.XRAY_OWNED, tip = "X-Ray Vision: See what's hiding in bushes" },
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
			bindTooltip(icon, def.tip)
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
			bindTooltip(currentBoost, "Total cash income boost from all sources")
		end
		local overall = boost:FindFirstChild("OverallLuck")
		local amount = overall and overall:FindFirstChild("Amount")
		if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
			overallLuckLabel = amount :: TextLabel
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
				bindTooltip(amt :: GuiObject, "Server-wide luck boost · affects all players")
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
