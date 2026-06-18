local Functions = {
	suffixes = require(script.Suffixes),
	getHRP = require(script.GetHRP),
	getHumanoid = require(script.GetHumanoid),
	compareTables = require(script.CompareTables),
	getEnvironment = require(script.GetEnvironment),
	logger = require(script.Logger),
	getUniqueId = require(script.GetUniqueId),
	getCharacter = require(script.GetCharacter),
	formatTime = require(script.FormatTime),
	setInterval = require(script.SetInterval),
	getProductInfo = require(script.GetProductInfo),
	find = require(script.Find),
	formatCommas = require(script.FormatCommas),
	getPlayerGui = require(script.GetPlayerGUI),
}

for _, _script in script:GetDescendants() do
	if _script:IsA("ModuleScript") then
		local name = string.sub(_script.Name, 1, 1):lower() .. string.sub(_script.Name, 2, -1)
		if not Functions[name] then
			Functions[name] = require(_script)
		end
	end
end

return Functions
