--[[
	StoreController
	Wires every Store panel buy button with the standard hover / click animation
	and SFX, routes purchases through PurchasePrompt (which handles the rainbow +
	confetti + purchase SFX automatically), and keeps dynamic labels fresh:
	• Cash bundle reward amounts (server-authoritative, refreshed on open).
	• Booster pack "N/2 available" counters.
	• Exclusive Brainrot / Free Brainrot disabled states.
	Also applies the VIP chat tag client-side via TextChatService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TextChatService = game:GetService("TextChatService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotEconomy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotEconomy"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)

local player = Players.LocalPlayer

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local StoreController = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getOrAddUIScale(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

-- Returns a clickable GuiButton covering `host` (creating a transparent overlay if needed).
local function ensureClickButton(host: GuiObject): GuiButton
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	local existing = host:FindFirstChild("_StoreClick")
	if existing and existing:IsA("GuiButton") then
		return existing :: GuiButton
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_StoreClick"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 50
	btn.Active = true
	btn.AutoButtonColor = false
	btn.Parent = host
	return btn
end

local function highlightOn(host: GuiObject): GuiObject?
	local decor = host:FindFirstChild("Decor")
	local highlight = decor and decor:FindFirstChild("Highlight")
	local on = highlight and highlight:FindFirstChild("On")
	if on and on:IsA("GuiObject") then
		return on :: GuiObject
	end
	return nil
end

type BuyButtonState = { enabled: boolean }

-- Wires standard hover/click anim + SFX onto a buy-button host. Returns a state table
-- so callers can enable/disable the button (e.g. owned / sold out).
local function wireBuyButton(host: GuiObject, onClick: () -> ()): BuyButtonState
	local scale = getOrAddUIScale(host)
	local on = highlightOn(host)
	if on then
		on.Visible = false
	end
	local state: BuyButtonState = { enabled = true }
	local btn = ensureClickButton(host)

	btn.MouseEnter:Connect(function()
		if not state.enabled then
			return
		end
		UIInteractionSounds.playHover()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1.06 }):Play()
		if on then
			on.Visible = true
		end
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
		if on then
			on.Visible = false
		end
	end)
	btn.MouseButton1Down:Connect(function()
		if not state.enabled then
			return
		end
		UIInteractionSounds.playClick()
		TweenService:Create(scale, CLICK_TWEEN, { Scale = 0.94 }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = if state.enabled then 1.06 else 1 }):Play()
	end)
	local function activated()
		if not state.enabled then
			GameSoundEffects.playErrorNotif()
			return
		end
		onClick()
	end
	btn.Activated:Connect(activated)
	return state
end

local function setButtonEnabled(host: GuiObject, state: BuyButtonState, enabled: boolean)
	state.enabled = enabled
	local overlay = host:FindFirstChild("_StoreDisabled")
	if not enabled then
		if not overlay then
			local f = Instance.new("Frame")
			f.Name = "_StoreDisabled"
			f.BackgroundColor3 = Color3.new(0, 0, 0)
			f.BackgroundTransparency = 0.55
			f.BorderSizePixel = 0
			f.Size = UDim2.fromScale(1, 1)
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.ZIndex = 40
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 12)
			corner.Parent = f
			f.Parent = host
		end
	elseif overlay then
		overlay:Destroy()
	end
end

local function findBuy(panel: Instance?): GuiObject?
	if not panel then
		return nil
	end
	local buyButtons = panel:FindFirstChild("BuyButtons")
	local one = buyButtons and buyButtons:FindFirstChild("1")
	if one and one:IsA("GuiObject") then
		return one :: GuiObject
	end
	return nil
end

-- ── Wiring ──────────────────────────────────────────────────────────────────────

local function wireGamePass(container: Instance, panelName: string, gamePassId: number)
	local panel = container:FindFirstChild(panelName)
	local buy = findBuy(panel)
	if not buy then
		return
	end
	wireBuyButton(buy, function()
		PurchasePrompt.promptGamePass(gamePassId)
	end)
end

local function wireProduct(panel: Instance?, productId: number)
	local buy = findBuy(panel)
	if not buy then
		return
	end
	wireBuyButton(buy, function()
		PurchasePrompt.promptProduct(productId)
	end)
end

local function wireExclusive(container: Instance)
	local panel = container:FindFirstChild("Exclusive(Ignore)")
	local buy = findBuy(panel)
	if not buy then
		return
	end
	local state = wireBuyButton(buy, function()
		if player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
			GameSoundEffects.playErrorNotif()
			return
		end
		PurchasePrompt.promptProduct(StoreConfig.PRODUCT.EXCLUSIVE_BRAINROT)
	end)
	local function refresh()
		setButtonEnabled(buy, state, player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) ~= true)
	end
	player:GetAttributeChangedSignal(StoreConfig.ATTR.EXCLUSIVE_OWNED):Connect(refresh)
	refresh()
end

local function wirePacks(container: Instance)
	for _, pack in StoreConfig.PACKS do
		local panel = container:FindFirstChild(pack.frameName)
		local buy = findBuy(panel)
		if buy and panel then
			local state = wireBuyButton(buy, function()
				PurchasePrompt.promptProduct(pack.productId)
			end)
			local availableLabel = panel:FindFirstChild("Available")
			local function refresh()
				local bought = player:GetAttribute(pack.boughtAttr)
				local count = if typeof(bought) == "number" then bought else 0
				local remaining = math.max(0, StoreConfig.PACK_PURCHASE_LIMIT - count)
				if availableLabel and (availableLabel:IsA("TextLabel") or availableLabel:IsA("TextButton")) then
					(availableLabel :: TextLabel).Text = string.format("%d/%d available", remaining, StoreConfig.PACK_PURCHASE_LIMIT)
				end
				setButtonEnabled(buy, state, remaining > 0)
			end
			player:GetAttributeChangedSignal(pack.boughtAttr):Connect(refresh)
			refresh()
		end
	end
end

local cashBundlePanels: { { panel: Instance, productId: number } } = {}

local function collectCashBundlePanels(container: Instance)
	local cash = container:FindFirstChild("Cash")
	if not cash then
		return
	end
	-- Ordered: column1[1], column1[2], column2[1], column2[2], column3[1] → bundles 1..5.
	local order = {
		{ "column1", "1", StoreConfig.PRODUCT.CASH_BUNDLE_1 },
		{ "column1", "2", StoreConfig.PRODUCT.CASH_BUNDLE_2 },
		{ "column2", "1", StoreConfig.PRODUCT.CASH_BUNDLE_3 },
		{ "column2", "2", StoreConfig.PRODUCT.CASH_BUNDLE_4 },
		{ "column3", "1", StoreConfig.PRODUCT.CASH_BUNDLE_5 },
	}
	for _, entry in order do
		local column = cash:FindFirstChild(entry[1])
		local panel = column and column:FindFirstChild(entry[2])
		if panel then
			table.insert(cashBundlePanels, { panel = panel, productId = entry[3] })
			wireProduct(panel, entry[3])
		end
	end
end

local function refreshCashBundles()
	if #cashBundlePanels == 0 then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	local rf = folder and folder:FindFirstChild("GetCashBundleRewards")
	if not rf or not rf:IsA("RemoteFunction") then
		return
	end
	task.spawn(function()
		local ok, rewards = pcall(function()
			return rf:InvokeServer()
		end)
		if not ok or typeof(rewards) ~= "table" then
			return
		end
		for _, entry in cashBundlePanels do
			local reward = rewards[entry.productId]
			if typeof(reward) == "number" then
				local info = entry.panel:FindFirstChild("Info")
				local amount = info and info:FindFirstChild("Amount")
				if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
					(amount :: TextLabel).Text = BrainrotEconomy.formatCashShort(reward)
				end
			end
		end
	end)
end

local function wireServerLuck(container: Instance)
	local panel = container:FindFirstChild("ServerLuck")
	wireProduct(panel, StoreConfig.PRODUCT.SERVER_LUCK)
end

local function wireFreeBrainrot(storeFrame: Instance)
	local quick = storeFrame:FindFirstChild("QuickButtons")
	local free = quick and quick:FindFirstChild("Free1")
	if not free or not free:IsA("GuiObject") then
		return
	end
	local freeGui = free :: GuiObject
	local remotesFolder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	local claimRE = remotesFolder and remotesFolder:FindFirstChild("ClaimFreeBrainrot")

	local state = wireBuyButton(freeGui, function()
		if player:GetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED) == true then
			GameSoundEffects.playErrorNotif()
			return
		end
		-- Satisfying scale pulse before celebrating.
		local scale = getOrAddUIScale(freeGui)
		local pulse = TweenService:Create(scale, CLICK_TWEEN, { Scale = 1.12 })
		pulse.Completed:Once(function()
			TweenService:Create(scale, POP_TWEEN, { Scale = 1 }):Play()
		end)
		pulse:Play()

		local re = claimRE or (ReplicatedStorage:FindFirstChild("StoreRemotes") and ReplicatedStorage.StoreRemotes:FindFirstChild("ClaimFreeBrainrot"))
		if re and re:IsA("RemoteEvent") then
			re:FireServer()
		end
		GameSoundEffects.playPurchase()
		GameSoundEffects.playPurchaseShake()
		pcall(function()
			require(ReplicatedStorage.EssentialsShared.EffectsController).celebratePurchase(player)
		end)
	end)

	local function refresh()
		setButtonEnabled(freeGui, state, player:GetAttribute(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED) ~= true)
	end
	player:GetAttributeChangedSignal(StoreConfig.ATTR.FREE_UNCOMMON_CLAIMED):Connect(refresh)
	refresh()
end

-- ── VIP chat tag ─────────────────────────────────────────────────────────────────

local function setupVipChatTag()
	local ok = pcall(function()
		local previous = TextChatService.OnIncomingMessage
		TextChatService.OnIncomingMessage = function(message: TextChatMessage)
			local props = Instance.new("TextChatMessageProperties")
			local source = message.TextSource
			if source then
				local sender = Players:GetPlayerByUserId(source.UserId)
				if sender and sender:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true then
					props.PrefixText = '<font color="#FFA500">[VIP]</font> ' .. message.PrefixText
				end
			end
			if previous then
				local prevProps = previous(message)
				if prevProps then
					return prevProps
				end
			end
			return props
		end
	end)
	if not ok then
		warn("[StoreController] VIP chat tag setup failed")
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────────

local function init()
	local main = PlayerGuiMain.ensure(player)
	if not main then
		warn("[StoreController] Main ScreenGui missing")
		return
	end
	local frames = main:WaitForChild("Frames")
	local storeFrame = frames:WaitForChild("Store")
	local container = storeFrame:WaitForChild("StoreFrame"):WaitForChild("Container")

	-- Gamepass panels.
	local gamepasses = container:FindFirstChild("Gamepasses")
	if gamepasses then
		wireGamePass(gamepasses, "2xCash", StoreConfig.GAMEPASS.DOUBLE_CASH)
		wireGamePass(gamepasses, "2xUpgrades", StoreConfig.GAMEPASS.DOUBLE_UPGRADES)
		wireGamePass(gamepasses, "SuperLuck", StoreConfig.GAMEPASS.SUPER_LUCK)
		wireGamePass(gamepasses, "MEGALuck", StoreConfig.GAMEPASS.MEGA_LUCK)
		wireGamePass(gamepasses, "XrayVision", StoreConfig.GAMEPASS.XRAY)
	end

	-- VIP panel sits directly under Container.
	do
		local vipBuy = findBuy(container:FindFirstChild("VIP"))
		if vipBuy then
			wireBuyButton(vipBuy, function()
				PurchasePrompt.promptGamePass(StoreConfig.GAMEPASS.VIP)
			end)
		end
	end

	wireExclusive(container)
	wireServerLuck(container)
	wirePacks(container)
	collectCashBundlePanels(container)
	wireFreeBrainrot(storeFrame)

	-- Refresh dynamic labels when the store opens and periodically while open.
	local function onStoreVisibility()
		if storeFrame.Visible then
			refreshCashBundles()
		end
	end
	storeFrame:GetPropertyChangedSignal("Visible"):Connect(onStoreVisibility)
	onStoreVisibility()

	task.spawn(function()
		while true do
			task.wait(4)
			if storeFrame.Visible then
				refreshCashBundles()
			end
		end
	end)

	setupVipChatTag()
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[StoreController]", err)
	end
end

StoreController.init = boot
return StoreController
