local RunService = game:GetService("RunService")
return function(player: Player)
	if RunService:IsServer() then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local MainGUI = playerGui:WaitForChild("MainGUI")
	return MainGUI
end
