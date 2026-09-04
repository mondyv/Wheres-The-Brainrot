-- [ACTIVE] BushHarvestLucky
--[[
	Bush lucky-block pre-roll + floating offer extracted from BushHarvest.server
	so the main script stays under Luau's 200 local register limit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BushLuckyBlockConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BushLuckyBlockConfig"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local LuckyBlockCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LuckyBlockCatalog"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))

local M = {}

M.HAS_ATTR = "HasHiddenLuckyBlock"
M.KIND_ATTR = "HiddenLuckyBlockKind"
M.VARIANT_ATTR = "HiddenLuckyBlockVariant"

export type OfferDeps = {
	isValidBushRef: (Instance?) -> boolean,
	spawnBrainrotAboveBush: (Model, Vector3, number, Vector3?) -> (CFrame, number),
	placeModelAtWorld: (Model, CFrame) -> (),
	setAllPartsPhysics: (Model, boolean, boolean) -> (),
	popSpawnEffect: (Model, (() -> ())?) -> (),
	startFloatingClaimOffer: (Player, Model, Model, Vector3, number) -> (),
	BrainrotHeader: any,
}

function M.clearHiddenLuckyLoot(bush: Instance)
	bush:SetAttribute(M.HAS_ATTR, nil)
	bush:SetAttribute(M.KIND_ATTR, nil)
	bush:SetAttribute(M.VARIANT_ATTR, nil)
end

function M.rollHiddenLuckyLoot(bush: Instance, worldPosition: Vector3)
	M.clearHiddenLuckyLoot(bush)
	local land = LandResolver.resolveLandAtPosition(worldPosition)
	if typeof(land) ~= "number" then
		land = 1
	end
	local chance = BushLuckyBlockConfig.chanceForLand(land)
	if math.random() > chance then
		return
	end
	local blockName, variant = BushLuckyBlockConfig.pickBlockForLand(land)
	bush:SetAttribute(M.HAS_ATTR, true)
	bush:SetAttribute(M.KIND_ATTR, blockName)
	if typeof(variant) == "string" and variant ~= "" then
		bush:SetAttribute(M.VARIANT_ATTR, variant)
	end
end

function M.tryOfferBushLuckyBlock(
	deps: OfferDeps,
	player: Player,
	worldPosition: Vector3,
	bushRef: Instance?
): (boolean, string?)
	-- Tutorial players only get brainrots from bushes; lucky blocks resume after TutorialCompleted.
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		return false, nil
	end
	if not bushRef or bushRef:GetAttribute(M.HAS_ATTR) ~= true then
		return false, nil
	end
	local blockName = bushRef:GetAttribute(M.KIND_ATTR)
	if typeof(blockName) ~= "string" or blockName == "" then
		blockName = "Starter Lucky Block"
	end
	local variant = bushRef:GetAttribute(M.VARIANT_ATTR)
	if typeof(variant) ~= "string" or variant == "" then
		variant = nil
	end

	local char = player.Character
	if not char then
		return false, nil
	end

	local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
	local cloneBF = folder and folder:FindFirstChild("CloneWorldModel")
	if not (cloneBF and cloneBF:IsA("BindableFunction")) then
		warn("[BushHarvestLucky] LuckyBlockInternal.CloneWorldModel missing")
		return false, nil
	end

	local okClone, cloneOrErr = pcall(function()
		return (cloneBF :: BindableFunction):Invoke(blockName, variant)
	end)
	if not okClone or typeof(cloneOrErr) ~= "Instance" or not (cloneOrErr :: Instance):IsA("Model") then
		if blockName ~= "Starter Lucky Block" then
			okClone, cloneOrErr = pcall(function()
				return (cloneBF :: BindableFunction):Invoke("Starter Lucky Block", "basic")
			end)
			if okClone and typeof(cloneOrErr) == "Instance" and (cloneOrErr :: Instance):IsA("Model") then
				warn("[BushHarvestLucky] CloneWorldModel fallback to Starter for", blockName)
				blockName = "Starter Lucky Block"
				variant = "basic"
			else
				warn("[BushHarvestLucky] CloneWorldModel failed:", cloneOrErr)
				return false, nil
			end
		else
			warn("[BushHarvestLucky] CloneWorldModel failed:", cloneOrErr)
			return false, nil
		end
	end

	local clone = cloneOrErr :: Model
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:SetAttribute("BrainrotCarryPhase", "Pop")
	clone:SetAttribute("LuckyBlockCarry", true)
	clone:SetAttribute("LuckyBlockKind", blockName)
	if typeof(variant) == "string" then
		clone:SetAttribute("LuckyBlockVariant", variant)
	end
	clone:SetAttribute("BrainrotName", LuckyBlockCatalog.displayName(blockName))
	clone:SetAttribute("BrainrotRarity", LuckyBlockCatalog.primaryDropRarity(blockName))
	clone:SetAttribute("BrainrotMutation", "normal")
	clone:SetAttribute("BrainrotLevel", 1)
	clone:SetAttribute("BrainrotBaseIncome", 0)
	if bushRef and deps.isValidBushRef(bushRef) then
		local pos = if bushRef:IsA("BasePart") then bushRef.Position else bushRef:GetPivot().Position
		clone:SetAttribute("BrainrotHarvestBushKey", string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z))
	end

	for _, d in clone:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end

	clone.Parent = workspace
	local facePos = char:GetPivot().Position
	local spawnCf, baseYaw = deps.spawnBrainrotAboveBush(clone, worldPosition, 1, facePos)
	deps.placeModelAtWorld(clone, spawnCf)
	deps.setAllPartsPhysics(clone, true, true)

	deps.BrainrotHeader.attach(clone, {
		name = LuckyBlockCatalog.displayName(blockName),
		rarity = LuckyBlockCatalog.primaryDropRarity(blockName),
		mutation = "normal",
		level = 1,
		incomePerSecond = 0,
		luckyBlock = true,
	})

	local anchorPos = spawnCf.Position
	deps.popSpawnEffect(clone, function()
		if not clone.Parent or player.Character ~= char then
			if clone.Parent then
				clone:Destroy()
			end
			return
		end
		clone:SetAttribute("BrainrotCarryPhase", "Floating")
		deps.setAllPartsPhysics(clone, true, true)
		deps.startFloatingClaimOffer(player, char, clone, anchorPos, baseYaw)
	end)

	M.clearHiddenLuckyLoot(bushRef)
	return true, blockName
end

return M
