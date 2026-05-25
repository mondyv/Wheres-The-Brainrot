--[[
	BackgroundMusicController — cycles SoundService.BackgroundMusic.SoundGroup
	direct Sound children in order; when one ends, plays the next (wraps).
--]]

local SoundService = game:GetService("SoundService")

local function playlistSoundsUnder(soundGroup: Instance): { Sound }
	local list: { Sound } = {}
	for _, c in soundGroup:GetChildren() do
		if c:IsA("Sound") then
			table.insert(list, c)
		end
	end
	return list
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
	local playlist = playlistSoundsUnder(sg)
	if #playlist == 0 then
		return
	end

	local groupRef = if sg:IsA("SoundGroup") then sg :: SoundGroup else nil
	for _, s in playlist do
		s.Looped = false
		if groupRef then
			s.SoundGroup = groupRef
		end
	end

	local idx = 1
	local endedConn: RBXScriptConnection? = nil

	local function stopAll()
		if endedConn then
			endedConn:Disconnect()
			endedConn = nil
		end
		for _, s in playlist do
			s:Stop()
		end
	end

	local function playAt(i: number)
		stopAll()
		idx = ((i - 1) % #playlist) + 1
		local s = playlist[idx]
		s.TimePosition = 0
		s:Play()
		endedConn = s.Ended:Connect(function()
			playAt(idx + 1)
		end)
	end

	playAt(1)
end

return BackgroundMusicController
