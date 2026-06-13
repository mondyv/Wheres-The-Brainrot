-- [ACTIVE] AdminAllowlist
--[[
	Server-only admin access rules.
	Live game: allowlisted UserIds + game owner + group rank 250+.
	Studio: any player (dev convenience, same as the original admin panel).

	SECURITY:
	• This module is server-only — never require from client or Shared.
	• AdminCommands re-checks isPlayerAllowed on every remote invoke.
	• The allowlist table is never sent to clients.
]]

local RunService = game:GetService("RunService")

local AdminAllowlist = {}

local GROUP_ADMIN_RANK = 250

-- Extra admins (mods). Game owner + group rank 250+ are allowed automatically on live servers.
-- Profile URL: roblox.com/users/<UserId>/profile
local ALLOWED_USER_IDS: { [number]: true } = {
	[4410847478] = true,
	[925465379] = true,
	[9015824974] = true,
	[5311146791] = true,
}

local function isGroupAdmin(player: Player): boolean
	if game.CreatorType ~= Enum.CreatorType.Group then
		return false
	end
	local ok, rank = pcall(function()
		return player:GetRankInGroup(game.CreatorId)
	end)
	if not ok then
		warn("[AdminAllowlist] group rank check failed:", rank)
		return false
	end
	return typeof(rank) == "number" and rank >= GROUP_ADMIN_RANK
end

function AdminAllowlist.isAllowed(userId: number): boolean
	if ALLOWED_USER_IDS[userId] then
		return true
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and userId == game.CreatorId then
		return true
	end
	return false
end

function AdminAllowlist.isPlayerAllowed(player: Player): boolean
	if ALLOWED_USER_IDS[player.UserId] then
		return true
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	if isGroupAdmin(player) then
		return true
	end
	return false
end

return AdminAllowlist
