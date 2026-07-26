-- [ACTIVE] BrainrotSFX
--[[
	Per-brainrot SFX — server fires ReplicatedStorage.PlayBrainrotSFX(brainrotName).
	Plays matching Sound from SoundService["Brainrot sfx"] locally for this player only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local ClientSFXVolume = require(script.Parent.ClientSFXVolume)

local BRAINROT_SFX_FOLDER_NAME = "Brainrot sfx"

local BrainrotSFX = {}

local function playBrainrotSound(brainrotName: string)
	if typeof(brainrotName) ~= "string" or brainrotName == "" then
		return
	end

	local sfxMult = ClientSFXVolume.getVolume()
	if sfxMult <= 0 then
		return
	end

	local folder = SoundService:FindFirstChild(BRAINROT_SFX_FOLDER_NAME)
	if not folder then
		warn("[BrainrotSFX] SoundService['Brainrot sfx'] missing")
		return
	end

	local template: Instance? = folder:FindFirstChild(brainrotName)
	if (not template or not template:IsA("Sound")) and brainrotName == "BurbalolliLuilolli" then
		template = folder:FindFirstChild("BurbalolliLulilolli")
	elseif (not template or not template:IsA("Sound")) and brainrotName == "BurbalolliLulilolli" then
		template = folder:FindFirstChild("BurbalolliLuilolli")
	end
	if not template or not template:IsA("Sound") then
		-- Fuzzy match Sound children (spaces / typo variants).
		local want = string.lower((brainrotName:gsub("[%s_%-]", "")))
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Sound") then
				local n = string.lower((child.Name:gsub("[%s_%-]", "")))
				if n == want then
					template = child
					break
				end
			end
		end
	end
	if not template or not template:IsA("Sound") then
		warn(string.format("[BrainrotSFX] No sound for brainrot %q in SoundService['Brainrot sfx']", brainrotName))
		return
	end

	local originalVolume = template.Volume
	local clone = template:Clone()
	local sfxGroup = ClientSFXVolume.getSoundGroup()
	if sfxGroup then
		clone.SoundGroup = sfxGroup
		clone.Volume = originalVolume
	else
		clone.Volume = originalVolume * sfxMult
	end
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
end

function BrainrotSFX.init()
	ClientSFXVolume.syncFromSoundService()

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
