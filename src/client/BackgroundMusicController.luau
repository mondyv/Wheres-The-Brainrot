-- [ACTIVE] BackgroundMusicController
--[[
	BackgroundMusicController — context BGM from SoundService.BackgroundMusic:
	• Booths (UpgradeBooth / SellBooth / BrainrotDealerBooth) — while at a stand shop
	• WhenHolding — while carrying a bush brainrot on your head
	• JungleZone — outside safe zone
	• Safezone — default / inside safe zone
	Picks a random track from the active folder; when it ends, picks another.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local CarryGate = require(script.Parent.CarryGate)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25

export type BoothKey = "UpgradeBooth" | "SellBooth" | "BrainrotDealerBooth"

type BgmMode = "none" | "safezone" | "jungle" | "holding" | "booth"

local player = Players.LocalPlayer

local activeBoothKey: BoothKey? = nil
local resolveAndApplyFn: (() -> ())? = nil

local function soundsInFolder(folder: Instance?): { Sound }
	local list: { Sound } = {}
	if not folder then
		return list
	end
	for _, c in folder:GetChildren() do
		if c:IsA("Sound") then
			table.insert(list, c)
		end
	end
	return list
end

local function pickRandom(list: { Sound }, avoid: Sound?): Sound?
	if #list == 0 then
		return nil
	end
	if #list == 1 then
		return list[1]
	end
	local choice = list[math.random(1, #list)]
	if choice == avoid then
		for _ = 1, 4 do
			local other = list[math.random(1, #list)]
			if other ~= avoid then
				return other
			end
		end
	end
	return choice
end

local BackgroundMusicController = {}

function BackgroundMusicController.setActiveBooth(boothKey: BoothKey?)
	if activeBoothKey == boothKey then
		return
	end
	activeBoothKey = boothKey
	if resolveAndApplyFn then
		resolveAndApplyFn()
	end
	-- Booth music is a different playlist — drop the panel muffle blur on it.
	task.defer(function()
		local ok, muffle = pcall(function()
			return require(script.Parent.GameplayMusicMuffle)
		end)
		if ok and typeof(muffle) == "table" and typeof((muffle :: any).sync) == "function" then
			(muffle :: any).sync()
		end
	end)
end

function BackgroundMusicController.getActiveBooth(): BoothKey?
	return activeBoothKey
end

function BackgroundMusicController.init()
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	if not bg then
		return
	end
	local sg = bg:FindFirstChild("SoundGroup")
	local boothsRoot = bg:FindFirstChild("Booths")

	local safezonePlaylist = soundsInFolder(sg and sg:FindFirstChild("Safezone"))
	local junglePlaylist = soundsInFolder(sg and sg:FindFirstChild("JungleZone"))
	local holdingPlaylist = soundsInFolder(sg and sg:FindFirstChild("WhenHolding"))

	local boothPlaylists: { [BoothKey]: { Sound } } = {
		UpgradeBooth = soundsInFolder(boothsRoot and boothsRoot:FindFirstChild("UpgradeBooth")),
		SellBooth = soundsInFolder(boothsRoot and boothsRoot:FindFirstChild("SellBooth")),
		BrainrotDealerBooth = soundsInFolder(boothsRoot and boothsRoot:FindFirstChild("BrainrotDealerBooth")),
	}

	local hasAnyBooth = false
	for _, list in boothPlaylists do
		if #list > 0 then
			hasAnyBooth = true
			break
		end
	end

	if #safezonePlaylist == 0 and #junglePlaylist == 0 and #holdingPlaylist == 0 and not hasAnyBooth then
		return
	end

	local groupRef = if sg and sg:IsA("SoundGroup") then sg :: SoundGroup else nil
	local allSounds: { Sound } = {}
	for _, playlist in { safezonePlaylist, junglePlaylist, holdingPlaylist } do
		for _, s in playlist do
			table.insert(allSounds, s)
		end
	end
	for _, playlist in boothPlaylists do
		for _, s in playlist do
			table.insert(allSounds, s)
		end
	end
	for _, s in allSounds do
		s.Looped = false
		if groupRef then
			s.SoundGroup = groupRef
		end
	end

	local currentMode: BgmMode = "none"
	local currentBoothKey: BoothKey? = nil
	local currentSound: Sound? = nil
	local endedConn: RBXScriptConnection? = nil
	local pollAccum = 0.0

	local function stopAll()
		if endedConn then
			endedConn:Disconnect()
			endedConn = nil
		end
		for _, s in allSounds do
			s:Stop()
		end
		currentSound = nil
		currentBoothKey = nil
	end

	local function playlistForMode(mode: BgmMode, boothKey: BoothKey?): { Sound }
		if mode == "booth" and boothKey then
			return boothPlaylists[boothKey] or {}
		elseif mode == "safezone" then
			return safezonePlaylist
		elseif mode == "jungle" then
			return junglePlaylist
		elseif mode == "holding" then
			return holdingPlaylist
		end
		return {}
	end

	local function playRandomFromMode(mode: BgmMode, boothKey: BoothKey?)
		local playlist = playlistForMode(mode, boothKey)
		local nextSound = pickRandom(playlist, currentSound)
		if not nextSound then
			stopAll()
			currentMode = "none"
			return
		end

		if endedConn then
			endedConn:Disconnect()
			endedConn = nil
		end
		for _, s in allSounds do
			if s ~= nextSound then
				s:Stop()
			end
		end

		currentMode = mode
		currentBoothKey = if mode == "booth" then boothKey else nil
		currentSound = nextSound
		nextSound.TimePosition = 0
		nextSound:Play()
		endedConn = nextSound.Ended:Connect(function()
			if currentMode == mode and currentBoothKey == boothKey then
				playRandomFromMode(mode, boothKey)
			end
		end)
	end

	local function resolveMode(): (BgmMode, BoothKey?)
		local booth = activeBoothKey
		if booth and #(boothPlaylists[booth] or {}) > 0 then
			return "booth", booth
		end
		if CarryGate.isCarryingOnHead() and #holdingPlaylist > 0 then
			return "holding", nil
		end
		local char = player.Character
		local inSafe = if char then SafezoneUtil.isCharacterInSafezone(char) else true
		if not inSafe and #junglePlaylist > 0 then
			return "jungle", nil
		end
		if #safezonePlaylist > 0 then
			return "safezone", nil
		end
		if #junglePlaylist > 0 then
			return "jungle", nil
		end
		return "none", nil
	end

	local function applyMode(mode: BgmMode, boothKey: BoothKey?)
		local sameBooth = mode ~= "booth" or currentBoothKey == boothKey
		if mode == currentMode and sameBooth and mode ~= "none" and currentSound and currentSound.IsPlaying then
			return
		end
		if mode == "none" then
			stopAll()
			currentMode = "none"
			return
		end
		if mode ~= currentMode or (mode == "booth" and currentBoothKey ~= boothKey) then
			playRandomFromMode(mode, boothKey)
		elseif currentSound and not currentSound.IsPlaying then
			playRandomFromMode(mode, boothKey)
		end
	end

	local function pollState()
		local mode, boothKey = resolveMode()
		applyMode(mode, boothKey)
	end
	resolveAndApplyFn = pollState

	task.spawn(function()
		SafezoneUtil.warmCacheAsync()
	end)

	player:GetAttributeChangedSignal("BrainrotCarryCount"):Connect(pollState)
	player.CharacterAdded:Connect(function()
		task.defer(pollState)
	end)

	RunService.Heartbeat:Connect(function(dt)
		pollAccum += dt
		if pollAccum < POLL_INTERVAL then
			return
		end
		pollAccum = 0
		pollState()
	end)

	pollState()
end

return BackgroundMusicController
