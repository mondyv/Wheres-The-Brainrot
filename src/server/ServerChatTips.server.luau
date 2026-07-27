-- [ACTIVE] ServerChatTips
--[[
	Posts clean rich-text system tips in chat on a fixed interval.
]]

local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerChatTipsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ServerChatTipsConfig"))

local messages = ServerChatTipsConfig.buildMessages()
local index = 1
local warnedMissingChannel = false

local function resolveTipChannel(): TextChannel?
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		local ok, result = pcall(function()
			return TextChatService:WaitForChild("TextChannels", 20)
		end)
		if ok and result then
			channels = result
		end
	end
	if not channels then
		return nil
	end
	local general = channels:FindFirstChild("RBXGeneral")
	if general and general:IsA("TextChannel") then
		return general
	end
	local system = channels:FindFirstChild("RBXSystem")
	if system and system:IsA("TextChannel") then
		return system
	end
	for _, child in ipairs(channels:GetChildren()) do
		if child:IsA("TextChannel") then
			return child
		end
	end
	return nil
end

local function postNextTip()
	if #messages == 0 then
		return
	end
	local channel = resolveTipChannel()
	if not channel then
		if not warnedMissingChannel then
			warnedMissingChannel = true
			warn("[ServerChatTips] TextChat TextChannels missing — tips disabled until chat loads")
		end
		return
	end
	local text = messages[index]
	index += 1
	if index > #messages then
		index = 1
	end
	local ok, err = pcall(function()
		channel:DisplaySystemMessage(text)
	end)
	if not ok then
		warn("[ServerChatTips] DisplaySystemMessage failed:", err)
	end
end

task.spawn(function()
	task.wait(ServerChatTipsConfig.FIRST_DELAY_SEC)
	while true do
		postNextTip()
		task.wait(ServerChatTipsConfig.INTERVAL_SEC)
	end
end)
