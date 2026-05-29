--[[
	Per-brainrot SFX — server fires ReplicatedStorage.PlayBrainrotSFX(brainrotName).
	Plays matching Sound from SoundService["Brainrot sfx"] locally for this player only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local BRAINROT_SFX_FOLDER_NAME = "Brainrot sfx"

local BrainrotSFX = {}

local function playBrainrotSound(brainrotName: string)
	if typeof(brainrotName) ~= "string" or brainrotName == "" then
		return
	end

	local folder = SoundService:FindFirstChild(BRAINROT_SFX_FOLDER_NAME)
	if not folder then
		warn("[BrainrotSFX] SoundService['Brainrot sfx'] missing")
		return
	end

	local template = folder:FindFirstChild(brainrotName)
	if not template or not template:IsA("Sound") then
		warn(string.format("[BrainrotSFX] No sound for brainrot %q in SoundService['Brainrot sfx']", brainrotName))
		return
	end

	local clone = template:Clone()
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function BrainrotSFX.init()
	local ev = ReplicatedStorage:WaitForChild("PlayBrainrotSFX", 60)
	if not ev or not ev:IsA("RemoteEvent") then
		warn("[BrainrotSFX] ReplicatedStorage.PlayBrainrotSFX RemoteEvent missing")
		return
	end

	(ev :: RemoteEvent).OnClientEvent:Connect(function(brainrotName: string)
		playBrainrotSound(brainrotName)
	end)
end

return BrainrotSFX
