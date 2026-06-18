local Logger = require(script.Parent.Logger)
return function(parent: Instance, path: string)
	local pathParts = string.split(path, "/")

	local Instance = parent
	for _, pathPart in pathParts do
		local child = Instance:FindFirstChild(pathPart)
		if child == nil then
			Logger.error(`failed to find {pathPart} in {Instance:GetFullName()} (full path: {path})`)
		end
		Instance = child
	end

	return Instance
end
