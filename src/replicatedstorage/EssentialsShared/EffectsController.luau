local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EssentialsConfig = require(script.Parent.EssentialsConfig)
local SoundController = require(script.Parent.SoundController)

local EffectsController = {}

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
		return vfx:FindFirstChild(name)
	end

	return nil
end

local function emitParticles(root: Instance, defaultCount: number)
	for _, child in root:GetChildren() do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or defaultCount)
		end
	end
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

function EffectsController.confetti(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local confettiTemplate = findTemplate("Confetti")

	if root and confettiTemplate then
		local confetti = confettiTemplate:Clone()
		confetti.Parent = root
		emitParticles(confetti, 50)
		Debris:AddItem(confetti, 3)
	end

	SoundController.play(EssentialsConfig.sounds.confetti, 1, false)
end

return EffectsController
