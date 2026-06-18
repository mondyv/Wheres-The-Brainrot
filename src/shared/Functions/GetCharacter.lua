return function(Player)
	if not Player.Parent then
		return
	else
		local Character = Player.Character or Player.CharacterAdded:Wait()
		if not Character then
			return
		else
			return Character
		end
	end
end
