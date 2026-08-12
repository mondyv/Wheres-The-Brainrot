-- [ACTIVE] Level.server
-- Remotes bootstrap for LevelService.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LevelService = require(script.Parent:WaitForChild("Modules"):WaitForChild("LevelService"))

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function ensureRE(name: string): RemoteEvent
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = remotesFolder
	return re
end

local levelUpRE = ensureRE("PlayerLevelUp")
local xpGainRE = ensureRE("PlayerXpGain")
LevelService.bindRemotes(levelUpRE, xpGainRE)
