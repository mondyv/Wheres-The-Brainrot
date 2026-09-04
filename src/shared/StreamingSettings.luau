-- [ACTIVE] StreamingSettings
--[[
	Custom cull / persist / radius overrides stay OFF.
	Only StreamOutBehavior is forced: Default/LowMemory dumps the spawn forest
	when you walk out, then slams it back in (FPS spike + dead inventory clicks).
]]

local M = {}

M.CUSTOM_CULL_ENABLED = false

function M.isCustomEnabled(): boolean
	return false
end

function M.gameplayMin(): number
	return 512
end

function M.gameplayTarget(): number
	return 2048
end

function M.apply(workspaceInst: Workspace)
	local wsAny = workspaceInst :: any
	-- Keep recently seen chunks (spawn trees / SafeZoneHitbox) instead of
	-- dumping them the moment you leave the lobby.
	local okOut, errOut = pcall(function()
		wsAny.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
	end)
	if not okOut then
		warn("[StreamingSettings] StreamOutBehavior apply failed:", errOut)
	end
end

return M
