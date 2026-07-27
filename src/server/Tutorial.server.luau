-- [ACTIVE] Tutorial.server
-- Tutorial completion + starter cash grant; PlayerDataService owns the save flag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))
local TutorialConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TutorialConfig"))

local GRANT_AMOUNT = TutorialConfig.STARTER_CASH

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
end

local completeRF = ensureRF("CompleteTutorial")
local grantCashRF = ensureRF("GrantTutorialCash")

completeRF.OnServerInvoke = function(player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	PlayerDataService.waitUntilLoaded(player)
	PlayerDataService.setTutorialCompleted(player, true)
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
