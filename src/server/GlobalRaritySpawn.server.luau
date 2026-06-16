-- [ACTIVE] GlobalRaritySpawn
local GlobalRaritySpawnService = require(script.Parent:WaitForChild("Modules"):WaitForChild("GlobalRaritySpawnService"))

local ServerStorage = game:GetService("ServerStorage")

local function ensureInternalFolder(): Folder
	local existing = ServerStorage:FindFirstChild("GameInternal")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "GameInternal"
	folder.Parent = ServerStorage
	return folder
end

local function ensureBindable(name: string): BindableFunction
	local folder = ensureInternalFolder()
	local bf = folder:FindFirstChild(name)
	if not bf then
		bf = Instance.new("BindableFunction")
		bf.Name = name
		bf.Parent = folder
	end
	return bf :: BindableFunction
end

GlobalRaritySpawnService.start()

ensureBindable("GlobalRaritySpawnClaimed").OnInvoke = function(bush: any)
	if typeof(bush) ~= "Instance" then
		return false
	end
	GlobalRaritySpawnService.onBushClaimed(bush)
	return true
end

ensureBindable("ForceServerRaritySpawn").OnInvoke = function(tierId: any)
	if typeof(tierId) ~= "string" then
		return false, "bad_tier"
	end
	return GlobalRaritySpawnService.forceSpawn(tierId)
end

ensureBindable("BroadcastGlobalRaritySpawn").OnInvoke = function(tierId: any)
	if typeof(tierId) ~= "string" then
		return false, "bad_tier"
	end
	return GlobalRaritySpawnService.broadcastGlobalSpawn(tierId)
end
