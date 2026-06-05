-- [ACTIVE] XrayController
--[[
	XrayController
	With the X-Ray Vision gamepass, reveals what brainrot (if any) is hiding inside
	the currently targeted bush. Uses a single BillboardGui (adorned to the bush,
	parented to the camera) that fades in when a bush is targeted and out otherwise.
	Rarity colouring reuses BrainrotHeaderStyle so it matches the rest of the game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))
local BrainrotHeaderStyle = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotHeaderStyle"))
local BushHoldInteraction = require(script.Parent.BushHoldInteraction)

local player = Players.LocalPlayer

local BUSH_HAS_BRAINROT_ATTR = "HasHiddenBrainrot"
local BUSH_HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local BUSH_HIDDEN_NAME_ATTR = "HiddenBrainrotName"

local FADE_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local XrayController = {}

local billboard: BillboardGui? = nil
local panel: Frame? = nil
local nameLabel: TextLabel? = nil
local subLabel: TextLabel? = nil
local stroke: UIStroke? = nil
local activeBushConn: RBXScriptConnection? = nil

local function buildBillboard()
	local bb = Instance.new("BillboardGui")
	bb.Name = "XrayReveal"
	bb.Size = UDim2.fromOffset(220, 64)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 80
	bb.Enabled = false
	bb.Parent = workspace.CurrentCamera

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(15, 15, 22)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(120, 220, 150)
	st.Thickness = 2
	st.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "Name"
	nameLbl.AutomaticSize = Enum.AutomaticSize.X
	nameLbl.Size = UDim2.fromScale(0, 0)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 18
	nameLbl.TextColor3 = Color3.new(1, 1, 1)
	nameLbl.Text = ""
	nameLbl.Parent = frame

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.AutomaticSize = Enum.AutomaticSize.X
	sub.Size = UDim2.fromScale(0, 0)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.GothamMedium
	sub.TextSize = 14
	sub.TextColor3 = Color3.fromRGB(200, 200, 210)
	sub.Text = ""
	sub.Parent = frame

	billboard = bb
	panel = frame
	nameLabel = nameLbl
	subLabel = sub
	stroke = st
end

local function setVisible(visible: boolean)
	if not billboard or not panel then
		return
	end
	if visible then
		billboard.Enabled = true
		panel.BackgroundTransparency = 1
		TweenService:Create(panel, FADE_IN, { BackgroundTransparency = 0.25 }):Play()
	else
		local p = panel
		TweenService:Create(p, FADE_OUT, { BackgroundTransparency = 1 }):Play()
		task.delay(0.16, function()
			if billboard and p.BackgroundTransparency >= 0.99 then
				billboard.Enabled = false
			end
		end)
	end
end

local function adorneeFor(bush: Instance): BasePart?
	if bush:IsA("BasePart") then
		return bush :: BasePart
	end
	if bush:IsA("Model") and bush.PrimaryPart then
		return bush.PrimaryPart
	end
	return bush:FindFirstChildWhichIsA("BasePart", true)
end

local function updateForBush(bush: Instance)
	if not billboard or not nameLabel or not subLabel or not stroke then
		return
	end
	billboard.Adornee = adorneeFor(bush)

	local hasBrainrot = bush:GetAttribute(BUSH_HAS_BRAINROT_ATTR) == true
	local hiddenName = bush:GetAttribute(BUSH_HIDDEN_NAME_ATTR)
	local hiddenRarity = bush:GetAttribute(BUSH_HIDDEN_RARITY_ATTR)

	if hasBrainrot and typeof(hiddenName) == "string" and hiddenName ~= "" then
		nameLabel.Text = hiddenName
		nameLabel.TextTransparency = 0
		if typeof(hiddenRarity) == "string" then
			BrainrotHeaderStyle.applyRarityLabel(subLabel, hiddenRarity)
		else
			subLabel.Text = "???"
		end
		stroke.Color = Color3.fromRGB(120, 220, 150)
	else
		nameLabel.Text = "No brainrot hiding..."
		nameLabel.TextTransparency = 0.35
		subLabel.Text = ""
		subLabel.Visible = false
		stroke.Color = Color3.fromRGB(90, 90, 100)
	end
	subLabel.Visible = subLabel.Text ~= ""
end

local function onActiveBushChanged(bush: Instance?)
	if activeBushConn then
		activeBushConn:Disconnect()
		activeBushConn = nil
	end

	if not bush or player:GetAttribute(StoreConfig.ATTR.XRAY_OWNED) ~= true then
		setVisible(false)
		return
	end

	updateForBush(bush)
	setVisible(true)

	-- Keep the reveal in sync if the hidden loot is (re)rolled while targeted.
	activeBushConn = bush:GetAttributeChangedSignal(BUSH_HIDDEN_NAME_ATTR):Connect(function()
		updateForBush(bush)
	end)
end

local function init()
	buildBillboard()
	BushHoldInteraction.onActiveBushChanged(onActiveBushChanged)

	-- If the player buys X-Ray mid-session, refresh the current target.
	player:GetAttributeChangedSignal(StoreConfig.ATTR.XRAY_OWNED):Connect(function()
		onActiveBushChanged(BushHoldInteraction.getActiveBush())
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[XrayController]", err)
	end
end

XrayController.init = boot
return XrayController
