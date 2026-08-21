-- [ACTIVE] GameSoundEffects
--[[
	GameSoundEffects — gameplay SFX under SoundService.SoundEffects
	CashGrab, ErrorNotif, Drops, BushAura, BushRustles, Grass, On ProximityPrompts,
	GroundSmash, Purchase, Upgrade, Level Up Sfx, Notification1, LandMultiply, Spider, Release
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
local upgradeTemplate: Sound?
local levelUpTemplate: Sound?
local releaseTemplate: Sound?
local liftingTemplate: Sound?
local xpCollectTemplate: Sound?
local notification1Template: Sound?
local landMultiplyTemplate: Sound?
local spiderRoarTemplate: Sound?
local spiderWebShotTemplate: Sound?
local spiderGettingHitTemplate: Sound?
local spiderDodgeTemplate: Sound?
local grassTemplates: { Sound } = {}

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
local purchaseShakeDuration = 0.42
local purchaseShakeAmp = 0.14
local PURCHASE_SHAKE_STEP = "PurchaseCelebrationCameraShake"
local PURCHASE_SHAKE_POS = 0.14
local PURCHASE_SHAKE_SPEED = 13
local PURCHASE_SHAKE_DURATION = 0.42

local BUSH_RANDOM_SHAKE_MAX_DIST = 70
local BUSH_RANDOM_SHAKE_PITCH_MIN = 0.94
local BUSH_RANDOM_SHAKE_PITCH_MAX = 1.06

local GRASS_WALK_COOLDOWN_SEC = 0.07
local GRASS_WALK_MAX_CONCURRENT = 3
local GRASS_WALK_PITCH_MIN = 0.92
local GRASS_WALK_PITCH_MAX = 1.08
local lastGrassWalkAt = 0.0
local activeGrassWalkSounds = 0

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

-- SoundEffects entries may be a Sound or a Folder containing one.
local function resolveSoundNode(node: Instance?): Sound?
	if not node then
		return nil
	end
	if node:IsA("Sound") then
		return node
	end
	return findSoundIn(node)
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
	return string.lower((string.gsub(rarity, "%s+", " ")))
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

local function startPurchaseCameraShake(durationSec: number?, amp: number?)
	purchaseShakeDuration = math.max(0.15, if typeof(durationSec) == "number" then durationSec else PURCHASE_SHAKE_DURATION)
	purchaseShakeAmp = if typeof(amp) == "number" and amp > 0 then amp else PURCHASE_SHAKE_POS
	purchaseShakeEndAt = os.clock() + purchaseShakeDuration
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
		local remaining = purchaseShakeEndAt - os.clock()
		local elapsed = purchaseShakeDuration - remaining
		local build = math.clamp(elapsed / math.max(purchaseShakeDuration * 0.45, 0.05), 0, 1)
		local fade = math.clamp(remaining / purchaseShakeDuration, 0, 1)
		local ampNow = purchaseShakeAmp * math.max(build, fade * 0.35)
		local t = os.clock() * PURCHASE_SHAKE_SPEED
		hum.CameraOffset = Vector3.new(
			(math.noise(t, 0.5, 0) - 0.5) * 2 * ampNow,
			(math.noise(0.5, t, 1.5) - 0.5) * 2 * ampNow,
			(math.noise(t, 2.5, 0.5) - 0.5) * 2 * ampNow * 0.35
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

	local upgrade = root:FindFirstChild("Upgrade")
	if upgrade and upgrade:IsA("Sound") then
		upgradeTemplate = upgrade
	end
	levelUpTemplate = resolveSoundNode(root:FindFirstChild("Level Up Sfx"))
	releaseTemplate = resolveSoundNode(root:FindFirstChild("Release"))
	liftingTemplate = resolveSoundNode(root:FindFirstChild("Lifting"))
	local xpFolder = root:FindFirstChild("Xp SFX")
	xpCollectTemplate = findSoundIn(xpFolder, "Xp Collect") or resolveSoundNode(xpFolder)

	notification1Template = resolveSoundNode(root:FindFirstChild("Notification1"))
	landMultiplyTemplate = resolveSoundNode(root:FindFirstChild("LandMultiply"))

	table.clear(grassTemplates)
	local grassNode = root:FindFirstChild("Grass")
	if grassNode then
		if grassNode:IsA("Sound") then
			table.insert(grassTemplates, grassNode)
		else
			for _, child in grassNode:GetDescendants() do
				if child:IsA("Sound") then
					table.insert(grassTemplates, child)
				end
			end
			if #grassTemplates == 0 then
				local one = grassNode:FindFirstChildWhichIsA("Sound")
				if one then
					table.insert(grassTemplates, one)
				end
			end
		end
	end

	local spiderFolder = root:FindFirstChild("Spider")
	local spiderGroup = spiderFolder and spiderFolder:FindFirstChild("SoundGroup")
	if spiderGroup then
		spiderRoarTemplate = findSoundIn(spiderGroup, "Spider Roar")
		spiderWebShotTemplate = findSoundIn(spiderGroup, "Spider Web Shot")
		spiderGettingHitTemplate = findSoundIn(spiderGroup, "Getting Hit")
		spiderDodgeTemplate = findSoundIn(spiderGroup, "Dodge")
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
	startPurchaseCameraShake(nil, nil)
end

-- Continuous camera shake while a lucky block is winding up / shaking.
function GameSoundEffects.playLuckyBlockShake(durationSec: number)
	startPurchaseCameraShake(math.max(0.2, durationSec), 0.11)
end

function GameSoundEffects.stopLuckyBlockShake()
	stopPurchaseCameraShake()
end

function GameSoundEffects.playUpgrade()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local template = upgradeTemplate
	if not template then
		local root = SoundService:FindFirstChild("SoundEffects")
		local inst = root and root:FindFirstChild("Upgrade")
		if inst and inst:IsA("Sound") then
			upgradeTemplate = inst
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

function GameSoundEffects.playRelease()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	if not releaseTemplate then
		local root = SoundService:FindFirstChild("SoundEffects")
		releaseTemplate = resolveSoundNode(root and root:FindFirstChild("Release"))
	end
	if not releaseTemplate then
		warn("[GameSoundEffects] SoundEffects.Release missing")
		return
	end
	playTemplate(releaseTemplate)
end

function GameSoundEffects.playLifting()
	if not liftingTemplate then
		local root = SoundService:FindFirstChild("SoundEffects")
		liftingTemplate = resolveSoundNode(root and root:FindFirstChild("Lifting"))
	end
	if not liftingTemplate then
		warn("[GameSoundEffects] SoundEffects.Lifting missing")
		return
	end
	playTemplate(liftingTemplate)
end

function GameSoundEffects.playXpCollect()
	if not xpCollectTemplate then
		local root = SoundService:FindFirstChild("SoundEffects")
		local xpFolder = root and root:FindFirstChild("Xp SFX")
		xpCollectTemplate = findSoundIn(xpFolder, "Xp Collect") or resolveSoundNode(xpFolder)
	end
	if not xpCollectTemplate then
		warn("[GameSoundEffects] SoundEffects['Xp SFX']['Xp Collect'] missing")
		return
	end
	playTemplate(xpCollectTemplate)
end

function GameSoundEffects.playLevelUp()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	if not levelUpTemplate then
		local root = SoundService:FindFirstChild("SoundEffects")
		levelUpTemplate = resolveSoundNode(root and root:FindFirstChild("Level Up Sfx"))
	end
	if not levelUpTemplate then
		warn("[GameSoundEffects] SoundEffects['Level Up Sfx'] missing")
		return
	end
	local clone = prepareClone(levelUpTemplate)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
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

	local dist = (bushPos - hrp.Position).Magnitude
	if dist > BUSH_RANDOM_SHAKE_MAX_DIST then
		return
	end

	local falloff = 1 - dist / BUSH_RANDOM_SHAKE_MAX_DIST
	local distanceVolume = 0.1 + 0.9 * falloff * falloff

	local clone = prepareClone(bushRandomShakeTemplate)
	clone.Volume = clone.Volume * distanceVolume
	clone.PlaybackSpeed = BUSH_RANDOM_SHAKE_PITCH_MIN
		+ math.random() * (BUSH_RANDOM_SHAKE_PITCH_MAX - BUSH_RANDOM_SHAKE_PITCH_MIN)
	clone.Parent = bush
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playNotification1()
	if not notification1Template then
		local root = SoundService:FindFirstChild("SoundEffects")
		notification1Template = resolveSoundNode(root and root:FindFirstChild("Notification1"))
	end
	if not notification1Template then
		return
	end
	local clone = prepareClone(notification1Template)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playLandMultiply()
	if not landMultiplyTemplate then
		local root = SoundService:FindFirstChild("SoundEffects")
		landMultiplyTemplate = resolveSoundNode(root and root:FindFirstChild("LandMultiply"))
	end
	if not landMultiplyTemplate then
		return
	end
	local clone = prepareClone(landMultiplyTemplate)
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function GameSoundEffects.playGrassWalk()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end

	local now = os.clock()
	if now - lastGrassWalkAt < GRASS_WALK_COOLDOWN_SEC then
		return
	end
	if activeGrassWalkSounds >= GRASS_WALK_MAX_CONCURRENT then
		return
	end

	if #grassTemplates == 0 then
		local root = SoundService:FindFirstChild("SoundEffects")
		if root then
			local grassNode = root:FindFirstChild("Grass")
			if grassNode and grassNode:IsA("Sound") then
				table.insert(grassTemplates, grassNode)
			elseif grassNode then
				for _, child in grassNode:GetDescendants() do
					if child:IsA("Sound") then
						table.insert(grassTemplates, child)
					end
				end
			end
		end
	end
	if #grassTemplates == 0 then
		return
	end

	lastGrassWalkAt = now
	activeGrassWalkSounds += 1
	local template = grassTemplates[math.random(1, #grassTemplates)]
	local clone = prepareClone(template)
	clone.PlaybackSpeed = GRASS_WALK_PITCH_MIN + math.random() * (GRASS_WALK_PITCH_MAX - GRASS_WALK_PITCH_MIN)
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		activeGrassWalkSounds = math.max(0, activeGrassWalkSounds - 1)
		clone:Destroy()
	end)
end

local function playSpiderSound(template: Sound?)
	playTemplate(template)
end

function GameSoundEffects.playSpiderRoar()
	playSpiderSound(spiderRoarTemplate)
end

function GameSoundEffects.playSpiderWebShot()
	playSpiderSound(spiderWebShotTemplate)
end

function GameSoundEffects.playSpiderGettingHit()
	playSpiderSound(spiderGettingHitTemplate)
end

function GameSoundEffects.playSpiderDodge()
	playSpiderSound(spiderDodgeTemplate)
end

-- Play once when a lucky block is held out. `sfxKey` is the SoundEffects child name
-- under SoundService.SoundEffects["Luckyblock sfx"] (e.g. "Troll Block").
local lastLuckyHoldKey: string? = nil
local lastLuckyHoldAt = 0.0

function GameSoundEffects.playLuckyBlockHold(sfxKey: string)
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	if typeof(sfxKey) ~= "string" or sfxKey == "" then
		return
	end
	local now = os.clock()
	-- Hard anti-spam: same key within 0.8s, or any hold within 0.25s.
	if lastLuckyHoldKey == sfxKey and (now - lastLuckyHoldAt) < 0.8 then
		return
	end
	if (now - lastLuckyHoldAt) < 0.25 then
		return
	end
	lastLuckyHoldKey = sfxKey
	lastLuckyHoldAt = now

	local root = SoundService:FindFirstChild("SoundEffects")
	local folder = root and root:FindFirstChild("Luckyblock sfx")
	if not folder then
		warn("[GameSoundEffects] SoundEffects['Luckyblock sfx'] missing")
		return
	end
	local template = resolveSoundNode(folder:FindFirstChild(sfxKey))
	if not template then
		-- Fuzzy: strip " Lucky" / match start
		for _, child in folder:GetChildren() do
			if child:IsA("Sound") or child:IsA("Folder") then
				local n = string.lower(child.Name)
				local key = string.lower(sfxKey)
				if n == key or string.find(n, key, 1, true) or string.find(key, n, 1, true) then
					template = resolveSoundNode(child)
					break
				end
			end
		end
	end
	if not template then
		warn("[GameSoundEffects] Luckyblock sfx missing:", sfxKey)
		return
	end
	playTemplate(template)
end

-- Full lucky-block rumble + open (~4s). One instance; stop if the cutscene aborts.
local activeBlockOpen: Sound? = nil

function GameSoundEffects.playLuckyBlockOpenSfx()
	GameSoundEffects.stopLuckyBlockOpenSfx()
	if ClientSFXVolume.getVolume() <= 0 then
		return
	end
	local root = SoundService:FindFirstChild("SoundEffects")
	local folder = root and root:FindFirstChild("Luckyblock sfx")
	local template = resolveSoundNode(folder and folder:FindFirstChild("Block Open"))
	if not template then
		warn("[GameSoundEffects] SoundEffects['Luckyblock sfx']['Block Open'] missing")
		return
	end
	local clone = prepareClone(template)
	clone.Parent = SoundService
	activeBlockOpen = clone
	clone:Play()
	clone.Ended:Once(function()
		if activeBlockOpen == clone then
			activeBlockOpen = nil
		end
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

function GameSoundEffects.stopLuckyBlockOpenSfx()
	local s = activeBlockOpen
	activeBlockOpen = nil
	if not s then
		return
	end
	pcall(function()
		s:Stop()
	end)
	if s.Parent then
		s:Destroy()
	end
end

return GameSoundEffects
