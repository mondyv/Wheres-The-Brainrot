--[[
	DailyService
	Server authority for the 7-day daily reward calendar.

	Responsibilities:
	• Track per-player state via player attributes (DailyDayClaimed, DailyNextAvailableAt, DailySkipAllOwned).
	• Validate + grant claims; reward delivery is delegated to caller-supplied grant hooks so the
	  per-reward side effects (cash, rebirth, brainrot, lucky block) live in Daily.server.luau.
	• Push state snapshots to the client through the DailyUpdated RemoteEvent.

	Skip-All gamepass marks every remaining day claimable; players can still spam-claim through
	the calendar after purchasing it, but each "claim" still walks through the normal grant chain.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DailyConfig"))

export type GrantFn = (player: Player, reward: DailyConfig.DailyReward) -> (boolean, string?)

local DailyService = {}

local grantFn: GrantFn? = nil
local updatedRE: RemoteEvent? = nil

local function ensureAttributes(player: Player)
	if player:GetAttribute(DailyConfig.DAY_ATTR) == nil then
		player:SetAttribute(DailyConfig.DAY_ATTR, 0)
	end
	if player:GetAttribute(DailyConfig.CLAIMED_MASK_ATTR) == nil then
		local last = player:GetAttribute(DailyConfig.DAY_ATTR)
		local lastClaimed = if typeof(last) == "number" then math.floor(last) else 0
		local mask = 0
		for day = 1, math.clamp(lastClaimed, 0, DailyConfig.MAX_DAY) do
			mask = bit32.bor(mask, bit32.lshift(1, day - 1))
		end
		player:SetAttribute(DailyConfig.CLAIMED_MASK_ATTR, mask)
	end
	if player:GetAttribute(DailyConfig.NEXT_AT_ATTR) == nil then
		-- First-time players: day 1 is claimable immediately.
		player:SetAttribute(DailyConfig.NEXT_AT_ATTR, os.time())
	end
	if player:GetAttribute(DailyConfig.SKIP_ALL_ATTR) == nil then
		player:SetAttribute(DailyConfig.SKIP_ALL_ATTR, false)
	end
	if player:GetAttribute(DailyConfig.NOTIF_ATTR) == nil then
		player:SetAttribute(DailyConfig.NOTIF_ATTR, false)
	end
end

local function syncNotifAttr(player: Player)
	local state = DailyConfig.buildState(player)
	player:SetAttribute(DailyConfig.NOTIF_ATTR, DailyConfig.hasUnclaimedReady(state))
end

local function pushState(player: Player)
	if not updatedRE then
		return
	end
	syncNotifAttr(player)
	local state = DailyConfig.buildState(player)
	updatedRE:FireClient(player, state)
end

function DailyService.setRemote(remote: RemoteEvent)
	updatedRE = remote
end

function DailyService.setGrantFn(fn: GrantFn)
	grantFn = fn
end

function DailyService.initPlayer(player: Player)
	ensureAttributes(player)
	pushState(player)
end

function DailyService.getState(player: Player): DailyConfig.DailyState
	ensureAttributes(player)
	syncNotifAttr(player)
	return DailyConfig.buildState(player)
end

function DailyService.claim(player: Player, day: number): (boolean, string?, DailyConfig.DailyState?)
	ensureAttributes(player)
	local reward = DailyConfig.REWARD_BY_DAY[day]
	if not reward then
		return false, "invalid_day", nil
	end
	if not DailyConfig.canClaim(player, day) then
		return false, "not_ready", DailyConfig.buildState(player)
	end
	local fn = grantFn
	if not fn then
		return false, "no_grant_fn", DailyConfig.buildState(player)
	end
	local ok, err = fn(player, reward)
	if not ok then
		return false, err or "grant_failed", DailyConfig.buildState(player)
	end

	DailyConfig.markDayClaimed(player, day)

	local skipAll = player:GetAttribute(DailyConfig.SKIP_ALL_ATTR) == true
	if skipAll then
		player:SetAttribute(DailyConfig.NEXT_AT_ATTR, os.time())
	else
		player:SetAttribute(DailyConfig.NEXT_AT_ATTR, os.time() + DailyConfig.CLAIM_COOLDOWN_SEC)
	end

	local state = DailyConfig.buildState(player)
	syncNotifAttr(player)
	if updatedRE then
		updatedRE:FireClient(player, state)
	end
	return true, nil, state
end

function DailyService.grantSkipAll(player: Player)
	ensureAttributes(player)
	if player:GetAttribute(DailyConfig.SKIP_ALL_ATTR) == true then
		pushState(player)
		return
	end
	player:SetAttribute(DailyConfig.SKIP_ALL_ATTR, true)
	player:SetAttribute(DailyConfig.NEXT_AT_ATTR, os.time())
	pushState(player)
end

return DailyService
