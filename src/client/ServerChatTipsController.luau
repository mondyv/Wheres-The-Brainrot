-- [ACTIVE] ServerChatTipsController
--[[
	Receives tip text from the server and shows it in TextChat (client-only API).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local ServerChatTipsController = {}

local function resolveTipChannel(): TextChannel?
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		local ok, result = pcall(function()
			return TextChatService:WaitForChild("TextChannels", 30)
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
	for _, child in channels:GetChildren() do
		if child:IsA("TextChannel") then
			return child
		end
	end
	return nil
end

local function showTip(text: string)
	if typeof(text) ~= "string" or text == "" then
		return
	end

	local channel = resolveTipChannel()
	if channel then
		local ok, err = pcall(function()
			channel:DisplaySystemMessage(text)
		end)
		if ok then
			return
		end
		warn("[ServerChatTipsController] DisplaySystemMessage failed:", err)
	end

	-- Legacy chat fallback (plain text; strips simple font tags).
	local plain = text:gsub("<.->", "")
	local okCore, errCore = pcall(function()
		StarterGui:SetCore("ChatMakeSystemMessage", {
			Text = plain,
			Color = Color3.fromRGB(228, 232, 240),
		})
	end)
	if not okCore then
		warn("[ServerChatTipsController] ChatMakeSystemMessage failed:", errCore)
	end
end

function ServerChatTipsController.init()
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("ServerChatTipsRemotes", 60)
		if not folder then
			warn("[ServerChatTipsController] ServerChatTipsRemotes missing")
			return
		end
		local tipRE = folder:WaitForChild("ShowChatTip", 30)
		if not tipRE or not tipRE:IsA("RemoteEvent") then
			warn("[ServerChatTipsController] ShowChatTip remote missing")
			return
		end
		(tipRE :: RemoteEvent).OnClientEvent:Connect(showTip)
	end)
end

return ServerChatTipsController
