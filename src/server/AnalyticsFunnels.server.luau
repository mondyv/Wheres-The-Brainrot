-- [ACTIVE] AnalyticsFunnels.server
--[[
	Wires Creator Hub funnel remotes + land progression polling.
	Onboarding / shop / progression / wave helpers live in AnalyticsFunnelService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = script.Parent:WaitForChild("Modules")
local AnalyticsFunnelService = require(Modules:WaitForChild("AnalyticsFunnelService"))
local AnalyticsFunnelConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AnalyticsFunnelConfig"))
local LandResolver = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LandResolver"))
local PlayerDataSchema = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerDataSchema"))

local LAND_POLL_SEC = 4

local function getFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("AnalyticsRemotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "AnalyticsRemotes"
	folder.Parent = ReplicatedStorage
	return folder
end

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

local reportOnboardingRE = ensureRE("ReportOnboardingStep")
local reportShopOpenRE = ensureRE("ReportShopOpened")
local reportWaveStartRE = ensureRE("ReportWaveChaseStarted")
local reportWaveEscapeRE = ensureRE("ReportWaveChaseEscaped")

local WAVE_REPORT_COOLDOWN = 2.5
local lastWaveStartAt: { [Player]: number } = {}
local lastWaveEscapeAt: { [Player]: number } = {}

-- Client may only report known tutorial → onboarding ids, one step at a time.
reportOnboardingRE.OnServerEvent:Connect(function(player: Player, stepId: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(stepId) ~= "string" then
		return
	end
	local mapped = AnalyticsFunnelConfig.TUTORIAL_ID_TO_ONBOARDING[stepId]
	local id = mapped or stepId
	if not AnalyticsFunnelConfig.onboardingById(id) then
		return
	end
	-- Soft-block: finished tutorial players shouldn't spam mid-funnel reports.
	if player:GetAttribute(PlayerDataSchema.TUTORIAL_COMPLETED_ATTR) == true then
		if id ~= "tutorial_completed" and id ~= "opened_starter_lucky_block" then
			return
		end
	end
	local allowSkip = id == "tutorial_completed" or id == "opened_starter_lucky_block"
	AnalyticsFunnelService.logOnboardingId(player, id, { allowSkip = allowSkip })
end)

reportShopOpenRE.OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	AnalyticsFunnelService.shopOpened(player)
end)

reportWaveStartRE.OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local now = os.clock()
	if (lastWaveStartAt[player] or 0) + WAVE_REPORT_COOLDOWN > now then
		return
	end
	lastWaveStartAt[player] = now
	AnalyticsFunnelService.waveChaseStarted(player)
end)

reportWaveEscapeRE.OnServerEvent:Connect(function(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local now = os.clock()
	if (lastWaveEscapeAt[player] or 0) + WAVE_REPORT_COOLDOWN > now then
		return
	end
	lastWaveEscapeAt[player] = now
	AnalyticsFunnelService.waveChaseEscaped(player)
end)

local function applyCurrentLand(player: Player)
	local land = player:GetAttribute("CurrentLand")
	if typeof(land) == "number" and land >= 1 then
		AnalyticsFunnelService.onReachedLand(player, math.floor(land))
	end
end

local function watchLand(player: Player)
	player:GetAttributeChangedSignal("CurrentLand"):Connect(function()
		applyCurrentLand(player)
	end)
	applyCurrentLand(player)
end

local function onPlayerJoined(player: Player)
	watchLand(player)
	task.defer(function()
		if not player.Parent then
			return
		end
		AnalyticsFunnelService.beginPlaySession(player)
		AnalyticsFunnelService.logOnboardingId(player, "player_joined", { allowSkip = true })
		applyCurrentLand(player)
	end)
end

Players.PlayerAdded:Connect(onPlayerJoined)
for _, plr in Players:GetPlayers() do
	onPlayerJoined(plr)
end

Players.PlayerRemoving:Connect(function(player)
	lastWaveStartAt[player] = nil
	lastWaveEscapeAt[player] = nil
end)

-- Progression: land milestones (server-authoritative position check).
task.spawn(function()
	while true do
		task.wait(LAND_POLL_SEC)
		if RunService:IsStudio() then
			-- Still track in Studio for local testing of step state; AnalyticsService no-ops inside service.
		end
		for _, player in Players:GetPlayers() do
			AnalyticsFunnelService.tickPlaySession(player)
			local attrLand = player:GetAttribute("CurrentLand")
			if typeof(attrLand) == "number" and attrLand >= 1 then
				AnalyticsFunnelService.onReachedLand(player, math.floor(attrLand))
				continue
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local land = LandResolver.resolveLandAtPosition(hrp.Position)
				if typeof(land) == "number" and land >= 1 then
					AnalyticsFunnelService.onReachedLand(player, land)
				end
			end
		end
	end
end)
