-- [ACTIVE] PlayerLandTracker.server
--[[
	Publishes each player's current land for the jungle activity strip:
	  CurrentLand = 0  → in safe zone / base
	  CurrentLand = 1..10 → jungle land index
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local ATTR = "CurrentLand"
local POLL_SEC = 0.45
local pollAccum = 0

local function setLand(player: Player, land: number)
	if player:GetAttribute(ATTR) == land then
		return
	end
	player:SetAttribute(ATTR, land)
end

local function refreshPlayer(player: Player)
	local character = player.Character
	if not character then
		setLand(player, 0)
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		setLand(player, 0)
		return
	end
	-- Until zone parts are cached, stay on "base" so jungle UI doesn't flash at spawn.
	if not SafezoneUtil.isCacheReady() then
		setLand(player, 0)
		return
	end
	if SafezoneUtil.isCharacterInSafezone(character) then
		setLand(player, 0)
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		setLand(player, 0)
		return
	end
	local land = LandResolver.resolveLandAtPosition(hrp.Position)
	if typeof(land) ~= "number" or land < 1 then
		return
	end
	setLand(player, math.clamp(math.floor(land), 1, 10))
end

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute(ATTR, 0)
	player.CharacterAdded:Connect(function()
		task.defer(function()
			refreshPlayer(player)
		end)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	player:SetAttribute(ATTR, nil)
end)

for _, player in Players:GetPlayers() do
	player:SetAttribute(ATTR, 0)
	player.CharacterAdded:Connect(function()
		task.defer(function()
			refreshPlayer(player)
		end)
	end)
end

RunService.Heartbeat:Connect(function(dt)
	pollAccum += dt
	if pollAccum < POLL_SEC then
		return
	end
	pollAccum = 0
	for _, player in Players:GetPlayers() do
		refreshPlayer(player)
	end
end)
