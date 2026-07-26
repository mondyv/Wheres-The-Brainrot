-- [ACTIVE] VerifiedCreators
-- Cosmetic verified badge for core creators (chat + global broadcasts).

local M = {}

M.BADGE_IMAGE = "rbxassetid://98026673576276"
M.BADGE_MARKUP = string.format('<img src="%s"/>', M.BADGE_IMAGE)

-- Profile URL: roblox.com/users/<UserId>/profile
local VERIFIED_USER_IDS: { [number]: true } = {
	[4410847478] = true, -- Kezdinis
	[925465379] = true, -- saqartvelo321
	[9015824974] = true, -- ap3zix
	[5311146791] = true, -- ailiths
}

function M.isVerified(userId: number?): boolean
	return typeof(userId) == "number" and VERIFIED_USER_IDS[userId] == true
end

function M.formatBroadcast(message: string, senderName: string?, senderUserId: number?): string
	if typeof(senderName) ~= "string" or senderName == "" then
		return message
	end
	if M.isVerified(senderUserId) then
		return string.format("%s %s: %s", senderName, M.BADGE_MARKUP, message)
	end
	return string.format("%s: %s", senderName, message)
end

return M
