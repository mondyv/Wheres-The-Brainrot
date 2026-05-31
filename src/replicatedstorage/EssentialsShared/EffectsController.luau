local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EssentialsConfig = require(script.Parent.EssentialsConfig)
local SoundController = require(script.Parent.SoundController)

local EffectsController = {}

local lastConfettiAt = 0
local CONFETTI_DEBOUNCE_SEC = 0.35
local purchaseSoundHandler: (() -> ())? = nil

local function findAssetsFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("EssentialsAssets")
		or ReplicatedStorage:FindFirstChild("EssentialAssets")
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

local function emitParticles(root: Instance, defaultCount: number)
	for _, child in root:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or defaultCount)
		end
	end
end

function EffectsController.setPurchaseSoundHandler(handler: (() -> ())?)
	purchaseSoundHandler = handler
end

function EffectsController.money(parent: Instance)
	local moneyTemplate = findTemplate("Money")
	if parent and moneyTemplate then
		local money = moneyTemplate:Clone()
		money.Parent = parent
		emitParticles(money, 30)
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
		local confetti = confettiTemplate:Clone()
		confetti.Parent = root
		emitParticles(confetti, 50)
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
