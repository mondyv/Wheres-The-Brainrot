-- [ACTIVE] Tutorial.server
-- Tutorial completion remote; PlayerDataService owns the save flag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))

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

local completeRF = ensureRF("CompleteTutorial")

completeRF.OnServerInvoke = function(player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	PlayerDataService.waitUntilLoaded(player)
	PlayerDataService.setTutorialCompleted(player, true)
	return true
end

-- Ensure new sessions without save data start with tutorial incomplete.
Players.PlayerAdded:Connect(function(player)
	task.defer(function()
		PlayerDataService.waitUntilLoaded(player)
		if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == nil then
			player:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, false)
		end
	end)
end)
for _, plr in Players:GetPlayers() do
	task.defer(function()
		PlayerDataService.waitUntilLoaded(plr)
		if plr:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == nil then
			plr:SetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR, false)
		end
	end)
end
