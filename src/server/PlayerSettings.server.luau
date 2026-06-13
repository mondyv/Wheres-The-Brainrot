-- [ACTIVE] PlayerSettings
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerDataService"))

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Remotes"
	created.Parent = ReplicatedStorage
	return created
end

local saveRE = getRemotesFolder():FindFirstChild("SavePlayerSettings")
if not saveRE then
	saveRE = Instance.new("RemoteEvent")
	saveRE.Name = "SavePlayerSettings"
	saveRE.Parent = getRemotesFolder()
end

(saveRE :: RemoteEvent).OnServerEvent:Connect(function(player: Player, patch: any)
	if typeof(patch) ~= "table" then
		return
	end
	PlayerDataService.waitUntilLoaded(player)
	PlayerDataService.savePlayerSettings(player, patch)
end)
