return function(value)
	local num = math.floor(tonumber(value) or 0)
	local sign = num < 0 and "-" or ""
	num = math.abs(num)

	local str = tostring(num)
	local result = ""

	while #str > 3 do
		result = "," .. string.sub(str, -3) .. result
		str = string.sub(str, 1, -4)
	end

	result = str .. result

	return sign .. result
end
