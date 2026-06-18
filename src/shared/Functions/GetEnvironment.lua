local RunService = game:GetService("RunService")
return function()
	if RunService:IsStudio() then
		return "Development - #006"
	else
		return "Production"
	end
end
