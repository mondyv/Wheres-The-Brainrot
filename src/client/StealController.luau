-- [ACTIVE] StealController
--[[
	StealController
	Adds a "Steal Brainrot" ProximityPrompt to every OTHER player's stand that
	currently holds a brainrot. The prompt description shows the player's remaining
	free steals (VIP) or the Robux price for the brainrot's rarity. Triggering fires
	StealRequest; the server decides between a free steal or a paid product prompt.

	The prompt uses the engine hold so it works on mobile (no custom hold needed),
	and is parented under workspace.Map so the existing ProximityPromptEffects styles
	it consistently with the rest of the game's prompts.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local player = Players.LocalPlayer
local STAND_TAG = "BrainrotStand"
local HOLD_DURATION = 0.9
local MAX_DISTANCE = 18

local StealController = {}

local stealPrompts: { [Model]: ProximityPrompt } = {}

local function getStealRemote(): RemoteEvent?
	local folder = ReplicatedStorage:FindFirstChild("StoreRemotes")
	local re = folder and folder:FindFirstChild("StealRequest")
	if re and re:IsA("RemoteEvent") then
		return re
	end
	return nil
end

local function standAnchorPart(stand: Model): BasePart?
	local spawn = stand:FindFirstChild("Spawn", true)
	if spawn and spawn:IsA("BasePart") then
		return spawn :: BasePart
	end
	if stand.PrimaryPart then
		return stand.PrimaryPart
	end
	return stand:FindFirstChildWhichIsA("BasePart", true)
end

local function ensureStealPrompt(stand: Model): ProximityPrompt?
	local existing = stealPrompts[stand]
	if existing and existing.Parent then
		return existing
	end
	local anchor = standAnchorPart(stand)
	if not anchor then
		return nil
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ObjectText = "Steal Brainrot"
	prompt.ActionText = "Steal"
	prompt.HoldDuration = HOLD_DURATION
	prompt.MaxActivationDistance = MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.Enabled = false
	prompt:SetAttribute("StealPrompt", true)
	prompt.Parent = anchor

	prompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer ~= player then
			return
		end
		local re = getStealRemote()
		if re then
			re:FireServer(stand)
		end
	end)

	stealPrompts[stand] = prompt
	return prompt
end

local function stealActionText(stand: Model): string
	local free = player:GetAttribute(StoreConfig.ATTR.FREE_STEAL_COUNT)
	if typeof(free) == "number" and free > 0 then
		return string.format("%d free steals remaining", free)
	end
	local rarity = stand:GetAttribute("BrainrotRarity")
	if typeof(rarity) == "string" then
		local price = StoreConfig.STEAL_PRICE_BY_RARITY[rarity]
		if price then
			return string.format("R$%d", price)
		end
	end
	return "Steal"
end

local function refreshStand(stand: Model)
	local owner = stand:GetAttribute("StandOwnerUserId")
	local hasBrainrot = typeof(stand:GetAttribute("BrainrotName")) == "string"
	local eligible = hasBrainrot and typeof(owner) == "number" and owner ~= player.UserId

	if not eligible then
		local p = stealPrompts[stand]
		if p then
			p.Enabled = false
		end
		return
	end

	local prompt = ensureStealPrompt(stand)
	if prompt then
		prompt.Enabled = true
		prompt.ActionText = stealActionText(stand)
	end
end

local function hookStand(stand: Instance)
	if not stand:IsA("Model") then
		return
	end
	local model = stand :: Model
	for _, attr in { "StandOwnerUserId", "BrainrotName", "BrainrotRarity" } do
		model:GetAttributeChangedSignal(attr):Connect(function()
			refreshStand(model)
		end)
	end
	refreshStand(model)
end

local function init()
	for _, stand in CollectionService:GetTagged(STAND_TAG) do
		hookStand(stand)
	end
	CollectionService:GetInstanceAddedSignal(STAND_TAG):Connect(hookStand)
	CollectionService:GetInstanceRemovedSignal(STAND_TAG):Connect(function(stand)
		if stand:IsA("Model") then
			stealPrompts[stand :: Model] = nil
		end
	end)

	-- Free-steal counter changes update every nearby prompt's description.
	player:GetAttributeChangedSignal(StoreConfig.ATTR.FREE_STEAL_COUNT):Connect(function()
		for stand in stealPrompts do
			if stand.Parent then
				refreshStand(stand)
			end
		end
	end)
end

local function boot()
	local ok, err = pcall(init)
	if not ok then
		warn("[StealController]", err)
	end
end

StealController.init = boot
return StealController
