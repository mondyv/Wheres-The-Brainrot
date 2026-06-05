-- [ACTIVE] GameSoundEffects
--[[
	GameSoundEffects — gameplay SFX under SoundService.SoundEffects
	CashGrab, ErrorNotif, Drops, BushAura, BushRustles, On ProximityPrompts, GroundSmash, Purchase
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)

local player = Players.LocalPlayer

local cashGrabTemplate: Sound?
local errorNotifTemplate: Sound?
local dropHighTemplate: Sound?
local dropEpicTemplate: Sound?
local dropOtherTemplate: Sound?
local bushAuraGodlyTemplate: Sound?
local bushAuraRareTemplate: Sound?
local bushAuraMythLegendTemplate: Sound?
local bushDuringSearchTemplate: Sound?
local bushRandomShakeTemplate: Sound?
local proximityPromptTemplate: Sound?
local groundSmashTemplate: Sound?
local purchaseTemplate: Sound?

local activeAuraSound: Sound?
local activeAuraKey: string? = nil
local activeSearchSound: Sound?

local dropShakeStepBound = false
local dropShakeEndAt = 0.0
local DROP_SHAKE_STEP = "HarvestDropCameraShake"
local DROP_SHAKE_POS = 0.09
local DROP_SHAKE_SPEED = 11
local DROP_SHAKE_DURATION = 0.38

local purchaseShakeStepBound = false
local purchaseShakeEndAt = 0.0
local PURCHASE_SHAKE_STEP = "PurchaseCelebrationCameraShake"
local PURCHASE_SHAKE_POS = 0.14
local PURCHASE_SHAKE_SPEED = 13
local PURCHASE_SHAKE_DURATION = 0.42

local BUSH_RANDOM_SHAKE_MAX_DIST = 45

local HIDDEN_RARITY_ATTR = "HiddenBrainrotRarity"
local HAS_BRAINROT_ATTR = "HasHiddenBrainrot"

-- Leading silence baked into the cash grab asset (~0.3s).
local CASH_GRAB_START_OFFSET = 0.3
local CASH_GRAB_COMBO_WINDOW_SEC = 1.25
local CASH_GRAB_PITCH_STEP = 0.08
local CASH_GRAB_MAX_PITCH = 2.0

local lastCashGrabTime = 0.0
local comboCount = 0

local GameSoundEffects = {}

local function findSoundIn(container: Instance?, ...: string): Sound?
	if not container then
		return nil
	end
	for _, name in { ... } do
		local child = container:FindFirstChild(name)
		if child and child:IsA("Sound") then
			return child
		end
	end
	return container:FindFirstChildWhichIsA("Sound")
end

local function prepareClone(template: Sound): Sound
	local originalVolume = template.Volume
	local clone = template:Clone()
	local sfxGroup = ClientSFXVolume.getSoundGroup()
	if sfxGroup then
		clone.SoundGroup = sfxGroup
		clone.Volume = originalVolume
	else
		clone.Volume = originalVolume * ClientSFXVolume.getVolume()
	end
	return clone
end

local function playTemplate(template: Sound?)
	if not template then
		return
	end
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local clone = prepareClone(template)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

local function stopLoop(sound: Sound?)
	if not sound then
		return
	end
	pcall(function()
		sound:Stop()
	end)
	sound:Destroy()
end

local function playLoop(template: Sound?): Sound?
	if not template then
		return nil
	end
	if ClientSFXVolume.getVolume() <= 0 then
		return nil
	end
	local clone = prepareClone(template)
	clone.Looped = true
	clone.Parent = SoundService
	clone:Play()
	return clone
end

local function normalizeRarity(rarity: string): string
	return string.lower(string.gsub(rarity, "%s+", " "))
end

local function resolveDropTemplate(rarity: string): Sound?
	local r = normalizeRarity(rarity)
	if r == "legendary" or r == "brainrot god" or r == "secret" then
		return dropHighTemplate
	end
	if r == "epic" then
		return dropEpicTemplate
	end
	return dropOtherTemplate
end

local function resolveAuraTemplate(rarity: string): (Sound?, string?)
	local r = normalizeRarity(rarity)
	if r == "secret" or r == "brainrot god" then
		return bushAuraGodlyTemplate, "godly"
	end
	if r == "rare" then
		return bushAuraRareTemplate, "rare"
	end
	if r == "mythic" or r == "legendary" then
		return bushAuraMythLegendTemplate, "mythLegend"
	end
	return nil, nil
end

local function getLocalHumanoid(): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

local function stopDropCameraShake()
	if dropShakeStepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(DROP_SHAKE_STEP)
		end)
		dropShakeStepBound = false
	end
	local hum = getLocalHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function startDropCameraShake()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	dropShakeEndAt = os.clock() + DROP_SHAKE_DURATION
	if dropShakeStepBound then
		return
	end
	dropShakeStepBound = true
	RunService:BindToRenderStep(DROP_SHAKE_STEP, Enum.RenderPriority.Camera.Value + 51, function()
		if os.clock() >= dropShakeEndAt then
			stopDropCameraShake()
			return
		end
		local hum = getLocalHumanoid()
		if not hum then
			return
		end
		local fade = math.clamp((dropShakeEndAt - os.clock()) / DROP_SHAKE_DURATION, 0, 1)
		local amp = DROP_SHAKE_POS * fade
		local t = os.clock() * DROP_SHAKE_SPEED
		hum.CameraOffset = Vector3.new(
			(math.noise(t, 0, 0) - 0.5) * 2 * amp,
			(math.noise(0, t, 1) - 0.5) * 2 * amp,
			(math.noise(t, 2, 0.5) - 0.5) * 2 * amp * 0.35
		)
	end)
end

local function stopPurchaseCameraShake()
	if purchaseShakeStepBound then
		pcall(function()
			RunService:UnbindFromRenderStep(PURCHASE_SHAKE_STEP)
		end)
		purchaseShakeStepBound = false
	end
	local hum = getLocalHumanoid()
	if hum then
		hum.CameraOffset = Vector3.zero
	end
end

local function startPurchaseCameraShake()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	purchaseShakeEndAt = os.clock() + PURCHASE_SHAKE_DURATION
	if purchaseShakeStepBound then
		return
	end
	purchaseShakeStepBound = true
	RunService:BindToRenderStep(PURCHASE_SHAKE_STEP, Enum.RenderPriority.Camera.Value + 52, function()
		if os.clock() >= purchaseShakeEndAt then
			stopPurchaseCameraShake()
			return
		end
		local hum = getLocalHumanoid()
		if not hum then
			return
		end
		local fade = math.clamp((purchaseShakeEndAt - os.clock()) / PURCHASE_SHAKE_DURATION, 0, 1)
		local amp = PURCHASE_SHAKE_POS * fade
		local t = os.clock() * PURCHASE_SHAKE_SPEED
		hum.CameraOffset = Vector3.new(
			(math.noise(t, 0.5, 0) - 0.5) * 2 * amp,
			(math.noise(0.5, t, 1.5) - 0.5) * 2 * amp,
			(math.noise(t, 2.5, 0.5) - 0.5) * 2 * amp * 0.35
		)
	end)
end

local function cashGrabStartOffset(template: Sound): number
	local attr = template:GetAttribute("StartOffset")
	if typeof(attr) == "number" and attr >= 0 then
		return attr
	end
	return CASH_GRAB_START_OFFSET
end

function GameSoundEffects.init()
	ClientSFXVolume.syncFromSoundService()

	local root = SoundService:WaitForChild("SoundEffects", 30)
	if not root then
		warn("[GameSoundEffects] SoundService.SoundEffects missing")
		return
	end

	local cashFolder = root:FindFirstChild("CashGrab")
	if cashFolder then
		cashGrabTemplate = findSoundIn(cashFolder, "Cash grab sfx")
	end
	local errFolder = root:FindFirstChild("ErrorNotif")
	if errFolder then
		errorNotifTemplate = findSoundIn(errFolder, "Xbox Menu Error")
	end

	local dropsFolder = root:FindFirstChild("Drops")
	if dropsFolder then
		dropHighTemplate = findSoundIn(dropsFolder, "Legendary/Godly/Secret Drop")
		dropEpicTemplate = findSoundIn(dropsFolder, "Epic Drop")
		dropOtherTemplate = findSoundIn(dropsFolder, "AnyOther Drop")
	end

	local auraFolder = root:FindFirstChild("BushAura")
	if auraFolder then
		bushAuraGodlyTemplate = findSoundIn(auraFolder, "Secret/Godly Bush Aura")
		bushAuraRareTemplate = findSoundIn(auraFolder, "Rare Bush Aura")
		bushAuraMythLegendTemplate = findSoundIn(auraFolder, "Mythic/Legendary Bush Aura")
	end

	local rustleFolder = root:FindFirstChild("BushRustles")
	if rustleFolder then
		bushDuringSearchTemplate = findSoundIn(rustleFolder, "BushDuringSearch")
		bushRandomShakeTemplate = findSoundIn(rustleFolder, "BushRandomShake")
	end

	local promptFolder = root:FindFirstChild("On ProximityPrompts")
	if promptFolder then
		proximityPromptTemplate = findSoundIn(promptFolder)
	end

	local groundSmash = root:FindFirstChild("GroundSmash")
	if groundSmash and groundSmash:IsA("Sound") then
		groundSmashTemplate = groundSmash
	end

	local purchase = root:FindFirstChild("Purchase")
	if purchase and purchase:IsA("Sound") then
		purchaseTemplate = purchase
	end

	local ev = ReplicatedStorage:WaitForChild("PlayHarvestDropFX", 60)
	if ev and ev:IsA("RemoteEvent") then
		(ev :: RemoteEvent).OnClientEvent:Connect(function(rarity: string)
			GameSoundEffects.playDrop(typeof(rarity) == "string" and rarity or "common")
		end)
	end

	local essentials = ReplicatedStorage:WaitForChild("EssentialsShared", 15)
	if essentials then
		local effects = require(essentials:WaitForChild("EffectsController"))
		effects.setPurchaseSoundHandler(function()
			GameSoundEffects.playPurchase()
			GameSoundEffects.playPurchaseShake()
		end)
	end
end

function GameSoundEffects.playCashGrab()
	if not cashGrabTemplate then
		return
	end

	local now = os.clock()
	if lastCashGrabTime > 0 and (now - lastCashGrabTime) <= CASH_GRAB_COMBO_WINDOW_SEC then
		comboCount += 1
	else
		comboCount = 0
	end
	lastCashGrabTime = now

	local pitch = math.min(1 + comboCount * CASH_GRAB_PITCH_STEP, CASH_GRAB_MAX_PITCH)

	local clone = prepareClone(cashGrabTemplate)
	clone.PlaybackSpeed = pitch

	local startAt = cashGrabStartOffset(cashGrabTemplate)
	if startAt > 0 then
		clone.TimePosition = startAt
	end

	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playErrorNotif()
	playTemplate(errorNotifTemplate)
end

function GameSoundEffects.playDrop(rarity: string)
	playTemplate(resolveDropTemplate(rarity))
	startDropCameraShake()
end

function GameSoundEffects.playProximityPromptAppear()
	playTemplate(proximityPromptTemplate)
end

function GameSoundEffects.playGroundSmash(intensity: number?)
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local template = groundSmashTemplate
	if not template then
		local root = SoundService:FindFirstChild("SoundEffects")
		local inst = root and root:FindFirstChild("GroundSmash")
		if inst and inst:IsA("Sound") then
			groundSmashTemplate = inst
			template = inst
		end
	end
	if not template then
		return
	end

	local t = if typeof(intensity) == "number" then math.clamp(intensity, 0, 1) else 1
	local clone = prepareClone(template)
	clone.PlaybackSpeed = 0.92 + t * 0.14
	clone.Volume = clone.Volume * math.max(0.75, 0.65 + t * 0.35)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playPurchase()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local template = purchaseTemplate
	if not template then
		local root = SoundService:FindFirstChild("SoundEffects")
		local inst = root and root:FindFirstChild("Purchase")
		if inst and inst:IsA("Sound") then
			purchaseTemplate = inst
			template = inst
		end
	end
	if not template then
		return
	end
	local clone = prepareClone(template)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playPurchaseShake()
	startPurchaseCameraShake()
end

function GameSoundEffects.startBushSearchLoop()
	if activeSearchSound then
		return
	end
	activeSearchSound = playLoop(bushDuringSearchTemplate)
end

function GameSoundEffects.stopBushSearchLoop()
	stopLoop(activeSearchSound)
	activeSearchSound = nil
end

function GameSoundEffects.syncBushAura(bush: Instance?)
	if bush and bush.Parent and bush:GetAttribute(HAS_BRAINROT_ATTR) == true then
		local rarityAttr = bush:GetAttribute(HIDDEN_RARITY_ATTR)
		if typeof(rarityAttr) == "string" then
			local template, key = resolveAuraTemplate(rarityAttr)
			if template and key then
				if activeAuraSound and activeAuraKey == key then
					return
				end
				stopLoop(activeAuraSound)
				activeAuraSound = playLoop(template)
				activeAuraKey = key
				return
			end
		end
	end

	stopLoop(activeAuraSound)
	activeAuraSound = nil
	activeAuraKey = nil
end

function GameSoundEffects.playBushRandomShakeAt(bush: Instance)
	if not bushRandomShakeTemplate or ClientSFXVolume.getVolume() <= 0 then
		return
	end
	if not bush or not bush.Parent then
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local bushPos: Vector3
	if bush:IsA("BasePart") then
		bushPos = bush.Position
	elseif bush:IsA("Model") then
		bushPos = bush:GetPivot().Position
	else
		return
	end

	if (bushPos - hrp.Position).Magnitude > BUSH_RANDOM_SHAKE_MAX_DIST then
		return
	end

	local clone = prepareClone(bushRandomShakeTemplate)
	clone.Parent = bush
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

return GameSoundEffects
