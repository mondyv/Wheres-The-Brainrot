-- [ACTIVE] Tutorial.server
-- Tutorial completion + starter cash grant; PlayerDataService owns the save flag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local AnalyticsFunnelService = require(script.Parent:WaitForChild("Modules"):WaitForChild("AnalyticsFunnelService"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))

local GRANT_AMOUNT = TutorialConfig.STARTER_CASH
local STARTER_LUCKY_BLOCK = TutorialConfig.STARTER_LUCKY_BLOCK

local function getFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("TutorialRemotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "TutorialRemotes"
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRF(name: string): RemoteFunction
	local folder = getFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

local function grantStarterLuckyBlock(player: Player)
	local folder = ServerStorage:FindFirstChild("LuckyBlockInternal")
	local bf = folder and folder:FindFirstChild("GrantLuckyBlock")
	if not (bf and bf:IsA("BindableFunction")) then
		warn("[Tutorial] GrantLuckyBlock missing — starter lucky block skipped")
		return
	end
	local ok, success = pcall(function()
		return (bf :: BindableFunction):Invoke(player, STARTER_LUCKY_BLOCK, {
			equip = true,
			variant = "basic",
		})
	end)
	if not ok then
		warn("[Tutorial] GrantLuckyBlock error:", success)
		return
	end
	if success ~= true then
		warn("[Tutorial] GrantLuckyBlock returned false for", player.Name)
	end
end

local function ensureTutorialAttrs(player: Player)
	PlayerDataService.waitUntilLoaded(player)
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == nil then
		player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, false)
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR) == nil then
		player:SetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR, false)
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR) == nil then
		player:SetAttribute(PlayerDataSchema.TUTORIAL_FIRST_BUSH_CLAIMED_ATTR, false)
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) ~= true then
		-- Soft respawn until tutorial client advances past the swing step.
		if player:GetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR) == nil then
			player:SetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR, true)
		end
	else
		player:SetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR, false)
	end
end

local completeRF = ensureRF("CompleteTutorial")
local grantCashRF = ensureRF("GrantTutorialCash")

local function ensureRE(name: string): RemoteEvent
	local folder = getFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = folder
	return re
end

local softRespawnRE = ensureRE("SetTutorialSoftRespawn")

softRespawnRE.OnServerEvent:Connect(function(player: Player, enabled: any)
	if not player or not player.Parent then
		return
	end
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
		player:SetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR, false)
		return
	end
	player:SetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR, enabled == true)
end)

completeRF.OnServerInvoke = function(player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	PlayerDataService.waitUntilLoaded(player)
	local alreadyDone = player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true
	PlayerDataService.setTutorialCompleted(player, true)
	player:SetAttribute(PlayerDataSchema.TUTORIAL_SOFT_RESPAWN_ATTR, false)
	if not alreadyDone then
		grantStarterLuckyBlock(player)
		AnalyticsFunnelService.logOnboardingId(player, "tutorial_completed", { allowSkip = true })
	end
	return true
end

grantCashRF.OnServerInvoke = function(player: Player): (boolean, number)
	if not player or not player.Parent then
		return false, 0
	end
	PlayerDataService.waitUntilLoaded(player)
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_CASH_GRANTED_ATTR) == true then
		return true, 0
	end
	local cash = player:GetAttribute("Cash")
	local c = if typeof(cash) == "number" then cash else 0
	player:SetAttribute("Cash", c + GRANT_AMOUNT)
	PlayerDataService.setTutorialCashGranted(player, true)
	AnalyticsFunnelService.logOnboardingId(player, "got_starter_cash", { allowSkip = true })
	return true, GRANT_AMOUNT
end

-- Ensure new sessions without save data start with tutorial incomplete.
Players.PlayerAdded:Connect(function(player)
	task.defer(function()
		ensureTutorialAttrs(player)
	end)
end)
for _, plr in Players:GetPlayers() do
	task.defer(function()
		ensureTutorialAttrs(plr)
	end)
end
