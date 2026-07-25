-- [ACTIVE] BackgroundMusicController
--[[
	BackgroundMusicController — context BGM from SoundService.BackgroundMusic.SoundGroup:
	• Safezone — default / inside safe zone
	• JungleZone — outside safe zone (Background1 / Background2, one at a time)
	• WhenHolding — while carrying a bush brainrot on your head
	Picks a random track from the active folder; when it ends, picks another.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local CarryGate = require(script.Parent.CarryGate)
local SafezoneUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafezoneUtil"))

local POLL_INTERVAL = 0.25

type BgmMode = "none" | "safezone" | "jungle" | "holding"

local player = Players.LocalPlayer

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

function BackgroundMusicController.init()
	local bg = SoundService:FindFirstChild("BackgroundMusic")
	if not bg then
		return
	end
	local sg = bg:FindFirstChild("SoundGroup")
	if not sg then
		return
	end

	local safezonePlaylist = soundsInFolder(sg:FindFirstChild("Safezone"))
	local junglePlaylist = soundsInFolder(sg:FindFirstChild("JungleZone"))
	local holdingPlaylist = soundsInFolder(sg:FindFirstChild("WhenHolding"))
	if #safezonePlaylist == 0 and #junglePlaylist == 0 and #holdingPlaylist == 0 then
		return
	end

	local groupRef = if sg:IsA("SoundGroup") then sg :: SoundGroup else nil
	local allSounds: { Sound } = {}
	for _, playlist in { safezonePlaylist, junglePlaylist, holdingPlaylist } do
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
	end

	local function playlistForMode(mode: BgmMode): { Sound }
		if mode == "safezone" then
			return safezonePlaylist
		elseif mode == "jungle" then
			return junglePlaylist
		elseif mode == "holding" then
			return holdingPlaylist
		end
		return {}
	end

	local function playRandomFromMode(mode: BgmMode)
		local playlist = playlistForMode(mode)
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
		currentSound = nextSound
		nextSound.TimePosition = 0
		nextSound:Play()
		endedConn = nextSound.Ended:Connect(function()
			if currentMode == mode then
				playRandomFromMode(mode)
			end
		end)
	end

	local function resolveMode(): BgmMode
		if CarryGate.isCarryingOnHead() and #holdingPlaylist > 0 then
			return "holding"
		end
		local char = player.Character
		local inSafe = if char then SafezoneUtil.isCharacterInSafezone(char) else true
		if not inSafe and #junglePlaylist > 0 then
			return "jungle"
		end
		if #safezonePlaylist > 0 then
			return "safezone"
		end
		if #junglePlaylist > 0 then
			return "jungle"
		end
		return "none"
	end

	local function applyMode(mode: BgmMode)
		if mode == currentMode and mode ~= "none" and currentSound and currentSound.IsPlaying then
			return
		end
		if mode == "none" then
			stopAll()
			currentMode = "none"
			return
		end
		if mode ~= currentMode then
			playRandomFromMode(mode)
		elseif currentSound and not currentSound.IsPlaying then
			playRandomFromMode(mode)
		end
	end

	local function pollState()
		applyMode(resolveMode())
	end

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
