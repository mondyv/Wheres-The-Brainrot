--[[
	VipChatController
	Prefixes an orange [VIP] tag onto chat messages sent by players who own the VIP
	gamepass.

	Roblox only exposes TextChatService.OnIncomingMessage as a *client* callback, so the
	tag is necessarily applied on the client — but the trust boundary is still the
	server: we only tag senders whose server-set VIPOwned attribute is true, so a
	client cannot fake a VIP tag for itself or anyone else.

	This is isolated in its own controller (with its own pcall + chat-version guard) so
	that, if the experience is still on the legacy chat system, it fails silently
	instead of taking down the rest of the store UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local StoreConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoreConfig"))

local VipChatController = {}

local function init()
	-- OnIncomingMessage only works under the new TextChatService. On the legacy
	-- system assigning it does nothing useful, so skip cleanly.
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		warn("[VIPChat] legacy chat detected — VIP tag requires TextChatService; skipping")
		return
	end

	local previous = TextChatService.OnIncomingMessage
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local props: TextChatMessageProperties? = nil
		if previous then
			local ok, prev = pcall(previous, message)
			if ok and typeof(prev) == "Instance" and prev:IsA("TextChatMessageProperties") then
				props = prev
			end
		end
		if not props then
			props = Instance.new("TextChatMessageProperties")
			props.PrefixText = message.PrefixText
		end

		local source = message.TextSource
		if source then
			local sender = Players:GetPlayerByUserId(source.UserId)
			if sender and sender:GetAttribute(StoreConfig.ATTR.VIP_OWNED) == true then
				props.PrefixText = '<font color="#FFA500">[VIP]</font> ' .. props.PrefixText
			end
		end
		return props
	end
end

function VipChatController.init()
	local ok, err = pcall(init)
	if not ok then
		warn("[VIPChat] setup failed:", err)
	end
end

return VipChatController
