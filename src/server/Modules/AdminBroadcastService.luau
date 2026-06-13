-- [ACTIVE] AdminBroadcastService
--[[
	Admin-authored top notifications — current server or all servers (MessagingService).
]]

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

local MESSAGING_TOPIC = "AdminGlobalTopNotif_v1"
local REMOTE_NAME = "BroadcastTopNotif"
local MAX_MESSAGE_LEN = 240

local broadcastRE: RemoteEvent? = nil
local messagingReady = false

local function ensureRemote(): RemoteEvent
	if broadcastRE and broadcastRE.Parent then
		return broadcastRE
	end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local ev = folder:FindFirstChild(REMOTE_NAME)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = REMOTE_NAME
		ev.Parent = folder
	end
	broadcastRE = ev :: RemoteEvent
	return broadcastRE
end

local function sanitizeMessage(raw: string): string?
	local trimmed = string.gsub(raw, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end
	if #trimmed > MAX_MESSAGE_LEN then
		trimmed = string.sub(trimmed, 1, MAX_MESSAGE_LEN)
	end
	return trimmed
end

local function fireToAllPlayers(message: string, scope: string)
	local ev = ensureRemote()
	ev:FireAllClients(message, scope)
end

function M.joinArgs(args: { string }): string?
	if #args == 0 then
		return nil
	end
	return sanitizeMessage(table.concat(args, " "))
end

function M.broadcastServer(message: string): boolean
	local text = sanitizeMessage(message)
	if not text then
		return false
	end
	fireToAllPlayers(text, "server")
	return true
end

function M.broadcastGlobal(message: string, senderName: string?): boolean
	local text = sanitizeMessage(message)
	if not text then
		return false
	end
	if messagingReady then
		task.spawn(function()
			pcall(function()
				MessagingService:PublishAsync(MESSAGING_TOPIC, {
					message = text,
					sender = if typeof(senderName) == "string" then senderName else "Admin",
					sentAt = os.time(),
				})
			end)
		end)
	else
		fireToAllPlayers(text, "global")
	end
	return true
end

function M.start()
	ensureRemote()

	pcall(function()
		MessagingService:SubscribeAsync(MESSAGING_TOPIC, function(packet)
			if typeof(packet) ~= "table" or typeof(packet.Data) ~= "table" then
				return
			end
			local data = packet.Data
			if typeof(data.message) ~= "string" then
				return
			end
			local text = sanitizeMessage(data.message)
			if text then
				fireToAllPlayers(text, "global")
			end
		end)
		messagingReady = true
	end)
end

return M
