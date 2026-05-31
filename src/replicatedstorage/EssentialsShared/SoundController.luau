local SoundService = game:GetService("SoundService")

local SoundController = {}

function SoundController.play(id: string, volume: number?, looped: boolean?)
	if typeof(id) ~= "string" or id == "" or id == "rbxassetid://0" then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 0.5
	sound.Looped = looped or false
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

return SoundController
