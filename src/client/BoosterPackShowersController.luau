-- [ACTIVE] BoosterPackShowersController
--[[
	Client purchase prompts for Map.Booster Pack Showers stand hitboxes.
	Group Stand: stand-style charge bar, then Main.Frames["Free Rewards"]
	(like game + join group + claim epic Nyan Cat).
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotsConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local PurchasePrompt = require(ReplicatedStorage:WaitForChild("EssentialsShared"):WaitForChild("PurchasePrompt"))
local HUDController = require(script.Parent.HUDController)
local PlayerGuiMain = require(script.Parent.PlayerGuiMain)
local UIButtonEffects = require(script.Parent.UIButtonEffects)
local UIInteractionSounds = require(script.Parent.UIInteractionSounds)
local GameSoundEffects = require(script.Parent.GameSoundEffects)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local REMOTE_FOLDER = "StoreRemotes"
local REMOTE_NAME = "BoosterShowerProductPrompt"
local GROUP_CLAIM_REMOTE_NAME = "GroupStandClaim"
local GROUP_LIKED_REMOTE_NAME = "GroupStandLiked"
local FRAME_NAME = StoreConfig.FREE_REWARDS_FRAME
local CHARGE_DURATION = 0.55
local CHARGE_GUI_NAME = "GroupStandPadCharge"
local CHARGE_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSE_DEBOUNCE = 0.22
local SHOWERS_FOLDER_NAME = "Booster Pack Showers"

local BoosterPackShowersController = {}

local groupPromptBusy = false
local likedLocal = false
local joinedLocal = false
local panelWired = false
local claimInFlight = false
local groupHitbox: BasePart? = nil
local panelOpen = false
local dismissedUntilLeave = false
local closePending: thread? = nil
local chargeAmount = 0
local charging = false
local chargeBillboard: BillboardGui? = nil
local chargeFill: Frame? = nil
local chargeFillTween: Tween? = nil
local heartbeatConn: RBXScriptConnection? = nil

local likeCheck: GuiObject? = nil
local joinCheck: GuiObject? = nil
local claimNameLabel: TextLabel? = nil

local function onPromptProduct(productId: number, productKind: string?)
	if typeof(productId) ~= "number" then
		return
	end
	if productKind == "exclusive" and player:GetAttribute(StoreConfig.ATTR.EXCLUSIVE_OWNED) == true then
		return
	end
	PurchasePrompt.promptProduct(productId)
end

local function storeFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function likedRemote(): RemoteEvent?
	local folder = storeFolder()
	local ev = folder and folder:FindFirstChild(GROUP_LIKED_REMOTE_NAME)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	return nil
end

local function claimRemote(): RemoteFunction?
	local folder = storeFolder()
	local fn = folder and folder:FindFirstChild(GROUP_CLAIM_REMOTE_NAME)
	if fn and fn:IsA("RemoteFunction") then
		return fn
	end
	return nil
end

local function alreadyClaimed(): boolean
	return player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_CLAIMED) == true
end

local function likedSaved(): boolean
	return likedLocal or player:GetAttribute(StoreConfig.ATTR.GROUP_REWARD_LIKED) == true
end

local function playerInGroup(): boolean
	local ok, inGroup = pcall(function()
		return player:IsInGroup(StoreConfig.GROUP_ID)
	end)
	return ok and inGroup == true
end

local function findRowButton(row: Instance?): GuiButton?
	if not row then
		return nil
	end
	local nested = row:FindFirstChild("Button")
	if nested and nested:IsA("GuiButton") then
		return nested
	end
	if row:IsA("GuiButton") then
		return row
	end
	return row:FindFirstChildWhichIsA("GuiButton", true)
end

local function setCheckVisible(icon: GuiObject?, on: boolean)
	if icon then
		icon.Visible = on
	end
end

local function setClaimLabel(text: string)
	if claimNameLabel then
		claimNameLabel.Text = text
	end
end

local function refreshPanelState()
	joinedLocal = joinedLocal or playerInGroup()
	likedLocal = likedSaved()
	setCheckVisible(likeCheck, likedLocal or alreadyClaimed())
	setCheckVisible(joinCheck, joinedLocal or alreadyClaimed())
	if alreadyClaimed() then
		setClaimLabel("CLAIMED")
	elseif likedLocal and joinedLocal then
		setClaimLabel("CLAIM")
	else
		setClaimLabel("CLAIM")
	end
end

local function markLiked()
	if alreadyClaimed() then
		return
	end
	likedLocal = true
	local ev = likedRemote()
	if ev then
		ev:FireServer()
	end
	refreshPanelState()
end

local function tryFavoriteCheck()
	local ok, favorited = pcall(function()
		return AvatarEditorService:GetFavoriteAsync(game.PlaceId, Enum.AvatarItemType.Asset)
	end)
	if ok and favorited == true then
		markLiked()
		return true
	end
	return false
end

local function promptLikeGame()
	if alreadyClaimed() or likedSaved() then
		refreshPanelState()
		return
	end
	if tryFavoriteCheck() then
		return
	end
	local ok, err = pcall(function()
		AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
	end)
	if not ok then
		warn("[BoosterPackShowersController] PromptSetFavorite failed:", err)
		TopNotifController.showPersonal("Couldn't open the like prompt.", "legendary", 3)
	end
end

local function promptJoinGroup()
	if groupPromptBusy then
		return
	end
	if playerInGroup() then
		joinedLocal = true
		refreshPanelState()
		return
	end
	groupPromptBusy = true
	local success, result = pcall(function()
		return GroupService:PromptJoinAsync(StoreConfig.GROUP_ID)
	end)
	groupPromptBusy = false
	if not success then
		warn("[BoosterPackShowersController] PromptJoinAsync failed:", result)
		if playerInGroup() then
			joinedLocal = true
			refreshPanelState()
		end
		return
	end
	if result == Enum.GroupMembershipStatus.Joined or result == Enum.GroupMembershipStatus.AlreadyMember then
		joinedLocal = true
		refreshPanelState()
	end
end

local function claimReward()
	if claimInFlight then
		return
	end
	if alreadyClaimed() then
		TopNotifController.showPersonal("You already claimed this reward!", "legendary", 3.5)
		return
	end
	joinedLocal = joinedLocal or playerInGroup()
	if not likedSaved() then
		TopNotifController.showPersonal("Like the game first!", "legendary", 3)
		return
	end
	if not joinedLocal then
		TopNotifController.showPersonal("Join the group first!", "legendary", 3)
		return
	end
	local rf = claimRemote()
	if not rf then
		warn("[BoosterPackShowersController] GroupStandClaim remote missing")
		return
	end
	claimInFlight = true
	if likedLocal then
		local ev = likedRemote()
		if ev then
			ev:FireServer()
		end
	end
	local granted: boolean? = nil
	local err: string? = nil
	local ok = pcall(function()
		granted, err = rf:InvokeServer()
	end)
	claimInFlight = false
	if not ok then
		warn("[BoosterPackShowersController] Claim invoke failed")
		GameSoundEffects.playErrorNotif()
		return
	end
	if granted == true then
		GameSoundEffects.playPurchase()
		setClaimLabel("CLAIMED")
		refreshPanelState()
		TopNotifController.showPersonal("Claimed Nyan Cat!", "epic", 3.5)
		return
	end
	GameSoundEffects.playErrorNotif()
	local reason = if typeof(err) == "string" then err else "claim_failed"
	if reason == "not_liked" then
		TopNotifController.showPersonal("Like the game first!", "legendary", 3)
	elseif reason == "not_in_group" then
		TopNotifController.showPersonal("Join the group first!", "legendary", 3)
	elseif reason == "already_claimed" then
		TopNotifController.showPersonal("You already claimed this reward!", "legendary", 3.5)
	else
		TopNotifController.showPersonal("Couldn't claim yet. Try again.", "legendary", 3)
	end
end

local function applyRewardPreview(frame: Frame)
	local rewards = frame:FindFirstChild("Rewards")
	local main = rewards and rewards:FindFirstChild("Main")
	if not main then
		return
	end
	local name = StoreConfig.GROUP_REWARD_BRAINROT
	local rarity = "epic"
	local rewardName = main:FindFirstChild("RewardName")
	if rewardName and (rewardName:IsA("TextLabel") or rewardName:IsA("TextButton")) then
		(rewardName :: TextLabel).Text = name
		BrainrotHeaderStyle.applyRarityLabel(rewardName, rarity)
	end
	local rarityNode = main:FindFirstChild("Rarity")
	if rarityNode then
		if rarityNode:IsA("TextLabel") or rarityNode:IsA("TextButton") then
			(rarityNode :: TextLabel).Text = "EPIC"
		end
		BrainrotHeaderStyle.applyRarityLabel(rarityNode, rarity)
	end
	local itemIcon = main:FindFirstChild("ItemIcon")
	if itemIcon then
		local image: ImageLabel? = if itemIcon:IsA("ImageLabel")
			then itemIcon
			else itemIcon:FindFirstChildWhichIsA("ImageLabel", true)
		if image then
			image.Image = BrainrotsConfig:GetNormalIcon(name)
			image.ScaleType = Enum.ScaleType.Fit
		end
	end
end

local function wireFreeRewardsPanel()
	if panelWired then
		return
	end
	local main = PlayerGuiMain.ensure(player)
	local frames = main:FindFirstChild("Frames")
	local frame = frames and frames:FindFirstChild(FRAME_NAME)
	if not frame or not frame:IsA("Frame") then
		warn("[BoosterPackShowersController] Frames['Free Rewards'] missing")
		return
	end
	panelWired = true
	applyRewardPreview(frame)

	local buttons = frame:FindFirstChild("Buttons")
	local likeRow = buttons and (buttons:FindFirstChild("Like The game") or buttons:FindFirstChild("Like The Game"))
	local joinRow = buttons and buttons:FindFirstChild("JoinTheGroupButton")
	local claimRow = buttons and buttons:FindFirstChild("ClaimButton")

	likeCheck = likeRow and likeRow:FindFirstChild("CheckMarkIcon") :: GuiObject?
	joinCheck = joinRow and joinRow:FindFirstChild("CheckMarkIcon") :: GuiObject?
	local claimName = claimRow and claimRow:FindFirstChild("Name")
	if claimName and (claimName:IsA("TextLabel") or claimName:IsA("TextButton")) then
		claimNameLabel = claimName :: TextLabel
	end

	local likeBtn = findRowButton(likeRow)
	if likeBtn then
		UIButtonEffects.wireScaleButtonAnim(likeBtn, function()
			UIInteractionSounds.playClick()
			promptLikeGame()
		end)
	end
	local joinBtn = findRowButton(joinRow)
	if joinBtn then
		UIButtonEffects.wireScaleButtonAnim(joinBtn, function()
			UIInteractionSounds.playClick()
			promptJoinGroup()
		end)
	end
	local claimBtn = findRowButton(claimRow)
	if claimBtn then
		UIButtonEffects.wireScaleButtonAnim(claimBtn, function()
			UIInteractionSounds.playClick()
			claimReward()
		end)
	end

	AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(result)
		if result == Enum.AvatarPromptResult.Success then
			markLiked()
		else
			tryFavoriteCheck()
		end
	end)

	player:GetAttributeChangedSignal(StoreConfig.ATTR.GROUP_REWARD_CLAIMED):Connect(refreshPanelState)
	player:GetAttributeChangedSignal(StoreConfig.ATTR.GROUP_REWARD_LIKED):Connect(refreshPanelState)
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			panelOpen = true
			refreshPanelState()
			return
		end
		if panelOpen then
			panelOpen = false
			dismissedUntilLeave = true
		end
	end)
	refreshPanelState()
end

local function getHRP(): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
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

	chargeBillboard = bb
	chargeFill = fill
	return fill
end

local function setChargeVisual(alpha: number)
	local fill = ensureChargeUi()
	if not fill then
		return
	end
	if chargeFillTween then
		chargeFillTween:Cancel()
	end
	chargeFillTween = TweenService:Create(fill, CHARGE_TWEEN, {
		Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1),
	})
	chargeFillTween:Play()
end

local function resetCharge()
	charging = false
	chargeAmount = 0
	destroyChargeUi()
end

local function isPointInsidePartOBB(worldPoint: Vector3, part: BasePart, padding: number): boolean
	local localPt = part.CFrame:PointToObjectSpace(worldPoint)
	local half = part.Size * 0.5 + Vector3.new(padding, padding, padding)
	return math.abs(localPt.X) <= half.X and math.abs(localPt.Y) <= half.Y and math.abs(localPt.Z) <= half.Z
end

local function findStandHitbox(stand: Instance): BasePart?
	local direct = stand:FindFirstChild("Hitbox")
	if direct and direct:IsA("BasePart") then
		return direct
	end
	local nested = stand:FindFirstChild("Hitbox", true)
	if nested and nested:IsA("BasePart") then
		return nested
	end
	for _, desc in stand:GetDescendants() do
		if desc:IsA("BasePart") and string.lower(desc.Name) == "hitbox" then
			return desc
		end
	end
	return nil
end

local function resolveGroupHitbox(): BasePart?
	if groupHitbox and groupHitbox.Parent then
		return groupHitbox
	end
	local map = Workspace:FindFirstChild("Map")
	local showers = map and map:FindFirstChild(SHOWERS_FOLDER_NAME)
	local stand = showers and showers:FindFirstChild(StoreConfig.GROUP_STAND_NAME)
	if not stand then
		return nil
	end
	groupHitbox = findStandHitbox(stand)
	return groupHitbox
end

local function cancelPendingClose()
	if closePending then
		task.cancel(closePending)
		closePending = nil
	end
end

local function openFreeRewards()
	wireFreeRewardsPanel()
	dismissedUntilLeave = false
	panelOpen = true
	HUDController.openFrameByName(FRAME_NAME)
	refreshPanelState()
end

local function scheduleClose()
	cancelPendingClose()
	closePending = task.delay(CLOSE_DEBOUNCE, function()
		closePending = nil
		panelOpen = false
		local current = HUDController.getCurrentFrame()
		if current and current.Name == FRAME_NAME then
			HUDController.closeCurrentFrame()
		end
	end)
end

local function tick(dt: number)
	local hrp = getHRP()
	local hitbox = resolveGroupHitbox()
	if not hrp or not hitbox then
		resetCharge()
		return
	end
	local inside = isPointInsidePartOBB(hrp.Position, hitbox, 2.75)
	if inside then
		cancelPendingClose()
		if dismissedUntilLeave or panelOpen then
			resetCharge()
			return
		end
		local current = HUDController.getCurrentFrame()
		if current and current.Name == FRAME_NAME then
			panelOpen = true
			resetCharge()
			return
		end
		if not charging then
			charging = true
			chargeAmount = 0
		end
		chargeAmount += dt / CHARGE_DURATION
		setChargeVisual(chargeAmount)
		if chargeAmount >= 1 then
			resetCharge()
			openFreeRewards()
		end
	else
		dismissedUntilLeave = false
		resetCharge()
		if panelOpen and not closePending then
			scheduleClose()
		end
	end
end

function BoosterPackShowersController.init()
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER, 120)
		if not folder then
			warn("[BoosterPackShowersController] StoreRemotes folder missing")
			return
		end

		local remote = folder:WaitForChild(REMOTE_NAME, 120)
		if remote and remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(function(productId: any, productKind: any)
				onPromptProduct(productId, if typeof(productKind) == "string" then productKind else nil)
			end)
		else
			warn("[BoosterPackShowersController]", REMOTE_NAME, "remote missing")
		end
	end)

	task.defer(wireFreeRewardsPanel)

	if not heartbeatConn then
		heartbeatConn = RunService.Heartbeat:Connect(function(dt)
			tick(dt)
		end)
	end
end

return BoosterPackShowersController
