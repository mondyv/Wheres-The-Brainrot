local RunService = game:GetService("RunService")
return function(callback, interval, immediateCall)
	assert(type(callback) == "function", "Callback must be a function")
	assert(interval > 0, "Interval must be a positive number")

	if immediateCall then
		callback()
	end

	local timer = 0
	local connection = RunService.Heartbeat:Connect(function(delta)
		timer += delta
		if timer >= interval then
			timer = timer - interval
			callback()
		end
	end)

	return function()
		return connection:Disconnect()
	end
end
