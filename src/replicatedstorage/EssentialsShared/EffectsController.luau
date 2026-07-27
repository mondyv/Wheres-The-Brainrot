-- [ACTIVE] EffectsController
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EssentialsConfig = require(script.Parent.EssentialsConfig)
local SoundController = require(script.Parent.SoundController)

local EffectsController = {}

local lastConfettiAt = 0
local CONFETTI_DEBOUNCE_SEC = 2.5
local purchaseSoundHandler: (() -> ())? = nil

local function findAssetsFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("EssentialAssets")
end

local function findTemplate(name: string): Instance?
	local assets = findAssetsFolder()
	if assets then
		local templates = assets:FindFirstChild("Templates")
		if templates then
			local template = templates:FindFirstChild(name)
			if template then
				return template
			end
		end
	end

	local vfx = ReplicatedStorage:FindFirstChild("VFX")
	if vfx then
		local inVfx = vfx:FindFirstChild(name)
		if inVfx then
			return inVfx
		end
	end

	for _, desc in ReplicatedStorage:GetDescendants() do
		if desc.Name == name and (desc:IsA("Folder") or desc:IsA("Model") or desc:IsA("Attachment")) then
			return desc
		end
	end

	return nil
end

local function stripCloneBehaviors(root: Instance)
	-- Studio VFX kits often ship scripts that Emit again on AncestryChanged.
	for _, d in root:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		elseif d:IsA("Sound") then
			d:Stop()
			d:Destroy()
		end
	end
end

local function emitParticlesOnce(root: Instance, defaultCount: number)
	-- One visual wave only: skip EmitDelay > 0 (second cannon / delayed blast),
	-- never enable Rate/EmitDuration windows.
	local emitters: { ParticleEmitter } = {}
	local minDelay = math.huge
	for _, child in root:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child.Enabled = false
			child.Rate = 0
			local delayAttr = child:GetAttribute("EmitDelay")
			local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
			if delaySec < minDelay then
				minDelay = delaySec
			end
			table.insert(emitters, child)
		end
	end
	if minDelay == math.huge then
		return
	end
	for _, child in emitters do
		local delayAttr = child:GetAttribute("EmitDelay")
		local delaySec = if typeof(delayAttr) == "number" then math.max(0, delayAttr) else 0
		if delaySec > minDelay + 0.001 then
			continue
		end
		local countAttr = child:GetAttribute("EmitCount")
		local count = if typeof(countAttr) == "number" then math.floor(countAttr) else defaultCount
		if count > 0 then
			child:Emit(count)
		end
	end
end

function EffectsController.setPurchaseSoundHandler(handler: (() -> ())?)
	purchaseSoundHandler = handler
end

function EffectsController.wasRecentCelebration(windowSec: number?): boolean
	local window = if typeof(windowSec) == "number" then windowSec else CONFETTI_DEBOUNCE_SEC
	return lastConfettiAt > 0 and (os.clock() - lastConfettiAt) < window
end

function EffectsController.money(parent: Instance)
	local moneyTemplate = findTemplate("Money")
	if parent and moneyTemplate then
		local money = moneyTemplate:Clone()
		stripCloneBehaviors(money)
		money.Parent = parent
		emitParticlesOnce(money, 30)
		Debris:AddItem(money, 3)
	end

	SoundController.play(EssentialsConfig.sounds.cashCollect, 1, false)
end

function EffectsController.celebratePurchase(player: Player)
	local now = os.clock()
	if now - lastConfettiAt < CONFETTI_DEBOUNCE_SEC then
		return
	end
	lastConfettiAt = now

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local confettiTemplate = findTemplate("Confetti")

	if root and confettiTemplate then
		-- Drop any leftover burst still attached from a prior celebrate.
		for _, ch in root:GetChildren() do
			if ch.Name == "Confetti" or ch:GetAttribute("PurchaseConfetti") == true then
				ch:Destroy()
			end
		end

		local confetti = confettiTemplate:Clone()
		confetti:SetAttribute("PurchaseConfetti", true)
		stripCloneBehaviors(confetti)
		for _, child in confetti:GetDescendants() do
			if child:IsA("ParticleEmitter") then
				child.Enabled = false
				child.Rate = 0
			end
		end
		confetti.Parent = root
		emitParticlesOnce(confetti, 40)
		Debris:AddItem(confetti, 3)
	end

	if purchaseSoundHandler then
		purchaseSoundHandler()
	else
		SoundController.play(EssentialsConfig.sounds.confetti, 1, false)
	end
end

function EffectsController.confetti(player: Player)
	EffectsController.celebratePurchase(player)
end

return EffectsController
