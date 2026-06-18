local RunService = game:GetService("RunService")
local Logger = {}

local function getScriptInfo()
	local traceback = debug.traceback()
	local pattern = "([^\n]+):(%d+)"
	local count = 0
	for source, line in string.gmatch(traceback, pattern) do
		count = count + 1
		if count == 4 then
			source = source:match("([^%.]+)$") or source
			return source, tonumber(line) or 0
		end
	end
	return "Unknown", 0
end

local function log(level, message, bypassStudioCheck, ...)
	local scriptName, lineNumber = getScriptInfo()
	local formattedMessage =
		string.format("[%s] [%s:%d] %s", level, scriptName, lineNumber, string.format(message, ...))

	if level == "ERROR" or level == "WARN" or bypassStudioCheck or RunService:IsStudio() then
		if level == "ERROR" or level == "WARN" then
			warn(formattedMessage)
		else
			print(formattedMessage)
		end
	end
end

function Logger.info(message, ...)
	if RunService:IsStudio() then
		local args = { ... }
		log("INFO", message, false, table.unpack(args))
	end
end

function Logger.warn(message, ...)
	local args = { ... }
	log("WARN", message, false, table.unpack(args))
end

function Logger.error(message, ...)
	local args = { ... }
	log("ERROR", message, false, table.unpack(args))
end

function Logger.bypassInfo(message, ...) -- this means it will print in production games btw
	local args = { ... }
	log("INFO", message, true, table.unpack(args))
end

return Logger
