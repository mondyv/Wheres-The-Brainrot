return function(seconds)
	local days = math.floor(seconds / 86400)
	seconds = seconds % 86400
	local hours = math.floor(seconds / 3600)
	seconds = seconds % 3600
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60

	if days > 0 then
		return string.format("%d:%02d:%02d:%02d", days, hours, minutes, seconds)
	elseif hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, seconds)
	elseif minutes > 0 then
		return string.format("%d:%02d", minutes, seconds)
	else
		return string.format("0:%02d", seconds)
	end
end
