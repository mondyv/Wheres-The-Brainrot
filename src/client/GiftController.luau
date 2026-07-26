-- [ACTIVE] GiftController
--[[
	GiftController
	Store's Header.Buttons.Gift → Frames.Gift player picker → Store "gifting mode".

	• Populates Frames.Gift.Container from Container.Template (Label/Icon/Activation)
	  per other player currently in the server; avatar via rbxthumb headshot.
	• Selecting a player closes Gift, reopens Store, and swaps the header into
	  gifting-mode visuals (title + gradients + hides the Gift button).
	• Exposes isGifting()/getTargetUserId()/requestGiftProduct()/requestGiftGamepass()
	  so StoreController can redirect a buy click into a gift purchase instead of
	  the normal PurchasePrompt flow. The server (StoreHandler.server) validates
	  the target and redirects the actual grant.
	• Closing Store while gifting, or the recipient leaving the server, resets
	  gifting mode back to normal.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local HUDController = require(script.Parent.HUDController)
local TopNotifController = require(script.Parent.TopNotifController)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)

local player = Players.LocalPlayer

local STORE_TITLE_DEFAULT = "Store"
local STORE_TITLE_GIFTING = "Store: Choose A Gift"
local PANEL_SWAP_DELAY = 0.18
local TRANSITION_GUARD_SEC = 0.3
local REMOTE_WAIT_SEC = 15

local GiftController = {}

local storeFrame: Frame? = nil
local giftFrame: Frame? = nil
local headerNameLabel: Instance? = nil
local giftButtonHost: Instance? = nil
local normalGradient: UIGradient? = nil
local giftingGradient: UIGradient? = nil
local studNormalGradient: UIGradient? = nil
local studGiftingGradient: UIGradient? = nil
local container: Instance? = nil
local template: GuiObject? = nil

local giftTargetUserId: number? = nil
local giftTargetName: string? = nil
local isPanelTransition = false

local listPlayerAddedConn: RBXScriptConnection? = nil
local listPlayerRemovingConn: RBXScriptConnection? = nil

local giftBuyProductRE: RemoteEvent? = nil
local giftBuyGamepassRE: RemoteEvent? = nil

local giftingChangedListeners: { () -> () } = {}

local function notifyGiftingChanged()
	for _, listener in giftingChangedListeners do
		local ok, err = pcall(listener)
		if not ok then
			warn("[GiftController] onGiftingChanged error:", err)
		end
	end
end

-- ── Small helpers ────────────────────────────────────────────────────────────────

local function setLabelText(inst: Instance?, text: string)
	if inst and (inst:IsA("TextLabel") or inst:IsA("TextButton")) then
		(inst :: TextLabel).Text = text
	end
end

local function setGradientEnabled(gradient: UIGradient?, enabled: boolean)
	if gradient then
		gradient.Enabled = enabled
	end
end

-- Resolves a clickable GuiButton from a host that may already be one, or may
-- just contain one (mirrors the pattern StoreController uses for buy hosts).
local function resolveButton(host: Instance?): GuiButton?
	if not host then
		return nil
	end
	if host:IsA("GuiButton") then
		return host :: GuiButton
	end
	if host:IsA("GuiObject") then
		return host:FindFirstChildWhichIsA("GuiButton")
	end
	return nil
end

local function avatarHeadshotUrl(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

-- ── Gifting-mode visuals ───────────────────────────────────────────────────────

local function applyGiftingVisuals(active: boolean)
	setLabelText(headerNameLabel, if active then STORE_TITLE_GIFTING else STORE_TITLE_DEFAULT)
	setGradientEnabled(giftingGradient, active)
	setGradientEnabled(normalGradient, not active)
	setGradientEnabled(studGiftingGradient, active)
	setGradientEnabled(studNormalGradient, not active)
	if giftButtonHost and giftButtonHost:IsA("GuiObject") then
		(giftButtonHost :: GuiObject).Visible = not active
	end
end

local function exitGiftingMode()
	if not giftTargetUserId then
		return
	end
	giftTargetUserId = nil
	giftTargetName = nil
	applyGiftingVisuals(false)
	notifyGiftingChanged()
end

local function enterGiftingMode(targetUserId: number, targetName: string)
	giftTargetUserId = targetUserId
	giftTargetName = targetName
	applyGiftingVisuals(true)
	notifyGiftingChanged()
end

-- ── Gift picker list ───────────────────────────────────────────────────────────

local function disconnectListRefresh()
	if listPlayerAddedConn then
		listPlayerAddedConn:Disconnect()
		listPlayerAddedConn = nil
	end
	if listPlayerRemovingConn then
		listPlayerRemovingConn:Disconnect()
		listPlayerRemovingConn = nil
	end
end

local function clearGiftEntries()
	if not container then
		return
	end
	for _, child in (container :: Instance):GetChildren() do
		if child ~= template and child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local selectGiftTarget: (targetPlayer: Player) -> ()

local function buildGiftEntry(targetPlayer: Player)
	if not template or not container then
		return
	end
	local entry = (template :: GuiObject):Clone()
	entry.Name = "Gift_" .. tostring(targetPlayer.UserId)
	entry.Visible = true

	local displayName = if targetPlayer.DisplayName ~= "" then targetPlayer.DisplayName else targetPlayer.Name
	setLabelText(entry:FindFirstChild("Label"), displayName)

	local icon = entry:FindFirstChild("Icon")
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		(icon :: ImageLabel).Image = avatarHeadshotUrl(targetPlayer.UserId)
	end

	local activateBtn = resolveButton(entry:FindFirstChild("Activation"))
	if activateBtn then
		activateBtn.MouseButton1Down:Connect(function()
			UIInteractionSounds.playClick()
			selectGiftTarget(targetPlayer)
		end)
	else
		warn("[GiftController] Template.Activation missing/not a button for", targetPlayer.Name)
	end

	entry.Parent = container
end

local function refreshGiftList()
	clearGiftEntries()
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			buildGiftEntry(otherPlayer)
		end
	end
end

-- ── Panel open/close ───────────────────────────────────────────────────────────

selectGiftTarget = function(targetPlayer: Player)
	local displayName = if targetPlayer.DisplayName ~= "" then targetPlayer.DisplayName else targetPlayer.Name
	enterGiftingMode(targetPlayer.UserId, displayName)
	disconnectListRefresh()

	isPanelTransition = true
	HUDController.closeFrameByName("Gift")
	task.delay(PANEL_SWAP_DELAY, function()
		HUDController.openFrameByName("Store")
		task.delay(TRANSITION_GUARD_SEC, function()
			isPanelTransition = false
		end)
	end)
end

local function onGiftButtonActivated()
	if not giftFrame then
		return
	end
	UIInteractionSounds.playClick()
	refreshGiftList()

	disconnectListRefresh()
	listPlayerAddedConn = Players.PlayerAdded:Connect(refreshGiftList)
	listPlayerRemovingConn = Players.PlayerRemoving:Connect(function()
		task.defer(refreshGiftList)
	end)

	isPanelTransition = true
	HUDController.openFrameByName("Gift")
	task.delay(TRANSITION_GUARD_SEC, function()
		isPanelTransition = false
	end)
end

local function onGiftCloseActivated()
	UIInteractionSounds.playClick()
	disconnectListRefresh()

	isPanelTransition = true
	HUDController.closeFrameByName("Gift")
	task.delay(PANEL_SWAP_DELAY, function()
		HUDController.openFrameByName("Store")
		task.delay(TRANSITION_GUARD_SEC, function()
			isPanelTransition = false
		end)
	end)
end

-- ── Remotes ─────────────────────────────────────────────────────────────────────

local function wireGiftRemotes()
	task.spawn(function()
		local storeRemotes = ReplicatedStorage:WaitForChild("StoreRemotes", REMOTE_WAIT_SEC)
		if not storeRemotes then
			warn("[GiftController] StoreRemotes folder missing")
			return
		end

		giftBuyProductRE = storeRemotes:WaitForChild("GiftBuyProduct", REMOTE_WAIT_SEC) :: RemoteEvent?
		giftBuyGamepassRE = storeRemotes:WaitForChild("GiftBuyGamepass", REMOTE_WAIT_SEC) :: RemoteEvent?
		local resultRE = storeRemotes:WaitForChild("GiftPurchaseResult", REMOTE_WAIT_SEC) :: RemoteEvent?
		local receivedRE = storeRemotes:WaitForChild("GiftReceived", REMOTE_WAIT_SEC) :: RemoteEvent?

		if resultRE then
			resultRE.OnClientEvent:Connect(function(success: any, message: any)
				if typeof(message) ~= "string" then
					return
				end
				if success == true then
					TopNotifController.showPersonal(message, "legendary", 4)
				else
					TopNotifController.showError(message)
				end
			end)
		end

		if receivedRE then
			receivedRE.OnClientEvent:Connect(function(fromName: any, description: any)
				if typeof(fromName) ~= "string" or typeof(description) ~= "string" then
					return
				end
				TopNotifController.showPersonal(
					string.format("%s gifted you %s!", fromName, description),
					"legendary",
					5
				)
			end)
		end
	end)
end

-- ── Init ──────────────────────────────────────────────────────────────────────────

local function init()
	local main = PlayerGuiMain.ensure(player)
	local frames = main:WaitForChild("Frames")

	storeFrame = frames:WaitForChild("Store") :: Frame
	giftFrame = frames:WaitForChild("Gift") :: Frame

	local header = storeFrame:WaitForChild("Header")
	headerNameLabel = header:WaitForChild("Name")
	local headerButtons = header:WaitForChild("Buttons")
	giftButtonHost = headerButtons:WaitForChild("Gift")

	normalGradient = header:FindFirstChild("UIGradient") :: UIGradient?
	giftingGradient = header:FindFirstChild("Gifting Gradient") :: UIGradient?
	local decor = header:FindFirstChild("Decor")
	local stud = decor and decor:FindFirstChild("Stud")
	if stud then
		studNormalGradient = stud:FindFirstChild("UIGradient") :: UIGradient?
		studGiftingGradient = stud:FindFirstChild("Gifting Gradient") :: UIGradient?
	end
	if not giftingGradient or not studGiftingGradient then
		warn(
			"[GiftController] Missing 'Gifting Gradient' on Header and/or Header.Decor.Stud — add them in Studio"
		)
	end

	container = giftFrame:WaitForChild("Container")
	local templateInstance = container:WaitForChild("Template")
	templateInstance.Visible = false
	template = templateInstance :: GuiObject

	local giftButton = resolveButton(giftButtonHost)
	if giftButton then
		HUDController.applyHoverAndClick(giftButton, onGiftButtonActivated)
	else
		warn("[GiftController] Store Header.Buttons.Gift is not a GuiButton")
	end

	local giftHeader = giftFrame:FindFirstChild("Header")
	local giftHeaderButtons = giftHeader and giftHeader:FindFirstChild("Buttons")
	local giftCloseHost = giftHeaderButtons and giftHeaderButtons:FindFirstChild("Close")
	local giftCloseButton = resolveButton(giftCloseHost)
	if giftCloseButton then
		HUDController.applyHoverAndClick(giftCloseButton, onGiftCloseActivated)
	else
		warn("[GiftController] Gift.Header.Buttons.Close is not a GuiButton")
	end

	-- Recipient leaving mid-gift resets gifting mode regardless of which panel is open.
	Players.PlayerRemoving:Connect(function(leaving: Player)
		if giftTargetUserId and leaving.UserId == giftTargetUserId then
			exitGiftingMode()
		end
	end)

	-- Real Store close (not the transient Store→Gift→Store hop) exits gifting mode.
	local storeFrameInstance = storeFrame :: Frame
	storeFrameInstance:GetPropertyChangedSignal("Visible"):Connect(function()
		if storeFrameInstance.Visible or isPanelTransition then
			return
		end
		exitGiftingMode()
	end)

	wireGiftRemotes()
	applyGiftingVisuals(false)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[GiftController]", err)
	end
end

function GiftController.isGifting(): boolean
	return giftTargetUserId ~= nil
end

function GiftController.onGiftingChanged(listener: () -> ())
	table.insert(giftingChangedListeners, listener)
end

function GiftController.getTargetUserId(): number?
	return giftTargetUserId
end

function GiftController.getTargetName(): string?
	return giftTargetName
end

function GiftController.requestGiftProduct(productId: number)
	if not giftTargetUserId then
		return
	end
	if not giftBuyProductRE then
		warn("[GiftController] GiftBuyProduct remote unavailable")
		return
	end
	giftBuyProductRE:FireServer(giftTargetUserId, productId)
end

function GiftController.requestGiftGamepass(gamepassId: number)
	if not giftTargetUserId then
		return
	end
	if not giftBuyGamepassRE then
		warn("[GiftController] GiftBuyGamepass remote unavailable")
		return
	end
	giftBuyGamepassRE:FireServer(giftTargetUserId, gamepassId)
end

GiftController.init = boot
return GiftController
