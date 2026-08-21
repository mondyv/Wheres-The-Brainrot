-- [ACTIVE] MailboxFeedbackController
--[[
	Map["Booster Pack Showers"].Mailbox: outline when nearby, custom proximity prompt.
	Press opens Roblox in-experience leave-feedback (SocialService).
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local ProximityPromptEffects = require(script.Parent.ProximityPromptEffects)
local TopNotifController = require(script.Parent.TopNotifController)

local player = Players.LocalPlayer

local SHOWERS_FOLDER_NAME = "Booster Pack Showers"
local MAILBOX_NAME = "Mailbox"
local PROMPT_NAME = "MailboxFeedbackPrompt"
local HIGHLIGHT_NAME = "MailboxFeedbackHighlight"
local MAX_DISTANCE = 12

local MailboxFeedbackController = {}

local boundRoot: Instance? = nil
local prompt: ProximityPrompt? = nil
local highlight: Highlight? = nil
local promptConn: RBXScriptConnection? = nil
local shownConn: RBXScriptConnection? = nil
local hiddenConn: RBXScriptConnection? = nil
local ancestryConn: RBXScriptConnection? = nil
local prompting = false
local studioHintShown = false

local function resolveHostPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") then
		return root.PrimaryPart or root:FindFirstChildWhichIsA("BasePart", true)
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function findMailbox(): Instance?
	local map = Workspace:FindFirstChild("Map")
	local showers = map and map:FindFirstChild(SHOWERS_FOLDER_NAME)
	local mailbox = showers and showers:FindFirstChild(MAILBOX_NAME)
	return mailbox
end

local function setOutlineVisible(on: boolean)
	if highlight and highlight.Parent then
		highlight.Enabled = on
	end
end

local function destroyBound()
	if promptConn then
		promptConn:Disconnect()
		promptConn = nil
	end
	if shownConn then
		shownConn:Disconnect()
		shownConn = nil
	end
	if hiddenConn then
		hiddenConn:Disconnect()
		hiddenConn = nil
	end
	if ancestryConn then
		ancestryConn:Disconnect()
		ancestryConn = nil
	end
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if prompt then
		prompt:Destroy()
		prompt = nil
	end
	boundRoot = nil
end

local function openRobloxFeedback()
	if prompting then
		return
	end
	prompting = true
	task.spawn(function()
		if RunService:IsStudio() and not studioHintShown then
			studioHintShown = true
			TopNotifController.showPersonal("Feedback opens in the published game (not Studio).", "legendary", 3.2)
		end
		local ok, err = pcall(function()
			local feedbackType = (Enum :: any).FeedbackType
			if feedbackType and feedbackType.Feedback then
				(SocialService :: any):PromptFeedbackSubmissionAsync({
					FeedbackType = feedbackType.Feedback,
				})
			else
				(SocialService :: any):PromptFeedbackSubmissionAsync()
			end
		end)
		if not ok then
			warn("[MailboxFeedbackController] PromptFeedbackSubmissionAsync:", err)
		end
		prompting = false
	end)
end

local function bindMailbox(root: Instance)
	if boundRoot == root and prompt and prompt.Parent then
		return
	end
	destroyBound()
	boundRoot = root

	local host = resolveHostPart(root)
	if not host then
		warn("[MailboxFeedbackController] Mailbox has no BasePart")
		boundRoot = nil
		return
	end

	local existing = host:FindFirstChild(PROMPT_NAME)
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		local pp = Instance.new("ProximityPrompt")
		pp.Name = PROMPT_NAME
		pp.ActionText = "Feedback"
		pp.ObjectText = "Mailbox"
		pp.HoldDuration = 0
		pp.MaxActivationDistance = MAX_DISTANCE
		pp.RequiresLineOfSight = false
		pp.KeyboardKeyCode = Enum.KeyCode.E
		pp.GamepadKeyCode = Enum.KeyCode.ButtonX
		pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
		pp.Style = Enum.ProximityPromptStyle.Custom
		pp:SetAttribute("CustomPromptFX", true)
		pp.Parent = host
		prompt = pp
	end

	local pp = prompt :: ProximityPrompt
	pp.ActionText = "Feedback"
	pp.ObjectText = "Mailbox"
	pp.HoldDuration = 0
	pp.MaxActivationDistance = MAX_DISTANCE
	pp.RequiresLineOfSight = false
	pp.Style = Enum.ProximityPromptStyle.Custom
	pp:SetAttribute("CustomPromptFX", true)
	pp.Enabled = true

	local hl = Instance.new("Highlight")
	hl.Name = HIGHLIGHT_NAME
	hl.FillTransparency = 1
	hl.OutlineColor = Color3.fromRGB(255, 214, 70)
	hl.OutlineTransparency = 0.05
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	if root:IsA("Model") or root:IsA("BasePart") then
		hl.Adornee = root
	else
		hl.Adornee = host
	end
	hl.Parent = root
	highlight = hl

	pcall(function()
		ProximityPromptEffects.stylePrompt(pp)
	end)

	promptConn = pp.Triggered:Connect(function(who)
		if who ~= player then
			return
		end
		openRobloxFeedback()
	end)
	shownConn = pp.PromptShown:Connect(function()
		setOutlineVisible(true)
	end)
	hiddenConn = pp.PromptHidden:Connect(function()
		setOutlineVisible(false)
	end)

	ancestryConn = root.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBound()
		end
	end)
end

function MailboxFeedbackController.init()
	task.spawn(function()
		local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 120)
		if not map then
			warn("[MailboxFeedbackController] Map missing")
			return
		end
		local showers = map:FindFirstChild(SHOWERS_FOLDER_NAME) or map:WaitForChild(SHOWERS_FOLDER_NAME, 120)
		if not showers then
			warn("[MailboxFeedbackController] Booster Pack Showers missing")
			return
		end
		local mailbox = showers:FindFirstChild(MAILBOX_NAME) or showers:WaitForChild(MAILBOX_NAME, 60)
		if not mailbox then
			warn("[MailboxFeedbackController] Mailbox missing")
			return
		end
		bindMailbox(mailbox)
	end)

	-- Streaming: mailbox can arrive after the wait above timed out.
	local showersFolder: Instance? = nil
	local function watchShowers(showers: Instance)
		if showersFolder == showers then
			return
		end
		showersFolder = showers
		showers.ChildAdded:Connect(function(child)
			if child.Name == MAILBOX_NAME then
				bindMailbox(child)
			end
		end)
	end

	local map = Workspace:FindFirstChild("Map")
	if map then
		local showers = map:FindFirstChild(SHOWERS_FOLDER_NAME)
		if showers then
			watchShowers(showers)
		else
			map.ChildAdded:Connect(function(child)
				if child.Name == SHOWERS_FOLDER_NAME then
					watchShowers(child)
					local mailbox = child:FindFirstChild(MAILBOX_NAME)
					if mailbox then
						bindMailbox(mailbox)
					end
				end
			end)
		end
	end

	-- PromptShown also fires through the service if instance events miss.
	ProximityPromptService.PromptShown:Connect(function(shownPrompt)
		if shownPrompt == prompt then
			setOutlineVisible(true)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(hiddenPrompt)
		if hiddenPrompt == prompt then
			setOutlineVisible(false)
		end
	end)
end

return MailboxFeedbackController
