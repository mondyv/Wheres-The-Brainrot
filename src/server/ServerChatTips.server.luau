-- [ACTIVE] ServerChatTips
--[[
	Posts rotating tips on an interval. DisplaySystemMessage is client-only,
	so the server broadcasts tip text via RemoteEvent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerChatTipsConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ServerChatTipsConfig"))

local messages = ServerChatTipsConfig.buildMessages()
local index = 1

local function getRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("ServerChatTipsRemotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ServerChatTipsRemotes"
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureTipRemote(): RemoteEvent
	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild("ShowChatTip")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = "ShowChatTip"
	ev.Parent = folder
	return ev
end

local tipRE = ensureTipRemote()

local function nextTipText(): string?
	if #messages == 0 then
		return nil
	end
	local text = messages[index]
	index += 1
	if index > #messages then
		index = 1
	end
	return text
end

local function postNextTip()
	local text = nextTipText()
	if not text then
		return
	end
	tipRE:FireAllClients(text)
end

task.spawn(function()
	task.wait(ServerChatTipsConfig.FIRST_DELAY_SEC)
	while true do
		if #Players:GetPlayers() > 0 then
			postNextTip()
		end
		task.wait(ServerChatTipsConfig.INTERVAL_SEC)
	end
end)
