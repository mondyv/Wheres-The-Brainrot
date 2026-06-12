-- [ACTIVE] AdminAllowlist
--[[
	Server-only admin UserId allowlist.
	Only accounts listed here can run admin commands or open the F5 command bar.

	SECURITY:
	• This file lives under ServerScriptService only — never require it from client or Shared.
	• Authorization is enforced again in AdminCommands.server on every remote invoke.
	• Do not replicate this list to clients (no attributes/remotes that expose UserIds).
]]

local AdminAllowlist = {}

-- Add Roblox UserIds below (profile URL: roblox.com/users/<id>/profile).
-- Example: [123456789] = true,
local ALLOWED_USER_IDS: { [number]: true } = {
	-- Add your UserIds here:
}

function AdminAllowlist.isAllowed(userId: number): boolean
	return ALLOWED_USER_IDS[userId] == true
end

function AdminAllowlist.isPlayerAllowed(player: Player): boolean
	return AdminAllowlist.isAllowed(player.UserId)
end

return AdminAllowlist
