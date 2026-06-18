local function compareTables(newData, oldData)
	local changes = {}

	for key, newValue in pairs(newData) do
		local oldValue = oldData[key]

		if type(newValue) == "table" and type(oldValue) == "table" then
			local nestedChanges = compareTables(newValue, oldValue)
			if next(nestedChanges) then
				changes[key] = nestedChanges
			end
		elseif newValue ~= oldValue then
			changes[key] = newValue
		end
	end

	for key, _oldValue in pairs(oldData) do
		if newData[key] == nil then
			changes[key] = nil
		end
	end

	return changes
end

return compareTables
